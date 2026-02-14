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
  bool _mobileAdsInitialized = false;
  bool _productValueReached = false;
  String? _bannerUnitId;

  Future<void> configure(AdsCloudConfig config) async {
    _config = config;
    _bannerUnitId = null;
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
    _bannerUnitId = unitId;

    try {
      if (!_mobileAdsInitialized) {
        await MobileAds.instance.initialize();
        _mobileAdsInitialized = true;
      }
      if (_productValueReached) {
        await _loadBanner(unitId);
      } else {
        status.value =
            'Ads are ready but hidden until first successful device connection';
      }
    } catch (error) {
      status.value = 'Failed to initialize ads: $error';
    }
  }

  Future<void> reloadBanner() async {
    final unitId = _bannerUnitId;
    if (unitId == null || unitId.trim().isEmpty) {
      return;
    }
    if (!_productValueReached) {
      status.value =
          'Connect device first to unlock ads (delayed first ad policy)';
      return;
    }
    await _loadBanner(unitId);
  }

  Future<void> markProductValueReached({String reason = 'device connected'}) async {
    if (_productValueReached) {
      return;
    }
    _productValueReached = true;
    final unitId = _bannerUnitId;
    if (unitId == null || unitId.trim().isEmpty) {
      status.value = 'Product value reached, ads stay disabled by config';
      return;
    }
    if (!_mobileAdsInitialized) {
      status.value = 'Ads pending initialization';
      return;
    }
    status.value = 'Product value reached ($reason). Loading banner...';
    await _loadBanner(unitId);
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
    try {
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
    } finally {
      _isLoading = false;
    }
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
