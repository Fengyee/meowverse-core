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

    /// `raw` scaled to unit length: the scale `distance` and every threshold assume (Vision's
    /// prints already are; a model's raw output is not). nil when a value is not finite or the
    /// vector is all zeros, so a broken prediction is never stored or compared.
    public static func unitVector(_ raw: [Float]) -> [Float]? {
        guard !raw.isEmpty, raw.allSatisfy(\.isFinite) else { return nil }
        var squares: Float = 0
        vDSP_svesq(raw, 1, &squares, vDSP_Length(raw.count))
        let length = squares.squareRoot()
        guard length.isFinite, length > 0 else { return nil }
        return raw.map { $0 / length }
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
    /// The `FeaturePrint.revision` its prints carry; a cache keeps only prints of this revision.
    var revision: Int { get }
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

    public var revision: Int { Self.revision }

    public var analyzer: String {
        switch masking {
        case .none: "vision.featurePrint"
        case .coverCat: "vision.featurePrint.catCovered"
        }
    }

    public func featurePrint(imageData: Data) async throws -> FeaturePrint {
        try Task.checkCancellation()
        guard var image = PhotoIngest.downsampledImage(data: imageData, maxPixel: Self.maxPixel) else {
            throw RecognitionError.undecodableImage
        }
        try Task.checkCancellation()
        if masking == .coverCat {
            let animals = try await RecognizeAnimalsRequest().perform(on: image)
            let cats = animals
                .filter { $0.labels.contains { $0.identifier.lowercased() == "cat" } }
                .map(\.boundingBox.cgRect)
            if !cats.isEmpty, let covered = Self.cover(cats, in: image) { image = covered }
        }
        try Task.checkCancellation()
        let observation = try await GenerateImageFeaturePrintRequest().perform(on: image)
        return FeaturePrint(analyzer: analyzer, revision: Self.revision, vector: Self.floats(observation))
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

/// How long the most recent feature prints took on this device, for the bug report. Durations
/// and the analyzer's name only: nothing that says which photo was printed.
public struct FeaturePrintTimings: Sendable, Equatable {
    /// How many of the most recent prints count.
    public static let window = 20
    /// Milliseconds, oldest first, at most `window`.
    public private(set) var recent: [Double]
    public private(set) var analyzer: String?

    public init(recent: [Double] = [], analyzer: String? = nil) {
        self.recent = Array(recent.filter { $0.isFinite && $0 >= 0 }.suffix(Self.window))
        self.analyzer = self.recent.isEmpty ? nil : analyzer
    }

    public var count: Int { recent.count }

    public var median: Double? {
        guard !recent.isEmpty else { return nil }
        let sorted = recent.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// A print of another analyzer starts the window again: two kinds of print are not one median.
    public mutating func record(milliseconds: Double, analyzer: String) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        if analyzer != self.analyzer { recent = [] }
        self.analyzer = analyzer
        recent.append(milliseconds)
        if recent.count > Self.window { recent.removeFirst(recent.count - Self.window) }
    }
}

/// `FeaturePrintTimings` kept in UserDefaults, so a report sent after a relaunch still has them.
public final class FeaturePrintTimingLog: @unchecked Sendable {
    public static let defaultsKey = "MeowverseFeaturePrintTimings"
    public static let shared = FeaturePrintTimingLog(defaults: .standard)

    private let defaults: UserDefaults
    private let lock = OSAllocatedUnfairLock()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var timings: FeaturePrintTimings {
        lock.withLock { read() }
    }

    public func record(milliseconds: Double, analyzer: String) {
        lock.withLock {
            var timings = read()
            timings.record(milliseconds: milliseconds, analyzer: analyzer)
            defaults.set(["analyzer": timings.analyzer ?? "", "ms": timings.recent], forKey: Self.defaultsKey)
        }
    }

    public func reset() {
        lock.withLock { defaults.removeObject(forKey: Self.defaultsKey) }
    }

    /// Makes one print with `embedder` and records how long it took; a print that fails is not timed.
    public func timed(_ embedder: any PhotoEmbedding, imageData: Data) async throws -> FeaturePrint {
        let clock = ContinuousClock(), start = clock.now
        let print = try await embedder.featurePrint(imageData: imageData)
        let elapsed = start.duration(to: clock.now).components
        record(milliseconds: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15, analyzer: print.analyzer)
        return print
    }

    private func read() -> FeaturePrintTimings {
        guard let stored = defaults.dictionary(forKey: Self.defaultsKey),
              let analyzer = stored["analyzer"] as? String, let ms = stored["ms"] as? [Double] else { return FeaturePrintTimings() }
        return FeaturePrintTimings(recent: ms, analyzer: analyzer)
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

/// Analyzer names Core needs to know without the embedders that make them.
public enum KnownAnalyzer {
    /// DINOv2 ViT-B/14-reg, int8, mean of the patch tokens: `DinoPhotoEmbedder.analyzerName` in
    /// the app, which checks the two agree.
    public static let dinoV2 = "dinov2.vitb14reg.int8.meanpatch"

    /// The model behind `analyzer`, as the interface names it: "DINOv2" or "Apple Vision"
    /// (feature prints and the category classifier alike). nil for anything else, e.g. the UI
    /// tests' colour grid, so a stand-in is never shown as a real model.
    public static func engineName(of analyzer: String) -> String? {
        if analyzer == dinoV2 { return "DINOv2" }
        if analyzer.hasPrefix("vision.") { return "Apple Vision" }
        return nil
    }
}

/// Vote over nearby photos, then show only furniture with a sufficiently similar example.
public enum SimilarFurniture {
    /// How many of the closest photos vote.
    public static let neighbours = 5
    /// Pieces after the first are listed only with at least this share of the vote.
    public static let alsoShownFrom: Float = 0.1
    /// Squared distance on unit vectors: 0.4 corresponds to cosine similarity of 0.8. Chosen on
    /// Vision's prints; DINOv2 prints use `dinoMaximumDistance`.
    public static let maximumDistance: Float = 0.4
    /// The review only ranks pieces for the user to pick from, so its cut is looser than the batch
    /// rule's (`BatchSuggestionSettings.maximumDistance`, 0.42, which files on one confirmation).
    /// Measured on a real library on the phone (2026-11-18, 37 photos, 7 pieces): the right piece
    /// was the nearest at 0.24 to 0.63, unrelated photos started near 0.8; with 0.42 only 4 of 19
    /// unfiled photos were offered anything.
    public static let dinoMaximumDistance: Float = 0.65
    public static let limit = 3

    /// The "offered at all" cut on the scale of prints made by `analyzer`.
    public static func maximumDistance(for analyzer: String) -> Float {
        analyzer == KnownAnalyzer.dinoV2 ? dinoMaximumDistance : maximumDistance
    }

    /// Each piece among the `neighbours` closest photos, with its share of their votes (each
    /// photo splits its inverse-distance weight equally among its pieces) and its closest photo; highest share first. Prints made
    /// differently from `query` are skipped.
    public static func voteShares(_ query: FeaturePrint, against references: [FurniturePhotoPrint],
                                  neighbours: Int = neighbours) -> [FurnitureMatch] {
        guard neighbours > 0 else { return [] }
        var nearest: [(photoId: String, distance: Float)] = []
        var seen = Set<String>()
        for reference in references {
            guard !seen.contains(reference.photoId),
                  let distance = query.distance(to: reference.print), distance.isFinite else { continue }
            seen.insert(reference.photoId)
            let candidate = (photoId: reference.photoId, distance: distance)
            func closer(than other: (photoId: String, distance: Float)) -> Bool {
                (distance, reference.photoId) < (other.distance, other.photoId)
            }
            if nearest.count == neighbours, let last = nearest.last, !closer(than: last) { continue }
            let index = nearest.firstIndex(where: closer) ?? nearest.count
            nearest.insert(candidate, at: index)
            if nearest.count > neighbours { nearest.removeLast() }
        }
        let voters = Set(nearest.map(\.photoId))
        var owners: [String: Set<String>] = [:]
        for reference in references where voters.contains(reference.photoId) && query.isComparable(with: reference.print) {
            owners[reference.photoId, default: []].insert(reference.instanceId)
        }
        var votes: [String: (weight: Float, photoId: String, distance: Float)] = [:]
        var total: Float = 0
        for (photoId, distance) in nearest {
            guard let pieces = owners[photoId] else { continue }
            let weight = 1 / (distance + 1e-3)
            total += weight
            for piece in pieces {
                votes[piece, default: (0, photoId, distance)].weight += weight / Float(pieces.count)
            }
        }
        return votes.map { id, vote in
            FurnitureMatch(instanceId: id, photoId: vote.photoId, distance: vote.distance, share: vote.weight / total)
        }.sorted { $0.share != $1.share ? $0.share > $1.share : $0.instanceId < $1.instanceId }
    }

    /// A relative vote alone can be unanimous even if all reference photos are unrelated.
    public static func suggest(_ query: FeaturePrint, against references: [FurniturePhotoPrint],
                               alsoShownFrom: Float = alsoShownFrom, limit: Int = limit) -> [FurnitureMatch] {
        guard limit > 0 else { return [] }
        let cut = maximumDistance(for: query.analyzer)
        let shares = voteShares(query, against: references).filter { $0.distance <= cut }
        guard let first = shares.first else { return [] }
        return [first] + shares.dropFirst().filter { $0.share >= alsoShownFrom }.prefix(limit - 1)
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

/// What one comparison of a reviewed photo with the photos in furniture came to. "Nothing looks
/// like it" may be said only of a complete one.
public enum SimilarityOutcome: Sendable, Equatable {
    /// No piece has a photo that votes.
    case nothingToCompare
    /// Not one distance could be measured.
    case failed
    /// `complete` is false when some of the expected photos could not be compared.
    case compared(complete: Bool)

    /// `expected` is every photo that should have been compared; `prints` those that had a print.
    public init(query: FeaturePrint?, against prints: [FurniturePhotoPrint], expected: Set<String>) {
        guard !expected.isEmpty else {
            self = .nothingToCompare
            return
        }
        guard let query else {
            self = .failed
            return
        }
        let compared = Set(prints.filter { query.distance(to: $0.print)?.isFinite == true }.map(\.photoId))
        self = compared.isEmpty ? .failed : .compared(complete: expected.isSubset(of: compared))
    }
}

/// Feature prints by photoId, kept in one file. A cache: losing it only means recomputing.
///
/// A photoId does not name fixed pixels: repairing an old multi-image HEIF replaces its thumbnail
/// and keeps the id. So each print also records what it was made from: the SHA-256 of the input
/// file and the app's `pipeline` version. A print is handed out only after `refresh` has seen the
/// same input this session (or made the print itself); anything else is remade.
public actor FeaturePrintCache {
    /// Version of the app's own path from a stored photo to the pixels Vision is given (which
    /// item of a HEIF, thumbnail size and orientation). Unrelated to Vision's request revision,
    /// which `FeaturePrint.revision` records. Raise it when that path changes.
    /// 1: files before this field existed, made from item zero of a multi-image HEIF.
    /// 2: the ImageIO primary item, with each input fingerprinted.
    public static let pipeline = 2

    struct Entry: Codable, Equatable {
        var print: FeaturePrint
        var pipeline: Int
        /// SHA-256 of the file the print was made from; nil for prints from a version 1 file.
        var input: String?
    }

    /// The JSON file builds before the binary one wrote (about 40 MB at 10,000 photos). Version 1
    /// stored `prints` alone; version 2 stores `entries`. Read once to migrate, then removed.
    private struct LegacyFile: Codable {
        var version: Int
        var prints: [String: FeaturePrint]?
        var entries: [String: Entry]?
    }

    /// A version 2 JSON file, as older builds wrote it; for tests of the migration.
    static func legacyJSON(_ entries: [String: Entry]) throws -> Data {
        try JSONEncoder().encode(LegacyFile(version: 2, entries: entries))
    }

    /// When a file was last found to match its entry, so an unchanged file is not hashed again.
    private struct Stamp: Equatable {
        let size: Int?
        let modified: Date?
        let fileNumber: UInt64?

        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            size = (attributes[.size] as? NSNumber)?.intValue
            modified = attributes[.modificationDate] as? Date
            fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        }
    }

    /// A print that could not be made. It stands while the file is as it was; one that failed
    /// only because the file could not be read, until it can be.
    private struct Failure {
        let path: String
        let stamp: Stamp?
        let unreadable: Bool

        func stands(for url: URL, stamp now: Stamp?) -> Bool {
            guard path == url.path, stamp == now else { return false }
            // Unlocking the phone makes a file readable without changing its stamp.
            return !unreadable || (try? Data(contentsOf: url)) == nil
        }
    }

    private enum Attempt {
        case made(path: String, stamp: Stamp?, data: Data, print: FeaturePrint)
        case failed(Failure)
        /// Cancelled before it was through: not a failure.
        case stopped
    }

    private let fileURL: URL
    private let legacyFileURL: URL?
    private let analyzer: String
    private let revision: Int
    private let pipeline: Int
    private var entries: [String: Entry]?
    /// This session only: photos whose entry matched their current file, with that file's path and stamp.
    private var checked: [String: (path: String, stamp: Stamp?)] = [:]
    private var dirty = false
    /// This session only: prints that could not be made, with the file they failed on.
    private var failed: [String: Failure] = [:]
    /// Photos a running `refresh` is making a print of, and the refreshes waiting for them.
    private var making = Set<String>()
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// `fileURL` is the binary file (`FeaturePrintFile`). `legacyFileURL` is where older builds
    /// kept the JSON file: read once when there is no binary file yet, removed at the next save.
    /// Only prints of `analyzer` and `revision` (the embedder's) are kept or handed out.
    public init(fileURL: URL, analyzer: String, revision: Int = VisionPhotoEmbedder.revision,
                pipeline: Int = FeaturePrintCache.pipeline, legacyFileURL: URL? = nil) {
        self.fileURL = fileURL
        self.legacyFileURL = legacyFileURL
        self.analyzer = analyzer
        self.revision = revision
        self.pipeline = pipeline
    }

    private func isOurs(_ print: FeaturePrint) -> Bool {
        print.analyzer == analyzer && print.revision == revision && !print.vector.isEmpty
    }

    private func loaded() -> [String: Entry] {
        if let entries { return entries }
        let fm = FileManager.default
        var all: [String: Entry] = [:]
        if let data = try? Data(contentsOf: fileURL) {
            // Damaged, cut short or made another way: an empty cache, and the next save replaces the file.
            if let decoded = FeaturePrintFile.decode(data, analyzer: analyzer, revision: revision) { all = decoded } else { dirty = true }
        } else if let legacyFileURL, let data = try? Data(contentsOf: legacyFileURL) {
            // Migrated once: every entry keeps its input fingerprint, so `refresh` still checks each one.
            let decoded = try? JSONDecoder().decode(LegacyFile.self, from: data)
            all = decoded?.entries ?? [:]
            for (photoId, print) in decoded?.prints ?? [:] where all[photoId] == nil {
                all[photoId] = Entry(print: print, pipeline: 1, input: nil)
            }
        }
        if let legacyFileURL, fm.fileExists(atPath: legacyFileURL.path) { dirty = true }
        // Prints made another way are dropped rather than compared.
        let kept = all.filter { isOurs($0.value.print) }
        entries = kept
        return kept
    }

    /// Replaces every entry; for tests that need a large cache without making prints.
    func replaceAll(_ replacement: [String: Entry]) {
        entries = replacement.filter { isOurs($0.value.print) }
        dirty = true
    }

    /// The print of `photoId`, once `refresh` has matched it to the photo's current input.
    public func print(for photoId: String) -> FeaturePrint? {
        guard checked[photoId] != nil else { return nil }
        return loaded()[photoId]?.print
    }

    /// Forgets every photo not in `photoIds`, so a removed photo leaves nothing behind.
    public func retain(only photoIds: Set<String>) {
        let current = loaded()
        let kept = current.filter { photoIds.contains($0.key) }
        checked = checked.filter { photoIds.contains($0.key) }
        failed = failed.filter { photoIds.contains($0.key) }
        if kept.count != current.count {
            entries = kept
            dirty = true
        }
    }

    public var count: Int { loaded().count }

    /// The next `refresh` attempts every print given up this session again (a new import).
    public func retryFailed() {
        failed = [:]
    }

    private func forget(_ photoId: String) {
        var current = loaded()
        guard current.removeValue(forKey: photoId) != nil else { return }
        entries = current
        dirty = true
    }

    /// Keeps a print already made from `input` (the review's print of a photo's thumbnail) as
    /// `photoId`'s entry, so the next `refresh` checks it instead of making it again. It is
    /// served only after `refresh` finds the stored file to be these same bytes; otherwise it is
    /// remade there. Never replaces an entry the cache already holds, and refuses a print made
    /// another way. Written with the next save.
    public func adopt(_ print: FeaturePrint, madeFrom input: Data, for photoId: String) {
        guard isOurs(print), !input.isEmpty else { return }
        var current = loaded()
        guard current[photoId] == nil else { return }
        current[photoId] = Entry(print: print, pipeline: pipeline, input: PhotoIngest.sha256Hex(input))
        entries = current
        dirty = true
    }

    /// Checks each photo's print against the file `input` gives for it now, and makes the
    /// missing or outdated ones with `embed`. Photos with a usable print are confirmed before any
    /// new print is made, so a review waiting on this sees them first. A photo without an input
    /// keeps no usable print.
    ///
    /// At most `concurrency` prints are made at once. `planned` hears once how many prints have
    /// to be made (after the usable ones are confirmed); `progress` hears (photos settled, total)
    /// after each photo is confirmed, made or given up on. With `saveEvery` above 0 the file is
    /// written after every that many new prints, so a run the system ends without warning
    /// resumes from there. A cancelled refresh stops starting new prints and saves what it has.
    /// Returns how many prints it made.
    ///
    /// A print that failed is given up, and no longer planned, until the file changes or can be
    /// read again, `retryFailed` is called or the app starts again: a caller that refreshes
    /// after every refresh that planned something must come to an end.
    @discardableResult
    public func refresh(_ photoIds: [String], input: @Sendable (String) async -> URL?,
                        embed: @escaping @Sendable (Data) async throws -> FeaturePrint,
                        concurrency: Int = 1, saveEvery: Int = 0,
                        planned: (@Sendable (Int) async -> Void)? = nil,
                        progress: (@Sendable (Int, Int) async -> Void)? = nil) async -> Int {
        let total = photoIds.count
        var settled = 0, madeCount = 0, unsaved = 0
        var toMake: [(photoId: String, url: URL)] = []
        for photoId in photoIds {
            guard !Task.isCancelled else { break }
            guard let url = await input(photoId) else {
                checked[photoId] = nil
                settled += 1
                await progress?(settled, total)
                continue
            }
            // Stamp before reading: a file replaced while it is read gets a new stamp and is checked again.
            let stamp = Stamp(url)
            if let seen = checked[photoId], seen.path == url.path, seen.stamp != nil, seen.stamp == stamp,
               loaded()[photoId] != nil {
                settled += 1
                await progress?(settled, total)
                continue
            }
            checked[photoId] = nil
            if let failure = failed[photoId] {
                if failure.stands(for: url, stamp: stamp) {
                    settled += 1
                    await progress?(settled, total)
                    continue
                }
                failed[photoId] = nil
            }
            if let entry = loaded()[photoId] {
                let expected = entry.pipeline == pipeline ? entry.input : nil
                // An unreadable file says nothing about the entry; it is tried again next time.
                guard let expected, let data = try? Data(contentsOf: url) else {
                    if expected == nil { forget(photoId) }
                    toMake.append((photoId, url))
                    continue
                }
                if PhotoIngest.sha256Hex(data) == expected {
                    checked[photoId] = (url.path, stamp)
                    settled += 1
                    await progress?(settled, total)
                    continue
                }
                forget(photoId)
            }
            toMake.append((photoId, url))
        }
        await planned?(toMake.count)
        // A photo another refresh is making right now is waited for, not made twice.
        let madeElsewhere = await withTaskGroup(of: (photoId: String, attempt: Attempt).self,
                                                returning: [String].self) { group in
            var next = 0
            var madeElsewhere: [String] = []
            func start() {
                while !Task.isCancelled, next < toMake.count {
                    let (photoId, url) = toMake[next]
                    next += 1
                    guard making.insert(photoId).inserted else {
                        madeElsewhere.append(photoId)
                        continue
                    }
                    group.addTask {
                        guard !Task.isCancelled else { return (photoId, .stopped) }
                        let path = url.path, stamp = Stamp(url)
                        guard let data = try? Data(contentsOf: url) else {
                            return (photoId, .failed(Failure(path: path, stamp: stamp, unreadable: true)))
                        }
                        guard let print = try? await embed(data) else {
                            // A print that was stopped has not failed.
                            return (photoId, Task.isCancelled ? .stopped : .failed(Failure(path: path, stamp: stamp, unreadable: false)))
                        }
                        return (photoId, .made(path: path, stamp: stamp, data: data, print: print))
                    }
                    return
                }
            }
            for _ in 0..<max(1, concurrency) { start() }
            for await (photoId, attempt) in group {
                switch attempt {
                case let .made(path, stamp, data, print) where isOurs(print):
                    var current = loaded()
                    current[photoId] = Entry(print: print, pipeline: pipeline, input: PhotoIngest.sha256Hex(data))
                    entries = current
                    checked[photoId] = (path, stamp)
                    dirty = true
                    madeCount += 1
                    unsaved += 1
                    if saveEvery > 0, unsaved >= saveEvery {
                        try? save()
                        unsaved = 0
                    }
                case let .made(path, stamp, _, _):
                    failed[photoId] = Failure(path: path, stamp: stamp, unreadable: false)
                case let .failed(failure):
                    failed[photoId] = failure
                case .stopped:
                    break
                }
                finishedMaking(photoId)
                settled += 1
                await progress?(settled, total)
                start()
            }
            return madeElsewhere
        }
        for photoId in madeElsewhere {
            if making.contains(photoId) {
                await withCheckedContinuation { waiting[photoId, default: []].append($0) }
            }
            settled += 1
            await progress?(settled, total)
        }
        try? save()
        return madeCount
    }

    /// How many of `photoIds` have a print `refresh` has matched to their current input this
    /// session: the ones a comparison can use now. For the bug report.
    public func readyCount(of photoIds: [String]) -> Int {
        let current = loaded()
        return Set(photoIds).filter { checked[$0] != nil && current[$0] != nil }.count
    }

    private func finishedMaking(_ photoId: String) {
        making.remove(photoId)
        for waiter in waiting.removeValue(forKey: photoId) ?? [] { waiter.resume() }
    }

    /// Writes the file if anything changed; an empty cache removes the file.
    public func save() throws {
        let current = loaded()
        guard dirty else { return }
        let fm = FileManager.default
        if let data = FeaturePrintFile.encode(current, analyzer: analyzer, revision: revision, pipeline: pipeline) {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            options.insert(.completeFileProtection)
            #endif
            try data.write(to: fileURL, options: options)
        } else if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
        // Only once the binary file holds everything (or nothing is left) does the old file go.
        if let legacyFileURL, fm.fileExists(atPath: legacyFileURL.path) { try fm.removeItem(at: legacyFileURL) }
        dirty = false
    }
}

/// The print cache on disk. Little-endian throughout:
///
///     "MVFP"  format u16  pipeline u16  revision i32  dimension u32  count u32
///     analyzer length u16, analyzer UTF-8
///     count × (photoId length u16, photoId UTF-8, input SHA-256 32 bytes, dimension × Float32)
///
/// One analyzer, revision, pipeline and dimension per file, so a print is never compared with
/// one made another way. Anything that does not add up to exactly the file's length is rejected.
enum FeaturePrintFile {
    static let magic: [UInt8] = Array("MVFP".utf8)
    static let format: UInt16 = 1
    static let maxDimension = 1 << 16
    static let maxTextBytes = 1_024

    /// nil when there is nothing to write: no entry with this pipeline and a fingerprinted input.
    static func encode(_ entries: [String: FeaturePrintCache.Entry], analyzer: String, revision: Int, pipeline: Int) -> Data? {
        let writable = entries.compactMap { id, entry -> (id: String, input: [UInt8], vector: [Float])? in
            guard entry.pipeline == pipeline, let hex = entry.input, let input = bytes(hex: hex), input.count == 32,
                  id.utf8.count <= maxTextBytes else { return nil }
            return (id, input, entry.print.vector)
        }
        // All of one file share a dimension; in practice every print has the same one.
        let counts = Dictionary(writable.map { ($0.vector.count, 1) }, uniquingKeysWith: +)
        guard let dimension = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key,
              dimension > 0, dimension <= maxDimension, analyzer.utf8.count <= maxTextBytes,
              let revision = Int32(exactly: revision), let pipeline = UInt16(exactly: pipeline) else { return nil }
        let rows = writable.filter { $0.vector.count == dimension }.sorted { $0.id < $1.id }
        var data = Data()
        data.reserveCapacity(22 + analyzer.utf8.count + rows.count * (2 + 36 + 32 + dimension * 4))
        data.append(contentsOf: magic)
        append(format, to: &data)
        append(pipeline, to: &data)
        append(UInt32(bitPattern: revision), to: &data)
        append(UInt32(dimension), to: &data)
        append(UInt32(rows.count), to: &data)
        append(UInt16(analyzer.utf8.count), to: &data)
        data.append(contentsOf: Array(analyzer.utf8))
        for row in rows {
            append(UInt16(row.id.utf8.count), to: &data)
            data.append(contentsOf: Array(row.id.utf8))
            data.append(contentsOf: row.input)
            #if _endian(little)
            row.vector.withUnsafeBytes { data.append(contentsOf: $0) }
            #else
            for value in row.vector { append(value.bitPattern, to: &data) }
            #endif
        }
        return data
    }

    /// The entries, or nil if the file is damaged, cut short or made by another analyzer or revision.
    static func decode(_ data: Data, analyzer: String, revision: Int) -> [String: FeaturePrintCache.Entry]? {
        data.withUnsafeBytes { raw -> [String: FeaturePrintCache.Entry]? in
            var reader = Reader(raw: raw)
            guard reader.bytes(4).map(Array.init) == magic, reader.u16() == format,
                  let pipeline = reader.u16(), let storedRevision = reader.u32().map({ Int(Int32(bitPattern: $0)) }),
                  let dimension = reader.u32().map(Int.init), dimension <= maxDimension,
                  let count = reader.u32().map(Int.init),
                  let name = reader.text(), name == analyzer, storedRevision == revision else { return nil }
            let rowSize = 2 + 32 + dimension * 4
            guard count == 0 || dimension > 0, count <= reader.remaining / rowSize else { return nil }
            var entries: [String: FeaturePrintCache.Entry] = [:]
            entries.reserveCapacity(count)
            for _ in 0..<count {
                guard let id = reader.text(), entries[id] == nil, let input = reader.bytes(32),
                      let floats = reader.bytes(dimension * 4) else { return nil }
                let vector = [Float](unsafeUninitializedCapacity: dimension) { buffer, initialized in
                    #if _endian(little)
                    UnsafeMutableRawBufferPointer(buffer).copyMemory(from: floats)
                    #else
                    for index in 0..<dimension { buffer[index] = Float(bitPattern: UInt32(littleEndian: floats.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))) }
                    #endif
                    initialized = dimension
                }
                entries[id] = .init(print: FeaturePrint(analyzer: analyzer, revision: revision, vector: vector),
                                    pipeline: Int(pipeline), input: hex(input))
            }
            return reader.remaining == 0 ? entries : nil
        }
    }

    private struct Reader {
        let raw: UnsafeRawBufferPointer
        var offset = 0

        var remaining: Int { raw.count - offset }

        mutating func bytes(_ count: Int) -> UnsafeRawBufferPointer? {
            guard count >= 0, count <= remaining else { return nil }
            defer { offset += count }
            return UnsafeRawBufferPointer(rebasing: raw[offset ..< offset + count])
        }

        mutating func u16() -> UInt16? { bytes(2).map { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) } }
        mutating func u32() -> UInt32? { bytes(4).map { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } }

        /// A u16 length and that many bytes of valid UTF-8.
        mutating func text() -> String? {
            guard let length = u16().map(Int.init), length <= FeaturePrintFile.maxTextBytes,
                  let bytes = bytes(length) else { return nil }
            return String(validating: bytes, as: UTF8.self)
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func hex(_ bytes: UnsafeRawBufferPointer) -> String {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func bytes(hex: String) -> [UInt8]? {
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        func value(_ digit: UInt8) -> UInt8? {
            switch digit {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
            default: nil
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = value(digits[index]), let low = value(digits[index + 1]) else { return nil }
            out.append(high << 4 | low)
        }
        return out
    }
}
