import Foundation

// The chapters asked for again by hand (Settings › 使用导览, 「看看怎么玩」), and when the next of
// them begins (docs/onboarding/TECH_DESIGN.md §5.6). A request by hand does not wait for what only
// holds back a chapter that comes up on its own, nor for a chapter that was left behind.

/// What was asked for and has not begun yet. A value, kept in memory only.
public struct TourReplayQueue: Sendable, Equatable {
    /// How long the place has to have been free: the same dwell as an arrival. With the app's
    /// 0.1 s look a request begins within a second.
    public static let dwell: Duration = .milliseconds(800)

    /// Still to show, in order.
    public private(set) var chapters: [TourChapterID] = []
    /// Asked, and none of it has begun: the user's latest word, which wins over whatever the tour
    /// still has up. What is left of 「从头看一遍」 once it began waits for the part on screen.
    public private(set) var isNew = false

    public init() {}

    /// Replaces whatever was asked before.
    public mutating func ask(_ chapters: [TourChapterID]) {
        self.chapters = chapters
        isNew = !chapters.isEmpty
    }

    public mutating func take() -> TourChapterID? {
        guard !chapters.isEmpty else { return nil }
        isNew = false
        return chapters.removeFirst()
    }

    /// A replayed chapter ended: 「全部跳过」 also drops the rest asked for.
    public mutating func ended(_ exit: TourExit) {
        guard exit == .skippedAll else { return }
        chapters = []
        isNew = false
    }

    public enum Step: Sendable, Equatable {
        /// Nothing is asked for, or the part on screen is told first.
        case none
        /// End the chapter that is still up.
        case endShowing
        case wait
        /// Begin the next chapter asked for.
        case take
    }

    /// - Parameters:
    ///   - chapterShowing: the tour takes a chapter to be on screen.
    ///   - place: where the user is, when nothing is over it. nil: not free.
    ///   - freeFor: how long `place` has been free.
    public func step(catalog: TourCatalog, chapterShowing: Bool, place: TourSurface?, freeFor: Duration) -> Step {
        guard let next = chapters.first else { return .none }
        if chapterShowing { return isNew ? .endShowing : .none }
        guard let place, Self.canBegin(next, on: place, catalog: catalog), freeFor >= Self.dwell else { return .wait }
        return .take
    }

    /// The room has every chapter's card. A page only has its own chapter's: another one's card
    /// would be covered by that page, and the request spent on it.
    static func canBegin(_ chapter: TourChapterID, on place: TourSurface, catalog: TourCatalog) -> Bool {
        place == .room || (place == .companyPage && chapter == .company) || catalog[chapter]?.surface == place
    }
}

extension TourRules {
    /// A hand-off is recorded only on evidence that the user did it: their touch went through to
    /// the step's control, and what that control opens is open. Being gone from the step is none.
    /// A chapter left behind therefore has no ending, on a hand-off step or any other: it was not
    /// read and not skipped, and being put away does not count against it.
    public static func handOffEnding(onHandOffStep: Bool, userTouched: Bool, destinationOpened: Bool) -> TourExit? {
        onHandOffStep && userTouched && destinationOpened ? .handedOff : nil
    }
}
