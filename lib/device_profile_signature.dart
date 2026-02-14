import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class SignedProfileManifestEnvelope {
  SignedProfileManifestEnvelope({
    required this.payloadBytes,
    required this.signatureBytes,
    required this.algorithm,
    this.keyId,
  });

  final Uint8List payloadBytes;
  final Uint8List signatureBytes;
  final String algorithm;
  final String? keyId;

  static SignedProfileManifestEnvelope? fromMap(Map<String, dynamic> map) {
    final payloadRaw = map['payload_b64']?.toString() ?? '';
    final signatureRaw = map['signature_b64']?.toString() ?? '';
    if (payloadRaw.trim().isEmpty || signatureRaw.trim().isEmpty) {
      return null;
    }

    final payloadBytes = _decodeBase64Lenient(payloadRaw);
    final signatureBytes = _decodeBase64Lenient(signatureRaw);
    if (payloadBytes == null || signatureBytes == null) {
      return null;
    }

    return SignedProfileManifestEnvelope(
      payloadBytes: payloadBytes,
      signatureBytes: signatureBytes,
      algorithm: (map['algorithm']?.toString() ?? 'ed25519').trim().toLowerCase(),
      keyId: map['key_id']?.toString(),
    );
  }

  dynamic decodePayloadJson() {
    final payloadString = utf8.decode(payloadBytes);
    return jsonDecode(payloadString);
  }
}

class DeviceProfileSignatureVerifier {
  DeviceProfileSignatureVerifier({required this.publicKeyBase64});

  final String publicKeyBase64;

  Future<bool> verify(SignedProfileManifestEnvelope envelope) async {
    if (envelope.algorithm != 'ed25519') {
      return false;
    }
    final publicKeyBytes = _decodeBase64Lenient(publicKeyBase64);
    if (publicKeyBytes == null || publicKeyBytes.length != 32) {
      return false;
    }

    final algorithm = Ed25519();
    final signature = Signature(
      envelope.signatureBytes,
      publicKey: SimplePublicKey(
        publicKeyBytes,
        type: KeyPairType.ed25519,
      ),
    );
    return algorithm.verify(envelope.payloadBytes, signature: signature);
  }
}

Uint8List? _decodeBase64Lenient(String raw) {
  final normalized = raw.trim();
  if (normalized.isEmpty) {
    return null;
  }
  try {
    return base64Decode(normalized);
  } catch (_) {
    try {
      return base64Url.decode(base64Url.normalize(normalized));
    } catch (_) {
      return null;
    }
  }
}
