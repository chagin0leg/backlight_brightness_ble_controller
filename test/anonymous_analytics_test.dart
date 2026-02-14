import 'package:backlight_brightness_ble_controller/analytics/anonymous_analytics_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeAnalyticsParams', () {
    test('removes sensitive keys and redacts sensitive values', () {
      final sanitized = sanitizeAnalyticsParams(<String, dynamic>{
        'provider': 'google',
        'email': 'test@example.com',
        'phone': '+12345678901',
        'display_name': 'John Doe',
        'status_code': 200,
        'raw_error': 'Network timeout',
        'token': 'secret-token',
      });

      expect(sanitized.containsKey('email'), isFalse);
      expect(sanitized.containsKey('phone'), isFalse);
      expect(sanitized.containsKey('display_name'), isFalse);
      expect(sanitized.containsKey('token'), isFalse);
      expect(sanitized['provider'], 'google');
      expect(sanitized['status_code'], 200);
      expect(sanitized['raw_error'], 'Network timeout');
    });

    test('sanitizes nested collections and drops unsupported values', () {
      final sanitized = sanitizeAnalyticsParams(<String, dynamic>{
        'flags': <dynamic>[1, true, 'ok'],
        'details': <String, dynamic>{'nested': 'value'},
        'long_text': List<String>.filled(150, 'a').join(),
      });

      expect(sanitized['flags'], <dynamic>[1, true, 'ok']);
      expect(sanitized.containsKey('details'), isFalse);
      expect((sanitized['long_text'] as String).endsWith('...'), isTrue);
    });
  });
}
