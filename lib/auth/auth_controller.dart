import 'dart:async';

import 'package:get/get.dart';

import 'package:backlight_brightness_ble_controller/auth/auth_gateway_client.dart';
import 'package:backlight_brightness_ble_controller/auth/auth_provider.dart';
import 'package:backlight_brightness_ble_controller/auth/auth_session.dart';
import 'package:backlight_brightness_ble_controller/auth/auth_session_storage.dart';
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
  AuthController({AuthSessionStorage? sessionStorage})
      : _sessionStorage =
            sessionStorage ?? ResilientAuthSessionStorage();

  final AuthSessionStorage _sessionStorage;
  final RxBool isEnabled = false.obs;
  final RxList<AuthProviderOption> options = <AuthProviderOption>[].obs;
  final Rxn<AuthSession> session = Rxn<AuthSession>();
  final RxString status = 'Authorization is not configured'.obs;
  final RxnString sessionWarning = RxnString();
  final RxBool isSignInPending = false.obs;
  final RxInt pollErrorCount = 0.obs;
  final RxnString pendingSessionId = RxnString();
  final RxnString pendingExternalAuthUrl = RxnString();

  AuthGatewayClient? _gatewayClient;
  Timer? _authPollTimer;
  Timer? _sessionWatchdog;
  DateTime? _sessionStartedAtUtc;
  int _pollIntervalSeconds = 3;
  int _sessionTimeoutSeconds = 240;
  int _sessionCheckIntervalSeconds = 30;
  AuthProviderType? _pendingProvider;
  bool _pollInFlight = false;
  bool _rememberSession = true;
  bool _reauthPromptShown = false;
  Duration _sessionTtl = const Duration(days: 30);
  Duration _reauthPromptBefore = const Duration(hours: 24);

  Future<void> configure(AppCloudConfig config) async {
    isEnabled.value = config.auth.enabled;
    _pollIntervalSeconds = config.auth.pollIntervalSeconds.clamp(1, 30).toInt();
    _sessionTimeoutSeconds = config.auth.sessionTimeoutSeconds.clamp(30, 1800).toInt();
    _sessionCheckIntervalSeconds =
        config.auth.sessionCheckIntervalSeconds.clamp(5, 300).toInt();
    _rememberSession = config.auth.rememberSession;
    _sessionTtl =
        Duration(minutes: config.auth.sessionTtlMinutes.clamp(5, 525600).toInt());
    _reauthPromptBefore = Duration(
      minutes: config.auth.reauthPromptMinutes.clamp(1, 10080).toInt(),
    );
    _gatewayClient = config.auth.canUseDeviceFlow
        ? AuthGatewayClient(
            deviceStartUrl: config.auth.deviceStartUrl!,
            deviceStatusUrl: config.auth.deviceStatusUrl!,
          )
        : null;

    options.value = config.auth.providers
        .where(
          (providerConfig) =>
              providerConfig.provider != AuthProviderType.anonymousGuest,
        )
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
      _stopPolling();
      _sessionWatchdog?.cancel();
      session.value = null;
      sessionWarning.value = null;
      if (_rememberSession) {
        unawaited(_sessionStorage.clear());
      }
      status.value = 'Authorization disabled by cloud configuration';
      return;
    }

    if (!_rememberSession) {
      session.value = null;
      await _sessionStorage.clear();
    }

    final restored = await _restoreSession();
    _startSessionWatchdog();

    if (options.isEmpty) {
      status.value = 'Authorization enabled but providers list is empty';
      return;
    }

    if (!restored) {
      status.value = _gatewayClient == null
          ? 'Authorization configured (${options.length} providers)'
          : 'Authorization configured with device flow (${options.length} providers)';
    }
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
      return const AuthActionResult(
        ok: false,
        message: 'Guest sign-in is disabled by product policy',
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
      if (startResult.authUrl == null || startResult.authUrl!.isEmpty) {
        return const AuthActionResult(
          ok: false,
          message: 'Auth session started, but auth URL is missing',
        );
      }

      pendingSessionId.value = startResult.sessionId;
      pendingExternalAuthUrl.value = startResult.authUrl;
      _sessionStartedAtUtc = DateTime.now().toUtc();
      _pendingProvider = option.provider;
      isSignInPending.value = true;
      pollErrorCount.value = 0;

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
    if (_pollInFlight) {
      return;
    }

    final sessionId = pendingSessionId.value;
    final gatewayClient = _gatewayClient;
    if (sessionId == null || sessionId.isEmpty || gatewayClient == null) {
      return;
    }

    _pollInFlight = true;
    final startedAt = _sessionStartedAtUtc;
    try {
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
        pollErrorCount.value += 1;
        status.value = result.message;
        if (pollErrorCount.value >= 5) {
          status.value =
              'Sign-in failed due to repeated network errors. Please retry.';
          _stopPolling();
        }
        return;
      }

      pollErrorCount.value = 0;
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
    } finally {
      _pollInFlight = false;
    }
  }

  void _stopPolling() {
    _authPollTimer?.cancel();
    _authPollTimer = null;
    isSignInPending.value = false;
    pollErrorCount.value = 0;
    pendingSessionId.value = null;
    pendingExternalAuthUrl.value = null;
    _sessionStartedAtUtc = null;
    _pendingProvider = null;
    _pollInFlight = false;
  }

  void completeSignIn({
    required AuthProviderType provider,
    required String userId,
    required String displayName,
    Duration? ttl,
  }) {
    final now = DateTime.now().toUtc();
    final expiresAt = now.add(ttl ?? _sessionTtl);
    session.value = AuthSession(
      provider: provider,
      userId: userId,
      displayName: displayName,
      issuedAtUtc: now,
      expiresAtUtc: expiresAt,
    );
    sessionWarning.value = null;
    _reauthPromptShown = false;
    if (_rememberSession) {
      unawaited(_sessionStorage.write(session.value!));
    }
    status.value = 'Signed in as $displayName via ${authProviderDisplayName(provider)}';
    _startSessionWatchdog();
  }

  void signOut({String reason = 'Signed out'}) {
    _stopPolling();
    sessionWarning.value = null;
    _reauthPromptShown = false;
    session.value = null;
    if (_rememberSession) {
      unawaited(_sessionStorage.clear());
    }
    status.value = reason;
  }

  void cancelPendingSignIn() {
    if (!isSignInPending.value) {
      return;
    }
    _stopPolling();
    status.value = 'Sign-in cancelled by user';
  }

  Future<bool> _restoreSession() async {
    if (!_rememberSession) {
      return false;
    }
    final restored = await _sessionStorage.read();
    if (restored == null) {
      return false;
    }
    if (restored.isExpired) {
      await _sessionStorage.clear();
      session.value = null;
      status.value = 'Stored session has expired. Please sign in again.';
      return false;
    }
    session.value = restored;
    status.value =
        'Session restored for ${restored.displayName} via ${authProviderDisplayName(restored.provider)}';
    return true;
  }

  void _startSessionWatchdog() {
    _sessionWatchdog?.cancel();
    _sessionWatchdog = Timer.periodic(
      Duration(seconds: _sessionCheckIntervalSeconds),
      (timer) => _evaluateSessionState(),
    );
    _evaluateSessionState();
  }

  void _evaluateSessionState() {
    final activeSession = session.value;
    if (activeSession == null) {
      sessionWarning.value = null;
      _reauthPromptShown = false;
      return;
    }

    final remaining = activeSession.timeLeft;
    if (remaining <= Duration.zero) {
      signOut(reason: 'Session expired. Please sign in again.');
      return;
    }

    if (remaining <= _reauthPromptBefore) {
      final pretty = _formatDuration(remaining);
      sessionWarning.value = 'Session expires in $pretty. Re-auth is recommended.';
      if (!_reauthPromptShown) {
        status.value = 'Session is close to expiration. Re-auth soon.';
        _reauthPromptShown = true;
      }
      return;
    }

    sessionWarning.value = null;
    _reauthPromptShown = false;
  }

  String _formatDuration(Duration duration) {
    final totalMinutes = duration.inMinutes;
    if (totalMinutes <= 0) {
      return 'less than a minute';
    }
    final days = totalMinutes ~/ (24 * 60);
    final hours = (totalMinutes % (24 * 60)) ~/ 60;
    final minutes = totalMinutes % 60;

    if (days > 0) {
      return '${days}d ${hours}h';
    }
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    }
    return '${minutes}m';
  }

  @override
  void onClose() {
    _stopPolling();
    _sessionWatchdog?.cancel();
    super.onClose();
  }
}
