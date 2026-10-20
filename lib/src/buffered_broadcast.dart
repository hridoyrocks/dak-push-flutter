import 'dart:async';

/// A broadcast stream that keeps events while nobody listens and hands them
/// to the next listener, so a tap that comes before the app subscribes (in
/// main, or while Dak.init runs) is not lost.
class BufferedBroadcast<T> {
  BufferedBroadcast({this.limit = 20}) {
    _ctl = StreamController<T>.broadcast(onListen: _drain);
  }

  /// At most this many events are kept; older ones go first.
  final int limit;
  late final StreamController<T> _ctl;
  final _held = <T>[];

  Stream<T> get stream => _ctl.stream;

  void add(T event) {
    if (_ctl.isClosed) return;
    if (_ctl.hasListener) {
      _ctl.add(event);
      return;
    }
    _held.add(event);
    if (_held.length > limit) _held.removeAt(0);
  }

  // The new listener is registered before onListen runs, so it gets these.
  void _drain() {
    final held = List.of(_held);
    _held.clear();
    held.forEach(_ctl.add);
  }

  Future<void> close() => _ctl.close();
}
