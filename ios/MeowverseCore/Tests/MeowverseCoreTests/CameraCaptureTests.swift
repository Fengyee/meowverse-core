import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MeowverseCore

/// A photo taken in the app keeps the camera's EXIF (capture day, orientation), never gains a
/// date it did not have, and carries no location.
@Suite struct CameraCaptureTests {
    /// The shape of `UIImagePickerController.InfoKey.mediaMetadata` from the system camera,
    /// with a location added to prove it is dropped.
    private static func cameraMetadata(date: String? = "2026:03:14 09:26:53", orientation: Int = 6) -> [String: Any] {
        var exif: [String: Any] = [kCGImagePropertyExifLensModel as String: "Synthetic lens",
                                   kCGImagePropertyExifExposureTime as String: 0.01]
        if let date {
            exif[kCGImagePropertyExifDateTimeOriginal as String] = date
            exif[kCGImagePropertyExifDateTimeDigitized as String] = date
        }
        return [
            kCGImagePropertyOrientation as String: orientation,
            kCGImagePropertyExifDictionary as String: exif,
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Apple",
                                                       kCGImagePropertyTIFFOrientation as String: orientation],
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 22.3,
                                                      kCGImagePropertyGPSLatitudeRef as String: "N",
                                                      kCGImagePropertyGPSLongitude as String: 114.2,
                                                      kCGImagePropertyGPSLongitudeRef as String: "E"],
        ]
    }

    private static func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private static func gpsTags(_ data: Data) throws -> [String] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return [] }
        return tags.compactMap { tag in
            let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
            let prefix = CGImageMetadataTagCopyPrefix(tag) as String? ?? ""
            return name.uppercased().hasPrefix("GPS") || prefix.lowercased().contains("gps") ? "\(prefix):\(name)" : nil
        }
    }

    @Test(arguments: [UTType.heic, .jpeg])
    func keepsTheCameraDayAndOrientation(type: UTType) throws {
        // Sensor pixels 120x60, shown rotated a quarter turn (EXIF 6) as 60x120.
        let image = TestSupport.cgImage(width: 120, height: 60, seed: 3)
        let encoded = try CameraCapture.encode(image, orientation: 6, metadata: Self.cameraMetadata(), type: type)
        let props = try Self.properties(encoded.data)
        let exif = try #require(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:03:14 09:26:53")
        #expect(exif[kCGImagePropertyExifLensModel] as? String == "Synthetic lens")
        #expect((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 6)

        let draft = try PhotoIngest.makeDraft(data: encoded.data, filename: nil)
        #expect(draft.captureDate == "2026-03-14")
        #expect(draft.captureDateSource == .exif)
        #expect(draft.width == 60 && draft.height == 120)
        #expect(draft.mimeType == encoded.mimeType)
    }

    @Test(arguments: [UTType.heic, .jpeg])
    func carriesNoLocation(type: UTType) throws {
        let image = TestSupport.cgImage(width: 64, height: 48)
        let encoded = try CameraCapture.encode(image, orientation: 1, metadata: Self.cameraMetadata(orientation: 1), type: type)
        let props = try Self.properties(encoded.data)
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        #expect(try Self.gpsTags(encoded.data).isEmpty)
    }

    @Test func noExifMeansAnUnknownDayNotToday() throws {
        let image = TestSupport.cgImage(width: 64, height: 48)
        for metadata in [nil, [:], Self.cameraMetadata(date: nil, orientation: 1)] as [[String: Any]?] {
            let encoded = try CameraCapture.encode(image, orientation: 1, metadata: metadata)
            let exif = try Self.properties(encoded.data)[kCGImagePropertyExifDictionary] as? [CFString: Any]
            #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil, "the encoder must not invent a capture time")
            let draft = try PhotoIngest.makeDraft(data: encoded.data, filename: nil)
            #expect(draft.captureDate == nil)
            #expect(draft.captureDateSource == .unknown)
        }
    }

    /// The pixels' own orientation wins over a stale value in the metadata, in both places
    /// EXIF readers look for it.
    @Test func pixelOrientationWinsOverTheMetadata() throws {
        let image = TestSupport.cgImage(width: 120, height: 60)
        let encoded = try CameraCapture.encode(image, orientation: 8, metadata: Self.cameraMetadata(orientation: 1), type: .jpeg)
        let props = try Self.properties(encoded.data)
        #expect((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 8)
        let tiff = try #require(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        #expect((tiff[kCGImagePropertyTIFFOrientation] as? NSNumber)?.intValue == 8)
        #expect(tiff[kCGImagePropertyTIFFMake] as? String == "Apple")
        let draft = try PhotoIngest.makeDraft(data: encoded.data, filename: nil)
        #expect(draft.width == 60 && draft.height == 120)
    }

    @Test func prefersHEICAndFallsBackToJPEG() throws {
        let image = TestSupport.cgImage(width: 64, height: 48)
        let encoded = try CameraCapture.encode(image, orientation: 1, metadata: nil)
        #expect(["image/heic", "image/jpeg"].contains(encoded.mimeType))
        let source = try #require(CGImageSourceCreateWithData(encoded.data as CFData, nil))
        #expect(UTType(CGImageSourceGetType(source) as String? ?? "")?.preferredMIMEType == encoded.mimeType)
    }

    @Test func rejectsAnOrientationOutsideEXIF() {
        let image = TestSupport.cgImage(width: 8, height: 8)
        #expect(throws: CameraCapture.EncodeError.self) {
            try CameraCapture.encode(image, orientation: 9, metadata: nil)
        }
    }
}
