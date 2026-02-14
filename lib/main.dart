import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';

import 'package:backlight_brightness_ble_controller/ads/ad_controller.dart';
import 'package:backlight_brightness_ble_controller/auth/auth_controller.dart';
import 'package:backlight_brightness_ble_controller/auth/auth_provider.dart';
import 'package:backlight_brightness_ble_controller/cloud/app_cloud_config.dart';
import 'package:backlight_brightness_ble_controller/cloud/unknown_device_report_uploader.dart';
import 'package:backlight_brightness_ble_controller/device_profile.dart';
import 'package:backlight_brightness_ble_controller/device_profile_registry.dart';
import 'package:backlight_brightness_ble_controller/settings/app_settings.dart';
import 'package:backlight_brightness_ble_controller/settings/app_settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:backlight_brightness_ble_controller/brightness.dart';
import 'package:get/get.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:backlight_brightness_ble_controller/unknown_device_diagnostics.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:win_ble/win_ble.dart';
import 'package:win_ble/win_file.dart';

BleDevice? device;
final RxString status = RxString('Disconnected');
final RxString cloudStatus = RxString('Cloud config not loaded');
final RxString profileStatus = RxString('Profile: not selected');
final RxString diagnosticsStatus = RxString('');
final RxString authFlowStatus = RxString('');
final RxString reconnectStatus = RxString('');
final RxList<String> services = <String>[].obs;
final DeviceProfileRegistry deviceProfileRegistry = DeviceProfileRegistry();
final UnknownDeviceDiagnosticsCollector diagnosticsCollector =
    UnknownDeviceDiagnosticsCollector();
final Map<String, DateTime> unknownDeviceReportRateLimit = <String, DateTime>{};
AppCloudConfig appCloudConfig = AppCloudConfig.disabled();
DeviceProfile? activeProfile;
int? lastSyncedBrightness;
AppSettingsController? appSettingsControllerRef;

