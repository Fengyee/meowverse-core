import Foundation

/// A wall-clock time of day, in whatever time zone the device is in when it fires.
public struct ReminderTime: Codable, Sendable, Hashable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public var isValid: Bool { (0...23).contains(hour) && (0...59).contains(minute) }
}

/// The user's reminder choices. A device setting: kept per store folder in UserDefaults by the
/// app, never in the library or its backups. Everything is off until the user turns it on.
public struct ReminderSettings: Codable, Sendable, Equatable {
    public static let maxCallTimes = 2

    /// 猫咪的招呼: the cat calls at `callTimes` every day.
    public var callsEnabled = false
    /// At most `maxCallTimes` are used; the first is the main one.
    public var callTimes = [ReminderTime(hour: 8, minute: 0)]
    /// 历史上的今天.
    public var onThisDayEnabled = false
    /// 家具的回忆, about once a week.
    public var furnitureEnabled = false
    /// 猫咪小知识, about once a week in the late morning.
    public var catFactsEnabled = false
    /// When memories (both kinds) arrive: a quiet evening hour.
    public var memoryTime = ReminderTime(hour: 20, minute: 0)
    /// Picks which photo, piece and day; fixed once per install so re-planning keeps the same days.
    public var seed: UInt64 = 0

    public init() {}

    public var anyEnabled: Bool { callsEnabled || onThisDayEnabled || furnitureEnabled || catFactsEnabled }

    private enum CodingKeys: String, CodingKey { case callsEnabled, callTimes, onThisDayEnabled, furnitureEnabled, catFactsEnabled, memoryTime, seed }

    /// Missing keys keep their defaults, so a later build can add settings without losing these.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReminderSettings()
        callsEnabled = try c.decodeIfPresent(Bool.self, forKey: .callsEnabled) ?? defaults.callsEnabled
        callTimes = try c.decodeIfPresent([ReminderTime].self, forKey: .callTimes) ?? defaults.callTimes
        onThisDayEnabled = try c.decodeIfPresent(Bool.self, forKey: .onThisDayEnabled) ?? defaults.onThisDayEnabled
        furnitureEnabled = try c.decodeIfPresent(Bool.self, forKey: .furnitureEnabled) ?? defaults.furnitureEnabled
        // Settings saved before cat facts existed have no key: the facts stay off.
        catFactsEnabled = try c.decodeIfPresent(Bool.self, forKey: .catFactsEnabled) ?? defaults.catFactsEnabled
        memoryTime = try c.decodeIfPresent(ReminderTime.self, forKey: .memoryTime) ?? defaults.memoryTime
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? defaults.seed
    }
}

/// One of the cat's calls. The words are chosen by the app (they are localised there).
public enum CatCall: Int, CaseIterable, Sendable, Hashable {
    /// 「Enn~ EnAhh~」
    case ennEnAhh
    /// 「零食零食」
    case snack
    /// 「饭来~」
    case food
}

/// A piece of furniture a memory names. Stored pieces count: they keep their photos and their
/// detail page still opens from the storage box.
public struct RememberedPiece: Sendable, Equatable {
    public let instanceId: String
    public let displayName: String
    /// How the cat relates to the piece in the chosen photo; `.unclear` and the rest must not be
    /// turned into "on" by the wording.
    public let relation: Relation
    public let isStored: Bool
}

/// 历史上的今天: a photo whose known capture day has today's month and day, in an earlier year.
public struct OnThisDayMemory: Sendable, Equatable {
    public let photoId: String
    /// Whole years between the photo's day and the day the reminder fires (≥ 1).
    public let yearsAgo: Int
    /// Photos taken on that same day of that same year (≥ 1).
    public let photoCount: Int
    /// The piece the chosen photo is on, if any.
    public let piece: RememberedPiece?
}

/// 家具的回忆: a piece with photos.
public struct FurnitureMemory: Sendable, Equatable {
    public let instanceId: String
    public let displayName: String
    /// Photos on the piece that are still in the library (≥ 1).
    public let photoCount: Int
    public let isStored: Bool
}

