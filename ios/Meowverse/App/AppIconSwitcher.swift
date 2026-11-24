import MeowverseCore
import os
import SwiftUI
import UIKit

/// The app icon follows the seasons and holidays (`AppIconCalendar`). iOS only lets an app
/// change its icon while it is in the foreground, and shows its own alert every time; the app
/// cannot hide that alert. So the icon is checked when the app comes to the foreground (and
/// when the day changes while it is open), changed only if today's icon differs, and the same
/// icon is requested at most once (`AppIconSync`).
@MainActor
enum AppIconSwitcher {
    static let followsCalendarKey = "appIcon.followsCalendar"
    static let lastAttemptKey = "appIcon.lastAttempt"

    private static let log = Logger(subsystem: "app.meowverse", category: "app-icon")
    private static var inFlight = false
    /// The icon is being changed: the system's alert about it may be up (the tour waits).
    static var isSwitching: Bool { inFlight }

    static var followsCalendar: Bool {
        UserDefaults.standard.object(forKey: followsCalendarKey) as? Bool ?? true
    }

    static func todaysTheme(now: Date = .now) -> AppIconTheme {
        let options = AppIconTestOptions.current
        let hemisphere = Hemisphere(regionCode: options.region ?? Locale.current.region?.identifier)
        if let day = options.day { return AppIconCalendar.theme(on: day, hemisphere: hemisphere) }
        return AppIconCalendar.theme(at: now, in: .current, hemisphere: hemisphere)
    }

    static var target: String? {
        AppIconSync.target(followsCalendar: followsCalendar, theme: todaysTheme())
    }

    /// The user turned the setting on or off: that is a new request, even for an icon that
    /// failed before.
    static func userChangedSetting() {
        UserDefaults.standard.removeObject(forKey: lastAttemptKey)
        Task { await sync() }
    }

