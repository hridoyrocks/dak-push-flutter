import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One string kept between app starts.
abstract class DakStateStore {
  Future<String?> read();
  Future<void> write(String value);
}

/// Where the SDK keeps its state (device id, device secret, pending changes)
/// between app starts: one small JSON string. Receipts from Firebase's
/// background isolate are kept apart, one entry each, so the two isolates
/// never overwrite each other's writes.
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

/// Keychain on iOS, encrypted storage on Android.
class SecureDakStorage implements DakStorage {
  SecureDakStorage([this._storage = const FlutterSecureStorage(), this._key = 'dak_push_state']);

  /// How many receipts the background handler keeps at most.
  static const maxReceipts = 200;

  /// 0.3 kept the receipts as one JSON list under this key.
  static const _legacyReceiptsKey = 'dak_push_receipts';
  final FlutterSecureStorage _storage;
  final String _key;

  String get _receiptPrefix => '$_key.receipt.';

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);

  @override
  Future<void> addReceipt(String messageId) async {
    final all = await _storage.readAll();
    final key = '$_receiptPrefix$messageId';
    if (all.containsKey(key) || all.keys.where((k) => k.startsWith(_receiptPrefix)).length >= maxReceipts) return;
    await _storage.write(key: key, value: '1');
  }

  @override
  Future<List<String>> readReceipts() async {
    final all = await _storage.readAll();
    final ids = [
      for (final k in all.keys)
        if (k.startsWith(_receiptPrefix)) k.substring(_receiptPrefix.length),
    ];
    final legacy = all[_legacyReceiptsKey];
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
      await _storage.delete(key: '$_receiptPrefix$id');
    }
    if (await _storage.containsKey(key: _legacyReceiptsKey)) await _storage.delete(key: _legacyReceiptsKey);
  }

  /// Deletes only Dak's own keys: the app may keep its own secrets in the same
  /// storage.
  @override
  Future<void> clear() async {
    await removeReceipts(await readReceipts());
    await _storage.delete(key: _key);
  }

  /// Deletes this storage's state key only (an old in-app cache).
  Future<void> delete() => _storage.delete(key: _key);
}

/// A plain file, written atomically (a temporary file, then a rename). For
/// state that holds no secret and changes often, like the in-app cache.
class FileDakStateStore implements DakStateStore {
  FileDakStateStore(this.path);

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
