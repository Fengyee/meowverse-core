import Foundation
import Testing
@testable import MeowverseCore

/// The projection's safety net past its first stage (`SyncProjection.project`): when the library
/// built from the records would fail the store's checks, which records are held back, and what
/// the report says about them. The store's own check is replaced by one that fails while a
/// chosen thing is in the library, standing in for a bug this build does not know about.
@Suite struct SyncQuarantineTests {
    static let s = SyncStamp(wall: 1_800_000_000_000, counter: 0, device: "x")

    /// A library with one photo of its own, and records for: that photo (with a note written
    /// elsewhere), a photo new here (its copy downloaded), and a piece new here.
    func setUp() async throws -> (local: AppState, replica: SyncReplica, downloaded: [String: SyncIncomingFile],
                                  mine: String, fresh: String) {
        let store = LibraryStore(root: TestSupport.tempDir(), catalog: try TestSupport.catalog())
        try await store.load()
        _ = try await store.importPhotos([try TestSupport.draft(seed: 1)])
        let local = await store.snapshot()
        let own = local.photos[0]
        var replica = SyncReplica()
        replica.merge(.photo(SyncMergeTests.photo(ids: [own.photoId], file: SyncFileInfo(own), at: Self.s, note: "from elsewhere")))
        let other = SyncFileInfo(sha256: String(repeating: "e", count: 64), mimeType: "image/jpeg", ext: "jpg",
                                 byteSize: 10, width: 4, height: 2, reducedFrom: nil)
        replica.merge(.photo(SyncMergeTests.photo(ids: ["elsewhere"], file: other, at: Self.s)))
        replica.merge(.furniture(SyncMergeTests.furniture(Self.s)))
        let staged = SyncIncomingFile(info: other, stagedFile: "sync-incoming/e", stagedThumbnail: "sync-incoming/e.jpg")
        return (local, replica, [other.sha256: staged], SyncRecord.photoName(SyncFileInfo(own).sourceHash),
                SyncRecord.photoName(other.sourceHash))
    }

    static func has(_ state: AppState, photo id: String) -> Bool { state.photos.contains { $0.photoId == id } }
    static func hasPiece(_ state: AppState) -> Bool { (state.items + state.storage).contains { $0.instanceId == "f1" } }

    /// Stage 2: the fault comes with the new photo. Holding back what is new to this device
    /// clears it; the piece still comes in, and this device's own photo takes the note.
    @Test func aFaultThatComesWithANewPhotoHoldsBackWhatIsNew() async throws {
        let (local, replica, downloaded, mine, fresh) = try await setUp()
        let result = SyncProjection.project(replica, local: local, downloaded: downloaded,
                                            fault: { Self.has($0, photo: "elsewhere") ? "photo" : nil })
        #expect(result.quarantined == [fresh])
        #expect(result.heldBack == [fresh])
        #expect(!Self.has(result.state, photo: "elsewhere") && Self.hasPiece(result.state))
        #expect(result.state.photos.first?.note == "from elsewhere")
        #expect(!result.quarantined.contains(mine))
    }

    /// Stage 3: the fault comes with the piece. What stage 2 held back did not help, so it is
    /// not held in stage 3: the new photo comes in, only the piece waits.
    @Test func aFaultThatComesWithAPieceHoldsBackOnlyThePieces() async throws {
        let (local, replica, downloaded, _, _) = try await setUp()
        let result = SyncProjection.project(replica, local: local, downloaded: downloaded,
                                            fault: { Self.hasPiece($0) ? "piece" : nil })
        #expect(result.quarantined == ["furniture.f1"])
        #expect(Self.has(result.state, photo: "elsewhere"), "the photo stage 2 held back for nothing comes in")
        #expect(!Self.hasPiece(result.state))
        #expect(result.writes.count == 1)
    }

    /// Stage 4: it takes both. This device's own photo still takes what its record says.
    @Test func aFaultThatComesWithBothHoldsBackBoth() async throws {
        let (local, replica, downloaded, mine, fresh) = try await setUp()
        let result = SyncProjection.project(replica, local: local, downloaded: downloaded,
                                            fault: { Self.hasPiece($0) || Self.has($0, photo: "elsewhere") ? "both" : nil })
        #expect(Set(result.quarantined) == [fresh, "furniture.f1"])
        #expect(!Self.has(result.state, photo: "elsewhere") && !Self.hasPiece(result.state))
        #expect(result.state.photos.first?.note == "from elsewhere", "not the last resort: \(mine) is still merged")
    }