/// One notification to hand to the system.
public struct PlannedReminder: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case call(CatCall)
        case onThisDay(OnThisDayMemory)
        case furniture(FurnitureMemory)
        /// The id of a fact in `CatFacts`; the app looks up its text.
        case catFact(String)
    }

    /// Stable for the same slot and day, so re-planning replaces rather than duplicates.
    public let id: String
    public let kind: Kind
    /// Gregorian wall-clock components without a time zone. Calls: weekday, hour, minute and
    /// `repeats`; memories and cat facts: year, month, day, hour, minute, fired once.
    public let fireDate: DateComponents
    public let repeats: Bool
    /// For a cat fact, the week it belongs to: the logical event, whichever day it moved to.
    /// The id follows the day; this does not.
    public var catFactWeek: Int? = nil

    /// The piece a tap should open; nil opens the room.
    public var furnitureID: String? {
        switch kind {
        case .call, .catFact: nil
        case .onThisDay(let memory): memory.piece?.instanceId
        case .furniture(let memory): memory.instanceId
        }
    }
}

/// Plans local notifications. Pure: the same library, settings, moment, calendar and seed give
/// the same plan.
///
/// Calls repeat by themselves (one weekly trigger per weekday and time, so the words rotate
/// without the app running). Memories and cat facts are planned for `horizonDays` ahead and must
/// be re-planned whenever the app runs. iOS keeps at most 64 pending requests per app; with two
/// call times (14 requests), one memory per day for 30 days and `maxPendingCatFacts` facts the
/// plan stays at or under 48, and `limit` is a hard cap on top. When the cap bites, facts go
/// first, then the latest memories.
///
/// Rules:
/// - Only photos whose capture day is known (`exif` or `user`) and valid are remembered. Import
///   time never stands in for a capture day.
/// - "On this day" matches month and day exactly, in an earlier year. Feb 29 matches only Feb 29.
/// - At most one memory a day; "on this day" wins over a furniture memory.
/// - Cat facts come about weekly at 10:xx, on a weekday and minute fixed by the seed. A day that
///   already has a memory is not a fact's day: the fact waits for the next free day, at most
///   `catFactMaxWait` days, else that week has none. A fact whose time has passed is never moved
///   later. Each round shows every fact once before any comes again, and no fact comes back
///   within five weeks.
/// - Pieces put away still count: their photos and detail page remain.
/// - Matching uses the Gregorian calendar (stored days are Gregorian) in the time zone of
///   `calendar`.
public enum ReminderPlanner {
    public static let horizonDays = 30
    public static let defaultLimit = 60
    public static let idPrefix = "meowverse.reminder."
    /// Cat facts arrive between 10:00 and 11:00, away from the evening memories.
    public static let catFactHour = 10
    /// Facts planned ahead; the rest are planned on later launches.
    public static let maxPendingCatFacts = 4
    /// A fact waits at most this long for a day without a memory, so it never meets next week's.
    static let catFactMaxWait = 6
    /// Weeks before a fact may come again: more than five.
    static let catFactMinWeeks = 6

    /// `catFacts` is the rotation: only checked facts (`CatFacts.rotation`), in a fixed order.
    /// `consumedCatFactWeeks` are weeks whose fact the system already showed (see
    /// `CatFactHistory`); they get none, even if a later change of the library would move it.
    public static func plan(state: AppState, settings: ReminderSettings, now: Date, calendar: Calendar,
                            horizonDays: Int = horizonDays, limit: Int = defaultLimit,
                            catFacts: [String] = CatFacts.rotation,
                            consumedCatFactWeeks: Set<Int> = []) -> [PlannedReminder] {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let calls = settings.callsEnabled ? callPlan(settings) : []
        let memoryBudget = max(0, limit - calls.count)
        let days = MemoryDays(state: state, settings: settings)
        let memories = memoryBudget > 0
            ? days.map { memoryPlan($0, settings: settings, now: now, calendar: gregorian, horizonDays: horizonDays) } ?? []
            : []
        let kept = memories.prefix(memoryBudget)
        let factBudget = min(maxPendingCatFacts, memoryBudget - kept.count)
        let facts = settings.catFactsEnabled && factBudget > 0 && !catFacts.isEmpty
            ? catFactPlan(memoryDays: days, facts: catFacts, seed: settings.seed, now: now, calendar: gregorian,
                          horizonDays: horizonDays, limit: factBudget, consumed: consumedCatFactWeeks)
            : []
        return Array(calls.prefix(limit)) + kept + facts
    }

