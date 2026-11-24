import Foundation

// When chapter 8 is looked for again (docs/onboarding/TECH_DESIGN.md §5.3). `importRunning` is
// wider than "the room is busy": photos are compared in a free room, so the arrival in that room
// is spent while the chapter is not due yet, and nothing else would look again when that ends.

/// An arrival in the room that came while an import or its comparison still ran. When that has
/// ended, the tour looks again with `TourEvent.factsChanged`: the same visit, so it brings
/// nothing when this visit already had a chapter.
public struct TourImportWait: Sendable, Equatable {
    /// How long it has to have ended: the same dwell as an arrival. A short break is not the end.
    public static let dwell: Duration = .milliseconds(800)

    public private(set) var waiting = false
    private var endedAt: ContinuousClock.Instant?

    public init() {}

    /// Every arrival replaces what the one before left.
    public mutating func arrived(_ snapshot: TourSnapshot) {
        waiting = snapshot.surface == .room && snapshot.importRunning
        endedAt = nil
    }

    /// Asked only while the user is still in the free room. True once for each such arrival.
    public mutating func looksAgain(importRunning: Bool, now: ContinuousClock.Instant) -> Bool {
        guard waiting, !importRunning else {
            endedAt = nil
            return false
        }
        let since = endedAt ?? now
        endedAt = since
        guard now - since >= Self.dwell else { return false }
        self = TourImportWait()
        return true
    }
}
