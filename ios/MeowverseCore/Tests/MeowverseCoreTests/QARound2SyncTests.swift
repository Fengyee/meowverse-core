import Foundation
import Testing
@testable import MeowverseCore

/// QA round 2 (2026-11-19): the observation re-stamp in SyncCapture (1704291), adversarially.
@Suite(.serialized) struct QARound2SyncTests {
    let clock = SyncTestClock()

    private func recognition() -> RecognitionResult {
        RecognitionResult(analyzer: "test", analyzerRevision: 1,
                          objects: [ObservedObject(kind: .chair, label: "chair", confidence: 0.9)], catLikely: true)
    }

    /// A model-origin chair with a second (manual) photo, settled on both.
    private func setUp(_ swap: Bool) async throws -> (QADevice, QADevice, PhotoFurniture, PhotoCarrierSource, PhotoObservation, String) {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice(swap ? "B" : "A", cloud: cloud, clock: clock), b = try await QADevice(swap ? "A" : "B", cloud: cloud, clock: clock)
        try await QACheck.settle([a, b])
        let chair = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: 481), placement: SyncCheck.chair,
                                                         displayName: "Chair", decision: SourceDecision(recognition: recognition(), acceptedObjectIndex: 0))
        let q = try await a.store.addPhoto(draft: try TestSupport.draft(seed: 482)).photoId
        try await a.store.linkPhotos(photoIds: [q], toInstance: chair.instanceId)
        try await QACheck.settle([a, b])
        let link = try #require(chair.sources.first)
        let obs = try #require(await a.state().observations.first { $0.observationId == link.observationId })
        return (a, b, chair, link, obs, q)
    }

    private func pending(_ d: QADevice) async throws -> Int { try await d.sync().pendingLinks.values.reduce(0, +) }

    private func expectDeleted(_ devices: [QADevice], _ link: PhotoCarrierSource, _ label: String) async throws {
        for d in devices {
            let s = await d.state()
            #expect(!s.photos.contains { $0.photoId == link.photoId }, "\(label) \(d.name): the deleted photo stays deleted")
            #expect(!s.observations.contains { $0.observationId == link.observationId }, "\(label) \(d.name): and its observation")
            #expect(try await pending(d) == 0, "\(label) \(d.name): nothing waiting")
        }
        await QACheck.expectConverged(devices)
    }

    /// Undo vs unseen deletion: the observation comes back byte for byte, nothing waits, and
    /// further syncs send nothing (no re-stamp ping-pong).
    @Test(arguments: [false, true]) func observationComesBackUnchangedAndQuiet(swap: Bool) async throws {
        let (a, b, chair, link, obs, _) = try await setUp(swap)
        let receipt = try await a.store.unlinkPhotos(photoIds: [link.photoId], fromInstances: nil)
        try await QACheck.settle([a, b])
        try await b.store.deletePhoto(photoId: link.photoId)
        _ = try await a.store.undoUnlink(receipt)
        try await QACheck.settle([a, b])
        for d in [a, b] {
            let s = await d.state()
            #expect(s.observations == [obs], "\(d.name): observation content identical")
            #expect(s.allFurniture.first { $0.instanceId == chair.instanceId }?.sources.first == link, "\(d.name): link identical")
            #expect(try await pending(d) == 0)
        }
        for d in [a, b, a, b] { let r = try await d.sync(); #expect(r.sent == 0 && !r.applied, "\(d.name) quiet: \(r)") }
    }

    /// B deletes the photo on purpose; A, unaware, only reorders the album. Deletion must win.
    @Test(arguments: [false, true]) func explicitDeleteThenUnseenReorder(swap: Bool) async throws {
        let (a, b, chair, link, _, q) = try await setUp(swap)
        try await b.store.deletePhoto(photoId: link.photoId)
        _ = try await a.store.reorderPhotos(instanceId: chair.instanceId, order: [q, link.photoId])
        try await QACheck.settle([a, b])
        try await expectDeleted([a, b], link, "reorder")
    }

    /// … or renames the piece, sets the deleted photo as cover, links another photo to it.
    @Test(arguments: [false, true]) func explicitDeleteThenUnseenPieceEdits(swap: Bool) async throws {
        let (a, b, chair, link, _, _) = try await setUp(swap)
        try await b.store.deletePhoto(photoId: link.photoId)
        _ = try await a.store.rename(instanceId: chair.instanceId, displayName: "Armchair")
        let r = try await a.store.addPhoto(draft: try TestSupport.draft(seed: 483)).photoId
        try await a.store.linkPhotos(photoIds: [r], toInstance: chair.instanceId)
        try await QACheck.settle([a, b])
        try await expectDeleted([a, b], link, "edits")
    }

    /// … or puts the deleted photo by hand onto another piece (a real unseen use of the photo:
    /// the photo coming back is the old rule). The observation was not used: it stays gone, and
    /// nothing is left waiting.
    @Test(arguments: [false, true]) func explicitDeleteThenUnseenManualLinkElsewhere(swap: Bool) async throws {
        let (a, b, _, link, _, _) = try await setUp(swap)
        let stool = try await a.store.addFurniture(placement: SyncCheck.spot(3), displayName: "Stool")
        try await QACheck.settle([a, b])
        try await b.store.deletePhoto(photoId: link.photoId)
        try await a.store.linkPhotos(photoIds: [link.photoId], toInstance: stool.instanceId)
        try await QACheck.settle([a, b])
        for d in [a, b] {
            let s = await d.state()
            print("QA manual-elsewhere \(d.name) swap=\(swap): photo=\(s.photos.contains { $0.photoId == link.photoId }) obs=\(s.observations.count) links=\(s.allFurniture.map { "\($0.displayName):\($0.sources.map { "\($0.origin)" })" })")
            #expect(!s.observations.contains { $0.observationId == link.observationId }, "\(d.name): unused observation stays deleted")
            #expect(try await pending(d) == 0, "\(d.name): nothing waiting")
        }
        await QACheck.expectConverged([a, b])
    }

    /// The undo lands while A's sync is held on the network after B's deletion was uploaded:
    /// A's replica learns of the deletion before it captures the undo.
    @Test(arguments: [false, true]) func undoDuringAHeldSyncThatBringsTheDeletion(swap: Bool) async throws {
        let (a, b, chair, link, obs, _) = try await setUp(swap)
        let receipt = try await a.store.unlinkPhotos(photoIds: [link.photoId], fromInstances: nil)
        try await QACheck.settle([a, b])
        try await b.store.deletePhoto(photoId: link.photoId)
        try await b.sync()
        await a.gate.arm()
        let held = Task { try await a.sync() }
        await a.gate.waitUntilHeld()
        let restored = try await a.store.undoUnlink(receipt)
        await a.gate.release()
        _ = try await held.value
        try await QACheck.settle([a, b])
        for d in [a, b] {
            let s = await d.state()
            let hasPhoto = s.photos.contains { $0.photoId == link.photoId }
            let hasObs = s.observations.contains { $0.observationId == link.observationId }
            let chairLink = s.allFurniture.first { $0.instanceId == chair.instanceId }?.sources.first { $0.photoId == link.photoId }
            let p = try await pending(d)
            print("QA held swap=\(swap) restored=\(restored) \(d.name): photo=\(hasPhoto) obs=\(hasObs) link=\(chairLink != nil) pending=\(p)")
            #expect(hasPhoto == hasObs && hasPhoto == (chairLink != nil), "\(d.name): all or nothing")
            if hasObs { #expect(s.observations.first { $0.observationId == obs.observationId } == obs) }
            #expect(p == 0, "\(d.name): nothing waiting")
        }
        await QACheck.expectConverged([a, b])
    }
}
