import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the SDK keeps its state (device id, device secret, pending changes)
/// between app starts. One small JSON string.
abstract class DakStorage {
  Future<String?> read();
  Future<void> write(String value);
}

/// Keychain on iOS, encrypted storage on Android.
class SecureDakStorage implements DakStorage {
  SecureDakStorage([this._storage = const FlutterSecureStorage()]);

  static const _key = 'dak_push_state';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
}

/// Keeps state in memory only (tests).
class MemoryDakStorage implements DakStorage {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String v) async => value = v;
}
