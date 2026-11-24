import Foundation
import Testing
@testable import MeowverseCore

/// Local reminders: what gets scheduled for the next days, from the library and the user's settings.
@Suite struct ReminderPlannerTests {
    // MARK: Fixtures

    func photo(_ id: String, day: String?, source: CaptureDateSource? = nil) -> PhotoRecord {
        PhotoRecord(photoId: id, filename: nil, sha256: id, mimeType: "image/jpeg", byteSize: 1, width: 1, height: 1,
                    originalFile: "originals/\(id).jpeg", thumbnailFile: "thumbnails/\(id).jpg",
                    captureDate: day, captureDateSource: source ?? (day == nil ? .unknown : .exif),
                    exifCaptureDate: nil, importedAt: Date(timeIntervalSince1970: 1_700_000_000), revision: 1)
    }

    func piece(_ id: String, name: String? = nil, photos: [String], relation: Relation = .on) -> PhotoFurniture {
        PhotoFurniture(instanceId: id, modelId: "kenney-chair", x: 0, z: 0, width: 1, depth: 1, turn: 0,
                       finish: .original, displayName: name ?? id,
                       sources: photos.map { PhotoCarrierSource(photoId: $0, observationId: nil, objectIndex: nil, origin: .user, relationToCat: relation) },
                       tags: [], revision: 1)
    }

    func state(photos: [PhotoRecord], items: [PhotoFurniture] = [], storage: [PhotoFurniture] = []) -> AppState {
        AppState(revision: 1, photos: photos, observations: [], items: items, storage: storage)
    }

