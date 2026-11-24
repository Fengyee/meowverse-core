import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import Vision
@testable import MeowverseCore

@Suite struct PhotoSimilarityTests {
    private func print(_ values: [Float], analyzer: String = "a", revision: Int = 2) -> FeaturePrint {
        FeaturePrint(analyzer: analyzer, revision: revision, vector: values)
    }

    /// The review header names the model behind an analyzer; a test stand-in is never named.
    @Test func engineNameOnlyForRealModels() {
        #expect(KnownAnalyzer.engineName(of: KnownAnalyzer.dinoV2) == "DINOv2")
        #expect(KnownAnalyzer.engineName(of: VisionPhotoEmbedder().analyzer) == "Apple Vision")
        #expect(KnownAnalyzer.engineName(of: VisionPhotoEmbedder(masking: .none).analyzer) == "Apple Vision")
        #expect(KnownAnalyzer.engineName(of: VisionFurnitureRecognizer.analyzer) == "Apple Vision")
        #expect(KnownAnalyzer.engineName(of: ColorGridEmbedder.analyzerName) == nil)
        #expect(KnownAnalyzer.engineName(of: "dinov2.other") == nil)
    }

    @Test func distanceIsSquaredEuclideanAndOnlyBetweenComparablePrints() {
        let a = print([0, 0, 0]), b = print([3, 4, 0])
        #expect(a.distance(to: b) == 25)
        #expect(a.distance(to: print([3, 4, 0], analyzer: "other")) == nil)
        #expect(a.distance(to: print([3, 4, 0], revision: 1)) == nil)
        #expect(a.distance(to: print([3, 4])) == nil)
        #expect(print([]).distance(to: print([])) == nil)
    }

