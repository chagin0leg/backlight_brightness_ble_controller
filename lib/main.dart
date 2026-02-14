import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';

import 'package:backlight_brightness_ble_controller/device_profile.dart';
import 'package:backlight_brightness_ble_controller/device_profile_registry.dart';
import 'package:flutter/material.dart';
import 'package:backlight_brightness_ble_controller/brightness.dart';
import 'package:get/get.dart';
import 'package:backlight_brightness_ble_controller/unknown_device_diagnostics.dart';
import 'package:win_ble/win_ble.dart';
import 'package:win_ble/win_file.dart';

BleDevice? device;
final RxString status = RxString('Disconnected');
final RxString profileStatus = RxString('Profile: not selected');
final RxString diagnosticsStatus = RxString('');
final RxList<String> services = <String>[].obs;
final DeviceProfileRegistry deviceProfileRegistry = DeviceProfileRegistry();
final UnknownDeviceDiagnosticsCollector diagnosticsCollector =
    UnknownDeviceDiagnosticsCollector();
final Map<String, DateTime> unknownDeviceReportRateLimit = <String, DateTime>{};
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

  Timer? restart;

  Future<void> initialize() async {
    status.value = 'Loading profiles';
    await deviceProfileRegistry.loadDefaultProfiles();
    status.value = 'Initializing BLE';
    await WinBle.initialize(serverPath: await WinServer.path, enableLog: true);
    status.value = 'Scanning';
    WinBle.startScanning();
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

  final path = await diagnosticsCollector.saveSnapshot(
    deviceName: event.name,
    deviceAddress: event.address,
    services: services,
    characteristics: characteristics,
    matchScore: matchResult.score,
    matchReasons: matchResult.reasons,
    errorMessage: errorMessage,
  );
  diagnosticsStatus.value = path == null
      ? 'Unknown device detected. Failed to store diagnostics.'
      : 'Unknown device diagnostics saved: $path';
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
