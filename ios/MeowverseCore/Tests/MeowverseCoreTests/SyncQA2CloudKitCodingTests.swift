import CloudKit
import Foundation
import Testing
@testable import MeowverseCore

/// QA review, round 2 (2026-11-18): the CloudKit coding as the transport uses it. The transport
/// skips, for good, any fetched record `envelope(from:)` returns nil for (CKSyncEngine's token
/// moves past it), so nil must mean "not sync's", never "sync's, but from a newer build".
struct SyncQA2CloudKitCodingTests {
    /// A record written by a newer build (higher format, fields this build does not know) is
    /// handed to sync, which keeps it as it came and leaves the piece alone.
    @Test func aRecordFromANewerBuildIsHandedOnToBeHeldBackNotSkipped() throws {
        let scratch = TestSupport.tempDir()
        let newer = SyncEnvelope(type: "MVFurniture", name: "furniture.f1", format: SyncEnvelope.currentFormat + 1,
                                 payload: Data("{\"future\":true}".utf8))
        let (record, _) = try CloudKitSyncCoding.record(for: newer, systemFields: nil, zones: .home, scratch: scratch)
        record["fieldFromTheFuture"] = "x" as NSString
        let read = try #require(CloudKitSyncCoding.envelope(from: record, zones: .home), "a newer record would be skipped by the transport")
        #expect(read == newer)
        var replica = SyncReplica()
        let merged = replica.merge(read)
        #expect(merged)
        #expect(replica.unreadable["furniture.f1"] == newer)

        // The same for a type this build does not know at all.
        let unknownType = SyncEnvelope(type: "MVGarden", name: "garden.g1", format: 1, payload: Data("{}".utf8))
        let (other, _) = try CloudKitSyncCoding.record(for: unknownType, systemFields: nil, zones: .home, scratch: scratch)
        #expect(CloudKitSyncCoding.envelope(from: other, zones: .home) == unknownType)
    }

    /// The mirror hands a cycle the newest version of each record once, whichever way it came in
    /// (the engine's fetch, this device's own save, a conflict's server record).
    @Test func theMirrorHandsOutOnlyTheNewestVersionOfEachRecord() {
        var mirror = CloudSyncMirror(epoch: "e")
        let start = mirror.changes(since: nil).token
        let v1 = SyncEnvelope(type: "MVRoom", name: "room.r1", format: 1, payload: Data("1".utf8))
        let v2 = SyncEnvelope(type: "MVRoom", name: "room.r1", format: 1, payload: Data("2".utf8))
        let first = mirror.record(v1, tag: "t1", systemFields: nil)
        let second = mirror.record(v2, tag: "t2", systemFields: Data([1]))
        let again = mirror.record(v2, tag: "t2", systemFields: Data([2]))
        #expect(first && second)
        #expect(!again, "the same version again is not new")
        let changes = mirror.changes(since: start)
        #expect(changes.records.map(\.envelope) == [v2])
        #expect(mirror.entry(named: "room.r1")?.systemFields == Data([2]))
        #expect(mirror.changes(since: changes.token).records.isEmpty)
    }
}
