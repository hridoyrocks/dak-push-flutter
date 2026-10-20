import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

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
///
/// It may be built before `Dak.init` finishes. With more than one host in
/// the tree, the first one draws the messages.
class DakInAppHost extends StatefulWidget {
  /// Shows in-app messages above [child].
  const DakInAppHost({super.key, required this.child, this.controller, this.imageLoader});

  /// The app: the child that MaterialApp's builder gets.
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

  /// What the Navigator below last said about handling the back button.
  bool? _navigatorCanPop;
  bool _ownsBack = false;
  FocusNode? _focusBefore;

  @override
  void initState() {
    super.initState();
    dakInAppControllers.addListener(_bind);
    _bind();
  }

  @override
  void didUpdateWidget(DakInAppHost old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) _bind();
  }

  @override
  void dispose() {
    dakInAppControllers.removeListener(_bind);
    _unbind();
    super.dispose();
  }

  void _unbind() {
    final c = _c;
    if (c == null) return;
    c.current.removeListener(_changed);
    c.activeHost.removeListener(_changed);
    _c = null;
    c.detach(this);
  }

  /// Binds to the controller given, or to `Dak.init`'s, also when that comes
  /// after this host was built.
  void _bind() {
    final c = widget.controller ?? dakInAppControllers.value;
    if (identical(c, _c)) return;
    _unbind();
    _c = c;
    if (c == null) {
      _changed();
      return;
    }
    c.current.addListener(_changed);
    c.activeHost.addListener(_changed);
    // Attaching may pick a message at once; do it outside this build.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_c, c)) c.attach(this);
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
    if (!mounted) return;
    final c = _c;
    final token = ++_token;
    final m = c != null && identical(c.activeHost.value, this) ? c.current.value : null;
    if (c == null || m == null) {
      if (_shown != null) _show(null);
      return;
    }
    var show = m;
    final url = m.content.imageUrl;
    if (url != null && url.isNotEmpty) {
      final loader = widget.imageLoader;
      final loading = loader != null ? loader(context, url) : _precache(context, m);
      final ok = await loading;
      if (!mounted || token != _token || c.current.value?.id != m.id || !identical(c.activeHost.value, this)) return;
      if (!ok) {
        if (!m.content.hasText) {
          c.didFail(m);
          return;
        }
        show = m.copyWith(content: m.content.withoutImage());
      }
    }
    _show(show);
    // Counted once a frame shows it; an app in the background draws none.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_c, c) && token == _token && c.current.value?.id == m.id && identical(c.activeHost.value, this)) {
        c.didDisplay(m);
      }
    });
  }

  void _show(DakInAppMessage? m) {
    final blocking = m != null && !m.layout.isBanner;
    if (blocking && _shown == null) _focusBefore = FocusManager.instance.primaryFocus;
    setState(() => _shown = m);
    final before = _focusBefore;
    if (m == null && before != null) {
      // Focus goes back where it was before the message took it, once the
      // app is focusable again (after this frame).
      _focusBefore = null;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && (before.context?.mounted ?? false) && before.canRequestFocus) before.requestFocus();
      });
    }
    _claimBack(m != null);
  }

  /// With Android's predictive back the system closes the app when the
  /// Navigator says it cannot pop. While a message is on screen the host
  /// says the app handles back (the SDK closes the message), then repeats
  /// what the Navigator last said.
  void _claimBack(bool claim) {
    if (claim == _ownsBack) return;
    _ownsBack = claim;
    final notification = NavigationNotification(canHandlePop: claim || (_navigatorCanPop ?? false));
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) notification.dispatch(context);
    });
  }

  static Future<bool> _precache(BuildContext context, DakInAppMessage m) async {
    var ok = true;
    try {
      await precacheImage(dakInAppImage(context, m), context, onError: (_, __) => ok = false)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      ok = false;
    }
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final m = _shown;
    final blocking = m != null && !m.layout.isBanner;
    return Stack(
      fit: StackFit.expand,
      alignment: AlignmentDirectional.topStart,
      children: [
        // The same widgets around the app in every state, so it never
        // rebuilds from scratch when a message comes or goes.
        NotificationListener<NavigationNotification>(
          onNotification: (n) {
            _navigatorCanPop = n.canHandlePop;
            return _ownsBack;
          },
          // A modal or full-screen message takes the keyboard focus, like a
          // dialog.
          child: ExcludeFocus(excluding: blocking, child: widget.child),
        ),
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
/// hidden and comes back afterwards; what is due shows after the screen goes
/// away.
class DakInAppBlock extends StatefulWidget {
  /// Keeps in-app messages away while [child] is shown.
  const DakInAppBlock({super.key, required this.child, this.controller});

  /// The screen to keep free of messages.
  final Widget child;

  /// Defaults to the one `Dak.init` made.
  final DakInAppController? controller;

  @override
  State<DakInAppBlock> createState() => _DakInAppBlockState();
}

class _DakInAppBlockState extends State<DakInAppBlock> {
  DakInAppController? _c;

  @override
  void initState() {
    super.initState();
    dakInAppControllers.addListener(_bind);
    _bind();
  }

  @override
  void didUpdateWidget(DakInAppBlock old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) _bind();
  }

  void _bind() {
    final c = widget.controller ?? dakInAppControllers.value;
    if (identical(c, _c)) return;
    _c?.unblock();
    _c = c;
    c?.block();
  }

  @override
  void dispose() {
    dakInAppControllers.removeListener(_bind);
    _c?.unblock();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
