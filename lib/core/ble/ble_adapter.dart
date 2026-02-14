import 'dart:typed_data';

import 'package:win_ble/win_ble.dart';
import 'package:win_ble/win_file.dart';

class BleScanResult {
  const BleScanResult({
    required this.address,
    required this.name,
  });

  final String address;
  final String name;
}

class BleCharacteristicInfo {
  const BleCharacteristicInfo({
    required this.uuid,
  });

  final String uuid;
}

abstract class BleAdapter {
  Stream<BleScanResult> get scanStream;
  Stream<Map<String, dynamic>> get connectionStream;
  Stream<BleState> get bleStateStream;

  Future<void> initialize();
  Future<void> startScanning();
  Future<void> stopScanning();
  Future<void> connect(String address);
  Future<void> disconnect(String address);
  Future<bool> isPaired(String address);
  Future<void> pair(String address);
  Future<void> unPair(String address);
  Future<List<String>> discoverServices(String address);
  Future<List<BleCharacteristicInfo>> discoverCharacteristics({
    required String address,
    required String serviceId,
  });
  Future<void> write({
    required String address,
    required String serviceId,
    required String characteristicId,
    required List<int> payload,
    required bool writeWithResponse,
  });
}

class WinBleAdapter implements BleAdapter {
  @override
  Stream<BleScanResult> get scanStream =>
      WinBle.scanStream.map((device) => BleScanResult(
            address: device.address,
            name: device.name,
          ));

  @override
  Stream<Map<String, dynamic>> get connectionStream => WinBle.connectionStream;

  @override
  Stream<BleState> get bleStateStream => WinBle.bleState;

  @override
  Future<void> initialize() async {
    await WinBle.initialize(serverPath: await WinServer.path, enableLog: true);
  }

  @override
  Future<void> startScanning() async {
    WinBle.startScanning();
  }

  @override
  Future<void> stopScanning() async {
    WinBle.stopScanning();
  }

  @override
  Future<void> connect(String address) => WinBle.connect(address);

  @override
  Future<void> disconnect(String address) => WinBle.disconnect(address);

  @override
  Future<bool> isPaired(String address) => WinBle.isPaired(address);

  @override
  Future<void> pair(String address) => WinBle.pair(address);

  @override
  Future<void> unPair(String address) => WinBle.unPair(address);

  @override
  Future<List<String>> discoverServices(String address) =>
      WinBle.discoverServices(address);

  @override
  Future<List<BleCharacteristicInfo>> discoverCharacteristics({
    required String address,
    required String serviceId,
  }) async {
    final characteristics = await WinBle.discoverCharacteristics(
      address: address,
      serviceId: serviceId,
    );
    return characteristics
        .map(
          (item) => BleCharacteristicInfo(
            uuid: item.uuid.toLowerCase(),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> write({
    required String address,
    required String serviceId,
    required String characteristicId,
    required List<int> payload,
    required bool writeWithResponse,
  }) {
    return WinBle.write(
      address: address,
      service: serviceId,
      characteristic: characteristicId,
      data: Uint8List.fromList(payload),
      writeWithResponse: writeWithResponse,
    );
  }
}
