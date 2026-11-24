import MeowverseCore
import os
import SwiftUI
import UserNotifications

/// The reminder kinds the settings page switches.
enum ReminderKind: CaseIterable {
    case calls, onThisDay, furniture, catFacts
}

/// Owns the reminder settings and keeps the system's pending notifications equal to the plan.
///
/// Local notifications are only re-planned while the app runs, so this runs on launch, on every
/// return to the foreground and after library changes. Nothing leaves the device.
@Observable
final class ReminderScheduler {
    private(set) var settings: ReminderSettings
    private(set) var authorization: ReminderAuthorization = .notDetermined
    /// True while the permission prompt is up or an answer is being read.
    private(set) var asking = false
    enum Destination: Equatable {
        case room
        case furniture(String)
    }

    struct Tap: Equatable {
        let id = UUID()
        let destination: Destination
    }

    var pendingTap: Tap?

    let client: any NotificationCenterClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private var lastScheduled: Signature?
    /// Which facts the system was given and which it has shown (fifth review, R5-04).
    @ObservationIgnored private var catFactHistory: CatFactHistory
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var delegate: ReminderNotificationDelegate?
    @ObservationIgnored private let log = Logger(subsystem: "app.meowverse", category: "reminders")

    private struct Signature: Equatable {
        var plan: [PlannedReminder]
        var catName: String
    }

    init(options: LaunchOptions, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Keyed by store folder like the import queue: each UI-test store has its own settings.
        key = "reminders.settings.\(options.storeFolder)"
        let isTest = options.storeFolder != "Library"
        if isTest, options.resetStore {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: key + ".setupComplete")
            defaults.removeObject(forKey: key + Self.historySuffix)
        }
        if let data = defaults.data(forKey: key), let stored = try? JSONDecoder().decode(ReminderSettings.self, from: data) {
            settings = stored
        } else {
            var fresh = ReminderSettings()
            fresh.seed = UInt64.random(in: 0...UInt64.max)
            settings = fresh
        }
        catFactHistory = defaults.data(forKey: key + Self.historySuffix)
            .flatMap { try? JSONDecoder().decode(CatFactHistory.self, from: $0) } ?? CatFactHistory()
        client = Self.makeClient(options: options, defaults: defaults)
        #if DEBUG || DRILLS
        if client is FakeNotificationCenter { return }
        #endif
        let delegate = ReminderNotificationDelegate { [weak self] furnitureID in
            self?.pendingTap = Tap(destination: furnitureID.map(Destination.furniture) ?? .room)
        }
        self.delegate = delegate
        // Set at launch so a tap that launched the app is delivered too.
        UNUserNotificationCenter.current().delegate = delegate
    }

    private static func makeClient(options: LaunchOptions, defaults: UserDefaults) -> any NotificationCenterClient {
        #if DEBUG || DRILLS
        if options.storeFolder != "Library" {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-MeowverseSystemNotifications") {
                return SystemDeliveryTestCenter(store: options.storeFolder, arguments: args)
            }
            var answer = FakeNotificationCenter.Answer.granted
            if let index = args.firstIndex(of: "-MeowverseFakeNotifications"), args.indices.contains(index + 1),
               let selected = FakeNotificationCenter.Answer(rawValue: args[index + 1]) {
                answer = selected
            }
            return FakeNotificationCenter(answer: answer, key: "reminders.fakeAuthorization.\(options.storeFolder)",
                                          reset: options.resetStore, defaults: defaults,
                                          failOnceAt: args.contains("-MeowverseFailReminderAdd") ? 2 : nil)
        }
        #endif
        return SystemNotificationCenter()
    }

    // MARK: Reading the settings

    /// What the switch shows: on only when the user wants it AND the system will deliver it.
    func isOn(_ kind: ReminderKind) -> Bool {
        authorization == .allowed && wants(kind)
    }

    func wants(_ kind: ReminderKind) -> Bool {
        switch kind {
        case .calls: settings.callsEnabled
        case .onThisDay: settings.onThisDayEnabled
        case .furniture: settings.furnitureEnabled
        case .catFacts: settings.catFactsEnabled
        }
    }

    // MARK: Changing them

    /// This device answered the old first-launch reminder page for this library (earlier builds
    /// wrote `.setupComplete` when it closed), or saved reminder settings. Then the tour's
    /// reminder chapter is not needed (TourSnapshot.answeredReminderSetup). Nothing writes the
    /// flag any more; it is only read, so upgraded devices keep their answer.
    var answeredFirstLaunchSetup: Bool {
        defaults.bool(forKey: key + ".setupComplete") || defaults.object(forKey: key) != nil
    }

    func requestPermissionIfNeeded() async {
        guard !asking else { return }
        asking = true
        defer { asking = false }
        let status = await client.authorization()
        authorization = status == .notDetermined ? await client.requestAuthorization() : status
    }

    /// Turning a kind on asks for permission the first time. If the answer is no, nothing is
    /// switched on: the settings page shows that notifications are off instead.
    func set(_ kind: ReminderKind, on: Bool, state: AppState) async {
        if on {
            await requestPermissionIfNeeded()
            guard authorization == .allowed else { return }
        }
        update(state: state) { settings in
            switch kind {
            case .calls: settings.callsEnabled = on
            case .onThisDay: settings.onThisDayEnabled = on
            case .furniture: settings.furnitureEnabled = on
            case .catFacts: settings.catFactsEnabled = on
            }
        }
    }

    func update(state: AppState, _ change: (inout ReminderSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: key) }
        reschedule(state: state)
    }

    // MARK: Scheduling

    /// Re-reads the permission and replaces the pending notifications with a fresh plan.
    /// Calls run one after another, so the latest state is always the one left scheduled.
    func reschedule(state: AppState) {
        let previous = work
        work = Task {
            await previous?.value
            await apply(state: state)
        }
    }

    /// Waits for the scheduling queued so far.
    func settle() async {
        await work?.value
    }

    private static let historySuffix = ".catFactHistory"

    private func apply(state: AppState) async {
        authorization = await client.authorization()
        // A fact the system held last time and holds no longer, once its time could have come,
        // was shown: its week is spent, even if a photo added since makes that day busy (R5-04).
        let now = Date.now, calendar = Calendar.autoupdatingCurrent
        catFactHistory.noteDeliveries(pending: await client.pendingIdentifiers(), now: now)
        let plan = authorization == .allowed && settings.anyEnabled
            ? ReminderPlanner.plan(state: state, settings: settings, now: now, calendar: calendar,
                                   consumedCatFactWeeks: catFactHistory.consumedWeeks)
            : []
        let signature = Signature(plan: plan, catName: state.primaryCat.name)
        guard signature != lastScheduled else { return saveHistory() }
        do {
            try await client.replacePending(with: plan.map { ReminderContent.request(for: $0, catName: state.primaryCat.name) })
            lastScheduled = signature
            log.info("reminders scheduled: \(plan.count)")
        } catch {
            lastScheduled = nil
            log.error("reminder scheduling failed: \(type(of: error), privacy: .public)")
        }
        // Even after a failure: only what the system really holds is recorded.
        catFactHistory.noteScheduled(plan, pending: await client.pendingIdentifiers(), calendar: calendar)
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(catFactHistory) { defaults.set(data, forKey: key + Self.historySuffix) }
    }
}

