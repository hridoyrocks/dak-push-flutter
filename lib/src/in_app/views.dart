import 'dart:async';

import 'package:flutter/material.dart';

import 'model.dart';

/// Draws one in-app message in its layout with plain Flutter widgets.
/// Colours the message leaves out come from the app's theme.
class DakInAppView extends StatefulWidget {
  const DakInAppView({super.key, required this.message, required this.onClick, required this.onDismiss});

  final DakInAppMessage message;

  /// A button, or null for a tap on the message itself.
  final void Function(DakInAppButton? button) onClick;
  final VoidCallback onDismiss;

  @override
  State<DakInAppView> createState() => _DakInAppViewState();
}

class _DakInAppViewState extends State<DakInAppView> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))..forward();
  Timer? _auto;

  DakInAppMessage get m => widget.message;

  @override
  void initState() {
    super.initState();
    final after = m.content.autoDismiss;
    if (m.layout.isBanner && after != null) _auto = Timer(after, widget.onDismiss);
  }

  @override
  void dispose() {
    _auto?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _Parts(context, m, widget.onClick, widget.onDismiss);
    final curve = CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic);
    Widget slide(Offset from, Widget child) =>
        SlideTransition(position: Tween(begin: from, end: Offset.zero).animate(curve), child: child);

    final Widget view = switch (m.layout) {
      DakInAppLayout.modal => _Backdrop(
          onTap: widget.onDismiss,
          child: Center(child: ScaleTransition(scale: Tween(begin: 0.92, end: 1.0).animate(curve), child: p.modal())),
        ),
      DakInAppLayout.card => _Backdrop(
          onTap: widget.onDismiss,
          child: Align(alignment: Alignment.bottomCenter, child: slide(const Offset(0, 1), p.card())),
        ),
      DakInAppLayout.fullscreen => BlockSemantics(child: p.fullscreen()),
      DakInAppLayout.bannerTop => slide(const Offset(0, -1), p.banner(top: true)),
      DakInAppLayout.bannerBottom => slide(const Offset(0, 1), p.banner(top: false)),
    };
    return KeyedSubtree(
      key: Key('dak-in-app-${m.layout.wire}'),
      child: FadeTransition(opacity: curve, child: view),
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
            GestureDetector(
              key: const Key('dak-in-app-backdrop'),
              onTap: onTap,
              child: const ColoredBox(color: Color(0x8A000000)),
            ),
            child,
          ],
        ),
      );
}

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
  bool get hasImage => c.imageUrl?.isNotEmpty ?? false;
  bool get hasTitle => c.title?.trim().isNotEmpty ?? false;
  bool get hasBody => c.body?.trim().isNotEmpty ?? false;

  Widget title({TextAlign align = TextAlign.center, TextStyle? style, int? maxLines}) => Text(
        c.title!,
        textAlign: align,
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
        style: (style ?? text.titleLarge)?.copyWith(color: c.titleColor ?? scheme.onSurface, fontWeight: FontWeight.w600),
      );

  Widget body({TextAlign align = TextAlign.center, int? maxLines}) => Text(
        c.body!,
        textAlign: align,
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
        style: text.bodyMedium?.copyWith(color: c.bodyColor ?? scheme.onSurfaceVariant),
      );

  Widget image({double? height, double? width}) {
    final img = Image.network(
      c.imageUrl!,
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
          icon: const Icon(Icons.close, size: 20),
          color: hasImage ? Colors.white : (color ?? c.titleColor ?? scheme.onSurface),
          visualDensity: VisualDensity.compact,
          onPressed: onDismiss,
        ),
      );

  Widget button(DakInAppButton b, {required bool primary}) {
    final bg = b.backgroundColor ?? (primary ? scheme.primary : null);
    final fg = b.textColor ?? (primary ? scheme.onPrimary : scheme.primary);
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
        if (c.closeButton) Positioned(top: top, right: 4, child: close()),
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
                    padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
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
                      if (c.closeButton) _bannerClose() else const SizedBox(width: 8),
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
        icon: const Icon(Icons.close, size: 18),
        color: c.titleColor ?? scheme.onSurfaceVariant,
        visualDensity: VisualDensity.compact,
        onPressed: onDismiss,
      );
}
