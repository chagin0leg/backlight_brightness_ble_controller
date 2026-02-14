class AppSettings {
  const AppSettings({
    this.brightnessPollIntervalSeconds = 1,
    this.syncEnabled = true,
    this.minOutputBrightnessPercent = 0,
    this.maxOutputBrightnessPercent = 100,
    this.preferredDeviceAddress,
    this.preferredDeviceName,
    this.diagnosticsUploadConsent = false,
    this.adsConsentGranted = false,
    this.anonymousAnalyticsEnabled = true,
  });

  final int brightnessPollIntervalSeconds;
  final bool syncEnabled;
  final int minOutputBrightnessPercent;
  final int maxOutputBrightnessPercent;
  final String? preferredDeviceAddress;
  final String? preferredDeviceName;
  final bool diagnosticsUploadConsent;
  final bool adsConsentGranted;
  final bool anonymousAnalyticsEnabled;

  factory AppSettings.fromMap(Map<String, dynamic> map) {
    final minOutput = _toInt(map['min_output_brightness_percent'], 0);
    final maxOutput = _toInt(map['max_output_brightness_percent'], 100);
    final normalizedRange = _normalizeRange(minOutput, maxOutput);

    return AppSettings(
      brightnessPollIntervalSeconds:
          _toInt(map['brightness_poll_interval_seconds'], 1).clamp(1, 10).toInt(),
      syncEnabled: _toBool(map['sync_enabled'], true),
      minOutputBrightnessPercent: normalizedRange.$1,
      maxOutputBrightnessPercent: normalizedRange.$2,
      preferredDeviceAddress: _toNullableString(map['preferred_device_address']),
      preferredDeviceName: _toNullableString(map['preferred_device_name']),
      diagnosticsUploadConsent: _toBool(map['diagnostics_upload_consent'], false),
      adsConsentGranted: _toBool(map['ads_consent_granted'], false),
      anonymousAnalyticsEnabled:
          _toBool(map['anonymous_analytics_enabled'], true),
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'brightness_poll_interval_seconds': brightnessPollIntervalSeconds,
      'sync_enabled': syncEnabled,
      'min_output_brightness_percent': minOutputBrightnessPercent,
      'max_output_brightness_percent': maxOutputBrightnessPercent,
      'preferred_device_address': preferredDeviceAddress,
      'preferred_device_name': preferredDeviceName,
      'diagnostics_upload_consent': diagnosticsUploadConsent,
      'ads_consent_granted': adsConsentGranted,
      'anonymous_analytics_enabled': anonymousAnalyticsEnabled,
    };
  }

  AppSettings copyWith({
    int? brightnessPollIntervalSeconds,
    bool? syncEnabled,
    int? minOutputBrightnessPercent,
    int? maxOutputBrightnessPercent,
    String? preferredDeviceAddress,
    bool clearPreferredDeviceAddress = false,
    String? preferredDeviceName,
    bool clearPreferredDeviceName = false,
    bool? diagnosticsUploadConsent,
    bool? adsConsentGranted,
    bool? anonymousAnalyticsEnabled,
  }) {
    final normalizedRange = _normalizeRange(
      minOutputBrightnessPercent ?? this.minOutputBrightnessPercent,
      maxOutputBrightnessPercent ?? this.maxOutputBrightnessPercent,
    );

    return AppSettings(
      brightnessPollIntervalSeconds: (brightnessPollIntervalSeconds ??
              this.brightnessPollIntervalSeconds)
          .clamp(1, 10)
          .toInt(),
      syncEnabled: syncEnabled ?? this.syncEnabled,
      minOutputBrightnessPercent: normalizedRange.$1,
      maxOutputBrightnessPercent: normalizedRange.$2,
      preferredDeviceAddress: clearPreferredDeviceAddress
          ? null
          : (preferredDeviceAddress ?? this.preferredDeviceAddress),
      preferredDeviceName:
          clearPreferredDeviceName ? null : (preferredDeviceName ?? this.preferredDeviceName),
      diagnosticsUploadConsent:
          diagnosticsUploadConsent ?? this.diagnosticsUploadConsent,
      adsConsentGranted: adsConsentGranted ?? this.adsConsentGranted,
      anonymousAnalyticsEnabled:
          anonymousAnalyticsEnabled ?? this.anonymousAnalyticsEnabled,
    );
  }

  int? transformBrightness(int inputPercent) {
    if (!syncEnabled) {
      return null;
    }
    final normalizedInput = inputPercent.clamp(0, 100).toInt();
    return normalizedInput
        .clamp(minOutputBrightnessPercent, maxOutputBrightnessPercent)
        .toInt();
  }

  bool get hasPreferredDevice =>
      preferredDeviceAddress != null &&
      preferredDeviceAddress!.trim().isNotEmpty;

  static (int, int) _normalizeRange(int min, int max) {
    final clampedMin = min.clamp(0, 100).toInt();
    final clampedMax = max.clamp(0, 100).toInt();
    if (clampedMin <= clampedMax) {
      return (clampedMin, clampedMax);
    }
    return (clampedMax, clampedMin);
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

bool _toBool(dynamic rawValue, bool defaultValue) {
  if (rawValue is bool) {
    return rawValue;
  }
  if (rawValue is num) {
    return rawValue != 0;
  }
  if (rawValue is String) {
    final normalized = rawValue.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1' || normalized == 'yes') {
      return true;
    }
    if (normalized == 'false' || normalized == '0' || normalized == 'no') {
      return false;
    }
  }
  return defaultValue;
}

String? _toNullableString(dynamic rawValue) {
  if (rawValue == null) {
    return null;
  }
  final value = rawValue.toString().trim();
  if (value.isEmpty) {
    return null;
  }
  return value;
}
