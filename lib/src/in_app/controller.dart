import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;

import '../api.dart';
import '../storage.dart';
import 'model.dart';

typedef DakCredentials = ({String deviceId, String secret});

final _triggerKey = RegExp(r'^[A-Za-z0-9_.:-]{1,64}$');

class _Local {
  _Local({this.shown = 0, this.last, this.session = 0});
  int shown;
  DateTime? last;

  /// The session it was last shown in (for every_session).
  int session;

  Map<String, Object?> toJson() => {'shown': shown, 'last': last?.toIso8601String(), 'session': session};

  static _Local fromJson(Map js) => _Local(
        shown: js['shown'] is num ? (js['shown'] as num).toInt() : 0,
        last: js['last'] is String ? DateTime.tryParse(js['last'] as String) : null,
        session: js['session'] is num ? (js['session'] as num).toInt() : 0,
      );
}

/// The in-app message logic: keeps the server's list (also offline), counts
/// sessions, checks triggers and frequency, picks what to show, and reports
/// impressions, clicks and dismissals. [DakInAppHost] draws [current].
class DakInAppController {
  DakInAppController({
    required this.api,
    required this.storage,
    required this.credentials,
    required this.setTags,
    this.openUrl,
    this.sessionTimeout = const Duration(minutes: 5),
    this.fetchWait = const Duration(seconds: 3),
    this.minFetchInterval = const Duration(minutes: 1),
    this.eventDelay = const Duration(seconds: 2),
    this.appState,
    DateTime Function()? clock,
    void Function(String message)? log,
  })  : _now = clock ?? DateTime.now,
        _log = log ?? ((_) {}) {
    _sessionStart = _now();
  }

  final DakApi api;
  final DakStorage storage;

  /// The device's id and secret, or null before it is registered.
  final DakCredentials? Function() credentials;
  final Future<void> Function(Map<String, Object?> tags) setTags;

  /// Opens `url` actions; null leaves them to the app's onInAppClick.
  final Future<bool> Function(Uri url)? openUrl;

  /// Back from the background after this long starts a new session.
  final Duration sessionTimeout;

  /// How long a session start waits for the server before using the cache.
  final Duration fetchWait;
  final Duration minFetchInterval;

  /// Events are sent this long after the last one; null sends only on
  /// [flushEvents] (tests).
  final Duration? eventDelay;

  /// The app's lifecycle state now (WidgetsBinding.instance.lifecycleState).
  /// Sessions start and messages show only in the foreground; null (tests)
  /// counts as the foreground.
  final AppLifecycleState? Function()? appState;
  final DateTime Function() _now;
  final void Function(String) _log;

  // Saved.
  List<Object?> _raw = [];
  String? _etag;
  DateTime? _fetchedAt;
  Map<String, _Local> _local = {};
  int _sessions = 0;
  DateTime? _installedAt;
  List<Map<String, Object?>> _events = [];
  int _seq = 0;

  // This run only.
  List<DakInAppMessage> _messages = [];
  final _triggers = <String, Object>{};
  late DateTime _sessionStart;
  DateTime? _backgroundAt;
  bool _started = false;

  /// The saved state was read (or was unreadable data); until then nothing
  /// is saved over it.
  bool _canSave = false;
  bool _loadTried = false;
  Future<void>? _reloading;
  bool _foreground = true;

  /// Started in the background: the first session waits for the foreground.
  bool _sessionDue = false;
  bool _paused = false;
  int _blocks = 0;
  bool _attached = false;
  bool _pending = false;
  bool _displayed = false;
  final _failed = <String>{};
  Timer? _timer;
  Timer? _eventTimer;
  Future<void>? _fetching;
  Future<void>? _sending;
  final _clicks = StreamController<DakInAppClick>.broadcast();

  /// The message to show now, or null. Set by the controller, drawn by the
  /// host, which reports back with [didDisplay] or [didFail].
  final current = ValueNotifier<DakInAppMessage?>(null);

  Stream<DakInAppClick> get onClick => _clicks.stream;

  /// Usable messages from the last fetch (or the cache), best first.
  List<DakInAppMessage> get messages => List.unmodifiable(_messages);
  int get sessionCount => _sessions;
  Map<String, Object> get triggers => Map.unmodifiable(_triggers);
  bool get isPaused => _paused || _blocks > 0;
  int get pendingEvents => _events.length;

