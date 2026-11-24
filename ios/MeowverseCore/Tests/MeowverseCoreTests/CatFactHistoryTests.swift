import Foundation
import Testing
@testable import MeowverseCore

/// A cat fact the system has shown is never sent again for the same week, whatever happens to
/// the library, the settings or the time zone afterwards (fifth review, R5-04).
///
/// `Device` plays the notification center: it holds what was handed to it, fires each request
/// at its wall-clock time in the zone the device is in at that moment, and forgets it. `open`
/// is what `ReminderScheduler.apply` does each time the app runs.
@Suite struct CatFactHistoryTests {
    struct Shown: Equatable {
        let fact: String
        let week: Int?
        let at: Date
    }

    struct Device {
        var zone: TimeZone
        var pending: [String: PlannedReminder] = [:]
        var shown: [Shown] = []
        var history = CatFactHistory()

        var calendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar
        }

        func moment(_ reminder: PlannedReminder) -> Date? {
            var components = reminder.fireDate
            components.calendar = nil
            return calendar.date(from: components)
        }

        /// The app runs: record what left the pending list, plan, replace the pending list.
        mutating func open(_ state: AppState, _ settings: ReminderSettings, at now: Date) {
            history.noteDeliveries(pending: Set(pending.keys), now: now)
            let plan = ReminderPlanner.plan(state: state, settings: settings, now: now, calendar: calendar,
                                            consumedCatFactWeeks: history.consumedWeeks)
            pending = Dictionary(uniqueKeysWithValues: plan.filter { !$0.repeats }.map { ($0.id, $0) })
            history.noteScheduled(plan, pending: Set(pending.keys), calendar: calendar)
        }

        /// Time passes to `now`: every one-off request whose time has come is shown and leaves.
        mutating func wait(until now: Date) {
            for (id, reminder) in pending.sorted(by: { $0.key < $1.key }) {
                guard let at = moment(reminder), at <= now else { continue }
                if case .catFact(let fact) = reminder.kind { shown.append(Shown(fact: fact, week: reminder.catFactWeek, at: at)) }
                pending[id] = nil
            }
            shown.sort { $0.at < $1.at }
        }

