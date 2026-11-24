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

    /// A new empty folder, alone in a new parent. `LibraryStore.load()` lists the root's parent for
    /// leftover swap folders; with roots straight in the temporary directory every load listed every
    /// test folder ever left there (57,538 on the dev Mac, 2026-11-22), and the full suite sat for
    /// minutes before any test finished, then failed the timing tests.
    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeowverseCoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("folder", isDirectory: true)
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

    /// Two distinct HEIF items. The green gradient in the second item rotates to landscape.
    static func designatedPrimaryHEIF(firstDate: String? = "2018:01:02 09:00:00") throws -> Data {
        let buffer = NSMutableData()
        let writer = try #require(CGImageDestinationCreateWithData(buffer, UTType.heic.identifier as CFString, 2, nil))
        for (width, height, seed, orientation, date) in [
            (320, 256, 0, 1, firstDate), (320, 640, 6, 6, "2024:03:15 12:00:00")
        ] {
            var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
            if let date { properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: date] }
            CGImageDestinationAddImage(writer, cgImage(width: width, height: height, seed: seed), properties as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(writer))

        // ImageIO makes the first item primary. Select the second image in the HEIF primary-item box.
        var bytes = buffer as Data
        let box = try #require(bytes.range(of: Data(Array("pitm".utf8) + [0, 0, 0, 0, 0, 1])))
        let visibleItem = Data(Array("infe".utf8) + [2, 0, 0, 0])
        let first = try #require(bytes.range(of: visibleItem))
        let second = try #require(bytes.range(of: visibleItem, in: first.upperBound..<bytes.endIndex))
        bytes.replaceSubrange(box.suffix(2), with: bytes[second.upperBound..<second.upperBound + 2])
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        try #require(CGImageSourceGetCount(source) == 2)
        try #require(CGImageSourceGetPrimaryImageIndex(source) == 1)
        return bytes
    }

    static func expectUprightHEIFPrimary(_ image: CGImage?, width: Int, height: Int,
                                        sourceLocation: SourceLocation = #_sourceLocation) throws {
        let image = try #require(image, sourceLocation: sourceLocation)
        #expect(image.width == width, sourceLocation: sourceLocation)
        #expect(image.height == height, sourceLocation: sourceLocation)
        let context = try #require(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        let rgba = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(rgba[1] > 160 && rgba[5] > 160, "the green second item", sourceLocation: sourceLocation)
        #expect(rgba[2] > rgba[0] && rgba[4] > rgba[6], "blue at left and red at right after rotating", sourceLocation: sourceLocation)
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

/// A fault injector that fails at a chosen step every time until it is cleared.
final class PersistentFault: Sendable {
    private let failing: Mutex<StoreStep?>

    init(_ step: StoreStep?) { failing = Mutex(step) }

    func clear() { failing.withLock { $0 = nil } }

    var handler: @Sendable (StoreStep) throws -> Void {
        { [self] step in
            if failing.withLock({ $0 == step }) { throw InjectedFault.failed(step) }
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