    @Test func codableRoundTripKeepsEveryBit() throws {
        let original = print([0, -1.5, .pi, Float.leastNonzeroMagnitude, 1e30])
        let decoded = try JSONDecoder().decode(FeaturePrint.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func rankKeepsEachPieceByItsClosestPhotoWithinLimitAndThreshold() {
        let query = print([0, 0])
        let refs = [
            FurniturePhotoPrint(instanceId: "sofa", photoId: "p1", print: print([0.5, 0])),
            FurniturePhotoPrint(instanceId: "sofa", photoId: "p2", print: print([0.1, 0])),
            FurniturePhotoPrint(instanceId: "bed", photoId: "p3", print: print([0.3, 0])),
            FurniturePhotoPrint(instanceId: "chair", photoId: "p4", print: print([0.4, 0])),
            FurniturePhotoPrint(instanceId: "far", photoId: "p5", print: print([2, 0])),
            FurniturePhotoPrint(instanceId: "other", photoId: "p6", print: print([0, 0], analyzer: "b")),
        ]
        let ranked = SimilarFurniture.rank(query, against: refs, maxDistance: 1, limit: 2)
        #expect(ranked.map(\.instanceId) == ["sofa", "bed"])
        #expect(ranked.first?.photoId == "p2")
        #expect(SimilarFurniture.rank(query, against: refs, maxDistance: 1, limit: 5).map(\.instanceId) == ["sofa", "bed", "chair"])
        #expect(SimilarFurniture.rank(query, against: [], maxDistance: 1).isEmpty)
    }

    @Test func rankBreaksTiesByInstanceId() {
        let refs = ["b", "a"].map { FurniturePhotoPrint(instanceId: $0, photoId: $0, print: print([1, 0])) }
        #expect(SimilarFurniture.rank(print([0, 0]), against: refs, maxDistance: 2).map(\.instanceId) == ["a", "b"])
    }

    @Test func cachePersistsPrunesAndDropsPrintsMadeAnotherWay() async throws {
        let dir = TestSupport.tempDir()
        let url = dir.appendingPathComponent("prints.bin")
        let analyzer = VisionPhotoEmbedder(masking: .coverCat).analyzer
        let inputs = Dictionary(uniqueKeysWithValues: ["p1", "p2", "p3"].map { ($0, dir.appendingPathComponent("\($0).jpg")) })
        for (index, id) in ["p1", "p2", "p3"].enumerated() { try TestSupport.imageData(seed: index).write(to: inputs[id]!) }
        let made: [String: FeaturePrint] = ["p1": print([1, 2], analyzer: analyzer), "p2": print([3, 4], analyzer: analyzer),
                                            "p3": print([5, 6], analyzer: "elsewhere")] // refused
        let byInput = Dictionary(uniqueKeysWithValues: made.map { (try! Data(contentsOf: inputs[$0.key]!), $0.value) })
        let cache = FeaturePrintCache(fileURL: url, analyzer: analyzer)
        await cache.refresh(["p1", "p2", "p3"], input: { inputs[$0] }, embed: { byInput[$0]! })
        #expect(await cache.print(for: "p3") == nil)
        #expect(await cache.count == 2)

        let reopened = FeaturePrintCache(fileURL: url, analyzer: analyzer)
        await reopened.refresh(["p2"], input: { inputs[$0] }, embed: { _ in throw RecognitionError.undecodableImage })
        #expect(await reopened.print(for: "p2") == print([3, 4], analyzer: analyzer))
        await reopened.retain(only: ["p2"])
        try await reopened.save()
        #expect(await FeaturePrintCache(fileURL: url, analyzer: analyzer).count == 1)

        // A cache read with another analyzer starts empty instead of mixing prints.
        #expect(await FeaturePrintCache(fileURL: url, analyzer: "vision.featurePrint").count == 0)

        await reopened.retain(only: [])
        #expect(await reopened.print(for: "p2") == nil)
        try await reopened.save()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func corruptCacheFileIsTreatedAsEmpty() async throws {
        let url = TestSupport.tempDir().appendingPathComponent("prints.bin")
        try Data("not json".utf8).write(to: url)
        #expect(await FeaturePrintCache(fileURL: url, analyzer: "a").count == 0)
    }

    @Test func voteSharesAreAmongTheClosestPhotosAndSumToOne() {
        let refs = [
            FurniturePhotoPrint(instanceId: "sofa", photoId: "s1", print: print([0.1, 0])),
            FurniturePhotoPrint(instanceId: "sofa", photoId: "s2", print: print([0.2, 0])),
            FurniturePhotoPrint(instanceId: "bed", photoId: "b1", print: print([0.3, 0])),
            FurniturePhotoPrint(instanceId: "bed", photoId: "b2", print: print([5, 0])), // not among the 3 closest
            FurniturePhotoPrint(instanceId: "wall", photoId: "w1", print: print([0.4, 0])),
            FurniturePhotoPrint(instanceId: "other", photoId: "o1", print: print([0, 0], analyzer: "b")), // skipped
        ]
        let shares = SimilarFurniture.voteShares(print([0, 0]), against: refs, neighbours: 3)
        #expect(shares.map(\.instanceId) == ["sofa", "bed"])
        #expect(abs(shares.map(\.share).reduce(0, +) - 1) < 1e-5)
        #expect(shares[0].photoId == "s1" && abs(shares[0].distance - 0.01) < 1e-6)
        #expect(SimilarFurniture.voteShares(print([0, 0]), against: [], neighbours: 3).isEmpty)
    }

    @Test func aSharedPhotoOccupiesOneNeighbourAndSplitsItsVote() {
        let shared = ["a", "b", "c", "d", "e", "f"].map {
            FurniturePhotoPrint(instanceId: $0, photoId: "p", print: print([1]))
        }
        let independent = FurniturePhotoPrint(instanceId: "x", photoId: "q", print: print([1]))
        let refs = shared + [shared[0], independent]
        let shares = SimilarFurniture.voteShares(print([0]), against: refs, neighbours: 2)
        #expect(shares.first?.instanceId == "x" && abs(shares[0].share - 0.5) < 0.00001)
        #expect(shares.count == 7)
        #expect(shares == SimilarFurniture.voteShares(print([0]), against: refs.reversed(), neighbours: 2))
        #expect(shares.dropFirst().allSatisfy { abs($0.share - 1 / 12) < 0.00001 })
    }

    @Test func suggestRequiresAnAbsoluteMatchAndLimitsAdditionalPieces() {
        func refs(_ pairs: [(String, Float)]) -> [FurniturePhotoPrint] {
            pairs.enumerated().map { FurniturePhotoPrint(instanceId: $1.0, photoId: "\($0)", print: print([$1.1, 0])) }
        }
        // Five pieces, one photo each at increasing distance: shares fall off as 1 / distance.
        let five = refs([("a", 0.3), ("b", 0.4), ("c", 0.5), ("d", 0.6), ("e", 3)])
        let query = print([0, 0])
        #expect(SimilarFurniture.suggest(query, against: five).map(\.instanceId) == ["a", "b", "c"], "never more than three")
        #expect(SimilarFurniture.suggest(query, against: five, alsoShownFrom: 0.25).map(\.instanceId) == ["a", "b"])
        #expect(SimilarFurniture.suggest(query, against: five, alsoShownFrom: 0.99).map(\.instanceId) == ["a"], "the best close match is listed")
        #expect(SimilarFurniture.suggest(query, against: refs([("only", 2)])).isEmpty)
        #expect(SimilarFurniture.suggest(query, against: refs([("close", 0.5), ("far", 0.8)])).map(\.instanceId) == ["close"])
        #expect(SimilarFurniture.suggest(query, against: []).isEmpty)
        #expect(SimilarFurniture.neighbours == 5 && SimilarFurniture.limit == 3)
    }

    /// The review's "offered at all" cut is on the query's own scale: 0.4 for Vision prints
    /// (cosine 0.8), 0.65 for DINOv2 prints (looser than the batch rule's 0.42: the review only ranks).
    @Test func theReviewCutFollowsTheAnalyzerOfThePrint() {
        #expect(SimilarFurniture.maximumDistance(for: KnownAnalyzer.dinoV2) == 0.65)
        #expect(SimilarFurniture.maximumDistance(for: VisionPhotoEmbedder(masking: .coverCat).analyzer) == 0.4)
        #expect(SimilarFurniture.maximumDistance(for: ColorGridEmbedder().analyzer) == 0.4)
        for analyzer in [KnownAnalyzer.dinoV2, VisionPhotoEmbedder(masking: .coverCat).analyzer] {
            func at(_ squared: Float) -> [FurnitureMatch] {
                let ref = FurniturePhotoPrint(instanceId: "sofa", photoId: "s", print: print([squared.squareRoot(), 0], analyzer: analyzer))
                return SimilarFurniture.suggest(print([0, 0], analyzer: analyzer), against: [ref])
            }
            #expect(at(0.39).count == 1)
            #expect(at(0.41).count == (analyzer == KnownAnalyzer.dinoV2 ? 1 : 0), "\(analyzer)")
            #expect(at(0.64).count == (analyzer == KnownAnalyzer.dinoV2 ? 1 : 0), "\(analyzer)")
            #expect(at(0.66).isEmpty)
        }
    }

    @Test func voteIsFastForALargeLibrary() {
        var generator = SystemRandomNumberGenerator()
        func unit() -> [Float] {
            let v = (0..<768).map { _ in Float.random(in: -1...1, using: &generator) }
            let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return v.map { $0 / n }
        }
        let refs = (0..<10_000).map { FurniturePhotoPrint(instanceId: "p\($0 % 60)", photoId: "\($0)", print: print(unit())) }
        let query = print(unit())
        let start = Date()
        _ = SimilarFurniture.suggest(query, against: refs)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.25, "10,000 photos took \(elapsed) s")
    }

    /// A scene drawn twice with a small change, and a different scene.
    private func scene(sofa: (CGFloat, CGFloat, CGFloat), wall: (CGFloat, CGFloat, CGFloat), ball: Int?) -> Data {
        let width = 1200, height = 900
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: wall.0, green: wall.1, blue: wall.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: sofa.0, green: sofa.1, blue: sofa.2, alpha: 1)
        ctx.fill(CGRect(x: 180, y: 240, width: 840, height: 330))
        ctx.fill(CGRect(x: 140, y: 240, width: 120, height: 420))
        ctx.fill(CGRect(x: 940, y: 240, width: 120, height: 420))
        if let ball {
            ctx.setFillColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: 300 + ball * 40, y: 80, width: 90, height: 90))
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test(arguments: VisionPhotoEmbedder.CatMasking.allCases)
    func visionPrintsPutTheSameSceneCloserThanAnotherScene(masking: VisionPhotoEmbedder.CatMasking) async throws {
        let embedder = VisionPhotoEmbedder(masking: masking)
        let blueSofa = (CGFloat(0.35), CGFloat(0.45), CGFloat(0.65)), cream = (CGFloat(0.93), CGFloat(0.89), CGFloat(0.80))
        let first = try await embedder.featurePrint(imageData: scene(sofa: blueSofa, wall: cream, ball: nil))
        let again = try await embedder.featurePrint(imageData: scene(sofa: blueSofa, wall: cream, ball: 3))
        let other = try await embedder.featurePrint(imageData: scene(sofa: (0.2, 0.15, 0.1), wall: (0.3, 0.6, 0.4), ball: nil))
        #expect(first.analyzer == embedder.analyzer && first.vector.count > 100)
        let near = try #require(first.distance(to: again)), far = try #require(first.distance(to: other))
        #expect(near < far)
        let ranked = SimilarFurniture.rank(again, against: [
            FurniturePhotoPrint(instanceId: "blue-sofa", photoId: "p1", print: first),
            FurniturePhotoPrint(instanceId: "brown-sofa", photoId: "p2", print: other),
        ], maxDistance: .infinity)
        #expect(ranked.first?.instanceId == "blue-sofa")
    }

    /// Our own distance agrees with Vision's, so stored vectors compare the way Vision would.
    @Test func ownDistanceMatchesVision() async throws {
        func image(_ seed: Int) -> CGImage { TestSupport.cgImage(width: 400, height: 300, seed: seed) }
        let a = try await GenerateImageFeaturePrintRequest().perform(on: image(1))
        let b = try await GenerateImageFeaturePrintRequest().perform(on: image(90))
        let ours = try #require(print(VisionPhotoEmbedder.floats(a)).distance(to: print(VisionPhotoEmbedder.floats(b))))
        let theirs = try a.distance(to: b)
        #expect(abs(Double(ours) - theirs) < 1e-4, "ours \(ours) vision \(theirs)")
    }

    @Test func coverPaintsOnlyTheBoxAndItsMargin() throws {
        let image = TestSupport.cgImage(width: 100, height: 100, seed: 4)
        let covered = try #require(VisionPhotoEmbedder.cover([CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)], in: image))
        #expect(covered.width == 100 && covered.height == 100)
        #expect(covered.dataProvider?.data as Data? != image.dataProvider?.data as Data?)
    }
}

/// The print cache file: a small header (magic, format, pipeline, analyzer, revision, dimension)
/// and then each photo id, its input's SHA-256 and the raw Float32 vector.
@Suite struct FeaturePrintFileTests {
    static let analyzer = "vision.featurePrint.catCovered"
    static let revision = VisionPhotoEmbedder.revision

