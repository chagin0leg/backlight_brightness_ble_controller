enum DeviceCapability {
  power,
  brightness,
  rgb,
  colorTemperature,
  effect,
}

DeviceCapability? deviceCapabilityFromString(String rawValue) {
  final normalized = rawValue.trim().toLowerCase();
  for (final capability in DeviceCapability.values) {
    if (capability.name.toLowerCase() == normalized) {
      return capability;
    }
  }
  return null;
}

class DeviceFingerprint {
  const DeviceFingerprint({
    required this.nameContains,
    required this.serviceUuids,
    required this.characteristicUuids,
    this.manufacturerId,
  });

  final List<String> nameContains;
  final List<String> serviceUuids;
  final List<String> characteristicUuids;
  final int? manufacturerId;

  factory DeviceFingerprint.fromMap(Map<String, dynamic> map) {
    return DeviceFingerprint(
      nameContains: (map['name_contains'] as List<dynamic>? ?? [])
          .map((item) => item.toString())
          .toList(),
      serviceUuids: (map['service_uuids'] as List<dynamic>? ?? [])
          .map((item) => item.toString().toLowerCase())
          .toList(),
      characteristicUuids:
          (map['characteristic_uuids'] as List<dynamic>? ?? [])
              .map((item) => item.toString().toLowerCase())
              .toList(),
      manufacturerId: map['manufacturer_id'] as int?,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'name_contains': nameContains,
      'service_uuids': serviceUuids,
      'characteristic_uuids': characteristicUuids,
      'manufacturer_id': manufacturerId,
    };
  }
}

class BrightnessCommandSpec {
  const BrightnessCommandSpec({
    required this.serviceUuid,
    required this.characteristicUuid,
    required this.basePayload,
    required this.valueByteIndex,
    required this.minValue,
    required this.maxValue,
    required this.writeWithResponse,
  });

  final String serviceUuid;
  final String characteristicUuid;
  final List<int> basePayload;
  final int valueByteIndex;
  final int minValue;
  final int maxValue;
  final bool writeWithResponse;

  factory BrightnessCommandSpec.fromMap(Map<String, dynamic> map) {
    return BrightnessCommandSpec(
      serviceUuid: map['service_uuid'].toString().toLowerCase(),
      characteristicUuid: map['characteristic_uuid'].toString().toLowerCase(),
      basePayload: (map['base_payload'] as List<dynamic>)
          .map((item) => item as int)
          .toList(),
      valueByteIndex: map['value_byte_index'] as int,
      minValue: map['min_value'] as int,
      maxValue: map['max_value'] as int,
      writeWithResponse: map['write_with_response'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'service_uuid': serviceUuid,
      'characteristic_uuid': characteristicUuid,
      'base_payload': basePayload,
      'value_byte_index': valueByteIndex,
      'min_value': minValue,
      'max_value': maxValue,
      'write_with_response': writeWithResponse,
    };
  }
}

class DeviceProfile {
  const DeviceProfile({
    required this.id,
    required this.label,
    required this.vendor,
    required this.fingerprint,
    required this.capabilities,
    required this.brightnessCommand,
  });

  final String id;
  final String label;
  final String vendor;
  final DeviceFingerprint fingerprint;
  final Set<DeviceCapability> capabilities;
  final BrightnessCommandSpec? brightnessCommand;

  factory DeviceProfile.fromMap(Map<String, dynamic> map) {
    final parsedCapabilities = <DeviceCapability>{};
    for (final item in (map['capabilities'] as List<dynamic>? ?? [])) {
      final parsed = deviceCapabilityFromString(item.toString());
      if (parsed != null) {
        parsedCapabilities.add(parsed);
      }
    }

    return DeviceProfile(
      id: map['id'].toString(),
      label: map['label'].toString(),
      vendor: map['vendor'].toString(),
      fingerprint:
          DeviceFingerprint.fromMap(map['fingerprint'] as Map<String, dynamic>),
      capabilities: parsedCapabilities,
      brightnessCommand: map['brightness_command'] == null
          ? null
          : BrightnessCommandSpec.fromMap(
              map['brightness_command'] as Map<String, dynamic>,
            ),
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'label': label,
      'vendor': vendor,
      'fingerprint': fingerprint.toMap(),
      'capabilities': capabilities.map((item) => item.name).toList(),
      'brightness_command': brightnessCommand?.toMap(),
    };
  }
}

class ProfileMatchResult {
  const ProfileMatchResult({
    required this.profile,
    required this.score,
    required this.reasons,
    required this.threshold,
  });

