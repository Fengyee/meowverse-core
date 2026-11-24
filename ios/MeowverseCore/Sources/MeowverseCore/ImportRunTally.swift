import Foundation

/// The single progress the system shows while user-started photo imports carry on in the
/// background. A batch from the room and photos added to one piece can run at the same time and
/// share one system bar, so the tally lasts until neither runs: a finished import keeps the photos
/// it got through as done instead of the total dropping under the user.
public struct ImportRunTally: Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        case batch
        case adding
    }

    public struct Counts: Equatable, Sendable {
        /// Photos dealt with so far (read, stored or found unreadable).
        public var shown: Int
        public var total: Int

        public init(shown: Int, total: Int) {
            self.shown = shown
            self.total = total
        }
    }

    /// What the system's progress is left with once a run is over.
    public struct Ending: Equatable, Sendable {
        public var completed: Int64
        public var total: Int64
        public var success: Bool
    }

    private var running: [Kind: Counts] = [:]
    /// Photos got through by imports that already ended during this run.
    private var ended = 0
    /// What those imports set out to do.
    private var endedPlanned = 0
    /// The last run to end.
    private var last = Counts(shown: 0, total: 0)

    public init() {}

    public var isRunning: Bool { !running.isEmpty }

    public var completed: Int { ended + running.values.reduce(0) { $0 + min(max($1.shown, 0), max($1.total, 0)) } }

    public var total: Int { ended + running.values.reduce(0) { $0 + max($1.total, 0) } }

    /// `nil` when that import ended. An import that ended early (stopped, or a save failed)
    /// counts only what it got through. Once nothing runs, the next import starts from zero.
    public mutating func update(_ kind: Kind, _ counts: Counts?) {
        if let counts {
            running[kind] = counts
            return
        }
        guard let counts = running.removeValue(forKey: kind) else { return }
        ended += min(max(counts.shown, 0), max(counts.total, 0))
        endedPlanned += max(counts.total, 0)
        if running.isEmpty {
            last = Counts(shown: ended, total: endedPlanned)
            ended = 0
            endedPlanned = 0
        }
    }

    /// For the system's progress of the run that just ended: full and a success only if every
    /// photo was dealt with and the system didn't end the task.
    public func ending(expired: Bool) -> Ending {
        let total = Int64(max(last.total, 1))
        return Ending(completed: Int64(last.shown), total: total, success: !expired && last.shown == last.total)
    }
}
