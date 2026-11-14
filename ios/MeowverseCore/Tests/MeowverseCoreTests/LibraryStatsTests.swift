import Foundation
import Testing
@testable import MeowverseCore

/// The numbers the room postcard may show: counts and the span of known capture days.
@Suite struct LibraryStatsTests {
    func photo(_ id: String, day: String?, source: CaptureDateSource? = nil) -> PhotoRecord {
        PhotoRecord(photoId: id, filename: nil, sha256: id, mimeType: "image/jpeg", byteSize: 1, width: 1, height: 1,
                    originalFile: "originals/\(id).jpeg", thumbnailFile: "thumbnails/\(id).jpg",
                    captureDate: day, captureDateSource: source ?? (day == nil ? .unknown : .exif),
                    exifCaptureDate: nil, importedAt: Date(timeIntervalSince1970: 0), revision: 1)
    }

    func piece(_ id: String, photos: [String]) -> PhotoFurniture {
        PhotoFurniture(instanceId: id, modelId: "kenney-chair", x: 0, z: 0, width: 1, depth: 1, turn: 0,
                       finish: .original, displayName: id, sources: photos.map { .manual(photoId: $0) },
                       tags: [], revision: 1)
    }

    func state(photos: [PhotoRecord], items: [PhotoFurniture] = [], storage: [PhotoFurniture] = []) -> AppState {
        AppState(revision: 1, photos: photos, observations: [], items: items, storage: storage)
    }

    @Test func emptyLibraryHasNothingToShow() {
        let stats = LibraryStats(state: .empty)
        #expect(stats.photoCount == 0)
        #expect(stats.furnitureCount == 0)
        #expect(stats.photosInFurnitureCount == 0)
        #expect(stats.captureSpan == nil)
        #expect(stats.isEmpty)
    }

    @Test func allDatesUnknownGivesNoSpan() {
        let stats = LibraryStats(state: state(photos: [photo("a", day: nil), photo("b", day: nil)]))
        #expect(stats.photoCount == 2)
        #expect(stats.captureSpan == nil)
        #expect(!stats.isEmpty)
    }

    @Test func aDayMarkedUnknownOrInvalidIsNotUsed() {
        // A stray day string with an `unknown` source, or a malformed day, is not a known date.
        let stats = LibraryStats(state: state(photos: [
            photo("a", day: "2024-05-01", source: .unknown), photo("b", day: "2024-13-40"), photo("c", day: "2024")
        ]))
        #expect(stats.captureSpan == nil)
    }

    @Test func oneDatedPhotoIsASingleDay() {
        let stats = LibraryStats(state: state(photos: [photo("a", day: "2026-03-14")]))
        #expect(stats.captureSpan == .single("2026-03-14"))
    }

    @Test func severalPhotosOnTheSameDayAreStillASingleDay() {
        let stats = LibraryStats(state: state(photos: [photo("a", day: "2026-03-14"), photo("b", day: "2026-03-14", source: .user)]))
        #expect(stats.captureSpan == .single("2026-03-14"))
    }

    @Test func mixedKnownAndUnknownSpansOnlyTheKnownDays() {
        let stats = LibraryStats(state: state(photos: [
            photo("a", day: nil), photo("b", day: "2025-11-02", source: .user), photo("c", day: "2023-03-09"),
            photo("d", day: nil), photo("e", day: "2024-07-30")
        ]))
        #expect(stats.photoCount == 5)
        #expect(stats.captureSpan == .range(earliest: "2023-03-09", latest: "2025-11-02"))
        #expect(stats.captureSpan?.earliest == "2023-03-09")
        #expect(stats.captureSpan?.latest == "2025-11-02")
    }

    @Test func furnitureCountsRoomAndStorage() {
        let stats = LibraryStats(state: state(photos: [photo("a", day: nil)],
                                              items: [piece("chair", photos: ["a"]), piece("bare", photos: [])],
                                              storage: [piece("boxed", photos: [])]))
        #expect(stats.furnitureCount == 3)
        #expect(stats.photosInFurnitureCount == 1)
    }

    @Test func aPhotoOnTwoPiecesIsCountedOnce() {
        let stats = LibraryStats(state: state(photos: [photo("a", day: nil), photo("b", day: nil), photo("c", day: nil)],
                                              items: [piece("chair", photos: ["a", "b"])],
                                              storage: [piece("sofa", photos: ["a"])]))
        #expect(stats.photosInFurnitureCount == 2)
    }

    @Test func aLinkToAMissingPhotoIsNotCounted() {
        let stats = LibraryStats(state: state(photos: [photo("a", day: nil)], items: [piece("chair", photos: ["a", "gone"])]))
        #expect(stats.photosInFurnitureCount == 1)
    }

    @Test func furnitureWithoutPhotosIsNotEmpty() {
        let stats = LibraryStats(state: state(photos: [], items: [piece("bare", photos: [])]))
        #expect(!stats.isEmpty)
        #expect(stats.captureSpan == nil)
    }
}
