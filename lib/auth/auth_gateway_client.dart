import 'dart:convert';
import 'dart:io';

class DeviceAuthStartResult {
  const DeviceAuthStartResult({
    required this.ok,
    required this.message,
    this.sessionId,
    this.authUrl,
    this.expiresInSec,
  });

  final bool ok;
  final String message;
  final String? sessionId;
  final String? authUrl;
  final int? expiresInSec;
}

class DeviceAuthStatusResult {
  const DeviceAuthStatusResult({
    required this.ok,
    required this.status,
    required this.message,
    this.provider,
    this.subject,
    this.error,
  });

  final bool ok;
  final String status;
  final String message;
  final String? provider;
  final String? subject;
  final String? error;
}

class AuthGatewayClient {
  AuthGatewayClient({
    required this.deviceStartUrl,
    required this.deviceStatusUrl,
    this.timeout = const Duration(seconds: 12),
  });

  final String deviceStartUrl;
  final String deviceStatusUrl;
  final Duration timeout;

  Future<DeviceAuthStartResult> startDeviceSession({
    required String provider,
    String? externalAuthUrl,
  }) async {
    final requestUri = _normalizeHttpUri(deviceStartUrl);
    if (requestUri == null) {
      return const DeviceAuthStartResult(
        ok: false,
        message: 'Invalid auth device-start URL',
      );
    }

    final client = HttpClient();
    try {
      final request = await client.postUrl(requestUri).timeout(timeout);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.write(
        jsonEncode(
          <String, dynamic>{
            'provider': provider,
            'external_auth_url': externalAuthUrl ?? '',
          },
        ),
      );
      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join();
      final decoded = _tryDecodeJsonObject(body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return DeviceAuthStartResult(
          ok: false,
          message: decoded?['error']?.toString() ??
              'Device auth start failed: HTTP ${response.statusCode}',
        );
      }
      if (decoded == null) {
        return const DeviceAuthStartResult(
          ok: false,
          message: 'Device auth start returned non-JSON response',
        );
      }

      return DeviceAuthStartResult(
        ok: decoded['ok'] as bool? ?? true,
        message: decoded['message']?.toString() ??
            'Device auth session has been started',
        sessionId: decoded['session_id']?.toString(),
        authUrl: _resolveAuthUrl(
          decoded['auth_url']?.toString(),
          requestUri: requestUri,
        ),
        expiresInSec: _asInt(decoded['expires_in_sec']),
      );
    } on SocketException catch (error) {
      return DeviceAuthStartResult(
        ok: false,
        message: 'Network error while starting auth: $error',
      );
    } catch (error) {
      return DeviceAuthStartResult(
        ok: false,
        message: 'Unexpected error while starting auth: $error',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<DeviceAuthStatusResult> getDeviceSessionStatus({
    required String sessionId,
  }) async {
    final baseUri = _normalizeHttpUri(deviceStatusUrl);
    if (baseUri == null) {
      return const DeviceAuthStatusResult(
        ok: false,
        status: 'error',
        message: 'Invalid auth device-status URL',
      );
    }

    final uri = baseUri.replace(
      queryParameters: <String, String>{
        ...baseUri.queryParameters,
        'session_id': sessionId,
      },
    );

    final client = HttpClient();
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join();
      final decoded = _tryDecodeJsonObject(body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return DeviceAuthStatusResult(
          ok: false,
          status: 'error',
          message: decoded?['error']?.toString() ??
              'Auth status request failed: HTTP ${response.statusCode}',
          error: decoded?['error']?.toString(),
        );
      }
      if (decoded == null) {
        return const DeviceAuthStatusResult(
          ok: false,
          status: 'error',
          message: 'Auth status returned non-JSON response',
        );
      }

      return DeviceAuthStatusResult(
        ok: decoded['ok'] as bool? ?? true,
        status: decoded['status']?.toString() ?? 'unknown',
        message: decoded['message']?.toString() ?? 'Auth status fetched',
        provider: decoded['provider']?.toString(),
        subject: decoded['subject']?.toString(),
        error: decoded['error']?.toString(),
      );
    } on SocketException catch (error) {
      return DeviceAuthStatusResult(
        ok: false,
        status: 'error',
        message: 'Network error while polling auth: $error',
        error: error.toString(),
      );
    } catch (error) {
      return DeviceAuthStatusResult(
        ok: false,
        status: 'error',
        message: 'Unexpected error while polling auth: $error',
        error: error.toString(),
      );
    } finally {
      client.close(force: true);
    }
  }
}

Map<String, dynamic>? _tryDecodeJsonObject(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
  } catch (_) {
    // Ignored intentionally.
  }
  return null;
}

int? _asInt(dynamic rawValue) {
  if (rawValue is int) {
    return rawValue;
  }
  if (rawValue is num) {
    return rawValue.toInt();
  }
  if (rawValue is String) {
    return int.tryParse(rawValue);
  }
  return null;
}

Uri? _normalizeHttpUri(String rawUrl) {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final direct = Uri.tryParse(trimmed);
  if (direct != null && direct.hasScheme) {
    return direct;
  }

  if (trimmed.startsWith('//')) {
    return Uri.tryParse('https:$trimmed');
  }

  if (direct != null && !direct.hasScheme) {
    return Uri.tryParse('https://$trimmed');
  }

  return null;
}

String? _resolveAuthUrl(
  String? rawAuthUrl, {
  required Uri requestUri,
}) {
  if (rawAuthUrl == null) {
    return null;
  }
  final trimmed = rawAuthUrl.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final parsed = Uri.tryParse(trimmed);
  if (parsed != null && parsed.hasScheme) {
    return parsed.toString();
  }

  if (trimmed.startsWith('/')) {
    return requestUri.resolve(trimmed).toString();
  }

  if (parsed != null) {
    return requestUri.resolveUri(parsed).toString();
  }

  return requestUri.resolve(trimmed).toString();
}
