import 'dart:async';

import 'package:flutter/services.dart';

import 'buffered_broadcast.dart';
import 'notification.dart';

/// The SDK's own native code: Android notifications with buttons, the
/// settings the iOS notification service extension reads, and the badge.
abstract class DakNative {
  /// Android: the SDK-shown notification that launched the app, if any.
  Future<DakNotification?> initialAction();

  /// Android: taps on notifications the SDK showed (body or button). Taps
  /// that come while nobody listens are kept for the next listener.
  Stream<DakNotification> get onAction;

  /// iOS with firebase_messaging 15/16: the button tapped for a message, if
  /// the app delegate passed the notification response on (see README).
  Future<String?> takeAction(String messageId);

  /// iOS: what the notification service extension needs to report
  /// deliveries, written to the App Group's shared defaults.
  Future<void> shareWithExtension(String appGroup, Map<String, String> values);

  /// iOS: sets the app icon badge (and the count the extension adds to).
  Future<void> setBadge(int count, {String? appGroup});

  /// Android: shows a Dak notification with its buttons (for a message that
  /// arrived while the app was open).
  Future<void> show(Map<String, String> data);
}

class MethodChannelDakNative implements DakNative {
  MethodChannelDakNative() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAction') {
        final n = _decode(call.arguments);
        if (n != null) _actions.add(n);
      }
    });
  }

  static const _channel = MethodChannel('dak_push');
  final _actions = BufferedBroadcast<DakNotification>();

  static DakNotification? _decode(Object? args) {
    if (args is! Map) return null;
    final data = (args['data'] as Map?)?.map((k, v) => MapEntry(k.toString(), v)) ?? <String, dynamic>{};
    final action = args['action_id'] as String?;
    return DakNotification.fromData(data, actionId: action == null || action.isEmpty ? null : action);
  }

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<DakNotification?> initialAction() async => _decode(await _call<Object>('initialAction'));

  @override
  Stream<DakNotification> get onAction => _actions.stream;

  @override
  Future<String?> takeAction(String messageId) => _call<String>('takeAction', {'message_id': messageId});

  @override
  Future<void> shareWithExtension(String appGroup, Map<String, String> values) =>
      _call<void>('shareWithExtension', {'app_group': appGroup, 'values': values});

  @override
  Future<void> setBadge(int count, {String? appGroup}) =>
      _call<void>('setBadge', {'count': count, 'app_group': appGroup});

  @override
  Future<void> show(Map<String, String> data) => _call<void>('show', {'data': data});
}

/// No native code (tests).
class NoDakNative implements DakNative {
  const NoDakNative();

  @override
  Future<DakNotification?> initialAction() async => null;

  @override
  Stream<DakNotification> get onAction => const Stream.empty();

  @override
  Future<String?> takeAction(String messageId) async => null;

  @override
  Future<void> shareWithExtension(String appGroup, Map<String, String> values) async {}

  @override
  Future<void> setBadge(int count, {String? appGroup}) async {}

  @override
  Future<void> show(Map<String, String> data) async {}
}
