import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:backlight_brightness_ble_controller/cloud/app_cloud_config.dart';
import 'package:get/get.dart';

typedef HttpClientFactory = HttpClient Function();

class AnonymousAnalyticsEvent {
  const AnonymousAnalyticsEvent({
    required this.name,
    required this.timestampUtc,
    required this.params,
  });

  final String name;
  final DateTime timestampUtc;
  final Map<String, dynamic> params;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'name': name,
      'timestamp_utc': timestampUtc.toIso8601String(),
      'params': params,
    };
  }
}

class AnonymousAnalyticsService {
  AnonymousAnalyticsService({
    Random? random,
    HttpClientFactory? httpClientFactory,
  })  : _random = random ?? Random(),
        _httpClientFactory = httpClientFactory ?? HttpClient.new;

  final Random _random;
  final HttpClientFactory _httpClientFactory;
  final RxBool enabled = false.obs;
  final RxInt queuedEvents = 0.obs;
  final RxString status = 'Anonymous analytics disabled'.obs;
  final List<AnonymousAnalyticsEvent> _queue = <AnonymousAnalyticsEvent>[];

  AnonymousAnalyticsCloudConfig _config = const AnonymousAnalyticsCloudConfig(
    enabled: false,
    collectUsageEvents: false,
    collectCrashSignals: false,
    sampleRatePercent: 1,
  );
  bool _userEnabled = true;
  bool _flushInFlight = false;
  Timer? _flushTimer;

  void configure({
    required AnonymousAnalyticsCloudConfig config,
    required bool userEnabled,
  }) {
    _config = config;
    _userEnabled = userEnabled;
    enabled.value = config.enabled && userEnabled;

    if (!enabled.value) {
      _flushTimer?.cancel();
      _queue.clear();
      queuedEvents.value = 0;
      status.value = !config.enabled
          ? 'Anonymous analytics disabled by cloud config'
          : 'Anonymous analytics disabled by user';
      return;
    }

    status.value = _config.endpointUrl == null || _config.endpointUrl!.trim().isEmpty
        ? 'Anonymous analytics enabled (local queue only)'
        : 'Anonymous analytics enabled';
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(
      const Duration(seconds: 30),
      (timer) => unawaited(flushNow()),
    );
  }

  void updateUserEnabled(bool userEnabled) {
    if (_userEnabled == userEnabled) {
      return;
    }
    configure(config: _config, userEnabled: userEnabled);
  }

  void trackUsage(String eventName, {Map<String, dynamic> params = const {}}) {
    if (!_config.collectUsageEvents) {
      return;
    }
    _track('usage.$eventName', params: params);
  }

  void trackCrash(String eventName, {Map<String, dynamic> params = const {}}) {
    if (!_config.collectCrashSignals) {
      return;
    }
    _track('crash.$eventName', params: params);
  }

  Future<void> flushNow() async {
    if (_flushInFlight || !enabled.value || _queue.isEmpty) {
      return;
    }
    final endpoint = _config.endpointUrl;
    if (endpoint == null || endpoint.trim().isEmpty) {
      return;
    }

    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null) {
      status.value = 'Analytics endpoint is invalid';
      return;
    }

    _flushInFlight = true;
    final snapshot = List<AnonymousAnalyticsEvent>.from(_queue);
    final client = _httpClientFactory();
    try {
      final request = await client.postUrl(uri);
      request.headers.set('Content-Type', 'application/json; charset=utf-8');
      request.add(
        utf8.encode(
          jsonEncode(
            <String, dynamic>{
              'schema': 'anonymous_analytics_v1',
              'events': snapshot.map((event) => event.toMap()).toList(),
            },
          ),
        ),
      );
      final response = await request.close();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _queue.removeRange(0, snapshot.length);
        queuedEvents.value = _queue.length;
        status.value = 'Anonymous analytics flushed (${snapshot.length} events)';
      } else {
        status.value = 'Analytics flush failed: HTTP ${response.statusCode}';
      }
    } catch (error) {
      status.value = 'Analytics flush failed: $error';
    } finally {
      _flushInFlight = false;
      client.close(force: true);
    }
  }

  void dispose() {
    _flushTimer?.cancel();
  }

  void _track(String eventName, {Map<String, dynamic> params = const {}}) {
    if (!enabled.value || !_sampledIn(_config.sampleRatePercent)) {
      return;
    }
    final cleanName = eventName.trim().toLowerCase();
    if (cleanName.isEmpty) {
      return;
    }
    final sanitizedParams = sanitizeAnalyticsParams(params);
    _queue.add(
      AnonymousAnalyticsEvent(
        name: cleanName,
        timestampUtc: DateTime.now().toUtc(),
        params: sanitizedParams,
      ),
    );

    if (_queue.length > 200) {
      _queue.removeRange(0, _queue.length - 200);
    }
    queuedEvents.value = _queue.length;

    if (_queue.length >= 20) {
      unawaited(flushNow());
    }
  }

  bool _sampledIn(int sampleRatePercent) {
    final normalized = sampleRatePercent.clamp(1, 100).toInt();
    return _random.nextInt(100) < normalized;
  }
}

Map<String, dynamic> sanitizeAnalyticsParams(Map<String, dynamic> params) {
  final sanitized = <String, dynamic>{};
  for (final entry in params.entries) {
    final key = _normalizeParamKey(entry.key);
    if (key.isEmpty || _isSensitiveKey(key)) {
      continue;
    }
    final value = _sanitizeParamValue(entry.value);
    if (value == null) {
      continue;
    }
    sanitized[key] = value;
  }
  return sanitized;
}

String _normalizeParamKey(String rawKey) {
  return rawKey.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]+'), '_');
}

bool _isSensitiveKey(String key) {
  return key.contains('email') ||
      key.contains('phone') ||
      key.contains('name') ||
      key.contains('address') ||
      key.contains('token') ||
      key.contains('secret') ||
      key.contains('password') ||
      key == 'user_id' ||
      key == 'user';
}

dynamic _sanitizeParamValue(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is num || value is bool) {
    return value;
  }
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (_looksLikeEmail(trimmed) || _looksLikePhone(trimmed)) {
      return '<redacted>';
    }
    if (trimmed.length > 120) {
      return '${trimmed.substring(0, 120)}...';
    }
    return trimmed;
  }
  if (value is Iterable<dynamic>) {
    final list = <dynamic>[];
    for (final item in value.take(10)) {
      final sanitizedItem = _sanitizeParamValue(item);
      if (sanitizedItem != null) {
        list.add(sanitizedItem);
      }
    }
    return list;
  }
  return null;
}

bool _looksLikeEmail(String input) {
  return input.contains('@') && input.contains('.');
}

bool _looksLikePhone(String input) {
  return RegExp(r'^\+?[0-9][0-9\-\s\(\)]{6,}$').hasMatch(input);
}
