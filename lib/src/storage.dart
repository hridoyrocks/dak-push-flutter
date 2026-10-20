import 'package:flutter/foundation.dart';
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

/// The keychain calls [SecureDakStorage] makes: flutter_secure_storage in
/// the app, a fake in tests.
abstract class DakKeychain {
  Future<String?> read(String key);

  /// iOS: the item as SDK 0.3.0 and earlier saved it (readable only while
  /// the phone is unlocked); null elsewhere.
  Future<String?> readLegacy(String key);
  Future<void> write(String key, String value);

  /// Removes the item whatever its accessibility.
  Future<void> delete(String key);
}

class FlutterDakKeychain implements DakKeychain {
  FlutterDakKeychain([this._storage = const FlutterSecureStorage()]);

  /// After the first unlock since the phone started, so a push or a
  /// background fetch that launches the app on a locked iPhone can still
  /// read the state. This device only: a backup restored on another phone
  /// does not bring the device secret along.
  static const iosOptions = IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device);

  // flutter_secure_storage's default, which 0.3.0 used.
  static const _legacyIosOptions = IOSOptions();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key, iOptions: iosOptions);

  @override
  Future<String?> readLegacy(String key) async =>
      defaultTargetPlatform == TargetPlatform.iOS ? _storage.read(key: key, iOptions: _legacyIosOptions) : null;

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value, iOptions: iosOptions);

  @override
  Future<void> delete(String key) => _storage.delete(key: key, iOptions: iosOptions);
}

/// Keychain on iOS, encrypted storage on Android.
class SecureDakStorage implements DakStorage {
  SecureDakStorage({String key = 'dak_push_state', DakKeychain? keychain})
      : _key = key,
        _keychain = keychain ?? FlutterDakKeychain();

  static const _receiptsKey = 'dak_push_receipts';
  final DakKeychain _keychain;
  final String _key;
  final _checked = <String>{};

  @override
  Future<String?> read() => _read(_key);

  @override
  Future<void> write(String value) => _write(_key, value);

  @override
  Future<String?> readReceipts() => _read(_receiptsKey);

  @override
  Future<void> writeReceipts(String value) => _write(_receiptsKey, value);

  /// Throws when the keychain cannot be read (a locked phone); the caller
  /// must then not write, or it would replace state it never saw.
  Future<String?> _read(String key) async {
    final value = await _keychain.read(key);
    if (value != null) {
      _checked.add(key);
      return value;
    }
    // flutter_secure_storage 10 looks items up by accessibility, so one that
    // 0.3.0 saved is found only this way: move it over once.
    final old = await _keychain.readLegacy(key);
    _checked.add(key);
    if (old == null) return null;
    try {
      await _keychain.delete(key);
      await _keychain.write(key, old);
    } catch (_) {
      // The caller has the value and its next save writes it.
    }
    return old;
  }

  Future<void> _write(String key, String value) async {
    // An item 0.3.0 saved and nobody read yet would block the write.
    if (!_checked.contains(key)) await _read(key);
    await _keychain.write(key, value);
  }
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
