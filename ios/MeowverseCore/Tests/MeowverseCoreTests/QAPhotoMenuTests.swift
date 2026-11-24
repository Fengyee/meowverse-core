import Foundation
import Testing
@testable import MeowverseCore

/// QA (round 10, photo menu): take-off and undo across cover, order, storage and sync.
@Suite struct QAPhotoMenuTests {
    let clock = SyncTestClock()

    private func recognition() -> RecognitionResult {
        RecognitionResult(analyzer: "test", analyzerRevision: 1,
                          objects: [ObservedObject(kind: .chair, label: "chair", confidence: 0.9)], catLikely: true)
    }

    private func library() async throws -> (URL, LibraryStore, PhotoFurniture, [PhotoRecord]) {
        let root = TestSupport.tempDir()
        let store = LibraryStore(root: root, catalog: try TestSupport.catalog())
        let chair = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 361),
                                                       placement: Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2),
                                                       displayName: "椅", decision: SourceDecision(recognition: recognition(), acceptedObjectIndex: 0))
        var loose: [PhotoRecord] = []
        for seed in 362...364 { loose.append(try await store.addPhoto(draft: try TestSupport.draft(seed: seed))) }
        try await store.linkPhotos(photoIds: loose.map(\.photoId), toInstance: chair.instanceId)
        return (root, store, chair, loose)
    }

    private func piece(_ store: LibraryStore, _ id: String) async -> PhotoFurniture? {
        await store.snapshot().allFurniture.first { $0.instanceId == id }
    }

    /// Taking the cover off: the piece falls back to its first photo; undo gives the cover back.
    @Test func coverPhotoTakenOffAndBack() async throws {
        let (root, store, chair, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.setCover(instanceId: chair.instanceId, photoId: loose[1].photoId)
        let before = try #require(await piece(store, chair.instanceId))
        let receipt = try await store.unlinkPhotos(photoIds: [loose[1].photoId], fromInstances: nil)
        let off = try #require(await piece(store, chair.instanceId))
        #expect(off.cover == off.sources.first?.photoId, "falls back to the first photo")
        #expect(try await store.undoUnlink(receipt) == 1)
        let back = try #require(await piece(store, chair.instanceId))
        #expect(back.sources == before.sources && back.cover == loose[1].photoId)
    }

    /// Every photo off (the first one is model-origin), the piece is truthfully without photos;
    /// undo restores all four exactly.
    @Test func lastPhotosOffAndBack() async throws {
        let (root, store, chair, _) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try #require(await piece(store, chair.instanceId))
        let receipt = try await store.unlinkPhotos(photoIds: before.sources.map(\.photoId), fromInstances: [chair.instanceId])
        let empty = try #require(await piece(store, chair.instanceId))
        #expect(empty.sources.isEmpty && empty.cover == nil)
        #expect(try await store.undoUnlink(receipt) == 4)
        #expect(await piece(store, chair.instanceId)?.sources == before.sources)
    }

    /// The piece goes into the storage box (and the album is reordered) meanwhile: undo still
    /// finds it and keeps every link; nothing duplicates.
    @Test func undoAfterStowAndReorder() async throws {
        let (root, store, chair, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = [loose[0].photoId, loose[1].photoId]
        let receipt = try await store.unlinkPhotos(photoIds: ids, fromInstances: nil)
        _ = try await store.stowFurniture(instanceId: chair.instanceId)
        let rest = try #require(await piece(store, chair.instanceId)).sources.map(\.photoId)
        _ = try await store.reorderPhotos(instanceId: chair.instanceId, order: rest.reversed())
        #expect(try await store.undoUnlink(receipt) == 2)
        let after = try #require(await store.snapshot().storage.first { $0.instanceId == chair.instanceId })
        #expect(Set(after.sources.map(\.photoId)).count == after.sources.count, "no duplicates")
        #expect(after.sources.count == 4)
        #expect(after.sources.allSatisfy { s in s.origin == (s.photoId == chair.sources[0].photoId ? .model : .user) })
    }

    /// Duplicated ids in the request and the same receipt undone twice change nothing extra.
    @Test func duplicatesAndDoubleUndo() async throws {
        let (root, store, chair, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try #require(await piece(store, chair.instanceId))
        let receipt = try await store.unlinkPhotos(photoIds: [loose[0].photoId, loose[0].photoId], fromInstances: [chair.instanceId, chair.instanceId])
        #expect(receipt.removed.count == 1)
        #expect(try await store.undoUnlink(receipt) == 1)
        #expect(try await store.undoUnlink(receipt) == 0)
        #expect(await piece(store, chair.instanceId)?.sources == before.sources)
    }

    /// Through sync: take a model-origin photo off on A, settle, undo on A, settle. B ends with
    /// the same link (origin, observation, relation, place) and the same cover.
    @Test func takeOffAndUndoTravelThroughSyncWithProvenance() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice("A", cloud: cloud, clock: clock), b = try await QADevice("B", cloud: cloud, clock: clock)
        try await QACheck.settle([a, b])
        let chair = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: 371), placement: SyncCheck.chair,
                                                         displayName: "Chair", decision: SourceDecision(recognition: recognition(), acceptedObjectIndex: 0))
        let extra = try await a.store.addPhoto(draft: try TestSupport.draft(seed: 372))
        try await a.store.linkPhotos(photoIds: [extra.photoId], toInstance: chair.instanceId)
        let model = try #require(chair.sources.first)
        _ = try await a.store.setCover(instanceId: chair.instanceId, photoId: extra.photoId)
        try await QACheck.settle([a, b])
        let original = try #require(await b.state().items.first { $0.instanceId == chair.instanceId })
        #expect(original.sources.first?.origin == .model)

        let receipt = try await a.store.unlinkPhotos(photoIds: [model.photoId], fromInstances: nil)
        try await QACheck.settle([a, b])
        #expect(await b.state().items.first?.sources.map(\.photoId) == [extra.photoId])
        #expect(try await a.store.undoUnlink(receipt) == 1)
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let now = try #require(await device.state().items.first { $0.instanceId == chair.instanceId })
            #expect(now.sources == original.sources, "\(device.name): same links, order, provenance")
            #expect(now.cover == extra.photoId, "\(device.name): cover kept")
        }
        await QACheck.expectConverged([a, b])
    }

    /// B deletes the photo while A (not yet synced) takes it back with 撤销. Whatever wins, no
    /// device may keep a link to a photo it does not have, and both converge. The deletion never
    /// saw the undo, so the photo comes back (as it does for a plain link), and with it what the
    /// link stands on: its observation, so the recognised link keeps its provenance instead of
    /// the photo coming back silently unlinked.
    /// Run with the device names both ways round, so a tie broken by device id cannot decide it.
    @Test(arguments: [false, true]) func undoAgainstAnUnseenDeletion(swap: Bool) async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice(swap ? "B" : "A", cloud: cloud, clock: clock), b = try await QADevice(swap ? "A" : "B", cloud: cloud, clock: clock)
        try await QACheck.settle([a, b])
        let chair = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: 381), placement: SyncCheck.chair,
                                                         displayName: "Chair", decision: SourceDecision(recognition: recognition(), acceptedObjectIndex: 0))
        let original = try #require(chair.sources.first)
        let photo = original.photoId
        try await QACheck.settle([a, b])
        let receipt = try await a.store.unlinkPhotos(photoIds: [photo], fromInstances: nil)
        try await QACheck.settle([a, b])
        try await b.store.deletePhoto(photoId: photo)
        #expect(try await a.store.undoUnlink(receipt) == 1)
        let mid = await a.state()
        print("QA A after undo, before sync: links=\(mid.allFurniture.flatMap(\.sources).map { "\($0.origin) obs=\($0.observationId != nil)" }) observations=\(mid.observations.count)")
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            print("QA \(device.name) observations=\(state.observations.count) problems=\(await device.filesAreWhole())")
            let photos = Set(state.photos.map(\.photoId))
            for piece in state.allFurniture {
                #expect(piece.sources.allSatisfy { photos.contains($0.photoId) }, "\(device.name): dangling link")
            }
            print("QA \(device.name): photos=\(state.photos.count) links=\(state.allFurniture.flatMap(\.sources).count)")
            #expect(state.photos.map(\.photoId) == [photo], "\(device.name): the photo comes back")
            #expect(state.observations.map(\.observationId) == [original.observationId].compactMap { $0 },
                    "\(device.name): its observation comes back with it")
            let piece = state.allFurniture.first { $0.instanceId == chair.instanceId }
            #expect(piece?.sources == [original], "\(device.name): the recognised link, exactly as it was")
        }
        await QACheck.expectConverged([a, b])
    }
}

