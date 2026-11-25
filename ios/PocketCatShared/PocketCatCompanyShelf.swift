import Foundation

/// What the widgets know about company: the one running companion, if any, as the app last
/// left it in the App Group (`group.io.github.fengyee.meowverse`). The widget extension can't
/// read the app's Live Activities (`Activity.activities` is empty there), so the app copies the
/// companion here whenever it starts, changes or ends (owner, 2026-11-19, step one of the
/// widgets). Only the companion: no photos, names or counts.
///
/// Foundation only: the Core tests compile this file through a symlink
/// (`MeowverseCore/Tests/MeowverseCoreTests/PocketCatShared/`).
nonisolated struct PocketCatCompanyShelf {
    static let appGroup = "group.io.github.fengyee.meowverse"
    static let key = "pocketCat.company"

    /// iOS ends a Live Activity at most eight hours after it starts; past that the widgets stop
    /// showing company even if the app never heard the end.
    static let longestCompany: TimeInterval = 8 * 60 * 60

    struct Record: Codable, Hashable {
        let sessionID: String
        /// When this companion started (or when this device first saw it): for the time limit.
        let startedAt: Date
        let state: PocketCatState
    }

    let defaults: UserDefaults

    /// The App Group's defaults, or nil where the group isn't available (a build without the
    /// entitlement): the widgets then show the cat at rest.
    static var shared: PocketCatCompanyShelf? {
        UserDefaults(suiteName: appGroup).map(PocketCatCompanyShelf.init)
    }

    var record: Record? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// The companion the widgets should follow at `now`, or nil.
    func companion(at now: Date) -> PocketCatWidgetPlan.Companion? {
        // The end is written before the record is removed, as two keys (X24-02): a record that
        // is also listed as ended is over.
        guard let record, !ended.contains(record.sessionID) else { return nil }
        let endsBy = record.startedAt.addingTimeInterval(Self.longestCompany)
        guard now < endsBy else { return nil }
        return .init(sessionID: record.sessionID, state: record.state, endsBy: endsBy)
    }

    /// Companions that have ended, newest last, so a write that arrives after the end
    /// ("Change expression" finishing its Live Activity update after "End company") can't bring
    /// one back. Session ids only.
    static let endedKey = "pocketCat.ended"
    static let endedKept = 8

    var ended: [String] { defaults.stringArray(forKey: Self.endedKey) ?? [] }

    private func remember(ended sessionID: String) {
        let list = ended.filter { $0 != sessionID } + [sessionID]
        defaults.set(Array(list.suffix(Self.endedKept)), forKey: Self.endedKey)
    }

    /// A companion shows `state` now. A late write for the same companion never replaces a
    /// newer expression, keeps the earliest start, and never brings back one that has ended.
    /// A write from another companion whose expression was chosen before the one on the shelf
    /// began is a late one from an older companion that ended unheard (X24-01): it doesn't
    /// replace the newer one. `PocketCatCompanyMirror.reconcile` ends a shelved companion the
    /// system no longer runs first, so an older one that really runs still gets the shelf.
    func keep(sessionID: String, state: PocketCatState, at now: Date) {
        let endedIDs = ended
        guard !endedIDs.contains(sessionID) else { return }
        var startedAt = now
        if let old = record {
            if old.sessionID == sessionID {
                if Self.changedAt(old.state) > Self.changedAt(state) { return }
                startedAt = min(old.startedAt, now)
            } else if !endedIDs.contains(old.sessionID), now < old.startedAt.addingTimeInterval(Self.longestCompany),
                      Self.changedAt(state) < old.startedAt {
                return
            }
        }
        write(Record(sessionID: sessionID, startedAt: startedAt, state: state))
    }

    /// When an expression was chosen: each change starts a new rotation.
    private static func changedAt(_ state: PocketCatState) -> Date {
        state.rotation?.startedAt ?? .distantPast
    }

    private func write(_ record: Record) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// The companion `sessionID` has ended. Another companion that is already on the shelf (a
    /// late end of an older one) stays.
    func end(sessionID: String) {
        remember(ended: sessionID)
        // Unreadable bytes are cleared too: they can't be a newer companion we could keep.
        guard (record?.sessionID ?? sessionID) == sessionID else { return }
        defaults.removeObject(forKey: Self.key)
    }

    /// No companion is running at all (the app found none): the one on the shelf has ended.
    func clear() {
        if let record { remember(ended: record.sessionID) }
        defaults.removeObject(forKey: Self.key)
    }
}
