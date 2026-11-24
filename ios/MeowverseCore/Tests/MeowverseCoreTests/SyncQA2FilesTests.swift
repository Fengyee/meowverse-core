import Foundation
import Synchronization
import Testing
@testable import MeowverseCore

/// QA review, round 2 (2026-11-18): the cloud's photo files now that any device cleans them up,
/// and a first sync that has many photos to download.

/// Hooks a test sets on one device's transport.
final class QA2Hooks: Sendable {
    /// Runs once, right after the next successful upload.
    let afterUpload = Mutex<(@Sendable () async -> Void)?>(nil)
    /// Runs before every save call, with what is about to be saved.
    let beforeSave = Mutex<(@Sendable ([SyncSave]) async -> Void)?>(nil)
    /// Runs before every download.
    let beforeDownload = Mutex<(@Sendable () async -> Void)?>(nil)
    /// Record names fetches never deliver (a transport that lost those versions).
    let lost = Mutex<Set<String>>([])
    /// Uploads of these hashes fail with `error`.
    let failingUploads = Mutex<Set<String>>([])
    let downloads = Mutex(0)
}

struct QA2Transport: SyncTransport {
    let inner: SyncMemoryEndpoint
    let hooks: QA2Hooks

    func accountKey() async throws -> String { try await inner.accountKey() }
    func fetchChanges(since token: SyncToken?) async throws -> SyncFetchResult {
        let page = try await inner.fetchChanges(since: token)
        let lost = hooks.lost.withLock { $0 }
        guard !lost.isEmpty else { return page }
        return SyncFetchResult(records: page.records.filter { !lost.contains($0.envelope.name) }, token: page.token,
                               moreComing: page.moreComing)
    }
    func save(_ records: [SyncSave]) async throws -> [SyncSaveResult] {
        if let check = hooks.beforeSave.withLock({ $0 }) { await check(records) }
        return try await inner.save(records)
    }
    func hasFile(sha256: String) async throws -> Bool { try await inner.hasFile(sha256: sha256) }
    func uploadFile(sha256: String, data: Data) async throws {
        if hooks.failingUploads.withLock({ $0.contains(sha256) }) { throw SyncTransportError.rejected("qa") }
        try await inner.uploadFile(sha256: sha256, data: data)
        let hook = hooks.afterUpload.withLock { hook in defer { hook = nil }; return hook }
        if let hook { await hook() }
    }
    func downloadFile(sha256: String) async throws -> Data {
        hooks.downloads.withLock { $0 += 1 }
        if let hook = hooks.beforeDownload.withLock({ $0 }) { await hook() }
        return try await inner.downloadFile(sha256: sha256)
    }
    func deleteFile(sha256: String) async throws { try await inner.deleteFile(sha256: sha256) }
}

struct QA2Device {
    let name: String
    let root: URL
    let store: LibraryStore
    let session: SyncSession
    let hooks = QA2Hooks()

    init(_ name: String, cloud: SyncMemoryCloud, clock: SyncTestClock) async throws {
        self.name = name
        root = TestSupport.tempDir().appendingPathComponent("Library-\(name)", isDirectory: true)
        let catalog = try TestSupport.catalog()
        store = LibraryStore(root: root, catalog: catalog)
        try await store.load()
        session = SyncSession(store: store, transport: QA2Transport(inner: cloud.endpoint(name), hooks: hooks),
                              catalog: catalog, deviceID: "dev\(name)", now: clock.reader())
    }

    @discardableResult
    func sync() async throws -> SyncReport { try await session.sync() }

    func state() async -> AppState { await store.snapshot() }

    static func settle(_ devices: [QA2Device], rounds: Int = 12, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 1...rounds {
            var changed = false
            for device in devices {
                let report = try await device.sync()
                if report.applied || report.sent > 0 || report.received > 0 || report.unsent > 0 || report.problem != nil
                    || report.waitingForFiles > 0 { changed = true }
            }
            if !changed { return }
        }
        Issue.record("did not settle in \(rounds) rounds", sourceLocation: sourceLocation)
    }
}

/// Every live photo record in the cloud has at least one of its copies in the cloud.
func qa2LivePhotosWithoutAFile(_ cloud: SyncMemoryCloud) async -> [String] {
    let files = await cloud.fileHashes
    return await cloud.allEnvelopes.compactMap { envelope -> String? in
        guard case .photo(let photo) = envelope.decoded(), SyncRecord.photo(photo).isLive else { return nil }
        return photo.copies.contains { files.contains($0.sha256) } ? nil : envelope.name
    }
}

@Suite struct SyncQA2FilesTests {
    let clock = SyncTestClock()

