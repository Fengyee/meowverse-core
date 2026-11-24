import Foundation

// One stay in the free room, or on a page a chapter begins on (docs/onboarding/TECH_DESIGN.md
// §5.3): when the tour looks for a chapter to tell on its own. A request by hand does not ask here.

/// A value, fed with what is true at each of the app's looks while no chapter is on screen.
public struct TourVisit: Sendable, Equatable {
    /// How long the place has to have been free before it counts as arrived at.
    public static let dwell: Duration = .milliseconds(800)

    public struct Sight: Sendable, Equatable {
        /// Where the user is with nothing over it. nil: not free.
        public var place: TourSurface?
        /// The last time the cat was sent to a piece. It outlasts the visit it was done in.
        public var sentCat: UUID?
        /// A photo was just filed: its receipt goes first (Q-18).
        public var receiptFirst: Bool
        public var importRunning: Bool

        public init(place: TourSurface?, sentCat: UUID?, receiptFirst: Bool, importRunning: Bool) {
            self.place = place
            self.sentCat = sentCat
            self.receiptFirst = receiptFirst
            self.importRunning = importRunning
        }
    }

    public enum Look: Sendable, Equatable {
        case none
        /// `TourEvent.arrived`, and 「都讲完啦」 may come.
        case arrive
        /// `TourEvent.factsChanged`: the same visit.
        case lookAgain
    }

    private var place: TourSurface?
    private var arrived = false
    private var freeSince: ContinuousClock.Instant?
    private var sentSeen: UUID?
    /// The cat was sent in this visit: it is for watching her go, and nothing comes on its own
    /// until the user leaves the free room.
    private var quiet = false
    private var importWait = TourImportWait()

    public init() {}

    public mutating func look(_ sight: Sight, now: ContinuousClock.Instant) -> Look {
        if sight.place != place {
            place = sight.place
            freeSince = nil
            arrived = false
            quiet = false
        }
        if place == .room, sight.sentCat != sentSeen {
            sentSeen = sight.sentCat
            if sentSeen != nil { quiet = true }
        }
        guard !quiet else { return .none }
        guard !sight.receiptFirst, let place else {
            freeSince = nil
            arrived = false
            return .none
        }
        let since = freeSince ?? now
        freeSince = since
        if !arrived {
            guard now - since >= Self.dwell else { return .none }
            arrived = true
            return .arrive
        }
        guard place == .room, importWait.looksAgain(importRunning: sight.importRunning, now: now) else { return .none }
        return .lookAgain
    }

    /// The arrival `look` asked for was made, with these facts.
    public mutating func arrived(with snapshot: TourSnapshot) {
        importWait.arrived(snapshot)
    }

    /// The receipt went: chapter 6 may be due now (Q-18).
    public mutating func receiptWent() {
        arrived = false
    }

    /// The chapter on screen was put away for something that is no ending: it may come again.
    public mutating func chapterPutAway() {
        arrived = false
    }

    /// The app is not in front, or a request by hand holds the place: the dwell starts over.
    public mutating func interrupted() {
        freeSince = nil
    }

    /// A chapter asked for by hand began here: this arrival is spent.
    public mutating func replayBegan(on place: TourSurface?) {
        if self.place != place { quiet = false }
        self.place = place
        arrived = true
        freeSince = nil
    }
}
