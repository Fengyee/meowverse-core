import Foundation
import Synchronization
import Testing
@testable import MeowverseCore

/// Which cloud files survive (audit 2026-11-24, M08): a file put up for a photo is confirmed
/// with the cloud itself before the record that needs it goes, not with a remembered answer
/// (D24-02); a file whose storage time can't be read now is not deleted (D24-03); a shared
/// photo's best copy stays while the photo is shown (C24-01); and a copy is not deleted for a
/// best one the cloud holds damaged (C24-07).
@Suite struct SyncFileSurvivalTests {
    let clock = SyncTestClock()

    /// The CloudKit transport's contract, in memory: `hasFile` answers from what this part of the
    /// cycle already learned (an upload counts as "there") until the next fetch; only
    /// `confirmFile` asks the cloud itself. Hooks for the timing a test needs.
    final class Hooks: Sendable {
        let answers = Mutex<[String: Bool]>([:])
        let afterUpload = Mutex<(@Sendable () async -> Void)?>(nil)
        let beforeSave = Mutex<(@Sendable ([SyncSave]) async -> Void)?>(nil)
        let storedAtFails = Mutex(false)
    }

    struct CachingTransport: SyncTransport {
        let inner: SyncMemoryEndpoint
        let hooks: Hooks

        func accountKey() async throws -> String { try await inner.accountKey() }
        func fetchChanges(since token: SyncToken?) async throws -> SyncFetchResult {
            let page = try await inner.fetchChanges(since: token)
            hooks.answers.withLock { $0 = [:] }
            return page
        }
        func save(_ records: [SyncSave]) async throws -> [SyncSaveResult] {
            if let check = hooks.beforeSave.withLock({ $0 }) { await check(records) }
            return try await inner.save(records)
        }
        func hasFile(sha256: String) async throws -> Bool {
            if let known = hooks.answers.withLock({ $0[sha256] }) { return known }
            return try await confirmFile(sha256: sha256)
        }
        func confirmFile(sha256: String) async throws -> Bool {
            let there = try await inner.hasFile(sha256: sha256)
            hooks.answers.withLock { $0[sha256] = there }
            return there
        }
        func uploadFile(sha256: String, data: Data) async throws {
            try await inner.uploadFile(sha256: sha256, data: data)
            hooks.answers.withLock { $0[sha256] = true }
            let hook = hooks.afterUpload.withLock { hook in defer { hook = nil }; return hook }
            if let hook { await hook() }
        }
        func downloadFile(sha256: String) async throws -> Data { try await inner.downloadFile(sha256: sha256) }
        func deleteFile(sha256: String) async throws {
            try await inner.deleteFile(sha256: sha256)
            hooks.answers.withLock { $0[sha256] = false }
        }
        func fileStoredAt(sha256: String) async throws -> Date? {
            if hooks.storedAtFails.withLock({ $0 }) { throw SyncTransportError.retryLater(seconds: 30) }
            return try await inner.fileStoredAt(sha256: sha256)
        }
    }

    struct Phone {
        let name: String
        let store: LibraryStore
        let session: SyncSession
        let hooks = Hooks()

        init(_ name: String, cloud: SyncMemoryCloud, clock: SyncTestClock) async throws {
            self.name = name
            let catalog = try TestSupport.catalog()
            store = LibraryStore(root: TestSupport.tempDir().appendingPathComponent("Library-\(name)", isDirectory: true), catalog: catalog)
            try await store.load()
            session = SyncSession(store: store, transport: CachingTransport(inner: cloud.endpoint(name), hooks: hooks),
                                  catalog: catalog, deviceID: "dev\(name)", now: clock.reader())
        }

        @discardableResult
        func sync() async throws -> SyncReport { try await session.sync() }
    }

    static func settle(_ phones: [Phone]) async throws {
        for _ in 1...10 {
            var changed = false
            for phone in phones {
                let r = try await phone.sync()
                if r.applied || r.sent > 0 || r.received > 0 || r.unsent > 0 || r.problem != nil || r.waitingForFiles > 0 { changed = true }
            }
            if !changed { return }
        }
        Issue.record("did not settle")
    }

    // MARK: D24-02