    private func print(_ values: [Float], analyzer: String = analyzer, revision: Int = revision) -> FeaturePrint {
        FeaturePrint(analyzer: analyzer, revision: revision, vector: values)
    }

    /// A cache holding `prints`, each adopted as made from its own small input file in `dir`.
    private func filledCache(_ prints: [String: FeaturePrint], in dir: URL, file: URL,
                             legacy: URL? = nil) async throws -> [String: URL] {
        var inputs: [String: URL] = [:]
        let cache = FeaturePrintCache(fileURL: file, analyzer: Self.analyzer, legacyFileURL: legacy)
        for (index, (photoId, print)) in prints.sorted(by: { $0.key < $1.key }).enumerated() {
            let url = dir.appending(path: "in-\(index).bin")
            try Data("input \(photoId)".utf8).write(to: url)
            inputs[photoId] = url
            await cache.adopt(print, madeFrom: try Data(contentsOf: url), for: photoId)
        }
        try await cache.save()
        return inputs
    }

    private func served(_ ids: [String], from file: URL, inputs: [String: URL], analyzer: String = analyzer,
                        revision: Int = revision, legacy: URL? = nil) async -> [String: FeaturePrint] {
        let cache = FeaturePrintCache(fileURL: file, analyzer: analyzer, revision: revision, legacyFileURL: legacy)
        await cache.refresh(ids, input: { inputs[$0] }, embed: { _ in throw RecognitionError.undecodableImage })
        var out: [String: FeaturePrint] = [:]
        for id in ids { out[id] = await cache.print(for: id) }
        return out
    }

