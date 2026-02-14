import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:backlight_brightness_ble_controller/device_profile.dart';
import 'package:backlight_brightness_ble_controller/device_profile_signature.dart';

class DeviceProfileRegistry {
  DeviceProfileRegistry();

  static const List<String> defaultAssetPaths = <String>[
    'assets/device_profiles/elk_bledom.json',
  ];

  final List<DeviceProfile> _profiles = <DeviceProfile>[];

  List<DeviceProfile> get profiles => List<DeviceProfile>.unmodifiable(_profiles);

  Future<void> loadDefaultProfiles() async {
    await loadFromAssetPaths(defaultAssetPaths);
    if (_profiles.isEmpty) {
      loadFallbackProfiles();
    }
  }

  Future<void> loadFromAssetPaths(List<String> assetPaths) async {
    _profiles.clear();
    for (final path in assetPaths) {
      try {
        final rawJson = await rootBundle.loadString(path);
        final decoded = jsonDecode(rawJson);
        if (decoded is Map<String, dynamic>) {
          _profiles.add(DeviceProfile.fromMap(decoded));
          continue;
        }
        if (decoded is List<dynamic>) {
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              _profiles.add(DeviceProfile.fromMap(item));
            }
          }
        }
      } catch (error) {
        log('Failed to load profile asset $path: $error');
      }
    }
  }

  Future<bool> loadFromRemoteManifest(
    String manifestUrl, {
    bool signedManifestRequired = false,
    String? manifestPublicKeyBase64,
  }) async {
    final uri = Uri.tryParse(manifestUrl);
    if (uri == null) {
      log('Remote profile manifest URL is invalid: $manifestUrl');
      return false;
    }

    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        log('Failed to load remote profile manifest: HTTP ${response.statusCode}');
        return false;
      }

      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      final keyConfigured =
          manifestPublicKeyBase64 != null && manifestPublicKeyBase64.trim().isNotEmpty;
      final looksSignedEnvelope =
          decoded is Map<String, dynamic> && _looksLikeSignedEnvelope(decoded);

      dynamic manifestPayload = decoded;
      if (looksSignedEnvelope) {
        if (!keyConfigured) {
          log(
            'Signed manifest received but profile registry public key is missing',
          );
          return false;
        }
        final envelope = SignedProfileManifestEnvelope.fromMap(
          decoded as Map<String, dynamic>,
        );
        if (envelope == null) {
          log('Signed manifest envelope is malformed');
          return false;
        }
        final verifier = DeviceProfileSignatureVerifier(
          publicKeyBase64: manifestPublicKeyBase64!,
        );
        final signatureOk = await verifier.verify(envelope);
        if (!signatureOk) {
          log('Remote profile manifest signature verification failed');
          return false;
        }
        manifestPayload = envelope.decodePayloadJson();
      } else if (signedManifestRequired || keyConfigured) {
        log(
          'Remote profile manifest must be signed, but unsigned payload was received',
        );
        return false;
      }

      final parsedProfiles = <DeviceProfile>[];
      if (manifestPayload is Map<String, dynamic>) {
        parsedProfiles.add(DeviceProfile.fromMap(manifestPayload));
      } else if (manifestPayload is List<dynamic>) {
        for (final item in manifestPayload) {
          if (item is Map<String, dynamic>) {
            parsedProfiles.add(DeviceProfile.fromMap(item));
          }
        }
      }

      if (parsedProfiles.isEmpty) {
        log('Remote profile manifest has no valid profiles');
        return false;
      }

      _profiles
        ..clear()
        ..addAll(parsedProfiles);
      return true;
    } catch (error) {
      log('Failed to fetch remote profile manifest: $error');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  void loadFallbackProfiles() {
    _profiles
      ..clear()
      ..addAll(
        _fallbackProfileMaps
            .map((map) => DeviceProfile.fromMap(map))
            .toList(growable: false),
      );
  }
}

bool _looksLikeSignedEnvelope(Map<String, dynamic> map) {
  final payload = map['payload_b64']?.toString() ?? '';
  final signature = map['signature_b64']?.toString() ?? '';
  return payload.trim().isNotEmpty || signature.trim().isNotEmpty;
}

const List<Map<String, dynamic>> _fallbackProfileMaps = <Map<String, dynamic>>[
  <String, dynamic>{
    'id': 'elk-bledom-default',
    'label': 'ELK-BLEDOM',
    'vendor': 'Unknown',
    'capabilities': <String>['power', 'brightness', 'rgb'],
    'fingerprint': <String, dynamic>{
      'name_contains': <String>['ELK-BLEDOM'],
      'service_uuids': <String>['0000fff0-0000-1000-8000-00805f9b34fb'],
      'characteristic_uuids': <String>['0000fff3-0000-1000-8000-00805f9b34fb'],
    },
    'brightness_command': <String, dynamic>{
      'service_uuid': '0000fff0-0000-1000-8000-00805f9b34fb',
      'characteristic_uuid': '0000fff3-0000-1000-8000-00805f9b34fb',
      'base_payload': <int>[126, 4, 1, 128, 255, 0, 0, 239],
      'value_byte_index': 3,
      'min_value': 1,
      'max_value': 255,
      'write_with_response': false,
    },
  },
];
