import 'package:backlight_brightness_ble_controller/settings/app_settings.dart';
import 'package:backlight_brightness_ble_controller/settings/app_settings_storage.dart';
import 'package:get/get.dart';

class AppSettingsController extends GetxController {
  AppSettingsController({AppSettingsStorage? storage})
      : _storage = storage ?? SharedPreferencesAppSettingsStorage();

  final AppSettingsStorage _storage;

  final Rx<AppSettings> settings = const AppSettings().obs;
  final RxBool isLoaded = false.obs;
  final RxString status = 'Settings not loaded'.obs;

  Future<void> load() async {
    final loaded = await _storage.read();
    settings.value = loaded;
    isLoaded.value = true;
    status.value = 'Settings loaded';
  }

  Future<void> setBrightnessPollIntervalSeconds(int seconds) async {
    await _save(settings.value.copyWith(brightnessPollIntervalSeconds: seconds));
  }

  Future<void> setSyncEnabled(bool enabled) async {
    await _save(settings.value.copyWith(syncEnabled: enabled));
  }

  Future<void> setOutputBrightnessRange({required int min, required int max}) async {
    await _save(
      settings.value.copyWith(
        minOutputBrightnessPercent: min,
        maxOutputBrightnessPercent: max,
      ),
    );
  }

  Future<void> setDiagnosticsUploadConsent(bool enabled) async {
    await _save(settings.value.copyWith(diagnosticsUploadConsent: enabled));
  }

  Future<void> setAdsConsentGranted(bool enabled) async {
    await _save(settings.value.copyWith(adsConsentGranted: enabled));
  }

  Future<void> setAnonymousAnalyticsEnabled(bool enabled) async {
    await _save(settings.value.copyWith(anonymousAnalyticsEnabled: enabled));
  }

  Future<void> rememberPreferredDevice({
    required String address,
    required String name,
  }) async {
    final normalizedAddress = address.trim();
    if (normalizedAddress.isEmpty) {
      return;
    }
    await _save(
      settings.value.copyWith(
        preferredDeviceAddress: normalizedAddress,
        preferredDeviceName: name.trim().isEmpty ? address : name.trim(),
      ),
    );
  }

  Future<void> clearPreferredDevice() async {
    await _save(
      settings.value.copyWith(
        clearPreferredDeviceAddress: true,
        clearPreferredDeviceName: true,
      ),
    );
  }

  bool shouldConsiderDeviceAddress(String address) {
    final preferred = settings.value.preferredDeviceAddress;
    if (preferred == null || preferred.trim().isEmpty) {
      return true;
    }
    return preferred.toLowerCase() == address.trim().toLowerCase();
  }

  int? transformBrightness(int inputPercent) {
    return settings.value.transformBrightness(inputPercent);
  }

  Future<void> resetToDefaults() async {
    await _save(const AppSettings());
  }

  Future<void> _save(AppSettings newValue) async {
    settings.value = newValue;
    status.value = 'Settings saved';
    await _storage.write(newValue);
  }
}
