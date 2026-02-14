import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:backlight_brightness_ble_controller/core/brightness/brightness_provider.dart';

class PlatformBrightnessProviderFactory {
  static BrightnessProvider create() {
    if (Platform.isWindows) {
      return WindowsWmiBrightnessProvider();
    }
    if (Platform.isMacOS) {
      return MacOsBrightnessProvider();
    }
    if (Platform.isLinux) {
      return LinuxBrightnessProvider();
    }
    if (Platform.isAndroid) {
      return AndroidBrightnessProvider();
    }
    if (Platform.isIOS) {
      return IosBrightnessProvider();
    }
    return UnsupportedBrightnessProvider(
      platformLabel: Platform.operatingSystem,
      details: 'Unsupported operating system for brightness provider',
    );
  }
}

class WindowsWmiBrightnessProvider implements BrightnessProvider {
  @override
  String get sourceDescription => 'Windows WMI (PowerShell fallback)';

  @override
  Future<int?> getBrightness() async {
    try {
      final process = await Process.start(
        'powershell',
        <String>[
          '(Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightness).CurrentBrightness'
        ],
      );
      final output = await process.stdout.transform(utf8.decoder).join();
      final brightness = int.tryParse(output.trim());
      if (brightness == null) {
        throw const FormatException('Unable to parse monitor brightness');
      }
      return brightness;
    } catch (error) {
      log('Windows brightness provider error: $error');
      return null;
    }
  }
}

class MacOsBrightnessProvider extends UnsupportedBrightnessProvider {
  MacOsBrightnessProvider()
      : super(
          platformLabel: 'macOS',
          details: 'macOS provider will be implemented via native APIs',
        );
}

class LinuxBrightnessProvider extends UnsupportedBrightnessProvider {
  LinuxBrightnessProvider()
      : super(
          platformLabel: 'Linux',
          details: 'Linux provider will use a sysfs/ddcutil fallback chain',
        );
}

class AndroidBrightnessProvider extends UnsupportedBrightnessProvider {
  AndroidBrightnessProvider()
      : super(
          platformLabel: 'Android',
          details: 'Android provider requires platform channel implementation',
        );
}

class IosBrightnessProvider extends UnsupportedBrightnessProvider {
  IosBrightnessProvider()
      : super(
          platformLabel: 'iOS',
          details: 'iOS provider requires platform channel implementation',
        );
}

class UnsupportedBrightnessProvider implements BrightnessProvider {
  UnsupportedBrightnessProvider({
    required this.platformLabel,
    required this.details,
  });

  final String platformLabel;
  final String details;

  @override
  String get sourceDescription => '$platformLabel provider: $details';

  @override
  Future<int?> getBrightness() async {
    log('Brightness provider unavailable: $sourceDescription');
    return null;
  }
}
