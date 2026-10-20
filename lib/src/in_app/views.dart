import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'model.dart';

/// The image of [m], decoded at about the size it is drawn rather than the
/// file's full size. The host precaches the same provider.
ImageProvider dakInAppImage(BuildContext context, DakInAppMessage m) {
  final screen = MediaQuery.sizeOf(context);
  final logical = switch (m.layout) {
    DakInAppLayout.modal => math.min(screen.width - 48, 400.0),
    // Wide images fill the card's 200-high box by its height.
    DakInAppLayout.card => math.min(screen.width, 600.0) * 1.5,
    // BoxFit.cover in a tall box: the longer side of the screen.
    DakInAppLayout.fullscreen => math.max(screen.width, screen.height),
    DakInAppLayout.bannerTop || DakInAppLayout.bannerBottom => 96.0,
  };
  final width = (math.max(logical, 48.0) * MediaQuery.devicePixelRatioOf(context)).round();
  return ResizeImage(NetworkImage(m.content.imageUrl!), width: width, allowUpscaling: false);
}

/// Draws one in-app message in its layout with plain Flutter widgets.
/// Colours the message leaves out come from the app's theme.
class DakInAppView extends StatefulWidget {
  /// Draws [message]; [onClick] and [onDismiss] report what the user did.
  const DakInAppView({super.key, required this.message, required this.onClick, required this.onDismiss});

  /// The message to draw.
  final DakInAppMessage message;

  /// A button, or null for a tap on the message itself.
  final void Function(DakInAppButton? button) onClick;

  /// The user closed the message (the X, a tap outside, a swipe, back, or
  /// auto-dismiss).
  final VoidCallback onDismiss;

  @override
  State<DakInAppView> createState() => _DakInAppViewState();
}

class _DakInAppViewState extends State<DakInAppView> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  // Made once: a CurvedAnimation listens to its parent until disposed.
  late final _curve = CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic);
  late final _scale = Tween(begin: 0.92, end: 1.0).animate(_curve);
  late final _fromTop = Tween(begin: const Offset(0, -1), end: Offset.zero).animate(_curve);
  late final _fromBottom = Tween(begin: const Offset(0, 1), end: Offset.zero).animate(_curve);
  Timer? _auto;
  bool _started = false;

  DakInAppMessage get m => widget.message;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.maybeOf(context);
    if (!_started) {
      _started = true;
      // Reduced motion: no slide or fade.
      if (media?.disableAnimations ?? false) {
        _anim.value = 1;
      } else {
        _anim.forward();
      }
    }
    // Screen reader users need the time it takes to find the banner: no
    // auto-dismiss for them.
    final after = m.content.autoDismiss;
    final reading = media?.accessibleNavigation ?? false;
    if (!m.layout.isBanner || after == null || reading) {
      _auto?.cancel();
      _auto = null;
    } else {
      _auto ??= Timer(after, widget.onDismiss);
    }
  }

  @override
  void dispose() {
    _auto?.cancel();
    _curve.dispose();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _Parts(context, m, widget.onClick, widget.onDismiss);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;

    final Widget view = switch (m.layout) {
      DakInAppLayout.modal => _Backdrop(
          onTap: widget.onDismiss,
          child: p.dialog(
            Padding(
              padding: EdgeInsets.only(bottom: keyboard),
              child: Center(child: ScaleTransition(scale: _scale, child: p.modal())),
            ),
          ),
        ),
      DakInAppLayout.card => _Backdrop(
          onTap: widget.onDismiss,
          child: p.dialog(
            Padding(
              padding: EdgeInsets.only(bottom: keyboard),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: SlideTransition(position: _fromBottom, child: p.card()),
              ),
            ),
          ),
        ),
      DakInAppLayout.fullscreen => BlockSemantics(child: p.dialog(p.fullscreen())),
      DakInAppLayout.bannerTop => SlideTransition(position: _fromTop, child: p.announced(p.banner(top: true))),
      DakInAppLayout.bannerBottom => Padding(
          padding: EdgeInsets.only(bottom: keyboard),
          child: SlideTransition(position: _fromBottom, child: p.announced(p.banner(top: false))),
        ),
    };
    // Escape (and the platform's other dismiss keys) closes the message;
    // modal layouts take the focus like a dialog.
    return Shortcuts(
      shortcuts: const {SingleActivator(LogicalKeyboardKey.escape): DismissIntent()},
      child: Actions(
        actions: {DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) => widget.onDismiss())},
        child: FocusScope(
          autofocus: !m.layout.isBanner,
          child: KeyedSubtree(
            key: Key('dak-in-app-${m.layout.wire}'),
            child: FadeTransition(opacity: _curve, child: view),
          ),
        ),
      ),
    );
  }
}