extension QAPhotoMenuTests {
    /// The photo, its link and what the link stands on all came back: a hand-made link names no
    /// observation, so there must be none, and the link is the user's own.
    private func expectWhole(_ state: AppState, photo: String, on instanceId: String, _ name: String) {
        #expect(state.photos.map(\.photoId) == [photo], "\(name): the photo comes back")
        let links = state.allFurniture.first { $0.instanceId == instanceId }?.sources ?? []
        #expect(links.map(\.photoId) == [photo], "\(name): and its link")
        #expect(links.allSatisfy { $0.origin == .user && $0.observationId == nil }, "\(name): still a hand-made link")
        #expect(state.observations.isEmpty, "\(name): no observation appears from nowhere")
    }

    /// A filed suggestion is taken off on A; B, not yet aware, takes the suggestion back (link
    /// and observation go). Once A has synced, its 撤销 has nothing whole to put back: the photo
    /// is still here but the observation is gone. Nothing comes back, nothing dangles, and the
    /// library still reads (a link naming a missing observation would make state.json invalid).
    @Test(arguments: [false, true]) func undoAfterTheObservationWasTakenBackElsewhere(swap: Bool) async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice(swap ? "B" : "A", cloud: cloud, clock: clock), b = try await QADevice(swap ? "A" : "B", cloud: cloud, clock: clock)
        try await QACheck.settle([a, b])
        let sofa = try await a.store.addFurniture(placement: SyncCheck.chair, displayName: "Sofa")
        let photo = try await a.store.addPhoto(draft: try TestSupport.draft(seed: 393)).photoId
        let filing = try await a.store.fileSuggestions([BatchSuggestion(photoId: photo, instanceId: sofa.instanceId, closestPhotoId: "x", distance: 0.1)],
                                                       printsBy: "t")
        try #require(filing.filed.count == 1)
        try await QACheck.settle([a, b])
        let receipt = try await a.store.unlinkPhotos(photoIds: [photo], fromInstances: nil)
        #expect(try await b.store.undoSuggestions(filing) == 1)
        try await QACheck.settle([a, b])
        #expect(await a.state().observations.isEmpty, "the observation is gone everywhere")
        #expect(try await a.store.undoUnlink(receipt) == 0, "half a link is not put back")
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(state.photos.map(\.photoId) == [photo], "\(device.name): the photo stays")
            #expect(state.allFurniture.flatMap(\.sources).isEmpty, "\(device.name): no link, no dangling link")
            #expect(state.observations.isEmpty, "\(device.name): the observation stays gone")
        }
        let reopened = LibraryStore(root: a.root, catalog: try TestSupport.catalog())
        #expect(try await reopened.load() == (await a.state()), "A's library still reads")
        await QACheck.expectConverged([a, b])
    }

    /// Control: the same race with a plain 放进家具 (linkPhotos) instead of 撤销.
    @Test(arguments: [false, true]) func plainLinkAgainstAnUnseenDeletion(swap: Bool) async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice(swap ? "B" : "A", cloud: cloud, clock: clock), b = try await QADevice(swap ? "A" : "B", cloud: cloud, clock: clock)
        try await QACheck.settle([a, b])
        let chair = try await a.store.addFurniture(placement: SyncCheck.chair, displayName: "Chair")
        let photo = try await a.store.addPhoto(draft: try TestSupport.draft(seed: 391)).photoId
        try await QACheck.settle([a, b])
        try await b.store.deletePhoto(photoId: photo)
        try await a.store.linkPhotos(photoIds: [photo], toInstance: chair.instanceId)
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            print("QA plain \(device.name) swap=\(swap): photos=\(state.photos.count) links=\(state.allFurniture.flatMap(\.sources).count)")
            expectWhole(state, photo: photo, on: chair.instanceId, device.name)
        }
        await QACheck.expectConverged([a, b])
    }

    /// The undo race again with the device names swapped.
    @Test(arguments: [false, true]) func undoRaceSwapped(swap: Bool) async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice(swap ? "B" : "A", cloud: cloud, clock: clock), b = try await QADevice(swap ? "A" : "B", cloud: cloud, clock: clock)
        try await QACheck.settle([a, b])
        let chair = try await a.store.addFurniture(placement: SyncCheck.chair, displayName: "Chair")
        let photo = try await a.store.addPhoto(draft: try TestSupport.draft(seed: 392)).photoId
        try await a.store.linkPhotos(photoIds: [photo], toInstance: chair.instanceId)
        try await QACheck.settle([a, b])
        let receipt = try await a.store.unlinkPhotos(photoIds: [photo], fromInstances: nil)
        try await QACheck.settle([a, b])
        try await b.store.deletePhoto(photoId: photo)
        _ = try await a.store.undoUnlink(receipt)
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            print("QA undo \(device.name) swap=\(swap): photos=\(state.photos.count) links=\(state.allFurniture.flatMap(\.sources).count)")
            expectWhole(state, photo: photo, on: chair.instanceId, device.name)
        }
        await QACheck.expectConverged([a, b])
    }
}
