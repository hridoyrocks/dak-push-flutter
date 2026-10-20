import Flutter
import UIKit
import UserNotifications

/// Shares what the Dak notification service extension needs, sets the badge,
/// and remembers which button was tapped (firebase_messaging 17 tells Dart
/// itself; 15 and 16 do not).
public class DakPushPlugin: NSObject, FlutterPlugin {
  /// Message id → the tapped button's id ("" for a tap on the notification).
  private var actions: [String: String] = [:]
  private var warnedDelegate = false
  private var warnedExtension = false

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "dak_push", binaryMessenger: registrar.messenger())
    let instance = DakPushPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    // Only listens: FlutterAppDelegate passes notification responses on to
    // every plugin when it is the notification center's delegate. This
    // plugin never becomes the delegate itself.
    registrar.addApplicationDelegate(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "takeAction":
      let id = args["message_id"] as? String ?? ""
      guard let action = actions.removeValue(forKey: id) else {
        warnNoResponse()
        result(nil)
        return
      }
      result(action.isEmpty ? nil : action)
    case "shareWithExtension":
      guard let group = args["app_group"] as? String, let values = args["values"] as? [String: String] else {
        result(nil)
        return
      }
      guard let defaults = Self.groupDefaults(group) else {
        result(
          FlutterError(
            code: "app_group",
            message: "App Group \(group) is not set up for the app: add it under Signing & Capabilities → App Groups "
              + "for the Runner target and the notification service extension",
            details: nil))
        return
      }
      defaults.set(values, forKey: DakShared.configKey)
      defaults.set(DakShared.schema, forKey: DakShared.schemaKey)
      checkExtensionSchema(defaults)
      result(nil)
    case "setBadge":
      let count = max(0, args["count"] as? Int ?? 0)
      if let group = args["app_group"] as? String, let defaults = Self.groupDefaults(group) {
        defaults.set(count, forKey: DakShared.badgeKey)
      }
      if #available(iOS 16.0, *) {
        UNUserNotificationCenter.current().setBadgeCount(count, withCompletionHandler: nil)
      } else {
        UIApplication.shared.applicationIconBadgeNumber = count
      }
      result(nil)
    case "extensionReceipts":
      // Called on every start and resume: also the moment to put back Dak's
      // button categories if another plugin replaced them all.
      guard let group = args["app_group"] as? String, let defaults = Self.groupDefaults(group) else {
        result([String]())
        return
      }
      Self.restoreCategories(defaults)
      let prefix = DakShared.receiptPrefix
      result(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    case "removeExtensionReceipts":
      if let group = args["app_group"] as? String, let defaults = Self.groupDefaults(group),
        let ids = args["message_ids"] as? [String]
      {
        for id in ids { defaults.removeObject(forKey: DakShared.receiptPrefix + id) }
      }
      result(nil)
    case "storageDirectory":
      result(Self.storageDirectory())
    case "show":
      result(false)  // Android only
    case "initialAction":
      result(nil)  // Android only
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    // completionHandler is not called here: firebase_messaging gets the same
    // response and calls it.
    let action = response.actionIdentifier
    guard let id = response.notification.request.content.userInfo["_dak_id"] as? String,
      action != UNNotificationDismissActionIdentifier
    else { return }
    actions[id] = action == UNNotificationDefaultActionIdentifier ? "" : action
  }

  /// The App Group's shared defaults, or nil when the app is not entitled to
  /// the group (then the extension could never read what is written).
  private static func groupDefaults(_ group: String) -> UserDefaults? {
    guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil else { return nil }
    return UserDefaults(suiteName: group)
  }

  /// Application Support/dak_push, kept out of backups: deleted with the app,
  /// unlike the keychain.
  private static func storageDirectory() -> String? {
    do {
      var dir = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      ).appendingPathComponent("dak_push", isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try dir.setResourceValues(values)
      return dir.path
    } catch {
      return nil
    }
  }

  /// Puts back the categories the extension made (saved in the App Group)
  /// when they are gone, for example after flutter_local_notifications set
  /// its own categories only.
  private static func restoreCategories(_ defaults: UserDefaults) {
    guard let saved = defaults.array(forKey: DakShared.categoriesKey) as? [[String: Any]], !saved.isEmpty else { return }
    let center = UNUserNotificationCenter.current()
    center.getNotificationCategories { existing in
      let have = Set(existing.map { $0.identifier })
      let missing: [UNNotificationCategory] = saved.compactMap { entry in
        guard let id = entry["id"] as? String, !have.contains(id), let list = entry["actions"] as? [[String: String]] else {
          return nil
        }
        let actions = list.compactMap { a -> UNNotificationAction? in
          guard let aid = a["id"], let title = a["title"] else { return nil }
          return UNNotificationAction(identifier: aid, title: title, options: [.foreground])
        }
        return actions.isEmpty ? nil : UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [])
      }
      if !missing.isEmpty { center.setNotificationCategories(existing.union(missing)) }
    }
  }

  /// Debug builds: a tap Dart asks about never reached this plugin, so the
  /// app delegate does not pass notification responses on.
  private func warnNoResponse() {
    #if DEBUG
      if warnedDelegate { return }
      warnedDelegate = true
      NSLog(
        "dak_push: no notification response reached the plugin, so button taps cannot be told apart. "
          + "With firebase_messaging 15 or 16, set UNUserNotificationCenter.current().delegate = self in "
          + "AppDelegate.application(_:didFinishLaunchingWithOptions:) before GeneratedPluginRegistrant (see the README).")
    #endif
  }

  /// Debug builds: the extension's copy of DakNotificationService.swift is
  /// older than this plugin expects.
  private func checkExtensionSchema(_ defaults: UserDefaults) {
    #if DEBUG
      let theirs = defaults.integer(forKey: DakShared.extensionSchemaKey)
      if warnedExtension || theirs == 0 || theirs >= DakShared.schema { return }
      warnedExtension = true
      NSLog(
        "dak_push: the notification service extension uses DakNotificationService.swift schema \(theirs), "
          + "this plugin expects \(DakShared.schema). Copy ios_extension/DakNotificationService.swift from the "
          + "package again.")
    #endif
  }
}

/// Keys shared with DakNotificationService (ios_extension/).
enum DakShared {
  /// What the plugin and the extension agree on. The extension keeps its own
  /// copy (schemaVersion); bump both when the shared keys change.
  static let schema = 2
  static let configKey = "dak_push"
  static let badgeKey = "dak_push_badge"
  static let schemaKey = "dak_push_schema"
  static let extensionSchemaKey = "dak_push_extension_schema"
  static let receiptPrefix = "dak_push_receipt."
  static let categoriesKey = "dak_push_categories"
}
