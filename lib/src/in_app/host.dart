import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../dak.dart';
import 'controller.dart';
import 'model.dart';
import 'views.dart';

/// Loads an image before a message shows; false when it could not load.
typedef DakImageLoader = Future<bool> Function(BuildContext context, String url);

/// Where in-app messages appear: above all of the app's pages. Put it in
/// MaterialApp's builder:
///
/// ```dart
/// MaterialApp(builder: Dak.inAppBuilder, ...)
/// // or, with a builder of your own:
/// MaterialApp(builder: (context, child) => DakInAppHost(child: myBuilder(context, child)))
/// ```
class DakInAppHost extends StatefulWidget {
  const DakInAppHost({super.key, required this.child, this.controller, this.imageLoader});

  final Widget child;

  /// Defaults to the one `Dak.init` made.
  final DakInAppController? controller;

  /// Defaults to precaching the network image (5 s at most).
  final DakImageLoader? imageLoader;

  @override
  State<DakInAppHost> createState() => _DakInAppHostState();
}

class _DakInAppHostState extends State<DakInAppHost> {
  DakInAppController? _c;
  DakInAppMessage? _shown;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(DakInAppHost old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) _bind();
  }

  @override
  void dispose() {
    _c?.current.removeListener(_changed);
    _c?.detach();
    super.dispose();
  }

  void _bind() {
    final c = widget.controller ?? Dak.inAppController;
    if (c == null || identical(c, _c)) return;
    _c?.current.removeListener(_changed);
    _c?.detach();
    _c = c;
    _shown = null;
    c.current.addListener(_changed);
    // Attaching may pick a message at once; do it outside this build.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_c, c)) c.attach();
    });
  }

  /// Changes can come while the tree is being built (a DakInAppBlock that
  /// appears or goes away), so they are applied after the frame then.
  void _changed() {
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _apply());
      SchedulerBinding.instance.ensureVisualUpdate();
    } else {
      _apply();
    }
  }

  Future<void> _apply() async {
    final c = _c;
    if (!mounted || c == null) return;
    final token = ++_token;
    final m = c.current.value;
    if (m == null) {
      if (_shown != null) setState(() => _shown = null);
      return;
    }
    var show = m;
    final url = m.content.imageUrl;
    if (url != null && url.isNotEmpty) {
      final ok = await (widget.imageLoader ?? _precache)(context, url);
      if (!mounted || token != _token || c.current.value?.id != m.id) return;
      if (!ok) {
        if (!m.content.hasText) {
          c.didFail(m);
          return;
        }
        show = m.copyWith(content: m.content.withoutImage());
      }
    }
    setState(() => _shown = show);
    // Counted once a frame shows it; an app in the background draws none.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_c, c) && token == _token && c.current.value?.id == m.id) c.didDisplay(m);
    });
  }

  static Future<bool> _precache(BuildContext context, String url) async {
    var ok = true;
    try {
      await precacheImage(NetworkImage(url), context, onError: (_, __) => ok = false)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      ok = false;
    }
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    if (_c == null) _bind(); // Dak.init ran after this host was built
    final c = _c;
    final m = _shown;
    return Stack(
      fit: StackFit.expand,
      alignment: Alignment.topLeft,
      children: [
        widget.child,
        if (c != null && m != null)
          DakInAppView(
            key: ValueKey('dak-in-app-${m.id}'),
            message: m,
            onClick: (button) => c.click(m, button),
            onDismiss: () => c.dismiss(m),
          ),
      ],
    );
  }
}

/// Keeps in-app messages away while this widget is in the tree, for screens
/// that must not be covered (a call, a payment). A message on screen is
/// hidden; what is due shows after the screen goes away.
class DakInAppBlock extends StatefulWidget {
  const DakInAppBlock({super.key, required this.child, this.controller});

  final Widget child;
  final DakInAppController? controller;

  @override
  State<DakInAppBlock> createState() => _DakInAppBlockState();
}

class _DakInAppBlockState extends State<DakInAppBlock> {
  DakInAppController? _c;

  @override
  void initState() {
    super.initState();
    _c = widget.controller ?? Dak.inAppController;
    _c?.block();
  }

  @override
  void dispose() {
    _c?.unblock();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
