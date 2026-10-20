/// A push notification as the app sees it.
class DakNotification {
  const DakNotification({
    this.id,
    this.title,
    this.body,
    this.url,
    this.data = const {},
  });

  /// Dak's message id, or null for pushes not sent through Dak.
  final String? id;
  final String? title;
  final String? body;

  /// The deep link given when the message was sent (`url`), if any.
  final String? url;

  /// The message's data, without Dak's own `_dak_` keys.
  final Map<String, String> data;

  static const idKey = '_dak_id';
  static const urlKey = '_dak_url';

  /// Builds a notification from an FCM data map and notification fields.
  factory DakNotification.fromData(
    Map<String, dynamic> raw, {
    String? title,
    String? body,
  }) {
    final data = <String, String>{};
    raw.forEach((k, v) {
      if (!k.startsWith('_dak_') && v != null) data[k] = v.toString();
    });
    return DakNotification(
      id: raw[idKey]?.toString(),
      url: raw[urlKey]?.toString(),
      title: title,
      body: body,
      data: data,
    );
  }

  @override
  String toString() => 'DakNotification(id: $id, title: $title, url: $url, data: $data)';
}
