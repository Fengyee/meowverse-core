import Foundation
import MeowverseCore
import UserNotifications

/// Whether the system will show the app's notifications.
enum ReminderAuthorization: Equatable {
    /// The system has not yet received an authorization request.
    case notDetermined
    /// Turned off in the system Settings (or refused when asked).
    case denied
    case allowed
}

/// The part of `UNUserNotificationCenter` the reminders use, so UI tests can swap in a fake.
protocol NotificationCenterClient: AnyObject {
    func authorization() async -> ReminderAuthorization
    /// Shows the system prompt if it was never shown; returns the resulting state.
    func requestAuthorization() async -> ReminderAuthorization
    /// Replaces the reminders managed by this client.
    func replacePending(with requests: [UNNotificationRequest]) async throws
    /// The identifiers of this app's reminders the system still holds, not yet shown.
    func pendingIdentifiers() async -> Set<String>
}

/// The real center. Every notification of this app is a reminder, so "all pending" is ours.
final class SystemNotificationCenter: NotificationCenterClient {
    private var center: UNUserNotificationCenter { .current() }

    func authorization() async -> ReminderAuthorization {
        Self.map(await center.notificationSettings().authorizationStatus)
    }

    func requestAuthorization() async -> ReminderAuthorization {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await authorization()
    }

    func replacePending(with requests: [UNNotificationRequest]) async throws {
        let wanted = Set(requests.map(\.identifier))
        let obsolete = await center.pendingNotificationRequests().map(\.identifier).filter {
            $0.hasPrefix(ReminderPlanner.idPrefix) && !wanted.contains($0)
        }
        center.removePendingNotificationRequests(withIdentifiers: obsolete)
        for request in requests { try await center.add(request) }
    }

    /// Takes this app's notifications out of Notification Center.
    func removeDelivered() {
        center.removeAllDeliveredNotifications()
    }

    func pendingIdentifiers() async -> Set<String> {
        Set(await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(ReminderPlanner.idPrefix) })
    }

    private static func map(_ status: UNAuthorizationStatus) -> ReminderAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        // Provisional and ephemeral deliver too (quietly, or for an App Clip).
        case .authorized, .provisional, .ephemeral: .allowed
        @unknown default: .denied
        }
    }
}

#if DEBUG || DRILLS
/// Exercises system permission, delivery and taps using a single one-shot request owned by the test store.
/// The recurring reminders in a fixture must never become real weekly notifications.
final class SystemDeliveryTestCenter: NotificationCenterClient {
    private let system = SystemNotificationCenter()
    private let identifier: String
    private let delay: TimeInterval?

    init(store: String, arguments: [String]) {
        identifier = "\(ReminderPlanner.idPrefix)ui-test.\(store).delivery"
        if let index = arguments.firstIndex(of: "-MeowverseTestReminderIn"), arguments.indices.contains(index + 1) {
            delay = TimeInterval(arguments[index + 1])
        } else {
            delay = nil
        }
    }

    func authorization() async -> ReminderAuthorization { await system.authorization() }
    func requestAuthorization() async -> ReminderAuthorization { await system.requestAuthorization() }
    /// Only the probe is ever scheduled, so no fact is recorded as held or shown.
    func pendingIdentifiers() async -> Set<String> { await system.pendingIdentifiers() }

    func replacePending(with requests: [UNNotificationRequest]) async throws {
        let center = UNUserNotificationCenter.current()
        // A setup launch clears this test's probe, even after an interrupted run.
        guard let delay, delay.isFinite, !requests.isEmpty else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Meowverse"
        content.body = String(localized: "测试提醒")
        if let memory = requests.first(where: { $0.content.userInfo[ReminderContent.furnitureKey] != nil }) {
            content.userInfo = memory.content.userInfo
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(delay, 1), repeats: false)
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}

/// Stands in for the system in UI tests (`-MeowverseFakeNotifications granted|denied`). It
/// answers the permission prompt as told, remembers the answer across launches like the system
/// does, and records the requests it was given instead of scheduling them.
@Observable
final class FakeNotificationCenter: NotificationCenterClient {
    enum Answer: String { case granted, denied }

    private var failOnceAt: Int?
    private let answer: Answer
    private let defaults: UserDefaults
    private let key: String
    private(set) var recorded: [UNNotificationRequest] = []
    /// How many times `replacePending` ran.
    private(set) var replaceCount = 0

    init(answer: Answer, key: String, reset: Bool, defaults: UserDefaults = .standard, failOnceAt: Int? = nil) {
        self.failOnceAt = failOnceAt
        self.answer = answer
        self.key = key
        self.defaults = defaults
        if reset { defaults.removeObject(forKey: key) }
    }

    private var stored: ReminderAuthorization {
        switch defaults.string(forKey: key) {
        case "allowed": .allowed
        case "denied": .denied
        default: .notDetermined
        }
    }

    func authorization() async -> ReminderAuthorization { stored }

    func requestAuthorization() async -> ReminderAuthorization {
        if stored == .notDetermined {
            defaults.set(answer == .granted ? "allowed" : "denied", forKey: key)
        }
        return stored
    }

    func replacePending(with requests: [UNNotificationRequest]) async throws {
        replaceCount += 1
        if let index = failOnceAt, requests.indices.contains(index) {
            failOnceAt = nil
            recorded = Array(requests.prefix(index))
            throw CocoaError(.fileWriteUnknown)
        }
        recorded = requests
    }

    /// Like the system: a one-off request leaves once its time has come.
    func pendingIdentifiers() async -> Set<String> {
        Set(recorded.filter { request in
            guard let trigger = request.trigger as? UNCalendarNotificationTrigger, !trigger.repeats else { return true }
            return trigger.nextTriggerDate() != nil
        }.map(\.identifier))
    }
}
#endif