    @Test func everyBitRoundTripsAndTheHeaderSaysHowPrintsWereMade() async throws {
        let dir = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "prints.bin")
        let prints = ["p1": print([0, -0.0, .pi, Float.leastNonzeroMagnitude]), "照片-2": print([1e30, -1, .greatestFiniteMagnitude, 0.5])]
        let inputs = try await filledCache(prints, in: dir, file: file)

        let bytes = try Data(contentsOf: file)
        #expect(bytes.prefix(4) == Data("MVFP".utf8))
        let header = 4 + 2 + 2 + 4 + 4 + 4 + 2 + Self.analyzer.utf8.count
        let body = prints.keys.map { 2 + $0.utf8.count + 32 + 4 * 4 }.reduce(0, +)
        #expect(bytes.count == header + body, "header, then id + SHA-256 + raw Float32 per photo")

        let back = await served(Array(prints.keys), from: file, inputs: inputs)
        #expect(back.count == 2)
        for (id, original) in prints {
            #expect(back[id]?.vector.map(\.bitPattern) == original.vector.map(\.bitPattern), "\(id)")
        }
        // Prints from another analyzer or revision are never handed out, and the file is not read as theirs.
        #expect(await served(Array(prints.keys), from: file, inputs: inputs, analyzer: "vision.featurePrint").isEmpty)
        #expect(await served(Array(prints.keys), from: file, inputs: inputs, revision: Self.revision + 1).isEmpty)
        #expect(await FeaturePrintCache(fileURL: file, analyzer: "test.colorGrid", revision: 1).count == 0)
    }

