#if DEBUG || DRILLS
import Foundation
import UserNotifications

/// UI tests (`-MeowverseDeliveredDrill`): 清除全部数据 starts with one notification in Notification
/// Center (provisional permission, so no prompt) and writes how many are left to
/// Caches/Meowverse/delivered-<store>.
enum ClearedNotificationsDrill {
    private final class Quiet: NSObject, UNUserNotificationCenterDelegate {
        nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
            done([.list])
        }
    }

    private static let quiet = Quiet()
    private static var on: Bool { ProcessInfo.processInfo.arguments.contains("-MeowverseDeliveredDrill") }

    static func deliverOne() async {
        guard on else { return }
        let center = UNUserNotificationCenter.current()
        // In the foreground one only reaches Notification Center if a delegate lets it.
        center.delegate = quiet
        _ = try? await center.requestAuthorization(options: [.alert, .provisional])
        let content = UNMutableNotificationContent()
        content.title = "Meowverse drill"
        content.body = "Delivered before clearing"
        try? await center.add(UNNotificationRequest(identifier: "drill.delivered", content: content, trigger: nil))
        for _ in 0..<20 where await center.deliveredNotifications().isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        write(await center.deliveredNotifications().count, to: "delivered-before-")
    }

    static func writeCount(store: String) async {
        guard on else { return }
        try? await Task.sleep(for: .seconds(1))
        write(await UNUserNotificationCenter.current().deliveredNotifications().count, to: "delivered-after-")
    }

    private static func write(_ count: Int, to name: String) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Meowverse")
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try? Data("\(count)".utf8).write(to: caches.appending(path: name + LaunchOptions.current.storeFolder), options: .atomic)
    }
}
#endif
