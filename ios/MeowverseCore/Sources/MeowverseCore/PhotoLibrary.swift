import Foundation

/// What the user may change about a stored photo. `nil` leaves that part as it is.
/// The original bytes, the import time and the EXIF day are never part of an edit.
public struct PhotoEdit: Sendable, Equatable {
    public enum DateChange: Sendable, Equatable {
        /// `yyyy-MM-dd`; the source becomes `user`.
        case set(String)
        /// Drops a user-set day: back to the file's EXIF day if it has one, otherwise unknown.
        case clear
    }

    public var favorite: Bool?
    public var note: String?
    public var captureDate: DateChange?

    public init(favorite: Bool? = nil, note: String? = nil, captureDate: DateChange? = nil) {
        self.favorite = favorite
        self.note = note
        self.captureDate = captureDate
    }
}

/// Read-only preview of deleting one photo. Unlike the web `deletePhoto` cascade, no furniture
/// is ever removed with a photo: every piece that shows it, in the room or put away, just loses
/// it, and a piece left without photos stays where it is.
public struct PhotoDeletionImpact: Sendable, Equatable {
    public let furnitureToUpdate: [PhotoFurniture]

    public init(furnitureToUpdate: [PhotoFurniture]) {
        self.furnitureToUpdate = furnitureToUpdate
    }
}

extension AppState {
    /// Every piece linked to the photo: those in the room first, then those put away.
    public func furniture(containing photoId: String) -> [PhotoFurniture] {
        allFurniture.filter { $0.sources.contains { $0.photoId == photoId } }
    }

    /// Computing this never authorizes or performs a deletion.
    public func deletionImpact(photoId: String) -> PhotoDeletionImpact {
        PhotoDeletionImpact(furnitureToUpdate: furniture(containing: photoId))
    }
}

public enum PhotoFilter: String, CaseIterable, Sendable {
    case all, favorites, unlinked
}

/// Photos of one capture month, or the photos whose capture day is unknown.
public struct PhotoSection: Identifiable, Sendable, Equatable {
    /// `yyyy-MM`, or nil for "date unknown".
    public let month: String?
    public let photos: [PhotoRecord]

    public var id: String { month ?? "unknown" }

    public init(month: String?, photos: [PhotoRecord]) {
        self.month = month
        self.photos = photos
    }
}

public enum PhotoLibrary {
    /// Newest capture month first, newest day first inside a month; photos without a capture
    /// day form one last section. Import time and filename only break ties in the order of
    /// photos and never stand in for a capture date.
    ///
    /// `onFurniture` narrows the result to photos on at least one of those pieces; empty means
    /// no such limit.
    public static func sections(in state: AppState, filter: PhotoFilter, onFurniture: Set<String> = [],
                                linkedElsewhere: Set<String> = []) -> [PhotoSection] {
        let photos = filtered(state, filter, onFurniture, linkedElsewhere)
        var dated: [String: [PhotoRecord]] = [:]
        var unknown: [PhotoRecord] = []
        for photo in photos {
            if let day = photo.captureDate, photo.captureDateSource != .unknown, day.count >= 7 {
                dated[String(day.prefix(7)), default: []].append(photo)
            } else {
                unknown.append(photo)
            }
        }
        var sections = dated.keys.sorted(by: >).map { month in
            PhotoSection(month: month, photos: dated[month]!.sorted { a, b in
                if a.captureDate != b.captureDate { return (a.captureDate ?? "") > (b.captureDate ?? "") }
                return stableOrder(a, b)
            })
        }
        if !unknown.isEmpty {
            sections.append(PhotoSection(month: nil, photos: unknown.sorted(by: stableOrder)))
        }
        return sections
    }

    public static func count(in state: AppState, filter: PhotoFilter, onFurniture: Set<String> = [],
                             linkedElsewhere: Set<String> = []) -> Int {
        filtered(state, filter, onFurniture, linkedElsewhere).count
    }

    /// A real Gregorian calendar day written exactly as `yyyy-MM-dd`.
    public static func isValidDay(_ day: String) -> Bool {
        guard day.count == 10, !day.hasPrefix("0000") else { return false }
        return PhotoIngest.exifDay(day.replacingOccurrences(of: "-", with: ":")) == day
    }

    // MARK: Capture days

