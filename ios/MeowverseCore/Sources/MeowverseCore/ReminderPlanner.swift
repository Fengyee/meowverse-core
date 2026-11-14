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
    /// When memories (both kinds) arrive: a quiet evening hour.
    public var memoryTime = ReminderTime(hour: 20, minute: 0)
    /// Picks which photo, piece and day; fixed once per install so re-planning keeps the same days.
    public var seed: UInt64 = 0

    public init() {}

    public var anyEnabled: Bool { callsEnabled || onThisDayEnabled || furnitureEnabled }

    private enum CodingKeys: String, CodingKey { case callsEnabled, callTimes, onThisDayEnabled, furnitureEnabled, memoryTime, seed }

    /// Missing keys keep their defaults, so a later build can add settings without losing these.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReminderSettings()
        callsEnabled = try c.decodeIfPresent(Bool.self, forKey: .callsEnabled) ?? defaults.callsEnabled
        callTimes = try c.decodeIfPresent([ReminderTime].self, forKey: .callTimes) ?? defaults.callTimes
        onThisDayEnabled = try c.decodeIfPresent(Bool.self, forKey: .onThisDayEnabled) ?? defaults.onThisDayEnabled
        furnitureEnabled = try c.decodeIfPresent(Bool.self, forKey: .furnitureEnabled) ?? defaults.furnitureEnabled
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
    }

    /// Stable for the same slot and day, so re-planning replaces rather than duplicates.
    public let id: String
    public let kind: Kind
    /// Gregorian wall-clock components without a time zone. Calls: weekday, hour, minute and
    /// `repeats`; memories: year, month, day, hour, minute, fired once.
    public let fireDate: DateComponents
    public let repeats: Bool

    /// The piece a tap should open; nil opens the room.
    public var furnitureID: String? {
        switch kind {
        case .call: nil
        case .onThisDay(let memory): memory.piece?.instanceId
        case .furniture(let memory): memory.instanceId
        }
    }
}

/// Plans local notifications. Pure: the same library, settings, moment, calendar and seed give
/// the same plan.
///
/// Calls repeat by themselves (one weekly trigger per weekday and time, so the words rotate
/// without the app running). Memories are planned for `horizonDays` ahead and must be re-planned
/// whenever the app runs. iOS keeps at most 64 pending requests per app; with two call times
/// (14 requests) and one memory per day for 30 days the plan stays at or under 44, and
/// `limit` is a hard cap on top.
///
/// Rules:
/// - Only photos whose capture day is known (`exif` or `user`) and valid are remembered. Import
///   time never stands in for a capture day.
/// - "On this day" matches month and day exactly, in an earlier year. Feb 29 matches only Feb 29.
/// - At most one memory a day; "on this day" wins over a furniture memory.
/// - Pieces put away still count: their photos and detail page remain.
/// - Matching uses the Gregorian calendar (stored days are Gregorian) in the time zone of
///   `calendar`.
public enum ReminderPlanner {
    public static let horizonDays = 30
    public static let defaultLimit = 60
    public static let idPrefix = "meowverse.reminder."

    public static func plan(state: AppState, settings: ReminderSettings, now: Date, calendar: Calendar,
                            horizonDays: Int = horizonDays, limit: Int = defaultLimit) -> [PlannedReminder] {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let calls = settings.callsEnabled ? callPlan(settings) : []
        let memoryBudget = max(0, limit - calls.count)
        let memories = (settings.onThisDayEnabled || settings.furnitureEnabled) && memoryBudget > 0
            ? memoryPlan(state: state, settings: settings, now: now, calendar: gregorian, horizonDays: horizonDays)
            : []
        return Array(calls.prefix(limit)) + memories.prefix(memoryBudget)
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

    private static func memoryPlan(state: AppState, settings: ReminderSettings, now: Date, calendar: Calendar,
                                   horizonDays: Int) -> [PlannedReminder] {
        guard settings.memoryTime.isValid, horizonDays > 0 else { return [] }
        let dated = settings.onThisDayEnabled ? knownDays(state) : []
        let byMonthDay = Dictionary(grouping: dated) { "\($0.day.month)-\($0.day.day)" }
        let rotation = settings.furnitureEnabled ? furnitureCandidates(state) : []
        let start = calendar.startOfDay(for: now)
        let seed = settings.seed
        var plan: [PlannedReminder] = []
        for offset in 0..<horizonDays {
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = c.year, let month = c.month, let dayOfMonth = c.day else { continue }
            var fire = DateComponents(year: year, month: month, day: dayOfMonth,
                                      hour: settings.memoryTime.hour, minute: settings.memoryTime.minute)
            guard let fireMoment = calendar.date(from: fire), fireMoment > now else { continue }
            fire.calendar = Calendar(identifier: .gregorian)
            let today = Day(year: year, month: month, day: dayOfMonth)
            let ordinal = dayOrdinal(year: year, month: month, day: dayOfMonth)

            let matches = (byMonthDay["\(month)-\(dayOfMonth)"] ?? []).filter { $0.day.year < year }
            if let memory = onThisDay(matches, today: today, ordinal: ordinal, seed: seed, state: state) {
                plan.append(PlannedReminder(id: "\(idPrefix)onthisday.\(today.key)", kind: .onThisDay(memory),
                                            fireDate: fire, repeats: false))
                continue
            }
            // About weekly, on a weekday fixed by the seed, so re-planning keeps the same evenings.
            if !rotation.isEmpty, (UInt64(bitPattern: Int64(ordinal)) &+ seed) % 7 == 0 {
                let week = UInt64(bitPattern: Int64(ordinal / 7))
                let memory = rotation[Int((week &+ seed) % UInt64(rotation.count))]
                plan.append(PlannedReminder(id: "\(idPrefix)furniture.\(today.key)", kind: .furniture(memory),
                                            fireDate: fire, repeats: false))
            }
        }
        return plan
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
