import 'package:backlight_brightness_ble_controller/auth/auth_provider.dart';

class AuthSession {
  const AuthSession({
    required this.provider,
    required this.userId,
    required this.displayName,
    required this.issuedAtUtc,
    required this.expiresAtUtc,
  });

  final AuthProviderType provider;
  final String userId;
  final String displayName;
  final DateTime issuedAtUtc;
  final DateTime expiresAtUtc;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAtUtc);

  Duration get timeLeft => expiresAtUtc.difference(DateTime.now().toUtc());

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'provider': provider.name,
      'user_id': userId,
      'display_name': displayName,
      'issued_at_utc': issuedAtUtc.toIso8601String(),
      'expires_at_utc': expiresAtUtc.toIso8601String(),
    };
  }

  factory AuthSession.fromMap(Map<String, dynamic> map) {
    final issuedRaw = map['issued_at_utc']?.toString() ?? '';
    final expiresRaw = map['expires_at_utc']?.toString() ?? '';
    final issuedAt = DateTime.tryParse(issuedRaw)?.toUtc() ??
        DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    final expiresAt = DateTime.tryParse(expiresRaw)?.toUtc() ??
        DateTime.now().toUtc().add(const Duration(minutes: 1));

    return AuthSession(
      provider: authProviderTypeFromString(map['provider']?.toString() ?? ''),
      userId: map['user_id']?.toString() ?? '',
      displayName: map['display_name']?.toString() ?? 'User',
      issuedAtUtc: issuedAt,
      expiresAtUtc: expiresAt,
    );
  }
}
