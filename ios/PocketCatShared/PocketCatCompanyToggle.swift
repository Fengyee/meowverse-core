import Foundation

/// The Control Center toggle "Keep Me Company" (owner, round 11: like the flashlight, it shows
/// whether company is on and turns it on or off; it can be set to start with a chosen
/// expression, `PocketCatCompanyConfiguration`). Foundation only: the Core tests compile this
/// file through a symlink (`MeowverseCore/Tests/MeowverseCoreTests/PocketCatShared/`).
///
/// The control's value is read in the extension, which can't see the app's Live Activities, so
/// it comes from the App Group (`PocketCatCompanyShelf`), with the same ended-session guard and
/// time limit as the widgets. The action runs in the app's process, where the activities are.
nonisolated enum PocketCatCompanyToggle {
    static let kind = "app.meowverse.control.companion"

    /// On while the widgets would show a running companion.
    static func isOn(_ shelf: PocketCatCompanyShelf?, at now: Date) -> Bool {
        shelf?.companion(at: now) != nil
    }

    /// What company starts with when the control has no choice saved: asleep, as it always did
    /// (and as the widgets' button does).
    static let defaultMood = PocketCatMood.sleeping

    static func startingMood(_ chosen: PocketCatMood?) -> PocketCatMood {
        chosen ?? defaultMood
    }

    /// Company started from the control: the chosen expression first, then the usual rotation.
    static func startingState(_ chosen: PocketCatMood?, at now: Date) -> PocketCatState {
        PocketCatState(startingWith: startingMood(chosen), at: now, interval: PocketCatRotation.standardInterval)
    }

    /// "Keep Me Company · Playing": the control's title names the expression it starts with.
    static func title(_ chosen: PocketCatMood?) -> LocalizedStringResource {
        LocalizedStringResource("Keep Me Company · \(startingMood(chosen).title)", table: "PocketCat")
    }

    enum Action: Hashable {
        /// Nothing is running: start company with this expression.
        case start(PocketCatMood)
        /// A companion is already running (the toggle was behind): keep it as it is.
        case adopt(String)
        /// End these running companions (and whatever the shelf holds).
        case end([String])
    }

    /// `ongoing` is the ids of the Live Activities that are active or stale, oldest first;
    /// `mood` is the control's chosen expression (nil for none saved).
    static func action(turningOn: Bool, ongoing: [String], mood: PocketCatMood? = nil) -> Action {
        guard turningOn else { return .end(ongoing) }
        return ongoing.first.map(Action.adopt) ?? .start(startingMood(mood))
    }

    /// What turning off ends, read before the activities are ended: the running companions,
    /// and the one the shelf holds now (which may be one the app never saw end). Read first so
    /// a companion started while the ends are awaited is not among them (D24-09).
    static func ending(_ ongoing: [String], on shelf: PocketCatCompanyShelf) -> [String] {
        guard let held = shelf.record?.sessionID, !ongoing.contains(held) else { return ongoing }
        return ongoing + [held]
    }

    /// After ending `sessions` (from `ending`): none of them stays on the widgets or comes back
    /// with a late write. Another companion on the shelf by now stays.
    static func ended(_ sessions: [String], on shelf: PocketCatCompanyShelf) {
        for id in sessions { shelf.end(sessionID: id) }
    }
}
