import 'dart:ui' show Color;

/// How an in-app message is laid out on screen.
enum DakInAppLayout {
  modal('modal'),
  bannerTop('banner_top'),
  bannerBottom('banner_bottom'),
  fullscreen('fullscreen'),
  card('card');

  const DakInAppLayout(this.wire);
  final String wire;

  bool get isBanner => this == bannerTop || this == bannerBottom;

  static DakInAppLayout? parse(Object? v) {
    for (final l in values) {
      if (l.wire == v) return l;
    }
    return null;
  }
}

/// What a click does. Every click also closes the message and is reported
/// through `Dak.onInAppClick`.
class DakInAppAction {
  const DakInAppAction({required this.type, this.url, this.tags = const {}});

  /// deep_link | url | tags | dismiss | custom
  final String type;
  final String? url;

  /// For `tags`: tags to set; an empty value removes the tag.
  final Map<String, String> tags;

  static const types = {'deep_link', 'url', 'tags', 'dismiss', 'custom'};

  static DakInAppAction? parse(Object? js) {
    if (js is! Map) return null;
    final type = js['type'];
    if (type is! String || !types.contains(type)) return null;
    final tags = js['tags'];
    return DakInAppAction(
      type: type,
      url: js['url'] as String?,
      tags: tags is Map ? tags.map((k, v) => MapEntry('$k', '${v ?? ''}')) : const {},
    );
  }
}

class DakInAppButton {
  const DakInAppButton({required this.id, required this.text, required this.action, this.backgroundColor, this.textColor});

  /// The click id: reported in `Dak.onInAppClick` and counted in the stats.
  final String id;
  final String text;
  final DakInAppAction action;
  final Color? backgroundColor;
  final Color? textColor;
}

class DakInAppContent {
  const DakInAppContent({
    this.title,
    this.body,
    this.imageUrl,
    this.backgroundColor,
    this.titleColor,
    this.bodyColor,
    this.closeButton = true,
    this.autoDismiss,
    this.clickAction,
    this.buttons = const [],
  });

  final String? title;
  final String? body;
  final String? imageUrl;
  final Color? backgroundColor;
  final Color? titleColor;
  final Color? bodyColor;
  final bool closeButton;

  /// Banners only: closes by itself after this long.
  final Duration? autoDismiss;

  /// What tapping the message itself does.
  final DakInAppAction? clickAction;
  final List<DakInAppButton> buttons;

  bool get hasText => (title?.trim().isNotEmpty ?? false) || (body?.trim().isNotEmpty ?? false);

  DakInAppContent withoutImage() => DakInAppContent(
        title: title,
        body: body,
        backgroundColor: backgroundColor,
        titleColor: titleColor,
        bodyColor: bodyColor,
        closeButton: closeButton,
        autoDismiss: autoDismiss,
        clickAction: clickAction,
        buttons: buttons,
      );
}

/// One trigger condition; see `docs/IN_APP.md`.
class DakInAppCondition {
  const DakInAppCondition({required this.kind, required this.op, this.key, this.value, this.values = const []});

  /// session_count | session_time | since_install | custom
  final String kind;
  final String op;
  final String? key;
  final Object? value;
  final List<String> values;

  static const _ops = {
    'session_count': {'=', '!=', '>', '>=', '<', '<='},
    'session_time': {'>=', '<'},
    'since_install': {'>=', '<'},
    'custom': {'=', '!=', '>', '>=', '<', '<=', 'in', 'exists', 'not_exists'},
  };

  static DakInAppCondition? parse(Object? js) {
    if (js is! Map) return null;
    final kind = js['kind'];
    final op = js['op'];
    if (kind is! String || op is! String || !(_ops[kind]?.contains(op) ?? false)) return null;
    final values = js['values'];
    final c = DakInAppCondition(
      kind: kind,
      op: op,
      key: js['key'] as String?,
      value: js['value'],
      values: values is List ? values.map((v) => '$v').toList() : const [],
    );
    if (kind == 'custom' && (c.key == null || c.key!.isEmpty)) return null;
    if (kind != 'custom' && c.value is! num) return null;
    return c;
  }
}

/// How often one device may see a message.
class DakInAppFrequency {
  const DakInAppFrequency({required this.type, this.interval = Duration.zero, this.maxDisplays});

  /// once | every_session | interval
  final String type;
  final Duration interval;
  final int? maxDisplays;

  static DakInAppFrequency? parse(Object? js) {
    if (js is! Map) return null;
    final type = js['type'];
    if (type != 'once' && type != 'every_session' && type != 'interval') return null;
    return DakInAppFrequency(
      type: type as String,
      interval: Duration(seconds: (js['interval_seconds'] as num?)?.toInt() ?? 0),
      maxDisplays: (js['max_displays'] as num?)?.toInt(),
    );
  }
}

