import Foundation
import Testing

/// The Control Center toggle "Keep Me Company" (`ios/PocketCatShared/PocketCatCompanyToggle.swift`,
/// compiled in here through the `PocketCatShared` symlinks): what it shows, and what turning it
/// on or off does. Owner, round 11: it should behave like the flashlight.
@Suite struct PocketCatCompanyToggleTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func shelf() -> PocketCatCompanyShelf {
        let name = "PocketCatCompanyToggleTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return PocketCatCompanyShelf(defaults: defaults)
    }

    private func state(_ mood: PocketCatMood, at date: Date) -> PocketCatState {
        PocketCatState(startingWith: mood, at: date, interval: 300)
    }

    // MARK: What the toggle shows

    @Test func noCompanionShowsOff() {
        #expect(!PocketCatCompanyToggle.isOn(shelf(), at: t0))
    }

    @Test func aRunningCompanionShowsOn() {
        let shelf = shelf()
        shelf.keep(sessionID: "A", state: state(.watching, at: t0), at: t0)
        #expect(PocketCatCompanyToggle.isOn(shelf, at: t0.addingTimeInterval(60)))
    }

    /// The same guard as the widgets: an ended companion's late write doesn't turn it back on.
    @Test func anEndedCompanionsLateWriteStaysOff() {
        let shelf = shelf()
        shelf.keep(sessionID: "A", state: state(.watching, at: t0), at: t0)
        shelf.end(sessionID: "A")
        shelf.keep(sessionID: "A", state: state(.playing, at: t0.addingTimeInterval(5)), at: t0.addingTimeInterval(6))
        #expect(!PocketCatCompanyToggle.isOn(shelf, at: t0.addingTimeInterval(6)))
    }

    /// Past the system's eight-hour limit the toggle is off even if the app never heard the end.
    @Test func companyPastTheSystemsLimitShowsOff() {
        let shelf = shelf()
        shelf.keep(sessionID: "A", state: state(.sleeping, at: t0), at: t0)
        #expect(PocketCatCompanyToggle.isOn(shelf, at: t0.addingTimeInterval(PocketCatCompanyShelf.longestCompany - 1)))
        #expect(!PocketCatCompanyToggle.isOn(shelf, at: t0.addingTimeInterval(PocketCatCompanyShelf.longestCompany)))
    }

    // MARK: Turning it on

    @Test func turningOnWithNothingRunningStartsCompany() {
        #expect(PocketCatCompanyToggle.action(turningOn: true, ongoing: []) == .start(.sleeping))
    }

    /// The toggle showed off but a companion is running (the shelf was behind): on adopts that
    /// companion. It doesn't start a second one, and doesn't change its expression.
    @Test func turningOnWhileACompanionRunsAdoptsIt() {
        #expect(PocketCatCompanyToggle.action(turningOn: true, ongoing: ["A"]) == .adopt("A"))
    }

    // MARK: Turning it off

    @Test func turningOffEndsEveryRunningCompanion() {
        #expect(PocketCatCompanyToggle.action(turningOn: false, ongoing: ["A", "B"]) == .end(["A", "B"]))
        #expect(PocketCatCompanyToggle.action(turningOn: false, ongoing: []) == .end([]))
    }

    /// Off ends the Live Activity's companion on the shelf too: the widgets go back to "Keep me
    /// company", and a late write from that companion can't bring it back.
    @Test func turningOffClearsTheWidgetsCompanion() throws {
        let shelf = shelf()
        shelf.keep(sessionID: "A", state: state(.watching, at: t0), at: t0)
        PocketCatCompanyToggle.ended(PocketCatCompanyToggle.ending(["A"], on: shelf), on: shelf)
        #expect(!PocketCatCompanyToggle.isOn(shelf, at: t0.addingTimeInterval(1)))
        let plan = PocketCatWidgetPlan.plan(at: t0.addingTimeInterval(1), companion: shelf.companion(at: t0.addingTimeInterval(1)))
        #expect(plan.moments.first?.button == .start)
        shelf.keep(sessionID: "A", state: state(.eating, at: t0.addingTimeInterval(2)), at: t0.addingTimeInterval(2))
        #expect(shelf.record == nil)
    }

    /// The Live Activity was already dismissed on the Lock Screen, so nothing is running, but the
    /// shelf still holds it (the toggle showed on). Off clears it.
    @Test func turningOffClearsACompanionTheAppNeverSawEnd() {
        let shelf = shelf()
        shelf.keep(sessionID: "A", state: state(.watching, at: t0), at: t0)
        PocketCatCompanyToggle.ended(PocketCatCompanyToggle.ending([], on: shelf), on: shelf)
        #expect(shelf.record == nil)
        #expect(shelf.ended.contains("A"))
    }

    /// The shelf was behind: it holds A while B is the one running. Off ends both.
    @Test func turningOffEndsTheRunningOneAndTheShelvedOne() {
        let shelf = shelf()
        shelf.keep(sessionID: "A", state: state(.watching, at: t0), at: t0)
        PocketCatCompanyToggle.ended(PocketCatCompanyToggle.ending(["B"], on: shelf), on: shelf)
        #expect(shelf.record == nil)
        #expect(Set(shelf.ended).isSuperset(of: ["A", "B"]))
    }

    /// D24-09: off captured A, and while A's end was still being awaited company B started
    /// (another control, the widget). When the old off finishes, only A is over.
    @Test func aSlowOffLeavesACompanionStartedMeanwhile() throws {
        let shelf = shelf()
        shelf.keep(sessionID: "A", state: state(.watching, at: t0), at: t0)
        let ending = PocketCatCompanyToggle.ending(["A"], on: shelf)
        shelf.keep(sessionID: "B", state: state(.eating, at: t0.addingTimeInterval(5)), at: t0.addingTimeInterval(5))
        PocketCatCompanyToggle.ended(ending, on: shelf)
        #expect(try #require(shelf.companion(at: t0.addingTimeInterval(6))).sessionID == "B")
        #expect(shelf.ended.contains("A"))
        #expect(!shelf.ended.contains("B"))
    }
}
