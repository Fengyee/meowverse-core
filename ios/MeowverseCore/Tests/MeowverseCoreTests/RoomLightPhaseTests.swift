import Foundation
import Testing
@testable import MeowverseCore

struct RoomLightPhaseTests {
    private func calendar(_ identifier: String) throws -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: identifier))
        return cal
    }

    @Test func phasesChangeAtTheLocalHour() throws {
        let cal = try calendar("Asia/Shanghai")
        let boundaries: [(String, RoomLightPhase)] = [
            ("2026-11-13T05:59:59+08:00", .night), ("2026-11-13T06:00:00+08:00", .dawn),
            ("2026-11-13T08:59:59+08:00", .dawn), ("2026-11-13T09:00:00+08:00", .daylight),
            ("2026-11-13T16:59:59+08:00", .daylight), ("2026-11-13T17:00:00+08:00", .dusk),
            ("2026-11-13T20:59:59+08:00", .dusk), ("2026-11-13T21:00:00+08:00", .night)
        ]
        for (stamp, phase) in boundaries {
            let date = try Date(stamp, strategy: .iso8601)
            #expect(RoomLightPhase.local(at: date, in: cal) == phase)
        }
        for i in stride(from: 0, to: boundaries.count, by: 2) {
            let before = try Date(boundaries[i].0, strategy: .iso8601)
            let at = try Date(boundaries[i + 1].0, strategy: .iso8601)
            #expect(RoomLightPhase.nextChange(after: before, in: cal) == at)
            #expect(try #require(RoomLightPhase.nextChange(after: at, in: cal)) > at)
        }
    }

    @Test func changingTimeZoneReevaluatesTheSameInstant() throws {
        let date = try Date("2026-11-13T23:00:00Z", strategy: .iso8601)
        #expect(RoomLightPhase.local(at: date, in: try calendar("Asia/Shanghai")) == .dawn)
        #expect(RoomLightPhase.local(at: date, in: try calendar("America/New_York")) == .dusk)
    }

    @Test func nextDawnUsesLocalClockAcrossDaylightSavingChanges() throws {
        let cal = try calendar("America/New_York")
        let transitions = [
            ("2026-03-07T21:00:00-05:00", "2026-03-08T06:00:00-04:00"),
            ("2026-10-31T21:00:00-04:00", "2026-11-01T06:00:00-05:00")
        ]
        for (start, end) in transitions {
            let night = try Date(start, strategy: .iso8601)
            let dawn = try Date(end, strategy: .iso8601)
            #expect(RoomLightPhase.nextChange(after: night, in: cal) == dawn)
        }
    }
}
