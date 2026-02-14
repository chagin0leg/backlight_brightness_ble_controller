import 'dart:async';

import 'package:get/get.dart';

import 'package:backlight_brightness_ble_controller/auth/auth_gateway_client.dart';
import 'package:backlight_brightness_ble_controller/auth/auth_provider.dart';
import 'package:backlight_brightness_ble_controller/cloud/app_cloud_config.dart';

class AuthProviderOption {
  const AuthProviderOption({
    required this.provider,
    required this.displayName,
    required this.enabled,
    this.oauthStartUrl,
    this.notes,
  });

  final AuthProviderType provider;
  final String displayName;
  final bool enabled;
  final String? oauthStartUrl;
  final String? notes;
}

class AuthSession {
  const AuthSession({
    required this.provider,
    required this.userId,
    required this.displayName,
    required this.issuedAtUtc,
  });

  final AuthProviderType provider;
  final String userId;
  final String displayName;
  final DateTime issuedAtUtc;
}

class AuthActionResult {
  const AuthActionResult({
    required this.ok,
    required this.message,
    this.externalAuthUrl,
  });

  final bool ok;
  final String message;
  final String? externalAuthUrl;
}

class AuthController extends GetxController {
  final RxBool isEnabled = false.obs;
  final RxList<AuthProviderOption> options = <AuthProviderOption>[].obs;
  final Rxn<AuthSession> session = Rxn<AuthSession>();
  final RxString status = 'Authorization is not configured'.obs;
  final RxnString pendingSessionId = RxnString();
  final RxnString pendingExternalAuthUrl = RxnString();

  AuthGatewayClient? _gatewayClient;
  Timer? _authPollTimer;
  DateTime? _sessionStartedAtUtc;
  int _pollIntervalSeconds = 3;
  int _sessionTimeoutSeconds = 240;
  AuthProviderType? _pendingProvider;

  void configure(AppCloudConfig config) {
    isEnabled.value = config.auth.enabled;
    _pollIntervalSeconds = config.auth.pollIntervalSeconds.clamp(1, 30).toInt();
    _sessionTimeoutSeconds = config.auth.sessionTimeoutSeconds.clamp(30, 1800).toInt();
    _gatewayClient = config.auth.canUseDeviceFlow
        ? AuthGatewayClient(
            deviceStartUrl: config.auth.deviceStartUrl!,
            deviceStatusUrl: config.auth.deviceStatusUrl!,
          )
        : null;

    options.value = config.auth.providers
        .map(
          (providerConfig) => AuthProviderOption(
            provider: providerConfig.provider,
            displayName: providerConfig.displayName,
            enabled: providerConfig.enabled,
            oauthStartUrl: providerConfig.oauthStartUrl,
            notes: providerConfig.notes,
          ),
        )
        .toList(growable: false);

    if (!isEnabled.value) {
      status.value = 'Authorization disabled by cloud configuration';
      return;
    }

    if (options.isEmpty) {
      status.value = 'Authorization enabled but providers list is empty';
      return;
    }

    status.value = _gatewayClient == null
        ? 'Authorization configured (${options.length} providers)'
        : 'Authorization configured with device flow (${options.length} providers)';
  }

