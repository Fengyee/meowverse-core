import Accelerate
import CoreGraphics
import Foundation
import os
import Vision

/// A photo's Vision feature print: photos that look alike get vectors that lie close together.
/// Used to suggest which piece of furniture already in the room a new photo belongs to. Kept on
/// this device only (a cache, never in a backup), and recomputed whenever it is missing.
public struct FeaturePrint: Sendable, Equatable {
    /// How the vector was made; prints are only compared with prints from the same analyzer.
    public let analyzer: String
    public let revision: Int
    public let vector: [Float]

    public init(analyzer: String, revision: Int, vector: [Float]) {
        self.analyzer = analyzer
        self.revision = revision
        self.vector = vector
    }

    public func isComparable(with other: FeaturePrint) -> Bool {
        analyzer == other.analyzer && revision == other.revision && vector.count == other.vector.count && !vector.isEmpty
    }

    /// Squared Euclidean distance, which is what Vision's `FeaturePrintObservation.distance(to:)`
    /// returns for revision 2 (checked by `ownDistanceMatchesVision`). The vectors have unit
    /// length, so it runs from 0 (same picture) to 4. nil when the two prints were made differently.
    public func distance(to other: FeaturePrint) -> Float? {
        guard isComparable(with: other) else { return nil }
        var sum: Float = 0
        vDSP_distancesq(vector, 1, other.vector, 1, &sum, vDSP_Length(vector.count))
        return sum
    }
}

extension FeaturePrint: Codable {
    private enum CodingKeys: String, CodingKey { case analyzer, revision, vector }

    /// The vector is stored as little-endian Float32 bytes (base64 in JSON), a quarter of the size of a number list.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        analyzer = try container.decode(String.self, forKey: .analyzer)
        revision = try container.decode(Int.self, forKey: .revision)
        let bytes = try container.decode(Data.self, forKey: .vector)
        guard bytes.count % 4 == 0 else {
            throw DecodingError.dataCorruptedError(forKey: .vector, in: container, debugDescription: "vector bytes")
        }
        vector = stride(from: 0, to: bytes.count, by: 4).map { offset in
            let bits = bytes[bytes.startIndex + offset ..< bytes.startIndex + offset + 4]
                .enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            return Float(bitPattern: bits)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(analyzer, forKey: .analyzer)
        try container.encode(revision, forKey: .revision)
        var bytes = Data(capacity: vector.count * 4)
        for value in vector {
            let bits = value.bitPattern
            for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: bits >> UInt32(shift))) }
        }
        try container.encode(bytes, forKey: .vector)
    }
}

public protocol PhotoEmbedding: Sendable {
    /// Stored with every print; changing how prints are made must change this.
    var analyzer: String { get }
    func featurePrint(imageData: Data) async throws -> FeaturePrint
}

/// Feature prints from Vision (`GenerateImageFeaturePrintRequest`, revision 2; no model download).
///
/// Every photo shows the same cat, so a print of the whole picture partly measures the cat.
/// `.coverCat` first finds cats (`RecognizeAnimalsRequest`) and paints over them with the
/// picture's average colour, so what is left to compare is mostly the furniture and the room.
/// Which works better on real photos is what `ios/Tools/RecognitionEval` measures.
public struct VisionPhotoEmbedder: PhotoEmbedding {
    public enum CatMasking: String, Sendable, CaseIterable {
        case none
        case coverCat
    }

    public static let revision = 2
    /// Prints are made from the stored 512 px thumbnail, so a new photo and the photos already
    /// in furniture always go through the same pixels.
    public static let maxPixel = PhotoIngest.thumbnailMaxPixel
    /// A cat's box is grown by this fraction on each side before it is painted over.
    static let coverMargin: CGFloat = 0.08

    public let masking: CatMasking
    private static let log = Logger(subsystem: "app.meowverse", category: "similarity")

    public init(masking: CatMasking = .coverCat) {
        self.masking = masking
    }

    public var analyzer: String {
        switch masking {
        case .none: "vision.featurePrint"
        case .coverCat: "vision.featurePrint.catCovered"
        }
    }