    /// A photo deleted over a day ago comes back on B. B puts its file up; before B's record
    /// goes, C (judging on records alone) deletes the file. B's check before sending the record
    /// must ask the cloud, not its own memory of the upload, and put the file up again.
    @Test func aFileRemovedRightAfterItsUploadIsPutUpAgainBeforeTheRecordGoes() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await Phone("A", cloud: cloud, clock: clock)
        let b = try await Phone("B", cloud: cloud, clock: clock)
        let c = try await Phone("C", cloud: cloud, clock: clock)
        let photo = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 601)).photo
        let name = SyncRecord.photoName(photo.reducedFrom?.sha256 ?? photo.sha256)
        try await Self.settle([a, b, c])
        try await b.session.startOver()
        try await a.store.deletePhoto(photoId: photo.photoId)
        try await a.sync()
        try await c.sync()
        clock.advance(SyncSession.fileGrace + 60)
        try await a.sync()
        try #require(await !cloud.fileHashes.contains(photo.sha256))

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
        #expect(fileAtSave.withLock { $0 } == true, "B's live record went out pointing at a file C had just deleted")
        b.hooks.beforeSave.withLock { $0 = nil }
        try await Self.settle([b, a, c])
        #expect(await qa2LivePhotosWithoutAFile(cloud) == [])
    }

    // MARK: D24-03

    /// Clean-up asks when the cloud stored a file; a failed answer is not "it can't tell": the
    /// file stays until an answer comes, then goes.
    @Test func aFileWhoseStorageTimeCannotBeReadNowIsNotDeleted() async throws {
        let cloud = SyncMemoryCloud(clock: clock.reader())
        let a = try await Phone("A", cloud: cloud, clock: clock)
        let photo = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 602)).photo
        try await a.sync()
        try await a.store.deletePhoto(photoId: photo.photoId)
        try await a.sync()
        clock.advance(SyncSession.fileGrace + 60)
        a.hooks.storedAtFails.withLock { $0 = true }
        try await a.sync()
        #expect(await cloud.fileHashes.contains(photo.sha256), "deleted on an unknown storage time")
        a.hooks.storedAtFails.withLock { $0 = false }
        try await a.sync()
        #expect(await !cloud.fileHashes.contains(photo.sha256), "deferred, not kept forever")
    }

    // MARK: Fixtures in the cloud

    static func blob(_ text: String) -> Data { Data(text.utf8) }

    static func info(_ data: Data, size: (Int, Int), from source: String?) -> SyncFileInfo {
        SyncFileInfo(sha256: PhotoIngest.sha256Hex(data), mimeType: "image/jpeg", ext: "jpg", byteSize: data.count,
                     width: size.0, height: size.1,
                     reducedFrom: source.map { ReducedFrom(sha256: $0, byteSize: 999, width: 80, height: 40) })
    }

    /// Long before the test clock's now, so any deletion stamped with it is past every grace.
    static let old = SyncStamp(wall: 1_799_000_000_000, counter: 0, device: "N")

    // MARK: C24-01

    /// O (deleted) and R (live) share copy S; O also has H, the photo's best copy. Their
    /// deletion named both, so R's comeback shows the photo with O's copies: H is the copy a
    /// device without one downloads. Clean-up must not delete it as a dead record's file.
    @Test func aSharedPhotosBestCopyFromADeletedMemberStays() async throws {
        let cloud = SyncMemoryCloud()
        let origin = String(repeating: "e", count: 64)
        let sData = Self.blob("copy S"), hData = Self.blob("copy H, the bigger one")
        let s = Self.info(sData, size: (4, 2), from: nil)
        let h = Self.info(hData, size: (8, 4), from: origin)
        var o = SyncMergeTests.photo(ids: ["p-o"], file: h, at: Self.old)
        o.copies = PhotoSyncRecord.union([h], [Self.info(sData, size: (4, 2), from: origin)])
        var r = SyncMergeTests.photo(ids: ["p-r"], file: s, at: Self.old)
        let names = [SyncRecord.photoName(o.sourceHash), SyncRecord.photoName(r.sourceHash)].sorted()
        o.tomb = SyncTombstone(seen: o.version, at: Self.old, together: names)
        r.note = SyncRegister("back", SyncStamp(wall: Self.old.wall + 5, counter: 0, device: "M"))
        let n = cloud.endpoint("N")
        try await n.uploadFile(sha256: s.sha256, data: sData)
        try await n.uploadFile(sha256: h.sha256, data: hData)
        _ = try await n.save([SyncSave(envelope: try SyncEnvelope(.photo(o)), baseTag: nil),
                              SyncSave(envelope: try SyncEnvelope(.photo(r)), baseTag: nil)])
        var replica = SyncReplica()
        replica.merge(.photo(o))
        replica.merge(.photo(r))
        try #require(SyncPhotoGroups(replica).groups.first?.merged.file.sha256 == h.sha256, "the shown photo's best copy is H")

        let c = try await Phone("C", cloud: cloud, clock: clock)
        try await c.sync()
        try await c.sync()
        #expect(await cloud.fileHashes.contains(h.sha256), "the shown photo's best copy was deleted")
        #expect(await cloud.fileHashes.contains(s.sha256))
    }

    /// Two live records M and N share copy H but describe it differently: M as its own
    /// original, 8x4, with G (4x2, made from H) as its second copy; N as a 2x1 copy made from
    /// another original. Every record is valid on its own (each copy names its record's
    /// source), and each record ranks H first. The group keeps N's description of H (the one
    /// that knows a source), so the photo shown is G, the best copy of the group. Clean-up
    /// judged by the records' own bests alone deletes G as M's lesser copy. Only devices that
    /// disagree about a file's size get there; the projection then downloads G for the photo.
    /// QA review round 20, WEAK-TEST 3: only `groupBest` keeps G here (`shown` keeps both
    /// records live, not which copy of theirs is best).
    @Test func aGroupsBestCopyStaysWhenNoMemberRanksItFirst() async throws {
        let cloud = SyncMemoryCloud()
        let gData = Self.blob("copy G of a shared photo"), hData = Self.blob("copy H of a shared photo")
        let hBig = Self.info(hData, size: (8, 4), from: nil)
        let g = Self.info(gData, size: (4, 2), from: hBig.sha256)
        let hSmall = Self.info(hData, size: (2, 1), from: String(repeating: "b", count: 64))
        var m = SyncMergeTests.photo(ids: ["p-m"], file: hBig, at: Self.old)
        m.copies = PhotoSyncRecord.union([hBig], [g])
        let n = SyncMergeTests.photo(ids: ["p-n"], file: hSmall, at: Self.old)
        try #require(try SyncEnvelope(.photo(m)).decoded() != nil && SyncEnvelope(.photo(n)).decoded() != nil, "both records are valid")
        var replica = SyncReplica()
        replica.merge(.photo(m))
        replica.merge(.photo(n))
        let groups = SyncPhotoGroups(replica).groups
        try #require(groups.count == 1 && groups[0].members.count == 2)
        try #require(groups[0].merged.file.sha256 == g.sha256, "the shown photo's best copy is G")
        try #require(m.file.sha256 == hBig.sha256 && n.file.sha256 == hBig.sha256, "each record ranks H first")

        let writer = cloud.endpoint("N")
        try await writer.uploadFile(sha256: g.sha256, data: gData)
        try await writer.uploadFile(sha256: hBig.sha256, data: hData)
        _ = try await writer.save([SyncSave(envelope: try SyncEnvelope(.photo(m)), baseTag: nil),
                                   SyncSave(envelope: try SyncEnvelope(.photo(n)), baseTag: nil)])
        let c = try await Phone("C", cloud: cloud, clock: clock)
        try await c.sync()
        try await c.sync()
        #expect(try await c.session.deviceState()?.replica.unreadable.isEmpty == true, "clean-up ran on a readable view")
        #expect(await cloud.fileHashes.contains(g.sha256), "the shown photo's best copy was deleted")
        #expect(await cloud.fileHashes.contains(hBig.sha256))
    }

    // MARK: C24-07

    /// One live photo with copies S and a better H; the cloud's H is damaged (its bytes do not
    /// match its name). Clean-up deletes a copy that is not the best only once the best is
    /// there and sound; a damaged H is not, so S stays. With a sound H, S goes as before.
    @Test(arguments: [true, false])
    func aCopyIsNotDeletedForABestCopyTheCloudHoldsDamaged(_ damaged: Bool) async throws {
        let cloud = SyncMemoryCloud()
        let origin = String(repeating: "f", count: 64)
        let sData = Self.blob("copy S of f"), hData = Self.blob("copy H of f, bigger")
        let s = Self.info(sData, size: (4, 2), from: origin)
        let h = Self.info(hData, size: (8, 4), from: origin)
        var p = SyncMergeTests.photo(ids: ["p-f"], file: h, at: Self.old)
        p.copies = PhotoSyncRecord.union([h], [s])
        let n = cloud.endpoint("N")
        try await n.uploadFile(sha256: s.sha256, data: sData)
        try await n.uploadFile(sha256: h.sha256, data: damaged ? Self.blob("not what its name says") : hData)
        _ = try await n.save([SyncSave(envelope: try SyncEnvelope(.photo(p)), baseTag: nil)])

        let c = try await Phone("C", cloud: cloud, clock: clock)
        try await c.sync()
        try await c.sync()
        if damaged {
            #expect(await cloud.fileHashes.contains(s.sha256), "the only sound copy was deleted for a damaged best one")
        } else {
            #expect(await !cloud.fileHashes.contains(s.sha256), "a copy no longer needed still goes")
        }
        #expect(await cloud.fileHashes.contains(h.sha256))
    }
}
