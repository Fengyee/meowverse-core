import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a reduced copy was made from: the bytes the photo picker handed over, which the app
/// does not keep. The full-size photo stays in the user's photo library.
public struct ReducedFrom: Codable, Sendable, Equatable {
    /// Lowercase hex SHA-256 of the source bytes.
    public let sha256: String
    public let byteSize: Int
    /// Orientation-corrected pixel size of the source.
    public let width: Int
    public let height: Int

    public init(sha256: String, byteSize: Int, width: Int, height: Int) {
        self.sha256 = sha256
        self.byteSize = byteSize
        self.width = width
        self.height = height
    }
}

/// A decoded-but-not-yet-stored import. `data` holds the bytes to store: the picked file
/// untouched, or a reduced copy of it when `reducedFrom` is set.
public struct ImportDraft: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let data: Data
    /// Lowercase hex SHA-256 of `data`.
    public let sha256: String
    public let filename: String?
    public let mimeType: String
    public let byteSize: Int
    /// Orientation-corrected pixel size.
    public let width: Int
    public let height: Int
    /// `yyyy-MM-dd` from EXIF DateTimeOriginal, or nil.
    public let captureDate: String?
    public let captureDateSource: CaptureDateSource
    /// JPEG, longest side <= 512 px, orientation applied, no metadata.
    public let thumbnailJPEG: Data
    /// Set when `data` is a reduced copy; nil when `data` is the picked file itself.
    public let reducedFrom: ReducedFrom?
    /// The photo library's identifier for the picked asset, when the picker gave one. Set by
    /// the caller after `makeDraft`; it plays no part in matching or in what is stored on disk.
    public var assetIdentifier: String?
    /// The photo library's cross-device identifier for the same asset, when the app may read
    /// the library. Like `assetIdentifier`, a hint that plays no part in matching.
    public var cloudIdentifier: String?

    public init(id: UUID = UUID(), data: Data, sha256: String, filename: String?, mimeType: String, byteSize: Int,
                width: Int, height: Int, captureDate: String?, captureDateSource: CaptureDateSource, thumbnailJPEG: Data,
                reducedFrom: ReducedFrom? = nil) {
        self.id = id
        self.data = data
        self.sha256 = sha256
        self.filename = filename
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.width = width
        self.height = height
        self.captureDate = captureDate
        self.captureDateSource = captureDateSource
        self.thumbnailJPEG = thumbnailJPEG
        self.reducedFrom = reducedFrom
    }
}

public enum IngestError: Error, Equatable, Sendable {
    case empty
    case notAnImage
    case tooLarge(bytes: Int)
}

public enum PhotoIngest {
    public static let maxBytes = 100 * 1024 * 1024
    public static let thumbnailMaxPixel = 512
    /// Longest side of the copy the app keeps. Enough for a full-screen view with some zoom; the
    /// full-size photo stays in the user's photo library, so it is not stored a second time.
    public static let storedMaxPixel = 2048
    /// Longest side of the copy kept for a photo the app can also read from the photo library:
    /// enough to recognise it and fill the screen if the library copy ever goes away.
    public static let linkedMaxPixel = 1024

    /// Synchronous and CPU-heavy: call off the main actor.
    ///
    /// With `reduce`, a photo larger than `storedMaxPixel` becomes a reduced copy (HEIC, or JPEG
    /// where HEIC cannot be written) and `reducedFrom` records the source. Backups pass false:
    /// their bytes are already what a record describes and must stay byte for byte.
    ///
    /// `maxPixel` is the longest side of a reduced copy. The default is what the app keeps when
    /// it is the only holder of a viewable photo; `linkedMaxPixel` is for a photo whose full
    /// size the app can read back from the photo library.
    public static func makeDraft(data: Data, filename: String?, reduce: Bool = true,
                                 maxPixel: Int = storedMaxPixel) throws -> ImportDraft {
        guard !data.isEmpty else { throw IngestError.empty }
        guard data.count <= maxBytes else { throw IngestError.tooLarge(bytes: data.count) }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let rawWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let rawHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              rawWidth > 0, rawHeight > 0
        else { throw IngestError.notAnImage }

        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swaps = (5...8).contains(orientation)
        let mimeType = UTType(typeIdentifier)?.preferredMIMEType ?? "application/octet-stream"

        guard let thumb = thumbnail(source: source, maxPixel: thumbnailMaxPixel),
              let thumbData = jpegData(thumb, quality: 0.82)
        else { throw IngestError.notAnImage }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let day = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(exifDay)

        let width = swaps ? rawHeight : rawWidth, height = swaps ? rawWidth : rawHeight
        if reduce, max(width, height) > maxPixel,
           let image = thumbnail(source: source, maxPixel: maxPixel),
           let copy = reducedCopy(image), copy.data.count < data.count {
            return ImportDraft(
                data: copy.data, sha256: sha256Hex(copy.data), filename: filename, mimeType: copy.mimeType,
                byteSize: copy.data.count, width: image.width, height: image.height,
                captureDate: day, captureDateSource: day == nil ? .unknown : .exif, thumbnailJPEG: thumbData,
                reducedFrom: ReducedFrom(sha256: sha256Hex(data), byteSize: data.count, width: width, height: height)
            )
        }
        return ImportDraft(
            data: data,
            sha256: sha256Hex(data),
            filename: filename,
            mimeType: mimeType,
            byteSize: data.count,
            width: width,
            height: height,
            captureDate: day,
            captureDateSource: day == nil ? .unknown : .exif,
            thumbnailJPEG: thumbData
        )
    }

    /// Orientation is already applied to `image` and no metadata is written: the capture day
    /// lives in the record, and the location stays out of the app's copy.
    private static func reducedCopy(_ image: CGImage) -> (data: Data, mimeType: String)? {
        if let heic = encoded(image, type: .heic, quality: 0.8) { return (heic, "image/heic") }
        if let jpeg = encoded(image, type: .jpeg, quality: 0.85) { return (jpeg, "image/jpeg") }
        return nil
    }

    public static func downsampledImage(data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return thumbnail(source: source, maxPixel: maxPixel)
    }

    public static func downsampledImage(at url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return thumbnail(source: source, maxPixel: maxPixel)
    }

    /// Lowercase hex SHA-256.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `"yyyy:MM:dd HH:mm:ss"` (EXIF) -> `"yyyy-MM-dd"` when it names a real calendar day.
    public static func exifDay(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let datePart = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let parts = datePart.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1800...9999).contains(y), (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = DateComponents(year: y, month: m, day: d)
        guard let date = calendar.date(from: comps),
              calendar.component(.day, from: date) == d,
              calendar.component(.month, from: date) == m
        else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    // MARK: - Private

    private static func thumbnail(source: CGImageSource, maxPixel: Int) -> CGImage? {
        guard maxPixel > 0, CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        encoded(image, type: .jpeg, quality: quality)
    }

    private static func encoded(_ image: CGImage, type: UTType, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