/// An in-app message as the server sent it.
class DakInAppMessage {
  const DakInAppMessage({
    required this.id,
    required this.layout,
    required this.content,
    this.triggers = const [],
    this.frequency = const DakInAppFrequency(type: 'once'),
    this.priority = 0,
    this.startAt,
    this.endAt,
    this.shown = 0,
    this.lastShownAt,
  });

  final String id;
  final DakInAppLayout layout;
  final DakInAppContent content;

  /// OR-ed groups of AND-ed conditions; empty means "when the app opens".
  final List<List<DakInAppCondition>> triggers;
  final DakInAppFrequency frequency;
  final int priority;
  final DateTime? startAt;
  final DateTime? endAt;

  /// How often the server has counted this device showing it.
  final int shown;
  final DateTime? lastShownAt;

  DakInAppMessage copyWith({DakInAppContent? content}) => DakInAppMessage(
        id: id,
        layout: layout,
        content: content ?? this.content,
        triggers: triggers,
        frequency: frequency,
        priority: priority,
        startAt: startAt,
        endAt: endAt,
        shown: shown,
        lastShownAt: lastShownAt,
      );

  /// Reads a message from the server's JSON. Returns null for anything this
  /// SDK version does not understand (a newer layout, action or trigger) or
  /// cannot read (a field of the wrong type), so it is skipped rather than
  /// shown wrongly. Never throws.
  static DakInAppMessage? parse(Object? js) {
    try {
      return _parse(js);
    } catch (_) {
      return null;
    }
  }

  static DakInAppMessage? _parse(Object? js) {
    if (js is! Map) return null;
    final id = js['id'];
    final layout = DakInAppLayout.parse(js['layout']);
    final c = js['content'];
    final frequency = DakInAppFrequency.parse(js['frequency']);
    if (id is! String || layout == null || c is! Map || frequency == null) return null;

    DakInAppAction? click;
    if (c['click_action'] != null) {
      click = DakInAppAction.parse(c['click_action']);
      if (click == null) return null;
    }
    final buttons = <DakInAppButton>[];
    for (final b in (c['buttons'] as List?) ?? const []) {
      if (b is! Map) return null;
      final action = DakInAppAction.parse(b['action']);
      final bid = b['id'];
      final text = b['text'];
      if (action == null || bid is! String || text is! String) return null;
      buttons.add(DakInAppButton(
        id: bid,
        text: text,
        action: action,
        backgroundColor: parseColor(b['background_color']),
        textColor: parseColor(b['text_color']),
      ));
    }
    final auto = (c['auto_dismiss_seconds'] as num?)?.toInt() ?? 0;
    final content = DakInAppContent(
      title: c['title'] as String?,
      body: c['body'] as String?,
      imageUrl: c['image_url'] as String?,
      backgroundColor: parseColor(c['background_color']),
      titleColor: parseColor(c['title_color']),
      bodyColor: parseColor(c['body_color']),
      closeButton: c['close_button'] as bool? ?? true,
      autoDismiss: auto > 0 ? Duration(seconds: auto) : null,
      clickAction: click,
      buttons: buttons,
    );

    final triggers = <List<DakInAppCondition>>[];
    for (final g in (js['triggers'] as List?) ?? const []) {
      if (g is! List || g.isEmpty) return null;
      final group = <DakInAppCondition>[];
      for (final raw in g) {
        final cond = DakInAppCondition.parse(raw);
        if (cond == null) return null;
        group.add(cond);
      }
      triggers.add(group);
    }

    return DakInAppMessage(
      id: id,
      layout: layout,
      content: content,
      triggers: triggers,
      frequency: frequency,
      priority: (js['priority'] as num?)?.toInt() ?? 0,
      startAt: _time(js['start_at']),
      endAt: _time(js['end_at']),
      shown: (js['shown'] as num?)?.toInt() ?? 0,
      lastShownAt: _time(js['last_shown_at']),
    );
  }

  static DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v) : null;
}

/// `#RRGGBB` or `#AARRGGBB`; null when absent or malformed.
Color? parseColor(Object? v) {
  if (v is! String || !v.startsWith('#')) return null;
  final hex = v.substring(1);
  if (hex.length != 6 && hex.length != 8) return null;
  final n = int.tryParse(hex, radix: 16);
  if (n == null) return null;
  return Color(hex.length == 6 ? 0xFF000000 | n : n);
}

/// A tap on an in-app message or one of its buttons.
class DakInAppClick {
  const DakInAppClick({required this.messageId, required this.action, this.buttonId});

  final String messageId;

  /// The button's id, or null when the message itself was tapped.
  final String? buttonId;
  final DakInAppAction action;

  /// deep_link | url | tags | dismiss | custom
  String get actionType => action.type;

  /// For deep_link and url actions.
  String? get url => action.url;

  @override
  String toString() => 'DakInAppClick($messageId, $buttonId, ${action.type}${url == null ? '' : ' $url'})';
}
