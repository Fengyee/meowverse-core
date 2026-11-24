import Foundation
import Testing
@testable import MeowverseCore

@Suite struct PhotoExportDateTests {
    @Test(arguments: [CaptureDateSource.exif, .user, .unknown])
    func onlyReducedCopiesCarryRecordedDays(_ source: CaptureDateSource) async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = TestSupport.imageData(width: 640, height: 480,
            dateTimeOriginal: source == .unknown ? nil : "2024:03:10 01:29:01")
        let draft = try PhotoIngest.makeDraft(data: bytes, filename: "test.jpg", maxPixel: 24)
        try #require(draft.reducedFrom != nil)
        let store = LibraryStore(root: root, catalog: try TestSupport.catalog())
        var photo = try await store.addPhoto(draft: draft)
        if source == .user {
            photo = try await store.editPhoto(photoId: photo.photoId, PhotoEdit(captureDate: .set("2024-11-03")))
        }
        let stored = try #require(await store.originalURL(photoId: photo.photoId))
        let copy = try await PhotoExport.prepare(photo: photo, stored: stored, in: root) { throw PhotoSourceIssue.permission }
        #expect(copy.copyCaptureDay?.day == photo.captureDate)
        #expect(copy.copyCaptureDay?.source == (source == .unknown ? nil : source))
        #expect(try Data(contentsOf: copy.url) == draft.data)
        if let day = copy.copyCaptureDay {
            for name in ["America/New_York", "Asia/Kathmandu", "Pacific/Kiritimati", "Pacific/Pago_Pago"] {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = try #require(TimeZone(identifier: name))
                let instant = try #require(PhotoLibrary.creationDate(on: day.day, in: calendar.timeZone))
                let parts = calendar.dateComponents([.year, .month, .day, .hour], from: instant)
                #expect(String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!) == photo.captureDate)
                #expect(parts.hour == 12)
            }
        }
        let original = try await PhotoExport.prepare(photo: photo, stored: stored, in: root) { bytes }
        #expect(original.copyCaptureDay == nil)
        #expect(try Data(contentsOf: original.url) == bytes)
    }

    static func record(day: String?) -> PhotoRecord {
        PhotoRecord(photoId: "p", filename: nil, sha256: "h", mimeType: "image/jpeg", byteSize: 1, width: 1, height: 1,
                    originalFile: "originals/h.jpg", thumbnailFile: "thumbnails/p.jpg",
                    captureDate: day, captureDateSource: day == nil ? .unknown : .exif, exifCaptureDate: day,
                    importedAt: Date(timeIntervalSince1970: 0), revision: 1)
    }

    static func copy(day: String?) -> PhotoExport {
        PhotoExport(url: URL(fileURLWithPath: "/dev/null"), copyReason: .permission,
                    copyCaptureDay: PhotoExport.CopyCaptureDay(record(day: day)))
    }

    /// Fifth review (R5-07): what the confirmation explains and what Photos is given come from
    /// one plan, and the plan says which copies get noon, a later moment of the same day, or no
    /// date because the day is unknown or the zone skipped it.
    @Test(arguments: [
        ("America/New_York", "2024-03-10" as String?, "noon"), ("America/New_York", "2024-11-03", "noon"),
        ("Africa/Khartoum", "2000-01-15", "later"), ("Africa/Juba", "2000-01-15", "later"),
        ("Pacific/Apia", "2011-12-30", "missing"), ("Pacific/Apia", "2011-12-31", "noon"),
        ("Asia/Shanghai", nil, "unknown"),
    ])
    func theCopyDateSaysWhatPhotosIsGiven(_ name: String, _ day: String?, _ expected: String) throws {
        let zone = try #require(TimeZone(identifier: name))
        let file = Self.copy(day: day)
        let plan = file.copyDate(in: zone)
        switch (expected, plan) {
        case ("noon", .localNoon(let date)), ("later", .laterThatDay(let date)):
            #expect(date == PhotoLibrary.creationDate(on: day, in: zone))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            #expect(String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!) == day)
            #expect((parts.hour == 12) == (expected == "noon"))
        case ("missing", .dayMissingHere), ("unknown", .unknownDay):
            #expect(plan.creationDate == nil)
        default:
            Issue.record("\(name) \(day ?? "unknown"): \(plan), expected \(expected)")
        }
        // A full original keeps the date in its own file.
        let original = PhotoExport(url: file.url, copyReason: nil)
        #expect(original.copyDate(in: zone) == .fromFile && original.copyDate(in: zone).creationDate == nil)
    }

    @Test func theCountsCoverEveryCopyOnce() throws {
        let apia = try #require(TimeZone(identifier: "Pacific/Apia"))
        let files = [Self.copy(day: "2011-12-30"), Self.copy(day: "2011-12-31"), Self.copy(day: nil),
                     Self.copy(day: "2011-12-29"), PhotoExport(url: URL(fileURLWithPath: "/dev/null"), copyReason: nil)]
        #expect(PhotoExport.copyDateCounts(files, in: apia)
                == PhotoExport.CopyDateCounts(localNoon: 2, laterThatDay: 0, dayMissingHere: 1, unknownDay: 1))
        let khartoum = try #require(TimeZone(identifier: "Africa/Khartoum"))
        #expect(PhotoExport.copyDateCounts([Self.copy(day: "2000-01-15")], in: khartoum)
                == PhotoExport.CopyDateCounts(laterThatDay: 1))
    }

    @Test func aSkippedLocalDayHasNoInventedReplacement() throws {
        let zone = try #require(TimeZone(identifier: "Pacific/Apia"))
        #expect(PhotoLibrary.creationDate(on: "2011-12-30", in: zone) == nil)
        #expect(PhotoLibrary.creationDate(on: "2026-02-30", in: zone) == nil)
    }
}
