import Foundation

/// The twelve alternate app icons (`Assets.xcassets/AppIcon-<rawValue>.appiconset`).
public enum AppIconTheme: String, CaseIterable, Sendable {
    case springSakura = "spring-sakura"
    case summerSea = "summer-sea"
    case autumnMaple = "autumn-maple"
    case winterKnit = "winter-knit"
    case thanksgivingHarvest = "thanksgiving-harvest"
    case christmasHolly = "christmas-holly"
    case newYearStarlight = "newyear-starlight"
    case lunarNewYear = "lunar-newyear"
    case valentineRose = "valentine-rose"
    case lanternGlow = "lantern-glow"
    /// Everyday colourways: in the app for a later icon picker, never chosen by date.
    case creamClassic = "cream-classic"
    case midnightSage = "midnight-sage"

    /// The name passed to `setAlternateIconName`.
    public var iconName: String { "AppIcon-" + rawValue }
}

/// Which way round the seasons go. Taken from the region setting, not the location: the app
/// asks for no location permission.
public enum Hemisphere: Sendable, Equatable {
    case northern, southern

    /// Regions mostly south of the equator where a season icon should be six months off.
    /// Equatorial regions keep the northern default.
    static let southernRegions: Set<String> = [
        "AR", "AU", "BO", "BR", "BW", "CL", "FJ", "LS", "MG", "MU", "MW", "MZ", "NA", "NC",
        "NZ", "PY", "SZ", "UY", "ZA", "ZM", "ZW",
    ]

    public init(regionCode: String?) {
        self = Self.southernRegions.contains(regionCode?.uppercased() ?? "") ? .southern : .northern
    }
}

