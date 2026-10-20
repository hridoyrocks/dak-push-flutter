import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:meta/meta.dart';

/// One string kept between app starts.
abstract class DakStateStore {
  /// The stored string, or null when nothing is stored.
  Future<String?> read();

  /// Replaces the stored string.
  Future<void> write(String value);
}

/// Where the SDK keeps its state (device id, device secret, pending changes)
/// between app starts: one small JSON string. Receipts from Firebase's
/// background isolate are kept apart, one entry each, so the two isolates
/// never overwrite each other's writes.
@internal
abstract class DakStorage implements DakStateStore {
  @override
  Future<String?> read();
  @override
  Future<void> write(String value);

  /// Keeps a delivery receipt the background handler could not send.
  Future<void> addReceipt(String messageId);

  /// The receipts the background handler kept. They stay until
  /// [removeReceipts], so a crash in between loses none.
  Future<List<String>> readReceipts();
  Future<void> removeReceipts(Iterable<String> messageIds);

  /// Forgets the state and the receipts (state left by an earlier install).
  Future<void> clear();
}

/// The keychain calls [SecureDakStorage] makes: flutter_secure_storage in
/// the app, a fake in tests.
abstract class DakKeychain {
  /// The item under [key], or null.
  Future<String?> read(String key);

  /// iOS: the item as SDK 0.3.0 and earlier saved it (readable only while
  /// the phone is unlocked); null elsewhere.
  Future<String?> readLegacy(String key);

  /// Saves [value] under [key].
  Future<void> write(String key, String value);

  /// Removes the item whatever its accessibility.
  Future<void> delete(String key);

  /// The keys of all items saved with the current accessibility.
  Future<Iterable<String>> keys();
}

/// [DakKeychain] on flutter_secure_storage.
class FlutterDakKeychain implements DakKeychain {
  /// Uses [FlutterSecureStorage] unless another is given (tests).
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

  @override
  Future<Iterable<String>> keys() async => (await _storage.readAll(iOptions: iosOptions)).keys;
}

/// Keychain on iOS, encrypted storage on Android.
class SecureDakStorage implements DakStorage {
  /// Keeps the state under [key] in the keychain (a fake one in tests).
  SecureDakStorage({String key = 'dak_push_state', DakKeychain? keychain})
      : _key = key,
        _keychain = keychain ?? FlutterDakKeychain();

  /// How many receipts the background handler keeps at most.
  static const maxReceipts = 200;

  /// 0.3 kept the receipts as one JSON list under this key.
  static const _legacyReceiptsKey = 'dak_push_receipts';
  final DakKeychain _keychain;
  final String _key;
  final _checked = <String>{};

  String get _receiptPrefix => '$_key.receipt.';

  @override
  Future<String?> read() => _read(_key);

  @override
  Future<void> write(String value) => _write(_key, value);

  /// A key of its own, which never existed under 0.3.0's accessibility.
  @override
  Future<void> addReceipt(String messageId) async {
    final keys = await _keychain.keys();
    final key = '$_receiptPrefix$messageId';
    if (keys.contains(key) || keys.where((k) => k.startsWith(_receiptPrefix)).length >= maxReceipts) return;
    await _keychain.write(key, '1');
  }

  @override
  Future<List<String>> readReceipts() async {
    final ids = [
      for (final k in await _keychain.keys())
        if (k.startsWith(_receiptPrefix)) k.substring(_receiptPrefix.length),
    ];
    final legacy = await _read(_legacyReceiptsKey);
    if (legacy != null && legacy.isNotEmpty) {
      try {
        ids.addAll((jsonDecode(legacy) as List).whereType<String>());
      } catch (_) {}
    }
    return ids;
  }

  @override
  Future<void> removeReceipts(Iterable<String> messageIds) async {
    for (final id in messageIds) {
      await _keychain.delete('$_receiptPrefix$id');
    }
    // Nothing writes the old list any more.
    await _keychain.delete(_legacyReceiptsKey);
  }

  /// Deletes only Dak's own keys: the app may keep its own secrets in the same
  /// storage.
  @override
  Future<void> clear() async {
    await removeReceipts(await readReceipts());
    await delete();
  }

  /// Deletes this storage's state key only (an old in-app cache).
  Future<void> delete() => _keychain.delete(_key);

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

/// A plain file, written atomically (a temporary file, then a rename). For
/// state that holds no secret and changes often, like the in-app cache.
class FileDakStateStore implements DakStateStore {
  /// Keeps the string in the file at [path].
  FileDakStateStore(this.path);

  /// The file.
  final String path;
  Future<void> _last = Future.value();

  /// Null when the file does not exist; other errors are thrown.
  @override
  Future<String?> read() async {
    await _last;
    try {
      return await File(path).readAsString();
    } on PathNotFoundException {
      return null;
    }
  }

  /// Writes one at a time, in order.
  @override
  Future<void> write(String value) {
    final next = _last.then((_) => _write(value));
    _last = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _write(String value) async {
    final tmp = File('$path.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(value, flush: true);
    await tmp.rename(path);
  }

  /// Deletes the file, after any write still going.
  Future<void> delete() async {
    await _last;
    try {
      await File(path).delete();
    } on PathNotFoundException {
      // Already gone.
    }
  }
}

/// Moves state 0.3 kept in secure storage ([readOld]) to [to] the first time,
/// then deletes the old copy ([deleteOld]). With [keep] false (state from an
/// earlier install) the old copy is only deleted.
Future<void> moveLegacyState({
  required Future<String?> Function() readOld,
  required Future<void> Function() deleteOld,
  required DakStateStore to,
  required bool keep,
}) async {
  final old = await readOld();
  if (old == null) return;
  if (keep && old.isNotEmpty) {
    final current = await to.read();
    if (current == null || current.isEmpty) await to.write(old);
  }
  await deleteOld();
}

/// Keeps state in memory only (tests).
@internal
class MemoryDakStorage implements DakStorage {
  String? value;
  final receipts = <String>[];

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String v) async => value = v;

  @override
  Future<void> addReceipt(String messageId) async {
    if (!receipts.contains(messageId) && receipts.length < SecureDakStorage.maxReceipts) receipts.add(messageId);
  }

  @override
  Future<List<String>> readReceipts() async => List.of(receipts);

  @override
  Future<void> removeReceipts(Iterable<String> messageIds) async => receipts.removeWhere(messageIds.toSet().contains);

  @override
  Future<void> clear() async {
    value = null;
    receipts.clear();
  }
}
