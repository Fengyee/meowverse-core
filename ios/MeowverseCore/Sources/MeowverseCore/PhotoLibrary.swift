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
    public static func sections(in state: AppState, filter: PhotoFilter, onFurniture: Set<String> = []) -> [PhotoSection] {
        let photos = filtered(state, filter, onFurniture)
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

    public static func count(in state: AppState, filter: PhotoFilter, onFurniture: Set<String> = []) -> Int {
        filtered(state, filter, onFurniture).count
    }

    /// A real Gregorian calendar day written exactly as `yyyy-MM-dd`.
    public static func isValidDay(_ day: String) -> Bool {
        guard day.count == 10, !day.hasPrefix("0000") else { return false }
        return PhotoIngest.exifDay(day.replacingOccurrences(of: "-", with: ":")) == day
    }

    private static func filtered(_ state: AppState, _ filter: PhotoFilter, _ onFurniture: Set<String>) -> [PhotoRecord] {
        let base = filtered(state, filter)
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
