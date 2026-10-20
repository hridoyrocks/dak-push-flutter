import 'dart:convert';

import 'package:http/http.dart' as http;

/// An error answer from the Dak server.
class DakApiException implements Exception {
  DakApiException(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;

  /// The device is unknown or its secret is wrong: register again.
  bool get isUnauthorized => status == 401;

  /// Retrying the same request cannot succeed (bad input, identity check).
  bool get isPermanent =>
      status >= 400 && status < 500 && status != 401 && status != 408 && status != 429;

  @override
  String toString() => 'DakApiException($status $code: $message)';
}

class Registration {
  Registration(this.deviceId, this.deviceSecret);
  final String deviceId;
  final String deviceSecret;
}

/// The SDK half of Dak's HTTP API.
class DakApi {
  DakApi({
    required String baseUrl,
    required this.appId,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  })  : baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _http = client ?? http.Client();

  final String baseUrl;
  final String appId;
  final Duration timeout;
  final http.Client _http;

  Uri _uri(String path) => Uri.parse('$baseUrl/v1/apps/$appId$path');

  Future<Registration> register(Map<String, Object?> body) async {
    final res = await _send('POST', _uri('/devices'), body, null);
    final js = jsonDecode(res.body) as Map<String, dynamic>;
    return Registration(js['device_id'] as String, js['device_secret'] as String);
  }

  Future<void> update(String deviceId, String secret, Map<String, Object?> body) async {
    await _send('PATCH', _uri('/devices/$deviceId'), body, secret);
  }

  Future<void> opened(String deviceId, String secret, String messageId) async {
    await _send('POST', _uri('/devices/$deviceId/opened'), {'message_id': messageId}, secret);
  }

  Future<http.Response> _send(String method, Uri uri, Map<String, Object?> body, String? secret) async {
    final req = http.Request(method, uri)
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(body);
    if (secret != null) req.headers['Authorization'] = 'Device $secret';
    final res = await http.Response.fromStream(await _http.send(req).timeout(timeout));
    if (res.statusCode >= 200 && res.statusCode < 300) return res;
    var code = 'http_${res.statusCode}';
    var message = res.reasonPhrase ?? '';
    try {
      final err = (jsonDecode(res.body) as Map<String, dynamic>)['error'] as Map<String, dynamic>;
      code = err['code'] as String? ?? code;
      message = err['message'] as String? ?? message;
    } catch (_) {}
    throw DakApiException(res.statusCode, code, message);
  }
}
