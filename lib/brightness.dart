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
  Timer? _timer;

  @override
  void onInit() {
    super.onInit();
    providerLabel.value = _provider.sourceDescription;
    _pollBrightness();
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (timer) => _pollBrightness(),
    );
  }

  Future<void> _pollBrightness() async {
    value.value = await _provider.getBrightness();
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }
}
