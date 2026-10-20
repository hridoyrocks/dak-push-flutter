import 'dart:ui' show Color;

/// How an in-app message is laid out on screen.
enum DakInAppLayout {
  /// A centred dialog over a dimmed app.
  modal('modal'),

  /// A banner at the top; the app stays usable.
  bannerTop('banner_top'),

  /// A banner at the bottom; the app stays usable.
  bannerBottom('banner_bottom'),

  /// A page that covers the app.
  fullscreen('fullscreen'),

  /// A card that slides up from the bottom.
  card('card');

  /// A layout with its name on the wire.
  const DakInAppLayout(this.wire);

  /// The name the server uses, like `banner_top`.
  final String wire;

  /// Whether this is a top or bottom banner.
  bool get isBanner => this == bannerTop || this == bannerBottom;

  /// The layout with this wire name, or null for one this SDK does not know.
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
  /// Creates an action of [type].
  const DakInAppAction({required this.type, this.url, this.tags = const {}});

  /// deep_link | url | tags | dismiss | custom
  final String type;

  /// For `deep_link` and `url`: the link.
  final String? url;

  /// For `tags`: tags to set; an empty value removes the tag.
  final Map<String, String> tags;

  /// The action types this SDK knows.
  static const types = {'deep_link', 'url', 'tags', 'dismiss', 'custom'};

  /// Reads an action from JSON; null for an unknown type.
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

/// A button on an in-app message.
class DakInAppButton {
  /// Creates a button.
  const DakInAppButton(
      {required this.id, required this.text, required this.action, this.backgroundColor, this.textColor});

  /// The click id: reported in `Dak.onInAppClick` and counted in the stats.
  final String id;

  /// The button's label.
  final String text;

  /// What a tap on the button does.
  final DakInAppAction action;

  /// The button's colour; null takes the theme's.
  final Color? backgroundColor;

  /// The label's colour; null picks one that reads on the background.
  final Color? textColor;
}

/// What an in-app message shows.
class DakInAppContent {
  /// Creates the content.
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

  /// The title, if any.
  final String? title;

  /// The text, if any.
  final String? body;

  /// The image, loaded before the message shows.
  final String? imageUrl;

  /// The message's background; null takes the theme's.
  final Color? backgroundColor;

  /// The title's colour; null picks one that reads on the background.
  final Color? titleColor;

  /// The text's colour; null picks one that reads on the background.
  final Color? bodyColor;

  /// Whether the message has an X. A fullscreen message with no other way out
  /// gets one anyway.
  final bool closeButton;

  /// Banners only: closes by itself after this long.
  final Duration? autoDismiss;

  /// What tapping the message itself does.
  final DakInAppAction? clickAction;

  /// The buttons, at most three.
  final List<DakInAppButton> buttons;

  /// Whether there is a title or text to show without the image.
  bool get hasText => (title?.trim().isNotEmpty ?? false) || (body?.trim().isNotEmpty ?? false);

  /// The same content without the image, for when it failed to load.
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

/// One condition of an in-app message's trigger. A message's
/// [DakInAppMessage.triggers] are groups of these.
class DakInAppCondition {
  /// Creates a condition.
  const DakInAppCondition({required this.kind, required this.op, this.key, this.value, this.values = const []});

  /// session_count | session_time | since_install | custom
  final String kind;

  /// The comparison: `=`, `!=`, `>`, `>=`, `<`, `<=`, and for custom triggers
  /// also `in`, `exists` and `not_exists`.
  final String op;

  /// For custom conditions: the trigger key set with `Dak.addTrigger`.
  final String? key;

  /// The value to compare with: a count, seconds, or the trigger value.
  final Object? value;

  /// For `in`: the values that match.
  final List<String> values;

  static const _ops = {
    'session_count': {'=', '!=', '>', '>=', '<', '<='},
    'session_time': {'>=', '<'},
    'since_install': {'>=', '<'},
    'custom': {'=', '!=', '>', '>=', '<', '<=', 'in', 'exists', 'not_exists'},
  };

  /// Reads a condition from JSON; null for a kind or comparison this SDK does
  /// not know.
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
  /// Creates a frequency.
  const DakInAppFrequency({required this.type, this.interval = Duration.zero, this.maxDisplays});

  /// once | every_session | interval
  final String type;

  /// For `interval`: the time between two showings.
  final Duration interval;

  /// At most this many showings in all; null for no limit.
  final int? maxDisplays;

  /// Reads a frequency from JSON; null for a type this SDK does not know.
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
  /// Creates a message; the SDK reads them with [parse].
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

  /// The message's id.
  final String id;

  /// How the message is laid out.
  final DakInAppLayout layout;

  /// What the message shows.
  final DakInAppContent content;

  /// OR-ed groups of AND-ed conditions; empty means "when the app opens".
  final List<List<DakInAppCondition>> triggers;

  /// How often this device may see the message.
  final DakInAppFrequency frequency;

  /// When several messages are due, the highest priority shows first.
  final int priority;

  /// Not shown before this time.
  final DateTime? startAt;

  /// Not shown after this time.
  final DateTime? endAt;

  /// How often the server has counted this device showing it.
  final int shown;

  /// When the server last counted this device showing it.
  final DateTime? lastShownAt;

  /// The same message with other [content].
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
  /// Creates a click.
  const DakInAppClick({required this.messageId, required this.action, this.buttonId});

  /// The message that was tapped.
  final String messageId;

  /// The button's id, or null when the message itself was tapped.
  final String? buttonId;

  /// What the tap did.
  final DakInAppAction action;

  /// deep_link | url | tags | dismiss | custom
  String get actionType => action.type;

  /// For deep_link and url actions.
  String? get url => action.url;

  @override
  String toString() => 'DakInAppClick($messageId, $buttonId, ${action.type}${url == null ? '' : ' $url'})';
}
