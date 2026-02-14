import 'dart:convert';

import 'package:backlight_brightness_ble_controller/settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract class AppSettingsStorage {
  Future<AppSettings> read();
  Future<void> write(AppSettings settings);
  Future<void> clear();
}

class SharedPreferencesAppSettingsStorage implements AppSettingsStorage {
  static const String _settingsKey = 'app_settings_v1';

  @override
  Future<AppSettings> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_settingsKey);
    if (raw == null || raw.trim().isEmpty) {
      return const AppSettings();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return AppSettings.fromMap(decoded);
      }
    } catch (_) {
      // Ignore malformed settings and fallback to defaults.
    }
    return const AppSettings();
  }

  @override
  Future<void> write(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_settingsKey, jsonEncode(settings.toMap()));
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_settingsKey);
  }
}
