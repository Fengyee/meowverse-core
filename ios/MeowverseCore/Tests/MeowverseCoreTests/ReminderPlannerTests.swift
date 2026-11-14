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
                  onThisDay: Bool = false, furniture: Bool = false, seed: UInt64 = 7) -> ReminderSettings {
        var s = ReminderSettings()
        s.callsEnabled = calls
        s.callTimes = times
        s.onThisDayEnabled = onThisDay
        s.furnitureEnabled = furniture
        s.seed = seed
        return s
    }

    func memories(_ plan: [PlannedReminder]) -> [PlannedReminder] { plan.filter { !$0.repeats } }

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
        #expect(!s.callsEnabled && !s.onThisDayEnabled && !s.furnitureEnabled)
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
}
