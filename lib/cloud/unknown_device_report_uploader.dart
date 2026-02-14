import 'dart:convert';
import 'dart:io';

class UnknownDeviceReportUploadResult {
  const UnknownDeviceReportUploadResult({
    required this.ok,
    required this.message,
    this.statusCode,
  });

  final bool ok;
  final String message;
  final int? statusCode;
}

abstract class UnknownDeviceReportUploader {
  Future<UnknownDeviceReportUploadResult> upload(Map<String, dynamic> payload);
}

class HttpUnknownDeviceReportUploader implements UnknownDeviceReportUploader {
  HttpUnknownDeviceReportUploader({
    required this.endpointUrl,
    this.apiKeyHeader,
    this.apiKeyValue,
    this.timeout = const Duration(seconds: 12),
  });

  final String endpointUrl;
  final String? apiKeyHeader;
  final String? apiKeyValue;
  final Duration timeout;

  @override
  Future<UnknownDeviceReportUploadResult> upload(
    Map<String, dynamic> payload,
  ) async {
    final uri = Uri.tryParse(endpointUrl);
    if (uri == null) {
      return const UnknownDeviceReportUploadResult(
        ok: false,
        message: 'Diagnostics upload URL is invalid',
      );
    }

    final client = HttpClient();
    try {
      final request = await client.postUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');

      if (apiKeyHeader != null &&
          apiKeyHeader!.isNotEmpty &&
          apiKeyValue != null &&
          apiKeyValue!.isNotEmpty) {
        request.headers.set(apiKeyHeader!, apiKeyValue!);
      }

      request.write(jsonEncode(payload));
      final response = await request.close().timeout(timeout);
      final responseBody = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return UnknownDeviceReportUploadResult(
          ok: true,
          statusCode: response.statusCode,
          message: responseBody.isEmpty
              ? 'Diagnostics uploaded successfully'
              : responseBody,
        );
      }
      return UnknownDeviceReportUploadResult(
        ok: false,
        statusCode: response.statusCode,
        message: responseBody.isEmpty
            ? 'Diagnostics upload failed with HTTP ${response.statusCode}'
            : responseBody,
      );
    } on SocketException catch (error) {
      return UnknownDeviceReportUploadResult(
        ok: false,
        message: 'Socket error while uploading diagnostics: $error',
      );
    } on HandshakeException catch (error) {
      return UnknownDeviceReportUploadResult(
        ok: false,
        message: 'TLS handshake error while uploading diagnostics: $error',
      );
    } on HttpException catch (error) {
      return UnknownDeviceReportUploadResult(
        ok: false,
        message: 'HTTP error while uploading diagnostics: $error',
      );
    } on FormatException catch (error) {
      return UnknownDeviceReportUploadResult(
        ok: false,
        message: 'Payload format error while uploading diagnostics: $error',
      );
    } catch (error) {
      return UnknownDeviceReportUploadResult(
        ok: false,
        message: 'Unexpected diagnostics upload error: $error',
      );
    } finally {
      client.close(force: true);
    }
  }
}