    @Test func prunedAndClearedAsBefore() async throws {
        let dir = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "prints.bin")
        let inputs = try await filledCache(["a": print([1, 2]), "b": print([3, 4]), "c": print([5, 6])], in: dir, file: file)
        let cache = FeaturePrintCache(fileURL: file, analyzer: Self.analyzer)
        await cache.retain(only: ["b"])
        try await cache.save()
        #expect(await served(["a", "b", "c"], from: file, inputs: inputs).keys.sorted() == ["b"])
        await cache.retain(only: [])
        try await cache.save()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// Every way a file can be cut short or damaged reads as an empty cache, never a crash.
    @Test func aTruncatedOrDamagedFileIsAnEmptyCache() async throws {
        let dir = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "prints.bin")
        _ = try await filledCache(["p1": print([1, 2, 3]), "p2": print([4, 5, 6])], in: dir, file: file)
        let good = try Data(contentsOf: file)
        #expect(FeaturePrintFile.decode(good, analyzer: Self.analyzer, revision: Self.revision)?.count == 2, "control")

        for length in 0..<good.count {
            #expect(FeaturePrintFile.decode(good.prefix(length), analyzer: Self.analyzer, revision: Self.revision) == nil,
                    "cut at \(length)")
        }
        func patched(_ offset: Int, _ bytes: [UInt8]) -> Data {
            var copy = good
            copy.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
            return copy
        }
        let damaged: [(String, Data)] = [
            ("magic", patched(0, [0x4A])),
            ("format", patched(4, [0x63, 0])),
            ("dimension", patched(12, [0xFF, 0xFF, 0xFF, 0x7F])),
            ("huge count", patched(16, [0xFF, 0xFF, 0xFF, 0xFF])),
            ("analyzer length", patched(20, [0xFF, 0xFF])),
            ("one byte more", good + Data([0])),
            ("bad UTF-8 id", patched(22 + Self.analyzer.utf8.count + 2, [0xFF])),
            // The second row's id "p2" becomes "p1": one photo with two prints is not a cache to trust.
            ("same id twice", patched(22 + Self.analyzer.utf8.count + (2 + 2 + 32 + 3 * 4) + 2 + 1, Array("1".utf8))),
        ]
        for (name, bytes) in damaged {
            #expect(FeaturePrintFile.decode(bytes, analyzer: Self.analyzer, revision: Self.revision) == nil, "\(name)")
        }
        var noise = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let junk = Data((0..<Int.random(in: 0...200, using: &noise)).map { _ in UInt8.random(in: 0...255, using: &noise) })
            #expect(FeaturePrintFile.decode(Data("MVFP".utf8) + junk, analyzer: Self.analyzer, revision: Self.revision) == nil)
        }
        // Through the cache: a cut file is empty, and the next save replaces it.
        try good.prefix(good.count - 1).write(to: file)
        let cache = FeaturePrintCache(fileURL: file, analyzer: Self.analyzer)
        #expect(await cache.count == 0)
        try await cache.save()
        #expect(!FileManager.default.fileExists(atPath: file.path), "a damaged file does not linger")
    }

    /// An old JSON cache is read once, written as the binary file and removed. Its entries keep
    /// their input fingerprints, so nothing is remade; an unreadable one is simply dropped.
    @Test func aJSONCacheIsMigratedOnceThenRemoved() async throws {
        let dir = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "prints.bin"), legacy = dir.appending(path: "prints.json")
        let input = dir.appending(path: "thumb.bin")
        try Data("thumbnail".utf8).write(to: input)
        let made = print([0.25, -2])
        let entry = FeaturePrintCache.Entry(print: made, pipeline: FeaturePrintCache.pipeline,
                                            input: PhotoIngest.sha256Hex(try Data(contentsOf: input)))
        try FeaturePrintCache.legacyJSON(["p": entry, "other": .init(print: print([1, 1], analyzer: "elsewhere"),
                                                                  pipeline: FeaturePrintCache.pipeline, input: nil)]).write(to: legacy)

        let cache = FeaturePrintCache(fileURL: file, analyzer: Self.analyzer, legacyFileURL: legacy)
        await cache.refresh(["p"], input: { _ in input }, embed: { _ in throw RecognitionError.undecodableImage })
        #expect(await cache.print(for: "p") == made, "migrated, not remade")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(await served(["p"], from: file, inputs: ["p": input], legacy: legacy)["p"] == made)

        // A binary file wins over a JSON file left behind (a crash between write and remove).
        try Data("not json".utf8).write(to: legacy)
        #expect(await served(["p"], from: file, inputs: ["p": input], legacy: legacy)["p"] == made)
        // Clearing removes both, even when there is nothing left to write.
        try Data("not json".utf8).write(to: legacy)
        let clearing = FeaturePrintCache(fileURL: file, analyzer: Self.analyzer, legacyFileURL: legacy)
        await clearing.retain(only: [])
        try await clearing.save()
        #expect(!FileManager.default.fileExists(atPath: file.path) && !FileManager.default.fileExists(atPath: legacy.path))

        // An unreadable JSON file is dropped and removed.
        try Data("{\"version\": 2, \"entries\": 7}".utf8).write(to: legacy)
        let broken = FeaturePrintCache(fileURL: file, analyzer: Self.analyzer, legacyFileURL: legacy)
        #expect(await broken.count == 0)
        try await broken.save()
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    /// 10,000 photos of 768 floats, the size the speed notes worried about. Prints the sizes and
    /// load times of the binary file and of the old JSON file it replaces.
    @Test func tenThousandPrintsLoadQuicklyAndTakeLessSpace() async throws {
        let dir = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "prints.bin"), legacy = dir.appending(path: "prints.json")
        var generator = SystemRandomNumberGenerator()
        var entries: [String: FeaturePrintCache.Entry] = [:]
        for index in 0..<10_000 {
            let vector = (0..<768).map { _ in Float.random(in: -1...1, using: &generator) }
            entries[UUID().uuidString] = .init(print: print(vector), pipeline: FeaturePrintCache.pipeline,
                                               input: PhotoIngest.sha256Hex(Data("\(index)".utf8)))
        }
        let writer = FeaturePrintCache(fileURL: file, analyzer: Self.analyzer)
        await writer.replaceAll(entries)
        let saveStart = Date()
        try await writer.save()
        let saveTime = Date().timeIntervalSince(saveStart)

        let loadStart = Date()
        let count = await FeaturePrintCache(fileURL: file, analyzer: Self.analyzer).count
        let loadTime = Date().timeIntervalSince(loadStart)
        let binarySize = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
        #expect(count == 10_000)
        #expect(binarySize == 4 + 2 + 2 + 4 + 4 + 4 + 2 + Self.analyzer.utf8.count + 10_000 * (2 + 36 + 32 + 768 * 4))
        #expect(loadTime < 1, "binary load took \(loadTime) s")

        let json = try FeaturePrintCache.legacyJSON(entries)
        try json.write(to: legacy)
        let jsonStart = Date()
        let jsonCount = await FeaturePrintCache(fileURL: dir.appending(path: "absent.bin"), analyzer: Self.analyzer,
                                                legacyFileURL: legacy).count
        let jsonTime = Date().timeIntervalSince(jsonStart)
        #expect(jsonCount == 10_000)
        #expect(Double(binarySize) < Double(json.count) * 0.8)
        Swift.print("feature print cache, 10,000 x 768: binary \(binarySize) bytes, save \(saveTime) s, load \(loadTime) s;"
                    + " JSON \(json.count) bytes, load \(jsonTime) s")
    }
}