    /// The last resort: nothing narrower helps. The library stays exactly as it is, every
    /// record is held and said, nothing is written.
    @Test func aFaultNothingNarrowerClearsKeepsTheLibraryAsItIs() async throws {
        let (local, replica, downloaded, mine, fresh) = try await setUp()
        let result = SyncProjection.project(replica, local: local, downloaded: downloaded, fault: { $0 == local ? nil : "any" })
        #expect(result.state == local)
        #expect(result.writes.isEmpty && result.missingFiles.isEmpty && result.pendingLinks.isEmpty)
        #expect(Set(result.quarantined) == [mine, fresh, "furniture.f1"])
        #expect(Set(result.heldBack).isSuperset(of: result.quarantined))
    }

    /// A newer version is held back but not quarantined: it is the one case where "update the
    /// app" is true. Values out of range in this build's format are quarantined.
    @Test func onlyANewerFormatIsReportedAsFromANewerVersion() async throws {
        let (local, replica0, downloaded, _, fresh) = try await setUp()
        var replica = replica0
        replica.merge(SyncEnvelope(type: "MVPhoto", name: fresh, format: SyncEnvelope.currentFormat + 1, payload: Data("{}".utf8)))
        var bad = SyncMergeTests.furniture(Self.s)
        bad.place.value.x = Int.max
        replica.merge(SyncEnvelope(type: "MVFurniture", name: "furniture.f2", format: SyncEnvelope.currentFormat,
                                   payload: try SyncCoding.encoder().encode(Self.renamed(bad, "f2"))))
        let result = SyncProjection.project(replica, local: local, downloaded: downloaded)
        #expect(result.heldBack.contains(fresh) && result.heldBack.contains("furniture.f2"))
        #expect(result.quarantined == ["furniture.f2"])
    }

    static func renamed(_ record: FurnitureSyncRecord, _ id: String) -> FurnitureSyncRecord {
        FurnitureSyncRecord(instanceId: id, place: record.place, name: record.name, tags: record.tags, locked: record.locked,
                            cover: record.cover, order: record.order, links: record.links,
                            createdAt: record.createdAt, updatedAt: record.updatedAt, tomb: record.tomb)
    }

    /// A version out of range is replaced by the cloud's next readable one: it is no longer
    /// held back, and the piece shows it.
    @Test func theNextReadableVersionReplacesOneOutOfRange() throws {
        var bad = SyncMergeTests.furniture(Self.s)
        bad.place.value.x = Int.max
        var replica = SyncReplica()
        let hostile = SyncEnvelope(type: "MVFurniture", name: "furniture.f1", format: SyncEnvelope.currentFormat,
                                   payload: try SyncCoding.encoder().encode(bad))
        let held = replica.merge(hostile)
        #expect(held && replica.unreadable["furniture.f1"] != nil)
        let fixed = SyncMergeTests.furniture(SyncStamp(wall: Self.s.wall + 1, counter: 0, device: "x"), name: "Fixed")
        let replaced = replica.merge(try SyncEnvelope(.furniture(fixed)))
        #expect(replaced)
        #expect(replica.unreadable["furniture.f1"] == nil)
        guard case .furniture(let now)? = replica["furniture.f1"] else { Issue.record("no record"); return }
        #expect(now.name.value == "Fixed")
        // A newer format is not replaced so: which of the two is newer cannot be told.
        let future = SyncEnvelope(type: "MVFurniture", name: "furniture.f1", format: SyncEnvelope.currentFormat + 1, payload: Data())
        replica.merge(future)
        replica.merge(try SyncEnvelope(.furniture(SyncMergeTests.furniture(SyncStamp(wall: Self.s.wall + 2, counter: 0, device: "x")))))
        #expect(replica.unreadable["furniture.f1"] == future)
    }

    /// End to end: a record out of range in the cloud reaches the report as quarantined, and a
    /// newer format as held back only.
    @Test func theReportSaysWhichRecordsANewerVersionExplains() async throws {
        let clock = SyncTestClock()
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        try await a.sync()
        var bad = SyncMergeTests.furniture(SyncStamp(wall: SyncClock.millis(clock.now), counter: 0, device: "zz"))
        bad.place.value.width = Int.max
        let hostile = SyncEnvelope(type: "MVFurniture", name: "furniture.f1", format: SyncEnvelope.currentFormat,
                                   payload: try SyncCoding.encoder().encode(bad))
        let future = SyncEnvelope(type: "MVRoom", name: "room.r9", format: SyncEnvelope.currentFormat + 1, payload: Data("{}".utf8))
        _ = try await cloud.endpoint("N").save([SyncSave(envelope: hostile, baseTag: nil), SyncSave(envelope: future, baseTag: nil)])
        clock.advance()
        let report = try await a.sync()
        #expect(Set(report.heldBack) == ["furniture.f1", "room.r9"])
        #expect(report.quarantined == ["furniture.f1"])
    }
}
