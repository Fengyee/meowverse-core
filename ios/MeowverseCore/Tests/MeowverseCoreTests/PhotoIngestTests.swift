import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MeowverseCore

@Suite struct PhotoIngestTests {
    @Test func shaMatchesCryptoKitOverOriginalBytes() throws {
        let data = TestSupport.imageData(width: 80, height: 40)
        let draft = try PhotoIngest.makeDraft(data: data, filename: "x.jpg")
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(draft.sha256 == expected)
        #expect(draft.data == data)
        #expect(draft.byteSize == data.count)
        #expect(draft.mimeType == "image/jpeg")
        #expect(draft.width == 80 && draft.height == 40)
        #expect(draft.filename == "x.jpg")
    }

    @Test func exifDateTimeOriginalBecomesDay() throws {
        let data = TestSupport.imageData(dateTimeOriginal: "2024:03:15 23:59:58")
        let draft = try PhotoIngest.makeDraft(data: data, filename: "2019-01-01.jpg")
        #expect(draft.captureDate == "2024-03-15")
        #expect(draft.captureDateSource == .exif)
    }

    @Test func missingOrInvalidExifIsUnknownNeverFilename() throws {
        let plain = try PhotoIngest.makeDraft(data: TestSupport.imageData(), filename: "IMG_20190101_120000.jpg")
        #expect(plain.captureDate == nil)
        #expect(plain.captureDateSource == .unknown)
        let bogus = try PhotoIngest.makeDraft(data: TestSupport.imageData(dateTimeOriginal: "0000:00:00 00:00:00"), filename: nil)
        #expect(bogus.captureDate == nil && bogus.captureDateSource == .unknown)
        #expect(PhotoIngest.exifDay("2023:02:29 10:00:00") == nil)
        #expect(PhotoIngest.exifDay("2024:02:29 10:00:00") == "2024-02-29")
    }

    @Test func orientationCorrectedSizeAndThumbnail() throws {
        // Stored 120x60 with orientation 6 (rotate 90 CW) displays as 60x120.
        let data = TestSupport.imageData(width: 120, height: 60, orientation: 6)
        let draft = try PhotoIngest.makeDraft(data: data, filename: nil)
        #expect(draft.width == 60 && draft.height == 120)
        let thumb = try #require(CGImageSourceCreateWithData(draft.thumbnailJPEG as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(thumb, 0, nil) as? [CFString: Any])
        let tw = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let th = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        #expect(th > tw, "thumbnail has orientation applied")
        #expect(CGImageSourceGetType(thumb) as String? == "public.jpeg")
    }

    @Test func thumbnailIsAtMost512() throws {
        let draft = try PhotoIngest.makeDraft(data: TestSupport.imageData(width: 1600, height: 900), filename: nil)
        let image = try #require(PhotoIngest.downsampledImage(data: draft.thumbnailJPEG, maxPixel: 4096))
        #expect(max(image.width, image.height) == 512)
        let small = try #require(PhotoIngest.downsampledImage(data: draft.data, maxPixel: 100))
        #expect(max(small.width, small.height) == 100)
    }

    @Test func pngMimeType() throws {
        let draft = try PhotoIngest.makeDraft(data: TestSupport.imageData(type: .png), filename: nil)
        #expect(draft.mimeType == "image/png")
    }

    @Test func rejectsEmptyNonImageAndTooLarge() {
        #expect(throws: IngestError.empty) { try PhotoIngest.makeDraft(data: Data(), filename: nil) }
        #expect(throws: IngestError.notAnImage) { try PhotoIngest.makeDraft(data: Data("not a picture".utf8), filename: nil) }
        let huge = Data(count: PhotoIngest.maxBytes + 1)
        #expect(throws: IngestError.tooLarge(bytes: PhotoIngest.maxBytes + 1)) { try PhotoIngest.makeDraft(data: huge, filename: nil) }
    }

    @Test func downsampleFromURL() throws {
        let dir = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.jpg")
        try TestSupport.imageData(width: 300, height: 200).write(to: file)
        let image = try #require(PhotoIngest.downsampledImage(at: file, maxPixel: 150))
        #expect(image.width == 150 && image.height == 100)
        #expect(PhotoIngest.downsampledImage(at: dir.appendingPathComponent("missing.jpg"), maxPixel: 10) == nil)
    }
}
