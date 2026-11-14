import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import MeowverseCore

enum TestSupport {
    static func catalogData() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "semantic-furniture.catalog", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    static func catalog() throws -> FurnitureCatalog {
        try FurnitureCatalog(data: catalogData())
    }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeowverseCoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A synthetic gradient image; `seed` changes the pixels so bytes differ.
    static func cgImage(width: Int, height: Int, seed: Int = 0) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in stride(from: 0, to: height, by: 4) {
            let t = CGFloat(y) / CGFloat(max(height, 1))
            ctx.setFillColor(red: t, green: CGFloat((seed * 37) % 255) / 255, blue: 1 - t, alpha: 1)
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 4))
        }
        ctx.setFillColor(red: 1, green: 1, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: seed % max(width - 4, 1), y: 2, width: 4, height: 4))
        return ctx.makeImage()!
    }

    /// Encodes a synthetic image; optional EXIF DateTimeOriginal and orientation.
    static func imageData(width: Int = 64, height: Int = 32, seed: Int = 0, type: UTType = .jpeg,
                          dateTimeOriginal: String? = nil, orientation: Int? = nil) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let dateTimeOriginal {
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: dateTimeOriginal]
        }
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, cgImage(width: width, height: height, seed: seed), props as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return out as Data
    }

    static func draft(seed: Int = 0) throws -> ImportDraft {
        try PhotoIngest.makeDraft(data: imageData(seed: seed), filename: "synthetic-\(seed).jpg")
    }

    /// Directory listing (relative paths) of everything under `root`.
    static func listing(_ root: URL) -> [String] {
        let base = root.standardizedFileURL.path
        let e = FileManager.default.enumerator(atPath: base)
        var paths: [String] = []
        while let p = e?.nextObject() as? String { paths.append(p) }
        return paths.sorted()
    }

    static func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }
}

/// A fault injector that fails once at a chosen step, then is disarmed.
final class FaultSwitch: Sendable {
    private let armed: Mutex<StoreStep?>

    init(_ step: StoreStep?) { armed = Mutex(step) }

    func arm(_ step: StoreStep?) { armed.withLock { $0 = step } }

    var handler: @Sendable (StoreStep) throws -> Void {
        { [self] step in
            let fire = armed.withLock { current -> Bool in
                guard current == step else { return false }
                current = nil
                return true
            }
            if fire { throw InjectedFault.failed(step) }
        }
    }
}

enum InjectedFault: Error, Equatable {
    case failed(StoreStep)
}

extension PhotoCarrierSource {
    /// The link without the time it was made, for tests about what a link points at.
    var untimed: PhotoCarrierSource {
        PhotoCarrierSource(photoId: photoId, observationId: observationId, objectIndex: objectIndex, origin: origin,
                           relationToCat: relationToCat)
    }
}
