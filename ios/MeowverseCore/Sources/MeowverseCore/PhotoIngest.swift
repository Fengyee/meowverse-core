import CoreGraphics
import CoreImage
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

/// The exact binding that PhotoKit could no longer resolve when the user reselected an asset.
public struct MissingLibraryBinding: Equatable, Sendable {
    let photoId: String
    let local: String?
    let cloud: String?

    private init(photo: PhotoRecord) {
        photoId = photo.photoId
        local = photo.assetIdentifier
        cloud = photo.cloudIdentifier
    }

    /// Preserve existing bindings if access is limited or if either identifier might still work.
    public static func confirmed(photo: PhotoRecord, selected: String, hasFullAccess: () -> Bool,
                                 localExists: (String) -> Bool, cloudIsMissing: (String) -> Bool) -> Self? {
        guard photo.assetIdentifier != selected, photo.assetIdentifier != nil || photo.cloudIdentifier != nil,
              hasFullAccess(), localExists(selected) else { return nil }
        if let old = photo.assetIdentifier, localExists(old) { return nil }
        if let cloud = photo.cloudIdentifier, !cloudIsMissing(cloud) { return nil }
        return hasFullAccess() ? Self(photo: photo) : nil
    }

    func matches(_ photo: PhotoRecord) -> Bool {
        self == Self(photo: photo)
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
    /// Transient comparison evidence, never written to disk or imported from a backup.
    public var missingLibraryBinding: MissingLibraryBinding?

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

extension ImportDraft {
    /// The capture day a review of this draft shows. A stored photo's record always wins, an
    /// unknown day included: a reduced copy has no EXIF, and the user may have corrected the day.
    public func shownCaptureDay(stored: PhotoRecord?) -> (day: String?, source: CaptureDateSource) {
        guard let stored else { return (captureDate, captureDateSource) }
        return (stored.captureDate, stored.captureDateSource)
    }
}

/// Where else the full-size file of a photo being imported lives, which decides whether the
/// app may keep a reduced copy in its place.
public enum FullSizeCopy: Sendable, Equatable {
    /// In the user's photo library: the photo was picked from it, or the in-app camera's save
    /// to it was confirmed. A reduced copy here loses nothing.
    case inPhotoLibrary
    /// Nowhere else: the bytes are the only full-size file (a photo taken in the app whose
    /// save to Photos was off, refused or failed, or a stored photo read back from the app).
    /// They are kept as they are.
    case onlyHere
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
              let index = primaryIndex(of: source),
              let props = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any],
              let rawWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let rawHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              rawWidth > 0, rawHeight > 0
        else { throw IngestError.notAnImage }

        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swaps = (5...8).contains(orientation)
        let mimeType = UTType(typeIdentifier)?.preferredMIMEType ?? "application/octet-stream"

        guard let thumb = thumbnail(source: source, index: index, maxPixel: thumbnailMaxPixel),
              let thumbData = jpegData(thumb, quality: 0.82)
        else { throw IngestError.notAnImage }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let day = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(exifDay)

        let width = swaps ? rawHeight : rawWidth, height = swaps ? rawWidth : rawHeight
        if reduce, max(width, height) > maxPixel,
           let image = thumbnail(source: source, index: index, maxPixel: maxPixel),
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

    /// `makeDraft` for an import whose full-size file may live only in these bytes: a reduced
    /// copy is made only when `fullSizeCopy` says the photo library keeps the full one.
    public static func makeDraft(data: Data, filename: String?, fullSizeCopy: FullSizeCopy,
                                 maxPixel: Int = storedMaxPixel) throws -> ImportDraft {
        try makeDraft(data: data, filename: filename, reduce: fullSizeCopy == .inPhotoLibrary, maxPixel: maxPixel)
    }

    /// Orientation is already applied to `image` and no metadata is written: the capture day
    /// lives in the record, and the location stays out of the app's copy.
    private static func reducedCopy(_ image: CGImage) -> (data: Data, mimeType: String)? {
        if let heic = encoded(image, type: .heic, quality: 0.8) { return (heic, "image/heic") }
        if let jpeg = encoded(image, type: .jpeg, quality: 0.85) { return (jpeg, "image/jpeg") }
        return nil
    }

    public static func downsampledImage(data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let index = primaryIndex(of: source)
        else { return nil }
        return thumbnail(source: source, index: index, maxPixel: maxPixel)
    }

    public static func downsampledImage(at url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let index = primaryIndex(of: source)
        else { return nil }
        return thumbnail(source: source, index: index, maxPixel: maxPixel)
    }

    static func primaryIndex(of source: CGImageSource) -> Int? {
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        return (0..<count).contains(index) ? index : nil
    }

    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    static func uprightImage(source: CGImageSource, index: Int, maxPixel: Int? = nil) -> CGImage? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return nil }
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let maxPixel, let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int,
           let factor = [8, 4, 2].first(where: { max(width, height) / $0 >= maxPixel }) {
            options[kCGImageSourceSubsampleFactor] = factor
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, index, options as CFDictionary) else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int32 ?? 1
        let edge = max(image.width, image.height)
        if orientation == 1, (maxPixel ?? edge) >= edge { return image }
        var upright = CIImage(cgImage: image).oriented(forExifOrientation: orientation)
        if let maxPixel, maxPixel < edge {
            let scale = CGFloat(maxPixel) / CGFloat(edge)
            upright = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true)
        }
        return imageContext.createCGImage(upright, from: upright.extent)
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

    private static func thumbnail(source: CGImageSource, index: Int, maxPixel: Int) -> CGImage? {
        guard maxPixel > 0 else { return nil }
        // ImageIO clamps nonzero items' thumbnails to item zero's dimensions, even if the
        // designated primary is much larger. Subsample the selected item itself in this case.
        if index != 0 { return uprightImage(source: source, index: index, maxPixel: maxPixel) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
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