    /// Whether the system's pending reminders (`pending`, this app's ids) are exactly `plan`,
    /// so submitting it again would change nothing (FF24-01). Having submitted the same plan
    /// before is no proof: the system may have dropped requests since. A one-off whose time has
    /// come at `now` is not expected: it left by being shown, and is not sent again.
    public static func pendingMatches(_ plan: [PlannedReminder], pending: Set<String>, now: Date, calendar: Calendar) -> Bool {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let expected = plan.filter { reminder in
            guard !reminder.repeats else { return true }
            var components = reminder.fireDate
            components.calendar = nil
            components.timeZone = nil
            guard let due = gregorian.date(from: components) else { return true }
            return due > now
        }
        return Set(expected.map(\.id)) == pending
    }

    // MARK: Calls

    private static func callPlan(_ settings: ReminderSettings) -> [PlannedReminder] {
        var times: [ReminderTime] = []
        for time in settings.callTimes where time.isValid && !times.contains(time) {
            times.append(time)
        }
        let lines = CatCall.allCases
        var plan: [PlannedReminder] = []
        for (slot, time) in times.prefix(ReminderSettings.maxCallTimes).enumerated() {
            for weekday in 1...7 {
                let index = Int((UInt64(weekday - 1 + slot) &+ settings.seed) % UInt64(lines.count))
                plan.append(PlannedReminder(
                    id: "\(idPrefix)call.\(slot).\(weekday)",
                    kind: .call(lines[index]),
                    fireDate: DateComponents(hour: time.hour, minute: time.minute, weekday: weekday),
                    repeats: true))
            }
        }
        return plan
    }

    // MARK: Memories

    private struct Day {
        let year: Int, month: Int, day: Int
        var key: String { String(format: "%04d-%02d-%02d", year, month, day) }
    }

    private struct DatedPhoto {
        let photoId: String
        let day: Day
    }

    /// Which memory each day gets, whatever the time now. Nil when no memory kind is on.
    private struct MemoryDays {
        let state: AppState
        let seed: UInt64
        let memoryTime: ReminderTime
        let byMonthDay: [String: [DatedPhoto]]
        let rotation: [FurnitureMemory]

        init?(state: AppState, settings: ReminderSettings) {
            guard settings.onThisDayEnabled || settings.furnitureEnabled, settings.memoryTime.isValid else { return nil }
            self.state = state
            seed = settings.seed
            memoryTime = settings.memoryTime
            let dated = settings.onThisDayEnabled ? knownDays(state) : []
            byMonthDay = Dictionary(grouping: dated) { "\($0.day.month)-\($0.day.day)" }
            rotation = settings.furnitureEnabled ? furnitureCandidates(state) : []
        }

        /// The memory of `day` and the id that names it.
        func memory(on day: Day) -> (id: String, kind: PlannedReminder.Kind)? {
            let ordinal = dayOrdinal(year: day.year, month: day.month, day: day.day)
            let matches = (byMonthDay["\(day.month)-\(day.day)"] ?? []).filter { $0.day.year < day.year }
            if let memory = onThisDay(matches, today: day, ordinal: ordinal, seed: seed, state: state) {
                return ("\(idPrefix)onthisday.\(day.key)", .onThisDay(memory))
            }
            // About weekly, on a weekday fixed by the seed, so re-planning keeps the same evenings.
            if !rotation.isEmpty, (UInt64(bitPattern: Int64(ordinal)) &+ seed) % 7 == 0 {
                let week = UInt64(bitPattern: Int64(ordinal / 7))
                let memory = rotation[Int((week &+ seed) % UInt64(rotation.count))]
                return ("\(idPrefix)furniture.\(day.key)", .furniture(memory))
            }
            return nil
        }
    }

