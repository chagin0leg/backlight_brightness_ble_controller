import 'package:backlight_brightness_ble_controller/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppSettings', () {
    test('normalizes range and interval on fromMap', () {
      final settings = AppSettings.fromMap(<String, dynamic>{
        'brightness_poll_interval_seconds': 99,
        'min_output_brightness_percent': 80,
        'max_output_brightness_percent': 20,
        'sync_enabled': 'true',
      });

      expect(settings.brightnessPollIntervalSeconds, 10);
      expect(settings.minOutputBrightnessPercent, 20);
      expect(settings.maxOutputBrightnessPercent, 80);
      expect(settings.syncEnabled, isTrue);
    });

    test('transformBrightness applies sync and clamps range', () {
      const settings = AppSettings(
        syncEnabled: true,
        minOutputBrightnessPercent: 25,
        maxOutputBrightnessPercent: 75,
      );

      expect(settings.transformBrightness(0), 25);
      expect(settings.transformBrightness(50), 50);
      expect(settings.transformBrightness(100), 75);
    });

    test('transformBrightness returns null when sync disabled', () {
      const settings = AppSettings(syncEnabled: false);
      expect(settings.transformBrightness(50), isNull);
    });

    test('copyWith can clear preferred device fields', () {
      const original = AppSettings(
        preferredDeviceAddress: 'AA:BB',
        preferredDeviceName: 'Device',
      );

      final cleared = original.copyWith(
        clearPreferredDeviceAddress: true,
        clearPreferredDeviceName: true,
      );

      expect(cleared.preferredDeviceAddress, isNull);
      expect(cleared.preferredDeviceName, isNull);
    });
  });
}