/// How long one print takes on this device, for the bug report: durations only, newest window.
@Suite struct FeaturePrintTimingTests {
    private func defaults() -> UserDefaults {
        let name = "timing-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func medianAndCountCoverOnlyTheNewestWindow() {
        var timings = FeaturePrintTimings()
        #expect(timings.median == nil && timings.count == 0)
        for ms in [30.0, 10, 20] { timings.record(milliseconds: ms, analyzer: "a") }
        #expect(timings.median == 20 && timings.count == 3)
        timings.record(milliseconds: 40, analyzer: "a")
        #expect(timings.median == 25, "even count: mean of the two middle values")
        for _ in 0..<FeaturePrintTimings.window { timings.record(milliseconds: 500, analyzer: "a") }
        #expect(timings.count == FeaturePrintTimings.window)
        #expect(timings.median == 500, "older prints left the window")
        // Another analyzer starts again rather than mixing two kinds of print.
        timings.record(milliseconds: 7, analyzer: "b")
        #expect(timings.count == 1 && timings.median == 7 && timings.analyzer == "b")
        timings.record(milliseconds: -1, analyzer: "b")
        timings.record(milliseconds: .nan, analyzer: "b")
        #expect(timings.count == 1, "impossible durations are ignored")
    }

    @Test func theLogKeepsTimingsAcrossInstancesAndStoresNothingButNumbers() async throws {
        let defaults = defaults()
        let log = FeaturePrintTimingLog(defaults: defaults)
        let embedder = ColorGridEmbedder()
        let data = TestSupport.imageData(width: 300, height: 200, seed: 5)
        let made = try await log.timed(embedder, imageData: data)
        #expect(made == (try await embedder.featurePrint(imageData: data)))
        log.record(milliseconds: 120, analyzer: embedder.analyzer)
        let again = FeaturePrintTimingLog(defaults: defaults).timings
        #expect(again.count == 2 && again.analyzer == embedder.analyzer)
        // The stored value holds the analyzer name and durations, nothing that names a photo.
        let stored = try #require(defaults.dictionary(forKey: FeaturePrintTimingLog.defaultsKey))
        #expect(Set(stored.keys) == ["analyzer", "ms"])
        #expect((stored["ms"] as? [Double])?.count == 2)

        // A failed print is not timed.
        await #expect(throws: RecognitionError.self) { try await log.timed(embedder, imageData: Data("nope".utf8)) }
        #expect(log.timings.count == 2)
        log.reset()
        #expect(FeaturePrintTimingLog(defaults: defaults).timings.count == 0)
    }

