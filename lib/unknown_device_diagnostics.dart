import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:backlight_brightness_ble_controller/cloud/unknown_device_report_uploader.dart';

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

class UnknownDeviceSaveResult {
  const UnknownDeviceSaveResult({
    required this.localPath,
    this.uploadResult,
  });

  final String? localPath;
  final UnknownDeviceReportUploadResult? uploadResult;
}

class UnknownDeviceDiagnosticsCollector {
  UnknownDeviceDiagnosticsCollector({
    this.folderName = 'backlight_ble_diagnostics',
    this.uploader,
  });

  final String folderName;
  UnknownDeviceReportUploader? uploader;

  Future<UnknownDeviceSaveResult> saveSnapshot({
    required String deviceName,
    required String deviceAddress,
    required List<String> services,
    required List<String> characteristics,
    required double matchScore,
    required List<String> matchReasons,
    bool uploadIfConfigured = true,
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
      final payload = snapshot.toMap();
      final json = const JsonEncoder.withIndent('  ').convert(payload);
      await file.writeAsString(json);

      UnknownDeviceReportUploadResult? uploadResult;
      if (uploadIfConfigured && uploader != null) {
        uploadResult = await uploader!.upload(payload);
      }

      return UnknownDeviceSaveResult(
        localPath: file.path,
        uploadResult: uploadResult,
      );
    } catch (error) {
      log('Unable to save unknown device diagnostics: $error');
      return const UnknownDeviceSaveResult(localPath: null);
    }
  }

  Future<Directory> _resolveDiagnosticsDirectory() async {
    return Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}$folderName',
    );
  }
}
