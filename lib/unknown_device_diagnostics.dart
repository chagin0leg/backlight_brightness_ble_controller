import 'dart:convert';
import 'dart:developer';
import 'dart:io';

class UnknownDeviceSnapshot {
  UnknownDeviceSnapshot({
    required this.createdAtUtc,
    required this.platform,
    required this.deviceName,
    required this.deviceAddress,
    required this.services,
    required this.characteristics,
    required this.matchScore,
    required this.matchReasons,
    required this.errorMessage,
  });

  final DateTime createdAtUtc;
  final String platform;
  final String deviceName;
  final String deviceAddress;
  final List<String> services;
  final List<String> characteristics;
  final double matchScore;
  final List<String> matchReasons;
  final String? errorMessage;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'created_at_utc': createdAtUtc.toIso8601String(),
      'platform': platform,
      'device_name': deviceName,
      'device_address': deviceAddress,
      'services': services,
      'characteristics': characteristics,
      'match_score': matchScore,
      'match_reasons': matchReasons,
      'error_message': errorMessage,
    };
  }
}

class UnknownDeviceDiagnosticsCollector {
  UnknownDeviceDiagnosticsCollector({this.folderName = 'backlight_ble_diagnostics'});

  final String folderName;

  Future<String?> saveSnapshot({
    required String deviceName,
    required String deviceAddress,
    required List<String> services,
    required List<String> characteristics,
    required double matchScore,
    required List<String> matchReasons,
    String? errorMessage,
  }) async {
    try {
      final snapshot = UnknownDeviceSnapshot(
        createdAtUtc: DateTime.now().toUtc(),
        platform: Platform.operatingSystem,
        deviceName: deviceName,
        deviceAddress: deviceAddress,
        services: services,
        characteristics: characteristics,
        matchScore: matchScore,
        matchReasons: matchReasons,
        errorMessage: errorMessage,
      );

      final directory = await _resolveDiagnosticsDirectory();
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      final timestamp =
          snapshot.createdAtUtc.toIso8601String().replaceAll(':', '-');
      final fileName = 'unknown_device_$timestamp.json';
      final file = File('${directory.path}${Platform.pathSeparator}$fileName');
      final json = const JsonEncoder.withIndent('  ').convert(snapshot.toMap());
      await file.writeAsString(json);
      return file.path;
    } catch (error) {
      log('Unable to save unknown device diagnostics: $error');
      return null;
    }
  }

  Future<Directory> _resolveDiagnosticsDirectory() async {
    return Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}$folderName',
    );
  }
}
