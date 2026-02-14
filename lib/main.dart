import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';

import 'package:backlight_brightness_ble_controller/auth/auth_controller.dart';
import 'package:backlight_brightness_ble_controller/auth/auth_provider.dart';
import 'package:backlight_brightness_ble_controller/cloud/app_cloud_config.dart';
import 'package:backlight_brightness_ble_controller/cloud/unknown_device_report_uploader.dart';
import 'package:backlight_brightness_ble_controller/device_profile.dart';
import 'package:backlight_brightness_ble_controller/device_profile_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:backlight_brightness_ble_controller/brightness.dart';
import 'package:get/get.dart';
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
final RxBool diagnosticsUploadConsent = false.obs;
final RxList<String> services = <String>[].obs;
final DeviceProfileRegistry deviceProfileRegistry = DeviceProfileRegistry();
final UnknownDeviceDiagnosticsCollector diagnosticsCollector =
    UnknownDeviceDiagnosticsCollector();
final Map<String, DateTime> unknownDeviceReportRateLimit = <String, DateTime>{};
AppCloudConfig appCloudConfig = AppCloudConfig.disabled();
DeviceProfile? activeProfile;
int? lastSyncedBrightness;

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
  BleState bleState = BleState.Unknown;
  final BrightnessController brightnessController =
      Get.put(BrightnessController());
  final AuthController authController = Get.put(AuthController());

  Timer? restart;

  Future<void> initialize() async {
    status.value = 'Loading cloud configuration';
    appCloudConfig = await AppCloudConfigLoader.load();
    authController.configure(appCloudConfig);
    _applyDiagnosticsCloudConfig(appCloudConfig);
    cloudStatus.value = 'Cloud backend: ${_backendLabel(appCloudConfig.backendKind)}';

    status.value = 'Loading profiles';
    await deviceProfileRegistry.loadDefaultProfiles();
    final remoteManifestUrl = appCloudConfig.profileRegistry.remoteManifestUrl;
    if (remoteManifestUrl != null && remoteManifestUrl.isNotEmpty) {
      status.value = 'Syncing remote profile registry';
      final remoteLoaded =
          await deviceProfileRegistry.loadFromRemoteManifest(remoteManifestUrl);
      if (!remoteLoaded) {
        diagnosticsStatus.value =
            'Remote profile sync failed. Using local profile assets.';
      }
    }
    status.value = 'Initializing BLE';
    await WinBle.initialize(serverPath: await WinServer.path, enableLog: true);
    status.value = 'Scanning';
    WinBle.startScanning();
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

  @override
  void initState() {
    super.initState();

    initialize();

    brightnessWorker = ever<int?>(
      brightnessController.value,
      (brightness) => syncBrightnessWithDevice(brightness),
    );

    connectionStream = WinBle.connectionStream.listen((event) {
      log('Connection Event : $event');
      if (device != null &&
          event["device"] == device!.address &&
          event["connected"] == false) {
        status.value = 'Disconnected';
        profileStatus.value = 'Profile: not selected';
        device = null;
        activeProfile = null;
        lastSyncedBrightness = null;
      }
    });

    scanStream = WinBle.scanStream.listen((event) async {
      if (await connectionProcess(event)) WinBle.stopScanning();
    });

    bleStateStream =
        WinBle.bleState.listen((BleState state) => bleState = state);

    restart = Timer.periodic(const Duration(seconds: 15), (timer) {
      if (device == null) {
        WinBle.startScanning();
        Future.delayed(const Duration(seconds: 10), () => WinBle.stopScanning());
      }
    });
  }

  @override
  void dispose() {
    WinBle.stopScanning();
    restart?.cancel();
    brightnessWorker?.dispose();
    scanStream?.cancel();
    connectionStream?.cancel();
    bleStateStream?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Obx(
          () => Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(status.value, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(cloudStatus.value, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(authController.status.value, textAlign: TextAlign.center),
                if (authController.session.value != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    'Signed in as: ${authController.session.value!.displayName}',
                    textAlign: TextAlign.center,
                  ),
                ],
                if (authController.options.isNotEmpty) ...<Widget>[
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
                ],
                if (authController.isSignInPending.value) ...<Widget>[
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
                ],
                if (authController.pollErrorCount.value > 0) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    'Auth polling errors: ${authController.pollErrorCount.value}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
                if (authFlowStatus.value.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    authFlowStatus.value,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: diagnosticsUploadConsent.value,
                  onChanged: (value) =>
                      diagnosticsUploadConsent.value = value ?? false,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    'Share unknown device diagnostics (opt-in)',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(height: 8),
                Text(profileStatus.value, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  'Screen brightness: ${brightnessController.value.value ?? '-'}',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Brightness source: ${brightnessController.providerLabel.value}',
                  textAlign: TextAlign.center,
                ),
                if (diagnosticsStatus.value.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    diagnosticsStatus.value,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<bool> connectionProcess(BleDevice event) async {
  if (device == null) {
    if (event.name.isEmpty) {
      return false;
    }

    device = event;
    status.value = 'Candidate found: ${event.name}';
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
      deviceName: event.name,
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
      (brightnessPercent - lastSyncedBrightness!).abs() < 2) {
    return;
  }

  final payload = BrightnessCommandEncoder.encodeBrightness(
    profile: profile,
    brightnessPercent: brightnessPercent,
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
    lastSyncedBrightness = brightnessPercent;
    status.value = 'Device Ready (brightness synced: $brightnessPercent)';
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
    uploadIfConfigured: diagnosticsUploadConsent.value,
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
