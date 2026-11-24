import Foundation
import Testing

/// The companion the app leaves in the App Group for the widgets
/// (`ios/PocketCatShared/PocketCatCompanyShelf.swift`, compiled in here through the
/// `PocketCatShared` symlinks). A late or stale write must never make a widget show a companion
/// that isn't the one on the Lock Screen.
@Suite struct PocketCatCompanyShelfTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func shelf() -> PocketCatCompanyShelf {
        let name = "PocketCatCompanyShelfTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return PocketCatCompanyShelf(defaults: defaults)
    }

    private func state(_ mood: PocketCatMood, at date: Date) -> PocketCatState {
        PocketCatState(startingWith: mood, at: date, interval: 300)
    }

    @Test func anEmptyShelfMeansNoCompany() {
        let shelf = shelf()
        #expect(shelf.record == nil)
        #expect(shelf.companion(at: t0) == nil)
    }

    /// What the app keeps is what the widget plans from, so the widget's button changes this
    /// companion and its expression is the Live Activity's.
    @Test func aKeptCompanionIsWhatTheWidgetsFollow() throws {
        let shelf = shelf()
        let watching = state(.watching, at: t0)
        shelf.keep(sessionID: "A", state: watching, at: t0)
        let companion = try #require(shelf.companion(at: t0.addingTimeInterval(10)))
        #expect(companion.sessionID == "A")
        #expect(companion.state == watching)
        let plan = PocketCatWidgetPlan.plan(at: t0.addingTimeInterval(10), companion: companion)
        #expect(plan.moments.first?.button == .change(sessionID: "A"))
        #expect(plan.moments.first?.mood == .watching)
    }

    /// "Change expression" twice in a row: if the first write lands last, the newer expression
    /// stays. The start used for the time limit stays the first one.
    @Test func aLateWriteDoesNotBringBackAnOlderExpression() throws {
        let shelf = shelf()
        shelf.keep(sessionID: "A", state: state(.sleeping, at: t0), at: t0)
        let newer = state(.zoomies, at: t0.addingTimeInterval(60))
        shelf.keep(sessionID: "A", state: newer, at: t0.addingTimeInterval(60))
        shelf.keep(sessionID: "A", state: state(.eating, at: t0.addingTimeInterval(30)), at: t0.addingTimeInterval(61))
        let record = try #require(shelf.record)
        #expect(record.state == newer)
        #expect(record.startedAt == t0)
    }

    @Test func aNewCompanionReplacesTheOldOne() throws {
        let shelf = shelf()
        shelf.keep(sessionID: "A", state: state(.sleeping, at: t0), at: t0)
        let second = state(.playing, at: t0.addingTimeInterval(100))
        shelf.keep(sessionID: "B", state: second, at: t0.addingTimeInterval(100))
        let record = try #require(shelf.record)
        #expect(record.sessionID == "B")
        #expect(record.state == second)
        #expect(record.startedAt == t0.addingTimeInterval(100))
    }

    /// Ending an older companion late (its "End company" intent running after a new one began)
    /// leaves the new one on the shelf.
    @Test func aLateEndOfAnOlderCompanionLeavesTheNewOne() {
        let shelf = shelf()
        shelf.keep(sessionID: "B", state: state(.playing, at: t0), at: t0)
        shelf.end(sessionID: "A")
        #expect(shelf.record?.sessionID == "B")
        shelf.end(sessionID: "B")
        #expect(shelf.record == nil)
        #expect(shelf.companion(at: t0) == nil)
    }

    /// "Change expression" writes after the Live Activity's update returns; if "End company"
    /// ran in between, that late write must not bring the ended companion back to the widgets.
    @Test func aLateWriteAfterTheEndDoesNotBringTheCompanionBack() {
        let shelf = shelf()
        shelf.keep(sessionID: "A", state: state(.sleeping, at: t0), at: t0)
        shelf.end(sessionID: "A")
        shelf.keep(sessionID: "A", state: state(.playing, at: t0.addingTimeInterval(5)), at: t0.addingTimeInterval(6))
        #expect(shelf.record == nil)
        #expect(shelf.companion(at: t0.addingTimeInterval(6)) == nil)
        // A new companion is kept as usual, and the old one's late end doesn't touch it.
        shelf.keep(sessionID: "B", state: state(.eating, at: t0.addingTimeInterval(10)), at: t0.addingTimeInterval(10))
        shelf.end(sessionID: "A")
        #expect(shelf.record?.sessionID == "B")
    }

    /// The app finding no companion at all (`clear`) also counts as the end of the one on the
    /// shelf, so its late write can't come back either.
    @Test func aLateWriteAfterClearingDoesNotComeBack() {
        let shelf = shelf()
        shelf.keep(sessionID: "A", state: state(.sleeping, at: t0), at: t0)
        shelf.clear()
        shelf.keep(sessionID: "A", state: state(.playing, at: t0.addingTimeInterval(5)), at: t0.addingTimeInterval(6))
        #expect(shelf.record == nil)
    }

    /// Only a handful of ended ids are remembered.
    @Test func theEndedListStaysShort() {
        let shelf = shelf()
        for index in 0..<50 { shelf.end(sessionID: "S\(index)") }
        #expect(shelf.ended.count == PocketCatCompanyShelf.endedKept)
        #expect(shelf.ended.last == "S49")
    }

    /// The shelf tells the plan when the system will have ended this companion.
    @Test func theCompanionCarriesTheSystemsLimit() throws {
        let shelf = shelf()
        shelf.keep(sessionID: "A", state: state(.sleeping, at: t0), at: t0)
        let companion = try #require(shelf.companion(at: t0))
        #expect(companion.endsBy == t0.addingTimeInterval(PocketCatCompanyShelf.longestCompany))
    }

    @Test func clearingRemovesAnyCompanion() {
        let shelf = shelf()
        shelf.keep(sessionID: "A", state: state(.sleeping, at: t0), at: t0)
        #expect(shelf.record != nil)
        shelf.clear()
        #expect(shelf.record == nil)
    }

    /// The system ends company after eight hours even if the app never hears it.
    @Test func companyOlderThanTheSystemsLimitIsOver() {
        let shelf = shelf()
        shelf.keep(sessionID: "A", state: state(.sleeping, at: t0), at: t0)
        shelf.keep(sessionID: "A", state: state(.eating, at: t0.addingTimeInterval(7 * 3600)), at: t0.addingTimeInterval(7 * 3600))
        #expect(shelf.companion(at: t0.addingTimeInterval(PocketCatCompanyShelf.longestCompany - 1)) != nil)
        #expect(shelf.companion(at: t0.addingTimeInterval(PocketCatCompanyShelf.longestCompany)) == nil)
    }

    /// Bytes the widget can't read (a later format, or damage) mean no company, not a crash.
    @Test func unreadableBytesMeanNoCompany() {
        let shelf = shelf()
        shelf.defaults.set(Data("not json".utf8), forKey: PocketCatCompanyShelf.key)
        #expect(shelf.companion(at: t0) == nil)
        shelf.keep(sessionID: "A", state: state(.sleeping, at: t0), at: t0)
        #expect(shelf.companion(at: t0)?.sessionID == "A")
    }

    /// Only the companion goes into the shared container: no name, photo or count.
    @Test func onlyTheCompanionIsShared() throws {
        let shelf = shelf()
        shelf.keep(sessionID: "A", state: state(.thinking, at: t0), at: t0)
        let data = try #require(shelf.defaults.data(forKey: PocketCatCompanyShelf.key))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["sessionID", "startedAt", "state"])
        let keys = { Set(shelf.defaults.dictionaryRepresentation().keys).filter { $0.hasPrefix("pocketCat") } }
        #expect(keys() == [PocketCatCompanyShelf.key])
        shelf.end(sessionID: "A")
        #expect(keys() == [PocketCatCompanyShelf.endedKey])
        // The ended list holds session ids only.
        #expect(shelf.defaults.stringArray(forKey: PocketCatCompanyShelf.endedKey) == ["A"])
    }
}
