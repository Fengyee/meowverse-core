import Foundation
import Synchronization
import Testing
@testable import MeowverseCore

/// What a deletion says it did (audit 2026-11-24, M07): records this device can't read are left
/// alone and said so (D24-01), "delete the home in iCloud" names a shared photo's records
/// together as an ordinary deletion does (DD24-01), a cloud deletion is not unsaid by a failed
/// local write after it (C24-06), and a deletion another device made that this device committed
/// but has not finished cleaning up is said as such (DD24-03).
@Suite struct SyncDeleteTruthTests {
    let clock = SyncTestClock()

    // MARK: D24-01

    /// A record a newer build wrote stays as it is in the cloud, and the report names it: the
    /// home is not all deleted, so the app must not say it is.
    @Test func aRecordThisDeviceCannotReadIsLeftAndSaidNotCountedAsDeleted() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        let b = try await SyncDevice("B", cloud: cloud, clock: clock)
        _ = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 501))
        _ = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 502))
        try await SyncCheck.settle([a, b])
        let photos = await a.state().photos.sorted { $0.sha256 < $1.sha256 }
        let newer = SyncRecord.photoName(photos[0].reducedFrom?.sha256 ?? photos[0].sha256)
        let other = SyncRecord.photoName(photos[1].reducedFrom?.sha256 ?? photos[1].sha256)
        let future = SyncEnvelope(type: "MVPhoto", name: newer, format: SyncEnvelope.currentFormat + 1, payload: Data("{}".utf8))
        let tag = try #require(try await a.session.deviceState()?.tags[newer])
        _ = try await cloud.endpoint("N").save([SyncSave(envelope: future, baseTag: tag)])
        try await a.sync()
        clock.advance()

        let report = try await a.session.deleteHomeInCloud()
        #expect(report.problem == nil && report.unsent == 0, "everything this device could delete was sent")
        #expect(report.heldBack == [newer], "the record left as it is is said, not hidden behind a full success")
        let envelopes = await cloud.allEnvelopes
        #expect(envelopes.first { $0.name == newer } == future, "the newer build's record is not overwritten")
        #expect(envelopes.first { $0.name == other }?.decoded()?.isLive == false, "the readable photo is deleted")
    }

    /// The ordinary case still reports nothing held back.
    @Test func aWholeDeletionHoldsNothingBack() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        _ = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 503))
        try await a.sync()
        clock.advance()
        let report = try await a.session.deleteHomeInCloud()
        #expect(report.problem == nil && report.unsent == 0 && report.heldBack.isEmpty && !report.localStateUnsaved)
    }

    // MARK: DD24-01

    /// A shared stored copy shown through two records (O on A, R on B), plus an unrelated photo
    /// U. A deletes the home in iCloud; B, not having seen that, writes a note into its own
    /// record R. R comes back, and must bring O with it, as after an ordinary deletion of the
    /// photo: the favourite and the confirmed day A wrote into O stay.
    @Test func deletingTheHomeNamesASharedPhotosRecordsTogether() async throws {
        let fixture = SyncSharedCopyTests()
        let cloud = SyncMemoryCloud()
        let (a, b, _) = try await fixture.sharedCopy(cloud)
        try await SyncCheck.settle([a, b])
        fixture.clock.advance()
        let mine = try await a.onlyPhoto()
        _ = try await a.store.editPhoto(photoId: mine.photoId, PhotoEdit(favorite: true, captureDate: .set("2020-01-02")))
        let unrelated = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 504)).photo
        try await SyncCheck.settle([a, b])
        let theirs = try #require(await b.state().photos.first { $0.sha256 == mine.sha256 })
        try #require(theirs.favorite && theirs.captureDate == "2020-01-02")
        fixture.clock.advance()

        let report = try await a.session.deleteHomeInCloud()
        #expect(report.problem == nil && report.unsent == 0)
        let replica = try #require(try await a.session.deviceState()).replica
        let o = SyncRecord.photoName(try #require(mine.reducedFrom?.sha256)), r = SyncRecord.photoName(mine.sha256)
        let u = SyncRecord.photoName(unrelated.reducedFrom?.sha256 ?? unrelated.sha256)
        func together(_ name: String) -> [String]? {
            guard case .photo(let record) = replica[name] else { return ["missing"] }
            return record.tomb?.together
        }
        #expect(together(o) == [o, r].sorted() && together(r) == [o, r].sorted(), "both records of the shared photo name each other")
        #expect(together(u) == nil, "an unrelated photo is not put in the group")

        fixture.clock.advance()
        _ = try await b.store.editPhoto(photoId: theirs.photoId, PhotoEdit(note: "unseen"))
        try await b.session.captureLocalEdits()
        _ = try await a.store.clearAll()
        try await SyncCheck.settle([a, b])
        for device in [a, b] {
            let p = try await device.onlyPhoto()
            #expect(p.note == "unseen", "\(device.name)")
            #expect(p.favorite && p.captureDate == "2020-01-02" && p.captureDateSource == .user,
                    "\(device.name): the photo came back without what O held")
        }
    }

    // MARK: C24-06

    /// Every deletion reached iCloud; then writing sync's own file fails. The report says what
    /// happened in the cloud (all sent), and that the local file is behind; the call does not
    /// throw as if nothing had been deleted anywhere.
    @Test func aLocalWriteFailingAfterTheDeletionsWentOutDoesNotUnsayThem() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        _ = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 505))
        try await a.sync()
        let root = TestSupport.tempDir().appendingPathComponent("Library-A2", isDirectory: true)
        try FileManager.default.copyItem(at: a.root, to: root)
        let store = LibraryStore(root: root, catalog: try TestSupport.catalog())
        try await store.load()
        let transport = AfterSaveTransport(inner: cloud.endpoint("A")) {
            // The disk refuses the next write into the library folder.
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        let session = SyncSession(store: store, transport: transport, catalog: try TestSupport.catalog(),
                                  deviceID: "devA", now: clock.reader())
        clock.advance()
        let report = try await session.deleteHomeInCloud()
        #expect(report.problem == nil && report.unsent == 0, "the cloud has every deletion")
        #expect(report.localStateUnsaved, "the local file is behind, and that is said")
        let live = await cloud.allEnvelopes.compactMap { $0.decoded() }.filter(\.isLive).map(\.name)
        #expect(!live.contains { $0.hasPrefix("photo.") })
    }

    // MARK: DD24-03

    /// B deletes a photo; A takes the deletion, commits it, but removing the local files fails
    /// once. A's report says the clean-up is pending; the next cycle finishes it.
    @Test func aRemoteDeletionWhoseLocalCleanUpFailsIsSaidPendingThenFinished() async throws {
        let cloud = SyncMemoryCloud()
        let fault = FaultSwitch(nil)
        let a = try await SyncDevice("A", cloud: cloud, clock: clock, fault: fault.handler)
        let b = try await SyncDevice("B", cloud: cloud, clock: clock)
        _ = try await b.store.importPhoto(draft: try TestSupport.draft(seed: 506))
        try await SyncCheck.settle([a, b])
        let onA = try await a.onlyPhoto()
        try await b.store.deletePhoto(photoId: try await b.onlyPhoto().photoId)
        try await b.sync()
        fault.arm(.deletionFileRemoval)
        let report = try await a.sync()
        let afterReport = await a.state().photos
        #expect(report.applied && afterReport.isEmpty, "the deletion is committed")
        #expect(report.localCleanupPending, "the files still here are said, not a plain success")
        let next = try await a.sync()
        #expect(!next.localCleanupPending)
        #expect(await a.store.integrityReport().isClean)
        #expect(!FileManager.default.fileExists(atPath: a.root.appendingPathComponent(onA.originalFile).path))
    }
}

/// Passes every call on; runs `afterSave` once, right after the first save call returns.
final class AfterSaveTransport: SyncTransport {
    let inner: SyncMemoryEndpoint
    let afterSave: Mutex<(@Sendable () -> Void)?>

    init(inner: SyncMemoryEndpoint, afterSave: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.afterSave = Mutex(afterSave)
    }

    func accountKey() async throws -> String { try await inner.accountKey() }
    func fetchChanges(since token: SyncToken?) async throws -> SyncFetchResult { try await inner.fetchChanges(since: token) }
    func save(_ records: [SyncSave]) async throws -> [SyncSaveResult] {
        let results = try await inner.save(records)
        afterSave.withLock { hook in hook?(); hook = nil }
        return results
    }
    func hasFile(sha256: String) async throws -> Bool { try await inner.hasFile(sha256: sha256) }
    func uploadFile(sha256: String, data: Data) async throws { try await inner.uploadFile(sha256: sha256, data: data) }
    func downloadFile(sha256: String) async throws -> Data { try await inner.downloadFile(sha256: sha256) }
    func deleteFile(sha256: String) async throws { try await inner.deleteFile(sha256: sha256) }
}
