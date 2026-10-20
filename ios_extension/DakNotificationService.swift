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
// It needs nothing else: no pods, no Firebase in the extension. Give the
// extension target its own PrivacyInfo.xcprivacy (ios_extension/ has one).
//
// When you update dak_push, copy this file again: the plugin warns in debug
// builds when this copy's schemaVersion is older than it expects.

import UserNotifications
import os.log

open class DakNotificationService: UNNotificationServiceExtension {
  /// The keys this file shares with the plugin (DakShared.schema there).
  public static let schemaVersion = 2

  private static let configKey = "dak_push"
  private static let badgeKey = "dak_push_badge"
  private static let schemaKey = "dak_push_schema"
  private static let extensionSchemaKey = "dak_push_extension_schema"
  private static let receiptPrefix = "dak_push_receipt."
  private static let categoriesKey = "dak_push_categories"
  private static let categoryPrefix = "dak_"
  private static let maxCategories = 30
  private static let maxKeptReceipts = 200
  private static let log = OSLog(subsystem: "dak_push", category: "extension")

  /// Category changes one at a time: two pushes at once would each write the
  /// categories they read, and one push's buttons would be lost.
  private static let categoryQueue = DispatchQueue(label: "dak_push.categories")

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
      defaults.set(Self.schemaVersion, forKey: Self.extensionSchemaKey)
      let app = defaults.integer(forKey: Self.schemaKey)
      if app > Self.schemaVersion {
        os_log(
          "dak_push: the app expects DakNotificationService schema %d, this copy is %d: copy the new file",
          log: Self.log, type: .error, app, Self.schemaVersion)
      }
      applyBadge(info: info, defaults: defaults)
    }
    if let buttons = info["_dak_buttons"] as? String {
      group.enter()
      applyButtons(json: buttons, defaults: defaults) { group.leave() }
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

  /// The App Group's defaults. A setup mistake is logged (Console.app,
  /// subsystem dak_push): without the group no delivery is reported.
  private static func sharedDefaults() -> UserDefaults? {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "DakAppGroup") as? String, !group.isEmpty else {
      os_log("dak_push: no DakAppGroup in the extension's Info.plist", log: log, type: .error)
      return nil
    }
    guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil else {
      os_log(
        "dak_push: App Group %{public}@ is not in the extension's entitlements (Signing & Capabilities → App Groups)",
        log: log, type: .error, group)
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
      os_log("dak_push: the app has not shared its settings yet (Dak.init with iosAppGroup)", log: Self.log, type: .info)
      keepReceipt(messageID, defaults: defaults)
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
    URLSession.shared.dataTask(with: request) { _, response, _ in
      // Kept for the app (it sends them on its next start or resume) unless
      // the server took it or refused it for good.
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      let refused = (400..<500).contains(status) && ![401, 408, 429].contains(status)
      if !(200..<300).contains(status) && !refused { self.keepReceipt(messageID, defaults: defaults) }
      done()
    }.resume()
  }

  /// One key per receipt, so the app taking receipts and this extension
  /// keeping one never overwrite each other.
  private func keepReceipt(_ messageID: String, defaults: UserDefaults) {
    let kept = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.receiptPrefix) }.count
    if kept < Self.maxKeptReceipts { defaults.set(true, forKey: Self.receiptPrefix + messageID) }
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

  private func applyButtons(json: String, defaults: UserDefaults?, done: @escaping () -> Void) {
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
    Self.categoryQueue.async {
      Self.register(category, defaults: defaults)
      self.edit { $0.categoryIdentifier = id }
      done()
    }
  }

  /// Adds the category, keeping the app's own and Dak's most recently used
  /// ones (at most maxCategories), and returns once iOS has it: the
  /// notification is shown right after, and without its category it would
  /// have no buttons. Runs on categoryQueue.
  private static func register(_ category: UNNotificationCategory, defaults: UserDefaults?) {
    let center = UNUserNotificationCenter.current()
    let id = category.identifier
    let existing = current(center)
    // Most recently used last. Dak categories the list does not know (made
    // before it, or without an App Group) count as the oldest.
    var recent = (defaults?.array(forKey: categoriesKey) as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    let unknown = existing.map { $0.identifier }.filter { $0.hasPrefix(categoryPrefix) && !recent.contains($0) }.sorted()
    recent = unknown + recent
    recent.removeAll { $0 == id }
    recent.append(id)
    let keep = Set(recent.suffix(maxCategories))

    var categories = existing.filter {
      $0.identifier != id && (!$0.identifier.hasPrefix(categoryPrefix) || keep.contains($0.identifier))
    }
    categories.insert(category)
    center.setNotificationCategories(categories)
    // setNotificationCategories returns before iOS has the new set.
    for _ in 0..<10 {
      if current(center).contains(where: { $0.identifier == id }) { break }
      usleep(30_000)
    }

    // For the app, which puts them back if another plugin replaces them all.
    let byId = Dictionary(categories.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
    let saved: [[String: Any]] = recent.suffix(maxCategories).compactMap { cid in
      guard let c = byId[cid] else { return nil }
      return ["id": cid, "actions": c.actions.map { ["id": $0.identifier, "title": $0.title] }]
    }
    defaults?.set(saved, forKey: categoriesKey)
  }

  private static func current(_ center: UNUserNotificationCenter) -> Set<UNNotificationCategory> {
    let done = DispatchSemaphore(value: 0)
    var result = Set<UNNotificationCategory>()
    center.getNotificationCategories { categories in
      result = categories
      done.signal()
    }
    _ = done.wait(timeout: .now() + 2)
    return result
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