/// Receives taps on delivered reminders and lets them show while the app is open.
final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let open: @MainActor @Sendable (String?) -> Void

    init(open: @escaping @MainActor @Sendable (String?) -> Void) {
        self.open = open
    }

    /// The completion-handler form on purpose: with the `async` form, Swift calls UIKit's handler
    /// from a concurrency thread, UIKit asserts it is on the main thread while updating the app
    /// snapshot, and the app aborts right after the tap brings it forward (0.1.0 build 1).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        let isReminder = request.identifier.hasPrefix(ReminderPlanner.idPrefix)
        let furnitureID = request.content.userInfo[ReminderContent.furnitureKey] as? String
        nonisolated(unsafe) let done = completionHandler
        DispatchQueue.main.async { [open] in
            if isReminder { MainActor.assumeIsolated { open(furnitureID) } }
            done()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

/// Hooks the scheduler to the app's lifecycle: launch, foreground, library changes, and taps.
struct ReminderHooks: ViewModifier {
    let model: AppModel
    let scheduler: ReminderScheduler
    @Environment(\.scenePhase) private var scenePhase

    // No reminder page at the first launch (PRODUCT_PLAN §2.2, Plan A): the tour offers reminders
    // later, and the permission prompt waits until the user turns a reminder on.
    func body(content: Content) -> some View {
        content
            .onChange(of: model.phase) { _, phase in
                if phase == .ready { scheduler.reschedule(state: model.shownState) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, model.phase == .ready { scheduler.reschedule(state: model.shownState) }
            }
            .onChange(of: model.state.revision) { _, _ in scheduler.reschedule(state: model.shownState) }
            .onChange(of: model.libraryGeneration) { _, _ in scheduler.reschedule(state: model.shownState) }
            // A repair that could not be saved moves a photo's day without a new revision.
            .onChange(of: model.unsavedPhotoRepairs) { _, _ in scheduler.reschedule(state: model.shownState) }
    }
}

extension View {
    func reminderScheduling(model: AppModel, scheduler: ReminderScheduler) -> some View {
        modifier(ReminderHooks(model: model, scheduler: scheduler))
    }
}
