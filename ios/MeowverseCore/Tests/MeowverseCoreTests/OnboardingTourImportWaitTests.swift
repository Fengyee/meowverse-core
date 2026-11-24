import Foundation
import Testing
@testable import MeowverseCore

// Chapter 8 after a comparison that outlasted the receipt (TECH_DESIGN §5.3): the room is free
// while photos are compared, so the arrival is spent before the chapter is due.

private let start = ContinuousClock.now
private func at(_ milliseconds: Int) -> ContinuousClock.Instant { start + .milliseconds(milliseconds) }

private func batchHome(running: Bool) -> TourSnapshot {
    var snapshot = TourSnapshot()
    snapshot.surface = .room
    snapshot.photoCount = 3
    snapshot.unsortedPhotoCount = 3
    snapshot.importRunning = running
    return snapshot
}

/// Every chapter read but those named, and the app opened.
private func machine(left: Set<TourChapterID>) -> TourMachine {
    var record = TourRecord()
    record.opens = 1
    for chapter in TourCatalog.current.chapters where !left.contains(chapter.id) {
        record.chapters[chapter.id.rawValue] = TourEntry(outcome: .completed, revision: chapter.revision)
    }
    var machine = TourMachine(stored: .record(record))
    _ = machine.handle(.opened(.launch, batchHome(running: true)))
    return machine
}

private func started(_ effects: [TourEffect]) -> TourRun? {
    for case .start(let run) in effects { return run }
    return nil
}

/// `#expect` cannot call a mutating member, so the value under test sits in a box.
private final class Waiting {
    private var value = TourImportWait()
    var waiting: Bool { value.waiting }
    func arrived(_ snapshot: TourSnapshot) { value.arrived(snapshot) }
    func looksAgain(importRunning: Bool, now: ContinuousClock.Instant) -> Bool {
        value.looksAgain(importRunning: importRunning, now: now)
    }
}

struct OnboardingTourImportWaitTests {
    @Test func chapterEightComesWhenTheRecognitionEndsThoughTheArrivalWasSpent() {
        var tour = machine(left: [.photoBatch])
        let wait = Waiting()
        let atArrival = started(tour.handle(.arrived(batchHome(running: true))))
        #expect(atArrival == nil)
        wait.arrived(batchHome(running: true))
        for time in stride(from: 100, through: 20_000, by: 100) {
            #expect(!wait.looksAgain(importRunning: true, now: at(time)), "not over the comparison")
        }
        #expect(!wait.looksAgain(importRunning: false, now: at(20_100)), "the bar has just changed")
        #expect(wait.looksAgain(importRunning: false, now: at(20_900)))
        let atItsEnd = started(tour.handle(.factsChanged(batchHome(running: false))))
        #expect(atItsEnd?.chapter == .photoBatch)
    }

    @Test func withoutAnArrivalThereIsNothingToLookFor() {
        let wait = Waiting()
        #expect(!wait.looksAgain(importRunning: false, now: at(0)))
        #expect(!wait.looksAgain(importRunning: false, now: at(800)))
    }

    @Test func itLooksAgainOnlyOnce() {
        let wait = Waiting()
        wait.arrived(batchHome(running: true))
        #expect(!wait.looksAgain(importRunning: false, now: at(0)))
        #expect(wait.looksAgain(importRunning: false, now: at(800)))
        #expect(!wait.looksAgain(importRunning: false, now: at(900)))
        #expect(!wait.looksAgain(importRunning: true, now: at(1000)))
        #expect(!wait.looksAgain(importRunning: false, now: at(3000)), "a later comparison waits for an arrival")
    }

    @Test func aShortBreakInTheWorkIsNotItsEnd() {
        let wait = Waiting()
        wait.arrived(batchHome(running: true))
        #expect(!wait.looksAgain(importRunning: false, now: at(0)))
        #expect(!wait.looksAgain(importRunning: true, now: at(500)))
        #expect(!wait.looksAgain(importRunning: false, now: at(1000)))
        #expect(!wait.looksAgain(importRunning: false, now: at(1700)))
        #expect(wait.looksAgain(importRunning: false, now: at(1800)))
    }

    @Test func anArrivalWithNothingRunningHasNothingToWaitFor() {
        let wait = Waiting()
        wait.arrived(batchHome(running: true))
        #expect(wait.waiting)
        wait.arrived(batchHome(running: false))
        #expect(!wait.waiting, "that arrival could start the chapter itself")
        var onAPage = batchHome(running: true)
        onAPage.surface = .photoLibrary
        wait.arrived(onAPage)
        #expect(!wait.waiting, "chapter 8 begins only in the room, and going there is an arrival")
    }

    @Test func lookingAgainIsNotASecondVisit() {
        var tour = machine(left: [.photoBatch, .company])
        var home = batchHome(running: true)
        guard let first = started(tour.handle(.arrived(home))) else {
            Issue.record("the company chapter was due")
            return
        }
        #expect(first.chapter == .company)
        home.importRunning = false
        _ = tour.handle(.finished(run: first.id, .completed, home))
        let sameVisit = started(tour.handle(.factsChanged(home)))
        #expect(sameVisit == nil, "one chapter a visit")
        let nextVisit = started(tour.handle(.arrived(home)))
        #expect(nextVisit?.chapter == .photoBatch, "the next visit has it")
    }
}
