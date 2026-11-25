@preconcurrency import ActivityKit
import AppIntents

typealias PocketCatActivity = Activity<PocketCatAttributes>

extension Activity where Attributes == PocketCatAttributes {
    var isOngoing: Bool { activityState == .active || activityState == .stale }

    func show(_ mood: PocketCatMood, at date: Date = .now) async {
        await show(content.state.showing(mood, at: date), at: date)
    }

    /// "Change expression": the next one, written to the activity and then to the App Group,
    /// which reloads the widgets and the control.
    func changeExpression(at date: Date) async {
        await show(content.state.changed(at: date), at: date)
    }

    private func show(_ state: PocketCatState, at date: Date) async {
        await update(.init(state: state, staleDate: nil), timestamp: date)
        await PocketCatCompanyMirror.kept(id, state)
    }
}

struct ChangePocketCatMood: LiveActivityIntent {
    static let title = LocalizedStringResource("Change expression", table: "PocketCat")
    static let isDiscoverable = false

    @Parameter(title: .init("Companion session", table: "PocketCat")) var sessionID: String

    init() {}
    init(sessionID: String) { self.sessionID = sessionID }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let activity = PocketCatActivity.activities.first(where: { $0.id == sessionID && $0.isOngoing }) {
            let now = Date()
            await activity.changeExpression(at: now)
        } else {
            // Ended where the app didn't hear it (dismissed on the Lock Screen): the widget
            // that offered "Change expression" goes back to "Keep me company".
            PocketCatCompanyMirror.ended(sessionID)
        }
        return .result()
    }
}

/// The widgets' "Keep me company" button (the Control Center control is now a toggle,
/// `SetPocketCatCompany`). A Live Activity intent runs in the app's
/// process and may start the activity from the background, so the app does not open. Already
/// keeping company: the next expression, as "Change expression" does. The name is the one the
/// app last left (`PocketCatAttributes.remember`), since the app's model may not be loaded.
struct StartPocketCatCompany: LiveActivityIntent {
    static let title = LocalizedStringResource("Keep me company", table: "PocketCat")
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let now = Date()
        if let activity = PocketCatActivity.activities.first(where: \.isOngoing) {
            await activity.changeExpression(at: now)
            return .result()
        }
        try PocketCatActivity.startFromOutside(at: now)
        return .result()
    }
}

extension Activity where Attributes == PocketCatAttributes {
    /// Company started from outside the app (a widget or a control): on `mood` (asleep unless
    /// the control was set to another), with the name the app last left, and copied into the
    /// App Group for the widgets and the control.
    @MainActor
    static func startFromOutside(at now: Date, mood: PocketCatMood? = nil) throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw PocketCatControlError.liveActivitiesOff }
        let state = PocketCatCompanyToggle.startingState(mood, at: now)
        do {
            let activity = try PocketCatActivity.request(attributes: .remembered(), content: .init(state: state, staleDate: nil))
            PocketCatCompanyMirror.kept(activity.id, state)
        } catch {
            throw PocketCatControlError.couldNotStart
        }
    }
}

/// The Control Center toggle "Keep Me Company" (`PocketCatCompanyToggle`). On starts company on
/// the control's chosen expression (`PocketCatCompanyConfiguration`), or adopts the companion
/// already running without changing its expression. Off ends every running companion, as "End
/// company" does, and clears the App Group, so the widgets, the Live Activity and the control
/// all show company over. `mood` is optional so an action saved before the control had a
/// setting still runs, asleep as it did.
struct SetPocketCatCompany: SetValueIntent, LiveActivityIntent {
    static let title = LocalizedStringResource("Keep me company", table: "PocketCat")
    static let isDiscoverable = false

    @Parameter(title: .init("Keeping company", table: "PocketCat")) var value: Bool
    @Parameter(title: .init("Expression", table: "PocketCat")) var mood: PocketCatMood?

    init() {}
    init(mood: PocketCatMood?) { self.mood = mood }
    init(value: Bool, mood: PocketCatMood? = nil) {
        self.value = value
        self.mood = mood
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let ongoing = PocketCatActivity.activities.filter(\.isOngoing)
        switch PocketCatCompanyToggle.action(turningOn: value, ongoing: ongoing.map(\.id), mood: mood) {
        case .start(let mood):
            try PocketCatActivity.startFromOutside(at: .now, mood: mood)
        case .adopt(let id):
            if let activity = ongoing.first(where: { $0.id == id }) {
                PocketCatCompanyMirror.kept(activity.id, activity.content.state)
            }
        case .end(let ids):
            // Read before the awaits: a companion started meanwhile stays (D24-09).
            let ending = PocketCatCompanyMirror.ending(ids)
            for activity in ongoing where ids.contains(activity.id) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            PocketCatCompanyMirror.endedAll(ending)
        }
        return .result()
    }
}

/// Shown by the system when the control cannot start company. Opening the app's companion
/// page instead would need a foreground-continuable intent, which the extension (where the
/// control's copy of this intent is compiled) cannot have on iOS 18.
enum PocketCatControlError: Error, CustomLocalizedStringResourceConvertible {
    case liveActivitiesOff, couldNotStart

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .liveActivitiesOff: .init("To invite your pixel cat, allow Live Activities in the app’s settings.", table: "PocketCat")
        case .couldNotStart: .init("Couldn’t start this Live Activity. Try again, or check Live Activities in Settings.", table: "PocketCat")
        }
    }
}

/// The Control Center buttons that add photos open the app and take the Home Screen quick
/// action's path (`QuickActionCenter`, then `RoomScreen.handleQuickAction`). `PocketCatRoute`
/// is the app's in the app target and does nothing in the extension, where these never run.
struct TakePhotoToAdd: AppIntent {
    static let title = LocalizedStringResource("Take Photo", table: "PocketCat")
    static let isDiscoverable = false
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        PocketCatRoute.open(.camera)
        return .result()
    }
}

struct AddFromPhotos: AppIntent {
    static let title = LocalizedStringResource("Add from Photos", table: "PocketCat")
    static let isDiscoverable = false
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        PocketCatRoute.open(.library)
        return .result()
    }
}

nonisolated enum PocketCatDestination: Sendable {
    case camera, library
}

struct EndPocketCatCompany: LiveActivityIntent {
    static let title = LocalizedStringResource("End company", table: "PocketCat")
    static let isDiscoverable = false

    @Parameter(title: .init("Companion session", table: "PocketCat")) var sessionID: String

    init() {}
    init(sessionID: String) { self.sessionID = sessionID }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let activity = PocketCatActivity.activities.first(where: { $0.id == sessionID && $0.isOngoing }) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        PocketCatCompanyMirror.ended(sessionID)
        return .result()
    }
}