    private static func memoryPlan(_ days: MemoryDays, settings: ReminderSettings, now: Date, calendar: Calendar,
                                   horizonDays: Int) -> [PlannedReminder] {
        guard horizonDays > 0 else { return [] }
        let start = calendar.startOfDay(for: now)
        var plan: [PlannedReminder] = []
        for offset in 0..<horizonDays {
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = c.year, let month = c.month, let dayOfMonth = c.day else { continue }
            var fire = DateComponents(year: year, month: month, day: dayOfMonth,
                                      hour: settings.memoryTime.hour, minute: settings.memoryTime.minute)
            guard let fireMoment = calendar.date(from: fire), fireMoment > now else { continue }
            fire.calendar = Calendar(identifier: .gregorian)
            if let memory = days.memory(on: Day(year: year, month: month, day: dayOfMonth)) {
                plan.append(PlannedReminder(id: memory.id, kind: memory.kind, fireDate: fire, repeats: false))
            }
        }
        return plan
    }

    // MARK: Cat facts

    /// A fact's preferred day is fixed by the seed and the week; a memory on that day sends it to
    /// the next free one. Busy days are judged without regard to the time now, so a fact waiting
    /// for tomorrow is still waiting when the app is opened after the memory has gone out.
    ///
    /// A week in `consumed` already had its fact shown. A memory that later appears on that day
    /// (a photo dated to it after 10 o'clock) must not send the same fact to the next free day.
    private static func catFactPlan(memoryDays: MemoryDays?, facts: [String], seed: UInt64, now: Date,
                                    calendar: Calendar, horizonDays: Int, limit: Int,
                                    consumed: Set<Int>) -> [PlannedReminder] {
        guard horizonDays > 0, limit > 0, !facts.isEmpty else { return [] }
        let c = calendar.dateComponents([.year, .month, .day], from: calendar.startOfDay(for: now))
        guard let year = c.year, let month = c.month, let dayOfMonth = c.day else { return [] }
        let today = dayOrdinal(year: year, month: month, day: dayOfMonth)
        let busy: (Int) -> Bool = { ordinal in memoryDays?.memory(on: civilDay(ordinal)) != nil }
        let shift = Int(seed % 7)
        var plan: [PlannedReminder] = []
        // Start a week back: a fact from then may still be waiting for a free day.
        for preferred in (today - catFactMaxWait)..<(today + horizonDays) {
            let slot = preferred + shift + 4
            guard slot % 7 == 0 else { continue }
            let week = slot / 7
            guard !consumed.contains(week) else { continue }
            guard let actual = (preferred...(preferred + catFactMaxWait)).first(where: { !busy($0) }),
                  actual >= today, actual < today + horizonDays else { continue }
            let day = civilDay(actual)
            let minute = Int(mix(seed ^ mix(UInt64(week))) % 60)
            var fire = DateComponents(year: day.year, month: day.month, day: day.day, hour: catFactHour, minute: minute)
            guard let moment = calendar.date(from: fire), moment > now else { continue }
            fire.calendar = Calendar(identifier: .gregorian)
            plan.append(PlannedReminder(id: "\(idPrefix)catfact.\(day.key)", kind: .catFact(catFact(week: week, from: facts, seed: seed)),
                                        fireDate: fire, repeats: false, catFactWeek: week))
            if plan.count == limit { break }
        }
        return plan
    }

    /// The fact of a week. Weeks run in rounds of `facts.count`: each round is its own shuffle, so
    /// every fact comes once per round, and the facts that closed one round stay out of the start
    /// of the next, so a fact never comes back within `catFactMinWeeks` weeks.
    static func catFact(week: Int, from facts: [String], seed: UInt64) -> String {
        let n = facts.count
        let round = week >= 0 ? week / n : (week + 1) / n - 1
        return roundOrder(round, of: facts, seed: seed)[week - round * n]
    }