void main() {
  runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: MyApp()));
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription? scanStream;
  StreamSubscription? connectionStream;
  StreamSubscription? bleStateStream;
  Worker? brightnessWorker;
  Worker? settingsWorker;
  Timer? reconnectTimer;
  int reconnectAttempt = 0;
  BleState bleState = BleState.Unknown;
  final BrightnessController brightnessController =
      Get.put(BrightnessController());
  final AuthController authController = Get.put(AuthController());
  final AdController adController = Get.put(AdController());
  final AppSettingsController settingsController =
      Get.put(AppSettingsController());

  Future<void> initialize() async {
    status.value = 'Loading cloud configuration';
    appCloudConfig = await AppCloudConfigLoader.load();
    await settingsController.load();
    appSettingsControllerRef = settingsController;
    brightnessController.setPollingIntervalSeconds(
      settingsController.settings.value.brightnessPollIntervalSeconds,
    );
    await authController.configure(appCloudConfig);
    await adController.configure(appCloudConfig.ads);
    _applyDiagnosticsCloudConfig(appCloudConfig);
    cloudStatus.value = 'Cloud backend: ${_backendLabel(appCloudConfig.backendKind)}';

    status.value = 'Loading profiles';
    await deviceProfileRegistry.loadDefaultProfiles();
    final remoteManifestUrl = appCloudConfig.profileRegistry.remoteManifestUrl;
    if (remoteManifestUrl != null && remoteManifestUrl.isNotEmpty) {
      status.value = 'Syncing remote profile registry';
      final remoteLoaded =
          await deviceProfileRegistry.loadFromRemoteManifest(
        remoteManifestUrl,
        signedManifestRequired:
            appCloudConfig.profileRegistry.signedManifestRequired,
        manifestPublicKeyBase64:
            appCloudConfig.profileRegistry.manifestPublicKeyBase64,
      );
      if (!remoteLoaded) {
        diagnosticsStatus.value =
            'Remote profile sync failed. Using local profile assets.';
      }
    }
    status.value = 'Initializing BLE';
    await WinBle.initialize(serverPath: await WinServer.path, enableLog: true);
    status.value = settingsController.settings.value.hasPreferredDevice
        ? 'Scanning for preferred device'
        : 'Scanning';
    _scheduleReconnect(reason: 'startup', immediate: true);
  }

  void _applyDiagnosticsCloudConfig(AppCloudConfig config) {
    if (config.diagnostics.canUpload) {
      diagnosticsCollector.uploader = HttpUnknownDeviceReportUploader(
        endpointUrl: config.diagnostics.uploadUrl!,
        apiKeyHeader: config.diagnostics.apiKeyHeader,
        apiKeyValue: config.diagnostics.apiKeyValue,
        timeout: Duration(seconds: config.diagnostics.timeoutSeconds),
      );
      diagnosticsStatus.value =
          'Diagnostics uploader configured. Enable consent to upload.';
      return;
    }
    diagnosticsCollector.uploader = null;
    diagnosticsStatus.value =
        'Diagnostics upload endpoint is not configured. Local snapshots only.';
  }

  String _backendLabel(CloudBackendKind kind) {
    switch (kind) {
      case CloudBackendKind.firebase:
        return 'Firebase';
      case CloudBackendKind.supabase:
        return 'Supabase';
      case CloudBackendKind.appwrite:
        return 'Appwrite';
      case CloudBackendKind.customWebhook:
        return 'Custom webhook';
      case CloudBackendKind.disabled:
        return 'Disabled';
    }
  }

  Future<void> _startAuthFlow(AuthProviderType provider) async {
    authFlowStatus.value = 'Starting sign-in...';
    final result = await authController.beginSignIn(provider);
    final authUrl = result.externalAuthUrl ??
        authController.pendingExternalAuthUrl.value;
    if (!result.ok) {
      authFlowStatus.value = result.message;
      return;
    }

    if (authUrl == null || authUrl.isEmpty) {
      authFlowStatus.value = result.message;
      return;
    }

    final launched = await _openExternalAuthUrl(authUrl);
    authFlowStatus.value = launched
        ? '${result.message}. Browser has been opened.'
        : '${result.message}. Failed to open browser automatically, URL copied.';
  }

  Uri? _normalizeExternalAuthUri(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final parsed = Uri.tryParse(trimmed);
    if (parsed == null) {
      return null;
    }
    if (parsed.hasScheme) {
      return parsed;
    }
    if (trimmed.startsWith('/')) {
      final base = appCloudConfig.auth.deviceStartUrl;
      final baseUri = base == null ? null : Uri.tryParse(base);
      if (baseUri != null) {
        return baseUri.resolveUri(parsed);
      }
    }
    if (trimmed.startsWith('//')) {
      return Uri.tryParse('https:$trimmed');
    }
    return Uri.tryParse('https://$trimmed');
  }

  Future<bool> _openExternalAuthUrl(String rawUrl) async {
    final uri = _normalizeExternalAuthUri(rawUrl);
    if (uri == null) {
      await Clipboard.setData(ClipboardData(text: rawUrl));
      return false;
    }

    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (launched) {
        return true;
      }
    } catch (_) {
      // Ignore and fallback to clipboard.
    }

    await Clipboard.setData(ClipboardData(text: uri.toString()));
    return false;
  }

  Future<void> _reopenPendingAuthUrl() async {
    final url = authController.pendingExternalAuthUrl.value;
    if (url == null || url.isEmpty) {
      authFlowStatus.value = 'No active auth URL to reopen.';
      return;
    }
    final launched = await _openExternalAuthUrl(url);
    authFlowStatus.value = launched
        ? 'Auth URL reopened in browser.'
        : 'Could not reopen browser. URL copied to clipboard.';
  }

  void _cancelPendingAuthFlow() {
    authController.cancelPendingSignIn();
    authFlowStatus.value = 'Pending sign-in was cancelled.';
  }

  void _startScanBurst({int seconds = 10}) {
    if (device != null) {
      return;
    }
    reconnectStatus.value = 'Scan in progress';
    WinBle.startScanning();
    Future.delayed(Duration(seconds: seconds), () {
      if (device == null) {
        WinBle.stopScanning();
        _scheduleReconnect(reason: 'scan timeout');
      }
    });
  }

  int _nextReconnectDelaySeconds(int attempt) {
    const delays = <int>[0, 2, 5, 10, 20, 30, 45, 60];
    return delays[attempt.clamp(0, delays.length - 1)];
  }

  void _resetReconnectBackoff() {
    reconnectAttempt = 0;
    reconnectTimer?.cancel();
    reconnectTimer = null;
    reconnectStatus.value = 'Connected';
  }

  void _scheduleReconnect({required String reason, bool immediate = false}) {
    if (device != null) {
      return;
    }
    reconnectTimer?.cancel();
    if (!immediate) {
      reconnectAttempt += 1;
    } else {
      reconnectAttempt = 0;
    }
    final delaySeconds =
        immediate ? 0 : _nextReconnectDelaySeconds(reconnectAttempt);
    reconnectStatus.value = delaySeconds == 0
        ? 'Reconnect attempt #${reconnectAttempt + 1} (${reason})'
        : 'Reconnect in ${delaySeconds}s (#${reconnectAttempt + 1}, $reason)';

    reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      reconnectTimer = null;
      if (device == null) {
        _startScanBurst(seconds: 12);
      }
    });
  }

  Widget _buildSectionCard({
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(icon, size: 18),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildCloudSection() {
    return _buildSectionCard(
      icon: Icons.cloud_outlined,
      title: 'Cloud status',
      children: <Widget>[
        Text(cloudStatus.value, textAlign: TextAlign.center),
      ],
    );
  }

  Widget _buildAuthSection() {
    final widgets = <Widget>[
      Text(authController.status.value, textAlign: TextAlign.center),
    ];

    if (authController.session.value != null) {
      widgets.addAll(<Widget>[
        const SizedBox(height: 8),
        Text(
          'Signed in as: ${authController.session.value!.displayName}',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          'Session valid until: ${authController.session.value!.expiresAtUtc.toLocal()}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => authController.signOut(reason: 'Signed out by user'),
          child: const Text('Sign out'),
        ),
      ]);
    } else if (!authController.isSignInPending.value) {
      widgets.addAll(<Widget>[
        const SizedBox(height: 8),
        const Text(
          'Onboarding: 1) Ensure local server is reachable, '
          '2) press Google sign-in, 3) confirm in browser.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12),
        ),
      ]);
    }

    if (authController.options.isNotEmpty) {
      widgets.addAll(<Widget>[
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: authController.options
              .map(
                (option) => OutlinedButton(
                  onPressed: option.enabled
                      ? () => _startAuthFlow(option.provider)
                      : null,
                  child: Text(option.displayName),
                ),
              )
              .toList(growable: false),
        ),
      ]);
    }

    if (authController.isSignInPending.value) {
      widgets.addAll(<Widget>[
        const SizedBox(height: 8),
        const SizedBox(
          width: 220,
          child: LinearProgressIndicator(minHeight: 3),
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            OutlinedButton(
              onPressed: _reopenPendingAuthUrl,
              child: const Text('Open auth URL again'),
            ),
            OutlinedButton(
              onPressed: _cancelPendingAuthFlow,
              child: const Text('Cancel sign-in'),
            ),
          ],
        ),
      ]);
      if (authController.pendingSessionId.value != null) {
        widgets.addAll(<Widget>[
          const SizedBox(height: 6),
          Text(
            'Pending session: ${authController.pendingSessionId.value}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11),
          ),
        ]);
      }
    }

    if (authController.pollErrorCount.value > 0) {
      widgets.addAll(<Widget>[
        const SizedBox(height: 6),
        Text(
          'Auth polling errors: ${authController.pollErrorCount.value}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
      ]);
    }

    if (authController.sessionWarning.value != null) {
      widgets.addAll(<Widget>[
        const SizedBox(height: 6),
        Text(
          authController.sessionWarning.value!,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
      ]);
    }

    if (authFlowStatus.value.isNotEmpty) {
      widgets.addAll(<Widget>[
        const SizedBox(height: 6),
        Text(
          authFlowStatus.value,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
      ]);
    }

    return _buildSectionCard(
      icon: Icons.lock_outline,
      title: 'Authentication',
      children: widgets,
    );
  }

  Widget _buildDeviceSection() {
    final effectiveBrightness = settingsController.transformBrightness(
      brightnessController.value.value ?? 0,
    );

    return _buildSectionCard(
      icon: Icons.bluetooth_audio_outlined,
      title: 'Device sync',
      children: <Widget>[
        Text(status.value, textAlign: TextAlign.center),
        if (reconnectStatus.value.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            reconnectStatus.value,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
          ),
        ],
        const SizedBox(height: 8),
        Text(profileStatus.value, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          'Screen brightness: ${brightnessController.value.value ?? '-'}',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          'Brightness source: ${brightnessController.providerLabel.value}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 6),
        Text(
          'Output brightness target: ${effectiveBrightness ?? '-'} '
          '(range ${settingsController.settings.value.minOutputBrightnessPercent}'
          '-${settingsController.settings.value.maxOutputBrightnessPercent})',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildSettingsSection() {
    final current = settingsController.settings.value;
    final hasPreferred = current.hasPreferredDevice;

    return _buildSectionCard(
      icon: Icons.settings_outlined,
      title: 'Settings',
      children: <Widget>[
        Text(settingsController.status.value, textAlign: TextAlign.center),
        const SizedBox(height: 4),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Enable brightness sync'),
          value: current.syncEnabled,
          onChanged: (value) => settingsController.setSyncEnabled(value),
        ),
        const SizedBox(height: 4),
        Text(
          'Brightness poll interval: ${current.brightnessPollIntervalSeconds}s',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
        Slider(
          min: 1,
          max: 10,
          divisions: 9,
          label: '${current.brightnessPollIntervalSeconds}s',
          value: current.brightnessPollIntervalSeconds.toDouble(),
          onChanged: (value) => settingsController.setBrightnessPollIntervalSeconds(
            value.round(),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'Min output brightness: ${current.minOutputBrightnessPercent}%',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
        Slider(
          min: 0,
          max: 100,
          divisions: 100,
          label: '${current.minOutputBrightnessPercent}%',
          value: current.minOutputBrightnessPercent.toDouble(),
          onChanged: (value) => settingsController.setOutputBrightnessRange(
            min: value.round(),
            max: current.maxOutputBrightnessPercent,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'Max output brightness: ${current.maxOutputBrightnessPercent}%',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
        Slider(
          min: 0,
          max: 100,
          divisions: 100,
          label: '${current.maxOutputBrightnessPercent}%',
          value: current.maxOutputBrightnessPercent.toDouble(),
          onChanged: (value) => settingsController.setOutputBrightnessRange(
            min: current.minOutputBrightnessPercent,
            max: value.round(),
          ),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Enable anonymous analytics'),
          subtitle: const Text(
            'Anonymous-only usage and crash counters',
            style: TextStyle(fontSize: 12),
          ),
          value: current.anonymousAnalyticsEnabled,
          onChanged: (value) => settingsController.setAnonymousAnalyticsEnabled(value),
        ),
        const SizedBox(height: 4),
        Text(
          hasPreferred
              ? 'Preferred device: ${current.preferredDeviceName ?? current.preferredDeviceAddress}'
              : 'Preferred device: not selected yet',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
        if (hasPreferred) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            current.preferredDeviceAddress ?? '',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11),
          ),
          const SizedBox(height: 6),
          OutlinedButton(
            onPressed: settingsController.clearPreferredDevice,
            child: const Text('Forget preferred device'),
          ),
        ],
      ],
    );
  }

  Widget _buildDiagnosticsSection() {
    final children = <Widget>[
      CheckboxListTile(
        value: settingsController.settings.value.diagnosticsUploadConsent,
        onChanged: (value) =>
            settingsController.setDiagnosticsUploadConsent(value ?? false),
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text(
          'Share unknown device diagnostics (opt-in)',
          style: TextStyle(fontSize: 12),
        ),
      ),
    ];
    if (diagnosticsStatus.value.isNotEmpty) {
      children.add(
        Text(
          diagnosticsStatus.value,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
      );
    }

    return _buildSectionCard(
      icon: Icons.bug_report_outlined,
      title: 'Diagnostics',
      children: children,
    );
  }

  Widget _buildAdSection() {
    final adStatus = adController.status.value;
    final banner = adController.bannerAd.value;
    final visible = adController.bannerVisible.value && banner != null;

    final children = <Widget>[
      Text(
        adStatus,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12),
      ),
    ];

    if (visible) {
      children.addAll(<Widget>[
        const SizedBox(height: 8),
        Center(
          child: SizedBox(
            width: banner.size.width.toDouble(),
            height: banner.size.height.toDouble(),
            child: AdWidget(ad: banner),
          ),
        ),
      ]);
    } else if (adController.enabled.value) {
      children.addAll(<Widget>[
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: adController.reloadBanner,
          child: const Text('Retry ad load'),
        ),
      ]);
    }

    return _buildSectionCard(
      icon: Icons.campaign_outlined,
      title: 'Monetization',
      children: children,
    );
  }

  @override
  void initState() {
    super.initState();

    initialize();

    brightnessWorker = ever<int?>(
      brightnessController.value,
      (brightness) => syncBrightnessWithDevice(brightness),
    );
    settingsWorker = ever<AppSettings>(
      settingsController.settings,
      (settings) =>
          brightnessController.setPollingIntervalSeconds(settings.brightnessPollIntervalSeconds),
    );

    connectionStream = WinBle.connectionStream.listen((event) {
      log('Connection Event : $event');
      if (device != null &&
          event["device"] == device!.address &&
          event["connected"] == false) {
        status.value = settingsController.settings.value.hasPreferredDevice
            ? 'Disconnected. Waiting for preferred device'
            : 'Disconnected';
        profileStatus.value = 'Profile: not selected';
        device = null;
        activeProfile = null;
        lastSyncedBrightness = null;
        _scheduleReconnect(reason: 'device disconnected');
      }
    });

    scanStream = WinBle.scanStream.listen((event) async {
      if (await connectionProcess(event)) {
        WinBle.stopScanning();
        _resetReconnectBackoff();
        unawaited(
          adController.markProductValueReached(reason: 'first device connection'),
        );
      }
    });

    bleStateStream =
        WinBle.bleState.listen((BleState state) => bleState = state);

    reconnectStatus.value = 'Waiting for BLE initialization';
  }

  @override
  void dispose() {
    WinBle.stopScanning();
    reconnectTimer?.cancel();
    brightnessWorker?.dispose();
    settingsWorker?.dispose();
    scanStream?.cancel();
    connectionStream?.cancel();
    bleStateStream?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Obx(
            () => SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _buildCloudSection(),
                    _buildAuthSection(),
                    _buildDeviceSection(),
                    _buildSettingsSection(),
                    _buildDiagnosticsSection(),
                    _buildAdSection(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<bool> connectionProcess(BleDevice event) async {
  if (device == null) {
    final settingsController = appSettingsControllerRef;
    final isPreferredCandidate =
        settingsController?.shouldConsiderDeviceAddress(event.address) ?? true;
    if (settingsController != null &&
        !isPreferredCandidate) {
      return false;
    }
    final hasPreferred = settingsController?.settings.value.hasPreferredDevice ?? false;
    if (event.name.isEmpty && !hasPreferred) {
      return false;
    }
    final candidateName = event.name.isEmpty
        ? (settingsController?.settings.value.preferredDeviceName ?? event.address)
        : event.name;

    device = event;
    status.value = 'Candidate found: $candidateName';
    profileStatus.value = 'Profile: matching';
    diagnosticsStatus.value = '';

    await Future.delayed(const Duration(milliseconds: 500));
    if (!await connect(device!.address)) {
      status.value = 'Connection failed';
      device = null;
      return false;
    }

    status.value = 'Connected';
    await Future.delayed(const Duration(milliseconds: 500));

    final paired = await WinBle.isPaired(device!.address) ||
        await pair(device!.address);
    if (!paired) {
      await disconnect(device!.address);
      status.value = 'Pairing failed';
      device = null;
      return false;
    }

    status.value = 'Paired';
    services.value = await discoverServices(device!.address);
    final characteristicMap = await discoverAllCharacteristics(
      device!.address,
      services.toList(),
    );
    final characteristics = characteristicMap.values
        .expand((items) => items)
        .map((item) => item.uuid.toLowerCase())
        .toList(growable: false);

    final matchResult = DeviceProfileMatcher.match(
      deviceName: candidateName,
      serviceUuids: services.toList(),
      characteristicUuids: characteristics,
      candidates: deviceProfileRegistry.profiles,
    );

    if (!matchResult.confident || matchResult.profile == null) {
      await captureUnknownDevice(
        event: event,
        services: services.toList(),
        characteristics: characteristics,
        matchResult: matchResult,
      );
      await disconnect(device!.address);
      status.value = 'Unknown device profile';
      device = null;
      activeProfile = null;
      lastSyncedBrightness = null;
      return false;
    }

    activeProfile = matchResult.profile;
    profileStatus.value =
        'Profile: ${activeProfile!.label} (${(matchResult.score * 100).round()}%)';

    final brightnessCommand = activeProfile!.brightnessCommand;
    if (brightnessCommand == null) {
      status.value = 'Profile has no brightness command';
      return true;
    }

    final hasService = services.contains(brightnessCommand.serviceUuid);
    final hasCharacteristic =
        characteristics.contains(brightnessCommand.characteristicUuid);
    if (!hasService || !hasCharacteristic) {
      await captureUnknownDevice(
        event: event,
        services: services.toList(),
        characteristics: characteristics,
        matchResult: matchResult,
        errorMessage: 'Profile command endpoint is unavailable on this device',
      );
      await disconnect(device!.address);
      status.value = 'Profile mismatch';
      device = null;
      activeProfile = null;
      lastSyncedBrightness = null;
      return false;
    }

    status.value = 'Device Ready';
    if (settingsController != null) {
      await settingsController.rememberPreferredDevice(
        address: event.address,
        name: candidateName,
      );
    }
    diagnosticsStatus.value = '';
    return true;
  }
  return true;
}

Future<List<String>> discoverServices(String address) async {
  List<String> data = <String>[];
  try {
    data = await WinBle.discoverServices(address);
    log('DiscoverService : $data');
  } catch (e) {
    log('DiscoverServiceError : $e');
  }
  return data;
}

Future<bool> connect(String address) async {
  try {
    await WinBle.connect(address);
    log('Connected');
    return true;
  } catch (e) {
    log('ConnectError : $e');
    return false;
  }
}

Future<bool> pair(String address) async {
  try {
    await WinBle.pair(address);
    log('Paired Successfully');
    return true;
  } catch (e) {
    log('PairError : $e');
    return false;
  }
}

Future<bool> unPair(String address) async {
  try {
    await WinBle.unPair(address);
    log('UnPaired Successfully');
    return true;
  } catch (e) {
    log('UnPairError : $e');
    return false;
  }
}

Future<bool> disconnect(String address) async {
  try {
    if (await WinBle.isPaired(address)) await WinBle.unPair(address);
    if (!await WinBle.isPaired(address)) log('UnPaired Successfully');
    await WinBle.disconnect(address).then((e) => log('Disconnected'));
    return true;
  } catch (e) {
    log(e.toString());
    return false;
  }
}

Future<List<BleCharacteristic>> discoverCharacteristic(
    String address, String serviceID) async {
  List<BleCharacteristic> bleChar = <BleCharacteristic>[];
  try {
    bleChar = await WinBle.discoverCharacteristics(
        address: address, serviceId: serviceID);
    log(bleChar.toString());
    log(bleChar.map((e) => e.toJson()).toString());
  } catch (e) {
    log('DiscoverCharError : $e');
  }
  return bleChar;
}

Future<Map<String, List<BleCharacteristic>>> discoverAllCharacteristics(
  String address,
  List<String> serviceIds,
) async {
  final result = <String, List<BleCharacteristic>>{};
  for (final serviceId in serviceIds) {
    result[serviceId] = await discoverCharacteristic(address, serviceId);
  }
  return result;
}

Future<List<int>> readCharacteristic(
  String address,
  String serviceID,
  String charID,
) async {
  try {
    final List<int> data = await WinBle.read(
        address: address, serviceId: serviceID, characteristicId: charID);
    log(String.fromCharCodes(data));
    return data;
  } catch (e) {
    log('ReadCharError : $e');
    return <int>[];
  }
}

Future<bool> writeCharacteristic(
  String address,
  String serviceID,
  String charID,
  List<int> data,
  bool writeWithResponse,
) async {
  try {
    final payload = Uint8List.fromList(data);
    await WinBle.write(
        address: address,
        service: serviceID,
        characteristic: charID,
        data: payload,
        writeWithResponse: writeWithResponse);
    return true;
  } catch (e) {
    log('writeCharError : $e');
    return false;
  }
}

Future<void> syncBrightnessWithDevice(int? brightnessPercent) async {
  if (brightnessPercent == null) {
    return;
  }
  final settingsController = appSettingsControllerRef;
  final transformedBrightness =
      settingsController?.transformBrightness(brightnessPercent);
  if (settingsController != null && transformedBrightness == null) {
    return;
  }
  final outputBrightness = transformedBrightness ?? brightnessPercent;

  final connectedDevice = device;
  final profile = activeProfile;
  if (connectedDevice == null || profile == null) {
    return;
  }

  final brightnessCommand = profile.brightnessCommand;
  if (brightnessCommand == null) {
    return;
  }

  if (lastSyncedBrightness != null &&
      (outputBrightness - lastSyncedBrightness!).abs() < 2) {
    return;
  }

  final payload = BrightnessCommandEncoder.encodeBrightness(
    profile: profile,
    brightnessPercent: outputBrightness,
  );
  if (payload == null) {
    return;
  }

  final writeOk = await writeCharacteristic(
    connectedDevice.address,
    brightnessCommand.serviceUuid,
    brightnessCommand.characteristicUuid,
    payload,
    brightnessCommand.writeWithResponse,
  );
  if (writeOk) {
    lastSyncedBrightness = outputBrightness;
    status.value = 'Device Ready (brightness synced: $outputBrightness)';
  }
}

Future<void> captureUnknownDevice({
  required BleDevice event,
  required List<String> services,
  required List<String> characteristics,
  required ProfileMatchResult matchResult,
  String? errorMessage,
}) async {
  if (!_shouldSaveUnknownReport(event.address)) {
    diagnosticsStatus.value =
        'Unknown device detected. Diagnostics skipped due to cooldown.';
    return;
  }

  final saveResult = await diagnosticsCollector.saveSnapshot(
    deviceName: event.name,
    deviceAddress: event.address,
    services: services,
    characteristics: characteristics,
    matchScore: matchResult.score,
    matchReasons: matchResult.reasons,
    uploadIfConfigured:
        appSettingsControllerRef?.settings.value.diagnosticsUploadConsent ?? false,
    errorMessage: errorMessage,
  );
  if (saveResult.localPath == null) {
    diagnosticsStatus.value =
        'Unknown device detected. Failed to store diagnostics.';
    return;
  }

  final uploadResult = saveResult.uploadResult;
  if (uploadResult == null) {
    diagnosticsStatus.value =
        'Unknown device diagnostics saved locally: ${saveResult.localPath}';
    return;
  }

  diagnosticsStatus.value = uploadResult.ok
      ? 'Unknown diagnostics uploaded successfully (${uploadResult.statusCode ?? 0}).'
      : 'Diagnostics saved locally (${saveResult.localPath}), upload failed: ${uploadResult.message}';
}

bool _shouldSaveUnknownReport(String deviceAddress) {
  final now = DateTime.now().toUtc();
  final last = unknownDeviceReportRateLimit[deviceAddress];
  if (last != null && now.difference(last) < const Duration(minutes: 5)) {
    return false;
  }
  unknownDeviceReportRateLimit[deviceAddress] = now;
  return true;
}
