import Foundation

/// Counts for the room postcard, read from one state snapshot. Pure: no files, no formatting.
public struct LibraryStats: Sendable, Hashable {
    /// The calendar days (`yyyy-MM-dd`) the known capture dates cover.
    public enum CaptureSpan: Sendable, Hashable {
        /// Every known date is this one day.
        case single(String)
        /// `earliest < latest`.
        case range(earliest: String, latest: String)

        public var earliest: String {
            switch self {
            case .single(let day): day
            case .range(let earliest, _): earliest
            }
        }

        public var latest: String {
            switch self {
            case .single(let day): day
            case .range(_, let latest): latest
            }
        }
    }

    public let photoCount: Int
    /// Pieces in the room plus pieces put away.
    public let furnitureCount: Int
    /// Distinct library photos linked to at least one piece, in the room or put away.
    public let photosInFurnitureCount: Int
    /// nil when no photo has a known capture day. Import time never stands in for one.
    public let captureSpan: CaptureSpan?

    public init(photoCount: Int, furnitureCount: Int, photosInFurnitureCount: Int, captureSpan: CaptureSpan?) {
        self.photoCount = photoCount
        self.furnitureCount = furnitureCount
        self.photosInFurnitureCount = photosInFurnitureCount
        self.captureSpan = captureSpan
    }

    public init(state: AppState) {
        let pieces = state.items + state.storage
        let photoIds = Set(state.photos.map(\.photoId))
        let linked = Set(pieces.flatMap { $0.sources.map(\.photoId) }).intersection(photoIds)
        let days = state.photos.compactMap { photo -> String? in
            guard photo.captureDateSource != .unknown, let day = photo.captureDate, PhotoLibrary.isValidDay(day)
            else { return nil }
            return day
        }
        // `yyyy-MM-dd` sorts as text in calendar order.
        let span: CaptureSpan? = switch (days.min(), days.max()) {
        case let (earliest?, latest?): earliest == latest ? .single(earliest) : .range(earliest: earliest, latest: latest)
        default: nil
        }
        self.init(photoCount: state.photos.count, furnitureCount: pieces.count,
                  photosInFurnitureCount: linked.count, captureSpan: span)
    }

    /// Nothing worth showing: no photos and no furniture.
    public var isEmpty: Bool { photoCount == 0 && furnitureCount == 0 }
}
