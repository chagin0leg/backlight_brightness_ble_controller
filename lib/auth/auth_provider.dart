enum AuthProviderType {
  google,
  microsoft,
  yandex,
  telegram,
  github,
  apple,
  unknown,
}

AuthProviderType authProviderTypeFromString(String rawValue) {
  final normalized = rawValue.trim().toLowerCase();
  for (final provider in AuthProviderType.values) {
    if (provider.name.toLowerCase() == normalized) {
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
    case AuthProviderType.github:
      return 'GitHub';
    case AuthProviderType.apple:
      return 'Apple';
    case AuthProviderType.unknown:
      return 'Unknown';
  }
}
