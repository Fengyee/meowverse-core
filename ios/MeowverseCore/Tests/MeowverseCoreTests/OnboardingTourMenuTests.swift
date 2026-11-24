import Foundation
import Testing
@testable import MeowverseCore

// Settings → 使用导览 (PRODUCT_PLAN §4.1, LINES.md §6), and when the first icon change may come
// (PRODUCT_PLAN §2.2 item 2, chapter 14).

/// The chapters a build tells, as `TourCoordinator.shippedChapters` filters them.
private let shipped = TourCatalog(chapters: TourCatalog.current.chapters.filter { [.welcome, .play].contains($0.id) })

private func stored(opens: Int = 1, _ endings: [TourChapterID: TourOutcome] = [:]) -> TourStored {
    var record = TourRecord()
    record.opens = opens
    for (id, outcome) in endings { record.chapters[id.rawValue] = TourEntry(outcome: outcome, revision: 1) }
    return .record(record)
}

@Suite struct TourMenuTests {
    @Test func listsTheOpeningInOrderAndNothingElseThisBuildTells() {
        let menu = TourMenu(catalog: shipped, stored: .missing, snapshot: TourSnapshot())
        #expect(menu.opening.map(\.id) == [.welcome, .play])
        #expect(menu.onDemand.isEmpty)
        #expect(menu.fromTheStart == [.welcome, .play])
    }

    @Test func aChapterALaterBuildTellsIsListedInItsGroup() {
        let more = TourCatalog(chapters: TourCatalog.current.chapters.filter { [.welcome, .bringPhoto, .play, .memories].contains($0.id) })
        let menu = TourMenu(catalog: more, stored: .missing, snapshot: TourSnapshot())
        #expect(menu.opening.map(\.id) == [.welcome, .bringPhoto, .play])
        #expect(menu.onDemand.map(\.id) == [.memories])
        #expect(menu.fromTheStart == [.welcome, .bringPhoto, .play])
    }

    @Test func eachRowSaysHowItsChapterEnded() {
        let menu = TourMenu(catalog: shipped, stored: stored([.welcome: .completed, .play: .skipped]), snapshot: TourSnapshot())
        #expect(menu.opening.map(\.status) == [.seen, .skipped])
        let all = TourMenu(catalog: shipped, stored: stored([.welcome: .skippedAll, .play: .skippedAll]), snapshot: TourSnapshot())
        #expect(all.opening.map(\.status) == [.skipped, .skipped])
        let fresh = TourMenu(catalog: shipped, stored: stored([:]), snapshot: TourSnapshot())
        #expect(fresh.opening.map(\.status) == [.notYet, .notYet])
    }

    /// Waived or written by a later version: the user did not see it here. Not "seen".
    @Test func aWaivedChapterIsNotSeen() {
        let menu = TourMenu(catalog: shipped, stored: stored([.welcome: .grandfathered, .play: .other("later")]), snapshot: TourSnapshot())
        #expect(menu.opening.map(\.status) == [.notYet, .notYet])
        let unreadable = TourMenu(catalog: shipped, stored: .unreadable, snapshot: TourSnapshot())
        #expect(unreadable.opening.map(\.status) == [.notYet, .notYet])
    }

    @Test func aChapterForAFeatureThisDeviceLacksIsNotListed() {
        let catalog = TourCatalog(chapters: TourCatalog.current.chapters.filter { [.welcome, .tabletop].contains($0.id) })
        var snapshot = TourSnapshot()
        #expect(TourMenu(catalog: catalog, stored: .missing, snapshot: snapshot).onDemand.isEmpty)
        snapshot.supportsAR = true
        #expect(TourMenu(catalog: catalog, stored: .missing, snapshot: snapshot).onDemand.map(\.id) == [.tabletop])
    }
}

@Suite struct TourIconTimingTests {
    @Test func theFirstOpenHoldsTheIconUntilTheOpeningIsOver() {
        // The tour has not met the library yet: wait for it to look.
        #expect(TourRules.iconTiming(atLaunch: .missing, now: .missing, catalog: shipped) == .wait)
        #expect(TourRules.iconTiming(atLaunch: .missing, now: stored(opens: 0), catalog: shipped) == .wait)
        // A newcomer in the middle of the opening.
        #expect(TourRules.iconTiming(atLaunch: .missing, now: stored([:]), catalog: shipped) == .hold)
        #expect(TourRules.iconTiming(atLaunch: .missing, now: stored([.welcome: .completed]), catalog: shipped) == .hold)
        // The opening is over (read, handed off or skipped): a later look may change it.
        #expect(TourRules.iconTiming(atLaunch: .missing, now: stored([.welcome: .completed, .play: .completed]), catalog: shipped) == .go)
        #expect(TourRules.iconTiming(atLaunch: .missing, now: stored([.welcome: .skippedAll, .play: .skippedAll]), catalog: shipped) == .go)
    }

    /// Someone who used the app before the tour existed is waived on the first look: their icon
    /// changes as it did before.
    @Test func aLivedInHomeIsNotHeld() {
        let waived = stored([.welcome: .grandfathered, .play: .grandfathered])
        #expect(TourRules.iconTiming(atLaunch: .missing, now: waived, catalog: shipped) == .go)
    }

    /// The second open of the library goes ahead, even with the opening still to come.
    @Test func aLaterOpenIsNotHeld() {
        let half = stored(opens: 1, [.welcome: .completed])
        #expect(TourRules.iconTiming(atLaunch: half, now: half, catalog: shipped) == .go)
        #expect(TourRules.iconTiming(atLaunch: stored(opens: 3), now: stored(opens: 3), catalog: shipped) == .go)
    }

    /// A record that cannot be read is never written over until an ending, so it would hold the
    /// icon for good.
    @Test func anUnreadableRecordDoesNotHold() {
        #expect(TourRules.iconTiming(atLaunch: .unreadable, now: .unreadable, catalog: shipped) == .go)
        #expect(TourRules.iconTiming(atLaunch: .missing, now: .unreadable, catalog: shipped) == .go)
    }
}
