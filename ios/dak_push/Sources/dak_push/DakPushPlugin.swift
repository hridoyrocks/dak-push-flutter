import Flutter
import UIKit
import UserNotifications

/// Shares what the Dak notification service extension needs, sets the badge,
/// and remembers which button was tapped (firebase_messaging 17 tells Dart
/// itself; 15 and 16 do not).
public class DakPushPlugin: NSObject, FlutterPlugin {
  /// Message id → the tapped button's id.
  private var actions: [String: String] = [:]

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
      result(actions.removeValue(forKey: id))
    case "shareWithExtension":
      if let group = args["app_group"] as? String, let values = args["values"] as? [String: String],
        let defaults = UserDefaults(suiteName: group)
      {
        defaults.set(values, forKey: DakShared.configKey)
      }
      result(nil)
    case "setBadge":
      let count = max(0, args["count"] as? Int ?? 0)
      if let group = args["app_group"] as? String, let defaults = UserDefaults(suiteName: group) {
        defaults.set(count, forKey: DakShared.badgeKey)
      }
      if #available(iOS 16.0, *) {
        UNUserNotificationCenter.current().setBadgeCount(count, withCompletionHandler: nil)
      } else {
        UIApplication.shared.applicationIconBadgeNumber = count
      }
      result(nil)
    case "initialAction", "show":
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
      action != UNNotificationDefaultActionIdentifier, action != UNNotificationDismissActionIdentifier
    else { return }
    actions[id] = action
  }
}

/// Keys shared with DakNotificationService (ios_extension/).
enum DakShared {
  static let configKey = "dak_push"
  static let badgeKey = "dak_push_badge"
}
