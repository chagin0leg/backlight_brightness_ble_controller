import 'dart:convert';
import 'dart:developer';

import 'package:flutter/services.dart';

import 'package:backlight_brightness_ble_controller/auth/auth_provider.dart';

enum CloudBackendKind {
  disabled,
  firebase,
  supabase,
  appwrite,
  customWebhook,
}

CloudBackendKind cloudBackendKindFromString(String rawValue) {
  final normalized = rawValue.trim().toLowerCase();
  switch (normalized) {
    case 'firebase':
      return CloudBackendKind.firebase;
    case 'supabase':
      return CloudBackendKind.supabase;
    case 'appwrite':
      return CloudBackendKind.appwrite;
    case 'custom_webhook':
      return CloudBackendKind.customWebhook;
    case 'disabled':
    default:
      return CloudBackendKind.disabled;
  }
}

class AuthProviderCloudConfig {
  const AuthProviderCloudConfig({
    required this.provider,
    required this.enabled,
    required this.displayName,
    this.oauthStartUrl,
    this.notes,
  });

  final AuthProviderType provider;
  final bool enabled;
  final String displayName;
  final String? oauthStartUrl;
  final String? notes;

  factory AuthProviderCloudConfig.fromMap(Map<String, dynamic> map) {
    final provider = authProviderTypeFromString(map['provider'].toString());
    final fallbackDisplayName = authProviderDisplayName(provider);
    final rawUrl = map['oauth_start_url']?.toString();
    return AuthProviderCloudConfig(
      provider: provider,
      enabled: map['enabled'] as bool? ?? false,
      displayName: (map['display_name']?.toString() ?? fallbackDisplayName).trim(),
      oauthStartUrl: (rawUrl == null || rawUrl.trim().isEmpty) ? null : rawUrl,
      notes: map['notes']?.toString(),
    );
  }
}

class AuthCloudConfig {
  const AuthCloudConfig({
    required this.enabled,
    required this.providers,
  });

  final bool enabled;
  final List<AuthProviderCloudConfig> providers;

  factory AuthCloudConfig.fromMap(Map<String, dynamic> map) {
    final parsedProviders = <AuthProviderCloudConfig>[];
    for (final item in (map['providers'] as List<dynamic>? ?? <dynamic>[])) {
      if (item is Map<String, dynamic>) {
        parsedProviders.add(AuthProviderCloudConfig.fromMap(item));
      }
    }
    return AuthCloudConfig(
      enabled: map['enabled'] as bool? ?? false,
      providers: parsedProviders,
    );
  }
}

class DiagnosticsCloudConfig {
  const DiagnosticsCloudConfig({
    required this.enabled,
    required this.uploadWithUserConsent,
    this.uploadUrl,
    this.apiKeyHeader,
    this.apiKeyValue,
    this.timeoutSeconds = 12,
  });

  final bool enabled;
  final bool uploadWithUserConsent;
  final String? uploadUrl;
  final String? apiKeyHeader;
  final String? apiKeyValue;
  final int timeoutSeconds;

  bool get canUpload =>
      enabled &&
      uploadWithUserConsent &&
      uploadUrl != null &&
      uploadUrl!.trim().isNotEmpty;

  factory DiagnosticsCloudConfig.fromMap(Map<String, dynamic> map) {
    final rawUrl = map['upload_url']?.toString();
    return DiagnosticsCloudConfig(
      enabled: map['enabled'] as bool? ?? false,
      uploadWithUserConsent: map['upload_with_user_consent'] as bool? ?? false,
      uploadUrl: (rawUrl == null || rawUrl.trim().isEmpty) ? null : rawUrl,
      apiKeyHeader: map['api_key_header']?.toString(),
      apiKeyValue: map['api_key_value']?.toString(),
      timeoutSeconds: _toInt(map['timeout_seconds'], 12),
    );
  }
}

class ProfileRegistryCloudConfig {
  const ProfileRegistryCloudConfig({
    this.remoteManifestUrl,
    this.refreshMinutes = 120,
  });

  final String? remoteManifestUrl;
  final int refreshMinutes;

  factory ProfileRegistryCloudConfig.fromMap(Map<String, dynamic> map) {
    final rawUrl = map['remote_manifest_url']?.toString();
    return ProfileRegistryCloudConfig(
      remoteManifestUrl: (rawUrl == null || rawUrl.trim().isEmpty) ? null : rawUrl,
      refreshMinutes: _toInt(map['refresh_minutes'], 120),
    );
  }
}

class AppCloudConfig {
  const AppCloudConfig({
    required this.backendKind,
    required this.auth,
    required this.diagnostics,
    required this.profileRegistry,
  });

  final CloudBackendKind backendKind;
  final AuthCloudConfig auth;
  final DiagnosticsCloudConfig diagnostics;
  final ProfileRegistryCloudConfig profileRegistry;

  factory AppCloudConfig.fromMap(Map<String, dynamic> map) {
    return AppCloudConfig(
      backendKind: cloudBackendKindFromString(
        map['backend_kind']?.toString() ?? 'disabled',
      ),
      auth: AuthCloudConfig.fromMap(
        map['auth'] as Map<String, dynamic>? ?? <String, dynamic>{},
      ),
      diagnostics: DiagnosticsCloudConfig.fromMap(
        map['diagnostics'] as Map<String, dynamic>? ?? <String, dynamic>{},
      ),
      profileRegistry: ProfileRegistryCloudConfig.fromMap(
        map['profile_registry'] as Map<String, dynamic>? ?? <String, dynamic>{},
      ),
    );
  }

  factory AppCloudConfig.disabled() {
    return const AppCloudConfig(
      backendKind: CloudBackendKind.disabled,
      auth: AuthCloudConfig(enabled: false, providers: <AuthProviderCloudConfig>[]),
      diagnostics: DiagnosticsCloudConfig(
        enabled: false,
        uploadWithUserConsent: false,
      ),
      profileRegistry: ProfileRegistryCloudConfig(),
    );
  }
}

class AppCloudConfigLoader {
  static const String defaultAssetPath = 'assets/runtime/app_cloud_config.json';

  static Future<AppCloudConfig> load({String assetPath = defaultAssetPath}) async {
    try {
      final rawJson = await rootBundle.loadString(assetPath);
      final decoded = jsonDecode(rawJson);
      if (decoded is Map<String, dynamic>) {
        return AppCloudConfig.fromMap(decoded);
      }
    } catch (error) {
      log('Unable to load cloud config from $assetPath: $error');
    }
    return AppCloudConfig.disabled();
  }
}

int _toInt(dynamic rawValue, int defaultValue) {
  if (rawValue is int) {
    return rawValue;
  }
  if (rawValue is num) {
    return rawValue.toInt();
  }
  if (rawValue is String) {
    return int.tryParse(rawValue) ?? defaultValue;
  }
  return defaultValue;
}
