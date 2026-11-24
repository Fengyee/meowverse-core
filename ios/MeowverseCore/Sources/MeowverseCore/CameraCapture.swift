import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a photo taken with the in-app camera into the bytes that are imported (and, if the
/// user wants, saved to the photo library).
///
/// The camera hands over decoded pixels and a separate metadata dictionary. Writing them back
/// together keeps the EXIF as the camera wrote it, so the capture day still comes from
/// `DateTimeOriginal` (`UIImage.jpegData` would drop it and the day would become unknown).
/// Nothing is added: no date when the camera gave none, and no location. The system camera
/// gives none, and any `{GPS}` that is present is removed.
public enum CameraCapture {
    /// What became of saving a photo just taken in the app to the system photo library. Only a
    /// save the system confirmed leaves a full-size copy outside the app.
    public enum LibrarySave: Sendable, Equatable {
        /// "拍的照片也存进“照片”" is off.
        case notWanted
        /// Add access was refused or is restricted.
        case refused
        /// Photos did not take the new photo.
        case failed
        /// Photos confirmed the new asset; the identifier is nil when the system gave none.
        case saved(assetIdentifier: String?)

        public var fullSizeCopy: FullSizeCopy {
            if case .saved = self { return .inPhotoLibrary }
            return .onlyHere
        }

        public var assetIdentifier: String? {
            if case .saved(let identifier) = self { return identifier }
            return nil
        }

        /// The user wanted the photo in Photos and it is not there.
        public var saveFailed: Bool { self == .refused || self == .failed }
    }

    public struct Encoded: Sendable, Equatable {
        public let data: Data
        public let mimeType: String
    }

    public enum EncodeError: Error, Equatable {
        case badOrientation
        case encodingFailed
    }

    /// `orientation` is the EXIF orientation (1...8) of `image`'s pixels, read from the
    /// picture itself; it replaces whatever orientation the metadata carries. `metadata` is the
    /// camera's `mediaMetadata`. HEIC where it can be written, otherwise JPEG.
    public static func encode(_ image: CGImage, orientation: Int, metadata: [String: Any]?,
                              type: UTType = .heic) throws -> Encoded {
        guard (1...8).contains(orientation) else { throw EncodeError.badOrientation }
        let properties = self.properties(metadata ?? [:], orientation: orientation)
        for candidate in type == .heic ? [UTType.heic, .jpeg] : [type] {
            if let data = encoded(image, type: candidate, properties: properties) {
                return Encoded(data: data, mimeType: candidate.preferredMIMEType ?? "image/jpeg")
            }
        }
        throw EncodeError.encodingFailed
    }

    /// The camera's metadata as written: location removed, orientation set from the pixels in
    /// both places readers look for it.
    static func properties(_ metadata: [String: Any], orientation: Int) -> [CFString: Any] {
        var properties: [CFString: Any] = [:]
        for (key, value) in metadata { properties[key as CFString] = value }
        properties[kCGImagePropertyGPSDictionary] = nil
        // Read-only facts about the source pixels; the destination writes its own.
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth] {
            properties[key] = nil
        }
        properties[kCGImagePropertyOrientation] = orientation
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = orientation
        properties[kCGImagePropertyTIFFDictionary] = tiff
        properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        return properties
    }

    private static func encoded(_ image: CGImage, type: UTType, properties: [CFString: Any]) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return output as Data
    }
}
