import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the SDK keeps its state (device id, device secret, pending changes)
/// between app starts: one small JSON string. Receipts from Firebase's
/// background isolate are kept apart, so the two never overwrite each other.
abstract class DakStorage {
  Future<String?> read();
  Future<void> write(String value);

  /// Delivery receipts the background handler could not send (a JSON list).
  Future<String?> readReceipts();
  Future<void> writeReceipts(String value);
}

/// Keychain on iOS, encrypted storage on Android.
class SecureDakStorage implements DakStorage {
  SecureDakStorage([this._storage = const FlutterSecureStorage(), this._key = 'dak_push_state']);

  static const _receiptsKey = 'dak_push_receipts';
  final FlutterSecureStorage _storage;
  final String _key;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);

  @override
  Future<String?> readReceipts() => _storage.read(key: _receiptsKey);

  @override
  Future<void> writeReceipts(String value) => _storage.write(key: _receiptsKey, value: value);
}

/// Keeps state in memory only (tests).
class MemoryDakStorage implements DakStorage {
  String? value;
  String? receipts;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String v) async => value = v;

  @override
  Future<String?> readReceipts() async => receipts;

  @override
  Future<void> writeReceipts(String v) async => receipts = v;
}