    @Test func aDamagedStoredValueReadsAsNoTimings() {
        let defaults = defaults()
        defaults.set(["analyzer": 3, "ms": "x"], forKey: FeaturePrintTimingLog.defaultsKey)
        #expect(FeaturePrintTimingLog(defaults: defaults).timings == FeaturePrintTimings())
        defaults.set(["analyzer": "a", "ms": Array(repeating: 1.0, count: 500)], forKey: FeaturePrintTimingLog.defaultsKey)
        #expect(FeaturePrintTimingLog(defaults: defaults).timings.count == FeaturePrintTimings.window)
    }
}

/// The stand-in embedder UI tests use on the simulator, where Vision's networks do not run.
@Suite struct ColorGridEmbedderTests {
    @Test func samePictureIsAtZeroAndAnotherIsNot() async throws {
        let embedder = ColorGridEmbedder()
        let a = try await embedder.featurePrint(imageData: TestSupport.imageData(width: 1200, height: 900, seed: 3))
        let again = try await embedder.featurePrint(imageData: TestSupport.imageData(width: 1200, height: 900, seed: 3))
        let other = try await embedder.featurePrint(imageData: TestSupport.imageData(width: 1200, height: 900, seed: 77))
        #expect(a.analyzer == "test.colorGrid" && a.vector.count == 8 * 8 * 3)
        #expect(a.distance(to: again) == 0)
        let far = try #require(a.distance(to: other))
        #expect(far > 0)
        let norm = a.vector.reduce(0) { $0 + $1 * $1 }
        #expect(abs(norm - 1) < 1e-4)
    }

    @Test func undecodableDataThrows() async {
        await #expect(throws: RecognitionError.self) {
            try await ColorGridEmbedder().featurePrint(imageData: Data("nope".utf8))
        }
    }
}