    /// A capture day is a calendar fact, not a moment. Days become dates (and back) in this
    /// calendar, Gregorian in UTC, where every day exists, so showing or editing a day never
    /// depends on some clock time existing in the device's zone. Format such a date in this
    /// calendar's zone. Only `creationDate` turns a day into a moment of a real zone.
    public static let dayCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 12:00 in `dayCalendar` on `day`; nil unless `day` is a valid `yyyy-MM-dd`.
    public static func dayDate(_ day: String?) -> Date? {
        guard let parts = dayParts(day) else { return nil }
        return dayCalendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12))
    }

    /// The `yyyy-MM-dd` of a date made by `dayDate` or picked in `dayCalendar`.
    public static func day(of date: Date) -> String {
        format(dayCalendar.dateComponents([.year, .month, .day], from: date))
    }

    /// Today's `yyyy-MM-dd` on a device in `timeZone`.
    public static func today(in timeZone: TimeZone, now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return format(calendar.dateComponents([.year, .month, .day], from: now))
    }

    /// Where the day editor starts: the recorded day, or today on the device when the day is
    /// unknown. Starting there saves nothing; only the user's own save sets a day.
    public static func pickerDate(for day: String?, now: Date = Date(), in timeZone: TimeZone) -> Date {
        dayDate(day) ?? dayDate(today(in: timeZone, now: now)) ?? now
    }

    /// The moment Photos is given for a copy dated `day`, on that day in `timeZone`: local noon,
    /// or, where the clocks skipped noon that day (Africa/Khartoum and Africa/Juba, 2000-01-15),
    /// the first moment after it. nil for an unknown day, and when the zone skipped the whole
    /// day (Pacific/Apia, 2011-12-30): no moment is that day there and a neighbouring day would
    /// change the memory, so Photos keeps its own date for the copy.
    public static func creationDate(on day: String?, in timeZone: TimeZone) -> Date? {
        guard let parts = dayParts(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let noon = DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12, minute: 0, second: 0)
        if let date = calendar.date(from: noon),
           calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == noon { return date }
        // The wall clock read at a moment, written as if it were UTC, so it compares with `dayCalendar` dates.
        guard let noonWall = dayCalendar.date(from: noon) else { return nil }
        let start = Int64(noonWall.timeIntervalSince1970)
        func wall(_ second: Int64) -> Int64 {
            second + Int64(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(second))))
        }
        // UTC offsets lie within -12…+14 hours, so the moment local noon would have is in this window.
        var before = start - 15 * 3600
        guard wall(before) < start else { return nil }
        var after = before
        while wall(after) < start {
            before = after
            after += 60
            if after > start + 15 * 3600 { return nil }
        }
        while after - before > 1 {
            let middle = (before + after) / 2
            if wall(middle) < start { before = middle } else { after = middle }
        }
        // The first moment after noon must still be that day; after a skipped day it is the next.
        guard wall(after) < start + 12 * 3600 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(after))
    }

    private static func dayParts(_ day: String?) -> (year: Int, month: Int, day: Int)? {
        guard let day, isValidDay(day) else { return nil }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return parts.count == 3 ? (parts[0], parts[1], parts[2]) : nil
    }

    private static func format(_ parts: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// `linkedElsewhere`: photos on pieces this build can't show (sync holds those back). They
    /// are on furniture all the same.
    private static func filtered(_ state: AppState, _ filter: PhotoFilter, _ onFurniture: Set<String>,
                                 _ linkedElsewhere: Set<String>) -> [PhotoRecord] {
        var base = filtered(state, filter)
        if filter == .unlinked { base.removeAll { linkedElsewhere.contains($0.photoId) } }
        guard !onFurniture.isEmpty else { return base }
        let wanted = Set(state.allFurniture.filter { onFurniture.contains($0.instanceId) }.flatMap { $0.sources.map(\.photoId) })
        return base.filter { wanted.contains($0.photoId) }
    }

    private static func filtered(_ state: AppState, _ filter: PhotoFilter) -> [PhotoRecord] {
        switch filter {
        case .all:
            return state.photos
        case .favorites:
            return state.photos.filter(\.favorite)
        case .unlinked:
            // A photo on a piece that is put away is still on a piece.
            let linked = LibraryIndex(state: state).linkedPhotoIds
            return state.photos.filter { !linked.contains($0.photoId) }
        }
    }

    private static func stableOrder(_ a: PhotoRecord, _ b: PhotoRecord) -> Bool {
        if a.importedAt != b.importedAt { return a.importedAt > b.importedAt }
        return a.photoId < b.photoId
    }
}
