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
        let url = TestSupport.tempDir().appendingPathComponent("prints.json")
        let analyzer = VisionPhotoEmbedder(masking: .coverCat).analyzer
        let cache = FeaturePrintCache(fileURL: url, analyzer: analyzer)
        await cache.store(print([1, 2], analyzer: analyzer), for: "p1")
        await cache.store(print([3, 4], analyzer: analyzer), for: "p2")
        await cache.store(print([5, 6], analyzer: "elsewhere"), for: "p3") // refused
        try await cache.save()
        #expect(await cache.missing(from: ["p1", "p2", "p3"]) == ["p3"])

        let reopened = FeaturePrintCache(fileURL: url, analyzer: analyzer)
        #expect(await reopened.print(for: "p2") == print([3, 4], analyzer: analyzer))
        await reopened.retain(only: ["p2"])
        try await reopened.save()
        #expect(await FeaturePrintCache(fileURL: url, analyzer: analyzer).count == 1)

        // A cache read with another analyzer starts empty instead of mixing prints.
        #expect(await FeaturePrintCache(fileURL: url, analyzer: "vision.featurePrint").count == 0)

        await reopened.retain(only: [])
        try await reopened.save()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func corruptCacheFileIsTreatedAsEmpty() async throws {
        let url = TestSupport.tempDir().appendingPathComponent("prints.json")
        try Data("not json".utf8).write(to: url)
        #expect(await FeaturePrintCache(fileURL: url, analyzer: "a").count == 0)
    }

    // The app's rule: the 5 closest photos vote (weight 1 / distance); the best piece is always
    // listed, others only with at least `alsoShownFrom` of the vote, at most three.

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

    @Test func suggestAlwaysListsTheBestAndOthersOnlyAboveTheFloor() {
        func refs(_ pairs: [(String, Float)]) -> [FurniturePhotoPrint] {
            pairs.enumerated().map { FurniturePhotoPrint(instanceId: $1.0, photoId: "\($0)", print: print([$1.1, 0])) }
        }
        // Five pieces, one photo each at increasing distance: shares fall off as 1 / distance.
        let five = refs([("a", 0.3), ("b", 0.4), ("c", 0.5), ("d", 0.6), ("e", 3)])
        let query = print([0, 0])
        #expect(SimilarFurniture.suggest(query, against: five).map(\.instanceId) == ["a", "b", "c"], "never more than three")
        #expect(SimilarFurniture.suggest(query, against: five, alsoShownFrom: 0.25).map(\.instanceId) == ["a", "b"])
        #expect(SimilarFurniture.suggest(query, against: five, alsoShownFrom: 0.99).map(\.instanceId) == ["a"], "the best is always listed")
        #expect(SimilarFurniture.suggest(query, against: refs([("only", 2)])).map(\.instanceId) == ["only"])
        #expect(SimilarFurniture.suggest(query, against: []).isEmpty)
        #expect(SimilarFurniture.neighbours == 5 && SimilarFurniture.limit == 3)
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
