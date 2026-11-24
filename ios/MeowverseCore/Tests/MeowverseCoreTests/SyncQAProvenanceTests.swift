import Foundation
import Testing
@testable import MeowverseCore

/// QA review of the sync core (2026-11-18): provenance and accounts, which no sync test
/// covered (no test made a model-origin link or changed the account).
@Suite struct SyncQAProvenanceTests {
    let clock = SyncTestClock()

    func recognition(_ kinds: [FurnitureCategory]) -> RecognitionResult {
        RecognitionResult(analyzer: "test", analyzerRevision: 1,
                          objects: kinds.enumerated().map { ObservedObject(kind: $1, label: $1.rawValue, confidence: 0.9 - Double($0) * 0.1) },
                          catLikely: nil)
    }

    /// A piece confirmed from a model's suggestion arrives with the same origin, observation
    /// and relation; the observation alone never makes a piece; deleting the photo takes the
    /// observation and the link everywhere and leaves the piece, truthfully without photos.
    @Test func aModelOriginLinkKeepsItsProvenanceAndLeavesWithItsPhoto() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice("A", cloud: cloud, clock: clock), b = try await QADevice("B", cloud: cloud, clock: clock)
        try await QACheck.settle([a, b])
        let chair = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: 91), placement: SyncCheck.chair,
                                                         displayName: "Chair",
                                                         decision: SourceDecision(recognition: recognition([.chair, .sofa]), acceptedObjectIndex: 0))
        let source = try #require(chair.sources.first)
        #expect(source.origin == .model && source.observationId != nil)
        // A second photo with a recognition but no confirmed piece.
        _ = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 92))
        try await QACheck.settle([a, b])
        let onB = await b.state()
        #expect(onB.allFurniture.count == 1, "only the confirmed piece exists")
        let link = try #require(onB.items.first?.sources.first)
        #expect(link.origin == .model && link.observationId == source.observationId && link.objectIndex == 0
                && link.relationToCat == source.relationToCat)
        #expect(onB.observations.map(\.observationId) == [try #require(source.observationId)])
        try await b.store.deletePhoto(photoId: link.photoId)
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(state.observations.isEmpty, "\(device.name)")
            #expect(state.items.map(\.instanceId) == [chair.instanceId] && state.items[0].sources.isEmpty, "\(device.name)")
            #expect(try await device.sync().pendingLinks.isEmpty, "\(device.name): a piece without photos is not 'waiting'")
        }
        await QACheck.expectConverged([a, b])
    }

    /// The same photo imported and confirmed with a model link on both devices: one photo, both
    /// observations re-pointed at the shared id, both links valid.
    @Test func onePhotoConfirmedWithModelLinksOnTwoDevicesStaysValid() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice("A", cloud: cloud, clock: clock), b = try await QADevice("B", cloud: cloud, clock: clock)
        try await QACheck.settle([a, b])
        let draft = try TestSupport.draft(seed: 93)
        let decision = SourceDecision(recognition: recognition([.chair]), acceptedObjectIndex: 0)
        _ = try await a.store.commitNewFurniture(draft: draft, placement: SyncCheck.chair, displayName: "A's chair", decision: decision)
        _ = try await b.store.commitNewFurniture(draft: draft, placement: SyncCheck.spot(2), displayName: "B's chair", decision: decision)
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(state.photos.count == 1 && state.observations.count == 2, "\(device.name)")
            #expect(state.observations.allSatisfy { $0.photoId == state.photos[0].photoId }, "\(device.name)")
            #expect(state.items.count == 2 && state.items.allSatisfy { $0.sources.count == 1 && $0.sources[0].origin == .model },
                    "\(device.name)")
        }
        await QACheck.expectConverged([a, b])
    }

    /// Doc §10: a different account stops sync before anything is sent or applied.
    @Test func anotherAccountStopsSyncWithNothingSentOrApplied() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice("A", cloud: cloud, clock: clock), b = try await QADevice("B", cloud: cloud, clock: clock)
        let photo = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 94)).photo
        try await QACheck.settle([a, b])
        let before = await cloud.allEnvelopes
        await cloud.setAccount("account-2")
        _ = try await a.store.editPhoto(photoId: photo.photoId, PhotoEdit(note: "made under the old account"))
        let report = try await a.sync()
        #expect(report.problem == .accountChanged && report.sent == 0 && !report.applied)
        #expect(await cloud.allEnvelopes == before, "nothing went into the other account")
        #expect(try await a.store.load().photos.first?.note == "made under the old account")
    }
}
