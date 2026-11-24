import Foundation
import Testing
@testable import MeowverseCore

// 「从头看一遍」 and one chapter from Settings: a request by hand wins over a chapter that was left
// behind, and begins only where it can be seen (owner's iPhone, 2026-11-21: both did nothing).

@Suite struct OnboardingTourReplayQueueTests {
    private let catalog = TourCatalog.thisBuild
    private let dwell = TourReplayQueue.dwell

    private func asked(_ chapters: TourChapterID...) -> TourReplayQueue {
        var queue = TourReplayQueue()
        queue.ask(chapters)
        return queue
    }

    private func step(_ queue: TourReplayQueue, showing: Bool = false, at place: TourSurface? = .room,
                      freeFor: Duration = .seconds(5)) -> TourReplayQueue.Step {
        queue.step(catalog: catalog, chapterShowing: showing, place: place, freeFor: freeFor)
    }

    @Test func nothingAskedDoesNothing() {
        #expect(step(TourReplayQueue()) == .none)
        #expect(step(TourReplayQueue(), showing: true) == .none)
        #expect(step(asked()) == .none)
    }

    @Test func aNewRequestEndsTheChapterLeftBehindWhereverTheUserIs() {
        let queue = asked(.welcome)
        #expect(step(queue, showing: true) == .endShowing)
        #expect(step(queue, showing: true, at: nil, freeFor: .zero) == .endShowing)
    }

    @Test func theRestOfFromTheStartWaitsForTheChapterOnScreen() {
        var queue = asked(.welcome, .bringPhoto)
        let first = queue.take(); #expect(first == .welcome)
        #expect(step(queue, showing: true) == .none)
        #expect(step(queue) == .take)
    }

    @Test func askingAgainMidwayIsANewRequest() {
        var queue = asked(.welcome, .bringPhoto)
        _ = queue.take()
        queue.ask([.topRow])
        #expect(queue.chapters == [.topRow])
        #expect(step(queue, showing: true) == .endShowing)
    }

    @Test func aRequestBeginsWithinASecondOfTheRoomBeingFree() {
        let queue = asked(.topRow)
        #expect(dwell == .milliseconds(800))
        #expect(step(queue, freeFor: dwell - .milliseconds(1)) == .wait)
        #expect(step(queue, freeFor: dwell) == .take)
        #expect(dwell + .milliseconds(100) <= .seconds(1), "with the coordinator's 0.1 s tick")
    }

    @Test func aRequestWaitsWhileNothingIsFree() {
        #expect(step(asked(.topRow), at: nil) == .wait)
    }

    /// Begun on another page, its card was covered for 30 s and the request was spent.
    @Test func aRequestBeginsOnAPageOnlyWhenThatPageIsItsOwn() {
        #expect(step(asked(.photoLibrary), at: .photoLibrary) == .take)
        #expect(step(asked(.sendCat), at: .interactionPanel) == .take)
        #expect(step(asked(.company), at: .companyPage) == .take)
        #expect(step(asked(.topRow), at: .photoLibrary) == .wait)
        #expect(step(asked(.company), at: .interactionPanel) == .wait)
        #expect(step(asked(.photoLibrary), at: .room) == .take)
        #expect(step(asked(.topRow), at: .elsewhere) == .wait)
    }

    @Test func skipAllDropsTheRestAndSkippingOneDoesNot() {
        var queue = asked(.welcome, .bringPhoto)
        _ = queue.take()
        queue.ended(.skipped)
        #expect(queue.chapters == [.bringPhoto])
        queue.ended(.skippedAll)
        #expect(queue.chapters.isEmpty)
        #expect(step(queue) == .none)
    }

    // MARK: How a chapter left behind is recorded

    /// Never on screen (3.1 folded away), read as a page (13.1), or a touch that opened nothing.
    @Test func leftOnAHandOffStepItHasNoEnding() {
        #expect(TourRules.handOffEnding(onHandOffStep: true, userTouched: false, destinationOpened: false) == nil)
        #expect(TourRules.handOffEnding(onHandOffStep: true, userTouched: true, destinationOpened: false) == nil)
    }

    /// A quick action opens the camera, a notification a page: not the user's hand on the target.
    @Test func aDestinationOpenedFromOutsideIsNotHandedOver() {
        #expect(TourRules.handOffEnding(onHandOffStep: true, userTouched: false, destinationOpened: true) == nil)
    }

    @Test func theUsersTouchThatOpenedTheDestinationIsHandedOver() {
        #expect(TourRules.handOffEnding(onHandOffStep: true, userTouched: true, destinationOpened: true) == .handedOff)
    }

    @Test func leftOnAnyOtherStepItHasNoEnding() {
        #expect(TourRules.handOffEnding(onHandOffStep: false, userTouched: true, destinationOpened: true) == nil)
    }

    /// Putting it away invents no ending and is not counted against it, and the replay then runs.
    @Test func puttingAwayForAReplayKeepsTheRecordAndLetsTheReplayBegin() throws {
        var machine = TourMachine(catalog: catalog, settles: .current, stored: .missing)
        let snapshot = TourSnapshot()
        _ = machine.handle(.opened(.launch, snapshot))
        _ = machine.handle(.arrived(snapshot))
        let left = try #require(machine.session.run)
        #expect(left.chapter == .welcome)
        _ = machine.handle(.interrupted(run: left.id, .blocked))
        #expect(machine.record.entry(for: .welcome) == nil)
        #expect(machine.record.interruptions.isEmpty)
        _ = machine.handle(.replay(.topRow, snapshot))
        let replay = try #require(machine.session.run)
        #expect(replay.chapter == .topRow)
        // A late report from the chapter that was put away moves nothing.
        _ = machine.handle(.finished(run: left.id, .completed, snapshot))
        #expect(machine.session.run == replay)
        #expect(machine.record.entry(for: .welcome) == nil)
    }
}