/// A calendar day (no time, no zone). The icon follows the day on the user's own clock.
public struct IconDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The local calendar day of `date` in `timeZone`.
    public init(_ date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// Day arithmetic on a fixed UTC calendar, where every day exists.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var noonUTC: Date {
        Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    public func adding(days: Int) -> IconDay {
        IconDay(Self.utc.date(byAdding: .day, value: days, to: noonUTC)!, in: Self.utc.timeZone)
    }

    public static func < (lhs: IconDay, rhs: IconDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

/// Which icon a day should show: a season by Gregorian month, unless a holiday window covers
/// the day. Windows for 2026–27 follow the icon pack's usage notes; the same offsets are
/// applied to every year, and the lunar dates come from the system's Chinese calendar.
public enum AppIconCalendar {
    public static func theme(at date: Date, in timeZone: TimeZone, hemisphere: Hemisphere) -> AppIconTheme {
        theme(on: IconDay(date, in: timeZone), hemisphere: hemisphere)
    }

    public static func theme(on day: IconDay, hemisphere: Hemisphere) -> AppIconTheme {
        holiday(on: day, hemisphere: hemisphere) ?? season(of: day, hemisphere: hemisphere)
    }

    /// Meteorological seasons: Mar–May spring, Jun–Aug summer, Sep–Nov autumn, Dec–Feb winter
    /// in the north; shifted by six months in the south.
    public static func season(of day: IconDay, hemisphere: Hemisphere) -> AppIconTheme {
        let month = hemisphere == .northern ? day.month : (day.month + 5) % 12 + 1
        switch month {
        case 3...5: return .springSakura
        case 6...8: return .summerSea
        case 9...11: return .autumnMaple
        default: return .winterKnit
        }
    }

    // MARK: Holidays

    struct Holiday {
        let theme: AppIconTheme
        /// First and last day the icon may show.
        let window: ClosedRange<IconDay>
        /// The festival days themselves; they win over any other window.
        let peak: ClosedRange<IconDay>
    }

    /// Among peaks, and among windows whose next peak is equally near, the first wins.
    static let priority: [AppIconTheme] = [
        .lunarNewYear, .lanternGlow, .valentineRose, .newYearStarlight, .christmasHolly, .thanksgivingHarvest,
    ]

    /// The holiday icon for `day`, if any window covers it. Overlaps resolve so the icon
    /// changes as rarely as possible and never hides a festival day:
    /// 1. a holiday on one of its peak days wins (ties by `priority`);
    /// 2. else the holiday whose peak is nearest ahead;
    /// 3. else (every covering holiday is over) the one whose peak ended most recently.
    static func holiday(on day: IconDay, hemisphere: Hemisphere) -> AppIconTheme? {
        let active = holidays(around: day.year, hemisphere: hemisphere).filter { $0.window.contains(day) }
        func rank(_ holiday: Holiday) -> Int { priority.firstIndex(of: holiday.theme) ?? priority.count }
        if let peak = active.filter({ $0.peak.contains(day) }).min(by: { rank($0) < rank($1) }) {
            return peak.theme
        }
        let ahead = active.filter { $0.peak.lowerBound > day }
        if let next = ahead.min(by: { ($0.peak.lowerBound, rank($0)) < ($1.peak.lowerBound, rank($1)) }) {
            return next.theme
        }
        return active.max(by: { ($0.peak.upperBound, -rank($0)) < ($1.peak.upperBound, -rank($1)) })?.theme
    }

    /// Every holiday whose window could touch `year` (windows cross the year boundary).
    static func holidays(around year: Int, hemisphere: Hemisphere) -> [Holiday] {
        (year - 1...year + 1).flatMap { holidays(in: $0, hemisphere: hemisphere) }
    }

    static func holidays(in year: Int, hemisphere: Hemisphere) -> [Holiday] {
        func d(_ month: Int, _ day: Int) -> IconDay { IconDay(year: year, month: month, day: day) }
        let springFestival = lunarNewYear(in: year)
        let lantern = lanternFestival(in: year)
        var list = [
            // 12-01 – 12-26 (notes: 2026-12-01 – 12-26).
            Holiday(theme: .christmasHolly, window: d(12, 1)...d(12, 26), peak: d(12, 24)...d(12, 25)),
            // 12-27 – 01-07 (notes: 2026-12-27 – 2027-01-07).
            Holiday(theme: .newYearStarlight, window: d(12, 27)...IconDay(year: year + 1, month: 1, day: 7),
                    peak: d(12, 31)...IconDay(year: year + 1, month: 1, day: 1)),
            // Two weeks before new year's day to the eve of the Lantern Festival
            // (notes: 2027-01-23 – 02-19). Peak: eve to the third day.
            Holiday(theme: .lunarNewYear, window: springFestival.adding(days: -14)...lantern.adding(days: -1),
                    peak: springFestival.adding(days: -1)...springFestival.adding(days: 2)),
            // 02-10 – 02-15 (notes: 2027-02-10 – 02-15).
            Holiday(theme: .valentineRose, window: d(2, 10)...d(2, 15), peak: d(2, 14)...d(2, 14)),
            // Four days before to two days after the 15th of the first month
            // (notes: 2027-02-16 – 02-22).
            Holiday(theme: .lanternGlow, window: lantern.adding(days: -4)...lantern.adding(days: 2),
                    peak: lantern...lantern),
        ]
        if hemisphere == .northern {
            // A harvest icon in the northern autumn only. From a week before (notes:
            // 2026-11-19) until Christmas takes over on 12-01. The notes end on the Sunday
            // after (11-29); one or two days of autumn in between would cost an extra alert.
            let thursday = thanksgiving(in: year)
            list.append(Holiday(theme: .thanksgivingHarvest, window: thursday.adding(days: -7)...d(11, 30),
                                peak: thursday...thursday))
        }
        return list
    }

    // MARK: Dates

    /// The lunar calendar is computed for China Standard Time, as the almanac is.
    private static let chinaTime = TimeZone(identifier: "Asia/Shanghai")!

    private static var chinese: Calendar {
        var calendar = Calendar(identifier: .chinese)
        calendar.timeZone = chinaTime
        return calendar
    }

    private static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chinaTime
        return calendar
    }

    /// Day `day` of the first (non-leap) month of the Chinese year that starts in `year`.
    private static func firstMonth(day: Int, of year: Int) -> IconDay {
        // June is always after the new year (which falls between 01-21 and 02-20).
        let june = gregorian.date(from: DateComponents(year: year, month: 6, day: 1))!
        let lunarYear = chinese.dateComponents([.era, .year], from: june)
        var parts = DateComponents()
        parts.era = lunarYear.era
        parts.year = lunarYear.year
        parts.month = 1
        parts.day = day
        parts.isLeapMonth = false
        return IconDay(chinese.date(from: parts)!, in: chinaTime)
    }

    /// 春节, the first day of the first lunar month, in Gregorian `year`.
    public static func lunarNewYear(in year: Int) -> IconDay { firstMonth(day: 1, of: year) }

    /// 元宵节, the 15th of the first lunar month.
    public static func lanternFestival(in year: Int) -> IconDay { firstMonth(day: 15, of: year) }

    /// US Thanksgiving, the fourth Thursday of November.
    public static func thanksgiving(in year: Int) -> IconDay {
        let first = IconDay(year: year, month: 11, day: 1)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let weekday = utc.component(.weekday, from: utc.date(from: DateComponents(year: year, month: 11, day: 1, hour: 12))!)
        let toThursday = (5 - weekday + 7) % 7   // weekday: 1 = Sunday … 5 = Thursday
        return first.adding(days: toThursday + 21)
    }
}

/// When to call `setAlternateIconName`. Each change shows a system alert the app cannot
/// suppress, so an icon is only requested when it differs from the current one, and the same
/// target is requested once: a refused or failed change is not retried on every launch.
public enum AppIconSync {
    /// The last icon the app asked for, kept in user defaults.
    public enum Attempt: Equatable, Sendable {
        case primary
        case icon(String)

        public init(target: String?) {
            self = target.map(Attempt.icon) ?? .primary
        }

        private static let primaryValue = "primary"

        public init?(stored: String?) {
            guard let stored else { return nil }
            self = stored == Self.primaryValue ? .primary : .icon(stored)
        }

        public var stored: String {
            switch self {
            case .primary: Self.primaryValue
            case .icon(let name): name
            }
        }
    }

    /// `nil` is the primary icon.
    public static func target(followsCalendar: Bool, theme: AppIconTheme) -> String? {
        followsCalendar ? theme.iconName : nil
    }

    public static func shouldAttempt(target: String?, current: String?, lastAttempt: Attempt?) -> Bool {
        target != current && lastAttempt != Attempt(target: target)
    }
}
