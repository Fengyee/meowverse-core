import Foundation
import Testing
@testable import MeowverseCore

/// A capture day is a calendar fact, `yyyy-MM-dd`; an instant is only needed when a copy is
/// handed to Photos. Showing and editing a day must not depend on some clock time existing in
/// the device's zone, and the instant given to Photos must fall on that same local day.
@Suite struct CaptureDayTests {
    private func zone(_ name: String) throws -> TimeZone {
        try #require(TimeZone(identifier: name))
    }

    private func localParts(_ date: Date, in timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    private func dayString(_ parts: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// 2026-11-15 12:00 UTC: "today" for the editor of a photo without a day.
    private let now = Date(timeIntervalSince1970: 1_794_744_000)

    /// Khartoum and Juba went from UTC+2 to UTC+3 at local noon on 2000-01-15, so that day has
    /// no 12:00. Apia skipped 2011-12-30 entirely. New York's 2024-03-10 lost 02:00–03:00 only.
    static let days = ["2000-01-15", "2011-12-30", "2024-03-10", "2024-02-29", "1970-01-01", "1900-03-01"]
    static let zones = ["Africa/Khartoum", "Africa/Juba", "Pacific/Apia", "America/New_York", "Asia/Kathmandu",
                        "Australia/Lord_Howe", "Pacific/Kiritimati", "UTC"]

    /// The editor opens on the photo's own day, whatever the device's zone, and saving it
    /// unchanged writes the same day back.
    @Test(arguments: zones)
    func theEditorOpensOnTheRecordedDay(_ name: String) throws {
        let timeZone = try zone(name)
        for day in Self.days {
            let initial = PhotoLibrary.pickerDate(for: day, now: now, in: timeZone)
            #expect(PhotoLibrary.day(of: initial) == day, "\(name) \(day)")
        }
    }

    /// The day is shown as itself, in any device zone: it is never "no recorded date". Run this
    /// suite with `TZ=Africa/Khartoum` (or any zone) to check it under that device zone.
    @Test func aRecordedDayIsShownAsThatDay() throws {
        let style = Date.FormatStyle(date: .numeric, time: .omitted, locale: Locale(identifier: "en_US_POSIX"),
                                     calendar: PhotoLibrary.dayCalendar, timeZone: PhotoLibrary.dayCalendar.timeZone)
        for day in Self.days {
            let date = try #require(PhotoLibrary.dayDate(day), "\(day) in \(TimeZone.current.identifier)")
            let parts = day.split(separator: "-").map { Int($0)! }
            #expect(date.formatted(style) == "\(parts[1])/\(parts[2])/\(parts[0])")
            #expect(PhotoLibrary.day(of: date) == day)
        }
        let month = try #require(PhotoLibrary.dayDate("2011-12-01"))
        #expect(PhotoLibrary.dayCalendar.component(.month, from: month) == 12)
    }

    /// The instant handed to Photos is local noon when noon exists, otherwise the first moment
    /// after noon on the same day; either way the same local day.
    @Test(arguments: [
        ("Africa/Khartoum", "2000-01-15", 13, 0), ("Africa/Juba", "2000-01-15", 13, 0),
        ("America/New_York", "2024-03-10", 12, 0), ("America/New_York", "2024-11-03", 12, 0),
        ("Asia/Kathmandu", "2024-03-10", 12, 0), ("Asia/Kathmandu", "1986-01-01", 12, 0),
        ("Australia/Lord_Howe", "2024-04-07", 12, 0), ("Australia/Lord_Howe", "2024-10-06", 12, 0),
        ("Pacific/Apia", "2011-12-29", 12, 0), ("Pacific/Apia", "2011-12-31", 12, 0),
    ])
    func photosGetAnInstantOnTheSameLocalDay(_ name: String, _ day: String, hour: Int, minute: Int) throws {
        let timeZone = try zone(name)
        let instant = try #require(PhotoLibrary.creationDate(on: day, in: timeZone), "\(name) \(day)")
        let parts = localParts(instant, in: timeZone)
        #expect(dayString(parts) == day, "\(name) \(day)")
        #expect(parts.hour == hour && parts.minute == minute, "\(name) \(day): \(parts)")
        // Nothing on that day between 12:00 and the chosen moment.
        if hour != 12 || minute != 0 {
            let earlier = instant.addingTimeInterval(-1)
            let before = localParts(earlier, in: timeZone)
            #expect(dayString(before) == day && (before.hour ?? 0) < 12, "\(name) \(day): \(before)")
        }
    }

    /// Apia has no 2011-12-30: no instant can be that local day, so Photos gets none and keeps
    /// its own date, instead of a neighbouring day. The day still shows and edits as itself.
    @Test func aWholeMissingDayGivesPhotosNoInstant() throws {
        let apia = try zone("Pacific/Apia")
        #expect(PhotoLibrary.creationDate(on: "2011-12-30", in: apia) == nil)
        #expect(PhotoLibrary.dayDate("2011-12-30").map(PhotoLibrary.day(of:)) == "2011-12-30")
        #expect(PhotoLibrary.day(of: PhotoLibrary.pickerDate(for: "2011-12-30", now: now, in: apia)) == "2011-12-30")
    }

    /// Unknown stays unknown: no day is invented for display or for Photos. The editor of a photo
    /// without a day starts on today in the device's zone; nothing is saved until the user does.
    @Test(arguments: [nil, "", "2026-02-30", "0000-01-01", "2024-3-1"] as [String?])
    func anUnknownDayIsNeverFilledIn(_ day: String?) throws {
        let kathmandu = try zone("Asia/Kathmandu"), apia = try zone("Pacific/Apia")
        #expect(PhotoLibrary.dayDate(day) == nil)
        #expect(PhotoLibrary.creationDate(on: day, in: kathmandu) == nil)
        #expect(PhotoLibrary.day(of: PhotoLibrary.pickerDate(for: day, now: now, in: kathmandu)) == "2026-11-15")
        // 12:00 UTC is already the next day in Apia (UTC+13).
        #expect(PhotoLibrary.day(of: PhotoLibrary.pickerDate(for: day, now: now, in: apia)) == "2026-11-16")
    }
}
