import Foundation
import Testing
@testable import MeowverseCore

/// A cached feature print belongs to the exact pixels it was made from. Old imports took a
/// multi-image HEIF's thumbnail from item zero; when the stored photo is repaired its photoId
/// stays the same, so a cache keyed only by photoId would keep suggesting from the wrong picture.
@Suite struct FeaturePrintInvalidationTests {
    private static let analyzer = VisionPhotoEmbedder(masking: .coverCat).analyzer

    /// Stands in for Vision: the vector records the decoded width and the byte count, so a test
    /// can tell which file a print came from, and every call is counted.
    private actor CountingEmbedder {
        private(set) var calls = 0
        let analyzer: String
        let revision: Int

        init(analyzer: String = FeaturePrintInvalidationTests.analyzer, revision: Int = VisionPhotoEmbedder.revision) {
            self.analyzer = analyzer
            self.revision = revision
        }

        func print(_ data: Data) throws -> FeaturePrint {
            calls += 1
            guard let image = PhotoIngest.downsampledImage(data: data, maxPixel: 4096) else { throw RecognitionError.undecodableImage }
            return FeaturePrint(analyzer: analyzer, revision: revision, vector: [Float(image.width), Float(data.count)])
        }
    }

    /// The cache file exactly as builds before the fix wrote it.
    private struct VersionOneFile: Codable {
        var version = 1
        var prints: [String: FeaturePrint]
    }

    private func writeVersionOne(_ prints: [String: FeaturePrint], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(VersionOneFile(prints: prints)).write(to: url)
    }

    private func refresh(_ cache: FeaturePrintCache, _ ids: [String], embedder: CountingEmbedder,
                         input: @escaping @Sendable (String) async -> URL?) async {
        await cache.refresh(ids, input: input, embed: { try await embedder.print($0) })
    }

