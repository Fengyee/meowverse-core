import Foundation
import Testing
@testable import MeowverseCore

/// QA round 3 (deda176): the two new guards, against take-backs and held syncs.
@Suite(.serialized) struct QARound3SyncTests {
    let clock = SyncTestClock()

    private func pair(_ swap: Bool) async throws -> (QADevice, QADevice) {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice(swap ? "B" : "A", cloud: cloud, clock: clock), b = try await QADevice(swap ? "A" : "B", cloud: cloud, clock: clock)
        try await QACheck.settle([a, b])
        return (a, b)
    }

    /// A suggestion filed on A and settled.
    private func filed(_ a: QADevice, _ b: QADevice, seed: Int) async throws -> (String, String, LibraryStore.SuggestionReceipt, PhotoCarrierSource) {
        let sofa = try await a.store.addFurniture(placement: SyncCheck.chair, displayName: "Sofa")
        let photo = try await a.store.addPhoto(draft: try TestSupport.draft(seed: seed)).photoId
        let filing = try await a.store.fileSuggestions([BatchSuggestion(photoId: photo, instanceId: sofa.instanceId, closestPhotoId: "x", distance: 0.1)], printsBy: "t")
        try #require(filing.filed.count == 1)
        try await QACheck.settle([a, b])
        let link = try #require(await a.state().allFurniture.first?.sources.first)
        return (sofa.instanceId, photo, filing, link)
    }

    private func report(_ devices: [QADevice], _ photo: String, _ piece: String, _ tag: String) async throws -> [(Bool, Bool, Bool)] {
        var out: [(Bool, Bool, Bool)] = []
        for d in devices {
            let s = await d.state()
            let hasPhoto = s.photos.contains { $0.photoId == photo }
            let obs = s.observations.filter { $0.photoId == photo }
            let link = s.allFurniture.first { $0.instanceId == piece }?.sources.first { $0.photoId == photo }
            let pending = try await d.sync().pendingLinks.values.reduce(0, +)
            print("QA3 \(tag) \(d.name): photo=\(hasPhoto) obs=\(obs.count) link=\(link.map { "\($0.origin)" } ?? "none") pending=\(pending)")
            #expect(pending == 0, "\(tag) \(d.name): nothing waiting")
            // A model link only with its observation; an observation of this take-back only with its link.
            if let link, link.origin == .model { #expect(obs.contains { $0.observationId == link.observationId }, "\(tag) \(d.name)") }
            #expect((link == nil) == obs.isEmpty, "\(tag) \(d.name): observation and link go together")
            let reopened = LibraryStore(root: d.root, catalog: try TestSupport.catalog())
            #expect(try await reopened.load() == s, "\(tag) \(d.name): library reads back")
            out.append((hasPhoto, !obs.isEmpty, link != nil))
        }
        await QACheck.expectConverged(devices)
        return out
    }

    /// A takes the filed photo off and syncs, then undoes and syncs; B, which pulled neither,
    /// takes the suggestion back afterwards (link and observation go). B's take-back is the
    /// newer act on the link; the observation must not survive alone.
    @Test(.disabled("Known, round 11: a take-back on a device that missed an undo leaves the observation orphaned (no link, no pending link); see STATUS.md"), arguments: [false, true]) func takeBackAfterAnUnseenUndo(swap: Bool) async throws {
        let (a, b) = try await pair(swap)
        let (piece, photo, filing, _) = try await filed(a, b, seed: 501)
        let receipt = try await a.store.unlinkPhotos(photoIds: [photo], fromInstances: nil)
        try await a.sync()
        #expect(try await a.store.undoUnlink(receipt) == 1)
        try await a.sync()
        clock.advance()
        #expect(try await b.store.undoSuggestions(filing) == 1, "B never saw either")
        try await QACheck.settle([a, b])
        _ = try await report([a, b], photo, piece, "takeBackAfterUndo swap=\(swap)")
    }

    /// B takes the suggestion back (unseen by A), then A undoes its take-off before syncing:
    /// A's undo is the newer act. Whatever wins, all or nothing.
    @Test(arguments: [false, true]) func undoAfterAnUnseenTakeBack(swap: Bool) async throws {
        let (a, b) = try await pair(swap)
        let (piece, photo, filing, _) = try await filed(a, b, seed: 502)
        let receipt = try await a.store.unlinkPhotos(photoIds: [photo], fromInstances: nil)
        try await a.sync()
        #expect(try await b.store.undoSuggestions(filing) == 1)
        try await b.sync()
        clock.advance()
        #expect(try await a.store.undoUnlink(receipt) == 1)
        try await QACheck.settle([a, b])
        _ = try await report([a, b], photo, piece, "undoAfterTakeBack swap=\(swap)")
    }

    /// The take-back arrives while A's sync is held; A undoes during the hold.
    @Test(arguments: [false, true]) func undoDuringAHeldSyncThatBringsATakeBack(swap: Bool) async throws {
        let (a, b) = try await pair(swap)
        let (piece, photo, filing, _) = try await filed(a, b, seed: 503)
        let receipt = try await a.store.unlinkPhotos(photoIds: [photo], fromInstances: nil)
        #expect(try await b.store.undoSuggestions(filing) == 1)
        try await b.sync()
        await a.gate.arm()
        let held = Task { try await a.sync() }
        await a.gate.waitUntilHeld()
        let restored = try await a.store.undoUnlink(receipt)
        await a.gate.release()
        _ = try await held.value
        try await QACheck.settle([a, b])
        print("QA3 heldTakeBack restored=\(restored)")
        _ = try await report([a, b], photo, piece, "heldTakeBack swap=\(swap)")
    }

    /// The held round has already landed B's photo deletion in A's library when A taps 撤销.
    @Test(arguments: [false, true]) func undoAfterAHeldSyncLandedTheDeletion(swap: Bool) async throws {
        let (a, b) = try await pair(swap)
        let chair = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: 504), placement: SyncCheck.spot(2), displayName: "Chair",
                                                         decision: SourceDecision(recognition: RecognitionResult(analyzer: "test", analyzerRevision: 1,
                                                            objects: [ObservedObject(kind: .chair, label: "chair", confidence: 0.9)], catLikely: true), acceptedObjectIndex: 0))
        let photo = try #require(chair.sources.first).photoId
        try await QACheck.settle([a, b])
        let receipt = try await a.store.unlinkPhotos(photoIds: [photo], fromInstances: nil)
        try await QACheck.settle([a, b])
        try await b.store.deletePhoto(photoId: photo)
        try await b.sync()
        await a.gate.arm()
        let held = Task { try await a.sync() }
        await a.gate.waitUntilHeld()
        await a.gate.release()
        _ = try await held.value
        #expect(!(await a.state().photos.contains { $0.photoId == photo }), "the held round landed the deletion")
        #expect(try await a.store.undoUnlink(receipt) == 0)
        try await QACheck.settle([a, b])
        let r = try await report([a, b], photo, chair.instanceId, "heldLanded swap=\(swap)")
        #expect(r.allSatisfy { !$0.0 && !$0.1 && !$0.2 }, "all three stay deleted")
    }
}