    /// A photo deleted more than a day ago comes back: B had sync off meanwhile and turns it on
    /// again with the photo still in its library. B uploads the file first, as it should; but
    /// before B's record arrives, C (which heard of the deletion and has not cleaned up yet) runs
    /// a cycle and deletes the file as unneeded. B's live record then reaches the cloud with no
    /// file (the CloudKit transport's file gate trusts its cache of what it uploaded).
    @Test func aFileUploadedForAPhotoThatComesBackIsNotDeletedBeforeItsRecordArrives() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QA2Device("A", cloud: cloud, clock: clock)
        let b = try await QA2Device("B", cloud: cloud, clock: clock)
        let c = try await QA2Device("C", cloud: cloud, clock: clock)
        let photo = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 240)).photo
        let name = SyncRecord.photoName(photo.reducedFrom?.sha256 ?? photo.sha256)
        try await QA2Device.settle([a, b, c])
        try await b.session.startOver() // B turns sync off; its library keeps the photo
        try await a.store.deletePhoto(photoId: photo.photoId)
        try await a.sync()
        try await c.sync()
        clock.advance(SyncSession.fileGrace + 60)
        try await a.sync()
        #expect(await !cloud.fileHashes.contains(photo.sha256), "A cleaned up the deleted photo's file")

        // B turns sync on again. Between its upload and its save, C runs a cycle.
        b.hooks.afterUpload.withLock { $0 = { _ = try? await c.sync() } }
        let fileAtSave = Mutex<Bool?>(nil)
        b.hooks.beforeSave.withLock { hook in
            hook = { saves in
                guard let save = saves.first(where: { $0.envelope.name == name }),
                      case .photo(let record) = save.envelope.decoded(), SyncRecord.photo(record).isLive else { return }
                let present = await cloud.fileHashes.contains(photo.sha256)
                fileAtSave.withLock { $0 = present }
            }
        }
        try await b.sync()
        #expect(fileAtSave.withLock { $0 } == true,
                "B's live record of the photo went to the cloud after C deleted the file B had just uploaded")
        b.hooks.beforeSave.withLock { $0 = nil }
        try await QA2Device.settle([b, a, c])
        #expect(await qa2LivePhotosWithoutAFile(cloud) == [])
        #expect(await a.state().photos.map(\.sha256) == [photo.sha256], "the photo is back everywhere")
    }

    /// If a device's view misses one version (the CloudKit transport skips a record it cannot
    /// read, or its fetch cache is lost while the engine's token moved on), its clean-up must not
    /// delete the file of a photo that version brought back. Here B links a photo to a lamp while
    /// A deletes it; C never receives B's version of the photo record.
    @Test func aDeviceThatMissedAComebackDoesNotDeleteTheFileTheComebackNeeds() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QA2Device("A", cloud: cloud, clock: clock)
        let b = try await QA2Device("B", cloud: cloud, clock: clock)
        let c = try await QA2Device("C", cloud: cloud, clock: clock)
        let photo = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 241)).photo
        let name = SyncRecord.photoName(photo.reducedFrom?.sha256 ?? photo.sha256)
        let lamp = try await b.store.addFurniture(placement: SyncCheck.spot(1), displayName: "Lamp")
        try await QA2Device.settle([a, b, c])
        try await a.store.deletePhoto(photoId: photo.photoId)
        try await a.sync()
        try await c.sync()
        clock.advance()
        _ = try await b.store.linkPhoto(photoId: photo.photoId, toInstance: lamp.instanceId)
        c.hooks.lost.withLock { $0 = [name] }
        try await b.sync()
        try await a.sync()
        clock.advance(SyncSession.fileGrace + 60)
        try await c.sync()
        #expect(await qa2LivePhotosWithoutAFile(cloud) == [],
                "C deleted the file of a photo that is live in the cloud, judging on a view that missed a version")
        // A deleted its own copy; it can only get the photo back from the cloud.
        let report = try await a.sync()
        let shownOnA = await a.state().photos.count
        #expect(report.waitingForFiles == 0 && shownOnA == 1, "A waits for a file nobody has uploaded again")
    }

    /// A first sync with many photos to download. The user edits now and then while they come in
    /// (one edit per attempt here). Each edit sends the cycle back to the start, and every
    /// download of the attempt is thrown away and made again; after the fifth attempt `sync()`
    /// gives up and nothing has arrived.
    @Test func editsDuringAFirstSyncsDownloadsDoNotThrowAwayEveryDownload() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QA2Device("A", cloud: cloud, clock: clock)
        let b = try await QA2Device("B", cloud: cloud, clock: clock)
        let count = 6
        for i in 0..<count { _ = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 250 + i)) }
        try await a.sync()
        let store = b.store
        let edits = Mutex(0)
        b.hooks.beforeDownload.withLock { hook in
            hook = {
                // The first download of each attempt: the user renames the cat.
                let n = edits.withLock { $0 += 1; return $0 }
                if (n - 1) % count == 0 { _ = try? await store.setCatName("Cat \(n)") }
            }
        }
        var gaveUp = false
        do { try await b.sync() } catch SyncApplyError.localChanged { gaveUp = true }
        let downloads = b.hooks.downloads.withLock { $0 }
        #expect(!gaveUp, "the first sync gave up after \(downloads) downloads")
        #expect(downloads <= 2 * count, "\(downloads) downloads for \(count) photos")
        #expect(await b.state().photos.count == count)
    }

    /// One photo whose upload keeps failing (CloudKit refuses it, or the app cannot write its
    /// scratch copy) holds that photo back, not every other edit: a room renamed meanwhile on the
    /// same device still reaches the other one, and the device still receives. Only a full iCloud
    /// is handled per photo today; any other upload error ends the push and skips the fetch.
    @Test func onePhotoThatCannotBeUploadedDoesNotHoldBackEveryOtherEdit() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QA2Device("A", cloud: cloud, clock: clock)
        let b = try await QA2Device("B", cloud: cloud, clock: clock)
        let study = try await a.store.addRoom(name: "Study")
        try await QA2Device.settle([a, b])
        let photo = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 260)).photo
        a.hooks.failingUploads.withLock { $0 = [photo.sha256] }
        _ = try await a.store.renameRoom(roomId: study.roomId, name: "Atelier")
        let lamp = try await b.store.addFurniture(placement: SyncCheck.spot(2), displayName: "Lamp")
        for _ in 0..<3 {
            _ = try await a.sync()
            _ = try await b.sync()
        }
        #expect(await b.state().room(id: study.roomId)?.name == "Atelier",
                "one photo's failing upload kept A's room rename from ever leaving A")
        #expect(await a.state().allFurniture.contains { $0.instanceId == lamp.instanceId },
                "one photo's failing upload also kept A from ever receiving B's new piece")
        let report = try await a.sync()
        #expect(report.problem != nil, "A says something is wrong")
    }

    /// A newer build brought a deleted photo back in a format this build cannot read. Its file
    /// is what that record needs; this build, which still sees only the old deletion, must not
    /// clean it up (a guard no other test exercised).
    @Test func aPhotoANewerBuildBroughtBackKeepsItsFileOnAnOlderBuild() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QA2Device("A", cloud: cloud, clock: clock)
        let b = try await QA2Device("B", cloud: cloud, clock: clock)
        let photo = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 270)).photo
        let name = SyncRecord.photoName(photo.reducedFrom?.sha256 ?? photo.sha256)
        try await QA2Device.settle([a, b])
        try await a.store.deletePhoto(photoId: photo.photoId)
        try await a.sync()
        try await b.sync()
        clock.advance(SyncSession.fileGrace + 60)
        let future = SyncEnvelope(type: "MVPhoto", name: name, format: SyncEnvelope.currentFormat + 1,
                                  payload: Data("{\"back\":true}".utf8))
        let tag = try #require(try await b.session.deviceState()?.tags[name])
        _ = try await cloud.endpoint("N").save([SyncSave(envelope: future, baseTag: tag)])
        try await b.sync()
        #expect(await cloud.fileHashes.contains(photo.sha256),
                "an older build deleted the file of a photo a newer build brought back")
    }

    /// The best copy left the cloud with the photo's deletion; B, which never heard of it, links
    /// the photo and uploads its smaller copy. That copy is "not the best" but is now the only one
    /// in the cloud: no clean-up may take it (the best-is-there check no other test exercised).
    @Test func theOnlyCopyLeftOfAPhotoThatCameBackIsNotCleanedUpAsNotTheBest() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QA2Device("A", cloud: cloud, clock: clock)
        let b = try await QA2Device("B", cloud: cloud, clock: clock)
        let c = try await QA2Device("C", cloud: cloud, clock: clock)
        let big = try await a.store.importPhoto(draft: try SyncCheck.wideDraft(seed: 5, maxPixel: 2048)).photo
        let small = try await b.store.importPhoto(draft: try SyncCheck.wideDraft(seed: 5, maxPixel: 1024)).photo
        #expect(big.reducedFrom?.sha256 == small.reducedFrom?.sha256 && big.sha256 != small.sha256)
        let lamp = try await b.store.addFurniture(placement: SyncCheck.spot(1), displayName: "Lamp")
        try await QA2Device.settle([a, b, c])
        let photoId = try #require(await b.state().photos.first?.photoId)
        try await a.store.deletePhoto(photoId: photoId)
        try await a.sync()
        try await c.sync()
        clock.advance(SyncSession.fileGrace + 60)
        try await c.sync()
        #expect(await !cloud.fileHashes.contains(big.sha256), "the best copy left with the deletion")
        _ = try await b.store.linkPhoto(photoId: photoId, toInstance: lamp.instanceId)
        try await b.sync()
        try await c.sync()
        try await b.sync()
        #expect(await cloud.fileHashes.contains(small.sha256), "the only copy left in the cloud was cleaned up")
        #expect(await qa2LivePhotosWithoutAFile(cloud) == [])
    }
}