  Future<AuthActionResult> beginSignIn(AuthProviderType providerType) async {
    AuthProviderOption? option;
    for (final item in options) {
      if (item.provider == providerType) {
        option = item;
        break;
      }
    }

    if (option == null) {
      return const AuthActionResult(
        ok: false,
        message: 'Selected provider is not configured',
      );
    }

    if (!option.enabled) {
      return AuthActionResult(
        ok: false,
        message: '${option.displayName} sign-in is disabled in config',
      );
    }

    _stopPolling();

    if (option.provider == AuthProviderType.anonymousGuest) {
      completeSignIn(
        provider: AuthProviderType.anonymousGuest,
        userId: 'guest-${DateTime.now().millisecondsSinceEpoch}',
        displayName: 'Guest',
      );
      return const AuthActionResult(
        ok: true,
        message: 'Guest session has been started',
      );
    }

    if (_gatewayClient != null) {
      final startResult = await _gatewayClient!.startDeviceSession(
        provider: option.provider.name,
        externalAuthUrl: option.oauthStartUrl,
      );
      if (!startResult.ok ||
          startResult.sessionId == null ||
          startResult.sessionId!.isEmpty) {
        return AuthActionResult(
          ok: false,
          message: startResult.message,
        );
      }

      pendingSessionId.value = startResult.sessionId;
      pendingExternalAuthUrl.value = startResult.authUrl;
      _sessionStartedAtUtc = DateTime.now().toUtc();
      _pendingProvider = option.provider;

      status.value =
          'Device auth started for ${option.displayName}. Open URL and complete sign-in.';
      _authPollTimer = Timer.periodic(
        Duration(seconds: _pollIntervalSeconds),
        (timer) => _pollAuthSession(),
      );
      unawaited(_pollAuthSession());

      return AuthActionResult(
        ok: true,
        message: 'Device auth started for ${option.displayName}',
        externalAuthUrl: startResult.authUrl,
      );
    }

    if (option.oauthStartUrl == null || option.oauthStartUrl!.isEmpty) {
      return AuthActionResult(
        ok: false,
        message:
            '${option.displayName} requires OAuth start URL (serverless gateway or BaaS endpoint)',
      );
    }

    status.value =
        'External sign-in flow started for ${option.displayName}. Open provider URL.';
    return AuthActionResult(
      ok: true,
      message: 'External sign-in URL prepared for ${option.displayName}',
      externalAuthUrl: option.oauthStartUrl,
    );
  }

  Future<void> _pollAuthSession() async {
    final sessionId = pendingSessionId.value;
    final gatewayClient = _gatewayClient;
    if (sessionId == null || sessionId.isEmpty || gatewayClient == null) {
      return;
    }

    final startedAt = _sessionStartedAtUtc;
    if (startedAt != null &&
        DateTime.now().toUtc().difference(startedAt).inSeconds >
            _sessionTimeoutSeconds) {
      status.value = 'Auth session timeout. Please try sign-in again.';
      _stopPolling();
      return;
    }

    final result = await gatewayClient.getDeviceSessionStatus(
      sessionId: sessionId,
    );
    if (!result.ok && result.status == 'error') {
      status.value = result.message;
      return;
    }

    final normalizedStatus = result.status.trim().toLowerCase();
    if (normalizedStatus == 'pending') {
      status.value = 'Sign-in pending. Finish auth in browser.';
      return;
    }

    if (normalizedStatus == 'completed') {
      final provider = result.provider == null
          ? (_pendingProvider ?? AuthProviderType.unknown)
          : authProviderTypeFromString(result.provider!);
      final subject = (result.subject == null || result.subject!.isEmpty)
          ? 'subject-${DateTime.now().millisecondsSinceEpoch}'
          : result.subject!;
      completeSignIn(
        provider: provider,
        userId: subject,
        displayName: authProviderDisplayName(provider),
      );
      _stopPolling();
      return;
    }

    if (normalizedStatus == 'failed' || normalizedStatus == 'expired') {
      status.value = result.error == null || result.error!.isEmpty
          ? 'Sign-in failed ($normalizedStatus)'
          : 'Sign-in failed: ${result.error}';
      _stopPolling();
    }
  }

  void _stopPolling() {
    _authPollTimer?.cancel();
    _authPollTimer = null;
    pendingSessionId.value = null;
    pendingExternalAuthUrl.value = null;
    _sessionStartedAtUtc = null;
    _pendingProvider = null;
  }

  void completeSignIn({
    required AuthProviderType provider,
    required String userId,
    required String displayName,
  }) {
    session.value = AuthSession(
      provider: provider,
      userId: userId,
      displayName: displayName,
      issuedAtUtc: DateTime.now().toUtc(),
    );
    status.value = 'Signed in as $displayName via ${authProviderDisplayName(provider)}';
  }

  void signOut() {
    _stopPolling();
    session.value = null;
    status.value = 'Signed out';
  }

  @override
  void onClose() {
    _stopPolling();
    super.onClose();
  }
}