/// Dims the app behind a modal or card; a tap on it closes the message.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => BlockSemantics(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Semantics(
              label: _localizations(context)?.modalBarrierDismissLabel ?? 'Dismiss',
              onTap: onTap,
              child: GestureDetector(
                key: const Key('dak-in-app-backdrop'),
                excludeFromSemantics: true,
                onTap: onTap,
                child: const ColoredBox(color: Color(0x8A000000)),
              ),
            ),
            child,
          ],
        ),
      );
}

/// Material's strings when the app has them (a host outside MaterialApp may
/// not).
MaterialLocalizations? _localizations(BuildContext context) =>
    Localizations.of<MaterialLocalizations>(context, MaterialLocalizations);

class _Parts {
  _Parts(this.context, this.m, this.onClick, this.onDismiss)
      : scheme = Theme.of(context).colorScheme,
        text = Theme.of(context).textTheme,
        size = MediaQuery.sizeOf(context);

  final BuildContext context;
  final DakInAppMessage m;
  final void Function(DakInAppButton?) onClick;
  final VoidCallback onDismiss;
  final ColorScheme scheme;
  final TextTheme text;
  final Size size;

  DakInAppContent get c => m.content;
  Color get background => c.backgroundColor ?? scheme.surface;

  /// Text on the message's background: the theme's colour on the theme's
  /// surface; black or white, whichever reads, on a background the message
  /// sets.
  Color get onBackground => c.backgroundColor == null ? scheme.onSurface : _readableOn(c.backgroundColor!);
  Color get onBackgroundVariant =>
      c.backgroundColor == null ? scheme.onSurfaceVariant : onBackground.withAlpha(0xC0);

  static Color _readableOn(Color bg) =>
      ThemeData.estimateBrightnessForColor(bg) == Brightness.dark ? Colors.white : const Color(0xDE000000);

  String get closeLabel => _localizations(context)?.closeButtonTooltip ?? 'Close';

