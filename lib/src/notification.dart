import 'dart:convert';

/// A notification button, as the message was sent.
class DakButton {
  /// Creates a button; the SDK makes them from the message.
  const DakButton({required this.id, required this.text, this.url});

  /// The button's id, as [DakNotification.actionId] reports a tap on it.
  final String id;

  /// The button's label.
  final String text;

  /// The deep link for this button, if it has its own.
  final String? url;

  @override
  String toString() => 'DakButton($id)';
}

/// A push notification as the app sees it.
class DakNotification {
  /// Creates a notification; the SDK makes them from FCM messages.
  const DakNotification({
    this.id,
    this.title,
    this.body,
    this.url,
    this.imageUrl,
    this.data = const {},
    this.buttons = const [],
    this.actionId,
    this.raw = const {},
  });

  /// Dak's message id, or null for pushes not sent through Dak.
  final String? id;

  /// The title, or null for a silent push.
  final String? title;

  /// The text, or null for a silent push.
  final String? body;

  /// The deep link: the tapped button's own URL if it has one, otherwise the
  /// message's `url`.
  final String? url;

  /// The notification's image (`image` when it was sent), if any.
  final String? imageUrl;

  /// The message's data, without Dak's own `_dak_` keys.
  final Map<String, String> data;

  /// The message's buttons.
  final List<DakButton> buttons;

  /// The id of the button the user tapped, or null for a tap on the
  /// notification itself (and for messages that were not opened).
  final String? actionId;

  /// The FCM data as it came, with Dak's keys.
  final Map<String, String> raw;

  /// The data key of Dak's message id.
  static const idKey = '_dak_id';

  /// The data key of the message's deep link.
  static const urlKey = '_dak_url';

  /// The data key of the buttons, as JSON.
  static const buttonsKey = '_dak_buttons';

  /// A silent (data only) push has neither title nor body.
  bool get isSilent => title == null && body == null;

  /// Builds a notification from an FCM data map and notification fields.
  /// Android notifications the SDK shows itself (those with buttons) carry
  /// their title, body and image in the data.
  factory DakNotification.fromData(
    Map<String, dynamic> raw, {
    String? title,
    String? body,
    String? imageUrl,
    String? actionId,
  }) {
    final all = <String, String>{};
    final data = <String, String>{};
    raw.forEach((k, v) {
      if (v == null) return;
      all[k] = v.toString();
      if (!k.startsWith('_dak_')) data[k] = v.toString();
    });
    final buttons = parseButtons(all[buttonsKey]);
    var url = all[urlKey];
    if (actionId != null) {
      for (final b in buttons) {
        if (b.id == actionId && b.url != null) url = b.url;
      }
    }
    return DakNotification(
      id: all[idKey],
      url: url,
      title: title ?? all['_dak_title'],
      body: body ?? all['_dak_body'],
      imageUrl: imageUrl ?? all['_dak_image'],
      data: data,
      buttons: buttons,
      actionId: actionId,
      raw: all,
    );
  }

  /// The same notification, opened with [actionId].
  DakNotification withAction(String? actionId) => DakNotification.fromData(
        raw,
        title: title,
        body: body,
        imageUrl: imageUrl,
        actionId: actionId,
      );

  /// Reads the buttons from their JSON; an empty list when there are none or
  /// the JSON is bad.
  static List<DakButton> parseButtons(String? json) {
    if (json == null || json.isEmpty) return const [];
    try {
      final list = jsonDecode(json) as List;
      return [
        for (final b in list.cast<Map<String, dynamic>>())
          DakButton(id: b['id'] as String, text: b['text'] as String? ?? '', url: b['url'] as String?),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  String toString() => 'DakNotification(id: $id, title: $title, url: $url, action: $actionId, data: $data)';
}
