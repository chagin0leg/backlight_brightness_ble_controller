import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'package:backlight_brightness_ble_controller/cloud/app_cloud_config.dart';

class AdController extends GetxController {
  final RxBool enabled = false.obs;
  final RxString status = 'Ads disabled'.obs;
  final Rxn<BannerAd> bannerAd = Rxn<BannerAd>();
  final RxBool bannerVisible = false.obs;

  AdsCloudConfig? _config;
  bool _isLoading = false;

  Future<void> configure(AdsCloudConfig config) async {
    _config = config;
    enabled.value = config.enabled;
    bannerVisible.value = false;
    _disposeBanner();

    if (!config.enabled) {
      status.value = 'Ads disabled by configuration';
      return;
    }

    if (config.provider != AdsProviderKind.admob) {
      status.value = 'Configured ads provider is not implemented yet';
      return;
    }

    if (!_supportsMobileAdsRuntime()) {
      status.value =
          'AdMob is configured, but this platform does not support runtime ads';
      return;
    }

    final unitId = (config.bannerUnitId ?? '').trim();
    if (unitId.isEmpty) {
      status.value = 'AdMob banner unit id is not configured';
      return;
    }

    try {
      await MobileAds.instance.initialize();
      await _loadBanner(unitId);
    } catch (error) {
      status.value = 'Failed to initialize ads: $error';
    }
  }

  Future<void> reloadBanner() async {
    final config = _config;
    if (config == null) {
      return;
    }
    await configure(config);
  }

  bool _supportsMobileAdsRuntime() {
    if (kIsWeb) {
      return false;
    }
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  Future<void> _loadBanner(String unitId) async {
    if (_isLoading) {
      return;
    }
    _isLoading = true;

    final config = _config;
    final ad = BannerAd(
      adUnitId: unitId,
      request: _buildAdRequest(config?.nonPersonalizedOnly ?? true),
      size: AdSize.banner,
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          status.value = 'Banner ad loaded';
          bannerVisible.value = true;
        },
        onAdFailedToLoad: (ad, error) {
          status.value = 'Banner failed: ${error.code} ${error.message}';
          bannerVisible.value = false;
          ad.dispose();
        },
      ),
    );

    bannerAd.value = ad;
    ad.load();
    _isLoading = false;
  }

  void _disposeBanner() {
    bannerVisible.value = false;
    bannerAd.value?.dispose();
    bannerAd.value = null;
  }

  @override
  void onClose() {
    _disposeBanner();
    super.onClose();
  }
}

AdRequest _buildAdRequest(bool nonPersonalizedAds) {
  try {
    final dynamic request = Function.apply(
      AdRequest.new,
      const <Object>[],
      <Symbol, Object>{
        #nonPersonalizedAds: nonPersonalizedAds,
      },
    );
    if (request is AdRequest) {
      return request;
    }
  } catch (_) {
    // Ignore and fallback.
  }
  return AdRequest();
}
