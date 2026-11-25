@preconcurrency import ActivityKit
import Foundation

/// Copies the running companion into the App Group (`PocketCatCompanyShelf`) and asks the
/// widgets to read it again. Called wherever company starts, changes or ends, in the app and
/// in the intents (which run in the app's process), and when the app comes to the front.
@MainActor
enum PocketCatCompanyMirror {
    static func kept(_ sessionID: String, _ state: PocketCatState) {
        PocketCatCompanyShelf.shared?.keep(sessionID: sessionID, state: state, at: .now)
        PocketCatWidgetKind.reload()
    }

    static func ended(_ sessionID: String) {
        PocketCatCompanyShelf.shared?.end(sessionID: sessionID)
        PocketCatWidgetKind.reload()
    }

    /// What turning company off ends (`PocketCatCompanyToggle.ending`): call before awaiting
    /// the activities' ends, and pass the result to `endedAll`.
    static func ending(_ sessionIDs: [String]) -> [String] {
        guard let shelf = PocketCatCompanyShelf.shared else { return sessionIDs }
        return PocketCatCompanyToggle.ending(sessionIDs, on: shelf)
    }

    /// Company was turned off: these companions (from `ending`), and nothing started since.
    static func endedAll(_ sessionIDs: [String]) {
        if let shelf = PocketCatCompanyShelf.shared { PocketCatCompanyToggle.ended(sessionIDs, on: shelf) }
        PocketCatWidgetKind.reload()
    }

    /// Matches the shelf to the Live Activities the app can see: a companion dismissed on the
    /// Lock Screen while the app was away leaves the widgets here.
    static func reconcile() {
        guard let shelf = PocketCatCompanyShelf.shared else { return }
        let ongoing = PocketCatActivity.activities.filter(\.isOngoing)
        // The shelf's companion is no longer running: it ended, so an older one that still
        // runs isn't taken for a late write (`PocketCatCompanyShelf.keep`).
        if let held = shelf.record?.sessionID, !ongoing.contains(where: { $0.id == held }) {
            shelf.end(sessionID: held)
        }
        if let activity = ongoing.first {
            kept(activity.id, activity.content.state)
        } else if shelf.record != nil {
            shelf.clear()
            PocketCatWidgetKind.reload()
        }
    }
}
