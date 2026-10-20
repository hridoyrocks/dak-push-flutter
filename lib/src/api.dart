import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// An error answer from the Dak server.
class DakApiException implements Exception {
  DakApiException(this.status, this.code, this.message, {this.field, this.fromDak = true});

  final int status;
  final String code;
  final String message;

  /// The request field the server refused, like `tags` or `external_id`.
  final String? field;

  /// The answer is Dak's own JSON error. A proxy or load balancer in front
  /// of it (an HTML 403, a 404 page) is not, and is treated as a network
  /// problem: retried, never acted on.
  final bool fromDak;

  /// The device is unknown or its secret is wrong: register again.
  bool get isUnauthorized => fromDak && status == 401;

  /// Retrying the same request cannot succeed (bad input, identity check).
  bool get isPermanent =>
      fromDak && status >= 400 && status < 500 && status != 401 && status != 408 && status != 429;

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
    final res = await _exchange(req);
    if ((res.statusCode >= 200 && res.statusCode < 300) || res.statusCode == 304) return res;
    Object? err;
    try {
      final js = jsonDecode(res.body);
      if (js is Map) err = js['error'];
    } catch (_) {}
    if (err is Map && err['code'] is String) {
      final message = err['message'];
      final field = err['field'];
      throw DakApiException(res.statusCode, err['code'] as String, message is String ? message : '',
          field: field is String && field.isNotEmpty ? field : null);
    }
    throw DakApiException(res.statusCode, 'http_${res.statusCode}', res.reasonPhrase ?? '', fromDak: false);
  }

  /// Sends [req] and reads the whole answer within [timeout]. A server that
  /// sends headers and then stalls would otherwise hold every later call.
  Future<http.Response> _exchange(http.BaseRequest req) async {
    final clock = Stopwatch()..start();
    final sending = _http.send(req);
    final http.StreamedResponse streamed;
    try {
      streamed = await sending.timeout(timeout);
    } on TimeoutException {
      // Close the answer if it still comes.
      unawaited(sending.then<void>((s) => s.stream.listen(null).cancel(), onError: (Object _) {}));
      rethrow;
    }
    final body = BytesBuilder(copy: false);
    final done = Completer<void>();
    final sub = streamed.stream.listen(body.add, onError: done.completeError, onDone: done.complete, cancelOnError: true);
    final left = timeout - clock.elapsed;
    try {
      await done.future.timeout(left.isNegative ? Duration.zero : left);
    } on TimeoutException {
      unawaited(sub.cancel());
      rethrow;
    }
    return http.Response.bytes(
      body.takeBytes(),
      streamed.statusCode,
      request: streamed.request,
      headers: streamed.headers,
      isRedirect: streamed.isRedirect,
      persistentConnection: streamed.persistentConnection,
      reasonPhrase: streamed.reasonPhrase,
    );
  }
}