    public func featurePrint(imageData: Data) async throws -> FeaturePrint {
        let masking = masking, analyzer = analyzer
        return try await Task.detached(priority: .utility) { () async throws -> FeaturePrint in
            guard var image = PhotoIngest.downsampledImage(data: imageData, maxPixel: Self.maxPixel) else {
                throw RecognitionError.undecodableImage
            }
            if masking == .coverCat {
                let animals = try await RecognizeAnimalsRequest().perform(on: image)
                let cats = animals
                    .filter { $0.labels.contains { $0.identifier.lowercased() == "cat" } }
                    .map(\.boundingBox.cgRect)
                if !cats.isEmpty, let covered = Self.cover(cats, in: image) { image = covered }
            }
            let observation = try await GenerateImageFeaturePrintRequest().perform(on: image)
            return FeaturePrint(analyzer: analyzer, revision: Self.revision, vector: Self.floats(observation))
        }.value
    }

    static func floats(_ observation: FeaturePrintObservation) -> [Float] {
        observation.data.withUnsafeBytes { raw in
            switch observation.elementType {
            case .double: raw.bindMemory(to: Double.self).prefix(observation.elementCount).map { Float($0) }
            default: Array(raw.bindMemory(to: Float.self).prefix(observation.elementCount))
            }
        }
    }

    /// Paints `boxes` (normalized, lower-left origin, as Vision reports them) with the image's average colour.
    static func cover(_ boxes: [CGRect], in image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: full)
        context.setFillColor(averageColor(of: image, space: space))
        for box in boxes {
            // CGContext's origin is lower-left too, so the normalized box maps straight onto pixels.
            let pixels = CGRect(x: box.minX * CGFloat(width), y: box.minY * CGFloat(height),
                                width: box.width * CGFloat(width), height: box.height * CGFloat(height))
            context.fill(pixels.insetBy(dx: -pixels.width * coverMargin, dy: -pixels.height * coverMargin).intersection(full))
        }
        return context.makeImage()
    }

    private static func averageColor(of image: CGImage, space: CGColorSpace) -> CGColor {
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return CGColor(gray: 0.5, alpha: 1) }
        return CGColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
}

/// A piece of furniture a new photo looks like: the closest of its photos, how far it is, and
/// (from `SimilarFurniture.voteShares`) its share of the vote among the closest photos.
public struct FurnitureMatch: Sendable, Equatable {
    public let instanceId: String
    public let photoId: String
    public let distance: Float
    public let share: Float

    public init(instanceId: String, photoId: String, distance: Float, share: Float = 1) {
        self.instanceId = instanceId
        self.photoId = photoId
        self.distance = distance
        self.share = share
    }
}

/// One photo already in a piece of furniture, with its print.
public struct FurniturePhotoPrint: Sendable, Equatable {
    public let instanceId: String
    public let photoId: String
    public let print: FeaturePrint

    public init(instanceId: String, photoId: String, print: FeaturePrint) {
        self.instanceId = instanceId
        self.photoId = photoId
        self.print = print
    }
}

/// Which pieces a new photo is suggested for. Measured on the owner's 168 real photos in time
/// order (RECOGNITION_NOTES.md): no distance or confidence separates "a piece in the room" from
/// "not one", so the review always lists up to three and the user can answer "none of these".
/// Voting among the closest photos needs no training, so it stays fast and takes in a photo
/// the moment it is attached.
public enum SimilarFurniture {
    /// How many of the closest photos vote.
    public static let neighbours = 5
    /// Pieces after the first are listed only with at least this share of the vote.
    public static let alsoShownFrom: Float = 0.1
    public static let limit = 3

    /// Each piece among the `neighbours` closest photos, with its share of their votes (each
    /// photo weighs 1 / distance) and its closest photo; highest share first. Prints made
    /// differently from `query` are skipped.
    public static func voteShares(_ query: FeaturePrint, against references: [FurniturePhotoPrint],
                                  neighbours: Int = neighbours) -> [FurnitureMatch] {
        var nearest: [(reference: FurniturePhotoPrint, distance: Float)] = []
        nearest.reserveCapacity(neighbours + 1)
        for reference in references {
            guard let distance = query.distance(to: reference.print) else { continue }
            if nearest.count == neighbours, let last = nearest.last, !closer(distance, reference, than: last) { continue }
            let at = nearest.firstIndex { closer(distance, reference, than: $0) } ?? nearest.count
            nearest.insert((reference, distance), at: at)
            if nearest.count > neighbours { nearest.removeLast() }
        }
        var votes: [String: (weight: Float, closest: FurniturePhotoPrint, distance: Float)] = [:]
        for (reference, distance) in nearest {
            let weight = 1 / (distance + 1e-3)
            if let current = votes[reference.instanceId] {
                votes[reference.instanceId] = (current.weight + weight, current.closest, current.distance)
            } else {
                votes[reference.instanceId] = (weight, reference, distance)
            }
        }
        let total = votes.values.reduce(0) { $0 + $1.weight }
        return votes.map { id, vote in
            FurnitureMatch(instanceId: id, photoId: vote.closest.photoId, distance: vote.distance, share: vote.weight / total)
        }.sorted { $0.share != $1.share ? $0.share > $1.share : $0.instanceId < $1.instanceId }
    }