    static func sync() async {
        let app = UIApplication.shared
        AppIconStatus.shared.refresh()
        guard AppIconTestOptions.current.switchingAllowed, app.supportsAlternateIcons,
              app.applicationState == .active, !inFlight else { return }
        let defaults = UserDefaults.standard
        let target = target
        let last = AppIconSync.Attempt(stored: defaults.string(forKey: lastAttemptKey))
        guard AppIconSync.shouldAttempt(target: target, current: app.alternateIconName, lastAttempt: last) else { return }
        defaults.set(AppIconSync.Attempt(target: target).stored, forKey: lastAttemptKey)
        inFlight = true
        defer {
            inFlight = false
            AppIconStatus.shared.refresh()
        }
        do {
            try await app.setAlternateIconName(target)
            log.notice("app icon changed to \(target ?? "primary", privacy: .public)")
        } catch {
            log.notice("app icon change to \(target ?? "primary", privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// What the settings row and the DEBUG probe show. `alternateIconName` is not observable.
@MainActor @Observable
final class AppIconStatus {
    static let shared = AppIconStatus()
    private(set) var current: String?
    private(set) var target: String?

    func refresh() {
        current = UIApplication.shared.alternateIconName
        target = AppIconSwitcher.target
    }
}

/// Runs the check on every return to the foreground and at midnight while open.
struct AppIconFollowsCalendar: ViewModifier {
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .task(id: phase) {
                guard phase == .active else { return }
                // Asking during the launch transition can fail with "resource temporarily
                // unavailable"; wait until the app has settled.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, await AppIconTourHold.allows() else { return }
                await AppIconSwitcher.sync()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                Task { if await AppIconTourHold.allows() { await AppIconSwitcher.sync() } }
            }
    }
}

/// The first icon change waits for the tour's opening (PRODUCT_PLAN §2.2 item 2): the system's
/// alert cannot be hidden and would land on Bella's first words. On a library's first open it
/// comes the next time the app is brought to the front after the opening is over; from the second
/// open on, as before. A home already lived in when the tour first met it is not held. Turning the
/// setting on or off in Settings is the user's own request and is not held.
@MainActor
enum AppIconTourHold {
    private static var atLaunch: TourStored?

    private static var library: String { LaunchOptions.current.storeFolder }

    /// Call once at launch, before the tour counts this open.
    static func noteLaunch() {
        guard atLaunch == nil else { return }
        // A reset test library forgets the tour (`TourCoordinator.init`), which SwiftUI may create
        // after this runs.
        atLaunch = LaunchOptions.current.resetStore ? .missing : UserDefaultsTourRecordStore().load(library: library)
    }

    /// Asks the tour's record; while the tour has not looked at the library yet, asks again for up
    /// to a minute. False: not this time in the foreground.
    static func allows() async -> Bool {
        guard TourLaunch.isEnabled else { return true }
        let catalog = TourCatalog(chapters: TourCatalog.current.chapters.filter { TourCoordinator.shippedChapters.contains($0.id) })
        let store = UserDefaultsTourRecordStore()
        for _ in 0..<120 {
            switch TourRules.iconTiming(atLaunch: atLaunch ?? .missing, now: store.load(library: library), catalog: catalog) {
            case .go: return true
            case .hold: return false
            case .wait:
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return false }
            }
        }
        return false
    }
}

/// Settings → App icon.
struct AppIconSettings: View {
    @AppStorage(AppIconSwitcher.followsCalendarKey) private var followsCalendar = true
    @State private var status = AppIconStatus.shared

    var body: some View {
        Section {
            Toggle(isOn: $followsCalendar) {
                Text("图标随季节和节日更换", tableName: "AppIcon")
            }
            .accessibilityIdentifier("app-icon-follows")
            .onChange(of: followsCalendar) { _, _ in AppIconSwitcher.userChangedSetting() }
            #if DEBUG || DRILLS
            if AppIconTestOptions.current.probe {
                Text(verbatim: "target \(status.target ?? "primary") · current \(status.current ?? "primary")")
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("app-icon-probe")
                    .accessibilityValue(Text(verbatim: "\(status.target ?? "primary") \(status.current ?? "primary")"))
            }
            #endif
        } header: {
            Text("App 图标", tableName: "AppIcon")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if followsCalendar {
                    Text("今天：\(AppIconSwitcher.todaysTheme().title)", tableName: "AppIcon")
                        .accessibilityIdentifier("app-icon-today")
                }
                Text("春夏秋冬各一款，圣诞、跨年、春节、情人节、元宵和感恩节前后换成节日款。每次更换时 iOS 都会弹出提示，这是系统的规定，App 无法关闭。", tableName: "AppIcon")
            }
        }
        .onAppear { status.refresh() }
    }
}

extension AppIconTheme {
    var title: String {
        switch self {
        case .springSakura: String(localized: "春日樱语", table: "AppIcon")
        case .summerSea: String(localized: "夏日海盐", table: "AppIcon")
        case .autumnMaple: String(localized: "秋日枫糖", table: "AppIcon")
        case .winterKnit: String(localized: "冬日围巾", table: "AppIcon")
        case .thanksgivingHarvest: String(localized: "丰收感恩", table: "AppIcon")
        case .christmasHolly: String(localized: "圣诞冬青", table: "AppIcon")
        case .newYearStarlight: String(localized: "跨年星光", table: "AppIcon")
        case .lunarNewYear: String(localized: "春节朱砂", table: "AppIcon")
        case .valentineRose: String(localized: "情人节玫瑰", table: "AppIcon")
        case .lanternGlow: String(localized: "元宵灯暖", table: "AppIcon")
        case .creamClassic: String(localized: "奶油经典", table: "AppIcon")
        case .midnightSage: String(localized: "午夜鼠尾草", table: "AppIcon")
        }
    }
}

/// Test switches, only in DEBUG and DRILLS builds:
/// - `-MeowverseIconDate yyyy-MM-dd`: treat this as today.
/// - `-MeowverseIconRegion <code>`: use this region for the hemisphere.
/// - `-MeowverseIconSwitching`: allow real icon changes in a test launch. Launches with any
///   other test switch (`-MeowverseStore`, `-MeowverseSkipReminderSetup`) never change the
///   icon, so the system alert cannot interrupt unrelated UI tests or store screenshots.
/// - `-MeowverseIconReset`: forget the setting and the last attempt, and restore the primary
///   icon state on the next check.
struct AppIconTestOptions {
    var day: IconDay?
    var region: String?
    var switchingAllowed = true
    /// Settings shows the target and current icon names.
    var probe = false

    static let current: AppIconTestOptions = {
        var options = AppIconTestOptions()
        #if DEBUG || DRILLS
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        if let text = value("-MeowverseIconDate") {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            if parts.count == 3 { options.day = IconDay(year: parts[0], month: parts[1], day: parts[2]) }
        }
        options.region = value("-MeowverseIconRegion")
        let testLaunch = args.contains("-MeowverseStore") || args.contains("-MeowverseSkipReminderSetup")
        options.switchingAllowed = !testLaunch || args.contains("-MeowverseIconSwitching")
        options.probe = options.day != nil || args.contains("-MeowverseIconSwitching")
        if args.contains("-MeowverseIconReset") {
            UserDefaults.standard.removeObject(forKey: AppIconSwitcher.followsCalendarKey)
            UserDefaults.standard.removeObject(forKey: AppIconSwitcher.lastAttemptKey)
        }
        #endif
        return options
    }()
}
