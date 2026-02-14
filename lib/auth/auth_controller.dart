import 'package:get/get.dart';

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

  void configure(AppCloudConfig config) {
    isEnabled.value = config.auth.enabled;
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

    status.value = 'Authorization configured (${options.length} providers)';
  }

  AuthActionResult beginSignIn(AuthProviderType providerType) {
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
    session.value = null;
    status.value = 'Signed out';
  }
}
