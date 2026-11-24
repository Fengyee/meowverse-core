import Foundation
import Testing
@testable import MeowverseCore

/// IMPORT-1: the day a review shows is the stored record's. A draft made again from the stored
/// copy or from a file picked again never replaces it, not even when the stored day is unknown.
@Suite struct ReviewCaptureDayTests {
    private func draft(_ day: String?) -> ImportDraft {
        ImportDraft(data: Data([1]), sha256: "a", filename: nil, mimeType: "image/jpeg", byteSize: 1, width: 1, height: 1,
                    captureDate: day, captureDateSource: day == nil ? .unknown : .exif, thumbnailJPEG: Data())
    }

    private func record(_ day: String?, _ source: CaptureDateSource) -> PhotoRecord {
        PhotoRecord(photoId: "p", filename: nil, sha256: "a", mimeType: "image/jpeg", byteSize: 1, width: 1, height: 1,
                    originalFile: "originals/a.jpeg", thumbnailFile: "thumbnails/p.jpg",
                    captureDate: day, captureDateSource: source, exifCaptureDate: nil, importedAt: Date(timeIntervalSince1970: 0), revision: 1)
    }

    @Test func aReducedCopyWithoutExifShowsTheRecordedDay() {
        let shown = draft(nil).shownCaptureDay(stored: record("2026-03-14", .exif))
        #expect(shown.day == "2026-03-14")
        #expect(shown.source == .exif)
    }

    @Test func theUsersDayBeatsTheFilesDay() {
        let shown = draft("2024-03-15").shownCaptureDay(stored: record("2019-05-05", .user))
        #expect(shown.day == "2019-05-05")
        #expect(shown.source == .user)
    }

    @Test func aRecordedUnknownStaysUnknown() {
        let shown = draft("2024-03-15").shownCaptureDay(stored: record(nil, .unknown))
        #expect(shown.day == nil)
        #expect(shown.source == .unknown)
    }

    @Test func aPhotoNotStoredYetShowsItsFilesDay() {
        #expect(draft("2024-03-15").shownCaptureDay(stored: nil).day == "2024-03-15")
        #expect(draft(nil).shownCaptureDay(stored: nil).source == .unknown)
    }
}