    func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    /// A moment given as local wall-clock time in `calendar`.
    func moment(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9, _ min: Int = 0, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func settings(calls: Bool = false, times: [ReminderTime] = [ReminderTime(hour: 8, minute: 0)],
                  onThisDay: Bool = false, furniture: Bool = false, facts: Bool = false, seed: UInt64 = 7) -> ReminderSettings {
        var s = ReminderSettings()
        s.catFactsEnabled = facts
        s.callsEnabled = calls
        s.callTimes = times
        s.onThisDayEnabled = onThisDay
        s.furnitureEnabled = furniture
        s.seed = seed
        return s
    }

    /// On-this-day and furniture memories (cat facts are not memories).
    func memories(_ plan: [PlannedReminder]) -> [PlannedReminder] {
        plan.filter { if case .onThisDay = $0.kind { true } else if case .furniture = $0.kind { true } else { false } }
    }

    func catFacts(_ plan: [PlannedReminder]) -> [(PlannedReminder, String)] {
        plan.compactMap { if case .catFact(let id) = $0.kind { ($0, id) } else { nil } }
    }

    /// A rotation that does not depend on which facts have been checked so far.
    static let sampleFacts = (1...20).map { "fact.sample-\($0)" }

    func onThisDays(_ plan: [PlannedReminder]) -> [(PlannedReminder, OnThisDayMemory)] {
        plan.compactMap { if case .onThisDay(let m) = $0.kind { ($0, m) } else { nil } }
    }

    func furnitureMemories(_ plan: [PlannedReminder]) -> [(PlannedReminder, FurnitureMemory)] {
        plan.compactMap { if case .furniture(let m) = $0.kind { ($0, m) } else { nil } }
    }

    func day(_ r: PlannedReminder) -> String {
        String(format: "%04d-%02d-%02d", r.fireDate.year!, r.fireDate.month!, r.fireDate.day!)
    }

    // MARK: Off by default, disabled kinds

    @Test func defaultSettingsAreAllOff() {
        let s = ReminderSettings()
        #expect(!s.callsEnabled && !s.onThisDayEnabled && !s.furnitureEnabled && !s.catFactsEnabled)
        #expect(!s.anyEnabled)
    }

    @Test func disabledKindsProduceNothing() {
        let cal = calendar()
        let st = state(photos: [photo("a", day: "2024-03-15")], items: [piece("sofa", photos: ["a"])])
        let plan = ReminderPlanner.plan(state: st, settings: settings(), now: moment(2026, 3, 1, in: cal), calendar: cal)
        #expect(plan.isEmpty)
    }

    // MARK: Cat calls

    @Test func callsRepeatWeeklyPerWeekdayAndRotateTheLines() {
        let cal = calendar()
        let plan = ReminderPlanner.plan(state: .empty, settings: settings(calls: true), now: moment(2026, 3, 1, in: cal), calendar: cal)
        #expect(plan.count == 7)
        #expect(plan.allSatisfy { $0.repeats && $0.furnitureID == nil })
        #expect(Set(plan.map { $0.fireDate.weekday! }) == Set(1...7))
        #expect(plan.allSatisfy { $0.fireDate.hour == 8 && $0.fireDate.minute == 0 && $0.fireDate.day == nil })
        let lines = plan.compactMap { if case .call(let line) = $0.kind { line } else { nil } }
        #expect(Set(lines) == Set(CatCall.allCases), "all three calls are heard during the week")
        #expect(Set(plan.map(\.id)).count == plan.count)
    }

    @Test func twoCallTimesGiveTwoSlotsAndExtraTimesAreIgnored() {
        let cal = calendar()
        let times = [ReminderTime(hour: 8, minute: 0), ReminderTime(hour: 18, minute: 30), ReminderTime(hour: 22, minute: 0)]
        let plan = ReminderPlanner.plan(state: .empty, settings: settings(calls: true, times: times), now: moment(2026, 3, 1, in: cal), calendar: cal)
        #expect(plan.count == 14)
        #expect(Set(plan.map { $0.fireDate.hour! }) == [8, 18])
    }

    @Test func duplicateOrInvalidCallTimesAreDropped() {
        let cal = calendar()
        let times = [ReminderTime(hour: 8, minute: 0), ReminderTime(hour: 8, minute: 0)]
        #expect(ReminderPlanner.plan(state: .empty, settings: settings(calls: true, times: times), now: moment(2026, 3, 1, in: cal), calendar: cal).count == 7)
        let bad = [ReminderTime(hour: 25, minute: 0), ReminderTime(hour: 7, minute: 61)]
        #expect(ReminderPlanner.plan(state: .empty, settings: settings(calls: true, times: bad), now: moment(2026, 3, 1, in: cal), calendar: cal).isEmpty)
        #expect(ReminderPlanner.plan(state: .empty, settings: settings(calls: true, times: []), now: moment(2026, 3, 1, in: cal), calendar: cal).isEmpty)
    }

    // MARK: On this day

    @Test func noPhotosMeansNoMemories() {
        let cal = calendar()
        let plan = ReminderPlanner.plan(state: .empty, settings: settings(onThisDay: true, furniture: true),
                                        now: moment(2026, 3, 1, in: cal), calendar: cal)
        #expect(plan.isEmpty)
    }

    @Test func allDatesUnknownMeansNoOnThisDay() {
        let cal = calendar()
        // A stray day string with an `unknown` source is not a known date, and a malformed one is ignored.
        let st = state(photos: [photo("a", day: nil), photo("b", day: "2024-03-02", source: .unknown), photo("c", day: "2024-3-2")])
        let plan = ReminderPlanner.plan(state: st, settings: settings(onThisDay: true), now: moment(2026, 3, 1, in: cal), calendar: cal)
        #expect(plan.isEmpty)
    }

    @Test func importTimeNeverStandsInForACaptureDay() {
        let cal = calendar()
        // importedAt is 2023-11-14; the photo has no known day: nothing on 11-14.
        let st = state(photos: [photo("a", day: nil)])
        let plan = ReminderPlanner.plan(state: st, settings: settings(onThisDay: true), now: moment(2026, 11, 1, in: cal), calendar: cal)
        #expect(plan.isEmpty)
    }

    @Test func aPhotoFromAnEarlierYearIsRememberedOnItsDayAtTheMemoryTime() throws {
        let cal = calendar()
        let st = state(photos: [photo("a", day: "2024-03-15")], items: [piece("sofa", name: "双人沙发", photos: ["a"])])
        let plan = ReminderPlanner.plan(state: st, settings: settings(onThisDay: true), now: moment(2026, 3, 1, in: cal), calendar: cal)
        let found = onThisDays(plan)
        #expect(found.count == 1)
        let (reminder, memory) = try #require(found.first)
        #expect(day(reminder) == "2026-03-15")
        #expect(reminder.fireDate.hour == 20 && reminder.fireDate.minute == 0)
        #expect(memory.yearsAgo == 2)
        #expect(memory.photoCount == 1)
        #expect(memory.piece?.instanceId == "sofa")
        #expect(memory.piece?.displayName == "双人沙发")
        #expect(memory.piece?.relation == .on)
        #expect(reminder.furnitureID == "sofa")
    }

    @Test func aPhotoFromThisYearOrTheFutureIsNotAMemory() {
        let cal = calendar()
        let st = state(photos: [photo("a", day: "2026-03-15"), photo("b", day: "2027-03-16")])
        let plan = ReminderPlanner.plan(state: st, settings: settings(onThisDay: true), now: moment(2026, 3, 1, in: cal), calendar: cal)
        #expect(plan.isEmpty)
    }

    @Test func aUserEnteredDayCountsAsKnown() {
        let cal = calendar()
        let st = state(photos: [photo("a", day: "2025-03-10", source: .user)])
        let plan = ReminderPlanner.plan(state: st, settings: settings(onThisDay: true), now: moment(2026, 3, 1, in: cal), calendar: cal)
        #expect(onThisDays(plan).map { day($0.0) } == ["2026-03-10"])
        #expect(onThisDays(plan).first?.1.piece == nil, "an unlinked photo gets the generic line")
        #expect(plan.first?.furnitureID == nil)
    }

    @Test func leapDayOnlyMatchesLeapDay() {
        let cal = calendar()
        let st = state(photos: [photo("leap", day: "2024-02-29"), photo("feb28", day: "2023-02-28")])
        // 2027 is not a leap year: Feb 28 gets the Feb 28 photo only, and there is no Feb 29 / Mar 1 stand-in.
        let plan2027 = ReminderPlanner.plan(state: st, settings: settings(onThisDay: true), now: moment(2027, 2, 20, in: cal), calendar: cal)
        #expect(onThisDays(plan2027).map { day($0.0) } == ["2027-02-28"])
        #expect(onThisDays(plan2027).first?.1.photoId == "feb28")
        // 2028 is: Feb 29 gets the leap-day photo, four years on.
        let plan2028 = ReminderPlanner.plan(state: st, settings: settings(onThisDay: true), now: moment(2028, 2, 20, in: cal), calendar: cal)
        let days = onThisDays(plan2028)
        #expect(days.map { day($0.0) } == ["2028-02-28", "2028-02-29"])
        #expect(days.last?.1.photoId == "leap")
        #expect(days.last?.1.yearsAgo == 4)
    }

    @Test func sameDayInDifferentYearsIsOneNotificationAndCountsOnlyTheChosenYear() throws {
        let cal = calendar()
        let st = state(photos: [photo("y22a", day: "2022-03-15"), photo("y22b", day: "2022-03-15"), photo("y24", day: "2024-03-15")])
        let plan = ReminderPlanner.plan(state: st, settings: settings(onThisDay: true), now: moment(2026, 3, 1, in: cal), calendar: cal)
        let found = onThisDays(plan)
        #expect(found.count == 1, "one notification per day, however many years match")
        let memory = try #require(found.first?.1)
        if memory.yearsAgo == 4 {
            #expect(memory.photoCount == 2)
        } else {
            #expect(memory.yearsAgo == 2)
            #expect(memory.photoCount == 1)
        }
    }

    @Test func aLinkedPhotoIsPreferredOverAnUnlinkedOne() {
        let cal = calendar()
        let st = state(photos: [photo("loose1", day: "2022-03-15"), photo("linked", day: "2023-03-15"), photo("loose2", day: "2024-03-15")],
                       items: [piece("tree", name: "猫爬架", photos: ["linked"])])
        for seed in UInt64(0)..<6 {
            let plan = ReminderPlanner.plan(state: st, settings: settings(onThisDay: true, seed: seed), now: moment(2026, 3, 1, in: cal), calendar: cal)
            #expect(onThisDays(plan).first?.1.photoId == "linked")
            #expect(onThisDays(plan).first?.1.yearsAgo == 3)
        }
    }

    @Test func aStoredPieceIsStillRememberedAndSaysItIsStored() {
        let cal = calendar()
        let st = state(photos: [photo("a", day: "2024-03-15")], storage: [piece("box", name: "藏身窝", photos: ["a"], relation: .in)])
        let plan = ReminderPlanner.plan(state: st, settings: settings(onThisDay: true), now: moment(2026, 3, 1, in: cal), calendar: cal)
        let memory = onThisDays(plan).first?.1
        #expect(memory?.piece?.instanceId == "box")
        #expect(memory?.piece?.isStored == true)
        #expect(memory?.piece?.relation == .in)
    }

    @Test func aDeletedPieceIsNeverNamed() {
        let cal = calendar()
        // The piece is gone (not in the room or storage): the photo is remembered on its own.
        let st = state(photos: [photo("a", day: "2024-03-15")])
        let plan = ReminderPlanner.plan(state: st, settings: settings(onThisDay: true, furniture: true), now: moment(2026, 3, 1, in: cal), calendar: cal)
        #expect(onThisDays(plan).count == 1)
        #expect(onThisDays(plan).first?.1.piece == nil)
        #expect(furnitureMemories(plan).isEmpty)
    }

    @Test func todayIsIncludedOnlyBeforeTheMemoryTime() {
        let cal = calendar()
        let st = state(photos: [photo("a", day: "2024-03-15")])
        let before = ReminderPlanner.plan(state: st, settings: settings(onThisDay: true), now: moment(2026, 3, 15, 19, 59, in: cal), calendar: cal)
        #expect(onThisDays(before).map { day($0.0) } == ["2026-03-15"])
        let after = ReminderPlanner.plan(state: st, settings: settings(onThisDay: true), now: moment(2026, 3, 15, 20, 0, in: cal), calendar: cal)
        #expect(onThisDays(after).isEmpty)
    }

    @Test func theCalendarTimeZoneDecidesWhatTodayIs() {
        // 2026-03-14 20:30 UTC is already 2026-03-15 04:30 in Shanghai, but still the 14th in Los Angeles.
        let now = ISO8601DateFormatter().date(from: "2026-03-14T20:30:00Z")!
        let st = state(photos: [photo("a", day: "2024-03-14"), photo("b", day: "2024-03-15")])
        let shanghai = ReminderPlanner.plan(state: st, settings: settings(onThisDay: true), now: now, calendar: calendar("Asia/Shanghai"), horizonDays: 1)
        #expect(onThisDays(shanghai).map { $0.1.photoId } == ["b"])
        let losAngeles = ReminderPlanner.plan(state: st, settings: settings(onThisDay: true), now: now, calendar: calendar("America/Los_Angeles"), horizonDays: 1)
        #expect(onThisDays(losAngeles).map { $0.1.photoId } == ["a"])
    }

    // MARK: Furniture memories

    @Test func furnitureMemoriesComeAboutWeeklyForPiecesWithPhotos() {
        let cal = calendar()
        let st = state(photos: [photo("a", day: nil), photo("b", day: nil), photo("c", day: nil)],
                       items: [piece("tree", name: "猫爬架", photos: ["a", "b"]), piece("bare", photos: [])],
                       storage: [piece("bed", photos: ["c"])])
        let plan = ReminderPlanner.plan(state: st, settings: settings(furniture: true), now: moment(2026, 3, 1, in: cal), calendar: cal)
        let found = furnitureMemories(plan)
        #expect((4...5).contains(found.count), "30 days hold four or five weekly reminders")
        #expect(found.allSatisfy { $0.1.instanceId != "bare" }, "a piece without photos is never picked")
        #expect(Set(found.map(\.1.instanceId)) == ["tree", "bed"], "pieces take turns, stored ones included")
        #expect(found.first { $0.1.instanceId == "tree" }?.1.photoCount == 2)
        #expect(found.first { $0.1.instanceId == "bed" }?.1.isStored == true)
        #expect(found.allSatisfy { $0.0.furnitureID == $0.1.instanceId })
        // Seven days apart.
        let dates = found.map { cal.date(from: $0.0.fireDate)! }
        for (a, b) in zip(dates, dates.dropFirst()) {
            #expect(cal.dateComponents([.day], from: a, to: b).day == 7)
        }
    }

    @Test func aPhotoCountIgnoresSourcesWhosePhotoIsGone() {
        let cal = calendar()
        let st = state(photos: [photo("a", day: nil)], items: [piece("tree", photos: ["a", "missing"]), piece("ghost", photos: ["gone"])])
        let found = furnitureMemories(ReminderPlanner.plan(state: st, settings: settings(furniture: true), now: moment(2026, 3, 1, in: cal), calendar: cal))
        #expect(!found.isEmpty)
        #expect(found.allSatisfy { $0.1.instanceId == "tree" && $0.1.photoCount == 1 })
    }

    @Test func aDayWithAnOnThisDayDoesNotAlsoGetAFurnitureMemory() {
        let cal = calendar()
        // Every day of March has an old photo: on-this-day takes every evening.
        let photos = (1...31).map { photo("p\($0)", day: String(format: "2024-03-%02d", $0)) }
        let st = state(photos: photos, items: [piece("tree", photos: photos.map(\.photoId))])
        let plan = ReminderPlanner.plan(state: st, settings: settings(onThisDay: true, furniture: true), now: moment(2026, 3, 1, 9, in: cal), calendar: cal)
        let days = memories(plan).map(day)
        #expect(Set(days).count == days.count, "at most one memory per day")
    }

    // MARK: Determinism and limits

    @Test func thePlanIsDeterministicAndStableAcrossReplans() {
        let cal = calendar()
        let photos = (1...20).map { photo("p\($0)", day: String(format: "20%02d-03-%02d", 10 + $0 % 5, $0)) }
        let st = state(photos: photos, items: (0..<4).map { piece("i\($0)", photos: [photos[$0].photoId]) })
        let s = settings(calls: true, onThisDay: true, furniture: true, seed: 42)
        let a = ReminderPlanner.plan(state: st, settings: s, now: moment(2026, 3, 1, in: cal), calendar: cal)
        let b = ReminderPlanner.plan(state: st, settings: s, now: moment(2026, 3, 1, in: cal), calendar: cal)
        #expect(a == b)
        // Opening the app the next day keeps the days that were already planned.
        let next = ReminderPlanner.plan(state: st, settings: s, now: moment(2026, 3, 2, in: cal), calendar: cal)
        let overlap = Set(memories(a).map(\.id)).intersection(memories(next).map(\.id))
        for id in overlap {
            #expect(a.first { $0.id == id } == next.first { $0.id == id })
        }
        #expect(!overlap.isEmpty)
    }

    @Test func theTotalStaysUnderTheLimit() {
        let cal = calendar()
        // An old photo on every day of the year, two call times, everything on.
        var photos: [PhotoRecord] = []
        var date = moment(2020, 1, 1, in: cal)
        for index in 0..<366 {
            let c = cal.dateComponents([.year, .month, .day], from: date)
            photos.append(photo("p\(index)", day: String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)))
            date = cal.date(byAdding: .day, value: 1, to: date)!
        }
        let st = state(photos: photos, items: [piece("tree", photos: ["p0"])])
        let s = settings(calls: true, times: [ReminderTime(hour: 8, minute: 0), ReminderTime(hour: 18, minute: 0)],
                         onThisDay: true, furniture: true)
        let plan = ReminderPlanner.plan(state: st, settings: s, now: moment(2026, 3, 1, in: cal), calendar: cal)
        #expect(plan.count <= ReminderPlanner.defaultLimit)
        #expect(ReminderPlanner.defaultLimit < 64)
        #expect(plan.filter(\.repeats).count == 14)
        let tight = ReminderPlanner.plan(state: st, settings: s, now: moment(2026, 3, 1, in: cal), calendar: cal, limit: 20)
        #expect(tight.count == 20)
        #expect(tight.filter(\.repeats).count == 14, "calls are kept; the latest memories are the ones dropped")
        let kept = memories(tight).map(day)
        #expect(kept == kept.sorted())
        #expect(kept.first == "2026-03-01")
    }