    /// The best piece always, then others with at least `alsoShownFrom` of the vote, at most
    /// `limit`. Empty only when there is nothing to compare with.
    public static func suggest(_ query: FeaturePrint, against references: [FurniturePhotoPrint],
                               alsoShownFrom: Float = alsoShownFrom, limit: Int = limit) -> [FurnitureMatch] {
        let shares = voteShares(query, against: references)
        guard let first = shares.first else { return [] }
        return [first] + shares.dropFirst().filter { $0.share >= alsoShownFrom }.prefix(limit - 1)
    }

    private static func closer(_ distance: Float, _ reference: FurniturePhotoPrint,
                               than other: (reference: FurniturePhotoPrint, distance: Float)) -> Bool {
        distance != other.distance ? distance < other.distance : reference.photoId < other.reference.photoId
    }

    /// Pieces ordered by their closest photo (nearest neighbour), at most `limit`, none farther
    /// than `maxDistance`. The evaluation tool's distance report uses it; the app votes.
    public static func rank(_ query: FeaturePrint, against references: [FurniturePhotoPrint],
                            maxDistance: Float = .infinity, limit: Int = .max) -> [FurnitureMatch] {
        var best: [String: FurnitureMatch] = [:]
        for reference in references {
            guard let distance = query.distance(to: reference.print), distance <= maxDistance else { continue }
            if let current = best[reference.instanceId], current.distance <= distance { continue }
            best[reference.instanceId] = FurnitureMatch(instanceId: reference.instanceId, photoId: reference.photoId, distance: distance)
        }
        let sorted = best.values.sorted {
            $0.distance != $1.distance ? $0.distance < $1.distance : $0.instanceId < $1.instanceId
        }
        return Array(sorted.prefix(limit))
    }
}

/// Feature prints by photoId, kept in one file. A cache: losing it only means recomputing.
public actor FeaturePrintCache {
    private struct File: Codable {
        var version = 1
        var prints: [String: FeaturePrint]
    }

    private let fileURL: URL
    private let analyzer: String
    private var prints: [String: FeaturePrint]?
    private var dirty = false

    public init(fileURL: URL, analyzer: String) {
        self.fileURL = fileURL
        self.analyzer = analyzer
    }

    private func loaded() -> [String: FeaturePrint] {
        if let prints { return prints }
        let decoded = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(File.self, from: $0) }
        // Prints made another way are dropped rather than compared.
        let kept = (decoded?.prints ?? [:]).filter { $0.value.analyzer == analyzer && $0.value.revision == VisionPhotoEmbedder.revision }
        prints = kept
        return kept
    }

    public func print(for photoId: String) -> FeaturePrint? {
        loaded()[photoId]
    }

    public func missing(from photoIds: [String]) -> [String] {
        let known = loaded()
        return photoIds.filter { known[$0] == nil }
    }

    public func store(_ print: FeaturePrint, for photoId: String) {
        guard print.analyzer == analyzer else { return }
        var current = loaded()
        current[photoId] = print
        prints = current
        dirty = true
    }

    /// Forgets every photo not in `photoIds`, so a removed photo leaves nothing behind.
    public func retain(only photoIds: Set<String>) {
        let current = loaded()
        let kept = current.filter { photoIds.contains($0.key) }
        if kept.count != current.count {
            prints = kept
            dirty = true
        }
    }

    public var count: Int { loaded().count }

    /// Writes the file if anything changed; an empty cache removes the file.
    public func save() throws {
        guard dirty else { return }
        let current = loaded()
        let fm = FileManager.default
        if current.isEmpty {
            if fm.fileExists(atPath: fileURL.path) { try fm.removeItem(at: fileURL) }
        } else {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(File(prints: current)).write(to: fileURL, options: [.atomic, .completeFileProtection])
        }
        dirty = false
    }
}