    private static func roundOrder(_ round: Int, of facts: [String], seed: UInt64) -> [String] {
        let held = catFactMinWeeks - 1
        // Too few facts to reshuffle and still keep them apart: one order every round, which spaces
        // each fact a whole round apart.
        guard facts.count >= 3 * held else { return shuffled(facts, seed: roundKey(seed, 0)) }
        var order = shuffled(facts, seed: roundKey(seed, round))
        // The swaps below move facts only within the first n - held places, so every round closes
        // with its own raw shuffle's last facts and this needs no older rounds.
        let closing = Set(shuffled(facts, seed: roundKey(seed, round - 1)).suffix(held))
        // With n >= 3 * held there are always enough other facts in the middle to swap in.
        var spare = held
        for slot in 0..<held where closing.contains(order[slot]) {
            while spare < order.count - held, closing.contains(order[spare]) { spare += 1 }
            guard spare < order.count - held else { break }
            order.swapAt(slot, spare)
            spare += 1
        }
        return order
    }

    private static func roundKey(_ seed: UInt64, _ round: Int) -> UInt64 {
        mix(seed ^ mix(UInt64(bitPattern: Int64(round)) &+ 0x6361_7466_6163_7473))
    }

    /// Fisher–Yates with SplitMix64, written out so the order does not change with the Swift library.
    private static func shuffled(_ items: [String], seed: UInt64) -> [String] {
        var items = items
        var state = seed
        for i in stride(from: items.count - 1, to: 0, by: -1) {
            state &+= 0x9E37_79B9_7F4A_7C15
            let j = Int(mix(state) % UInt64(i + 1))
            items.swapAt(i, j)
        }
        return items
    }

    /// SplitMix64's finaliser.
    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Photos with a known, valid capture day.
    private static func knownDays(_ state: AppState) -> [DatedPhoto] {
        state.photos.compactMap { photo in
            guard photo.captureDateSource != .unknown, let text = photo.captureDate, PhotoLibrary.isValidDay(text) else { return nil }
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return DatedPhoto(photoId: photo.photoId, day: Day(year: parts[0], month: parts[1], day: parts[2]))
        }
    }

    /// The first piece holding the photo: room pieces before stored ones, then by id.
    private static func piece(holding photoId: String, in state: AppState) -> RememberedPiece? {
        let room = state.items.sorted { $0.instanceId < $1.instanceId }.map { ($0, false) }
        let stored = state.storage.sorted { $0.instanceId < $1.instanceId }.map { ($0, true) }
        for (item, isStored) in room + stored {
            if let source = item.sources.first(where: { $0.photoId == photoId }) {
                return RememberedPiece(instanceId: item.instanceId, displayName: item.displayName,
                                       relation: source.relationToCat, isStored: isStored)
            }
        }
        return nil
    }

    private static func onThisDay(_ matches: [DatedPhoto], today: Day, ordinal: Int, seed: UInt64,
                                  state: AppState) -> OnThisDayMemory? {
        guard !matches.isEmpty else { return nil }
        let sorted = matches.sorted { $0.photoId < $1.photoId }
        let linked = sorted.filter { piece(holding: $0.photoId, in: state) != nil }
        let pool = linked.isEmpty ? sorted : linked
        let chosen = pool[Int((UInt64(bitPattern: Int64(ordinal)) &+ seed) % UInt64(pool.count))]
        let sameYear = matches.filter { $0.day.year == chosen.day.year }.count
        return OnThisDayMemory(photoId: chosen.photoId, yearsAgo: today.year - chosen.day.year,
                               photoCount: sameYear, piece: piece(holding: chosen.photoId, in: state))
    }

    /// Pieces with at least one photo still in the library, in a fixed order.
    private static func furnitureCandidates(_ state: AppState) -> [FurnitureMemory] {
        let photoIds = Set(state.photos.map(\.photoId))
        let pieces = state.items.map { ($0, false) } + state.storage.map { ($0, true) }
        return pieces.compactMap { item, isStored in
            let count = Set(item.sources.map(\.photoId)).intersection(photoIds).count
            guard count > 0 else { return nil }
            return FurnitureMemory(instanceId: item.instanceId, displayName: item.displayName, photoCount: count, isStored: isStored)
        }
        .sorted { $0.instanceId < $1.instanceId }
    }