  /// When a time trigger (session_time, since_install) next comes true.
  @visibleForTesting
  DateTime? nextTimeCheck;

  /// Loads the cache, starts the first session and fetches the list. An app
  /// launched in the background (a push, a background fetch) starts its
  /// first session when it comes to the foreground.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _load();
    _installedAt ??= _now();
    final state = appState?.call();
    _foreground = state == null || state == AppLifecycleState.resumed;
    if (!_foreground) {
      _sessionDue = true;
      await _save();
      return;
    }
    _newSession();
    await _save();
    await _sessionStarted();
  }

  void _newSession() {
    _sessions++;
    _sessionStart = _now();
    _failed.clear();
  }

  Future<void> _sessionStarted() async {
    final fetch = refresh();
    var done = false;
    try {
      await fetch.timeout(fetchWait);
      done = true;
    } on TimeoutException {
      // Show from the cache now; the fresh list is checked when it comes.
    }
    _evaluate();
    if (!done) {
      await fetch;
      _evaluate();
    }
    await flushEvents();
  }

  /// Fetches the list from the server (at most once a minute unless forced).
  /// Never throws: without a network the cache stays.
  Future<void> refresh({bool force = false}) {
    final c = credentials();
    if (c == null) return Future.value();
    final now = _now();
    final last = _fetchedAt;
    if (!force && last != null && !now.isBefore(last) && now.difference(last) < minFetchInterval) {
      return _fetching ?? Future.value();
    }
    return _fetching ??= _fetch(c).whenComplete(() => _fetching = null);
  }

  Future<void> _fetch(DakCredentials c) async {
    try {
      final res = await api.fetchInApp(c.deviceId, c.secret, etag: _etag);
      if (res != null) {
        final parsed = _parse(res.messages);
        _raw = res.messages;
        _etag = res.etag;
        _messages = parsed;
      }
      _fetchedAt = _now();
      await _save();
    } catch (e) {
      _log('dak: in-app fetch failed, using the cache: $e');
    }
  }

  /// The device just registered (first start): fetch its list now.
  Future<void> onRegistered() async {
    if (!_started) return;
    await refresh(force: true);
    _evaluate();
    await flushEvents();
  }

  /// The messages this SDK can show, best first. One it cannot read is
  /// skipped, never the whole list.
  List<DakInAppMessage> _parse(List<Object?> raw) {
    final list = <DakInAppMessage>[];
    for (final js in raw) {
      final m = DakInAppMessage.parse(js);
      if (m == null) {
        _log('dak: skipping an in-app message this SDK version cannot show');
      } else {
        list.add(m);
      }
    }
    // Highest priority first; ties keep the server's order (newest first).
    final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
    indexed.sort((a, b) {
      final p = b.$2.priority.compareTo(a.$2.priority);
      return p != 0 ? p : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  // ---- triggers and pause

  /// Sets triggers; values are strings, numbers or booleans. Triggers live in
  /// memory only and never leave the phone.
  void addTriggers(Map<String, Object> triggers) {
    triggers.forEach((k, v) {
      if (!_triggerKey.hasMatch(k)) {
        throw ArgumentError.value(k, 'trigger key', 'must be 1-64 of A-Z a-z 0-9 _ . : -');
      }
      if (v is! String && v is! num && v is! bool) {
        throw ArgumentError.value(v, k, 'trigger values must be strings, numbers or booleans');
      }
    });
    _triggers.addAll(triggers);
    _evaluate(queue: true);
  }

  void removeTriggers(Iterable<String> keys) {
    keys.forEach(_triggers.remove);
    _evaluate(queue: true);
  }

  void clearTriggers() => removeTriggers(_triggers.keys.toList());

  /// Checks the triggers again now (also called by timers).
  void check() => _evaluate(queue: true);

  /// While paused nothing shows; a message on screen is hidden (not counted
  /// as dismissed). Unpausing shows what is due.
  void setPaused(bool paused) {
    _paused = paused;
    _pauseChanged();
  }

  /// Pauses while a [DakInAppBlock] is on screen; counted, so nested blocks work.
  void block() {
    _blocks++;
    _pauseChanged();
  }

  void unblock() {
    _blocks = math.max(0, _blocks - 1);
    _pauseChanged();
  }

  void _pauseChanged() {
    if (isPaused) {
      if (current.value != null) {
        _displayed = false;
        current.value = null;
      }
    } else {
      _evaluate();
    }
  }

  // ---- host

  void attach() {
    _attached = true;
    _evaluate();
  }

  void detach() {
    _attached = false;
    _displayed = false;
    current.value = null;
  }

  /// The host drew the message: count the impression.
  void didDisplay(DakInAppMessage m) {
    if (current.value?.id != m.id || _displayed) return;
    _displayed = true;
    final l = _local[m.id] ??= _Local();
    l.shown++;
    l.last = _now();
    l.session = _sessions;
    if (_local.length > 500) {
      final oldest = _local.entries.reduce((a, b) => (a.value.last ?? DateTime(0)).isBefore(b.value.last ?? DateTime(0)) ? a : b);
      _local.remove(oldest.key);
    }
    _queueEvent(m.id, 'impression');
  }

  /// The host could not draw it (an image-only message whose image did not
  /// load): skip it for this session.
  void didFail(DakInAppMessage m) {
    if (current.value?.id != m.id) return;
    _failed.add(m.id);
    _close();
    _evaluate();
  }

  /// A tap on a button, or on the message itself ([button] null).
  Future<void> click(DakInAppMessage m, [DakInAppButton? button]) async {
    final action = button?.action ?? m.content.clickAction;
    if (action == null || current.value?.id != m.id) return;
    _queueEvent(m.id, 'click', buttonId: button?.id);
    _close();
    _clicks.add(DakInAppClick(messageId: m.id, buttonId: button?.id, action: action));
    try {
      switch (action.type) {
        case 'tags':
          await setTags(action.tags);
        case 'url':
          final url = Uri.tryParse(action.url ?? '');
          if (url != null && openUrl != null) await openUrl!(url);
      }
    } catch (e) {
      _log('dak: in-app action ${action.type} failed: $e');
    }
  }

  /// Closed by X, a tap outside, a swipe, the back button or a timeout.
  void dismiss(DakInAppMessage m) {
    if (current.value?.id != m.id) return;
    if (_displayed) _queueEvent(m.id, 'dismiss');
    _close();
  }

  /// Android back button: closes a message on screen.
  bool handleBack() {
    final m = current.value;
    if (m == null || !_displayed) return false;
    dismiss(m);
    return true;
  }

  void _close() {
    _displayed = false;
    current.value = null;
    if (_pending) {
      _pending = false;
      _evaluate();
    }
  }

  // ---- lifecycle

  void lifecycle(AppLifecycleState state) {
    if (!_started) return;
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _foreground = false;
        _backgroundAt ??= _now();
        unawaited(flushEvents());
      case AppLifecycleState.resumed:
        _foreground = true;
        if (_loadTried && !_canSave) unawaited(_reload());
        final since = _backgroundAt;
        _backgroundAt = null;
        if (_sessionDue || (since != null && _now().difference(since) >= sessionTimeout)) {
          _sessionDue = false;
          _newSession();
          unawaited(_save());
          unawaited(_sessionStarted());
        } else {
          _evaluate();
        }
      default:
    }
  }

  // ---- choosing

  /// Shows the best message that is due. With [queue], a message due while
  /// another is on screen follows when that one closes.
  void _evaluate({bool queue = false}) {
    if (!_started) return;
    final now = _now();
    _scheduleTimer(now);
    final best = _messages.where((m) => _eligible(m, now)).firstOrNull;
    if (best == null) return;
    if (current.value != null) {
      if (queue && current.value!.id != best.id) _pending = true;
      return;
    }
    if (isPaused || !_attached || !_foreground) return;
    _displayed = false;
    current.value = best;
  }

  bool _eligible(DakInAppMessage m, DateTime now) {
    if (_failed.contains(m.id)) return false;
    if (m.startAt != null && now.isBefore(m.startAt!)) return false;
    if (m.endAt != null && !now.isBefore(m.endAt!)) return false;
    final local = _local[m.id];
    final shown = math.max(local?.shown ?? 0, m.shown);
    final last = _later(local?.last, m.lastShownAt);
    final max = m.frequency.maxDisplays;
    if (max != null && shown >= max) return false;
    switch (m.frequency.type) {
      case 'once':
        if (shown > 0) return false;
      case 'every_session':
        if (local?.session == _sessions) return false;
      case 'interval':
        if (last != null && now.difference(last) < m.frequency.interval) return false;
    }
    return m.triggers.isEmpty || m.triggers.any((group) => group.every((c) => _holds(c, now)));
  }

  bool _holds(DakInAppCondition c, DateTime now) {
    switch (c.kind) {
      case 'session_count':
        return _compare(_sessions, c.op, c.value as num);
      case 'session_time':
        return _compare(now.difference(_sessionStart).inSeconds, c.op, c.value as num);
      case 'since_install':
        return _compare(now.difference(_installedAt ?? now).inSeconds, c.op, c.value as num);
      case 'custom':
        final v = _triggers[c.key];
        switch (c.op) {
          case 'exists':
            return v != null;
          case 'not_exists':
            return v == null;
          case 'in':
            return v != null && c.values.contains(_str(v));
          case '=':
            return v != null && _equal(v, c.value);
          case '!=':
            return v == null || !_equal(v, c.value);
          default:
            final a = _num(v);
            final b = _num(c.value);
            return a != null && b != null && _compare(a, c.op, b);
        }
    }
    return false;
  }

  static bool _compare(num a, String op, num b) => switch (op) {
        '=' => a == b,
        '!=' => a != b,
        '>' => a > b,
        '>=' => a >= b,
        '<' => a < b,
        '<=' => a <= b,
        _ => false,
      };

  static num? _num(Object? v) => switch (v) {
        final num n => n,
        final String s => num.tryParse(s),
        _ => null,
      };

  static String _str(Object v) => v is double && v == v.truncateToDouble() ? '${v.toInt()}' : '$v';

  static bool _equal(Object a, Object? b) {
    final x = _num(a);
    final y = _num(b);
    if (x != null && y != null) return x == y;
    return b != null && _str(a) == _str(b);
  }

  static DateTime? _later(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  /// Wakes up when a session_time or since_install condition comes true.
  void _scheduleTimer(DateTime now) {
    _timer?.cancel();
    _timer = null;
    DateTime? next;
    for (final m in _messages) {
      for (final group in m.triggers) {
        for (final c in group) {
          if (c.op != '>=') continue;
          final secs = Duration(seconds: (c.value as num).toInt());
          final at = switch (c.kind) {
            'session_time' => _sessionStart.add(secs),
            'since_install' => (_installedAt ?? now).add(secs),
            _ => null,
          };
          if (at != null && at.isAfter(now) && (next == null || at.isBefore(next))) next = at;
        }
      }
    }
    nextTimeCheck = next;
    if (next != null && next.difference(now) <= const Duration(hours: 24)) {
      _timer = Timer(next.difference(now), check);
    }
  }

  // ---- events

  void _queueEvent(String messageId, String type, {String? buttonId}) {
    final now = _now();
    // Microseconds keep seq growing even if saved state is lost and the
    // device keeps its id.
    _seq = math.max(_seq + 1, now.microsecondsSinceEpoch);
    _events.add({
      'message_id': messageId,
      'type': type,
      if (buttonId != null) 'button_id': buttonId,
      'seq': _seq,
      'at': now.toUtc().toIso8601String(),
    });
    if (_events.length > 500) _events = _events.sublist(_events.length - 500);
    unawaited(_save());
    final delay = eventDelay;
    if (delay != null) {
      _eventTimer?.cancel();
      _eventTimer = Timer(delay, () => unawaited(flushEvents()));
    }
  }

  /// Sends queued events now. Never throws; failures keep them for later.
  Future<void> flushEvents() => _sending ??= _sendEvents().whenComplete(() => _sending = null);

  Future<void> _sendEvents() async {
    while (_events.isNotEmpty) {
      final c = credentials();
      if (c == null) return;
      final batch = _events.take(100).toList();
      try {
        await api.sendInAppEvents(c.deviceId, c.secret, batch);
      } on DakApiException catch (e) {
        if (!e.isPermanent) return; // offline-ish or re-registering: later
        _log('dak: in-app events refused, dropping them: $e');
      } catch (e) {
        _log('dak: in-app events not sent yet: $e');
        return;
      }
      // By identity: the list may have changed meanwhile (a reload merged
      // saved events in front).
      final sent = Set<Object>.identity()..addAll(batch);
      _events = [for (final e in _events) if (!sent.contains(e)) e];
      await _save();
    }
  }

  // ---- persistence

  /// A read that fails (a locked iPhone) leaves the controller running from
  /// memory without saving, so the saved state is not replaced; the next
  /// resume reads it again and keeps what happened meanwhile.
  Future<void> _load() async {
    try {
      final raw = await storage.read();
      _canSave = true;
      _restore(raw);
    } catch (e) {
      _log('dak: in-app state not readable yet, running from memory: $e');
    }
    _loadTried = true;
  }

  Future<void> _reload() => _reloading ??= _reloadOnce().whenComplete(() => _reloading = null);

  Future<void> _reloadOnce() async {
    final String? raw;
    try {
      raw = await storage.read();
    } catch (e) {
      _log('dak: in-app state still not readable: $e');
      return;
    }
    if (_canSave) return;
    final mem = (
      raw: _raw,
      etag: _etag,
      fetchedAt: _fetchedAt,
      local: _local,
      sessions: _sessions,
      installedAt: _installedAt,
      events: _events,
      seq: _seq,
    );
    _reset();
    _restore(raw);
    // Keep what happened while it could not be read: sessions and shows
    // continue the saved counts, events are still sent.
    final before = _sessions;
    _sessions += mem.sessions;
    mem.local.forEach((id, l) {
      final saved = _local[id];
      _local[id] = _Local(
        shown: (saved?.shown ?? 0) + l.shown,
        last: _later(saved?.last, l.last),
        session: l.session > 0 ? l.session + before : (saved?.session ?? 0),
      );
    });
    _installedAt ??= mem.installedAt;
    _events = [..._events, ...mem.events];
    if (_events.length > 500) _events = _events.sublist(_events.length - 500);
    _seq = math.max(_seq, mem.seq);
    if (mem.fetchedAt != null) {
      _raw = mem.raw;
      _etag = mem.etag;
      _fetchedAt = mem.fetchedAt;
      _messages = _parse(_raw);
    }
    _canSave = true;
    await _save();
    _evaluate();
  }

  void _reset() {
    _raw = [];
    _etag = null;
    _fetchedAt = null;
    _local = {};
    _sessions = 0;
    _installedAt = null;
    _events = [];
    _seq = 0;
    _messages = [];
  }

  /// Unreadable parts of the saved state are left out, never all of it.
  void _restore(String? raw) {
    if (raw == null || raw.isEmpty) return;
    final Object? js;
    try {
      js = jsonDecode(raw);
    } catch (e) {
      _log('dak: ignoring unreadable in-app state: $e');
      return;
    }
    if (js is! Map) return;
    DateTime? time(Object? v) => v is String ? DateTime.tryParse(v) : null;
    final messages = js['messages'];
    _raw = messages is List ? messages : [];
    _etag = js['etag'] is String ? js['etag'] as String : null;
    _fetchedAt = time(js['fetched_at']);
    final local = js['local'];
    _local = {
      if (local is Map)
        for (final e in local.entries)
          if (e.value is Map) '${e.key}': _Local.fromJson(e.value as Map),
    };
    _sessions = js['sessions'] is num ? (js['sessions'] as num).toInt() : 0;
    _installedAt = time(js['installed_at']);
    final events = js['events'];
    _events = [
      if (events is List)
        for (final e in events)
          if (e is Map) {for (final f in e.entries) '${f.key}': f.value},
    ];
    _seq = js['seq'] is num ? (js['seq'] as num).toInt() : 0;
    _messages = _parse(_raw);
  }

  /// Saving can fail (a locked keystore); the state then lives in memory
  /// until the next save works.
  Future<void> _save() async {
    if (!_canSave) return;
    try {
      await storage.write(jsonEncode({
        'v': 1,
        'messages': _raw,
        'etag': _etag,
        'fetched_at': _fetchedAt?.toIso8601String(),
        'local': _local.map((k, v) => MapEntry(k, v.toJson())),
        'sessions': _sessions,
        'installed_at': _installedAt?.toIso8601String(),
        'events': _events,
        'seq': _seq,
      }));
    } catch (e) {
      _log('dak: could not save in-app state: $e');
    }
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _eventTimer?.cancel();
    await _clicks.close();
    current.dispose();
  }
}