  final DeviceProfile? profile;
  final double score;
  final List<String> reasons;
  final double threshold;

  bool get confident => profile != null && score >= threshold;
}

class DeviceProfileMatcher {
  static ProfileMatchResult match({
    required String deviceName,
    required List<String> serviceUuids,
    required List<String> characteristicUuids,
    int? manufacturerId,
    required List<DeviceProfile> candidates,
    double threshold = 0.55,
  }) {
    if (candidates.isEmpty) {
      return ProfileMatchResult(
        profile: null,
        score: 0,
        reasons: const ['No profiles loaded'],
        threshold: threshold,
      );
    }

    final normalizedName = deviceName.toLowerCase();
    final normalizedServices = serviceUuids.map((item) => item.toLowerCase());
    final normalizedCharacteristics =
        characteristicUuids.map((item) => item.toLowerCase());

    DeviceProfile? bestProfile;
    double bestScore = 0;
    List<String> bestReasons = const ['No match'];

    for (final candidate in candidates) {
      final reasons = <String>[];
      double score = 0;

      const nameWeight = 0.45;
      const serviceWeight = 0.35;
      const characteristicWeight = 0.15;
      const manufacturerWeight = 0.05;

      final hasNameHint = candidate.fingerprint.nameContains.any(
        (token) => normalizedName.contains(token.toLowerCase()),
      );
      if (hasNameHint) {
        score += nameWeight;
        reasons.add('Name fingerprint matched');
      }

      final serviceCoverage = _coverage(
        requiredValues: candidate.fingerprint.serviceUuids,
        availableValues: normalizedServices,
      );
      if (serviceCoverage > 0) {
        score += serviceWeight * serviceCoverage;
        reasons.add(
          'Service coverage ${(serviceCoverage * 100).toStringAsFixed(0)}%',
        );
      }

      final characteristicCoverage = _coverage(
        requiredValues: candidate.fingerprint.characteristicUuids,
        availableValues: normalizedCharacteristics,
      );
      if (characteristicCoverage > 0) {
        score += characteristicWeight * characteristicCoverage;
        reasons.add(
          'Characteristic coverage '
          '${(characteristicCoverage * 100).toStringAsFixed(0)}%',
        );
      }

      if (candidate.fingerprint.manufacturerId != null &&
          candidate.fingerprint.manufacturerId == manufacturerId) {
        score += manufacturerWeight;
        reasons.add('Manufacturer fingerprint matched');
      }

      score = score.clamp(0, 1).toDouble();
      if (score > bestScore) {
        bestScore = score;
        bestProfile = candidate;
        bestReasons = reasons.isEmpty ? const ['Weak match'] : reasons;
      }
    }

    return ProfileMatchResult(
      profile: bestProfile,
      score: bestScore,
      reasons: bestReasons,
      threshold: threshold,
    );
  }

  static double _coverage({
    required List<String> requiredValues,
    required Iterable<String> availableValues,
  }) {
    if (requiredValues.isEmpty) {
      return 0;
    }
    final available = Set<String>.from(availableValues);
    final requiredSet = requiredValues.map((item) => item.toLowerCase()).toSet();
    final matched = requiredSet.where(available.contains).length;
    return matched / requiredSet.length;
  }
}

class BrightnessCommandEncoder {
  static List<int>? encodeBrightness({
    required DeviceProfile profile,
    required int brightnessPercent,
  }) {
    final spec = profile.brightnessCommand;
    if (spec == null) {
      return null;
    }
    if (spec.basePayload.length <= spec.valueByteIndex) {
      return null;
    }

    final normalizedPercent = brightnessPercent.clamp(0, 100).toInt();
    final range = spec.maxValue - spec.minValue;
    final mappedValue = spec.minValue + ((range * normalizedPercent) / 100).round();
    final payload = List<int>.from(spec.basePayload);
    payload[spec.valueByteIndex] = mappedValue.clamp(0, 255).toInt();
    return payload;
  }
}
