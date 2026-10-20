import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:http/http.dart' as http;

/// An error answer from the Dak server.
class DakApiException implements Exception {
  DakApiException(this.status, this.code, this.message, {this.retryAfter});

  final int status;
  final String code;
  final String message;

  /// How long the server asked the SDK to wait (Retry-After on 429 and 503).
  final Duration? retryAfter;

  /// The device is unknown or its secret is wrong: register again.
  bool get isUnauthorized => status == 401;

  /// Retrying the same request cannot succeed (bad input, identity check).
  bool get isPermanent =>
      status >= 400 && status < 500 && status != 401 && status != 408 && status != 429;

  @override
  String toString() => 'DakApiException($status $code: $message)';
}

/// The in-app messages for a device, with the ETag to send next time.
class InAppList {
  InAppList(this.messages, this.etag);
  final List<Object?> messages;
  final String? etag;
}

class Registration {
  Registration(this.deviceId, this.deviceSecret);
  final String deviceId;
  final String deviceSecret;
}

/// The SDK half of Dak's HTTP API.
class DakApi {
  /// [baseUrl] must be https; plain http is allowed only for this computer
  /// (localhost, 127.0.0.1, ::1) and the Android emulator's 10.0.2.2.
  DakApi({
    required String baseUrl,
    required this.appId,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  })  : baseUrl = checkBaseUrl(baseUrl),
        _http = client ?? http.Client();

  static const _localHosts = {'localhost', '127.0.0.1', '::1', '10.0.2.2'};

  /// Returns [url] without a trailing slash, or throws an ArgumentError when
  /// it is not https (the device secret travels in every request).
  static String checkBaseUrl(String url) {
    final uri = Uri.tryParse(url);
    final ok = uri != null &&
        uri.host.isNotEmpty &&
        (uri.scheme == 'https' || (uri.scheme == 'http' && _localHosts.contains(uri.host)));
    if (!ok) throw ArgumentError.value(url, 'baseUrl', 'must be an https URL like https://push.example.com');
    return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

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

  /// A tap on a notification, or on its button [actionId].
  Future<void> opened(String deviceId, String secret, String messageId, {String? actionId}) async {
    await _send('POST', _uri('/devices/$deviceId/opened'), {
      'message_id': messageId,
      if (actionId != null) 'action_id': actionId,
    }, secret);
  }

  /// Receipts: these messages arrived on the device (at most 50).
  Future<void> delivered(String deviceId, String secret, List<String> messageIds) async {
    await _send('POST', _uri('/devices/$deviceId/delivered'), {'message_ids': messageIds}, secret);
  }

  /// The in-app messages this device may show; null when unchanged since
  /// [etag].
  Future<InAppList?> fetchInApp(String deviceId, String secret, {String? etag}) async {
    final res = await _send('GET', _uri('/devices/$deviceId/in-app'), null, secret,
        headers: {if (etag != null) 'If-None-Match': etag});
    if (res.statusCode == 304) return null;
    final js = jsonDecode(res.body) as Map<String, dynamic>;
    return InAppList((js['messages'] as List?) ?? const [], res.headers['etag']);
  }

  Future<void> sendInAppEvents(String deviceId, String secret, List<Map<String, Object?>> events) async {
    await _send('POST', _uri('/devices/$deviceId/in-app/events'), {'events': events}, secret);
  }

  Future<http.Response> _send(String method, Uri uri, Map<String, Object?>? body, String? secret,
      {Map<String, String> headers = const {}}) async {
    final req = http.Request(method, uri)..headers.addAll(headers);
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    if (secret != null) req.headers['Authorization'] = 'Device $secret';
    final res = await http.Response.fromStream(await _http.send(req).timeout(timeout));
    if ((res.statusCode >= 200 && res.statusCode < 300) || res.statusCode == 304) return res;
    var code = 'http_${res.statusCode}';
    var message = res.reasonPhrase ?? '';
    try {
      final err = (jsonDecode(res.body) as Map<String, dynamic>)['error'] as Map<String, dynamic>;
      code = err['code'] as String? ?? code;
      message = err['message'] as String? ?? message;
    } catch (_) {}
    throw DakApiException(res.statusCode, code, message, retryAfter: parseRetryAfter(res.headers['retry-after']));
  }
}

/// Retry-After as seconds or as an HTTP date; null when absent or unreadable.
Duration? parseRetryAfter(String? value, {DateTime? now}) {
  if (value == null || value.trim().isEmpty) return null;
  final seconds = int.tryParse(value.trim());
  if (seconds != null) return seconds < 0 ? null : Duration(seconds: seconds);
  try {
    final wait = HttpDate.parse(value.trim()).difference(now ?? DateTime.now());
    return wait.isNegative ? Duration.zero : wait;
  } catch (_) {
    return null;
  }
}