    // MARK: Settings storage

    @Test func settingsRoundTripAndOldFilesKeepDefaults() throws {
        var s = settings(calls: true, times: [ReminderTime(hour: 7, minute: 15), ReminderTime(hour: 19, minute: 0)], onThisDay: true, seed: 99)
        s.memoryTime = ReminderTime(hour: 21, minute: 5)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(ReminderSettings.self, from: data) == s)
        let partial = try JSONDecoder().decode(ReminderSettings.self, from: Data(#"{"callsEnabled":true}"#.utf8))
        #expect(partial.callsEnabled)
        #expect(!partial.onThisDayEnabled)
        #expect(partial.callTimes == ReminderSettings().callTimes)
    }

    // MARK: Cat facts

    func factPlan(_ st: AppState, _ s: ReminderSettings, now: Date, cal: Calendar,
                  horizon: Int = ReminderPlanner.horizonDays, limit: Int = ReminderPlanner.defaultLimit,
                  facts: [String] = Self.sampleFacts) -> [PlannedReminder] {
        ReminderPlanner.plan(state: st, settings: s, now: now, calendar: cal, horizonDays: horizon, limit: limit, catFacts: facts)
    }

    func factPlan(_ s: ReminderSettings, now: Date, cal: Calendar, horizon: Int = ReminderPlanner.horizonDays,
                  facts: [String] = Self.sampleFacts) -> [PlannedReminder] {
        factPlan(.empty, s, now: now, cal: cal, horizon: horizon, facts: facts)
    }

    func startOfFireDay(_ r: PlannedReminder, _ cal: Calendar) -> Date {
        cal.startOfDay(for: cal.date(from: r.fireDate)!)
    }

    func daysBetween(_ a: Date, _ b: Date, _ cal: Calendar) -> Int {
        cal.dateComponents([.day], from: cal.startOfDay(for: a), to: cal.startOfDay(for: b)).day!
    }

    /// "YYYY-MM-DD" for the same month and day as `date`, in an earlier year.
    func earlier(_ date: Date, year: Int, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.month, .day], from: date)
        return String(format: "%04d-%02d-%02d", year, c.month!, c.day!)
    }

    @Test func catFactsAreOffUnlessTurnedOn() {
        let cal = calendar()
        let st = state(photos: [photo("a", day: "2024-03-15")], items: [piece("sofa", photos: ["a"])])
        let plan = factPlan(st, settings(calls: true, onThisDay: true, furniture: true), now: moment(2026, 3, 1, in: cal), cal: cal)
        #expect(!plan.isEmpty)
        #expect(catFacts(plan).isEmpty)
    }

    @Test func onlyCatFactsOnStillCountsAsEnabled() {
        var s = ReminderSettings()
        s.catFactsEnabled = true
        #expect(s.anyEnabled)
    }

    @Test func catFactsComeAboutWeeklyInTheLateMorningAndOpenTheRoom() {
        let cal = calendar()
        let plan = factPlan(settings(facts: true), now: moment(2026, 3, 1, 0, 0, in: cal), cal: cal)
        let found = catFacts(plan)
        #expect(found.count == ReminderPlanner.maxPendingCatFacts, "30 days hold four or five; only four are planned ahead")
        #expect(plan.count == found.count, "nothing else is switched on")
        for (reminder, _) in found {
            #expect(!reminder.repeats)
            #expect(reminder.fireDate.hour == 10, "between 10:00 and 11:00")
            #expect((0..<60).contains(reminder.fireDate.minute ?? -1))
            #expect(reminder.furnitureID == nil, "a tap opens the room")
            #expect(reminder.id.hasPrefix(ReminderPlanner.idPrefix + "catfact."))
        }
        let days = found.map { startOfFireDay($0.0, cal) }
        #expect(days == days.sorted())
        for (a, b) in zip(days, days.dropFirst()) {
            #expect(daysBetween(a, b, cal) == 7)
        }
        #expect(Set(found.map(\.1)).count == found.count, "no fact twice among the pending ones")
        #expect(Set(found.map(\.0.id)).count == found.count)
    }

    @Test func theSeedSpreadsTheWeekdayAndTheMinute() {
        let cal = calendar()
        var minutes = Set<Int>(), weekdays = Set<Int>()
        for seed in UInt64(0)..<40 {
            for (reminder, _) in catFacts(factPlan(settings(facts: true, seed: seed), now: moment(2026, 3, 1, 0, 0, in: cal), cal: cal)) {
                minutes.insert(reminder.fireDate.minute!)
                weekdays.insert(cal.component(.weekday, from: cal.date(from: reminder.fireDate)!))
            }
        }
        #expect(weekdays.count == 7)
        #expect(minutes.count > 10)
    }

    @Test func aFactWhoseTimeHasPassedIsNotPlannedAgain() throws {
        let cal = calendar()
        let s = settings(facts: true)
        let first = try #require(catFacts(factPlan(s, now: moment(2026, 3, 1, 0, 0, in: cal), cal: cal)).first)
        let fire = cal.date(from: first.0.fireDate)!
        #expect(catFacts(factPlan(s, now: fire.addingTimeInterval(-60), cal: cal)).first?.0 == first.0)
        let after = catFacts(factPlan(s, now: fire, cal: cal))
        #expect(!after.contains { $0.1 == first.1 }, "delivered: not moved to a later day")
        let next = try #require(after.first)
        #expect(daysBetween(fire, cal.date(from: next.0.fireDate)!, cal) == 7)
    }

    @Test func aFactGivesWayToOnThisDayAndWaitsForTheNextFreeDay() throws {
        let cal = calendar()
        let now = moment(2026, 3, 1, 0, 0, in: cal)
        let alone = try #require(catFacts(factPlan(settings(facts: true), now: now, cal: cal)).first)
        let factDay = startOfFireDay(alone.0, cal)
        let st = state(photos: [photo("a", day: earlier(factDay, year: 2023, cal))])
        let s = settings(onThisDay: true, facts: true)
        let plan = factPlan(st, s, now: now, cal: cal)
        #expect(onThisDays(plan).map { startOfFireDay($0.0, cal) } == [factDay])
        let moved = try #require(catFacts(plan).first)
        #expect(moved.1 == alone.1, "the same fact, a day later")
        #expect(daysBetween(factDay, startOfFireDay(moved.0, cal), cal) == 1)
        #expect(moved.0.fireDate.hour == 10 && moved.0.fireDate.minute == alone.0.fireDate.minute)
        // Planned again that evening, after the fact's own time and the memory: still waiting for tomorrow.
        let c = cal.dateComponents([.year, .month, .day], from: factDay)
        let evening = factPlan(st, s, now: moment(c.year!, c.month!, c.day!, 21, 0, in: cal), cal: cal)
        #expect(catFacts(evening).first?.0 == moved.0)
        // And the next morning, when the fact's own day is already in the past.
        let morning = factPlan(st, s, now: cal.date(byAdding: .hour, value: 7, to: cal.date(byAdding: .day, value: 1, to: factDay)!)!, cal: cal)
        #expect(catFacts(morning).first?.0 == moved.0)
    }

    @Test func aFactAlsoGivesWayToAFurnitureMemory() throws {
        let cal = calendar()
        let now = moment(2026, 3, 1, 0, 0, in: cal)
        let s = settings(onThisDay: true, furniture: true, facts: true)
        let base = state(photos: [photo("f", day: nil)], items: [piece("tree", photos: ["f"])])
        let basePlan = factPlan(base, s, now: now, cal: cal)
        let alone = try #require(catFacts(basePlan).first)
        let factDay = startOfFireDay(alone.0, cal)
        let furnitureDays = furnitureMemories(basePlan).map { startOfFireDay($0.0, cal) }
        #expect(!furnitureDays.contains(factDay))
        let nextFurniture = try #require(furnitureDays.first { $0 > factDay })
        let gap = daysBetween(factDay, nextFurniture, cal)
        try #require((1...5).contains(gap), "the furniture evening falls within the fact's week")
        // Old photos fill every evening from the fact's day up to the furniture evening.
        var photos = [photo("f", day: nil)]
        for offset in 0..<gap {
            photos.append(photo("o\(offset)", day: earlier(cal.date(byAdding: .day, value: offset, to: factDay)!, year: 2022, cal)))
        }
        let plan = factPlan(state(photos: photos, items: [piece("tree", photos: ["f"])]), s, now: now, cal: cal)
        #expect(furnitureMemories(plan).map { startOfFireDay($0.0, cal) }.contains(nextFurniture))
        let moved = try #require(catFacts(plan).first { $0.1 == alone.1 })
        #expect(daysBetween(factDay, startOfFireDay(moved.0, cal), cal) == gap + 1, "past both kinds of memory")
        let memoryDays = Set(memories(plan).map(day))
        #expect(memoryDays.isDisjoint(with: catFacts(plan).map { day($0.0) }), "never on the same day as a memory")
    }

    @Test func aWeekWithNoFreeDaySkipsItsFactInsteadOfStackingIt() {
        let cal = calendar()
        // An old photo on every day of March: every evening of the month is taken.
        let photos = (1...31).map { photo("p\($0)", day: String(format: "2024-03-%02d", $0)) }
        let plan = factPlan(state(photos: photos), settings(onThisDay: true, facts: true),
                            now: moment(2026, 3, 1, 0, 0, in: cal), cal: cal, horizon: 31)
        #expect(onThisDays(plan).count == 31)
        #expect(catFacts(plan).isEmpty)
    }

    @Test func theRotationShowsEveryFactOnceBeforeAnyRepeats() {
        let ids = Self.sampleFacts
        // Enough seeds and rounds that some shuffle opens with the fact the previous round closed on.
        for seed in Array(UInt64(0)..<60) + [.max] {
            var previous: String?
            var rounds: [[String]] = []
            for round in 0..<6 {
                let order = (0..<ids.count).map { ReminderPlanner.catFact(week: round * ids.count + $0, from: ids, seed: seed) }
                #expect(Set(order) == Set(ids), "round \(round) repeats a fact (seed \(seed))")
                #expect(order.first != previous, "the same fact twice in a row across rounds (seed \(seed))")
                previous = order.last
                rounds.append(order)
            }
            #expect(Set(rounds).count == rounds.count, "every round is shuffled anew (seed \(seed))")
            #expect(rounds[0] != ids, "shuffled, not in draft order")
        }
    }

    /// QA's case: seed 20 on 2027-01-05 had tail-up pending on 1-11 and again on 2-1.
    @Test func noFactIsPendingTwice() {
        let cal = calendar()
        let plan = catFacts(factPlan(settings(facts: true, seed: 20), now: moment(2027, 1, 5, 9, 0, in: cal), cal: cal,
                                     facts: CatFacts.rotation))
        #expect(plan.count == ReminderPlanner.maxPendingCatFacts)
        #expect(Set(plan.map(\.1)).count == plan.count, "\(plan.map { (day($0.0), $0.1) })")
    }

    /// Across round boundaries a fact never comes back sooner than `catFactMinWeeks` weeks: the
    /// facts that closed one round stay out of the start of the next.
    @Test func aFactNeverReturnsWithinFiveWeeks() {
        let minWeeks = ReminderPlanner.catFactMinWeeks
        #expect(minWeeks == 6, "more than five weeks between two showings of the same fact")
        for ids in [CatFacts.rotation, Self.sampleFacts, Array(Self.sampleFacts.prefix(15))] {
            let n = ids.count
            var violations: [String] = []
            var shuffledRounds = 0
            for seed in Array(UInt64(0)..<2_000) + [.max] {
                // Four rounds, three boundaries: one from the start and one from about now (week ~2,930).
                for firstRound in [0, 146] {
                    let weeks = (firstRound * n)..<((firstRound + 4) * n)
                    var last: [String: Int] = [:]
                    var rounds: [[String]] = []
                    for week in weeks {
                        let fact = ReminderPlanner.catFact(week: week, from: ids, seed: seed)
                        if let previous = last[fact], week - previous < minWeeks, violations.count < 5 {
                            violations.append("seed \(seed) \(fact): weeks \(previous) and \(week)")
                        }
                        last[fact] = week
                        if (week - weeks.lowerBound) % n == 0 { rounds.append([]) }
                        rounds[rounds.count - 1].append(fact)
                    }
                    for round in rounds where Set(round) != Set(ids) { violations.append("seed \(seed): a round repeats a fact") }
                    if Set(rounds).count == rounds.count { shuffledRounds += 1 }
                }
            }
            #expect(violations.isEmpty, "\(n) facts: \(violations)")
            #expect(shuffledRounds > 3_900, "\(n) facts: rounds are still shuffled anew")
        }
    }

    /// With too few facts to keep five weeks apart while reshuffling, the order stays the same
    /// every round, which spaces each fact a full round apart.
    @Test func aShortRotationKeepsOneOrder() {
        for n in 2..<15 {
            let ids = Array(Self.sampleFacts.prefix(n))
            for seed in UInt64(0)..<50 {
                let weeks = (0..<(3 * n)).map { ReminderPlanner.catFact(week: 140 * n + $0, from: ids, seed: seed) }
                #expect(Array(weeks[0..<n]) == Array(weeks[n..<(2 * n)]), "n \(n) seed \(seed)")
                #expect(Set(weeks.prefix(n)).count == n)
            }
        }
        #expect(ReminderPlanner.catFact(week: 3, from: ["only"], seed: 5) == "only")
    }

    /// A year of days, the app opened every morning, with old photos pushing some facts back:
    /// what is delivered never repeats within five weeks, and nothing is pending twice.
    @Test func deliveredFactsStayFiveWeeksApart() {
        let cal = calendar()
        let photos = stride(from: 1, through: 360, by: 4).map { offset -> PhotoRecord in
            let date = cal.date(byAdding: .day, value: offset, to: moment(2027, 1, 1, in: cal))!
            return photo("p\(offset)", day: earlier(date, year: 2020, cal))
        }
        let st = state(photos: photos)
        var problems: [String] = []
        for seed in UInt64(0)..<25 {
            let s = settings(onThisDay: true, facts: true, seed: seed)
            var delivered: [String: Date] = [:]
            for offset in 0..<365 {
                let morning = cal.date(byAdding: .day, value: offset, to: moment(2027, 1, 1, 0, 0, in: cal))!
                let pending = catFacts(factPlan(st, s, now: morning, cal: cal, facts: CatFacts.rotation))
                if Set(pending.map(\.1)).count != pending.count { problems.append("seed \(seed) \(morning): pending twice") }
                for (reminder, fact) in pending where cal.isDate(cal.date(from: reminder.fireDate)!, inSameDayAs: morning) {
                    if let previous = delivered[fact], daysBetween(previous, morning, cal) <= 35 {
                        problems.append("seed \(seed) \(fact): \(daysBetween(previous, morning, cal)) days apart")
                    }
                    delivered[fact] = morning
                }
            }
            #expect(delivered.count == CatFacts.rotation.count, "a year shows every fact (seed \(seed))")
        }
        #expect(problems.isEmpty, "\(problems.prefix(5))")
    }

    /// Seven busy days from the fact's own day: it is skipped, not pushed onto next week's day.
    @Test func sevenBusyDaysSkipTheWeeksFact() throws {
        let cal = calendar()
        let now = moment(2026, 3, 1, 0, 0, in: cal)
        let alone = catFacts(factPlan(settings(facts: true), now: now, cal: cal))
        let first = try #require(alone.first), second = try #require(alone.dropFirst().first)
        let factDay = startOfFireDay(first.0, cal)
        let photos = (0..<7).map { photo("b\($0)", day: earlier(cal.date(byAdding: .day, value: $0, to: factDay)!, year: 2023, cal)) }
        let plan = factPlan(state(photos: photos), settings(onThisDay: true, facts: true), now: now, cal: cal)
        let facts = catFacts(plan)
        #expect(!facts.contains { $0.1 == first.1 }, "that week's fact is skipped")
        #expect(facts.first?.0 == second.0, "next week's fact keeps its own day")
        #expect(Set(facts.map(\.0.id)).count == facts.count)
        #expect(Set(facts.map { day($0.0) }).count == facts.count, "one fact a day")
    }

    @Test func withoutCheckedFactsNothingIsSent() {
        let cal = calendar()
        let plan = factPlan(settings(facts: true), now: moment(2026, 3, 1, in: cal), cal: cal, facts: [])
        #expect(plan.isEmpty)
    }

    @Test func factsAreCappedAndAreTheFirstToGoWhenSpaceRunsOut() throws {
        let cal = calendar()
        let now = moment(2026, 3, 1, 0, 0, in: cal)
        #expect(catFacts(factPlan(settings(facts: true), now: now, cal: cal, horizon: 120)).count == ReminderPlanner.maxPendingCatFacts)
        // Everything on: two call times, a furniture memory each week, old photos on every third day.
        let photos = stride(from: 1, through: 28, by: 3).map { photo("p\($0)", day: String(format: "2024-03-%02d", $0)) }
        let st = state(photos: photos, items: [piece("tree", photos: ["p1"])])
        let s = settings(calls: true, times: [ReminderTime(hour: 8, minute: 0), ReminderTime(hour: 18, minute: 0)],
                         onThisDay: true, furniture: true, facts: true)
        let full = factPlan(st, s, now: now, cal: cal)
        #expect(full.count <= ReminderPlanner.defaultLimit)
        let facts = catFacts(full)
        #expect(!facts.isEmpty)
        let others = full.filter { if case .catFact = $0.kind { false } else { true } }
        let tight = factPlan(st, s, now: now, cal: cal, limit: others.count)
        #expect(tight == others, "calls and memories are kept; facts are dropped first")
        let oneMore = catFacts(factPlan(st, s, now: now, cal: cal, limit: others.count + 1))
        #expect(oneMore.map(\.0) == [facts[0].0], "the soonest fact is the one kept")
    }

    @Test func factPlansAreStableAcrossReplans() {
        let cal = calendar()
        let s = settings(facts: true, seed: 42)
        let a = catFacts(factPlan(s, now: moment(2026, 3, 1, 0, 0, in: cal), cal: cal))
        let b = catFacts(factPlan(s, now: moment(2026, 3, 9, 9, 0, in: cal), cal: cal))
        let overlap = Set(a.map(\.0.id)).intersection(b.map(\.0.id))
        #expect(!overlap.isEmpty)
        for id in overlap {
            #expect(a.first { $0.0.id == id }?.1 == b.first { $0.0.id == id }?.1)
            #expect(a.first { $0.0.id == id }?.0 == b.first { $0.0.id == id }?.0)
        }
    }

    @Test func settingsFromBeforeCatFactsDecodeWithFactsOff() throws {
        let old = #"{"callsEnabled":true,"callTimes":[{"hour":8,"minute":0}],"onThisDayEnabled":true,"furnitureEnabled":true,"memoryTime":{"hour":20,"minute":0},"seed":5}"#
        let s = try JSONDecoder().decode(ReminderSettings.self, from: Data(old.utf8))
        #expect(!s.catFactsEnabled)
        #expect(s.callsEnabled && s.onThisDayEnabled && s.furnitureEnabled && s.seed == 5)
        var on = s
        on.catFactsEnabled = true
        #expect(try JSONDecoder().decode(ReminderSettings.self, from: JSONEncoder().encode(on)) == on)
    }
}
