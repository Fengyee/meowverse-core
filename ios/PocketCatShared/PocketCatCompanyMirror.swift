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

    /// The control turned company off: these companions, and whatever the shelf held.
    static func endedAll(_ sessionIDs: [String]) {
        if let shelf = PocketCatCompanyShelf.shared { PocketCatCompanyToggle.ended(sessionIDs, on: shelf) }
        PocketCatWidgetKind.reload()
    }

    /// Matches the shelf to the Live Activities the app can see: a companion dismissed on the
    /// Lock Screen while the app was away leaves the widgets here.
    static func reconcile() {
        guard let shelf = PocketCatCompanyShelf.shared else { return }
        if let activity = PocketCatActivity.activities.first(where: \.isOngoing) {
            kept(activity.id, activity.content.state)
        } else if shelf.record != nil {
            shelf.clear()
            PocketCatWidgetKind.reload()
        }
    }
}
