// Dak's iOS notification service extension.
//
// It runs for every Dak push before iOS shows it, and:
//   • reports the delivery to your Dak server ("delivered" count, webhooks),
//   • adds the push's image,
//   • adds its buttons (as a notification category made on the fly),
//   • counts badge increments.
//
// Setup (details in doc/ios-notification-service-extension.md):
//   1. Xcode → File → New → Target → Notification Service Extension.
//   2. Add this file to that target; in the target's NotificationService.swift
//      write `class NotificationService: DakNotificationService {}`
//      (or set NSExtensionPrincipalClass to DakNotificationService).
//   3. Add the same App Group to the Runner and the extension, and put it in
//      the extension's Info.plist under DakAppGroup.
//   4. Dak.init(..., options: DakOptions(iosAppGroup: 'group.…')).
//
// It needs nothing else: no pods, no Firebase in the extension.

import UserNotifications

open class DakNotificationService: UNNotificationServiceExtension {
  private static let configKey = "dak_push"
  private static let badgeKey = "dak_push_badge"
  private static let categoryPrefix = "dak_"
  private static let maxCategories = 30

  private let lock = NSLock()
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var content: UNMutableNotificationContent?
  private var finished = false

  open override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }
    self.contentHandler = contentHandler
    self.content = content
    let info = content.userInfo
    let defaults = Self.sharedDefaults()
    let group = DispatchGroup()

    if let defaults = defaults {
      applyBadge(info: info, defaults: defaults)
    }
    if let buttons = info["_dak_buttons"] as? String {
      group.enter()
      applyButtons(json: buttons) { group.leave() }
    }
    if let image = Self.imageURL(info) {
      group.enter()
      attachImage(image) { group.leave() }
    }
    if let id = info["_dak_id"] as? String, let defaults = defaults {
      group.enter()
      reportDelivered(messageID: id, defaults: defaults) { group.leave() }
    }
    group.notify(queue: .main) { self.finish() }
  }

  open override func serviceExtensionTimeWillExpire() {
    finish()
  }

  private func finish() {
    lock.lock()
    defer { lock.unlock() }
    guard !finished, let content = content else { return }
    finished = true
    contentHandler?(content)
  }

  private func edit(_ change: (UNMutableNotificationContent) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    if !finished, let content = content { change(content) }
  }

  // MARK: - Shared settings

  private static func sharedDefaults() -> UserDefaults? {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "DakAppGroup") as? String, !group.isEmpty else {
      return nil
    }
    return UserDefaults(suiteName: group)
  }

  // MARK: - Delivery receipt

  private func reportDelivered(messageID: String, defaults: UserDefaults, done: @escaping () -> Void) {
    guard let config = defaults.dictionary(forKey: Self.configKey) as? [String: String],
      let base = config["base_url"], let app = config["app_id"],
      let device = config["device_id"], let token = config["receipt_token"],
      let url = URL(string: "\(base)/v1/apps/\(app)/devices/\(device)/delivered")
    else {
      done()
      return
    }
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // The receipt token can only report deliveries; the device secret stays
    // in the app's keychain.
    request.setValue("Receipt \(token)", forHTTPHeaderField: "Authorization")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["message_id": messageID])
    URLSession.shared.dataTask(with: request) { _, _, _ in done() }.resume()
  }

  // MARK: - Badge

  private func applyBadge(info: [AnyHashable: Any], defaults: UserDefaults) {
    if let raw = info["_dak_badge_inc"] as? String, let inc = Int(raw) {
      let count = max(0, defaults.integer(forKey: Self.badgeKey) + inc)
      defaults.set(count, forKey: Self.badgeKey)
      edit { $0.badge = NSNumber(value: count) }
    } else if let aps = info["aps"] as? [String: Any], let badge = aps["badge"] as? Int {
      defaults.set(badge, forKey: Self.badgeKey)
    }
  }

  // MARK: - Buttons

  private func applyButtons(json: String, done: @escaping () -> Void) {
    guard let data = json.data(using: .utf8),
      let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    else {
      done()
      return
    }
    let actions: [UNNotificationAction] = list.prefix(3).compactMap { b in
      guard let id = b["id"] as? String, let text = b["text"] as? String, !id.isEmpty, !text.isEmpty else {
        return nil
      }
      return UNNotificationAction(identifier: id, title: text, options: [.foreground])
    }
    guard !actions.isEmpty else {
      done()
      return
    }
    // The same buttons get the same category, so few are kept.
    let key = actions.map { "\($0.identifier)\u{1}\($0.title)" }.joined(separator: "\u{2}")
    let id = Self.categoryPrefix + Self.fnv1a(key)
    let category = UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [])
    let center = UNUserNotificationCenter.current()
    center.getNotificationCategories { existing in
      var categories = existing.filter { $0.identifier != id }
      let ours = categories.filter { $0.identifier.hasPrefix(Self.categoryPrefix) }
      if ours.count >= Self.maxCategories {
        // Drop some of Dak's older categories; the app's own stay.
        let drop = Set(ours.prefix(ours.count - Self.maxCategories + 1).map { $0.identifier })
        categories = categories.filter { !drop.contains($0.identifier) }
      }
      categories.insert(category)
      center.setNotificationCategories(categories)
      self.edit { $0.categoryIdentifier = id }
      done()
    }
  }

  /// A hash that is the same in every process (Swift's hashValue is not).
  private static func fnv1a(_ s: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in s.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x100_0000_01b3
    }
    return String(hash, radix: 36)
  }

  // MARK: - Image

  private static func imageURL(_ info: [AnyHashable: Any]) -> URL? {
    // FCM puts the message's apns.fcm_options.image here.
    guard let options = info["fcm_options"] as? [String: Any], let raw = options["image"] as? String,
      let url = URL(string: raw), url.scheme == "https"
    else { return nil }
    return url
  }

  private func attachImage(_ url: URL, done: @escaping () -> Void) {
    URLSession.shared.downloadTask(with: url) { location, response, _ in
      defer { done() }
      guard let location = location else { return }
      let ext: String
      switch (response as? HTTPURLResponse)?.mimeType ?? "" {
      case "image/png": ext = "png"
      case "image/gif": ext = "gif"
      case "image/jpeg", "image/jpg": ext = "jpg"
      default: ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
      }
      let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
      do {
        try FileManager.default.moveItem(at: location, to: file)
        let attachment = try UNNotificationAttachment(identifier: "image", url: file, options: nil)
        self.edit { $0.attachments = [attachment] }
      } catch {
        // Not an image iOS can show: the notification goes without it.
      }
    }.resume()
  }
}
