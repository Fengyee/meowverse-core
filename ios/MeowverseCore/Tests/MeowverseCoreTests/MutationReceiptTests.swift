import Foundation
import Testing
@testable import MeowverseCore

/// Batch changes in the photo library hand back what they really committed, and 撤销 takes
/// back only that, in the library it was made in (audit 2026-11-24 A24-04, A24-05).
@Suite struct MutationReceiptTests {
    private func library() async throws -> (root: URL, store: LibraryStore, stool: PhotoFurniture, loose: [PhotoRecord]) {
        let root = TestSupport.tempDir()
        let store = LibraryStore(root: root, catalog: try TestSupport.catalog())
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 71),
                                               placement: Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2),
                                               displayName: "椅", decision: .manual)
        let stool = try await store.addFurniture(placement: Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1), displayName: "凳")
        var loose: [PhotoRecord] = []
        for seed in 72...74 { loose.append(try await store.addPhoto(draft: try TestSupport.draft(seed: seed))) }
        return (root, store, stool, loose)
    }

    /// Another change put one of the photos on the stool between the page's look and the save:
    /// the receipt names only the link this save made, and 撤销 leaves the other one.
    @Test func aLinkReceiptNamesOnlyWhatThatSaveAddedAndUndoTakesOnlyThat() async throws {
        let (root, store, stool, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = try await store.linkPhotosForUndo(photoIds: [loose[1].photoId], toInstance: stool.instanceId)
        let mine = try await store.linkPhotosForUndo(photoIds: [loose[0].photoId, loose[1].photoId], toInstance: stool.instanceId)
        #expect(mine.added.map(\.photoId) == [loose[0].photoId])
        #expect(other.added.map(\.photoId) == [loose[1].photoId])
        #expect(try await store.undoLink(mine) == 1)
        #expect(await store.snapshot().item(id: stool.instanceId)?.sources.map(\.photoId) == [loose[1].photoId])
    }

    /// A link taken off and made again since is not the one the receipt made: it stays.
    @Test func undoLeavesALinkMadeAgainSince() async throws {
        let (root, store, stool, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = try await store.linkPhotosForUndo(photoIds: [loose[0].photoId], toInstance: stool.instanceId)
        try await store.unlinkPhotos(photoIds: [loose[0].photoId], fromInstance: stool.instanceId)
        try await Task.sleep(for: .milliseconds(1100))   // links are stamped to the second
        try await store.linkPhotos(photoIds: [loose[0].photoId], toInstance: stool.instanceId)
        let before = await store.snapshot()
        #expect(try await store.undoLink(receipt) == 0)
        #expect(await store.snapshot() == before, "nothing written")
    }

    @Test func aFavoriteReceiptNamesOnlyThePhotosItChangedAndUndoKeepsLaterMarks() async throws {
        let (root, store, _, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.setFavorite(photoIds: [loose[1].photoId], true)
        let receipt = try await store.setFavoriteForUndo(photoIds: loose.map(\.photoId).prefix(2).map { $0 }, true)
        #expect(receipt.photoIds == [loose[0].photoId])
        #expect(try await store.undoFavorite(receipt) == 1)
        let after = await store.snapshot()
        #expect(after.photo(id: loose[0].photoId)?.favorite == false)
        #expect(after.photo(id: loose[1].photoId)?.favorite == true, "marked before, by another change")
    }

    /// A receipt from before a clear (or restore) is refused in the library that replaced it,
    /// and so is any change asked for by a caller that still holds the old library.
    @Test func aReceiptOrChangeFromAReplacedLibraryWritesNothing() async throws {
        let (root, store, stool, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = try await store.linkPhotosForUndo(photoIds: [loose[0].photoId], toInstance: stool.instanceId)
        let old = await store.generation
        #expect(receipt.generation == old)
        _ = try await store.clearAll()
        let cleared = await store.snapshot()
        await #expect(throws: CancellationError.self) { try await store.undoLink(receipt) }
        await #expect(throws: CancellationError.self) {
            try await LibraryStore.$expectedGeneration.withValue(old) { try await store.setCatName("Old") }
        }
        #expect(await store.snapshot() == cleared)
        // The current library's own caller is not held back.
        let now = await store.generation
        try await LibraryStore.$expectedGeneration.withValue(now) { try await store.setCatName("New") }
        #expect(await store.snapshot().catName == "New")
    }

    @Test func unlinkAndSuggestionReceiptsCarryTheLibraryTheyWereMadeIn() async throws {
        let (root, store, stool, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.linkPhotos(photoIds: [loose[0].photoId], toInstance: stool.instanceId)
        let receipt = try await store.unlinkPhotos(photoIds: [loose[0].photoId], fromInstances: nil)
        #expect(receipt.generation == (await store.generation))
    }
}

/// What an offer to file photos rests on (audit 2026-11-24 EE24-01, EE24-03, L24-01, M16).
@Suite struct SuggestionEvidenceTests {
    private func p(_ x: Float, _ y: Float) -> FeaturePrint { FeaturePrint(analyzer: "t", revision: 1, vector: [x, y]) }

    /// Two sofa photos at .20 and .30, a bed photo at .32: with the bed's print the margin
    /// (1.25 × .30 = .375) refuses; with the bed's print missing nothing may be offered either.
    @Test func noOfferWhileAFiledPhotosPrintIsMissing() {
        let links = [(instanceId: "sofa", photoId: "s1"), (instanceId: "sofa", photoId: "s2"), (instanceId: "bed", photoId: "b1")]
        let all: [String: FeaturePrint] = ["s1": p(Float(0.2).squareRoot(), 0), "s2": p(0, Float(0.3).squareRoot()),
                                           "b1": p(-Float(0.32).squareRoot(), 0)]
        let candidate = [SuggestionCandidate(photoId: "new")], prints = ["new": p(0, 0)]
        let complete = BatchSuggestions.offers(for: candidate, prints: prints, links: links, referencePrints: all, boards: [], declined: [])
        #expect(complete.isEmpty, "the bed is too close")
        var missing = all
        missing["b1"] = nil
        let partial = BatchSuggestions.offers(for: candidate, prints: prints, links: links, referencePrints: missing, boards: [], declined: [])
        #expect(partial.isEmpty, "the missing bed print could have refused it")
    }

    @Test func aBoardPhotoAlsoOnAPieceFromANewerVersionIsNotACandidate() throws {
        let catalog = try FurnitureCatalog.bundled()
        var state = AppState.empty
        let photos = ["onBoard", "alsoNewer"].map { id in
            PhotoRecord(photoId: id, filename: "\(id).jpg", sha256: id, mimeType: "image/jpeg", byteSize: 1, width: 1, height: 1,
                        originalFile: "originals/\(id).jpg", thumbnailFile: "thumbnails/\(id).jpg", captureDate: nil,
                        captureDateSource: .unknown, exifCaptureDate: nil, importedAt: Date(timeIntervalSince1970: 0),
                        favorite: false, note: "", revision: 1)
        }
        state.photos = photos
        state.items = [PhotoFurniture(instanceId: "board", modelId: "wall-photo-board", x: 3, z: 0, width: 3, depth: 1, turn: 0,
                                      wall: .left, finish: .original, displayName: "", sources: photos.map { .manual(photoId: $0.photoId) },
                                      tags: [], revision: 1)]
        let ids = BatchSuggestions.candidates(.photoBoards, in: state, catalog: catalog, linkedElsewhere: ["alsoNewer"]).map(\.photoId)
        #expect(ids == ["onBoard"])
        let unfiled = BatchSuggestions.candidates(.unfiled(["x"]), in: state, catalog: catalog, linkedElsewhere: ["x"])
        #expect(unfiled.isEmpty)
    }

    /// A print being made when the library is cleared (the cache told to keep nothing) is not
    /// written when it arrives, in memory or on disk.
    @Test func aPrintArrivingAfterTheCacheWasClearedIsDropped() async throws {
        let dir = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("prints.bin"), input = dir.appendingPathComponent("p.jpg")
        try TestSupport.imageData(seed: 3).write(to: input)
        let cache = FeaturePrintCache(fileURL: url, analyzer: "t", revision: 1)
        let gate = QAGate()
        await gate.arm()
        let late = Task {
            await cache.refresh(["p"], input: { _ in input }, embed: { _ in
                await gate.pass()
                return FeaturePrint(analyzer: "t", revision: 1, vector: [1, 0])
            })
        }
        await gate.waitUntilHeld()
        await cache.retain(only: [])
        try await cache.save()
        await gate.release()
        #expect(await late.value == 0)
        #expect(await cache.count == 0)
        #expect(await cache.print(for: "p") == nil)
        #expect(await FeaturePrintCache(fileURL: url, analyzer: "t", revision: 1).count == 0)
    }

    /// A photo kept by the pruning is still written.
    @Test func aPrintOfAKeptPhotoIsStillWritten() async throws {
        let dir = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("prints.bin"), input = dir.appendingPathComponent("p.jpg")
        try TestSupport.imageData(seed: 4).write(to: input)
        let cache = FeaturePrintCache(fileURL: url, analyzer: "t", revision: 1)
        let gate = QAGate()
        await gate.arm()
        let late = Task {
            await cache.refresh(["p"], input: { _ in input }, embed: { _ in
                await gate.pass()
                return FeaturePrint(analyzer: "t", revision: 1, vector: [1, 0])
            })
        }
        await gate.waitUntilHeld()
        await cache.retain(only: ["p"])
        await gate.release()
        #expect(await late.value == 1)
        #expect(await cache.print(for: "p") != nil)
    }
}

/// Confirming offers checks, in the store's own step, that the home is still the one they were
/// worked out on (audit 2026-11-24 EE24-02, L24-02).
@Suite struct SuggestionCommitBasisTests {
    @Test func offersWorkedOutOnAnOlderHomeFileNothing() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: try FurnitureCatalog.bundled())
        let sofa = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 81),
                                                      placement: Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2),
                                                      displayName: "沙发", decision: .manual)
        let free = try await store.addPhoto(draft: try TestSupport.draft(seed: 82))
        let other = try await store.addPhoto(draft: try TestSupport.draft(seed: 83))
        let seen = await store.snapshot().revision
        // A remote change lands after the offers were worked out (here: a reference photo leaves the sofa).
        try await store.linkPhotos(photoIds: [other.photoId], toInstance: sofa.instanceId)
        let before = await store.snapshot()
        let offer = BatchSuggestion(photoId: free.photoId, instanceId: sofa.instanceId, closestPhotoId: "x", distance: 0.1)
        let receipt = try await store.fileSuggestions([offer], printsBy: "t", basedOnRevision: seen)
        #expect(receipt.filed.isEmpty && receipt.skipped == [free.photoId])
        #expect(await store.snapshot() == before, "nothing written")
        #expect(receipt.generation == (await store.generation))
        let current = try await store.fileSuggestions([offer], printsBy: "t", basedOnRevision: before.revision)
        #expect(current.filed.map(\.photoId) == [free.photoId])
    }

    /// A refusal for an older home is told apart from offers that simply no longer held, so the
    /// page can say it did not save (owner 2026-11-24, L24-02).
    @Test func aRefusalForAnOlderHomeIsToldApartFromOffersThatNoLongerHold() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: try FurnitureCatalog.bundled())
        let sofa = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 91),
                                                      placement: Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2),
                                                      displayName: "沙发", decision: .manual)
        let free = try await store.addPhoto(draft: try TestSupport.draft(seed: 92))
        let other = try await store.addPhoto(draft: try TestSupport.draft(seed: 93))
        let seen = await store.snapshot().revision
        try await store.linkPhotos(photoIds: [other.photoId], toInstance: sofa.instanceId)
        let offer = BatchSuggestion(photoId: free.photoId, instanceId: sofa.instanceId, closestPhotoId: "x", distance: 0.1)
        let refused = try await store.fileSuggestions([offer], printsBy: "t", basedOnRevision: seen)
        #expect(refused.filed.isEmpty && refused.homeChanged)

        // On the current home, an offer that no longer holds (the photo was filed by hand) is a
        // plain skip: nothing filed, and not a refusal.
        try await store.linkPhotos(photoIds: [free.photoId], toInstance: sofa.instanceId)
        let now = await store.snapshot().revision
        let skipped = try await store.fileSuggestions([offer], printsBy: "t", basedOnRevision: now)
        #expect(skipped.filed.isEmpty && skipped.skipped == [free.photoId] && !skipped.homeChanged)
        let empty = try await store.fileSuggestions([], printsBy: "t", basedOnRevision: now)
        #expect(empty.filed.isEmpty && !empty.homeChanged)
    }
}
