import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'notification.dart';
import 'storage.dart';

/// Firebase's background message handler for Dak: reports that the push
/// arrived. Dak.init registers it unless DakOptions(handleBackgroundMessages:
/// false); an app with its own handler calls [Dak.handleBackgroundMessage]
/// from it instead.
@pragma('vm:entry-point')
Future<void> dakBackgroundMessageHandler(RemoteMessage message) => reportDelivery(message.data);

/// Sends the receipt for a push from FCM's data. It runs in Firebase's
/// background isolate, so it reads the device id and secret the app saved;
/// if it cannot send, the app sends the receipt on its next start or resume.
Future<void> reportDelivery(
  Map<String, dynamic> data, {
  DakStorage? storage,
  http.Client? client,
}) async {
  final id = data[DakNotification.idKey]?.toString();
  if (id == null || id.isEmpty) return;
  final store = storage ?? SecureDakStorage();
  Map<String, dynamic>? state;
  try {
    final raw = await store.read();
    if (raw != null && raw.isNotEmpty) state = jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {}
  final baseUrl = state?['base_url'] as String?;
  final appId = state?['app_id'] as String?;
  final deviceId = state?['device_id'] as String?;
  final secret = state?['secret'] as String?;
  if (baseUrl != null && appId != null && deviceId != null && secret != null) {
    try {
      await DakApi(baseUrl: baseUrl, appId: appId, client: client, timeout: const Duration(seconds: 10))
          .delivered(deviceId, secret, [id]);
      return;
    } on DakApiException catch (e) {
      if (e.isPermanent || e.isUnauthorized) return;
    } catch (_) {
      // No network: keep it for later.
    }
  }
  try {
    await store.addReceipt(id);
  } catch (_) {}
}