    /// An old library: one full multi-image HEIF whose stored thumbnail and size came from item
    /// zero (320 wide), on a chair; ImageIO's primary is the 640-wide item.
    private func legacyLibrary(at root: URL, dateSource: CaptureDateSource) throws -> AppState {
        let bytes = try TestSupport.designatedPrimaryHEIF(), hash = PhotoIngest.sha256Hex(bytes)
        let photo = PhotoRecord(photoId: "pair", filename: "pair.heic", sha256: hash, mimeType: "image/heic",
                                byteSize: bytes.count, width: 320, height: 256, originalFile: "originals/\(hash).heic",
                                thumbnailFile: "thumbnails/pair.jpg",
                                captureDate: dateSource == .user ? "2020-02-29" : "2018-01-02", captureDateSource: dateSource,
                                exifCaptureDate: "2018-01-02", importedAt: Date(timeIntervalSince1970: 100),
                                favorite: false, note: "", revision: 1)
        var state = AppState.empty
        state.photos = [photo]
        state.items = [PhotoFurniture(instanceId: "chair", modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2,
                                     turn: 0, finish: .original, displayName: "Chair", sources: [.manual(photoId: photo.photoId)],
                                     tags: [], revision: 1, coverPhotoId: photo.photoId)]
        for dir in [LibraryStore.originalsDir, LibraryStore.thumbnailsDir] {
            try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
        try bytes.write(to: root.appending(path: photo.originalFile))
        try TestSupport.imageData(width: 320, height: 256).write(to: root.appending(path: photo.thumbnailFile))
        try LibraryStore.encodeState(state).write(to: root.appending(path: LibraryStore.stateFile))
        return state
    }

    /// Upgrading with a cache made from item zero: whether or not the photo was opened first, the
    /// warmup makes a new print from the repaired primary, keeps it across a relaunch, and the
    /// repair keeps the user's day and the chair's link.
    @Test(arguments: [(false, CaptureDateSource.exif), (true, .exif), (false, .user)])
    func aPrintMadeFromItemZeroIsRemadeAfterTheRepair(openedFirst: Bool, dateSource: CaptureDateSource) async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try legacyLibrary(at: root, dateSource: dateSource)
        let cacheURL = root.appending(path: "caches/prints.bin"), legacyURL = root.appending(path: "caches/prints.json")
        let itemZero = FeaturePrint(analyzer: Self.analyzer, revision: VisionPhotoEmbedder.revision, vector: [320, 1])
        try writeVersionOne(["pair": itemZero], to: legacyURL)

        let store = LibraryStore(root: root, catalog: try TestSupport.catalog())
        _ = try await store.load()
        if openedFirst { _ = await store.thumbnailURL(photoId: "pair") }
        let cache = FeaturePrintCache(fileURL: cacheURL, analyzer: Self.analyzer, legacyFileURL: legacyURL)
        let embedder = CountingEmbedder()
        await refresh(cache, ["pair"], embedder: embedder) { await store.thumbnailURL(photoId: $0) }

        let made = try #require(await cache.print(for: "pair"))
        #expect(made.vector.first == 512, "made from the repaired primary, not item zero")
        #expect(await embedder.calls == 1)
        let photo = try #require(await store.snapshot().photo(id: "pair"))
        #expect(photo.width == 640 && photo.exifCaptureDate == "2024-03-15")
        #expect(photo.captureDate == (dateSource == .user ? "2020-02-29" : "2024-03-15"))
        #expect(await store.snapshot().items == before.items)

        // Same input again, then a relaunch: the print is reused, never remade.
        await refresh(cache, ["pair"], embedder: embedder) { await store.thumbnailURL(photoId: $0) }
        let relaunched = LibraryStore(root: root, catalog: try TestSupport.catalog())
        _ = try await relaunched.load()
        let reopened = FeaturePrintCache(fileURL: cacheURL, analyzer: Self.analyzer, legacyFileURL: legacyURL)
        await refresh(reopened, ["pair"], embedder: embedder) { await relaunched.thumbnailURL(photoId: $0) }
        #expect(await reopened.print(for: "pair") == made)
        #expect(await embedder.calls == 1)
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path), "the old JSON file is gone after the first save")
    }

    /// Any change to the pixels under the same photoId, in this session or between launches,
    /// makes a new print; until it is checked an old print is not handed out.
    @Test func aChangedThumbnailUnderTheSamePhotoIdIsNotReused() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let thumbnail = root.appending(path: "thumb.jpg"), cacheURL = root.appending(path: "prints.bin")
        try TestSupport.imageData(width: 200, height: 100, seed: 1).write(to: thumbnail)
        let embedder = CountingEmbedder()
        let cache = FeaturePrintCache(fileURL: cacheURL, analyzer: Self.analyzer)
        await refresh(cache, ["p"], embedder: embedder) { _ in thumbnail }
        let first = try #require(await cache.print(for: "p"))

        try TestSupport.imageData(width: 240, height: 100, seed: 2).write(to: thumbnail, options: .atomic)
        await refresh(cache, ["p"], embedder: embedder) { _ in thumbnail }
        let second = try #require(await cache.print(for: "p"))
        #expect(second != first && second.vector.first == 240)
        #expect(await embedder.calls == 2)

        try TestSupport.imageData(width: 280, height: 100, seed: 3).write(to: thumbnail, options: .atomic)
        let reopened = FeaturePrintCache(fileURL: cacheURL, analyzer: Self.analyzer)
        #expect(await reopened.print(for: "p") == nil, "not served before its input is checked")
        await refresh(reopened, ["p"], embedder: embedder) { _ in thumbnail }
        #expect(await reopened.print(for: "p")?.vector.first == 280)
        #expect(await embedder.calls == 3)
    }

    /// Control: the same file is embedded once, however often the warmup runs or the app relaunches.
    @Test func theSameInputIsEmbeddedOnce() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let thumbnail = root.appending(path: "thumb.jpg"), cacheURL = root.appending(path: "prints.bin")
        try TestSupport.imageData(width: 200, height: 100).write(to: thumbnail)
        let embedder = CountingEmbedder()
        let cache = FeaturePrintCache(fileURL: cacheURL, analyzer: Self.analyzer)
        for _ in 0..<3 { await refresh(cache, ["p", "gone"], embedder: embedder) { $0 == "p" ? thumbnail : nil } }
        let made = try #require(await cache.print(for: "p"))
        #expect(await cache.print(for: "gone") == nil)
        let reopened = FeaturePrintCache(fileURL: cacheURL, analyzer: Self.analyzer)
        await refresh(reopened, ["p"], embedder: embedder) { _ in thumbnail }
        #expect(await reopened.print(for: "p") == made)
        #expect(await embedder.calls == 1)
    }

    /// The app's own pipeline version is separate from Vision's revision: raising it remakes a
    /// print of unchanged bytes, and a print of another Vision revision is still dropped.
    @Test func anOlderAppPipelineOrVisionRevisionIsRemade() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let thumbnail = root.appending(path: "thumb.jpg"), cacheURL = root.appending(path: "prints.bin")
        try TestSupport.imageData(width: 200, height: 100).write(to: thumbnail)
        let embedder = CountingEmbedder()
        let older = FeaturePrintCache(fileURL: cacheURL, analyzer: Self.analyzer, pipeline: FeaturePrintCache.pipeline - 1)
        await refresh(older, ["p"], embedder: embedder) { _ in thumbnail }
        let current = FeaturePrintCache(fileURL: cacheURL, analyzer: Self.analyzer)
        await refresh(current, ["p"], embedder: embedder) { _ in thumbnail }
        #expect(await embedder.calls == 2)
        await refresh(FeaturePrintCache(fileURL: cacheURL, analyzer: Self.analyzer), ["p"], embedder: embedder) { _ in thumbnail }
        #expect(await embedder.calls == 2)

        let oldVision = CountingEmbedder(revision: VisionPhotoEmbedder.revision - 1)
        let other = root.appending(path: "other.json")
        await refresh(FeaturePrintCache(fileURL: other, analyzer: Self.analyzer), ["p"], embedder: oldVision) { _ in thumbnail }
        #expect(await FeaturePrintCache(fileURL: other, analyzer: Self.analyzer).count == 0)
    }

    /// Upgrading from a build that made Vision prints to the DINOv2 embedder: the old file gives
    /// no print to compare with, every photo is printed again by the new analyzer, and the file
    /// is replaced (a later Vision cache would find nothing of its own in it either).
    @Test func aVisionCacheFromAnEarlierBuildIsReplacedByDinoPrints() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheURL = root.appending(path: "prints.bin")
        var inputs: [String: URL] = [:]
        for (index, id) in ["a", "b"].enumerated() {
            inputs[id] = root.appending(path: "\(id).jpg")
            try TestSupport.imageData(width: 200 + 40 * index, height: 100, seed: index).write(to: inputs[id]!)
        }
        let files = inputs
        let vision = CountingEmbedder()
        let old = FeaturePrintCache(fileURL: cacheURL, analyzer: Self.analyzer)
        await refresh(old, ["a", "b"], embedder: vision) { files[$0] }
        #expect(await old.count == 2)

        let dino = CountingEmbedder(analyzer: KnownAnalyzer.dinoV2, revision: 1)
        let upgraded = FeaturePrintCache(fileURL: cacheURL, analyzer: KnownAnalyzer.dinoV2, revision: 1)
        #expect(await upgraded.count == 0, "no Vision print is kept")
        #expect(await upgraded.print(for: "a") == nil)
        await refresh(upgraded, ["a", "b"], embedder: dino) { files[$0] }
        #expect(await dino.calls == 2, "every photo is printed again")
        let a = try #require(await upgraded.print(for: "a"))
        #expect(a.analyzer == KnownAnalyzer.dinoV2 && a.revision == 1)
        // A Vision print handed in by mistake is never compared with a DINOv2 one.
        let visionA = try await vision.print(Data(contentsOf: files["a"]!))
        #expect(a.distance(to: visionA) == nil)

        let relaunched = FeaturePrintCache(fileURL: cacheURL, analyzer: KnownAnalyzer.dinoV2, revision: 1)
        await refresh(relaunched, ["a", "b"], embedder: dino) { files[$0] }
        #expect(await dino.calls == 2, "the replaced file holds the DINOv2 prints")
        #expect(await FeaturePrintCache(fileURL: cacheURL, analyzer: Self.analyzer).count == 0)
    }

    /// The backfill saves as it goes: a run stopped half way without any chance to save (the app
    /// closed by the system) leaves its prints on disk, and the next launch makes only the rest.
    @Test func aHalfFinishedBackfillResumesFromTheSavedCache() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheURL = root.appending(path: "prints.bin")
        var inputs: [String: URL] = [:]
        let ids = (0..<6).map { "p\($0)" }
        for (index, id) in ids.enumerated() {
            inputs[id] = root.appending(path: "\(id).jpg")
            try TestSupport.imageData(width: 120 + 10 * index, height: 90, seed: index).write(to: inputs[id]!)
        }
        let files = inputs
        let counting = CountingEmbedder()
        // The fifth print never finishes: the run is stuck there, as when the app is closed.
        let first = FeaturePrintCache(fileURL: cacheURL, analyzer: Self.analyzer)
        let planned = Planned()
        let stuck = Task {
            await first.refresh(ids, input: { files[$0] }, embed: { data in
                if await counting.calls >= 4 { try await Task.sleep(for: .seconds(3_600)) }
                return try await counting.print(data)
            }, saveEvery: 2, planned: { await planned.set($0) })
        }
        while await counting.calls < 4 { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await planned.value == 6, "the run says how many prints it has to make")

        // A relaunch reads the file while the first run is still stuck.
        let relaunched = FeaturePrintCache(fileURL: cacheURL, analyzer: Self.analyzer)
        let resumed = CountingEmbedder()
        let made = await relaunched.refresh(ids, input: { files[$0] }, embed: { try await resumed.print($0) })
        #expect(await resumed.calls == 2, "only the prints the first run had not saved are made")
        #expect(made == 2)
        for id in ids { #expect(await relaunched.print(for: id) != nil) }
        #expect(await relaunched.readyCount(of: ids + ["unknown"]) == 6)
        stuck.cancel()
        await stuck.value
    }

    private actor Planned {
        var value: Int?
        func set(_ count: Int) { value = count }
    }

    /// The review compares a new photo by a print of its thumbnail. Saving that photo into a
    /// piece (a new one or one already there) hands the print to the cache, so the next backfill
    /// only checks it against the stored thumbnail: one print per photo across review, save,
    /// refresh and a relaunch.
    @Test func aReviewedPhotoIsEmbeddedOnceAcrossReviewSaveAndRefresh() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: try TestSupport.catalog())
        let cacheURL = root.appending(path: "caches/prints")
        let cache = FeaturePrintCache(fileURL: cacheURL, analyzer: Self.analyzer)
        let embedder = CountingEmbedder()

        let first = try TestSupport.draft(seed: 71), second = try TestSupport.draft(seed: 72)
        let firstPrint = try await embedder.print(first.thumbnailJPEG) // the review's query
        let chair = try await store.commitNewFurniture(draft: first, placement: Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2),
                                                       displayName: "椅", decision: .manual)
        let firstId = try #require(chair.sources.first?.photoId)
        await cache.adopt(firstPrint, madeFrom: first.thumbnailJPEG, for: firstId)
        #expect(await cache.print(for: firstId) == nil, "not served before refresh has checked the stored thumbnail")

        let secondPrint = try await embedder.print(second.thumbnailJPEG)
        let attached = try await store.addSource(draft: second, toInstance: chair.instanceId, decision: .manual)
        let secondId = try #require(attached.sources.map(\.photoId).first { $0 != firstId })
        await cache.adopt(secondPrint, madeFrom: second.thumbnailJPEG, for: secondId)

        await refresh(cache, [firstId, secondId], embedder: embedder) { await store.thumbnailURL(photoId: $0) }
        #expect(await cache.print(for: firstId) == firstPrint)
        #expect(await cache.print(for: secondId) == secondPrint)
        let reopened = FeaturePrintCache(fileURL: cacheURL, analyzer: Self.analyzer)
        await refresh(reopened, [firstId, secondId], embedder: embedder) { await store.thumbnailURL(photoId: $0) }
        #expect(await reopened.print(for: secondId) == secondPrint)
        #expect(await embedder.calls == 2, "one print per photo")
    }

    /// A handed-over print is only a claim about the bytes it came from: if the stored thumbnail
    /// is other bytes it is made again, a print made another way is refused, and it never
    /// replaces a print the cache already holds.
    @Test func aReviewPrintIsKeptOnlyForTheSameBytesAndTheSameAnalyzer() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let thumbnail = root.appending(path: "thumb.jpg"), cacheURL = root.appending(path: "prints")
        try TestSupport.imageData(width: 200, height: 100, seed: 1).write(to: thumbnail)
        let embedder = CountingEmbedder()
        let cache = FeaturePrintCache(fileURL: cacheURL, analyzer: Self.analyzer)

        let otherBytes = TestSupport.imageData(width: 240, height: 100, seed: 2)
        await cache.adopt(FeaturePrint(analyzer: Self.analyzer, revision: VisionPhotoEmbedder.revision, vector: [240, 1]),
                          madeFrom: otherBytes, for: "p")
        await refresh(cache, ["p"], embedder: embedder) { _ in thumbnail }
        #expect(await cache.print(for: "p")?.vector.first == 200, "remade from the stored thumbnail")
        #expect(await embedder.calls == 1)

        let stored = try Data(contentsOf: thumbnail)
        await cache.adopt(FeaturePrint(analyzer: Self.analyzer, revision: VisionPhotoEmbedder.revision, vector: [9, 9]),
                          madeFrom: stored, for: "p")
        #expect(await cache.print(for: "p")?.vector.first == 200, "an existing print is not replaced")

        await cache.adopt(FeaturePrint(analyzer: "elsewhere", revision: VisionPhotoEmbedder.revision, vector: [1, 1]),
                          madeFrom: stored, for: "q")
        await cache.adopt(FeaturePrint(analyzer: Self.analyzer, revision: VisionPhotoEmbedder.revision - 1, vector: [1, 1]),
                          madeFrom: stored, for: "r")
        #expect(await cache.count == 1, "prints made another way are refused")
    }

    /// A cache written before the fix is read without trouble, and none of its prints is used.
    @Test func aVersionOneFileIsReadButItsPrintsAreNotUsed() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheURL = root.appending(path: "prints.bin"), legacyURL = root.appending(path: "prints.json")
        let old = FeaturePrint(analyzer: Self.analyzer, revision: VisionPhotoEmbedder.revision, vector: [1, 2])
        try writeVersionOne(["a": old, "b": old], to: legacyURL)
        let cache = FeaturePrintCache(fileURL: cacheURL, analyzer: Self.analyzer, legacyFileURL: legacyURL)
        #expect(await cache.print(for: "a") == nil)
        #expect(await cache.print(for: "b") == nil)
        let embedder = CountingEmbedder()
        await refresh(cache, ["a"], embedder: embedder) { _ in nil }
        #expect(await cache.print(for: "a") == nil, "no input, no print")
        #expect(await embedder.calls == 0)
    }
}
