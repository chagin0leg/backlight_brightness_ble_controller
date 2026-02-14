import 'dart:async';

import 'package:backlight_brightness_ble_controller/core/brightness/brightness_provider.dart';
import 'package:backlight_brightness_ble_controller/core/brightness/platform_brightness_provider.dart';
import 'package:get/get.dart';

class BrightnessController extends GetxController {
  BrightnessController({BrightnessProvider? provider})
      : _provider = provider ?? PlatformBrightnessProviderFactory.create();

  final BrightnessProvider _provider;
  final RxnInt value = RxnInt();
  final RxString providerLabel = ''.obs;
  final RxInt pollIntervalSeconds = 1.obs;
  Timer? _timer;

  @override
  void onInit() {
    super.onInit();
    providerLabel.value = _provider.sourceDescription;
    _pollBrightness();
    _restartPolling();
  }

  Future<void> _pollBrightness() async {
    value.value = await _provider.getBrightness();
  }

  void setPollingIntervalSeconds(int seconds) {
    final normalized = seconds.clamp(1, 10).toInt();
    if (normalized == pollIntervalSeconds.value) {
      return;
    }
    pollIntervalSeconds.value = normalized;
    _restartPolling();
  }

  void _restartPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(seconds: pollIntervalSeconds.value),
      (timer) => _pollBrightness(),
    );
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }
}
