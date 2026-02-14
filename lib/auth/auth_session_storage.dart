import 'dart:convert';

import 'package:backlight_brightness_ble_controller/auth/auth_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract class AuthSessionStorage {
  Future<AuthSession?> read();
  Future<void> write(AuthSession session);
  Future<void> clear();
}

class SharedPreferencesAuthSessionStorage implements AuthSessionStorage {
  static const String _sessionKey = 'auth_session_v1';

  @override
  Future<AuthSession?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sessionKey);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return AuthSession.fromMap(decoded);
      }
    } catch (_) {
      // Ignore malformed persisted data.
    }
    return null;
  }

  @override
  Future<void> write(AuthSession session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sessionKey, jsonEncode(session.toMap()));
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionKey);
  }
}
