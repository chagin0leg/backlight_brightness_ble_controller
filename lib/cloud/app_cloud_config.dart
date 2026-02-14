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

enum AdsProviderKind {
  disabled,
  admob,
  yandexAds,
  applovin,
  unityAds,
  custom,
}

AdsProviderKind adsProviderKindFromString(String rawValue) {
  final normalized = rawValue.trim().toLowerCase();
  switch (normalized) {
    case 'admob':
      return AdsProviderKind.admob;
    case 'yandex_ads':
      return AdsProviderKind.yandexAds;
    case 'applovin':
      return AdsProviderKind.applovin;
    case 'unity_ads':
      return AdsProviderKind.unityAds;
    case 'custom':
      return AdsProviderKind.custom;
    case 'disabled':
    default:
      return AdsProviderKind.disabled;
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
    required this.deviceFlowEnabled,
    this.deviceStartUrl,
    this.deviceStatusUrl,
    this.pollIntervalSeconds = 3,
    this.sessionTimeoutSeconds = 240,
  });

  final bool enabled;
  final List<AuthProviderCloudConfig> providers;
  final bool deviceFlowEnabled;
  final String? deviceStartUrl;
  final String? deviceStatusUrl;
  final int pollIntervalSeconds;
  final int sessionTimeoutSeconds;

  bool get canUseDeviceFlow =>
      enabled &&
      deviceFlowEnabled &&
      deviceStartUrl != null &&
      deviceStartUrl!.trim().isNotEmpty &&
      deviceStatusUrl != null &&
      deviceStatusUrl!.trim().isNotEmpty;

  factory AuthCloudConfig.fromMap(Map<String, dynamic> map) {
    final parsedProviders = <AuthProviderCloudConfig>[];
    for (final item in (map['providers'] as List<dynamic>? ?? <dynamic>[])) {
      if (item is Map<String, dynamic>) {
        parsedProviders.add(AuthProviderCloudConfig.fromMap(item));
      }
    }
    final rawStartUrl = map['device_start_url']?.toString();
    final rawStatusUrl = map['device_status_url']?.toString();
    return AuthCloudConfig(
      enabled: map['enabled'] as bool? ?? false,
      providers: parsedProviders,
      deviceFlowEnabled: map['device_flow_enabled'] as bool? ?? false,
      deviceStartUrl:
          (rawStartUrl == null || rawStartUrl.trim().isEmpty) ? null : rawStartUrl,
      deviceStatusUrl:
          (rawStatusUrl == null || rawStatusUrl.trim().isEmpty) ? null : rawStatusUrl,
      pollIntervalSeconds: _toInt(map['poll_interval_seconds'], 3),
      sessionTimeoutSeconds: _toInt(map['session_timeout_seconds'], 240),
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

class AdsCloudConfig {
  const AdsCloudConfig({
    required this.enabled,
    required this.provider,
    required this.nonPersonalizedOnly,
    this.bannerUnitId,
    this.interstitialUnitId,
    this.rewardedUnitId,
    this.minIntervalSeconds = 90,
  });

  final bool enabled;
  final AdsProviderKind provider;
  final bool nonPersonalizedOnly;
  final String? bannerUnitId;
  final String? interstitialUnitId;
  final String? rewardedUnitId;
  final int minIntervalSeconds;

  factory AdsCloudConfig.fromMap(Map<String, dynamic> map) {
    return AdsCloudConfig(
      enabled: map['enabled'] as bool? ?? false,
      provider: adsProviderKindFromString(
        map['provider']?.toString() ?? 'disabled',
      ),
      nonPersonalizedOnly: map['non_personalized_only'] as bool? ?? true,
      bannerUnitId: map['banner_unit_id']?.toString(),
      interstitialUnitId: map['interstitial_unit_id']?.toString(),
      rewardedUnitId: map['rewarded_unit_id']?.toString(),
      minIntervalSeconds: _toInt(map['min_interval_seconds'], 90),
    );
  }
}

class AnonymousAnalyticsCloudConfig {
  const AnonymousAnalyticsCloudConfig({
    required this.enabled,
    required this.collectUsageEvents,
    required this.collectCrashSignals,
    required this.sampleRatePercent,
    this.endpointUrl,
  });

  final bool enabled;
  final bool collectUsageEvents;
  final bool collectCrashSignals;
  final int sampleRatePercent;
  final String? endpointUrl;

  factory AnonymousAnalyticsCloudConfig.fromMap(Map<String, dynamic> map) {
    final rawUrl = map['endpoint_url']?.toString();
    return AnonymousAnalyticsCloudConfig(
      enabled: map['enabled'] as bool? ?? false,
      collectUsageEvents: map['collect_usage_events'] as bool? ?? true,
      collectCrashSignals: map['collect_crash_signals'] as bool? ?? true,
      sampleRatePercent:
          _toInt(map['sample_rate_percent'], 20).clamp(1, 100).toInt(),
      endpointUrl: (rawUrl == null || rawUrl.trim().isEmpty) ? null : rawUrl,
    );
  }
}

class AppCloudConfig {
  const AppCloudConfig({
    required this.backendKind,
    required this.auth,
    required this.diagnostics,
    required this.profileRegistry,
    required this.ads,
    required this.anonymousAnalytics,
  });

  final CloudBackendKind backendKind;
  final AuthCloudConfig auth;
  final DiagnosticsCloudConfig diagnostics;
  final ProfileRegistryCloudConfig profileRegistry;
  final AdsCloudConfig ads;
  final AnonymousAnalyticsCloudConfig anonymousAnalytics;

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
      ads: AdsCloudConfig.fromMap(
        map['ads'] as Map<String, dynamic>? ?? <String, dynamic>{},
      ),
      anonymousAnalytics: AnonymousAnalyticsCloudConfig.fromMap(
        map['anonymous_analytics'] as Map<String, dynamic>? ??
            <String, dynamic>{},
      ),
    );
  }

  factory AppCloudConfig.disabled() {
    return const AppCloudConfig(
      backendKind: CloudBackendKind.disabled,
      auth: AuthCloudConfig(
        enabled: false,
        providers: <AuthProviderCloudConfig>[],
        deviceFlowEnabled: false,
      ),
      diagnostics: DiagnosticsCloudConfig(
        enabled: false,
        uploadWithUserConsent: false,
      ),
      profileRegistry: ProfileRegistryCloudConfig(),
      ads: AdsCloudConfig(
        enabled: false,
        provider: AdsProviderKind.disabled,
        nonPersonalizedOnly: true,
      ),
      anonymousAnalytics: AnonymousAnalyticsCloudConfig(
        enabled: false,
        collectUsageEvents: false,
        collectCrashSignals: false,
        sampleRatePercent: 1,
      ),
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
