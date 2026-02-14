import 'dart:convert';

import 'package:backlight_brightness_ble_controller/device_profile_signature.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeviceProfileSignatureVerifier', () {
    test('accepts valid ed25519 signature', () async {
      final payload = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{'id': 'example-profile'}
      ]);
      final payloadBytes = utf8.encode(payload);
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final signature = await algorithm.sign(
        payloadBytes,
        keyPair: keyPair,
      );

      final envelope = SignedProfileManifestEnvelope.fromMap(<String, dynamic>{
        'algorithm': 'ed25519',
        'payload_b64': base64Encode(payloadBytes),
        'signature_b64': base64Encode(signature.bytes),
      });

      expect(envelope, isNotNull);
      final verifier = DeviceProfileSignatureVerifier(
        publicKeyBase64: base64Encode(publicKey.bytes),
      );
      final ok = await verifier.verify(envelope!);
      expect(ok, isTrue);
    });

    test('rejects invalid signature', () async {
      final payload = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{'id': 'example-profile'}
      ]);
      final payloadBytes = utf8.encode(payload);
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final wrongKeyPair = await algorithm.newKeyPair();
      final wrongPublicKey = await wrongKeyPair.extractPublicKey();
      final signature = await algorithm.sign(
        payloadBytes,
        keyPair: keyPair,
      );

      final envelope = SignedProfileManifestEnvelope.fromMap(<String, dynamic>{
        'algorithm': 'ed25519',
        'payload_b64': base64Encode(payloadBytes),
        'signature_b64': base64Encode(signature.bytes),
      });

      expect(envelope, isNotNull);
      final verifier = DeviceProfileSignatureVerifier(
        publicKeyBase64: base64Encode(wrongPublicKey.bytes),
      );
      final ok = await verifier.verify(envelope!);
      expect(ok, isFalse);
    });
  });
}
