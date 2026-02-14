import 'package:backlight_brightness_ble_controller/device_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeviceProfileMatcher', () {
    test('returns confident match for ELK-BLEDOM-like device', () {
      final profile = DeviceProfile.fromMap(<String, dynamic>{
        'id': 'elk-bledom-default',
        'label': 'ELK-BLEDOM',
        'vendor': 'Unknown',
        'capabilities': <String>['power', 'brightness', 'rgb'],
        'fingerprint': <String, dynamic>{
          'name_contains': <String>['ELK-BLEDOM'],
          'service_uuids': <String>['0000fff0-0000-1000-8000-00805f9b34fb'],
          'characteristic_uuids': <String>[
            '0000fff3-0000-1000-8000-00805f9b34fb',
          ],
        },
        'brightness_command': <String, dynamic>{
          'service_uuid': '0000fff0-0000-1000-8000-00805f9b34fb',
          'characteristic_uuid': '0000fff3-0000-1000-8000-00805f9b34fb',
          'base_payload': <int>[126, 4, 1, 128, 255, 0, 0, 239],
          'value_byte_index': 3,
          'min_value': 1,
          'max_value': 255,
          'write_with_response': false,
        },
      });

      final result = DeviceProfileMatcher.match(
        deviceName: 'ELK-BLEDOM-01',
        serviceUuids: const <String>['0000fff0-0000-1000-8000-00805f9b34fb'],
        characteristicUuids: const <String>[
          '0000fff3-0000-1000-8000-00805f9b34fb',
        ],
        candidates: <DeviceProfile>[profile],
      );

      expect(result.profile?.id, 'elk-bledom-default');
      expect(result.confident, isTrue);
      expect(result.score, greaterThanOrEqualTo(0.55));
    });
  });

  group('BrightnessCommandEncoder', () {
    test('maps brightness percent into payload value byte', () {
      final profile = DeviceProfile.fromMap(<String, dynamic>{
        'id': 'sample',
        'label': 'Sample',
        'vendor': 'Test',
        'capabilities': <String>['brightness'],
        'fingerprint': <String, dynamic>{},
        'brightness_command': <String, dynamic>{
          'service_uuid': 'service',
          'characteristic_uuid': 'char',
          'base_payload': <int>[1, 2, 3, 4],
          'value_byte_index': 2,
          'min_value': 10,
          'max_value': 110,
          'write_with_response': false,
        },
      });

      final payloadAt0 = BrightnessCommandEncoder.encodeBrightness(
        profile: profile,
        brightnessPercent: 0,
      );
      final payloadAt100 = BrightnessCommandEncoder.encodeBrightness(
        profile: profile,
        brightnessPercent: 100,
      );
      final payloadAt50 = BrightnessCommandEncoder.encodeBrightness(
        profile: profile,
        brightnessPercent: 50,
      );

      expect(payloadAt0?[2], 10);
      expect(payloadAt100?[2], 110);
      expect(payloadAt50?[2], 60);
    });
  });
}