        var pendingFacts: [PlannedReminder] {
            pending.values.filter { if case .catFact = $0.kind { true } else { false } }.sorted { $0.id < $1.id }
        }
    }

    static func photo(_ id: String, day: String) -> PhotoRecord {
        PhotoRecord(photoId: id, filename: nil, sha256: id, mimeType: "image/jpeg", byteSize: 1, width: 1, height: 1,
                    originalFile: "originals/\(id).jpeg", thumbnailFile: "thumbnails/\(id).jpg",
                    captureDate: day, captureDateSource: .exif, exifCaptureDate: day,
                    importedAt: Date(timeIntervalSince1970: 1_700_000_000), revision: 1)
    }

    static func settings(onThisDay: Bool = true, seed: UInt64 = 0) -> ReminderSettings {
        var settings = ReminderSettings()
        settings.catFactsEnabled = true
        settings.onThisDayEnabled = onThisDay
        settings.seed = seed
        return settings
    }

    static let utc = TimeZone(identifier: "UTC")!

    static func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, in zone: TimeZone = utc) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// The same month and day one year before `date`, as a capture day.
    static func dayAYearBefore(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year! - 1, c.month!, c.day!)
    }

    /// The review's case: seed 0, UTC, facts and "on this day" on, an empty library. The first
    /// fact goes out; a minute later a photo from that day a year ago arrives. The next day
    /// must not bring the same fact again.
    @Test func aShownFactIsNotSentAgainWhenItsDayGainsAMemory() throws {
        var device = Device(zone: Self.utc)
        var state = AppState(revision: 1, photos: [], observations: [], items: [], storage: [])
        let settings = Self.settings()
        device.open(state, settings, at: Self.at(2026, 11, 16, 9))
        let first = try #require(device.pendingFacts.min { device.moment($0)! < device.moment($1)! })
        let firstAt = try #require(device.moment(first))
        device.wait(until: firstAt)
        try #require(device.shown.count == 1)

        state.photos.append(Self.photo("then", day: Self.dayAYearBefore(firstAt, in: Self.utc)))
        state.revision += 1
        device.open(state, settings, at: firstAt.addingTimeInterval(60))
        for day in 1...8 {
            let morning = firstAt.addingTimeInterval(Double(day) * 86_400 - 3 * 3600)
            device.open(state, settings, at: morning)
            device.wait(until: morning.addingTimeInterval(6 * 3600))
        }
        #expect(device.shown.filter { $0.fact == device.shown[0].fact }.count == 1,
                "shown: \(device.shown.map { "\($0.fact) \($0.at)" })")
        #expect(device.shown.filter { $0.week == first.catFactWeek }.count == 1)
    }

    /// The worst case the review built: after every fact, a photo dated to that day a year ago.
    /// Over a year, no week sends twice and no fact comes back within five weeks.
    @Test(arguments: [UInt64(0), 7, 0xDEAD_BEEF])
    func aYearOfMemoriesAddedRightAfterEachFactNeverRepeatsOne(seed: UInt64) {
        var device = Device(zone: Self.utc)
        var state = AppState(revision: 1, photos: [], observations: [], items: [], storage: [])
        let settings = Self.settings(seed: seed)
        var now = Self.at(2026, 1, 1, 9)
        for _ in 0..<365 {
            device.open(state, settings, at: now)
            let before = device.shown.count
            device.wait(until: now.addingTimeInterval(3 * 3600))
            for shown in device.shown[before...] {
                state.photos.append(Self.photo("p\(state.photos.count)", day: Self.dayAYearBefore(shown.at, in: Self.utc)))
                state.revision += 1
                device.open(state, settings, at: shown.at.addingTimeInterval(60))
            }
            now = now.addingTimeInterval(86_400)
        }
        let weeks = device.shown.compactMap(\.week)
        #expect(weeks.count == Set(weeks).count, "a week sent twice")
        for (i, shown) in device.shown.enumerated() {
            for later in device.shown[(i + 1)...] where later.fact == shown.fact {
                #expect(later.at.timeIntervalSince(shown.at) > 35 * 86_400,
                        "\(shown.fact) at \(shown.at) and again at \(later.at)")
            }
        }
        // Still about weekly: the busy days only ever push a fact a day.
        #expect(device.shown.count >= 48, "\(device.shown.count) facts in a year")
    }

    /// Control: a fact not yet shown still moves to the next free day when its day gains a
    /// memory, and is then shown once.
    @Test func aPendingFactStillWaitsForTheNextFreeDay() throws {
        var device = Device(zone: Self.utc)
        var state = AppState(revision: 1, photos: [], observations: [], items: [], storage: [])
        let settings = Self.settings()
        device.open(state, settings, at: Self.at(2026, 11, 16, 9))
        let first = try #require(device.pendingFacts.min { device.moment($0)! < device.moment($1)! })
        let firstAt = try #require(device.moment(first))
        guard case .catFact(let fact) = first.kind else { Issue.record("not a fact"); return }

        state.photos.append(Self.photo("then", day: Self.dayAYearBefore(firstAt, in: Self.utc)))
        state.revision += 1
        device.open(state, settings, at: firstAt.addingTimeInterval(-3600))
        let moved = try #require(device.pendingFacts.first { $0.catFactWeek == first.catFactWeek })
        #expect(moved.kind == first.kind && moved.id != first.id)
        #expect(try #require(device.moment(moved)).timeIntervalSince(firstAt) == 86_400)
        device.wait(until: firstAt.addingTimeInterval(2 * 86_400))
        #expect(device.shown.map(\.fact) == [fact])
    }

    /// Shown in UTC, then the app opens in UTC+14 (the wall clock jumps ahead) with the day now
    /// busy: the shown week stays consumed.
    @Test func aShownFactStaysShownAfterATimeZoneChange() throws {
        var device = Device(zone: Self.utc)
        var state = AppState(revision: 1, photos: [], observations: [], items: [], storage: [])
        let settings = Self.settings()
        device.open(state, settings, at: Self.at(2026, 11, 16, 9))
        let first = try #require(device.pendingFacts.min { device.moment($0)! < device.moment($1)! })
        let firstAt = try #require(device.moment(first))
        device.wait(until: firstAt)

        device.zone = TimeZone(identifier: "Pacific/Kiritimati")!
        state.photos.append(Self.photo("then", day: Self.dayAYearBefore(firstAt, in: Self.utc)))
        state.photos.append(Self.photo("then-local", day: Self.dayAYearBefore(firstAt, in: device.zone)))
        state.revision += 1
        for hour in stride(from: 1, through: 9 * 24, by: 6) {
            let now = firstAt.addingTimeInterval(Double(hour) * 3600)
            device.open(state, settings, at: now)
            device.wait(until: now.addingTimeInterval(6 * 3600))
        }
        #expect(device.shown.filter { $0.week == first.catFactWeek }.count == 1,
                "shown: \(device.shown.map { "\($0.fact) \($0.at)" })")
    }

    /// Scheduled in one zone, shown after the device moved east before the fact's time: the
    /// wall-clock trigger fires up to 26 hours earlier than the moment recorded when it was
    /// scheduled. A photo of that day a year ago then arrives; the shown fact must not come
    /// back (QA after the fifth review: this pins `CatFactHistory.zoneMargin`).
    @Test(arguments: [("Etc/GMT+12", "Pacific/Kiritimati"), ("America/Los_Angeles", "Asia/Tokyo")])
    func aFactShownEarlyAfterMovingEastIsNotSentAgain(from: String, to: String) throws {
        let west = try #require(TimeZone(identifier: from)), east = try #require(TimeZone(identifier: to))
        var device = Device(zone: west)
        var state = AppState(revision: 1, photos: [], observations: [], items: [], storage: [])
        let settings = Self.settings()
        let opened = Self.at(2026, 11, 16, 9, in: west)
        device.open(state, settings, at: opened)
        var eastDevice = device
        eastDevice.zone = east
        // The first fact whose time in the east is still ahead when the device gets there.
        let fact = try #require(device.pendingFacts
            .filter { eastDevice.moment($0)! > opened.addingTimeInterval(3600) }
            .min { eastDevice.moment($0)! < eastDevice.moment($1)! })
        let recorded = try #require(device.moment(fact)), shownAt = try #require(eastDevice.moment(fact))
        try #require(recorded.timeIntervalSince(shownAt) > 2 * 3600, "the move must make it fire well before the recorded time")

        device.zone = east
        device.wait(until: shownAt)
        try #require(device.shown.contains { $0.week == fact.catFactWeek })
        state.photos.append(Self.photo("then", day: Self.dayAYearBefore(shownAt, in: east)))
        state.revision += 1
        device.open(state, settings, at: shownAt.addingTimeInterval(60))
        for day in 1...8 {
            let morning = shownAt.addingTimeInterval(Double(day) * 86_400 - 3 * 3600)
            device.open(state, settings, at: morning)
            device.wait(until: morning.addingTimeInterval(6 * 3600))
        }
        #expect(device.shown.filter { $0.week == fact.catFactWeek }.count == 1,
                "shown: \(device.shown.map { "\($0.fact) \($0.at)" })")
    }

    /// Old photos already there, "on this day" off; the first fact goes out, then the user turns
    /// "on this day" on, which makes that day busy. The fact is not sent again.
    @Test func turningOnThisDayOnAfterAFactDoesNotRepeatIt() throws {
        var device = Device(zone: Self.utc)
        let off = Self.settings(onThisDay: false)
        let probe = Device(zone: Self.utc)
        var state = AppState(revision: 1, photos: [], observations: [], items: [], storage: [])
        var planned = probe
        planned.open(state, off, at: Self.at(2026, 11, 16, 9))
        let firstAt = try #require(planned.pendingFacts.compactMap { planned.moment($0) }.min())
        state.photos = [Self.photo("old", day: Self.dayAYearBefore(firstAt, in: Self.utc))]

        device.open(state, off, at: Self.at(2026, 11, 16, 9))
        device.wait(until: firstAt)
        try #require(device.shown.count == 1)
        device.open(state, Self.settings(onThisDay: true), at: firstAt.addingTimeInterval(60))
        device.wait(until: firstAt.addingTimeInterval(7 * 86_400))
        #expect(device.shown.filter { $0.fact == device.shown[0].fact }.count == 1,
                "shown: \(device.shown.map { "\($0.fact) \($0.at)" })")
    }

    /// Facts the system never took, and facts the app itself replaced, are not consumed.
    @Test func onlyFactsTheSystemHeldAndThenShowedAreConsumed() throws {
        let calendar = Device(zone: Self.utc).calendar
        let plan = ReminderPlanner.plan(state: AppState(revision: 1, photos: [], observations: [], items: [], storage: []),
                                        settings: Self.settings(), now: Self.at(2026, 11, 16, 9), calendar: calendar)
        let facts = plan.filter { $0.catFactWeek != nil }
        try #require(facts.count >= 2)
        var history = CatFactHistory()
        // The system took all but the last one.
        history.noteScheduled(plan, pending: Set(facts.dropLast().map(\.id)), calendar: calendar)
        #expect(history.scheduled.count == facts.count - 1)
        let firstDue = try #require(history.scheduled[facts[0].catFactWeek!]?.due)
        history.noteDeliveries(pending: Set(facts.dropLast().map(\.id)), now: firstDue)
        #expect(history.consumedWeeks.isEmpty, "nothing has left the pending list")
        // The first was shown; the second is still pending.
        history.noteDeliveries(pending: Set(facts.dropFirst().dropLast().map(\.id)), now: firstDue)
        #expect(history.consumedWeeks == [facts[0].catFactWeek!])
        // Turning facts off: the app empties the list, after recording what it still held.
        history.noteScheduled([], pending: [], calendar: calendar)
        #expect(history.scheduled.isEmpty && history.consumedWeeks == [facts[0].catFactWeek!])
    }

    /// A device restored from a backup keeps the app's settings but none of the system's
    /// pending requests. Facts whose time had not come were removed, not shown: they are sent.
    @Test func factsGoneLongBeforeTheirTimeAreNotConsumed() throws {
        var device = Device(zone: Self.utc)
        let state = AppState(revision: 1, photos: [], observations: [], items: [], storage: [])
        let start = Self.at(2026, 11, 16, 9)
        device.open(state, Self.settings(), at: start)
        let planned = device.pendingFacts
        try #require(planned.count >= 3)
        let dues = planned.compactMap { device.moment($0) }
        device.pending = [:]
        device.open(state, Self.settings(), at: start.addingTimeInterval(60))
        let margin = CatFactHistory.zoneMargin
        for (fact, due) in zip(planned, dues) {
            let weekStillPlanned = device.pendingFacts.contains { $0.catFactWeek == fact.catFactWeek }
            // Only a fact within the zone margin of its time may have been shown already.
            #expect(weekStillPlanned == (start.addingTimeInterval(60) < due - margin), "\(fact.id) due \(due)")
        }
        #expect(device.history.consumedWeeks.count <= 1)
    }

    @Test func historyRoundTripsAndKeepsOnlyRecentWeeks() throws {
        var history = CatFactHistory()
        let calendar = Device(zone: Self.utc).calendar
        let reminders = (0..<20).map {
            PlannedReminder(id: "f\($0)", kind: .catFact("fact"), fireDate: DateComponents(year: 2026, month: 1, day: 1 + $0, hour: 10),
                            repeats: false, catFactWeek: 3000 + $0)
        }
        history.noteScheduled(reminders, pending: Set(reminders.map(\.id)), calendar: calendar)
        history.noteDeliveries(pending: [], now: Self.at(2027, 1, 1, 0))
        #expect(history.consumedWeeks == Set(3004..<3020))
        let decoded = try JSONDecoder().decode(CatFactHistory.self, from: JSONEncoder().encode(history))
        #expect(decoded == history)
    }
}