    /// The day `ordinal` days after 1970-01-01 (Howard Hinnant's civil_from_days).
    private static func civilDay(_ ordinal: Int) -> Day {
        let z = ordinal + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return Day(year: yoe + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day)
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar; independent of time zone.
    private static func dayOrdinal(year: Int, month: Int, day: Int) -> Int {
        // Howard Hinnant's days_from_civil.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

/// Which cat facts the system was given and which of them it has shown, kept by the app across
/// launches (a device setting, like `ReminderSettings`).
///
/// The app is not told when a notification is shown, and is often not running then. The
/// system's pending list is the record: a fact the system accepted and no longer holds, once
/// its time could have come, has been shown or is treated as shown. Its week is consumed and
/// gets no other fact, whatever later happens to the photos, the settings or the time zone. A
/// fact still pending may move. A fact gone long before its time was removed, not shown (a
/// device restored from a backup has the settings but none of the pending requests).
///
/// "Could have come": the fire time is a wall-clock time, so moving east shows it up to 26
/// hours earlier than the moment recorded here. Cost of that margin: a fact that vanishes
/// another way within 26 hours of its time is not sent again, so that week has none.
public struct CatFactHistory: Codable, Sendable, Equatable {
    /// Older weeks are dropped: the planner never looks back more than a week.
    public static let keptWeeks = 16
    /// UTC offsets run from −12 to +14 hours.
    public static let zoneMargin: TimeInterval = 26 * 3600

    public struct Scheduled: Codable, Sendable, Equatable {
        public let id: String
        /// When it fires in the zone it was scheduled in.
        public let due: Date
    }

    /// Weeks whose fact was given to the system and has left its pending list.
    public private(set) var consumedWeeks: Set<Int> = []
    /// Each week's fact the system holds, as last given.
    public private(set) var scheduled: [Int: Scheduled] = [:]

    public init() {}

    /// Before planning: `pending` is every id the system still holds.
    public mutating func noteDeliveries(pending: Set<String>, now: Date) {
        for (week, fact) in scheduled where !pending.contains(fact.id) && now >= fact.due - Self.zoneMargin {
            consumedWeeks.insert(week)
        }
        scheduled = scheduled.filter { pending.contains($0.value.id) }
        prune()
    }

    /// After giving the system `plan` (whether or not every request went in): `pending` is
    /// every id it then holds. Only facts it really holds are recorded. What the app itself
    /// replaced is dropped, not consumed: a moved fact keeps its week.
    public mutating func noteScheduled(_ plan: [PlannedReminder], pending: Set<String>, calendar: Calendar) {
        scheduled = scheduled.filter { pending.contains($0.value.id) }
        for reminder in plan {
            guard let week = reminder.catFactWeek, pending.contains(reminder.id) else { continue }
            var components = reminder.fireDate
            components.calendar = nil
            components.timeZone = nil
            guard let due = calendar.date(from: components) else { continue }
            scheduled[week] = Scheduled(id: reminder.id, due: due)
        }
        prune()
    }

    private mutating func prune() {
        guard consumedWeeks.count > Self.keptWeeks else { return }
        consumedWeeks = Set(consumedWeeks.sorted().suffix(Self.keptWeeks))
    }
}

/// The cat facts the app can send. Text lives in the app's `CatFacts` strings table under these
/// ids; sources are in docs/CAT_FACTS_SOURCES.md. v1 has no health, food, safety or toxic-plant
/// facts. Ids are stable: never reuse one for a different fact.
public enum CatFacts {
    public static let all = [
        "fact.dawn-dusk", "fact.slow-blink", "fact.tail-up", "fact.purr", "fact.kneading",
        "fact.scratching", "fact.cheek-rub", "fact.carpal-whiskers", "fact.night-eyes", "fact.high-hearing",
        "fact.no-sweet", "fact.tongue", "fact.flehmen", "fact.meow-for-you", "fact.high-places",
        "fact.separate-resources", "fact.hiding-spot", "fact.catch-the-toy", "fact.wildcat-ancestor", "fact.kitten-social",
    ]

    /// Facts whose source a second person opened and checked: the rows of
    /// docs/CAT_FACTS_SOURCES.md with a link, visit date, role and check date (a test holds the
    /// two together). Nothing else is ever sent. First batch checked 2026-11-15.
    public static let verified: Set<String> = Set(all)

    /// What the reminders rotate through.
    public static var rotation: [String] { all.filter(verified.contains) }
}
