enum AuthProviderType {
  google,
  microsoft,
  yandex,
  telegram,
  facebook,
  github,
  apple,
  vk,
  discord,
  steam,
  reddit,
  xTwitter,
  emailMagicLink,
  phoneOtp,
  passkey,
  anonymousGuest,
  unknown,
}

AuthProviderType authProviderTypeFromString(String rawValue) {
  final normalized = _normalizeProviderKey(rawValue);
  const aliases = <String, AuthProviderType>{
    'emailmagiclink': AuthProviderType.emailMagicLink,
    'magiclink': AuthProviderType.emailMagicLink,
    'emaillink': AuthProviderType.emailMagicLink,
    'phoneotp': AuthProviderType.phoneOtp,
    'otp': AuthProviderType.phoneOtp,
    'smsotp': AuthProviderType.phoneOtp,
    'webauthn': AuthProviderType.passkey,
    'passkey': AuthProviderType.passkey,
    'guest': AuthProviderType.anonymousGuest,
    'anonymous': AuthProviderType.anonymousGuest,
    'anon': AuthProviderType.anonymousGuest,
    'x': AuthProviderType.xTwitter,
    'twitter': AuthProviderType.xTwitter,
  };
  if (aliases.containsKey(normalized)) {
    return aliases[normalized]!;
  }
  for (final provider in AuthProviderType.values) {
    if (_normalizeProviderKey(provider.name) == normalized) {
      return provider;
    }
  }
  return AuthProviderType.unknown;
}

String authProviderDisplayName(AuthProviderType provider) {
  switch (provider) {
    case AuthProviderType.google:
      return 'Google';
    case AuthProviderType.microsoft:
      return 'Microsoft';
    case AuthProviderType.yandex:
      return 'Yandex';
    case AuthProviderType.telegram:
      return 'Telegram';
    case AuthProviderType.facebook:
      return 'Facebook';
    case AuthProviderType.github:
      return 'GitHub';
    case AuthProviderType.apple:
      return 'Apple';
    case AuthProviderType.vk:
      return 'VK';
    case AuthProviderType.discord:
      return 'Discord';
    case AuthProviderType.steam:
      return 'Steam';
    case AuthProviderType.reddit:
      return 'Reddit';
    case AuthProviderType.xTwitter:
      return 'X/Twitter';
    case AuthProviderType.emailMagicLink:
      return 'Email magic link';
    case AuthProviderType.phoneOtp:
      return 'Phone OTP';
    case AuthProviderType.passkey:
      return 'Passkey';
    case AuthProviderType.anonymousGuest:
      return 'Guest mode';
    case AuthProviderType.unknown:
      return 'Unknown';
  }
}

String _normalizeProviderKey(String rawValue) {
  final buffer = StringBuffer();
  for (final codeUnit in rawValue.trim().toLowerCase().codeUnits) {
    final isLetter = codeUnit >= 97 && codeUnit <= 122;
    final isDigit = codeUnit >= 48 && codeUnit <= 57;
    if (isLetter || isDigit) {
      buffer.writeCharCode(codeUnit);
    }
  }
  return buffer.toString();
}
