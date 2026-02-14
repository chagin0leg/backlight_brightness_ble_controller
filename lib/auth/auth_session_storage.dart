import 'dart:convert';

import 'package:backlight_brightness_ble_controller/auth/auth_session.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract class AuthSessionStorage {
  Future<AuthSession?> read();
  Future<void> write(AuthSession session);
  Future<void> clear();
}

class ResilientAuthSessionStorage implements AuthSessionStorage {
  ResilientAuthSessionStorage({
    FlutterSecureStorage? secureStorage,
    SharedPreferencesAuthSessionStorage? fallbackStorage,
  })  : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
        _fallbackStorage = fallbackStorage ?? SharedPreferencesAuthSessionStorage();

  static const String _sessionKey = 'auth_session_v1';

  final FlutterSecureStorage _secureStorage;
  final SharedPreferencesAuthSessionStorage _fallbackStorage;

  @override
  Future<AuthSession?> read() async {
    final secureRaw = await _tryReadSecureRaw();
    final secureSession = _decodeSession(secureRaw);
    if (secureSession != null) {
      return secureSession;
    }

    final fallbackSession = await _fallbackStorage.read();
    if (fallbackSession == null) {
      return null;
    }
    final migrated = await _tryWriteSecureRaw(jsonEncode(fallbackSession.toMap()));
    if (migrated) {
      await _fallbackStorage.clear();
    }
    return fallbackSession;
  }

  @override
  Future<void> write(AuthSession session) async {
    final raw = jsonEncode(session.toMap());
    final writeSecureOk = await _tryWriteSecureRaw(raw);
    if (writeSecureOk) {
      await _fallbackStorage.clear();
      return;
    }
    await _fallbackStorage.write(session);
  }

  @override
  Future<void> clear() async {
    await _tryDeleteSecureRaw();
    await _fallbackStorage.clear();
  }

  Future<String?> _tryReadSecureRaw() async {
    try {
      return await _secureStorage.read(key: _sessionKey);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _tryWriteSecureRaw(String raw) async {
    try {
      await _secureStorage.write(key: _sessionKey, value: raw);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _tryDeleteSecureRaw() async {
    try {
      await _secureStorage.delete(key: _sessionKey);
    } catch (_) {
      // Ignore storage backend errors.
    }
  }

  AuthSession? _decodeSession(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return AuthSession.fromMap(decoded);
      }
    } catch (_) {
      // Ignore malformed session payload.
    }
    return null;
  }
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
