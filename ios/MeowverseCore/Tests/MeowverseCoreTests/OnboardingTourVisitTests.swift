import Foundation
import Testing
@testable import MeowverseCore

// Sending the cat leaves that visit to watching her go (TECH_DESIGN §5.3): neither the receipt
// going nor the recognition ending brings a chapter over her (QA R-3).

private let start = ContinuousClock.now

/// The coordinator's looks, 0.1 s apart.
private final class Looks {
    private var visit = TourVisit()
    private var milliseconds = 0

    /// What was asked for in `seconds`; an arrival is made as the coordinator makes it.
    func look(_ seconds: Double, at place: TourSurface? = .room, sent: UUID? = nil,
              receipt: Bool = false, importing: Bool = false) -> [TourVisit.Look] {
        var asked: [TourVisit.Look] = []
        for _ in 0..<Int(seconds * 10) {
            milliseconds += 100
            let sight = TourVisit.Sight(place: place, sentCat: sent, receiptFirst: receipt, importRunning: importing)
            let found = visit.look(sight, now: start + .milliseconds(milliseconds))
            if found == .arrive {
                var snapshot = TourSnapshot()
                snapshot.surface = place ?? .elsewhere
                snapshot.importRunning = importing
                visit.arrived(with: snapshot)
            }
            if found != .none { asked.append(found) }
        }
        return asked
    }

    func receiptWent() { visit.receiptWent() }
    func chapterPutAway() { visit.chapterPutAway() }
    func interrupted() { visit.interrupted() }
    func replayBegan() { visit.replayBegan(on: .room) }
}

@Suite struct OnboardingTourVisitTests {
    private let cat = UUID()

    @Test func anArrivalIsOnceAVisit() {
        let looks = Looks()
        #expect(looks.look(0.8).isEmpty)
        #expect(looks.look(5) == [.arrive])
        #expect(looks.look(1, at: nil).isEmpty)
        #expect(looks.look(2) == [.arrive])
    }

    @Test func theReceiptGoesFirst() {
        let looks = Looks()
        #expect(looks.look(5, receipt: true).isEmpty)
        looks.receiptWent()
        #expect(looks.look(2) == [.arrive])
    }

    @Test func recognitionEndingLooksAgainInTheSameVisit() {
        let looks = Looks()
        #expect(looks.look(5, importing: true) == [.arrive])
        #expect(looks.look(2) == [.lookAgain])
    }

    @Test func recognitionThatOutlastsTheReceiptStillLooksAgain() {
        let looks = Looks()
        #expect(looks.look(5, receipt: true, importing: true).isEmpty)
        looks.receiptWent()
        #expect(looks.look(3, importing: true) == [.arrive])
        #expect(looks.look(2) == [.lookAgain])
    }

    @Test func theSentCatHasTheVisit() {
        let looks = Looks()
        #expect(looks.look(5, sent: cat).isEmpty)
    }

    @Test func theReceiptGoingDoesNotEndTheSentCatsVisit() {
        let looks = Looks()
        _ = looks.look(2, at: .interactionPanel, receipt: true)
        #expect(looks.look(2, sent: cat, receipt: true).isEmpty)
        looks.receiptWent()
        #expect(looks.look(10, sent: cat).isEmpty)
    }

    @Test func aReceiptGoneBetweenTwoLooksDoesNotEndItEither() {
        let looks = Looks()
        #expect(looks.look(2, sent: cat, receipt: true).isEmpty)
        #expect(looks.look(10, sent: cat).isEmpty)
    }

    @Test func recognitionEndingAfterTheReceiptDoesNotEndIt() {
        let looks = Looks()
        #expect(looks.look(2, sent: cat, receipt: true, importing: true).isEmpty)
        looks.receiptWent()
        #expect(looks.look(5, sent: cat, importing: true).isEmpty)
        #expect(looks.look(5, sent: cat).isEmpty)
    }

    @Test func recognitionEndingUnderTheReceiptDoesNotEndIt() {
        let looks = Looks()
        #expect(looks.look(2, sent: cat, receipt: true, importing: true).isEmpty)
        #expect(looks.look(2, sent: cat, receipt: true).isEmpty)
        looks.receiptWent()
        #expect(looks.look(5, sent: cat).isEmpty)
    }

    @Test func sendingHerAfterTheArrivalDropsTheSecondLook() {
        let looks = Looks()
        #expect(looks.look(2, importing: true) == [.arrive])
        #expect(looks.look(1, sent: cat, importing: true).isEmpty)
        #expect(looks.look(5, sent: cat).isEmpty)
    }

    @Test func puttingAwayOrHoldingTheDwellDoesNotEndIt() {
        let looks = Looks()
        #expect(looks.look(1, sent: cat).isEmpty)
        looks.chapterPutAway()
        looks.interrupted()
        #expect(looks.look(5, sent: cat).isEmpty)
        looks.replayBegan()
        #expect(looks.look(5, sent: cat).isEmpty, "a replay read in that visit brings nothing after it")
    }

    @Test func theNextVisitIsAnOrdinaryOne() {
        let looks = Looks()
        #expect(looks.look(2, sent: cat, receipt: true, importing: true).isEmpty)
        #expect(looks.look(1, at: nil, sent: cat, receipt: true, importing: true).isEmpty)
        looks.receiptWent()
        #expect(looks.look(2, sent: cat, importing: true) == [.arrive], "back from another page")
        #expect(looks.look(2, sent: cat) == [.lookAgain])
    }
}