  /// A modal layout as screen readers know dialogs: its own route, named by
  /// its title, closed by their dismiss gesture.
  Widget dialog(Widget child) => Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: hasTitle ? c.title : (hasBody ? c.body : null),
        onDismiss: onDismiss,
        child: child,
      );

  /// A banner is read out when it appears (Android's live region).
  Widget announced(Widget child) => Semantics(
        container: true,
        liveRegion: true,
        onDismiss: onDismiss,
        child: child,
      );
  bool get hasImage => c.imageUrl?.isNotEmpty ?? false;
  bool get hasTitle => c.title?.trim().isNotEmpty ?? false;
  bool get hasBody => c.body?.trim().isNotEmpty ?? false;

  /// The X, also when the message turned it off but has no other way out (a
  /// fullscreen message with no buttons and nothing to tap; iOS has no back
  /// button).
  bool get showClose =>
      c.closeButton || (m.layout == DakInAppLayout.fullscreen && c.buttons.isEmpty && c.clickAction == null);

  Widget title({TextAlign align = TextAlign.center, TextStyle? style, int? maxLines}) => Text(
        c.title!,
        textAlign: align,
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
        style: (style ?? text.titleLarge)?.copyWith(color: c.titleColor ?? onBackground, fontWeight: FontWeight.w600),
      );

  Widget body({TextAlign align = TextAlign.center, int? maxLines}) => Text(
        c.body!,
        textAlign: align,
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
        style: text.bodyMedium?.copyWith(color: c.bodyColor ?? onBackgroundVariant),
      );

  Widget image({double? height, double? width}) {
    final img = Image(
      image: dakInAppImage(context, m),
      key: const Key('dak-in-app-image'),
      height: height,
      width: width,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
    if (c.clickAction == null) return img;
    return GestureDetector(onTap: () => onClick(null), child: img);
  }

  Widget close({Color? color}) => Material(
        key: const Key('dak-in-app-close'),
        type: MaterialType.circle,
        color: hasImage ? const Color(0x42000000) : Colors.transparent,
        child: IconButton(
          // No tooltip: the host sits above the Navigator, without an Overlay.
          icon: Icon(Icons.close, size: 20, semanticLabel: closeLabel),
          color: hasImage ? Colors.white : (color ?? c.titleColor ?? onBackground),
          visualDensity: VisualDensity.compact,
          onPressed: onDismiss,
        ),
      );

  Widget button(DakInAppButton b, {required bool primary}) {
    final bg = b.backgroundColor ?? (primary ? scheme.primary : null);
    final fg = b.textColor ??
        (b.backgroundColor != null
            ? _readableOn(b.backgroundColor!)
            : primary
                ? scheme.onPrimary
                // A text button on the message's own background.
                : (c.backgroundColor == null ? scheme.primary : onBackground));
    final label = Text(b.text, maxLines: 1, overflow: TextOverflow.ellipsis);
    final key = Key('dak-in-app-button-${b.id}');
    if (bg != null) {
      return FilledButton(
        key: key,
        style: FilledButton.styleFrom(backgroundColor: bg, foregroundColor: fg),
        onPressed: () => onClick(b),
        child: label,
      );
    }
    return TextButton(key: key, style: TextButton.styleFrom(foregroundColor: fg), onPressed: () => onClick(b), child: label);
  }

  /// One or two buttons side by side, three stacked.
  Widget buttons() {
    final list = [for (var i = 0; i < c.buttons.length; i++) button(c.buttons[i], primary: i == 0)];
    if (list.length <= 2) {
      return Row(children: [
        for (var i = 0; i < list.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: list[i]),
        ],
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < list.length; i++) ...[
        if (i > 0) const SizedBox(height: 8),
        list[i],
      ],
    ]);
  }

  /// Title, body and buttons, centred.
  Widget texts({EdgeInsets padding = const EdgeInsets.fromLTRB(20, 20, 20, 16)}) => Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasTitle) title(),
            if (hasTitle && hasBody) const SizedBox(height: 8),
            if (hasBody) body(),
            if (c.buttons.isNotEmpty) ...[const SizedBox(height: 20), buttons()],
          ],
        ),
      );

  Widget _withClose(Widget child, {double top = 4}) => Stack(children: [
        child,
        if (showClose) PositionedDirectional(top: top, end: 4, child: close()),
      ]);

  Widget _tappable(Widget child) => c.clickAction == null ? child : InkWell(onTap: () => onClick(null), child: child);

  Widget modal() => Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 400, maxHeight: size.height * 0.85),
          child: Material(
            color: background,
            elevation: 8,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: _withClose(SingleChildScrollView(
              child: _tappable(Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (hasImage) ConstrainedBox(constraints: const BoxConstraints(maxHeight: 240), child: image()),
                  texts(padding: EdgeInsets.fromLTRB(20, hasImage ? 20 : 36, 20, 16)),
                ],
              )),
            )),
          ),
        ),
      );

  Widget card() => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 600, maxHeight: size.height * 0.9),
        child: Material(
          color: background,
          elevation: 8,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: _withClose(SingleChildScrollView(
              child: _tappable(Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (hasImage) image(height: 200) else const SizedBox(height: 16),
                  texts(),
                ],
              )),
            ), top: 8),
          ),
        ),
      );

  Widget fullscreen() => Material(
        color: background,
        child: SafeArea(
          child: _withClose(
            _tappable(Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (hasImage) Expanded(flex: 5, child: image()),
                Expanded(
                  flex: 4,
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        if (hasTitle) title(style: text.headlineSmall),
                        if (hasTitle && hasBody) const SizedBox(height: 12),
                        if (hasBody) body(),
                      ]),
                    ),
                  ),
                ),
                if (c.buttons.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), child: buttons()),
              ],
            )),
          ),
        ),
      );

  /// A slim banner; the app behind it stays usable.
  Widget banner({required bool top}) => SafeArea(
        child: Align(
          alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Dismissible(
                key: ValueKey('dak-in-app-swipe-${m.id}'),
                direction: top ? DismissDirection.up : DismissDirection.down,
                onDismissed: (_) => onDismiss(),
                child: Material(
                  color: background,
                  elevation: 6,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: _tappable(Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 4, 10),
                    child: Row(children: [
                      if (hasImage) ...[
                        ClipRRect(borderRadius: BorderRadius.circular(10), child: image(height: 48, width: 48)),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (hasTitle) title(align: TextAlign.start, style: text.titleSmall, maxLines: 2),
                            if (hasTitle && hasBody) const SizedBox(height: 2),
                            if (hasBody) body(align: TextAlign.start, maxLines: 3),
                          ],
                        ),
                      ),
                      if (showClose) _bannerClose() else const SizedBox(width: 8),
                    ]),
                  )),
                ),
              ),
            ),
          ),
        ),
      );

  Widget _bannerClose() => IconButton(
        key: const Key('dak-in-app-close'),
        icon: Icon(Icons.close, size: 18, semanticLabel: closeLabel),
        color: c.titleColor ?? onBackgroundVariant,
        visualDensity: VisualDensity.compact,
        onPressed: onDismiss,
      );
}
