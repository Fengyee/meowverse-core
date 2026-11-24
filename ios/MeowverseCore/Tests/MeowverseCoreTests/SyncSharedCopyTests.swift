import Foundation
import Testing
@testable import MeowverseCore

/// One stored copy, two photo records (round-12 audit CLOUDKIT-1). Device A imports a wide photo
/// and keeps a reduced copy R (`reducedFrom` = the original O); 「分享原文件」 hands R out byte for
/// byte, and device B imports those bytes whole, before it has A's record. Sync names records by
/// source, so the cloud holds `photo.O {copies: [R]}` and `photo.R {copies: [R]}`; the library
/// counts equal stored bytes as one photo. Before the fix, building B's library put two photos
/// with sha R side by side, `applySynced` refused it as inconsistent on every cycle, and neither
/// device ever showed an edit made elsewhere again.
@Suite struct SyncSharedCopyTests {
    let clock = SyncTestClock()

    /// A's photo, and B holding the same stored bytes under its own source (B has not synced yet).
    func sharedCopy(_ cloud: SyncMemoryCloud = SyncMemoryCloud()) async throws -> (a: SyncDevice, b: SyncDevice, copy: String) {
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        let b = try await SyncDevice("B", cloud: cloud, clock: clock)
        _ = try await a.store.importPhotos([try SyncCheck.wideDraft(seed: 1, maxPixel: 2048, asset: "asset-A", cloud: "cloud-A")])
        let mine = try await a.onlyPhoto()
        try #require(mine.reducedFrom != nil, "A keeps a reduced copy")
        let url = try #require(await a.store.originalURL(photoId: mine.photoId))
        var shared = try PhotoIngest.makeDraft(data: try Data(contentsOf: url), filename: "shared.jpg", reduce: true, maxPixel: 2048)
        try #require(shared.sha256 == mine.sha256 && shared.reducedFrom == nil, "B stores the very same bytes, as a source")
        // Saved into B's Photos on the way, it is another asset there.
        shared.assetIdentifier = "asset-B"
        shared.cloudIdentifier = "cloud-B"
        _ = try await a.store.editPhoto(photoId: mine.photoId, PhotoEdit(note: "from A"))
        try await a.sync()
        clock.advance()
        _ = try await b.store.importPhotos([shared])
        return (a, b, mine.sha256)
    }

    /// What two devices must agree on about one photo. The stored copy's own facts (`reducedFrom`)
    /// stay each device's: A made R from O, B imported R whole.
    func shown(_ device: SyncDevice) async throws -> String {
        let p = try await device.onlyPhoto()
        return "\(p.photoId) note='\(p.note)' fav=\(p.favorite) day=\(p.captureDate ?? "-")/\(p.captureDateSource.rawValue) imported=\(p.importedAt.timeIntervalSince1970)"
    }

    @Test func aStoredCopySharedToAnotherDeviceIsOnePhotoThereAndEditsStillArrive() async throws {
        let (a, b, copy) = try await sharedCopy()
        try await SyncCheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(LibraryStore.isConsistent(state))
            #expect(state.photos.map(\.sha256) == [copy], "\(device.name) shows the photo once")
        }
        #expect(try await a.onlyPhoto().reducedFrom != nil, "A's copy still says it was made from the original")
        #expect(try await b.onlyPhoto().reducedFrom == nil, "B's copy says what B knows of its own file")
        #expect(try await b.onlyPhoto().note == "from A")
        // Which Photos asset each device's photo is stays that device's: B's is not A's.
        let (onA, onB0) = (try await a.onlyPhoto(), try await b.onlyPhoto())
        #expect(onA.cloudIdentifier == "cloud-A" && onA.assetIdentifier == "asset-A")
        #expect(onB0.cloudIdentifier == "cloud-B" && onB0.assetIdentifier == "asset-B")

        // Edits made on either device after that still reach the other one.
        let id = try await b.onlyPhoto().photoId
        _ = try await b.store.editPhoto(photoId: id, PhotoEdit(note: "from B, later"))
        try await SyncCheck.settle([a, b])
        #expect(try await a.onlyPhoto().note == "from B, later")
        clock.advance()
        _ = try await a.store.editPhoto(photoId: try await a.onlyPhoto().photoId, PhotoEdit(favorite: true, captureDate: .set("2024-02-03")))
        try await SyncCheck.settle([a, b])
        #expect(try await b.onlyPhoto().favorite)
        let onB = try await b.onlyPhoto()
        #expect(onB.captureDate == "2024-02-03" && onB.captureDateSource == .user)
        let (shownA, shownB) = (try await shown(a), try await shown(b))
        #expect(shownA == shownB)
    }

    @Test func aDeviceThatJoinsLaterShowsTheSharedCopyOnce() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b, copy) = try await sharedCopy(cloud)
        try await SyncCheck.settle([a, b])
        let c = try await SyncDevice("C", cloud: cloud, clock: clock)
        try await SyncCheck.settle([a, b, c])
        let state = await c.state()
        #expect(LibraryStore.isConsistent(state))
        #expect(state.photos.map(\.sha256) == [copy])
        #expect(state.photos.first?.reducedFrom != nil, "the copy's known history (made from O) is kept, not B's guess")
        let (shownC, shownA) = (try await shown(c), try await shown(a))
        #expect(shownC == shownA)
    }

    @Test(arguments: ["A", "B"])
    func deletingTheSharedPhotoOnEitherDeviceDeletesItOnEveryDevice(_ deleter: String) async throws {
        let cloud = SyncMemoryCloud()
        let (a, b, _) = try await sharedCopy(cloud)
        let c = try await SyncDevice("C", cloud: cloud, clock: clock)
        try await SyncCheck.settle([a, b, c])
        let device = deleter == "A" ? a : b
        try await device.store.deletePhotos(photoIds: [try await device.onlyPhoto().photoId])
        try await device.session.captureLocalEdits()
        clock.advance()
        try await SyncCheck.settle([a, b, c])
        for each in [a, b, c] {
            #expect(await each.state().photos.isEmpty, "\(each.name) no longer shows it")
        }
    }

    @Test func piecesMadeFromTheSharedPhotoOnBothDevicesLinkTheOnePhoto() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        let b = try await SyncDevice("B", cloud: cloud, clock: clock)
        let wide = try SyncCheck.wideDraft(seed: 2, maxPixel: 2048)
        _ = try await a.store.commitNewFurniture(draft: wide, placement: SyncCheck.spot(0), displayName: "A's chair", decision: .manual)
        let mine = try await a.onlyPhoto()
        let url = try #require(await a.store.originalURL(photoId: mine.photoId))
        let shared = try PhotoIngest.makeDraft(data: try Data(contentsOf: url), filename: "shared.jpg", reduce: true, maxPixel: 2048)
        try await a.sync()
        _ = try await b.store.commitNewFurniture(draft: shared, placement: SyncCheck.spot(1), displayName: "B's chair", decision: .manual)
        try await SyncCheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(LibraryStore.isConsistent(state))
            #expect(state.photos.count == 1)
            let photo = try #require(state.photos.first?.photoId)
            #expect(state.items.map(\.displayName).sorted() == ["A's chair", "B's chair"])
            #expect(state.items.allSatisfy { $0.sources.map(\.photoId) == [photo] }, "\(device.name): both pieces show the photo")
        }
    }

    /// The shared copy is only one way two records come to hold one stored file; the projection
    /// itself must never build a library the store refuses, whatever the records say.
    @Test func twoFreshRecordsWithOneCopyProjectToOnePhoto() throws {
        let copy = SyncFileInfo(sha256: String(repeating: "a", count: 64), mimeType: "image/jpeg", ext: "jpg",
                                byteSize: 10, width: 4, height: 2, reducedFrom: nil)
        let reduced = SyncFileInfo(sha256: copy.sha256, mimeType: "image/jpeg", ext: "jpg", byteSize: 10, width: 4, height: 2,
                                   reducedFrom: ReducedFrom(sha256: String(repeating: "b", count: 64), byteSize: 99, width: 8, height: 4))
        func record(_ file: SyncFileInfo, id: String, at wall: Int64, note: String) -> SyncRecord {
            let s = SyncStamp(wall: wall, counter: 0, device: "x")
            return .photo(PhotoSyncRecord(sourceHash: file.sourceHash, photoIds: [id], importedAt: Date(timeIntervalSince1970: Double(wall)),
                                          copies: [file], filename: SyncRegister(nil, .zero), exifDay: SyncRegister(nil, .zero),
                                          date: SyncRegister(.followFile, .zero), favorite: SyncRegister(false, .zero),
                                          note: SyncRegister(note, s), cloudIdentifier: SyncRegister(nil, .zero), tomb: nil))
        }
        var replica = SyncReplica()
        replica.merge(record(copy, id: "p-b", at: 20, note: "newer"))
        replica.merge(record(reduced, id: "p-a", at: 10, note: "older"))
        let staged = SyncIncomingFile(info: copy, stagedFile: "sync-incoming/x", stagedThumbnail: "sync-incoming/x.jpg")
        let result = SyncProjection.project(replica, local: AppState.empty, downloaded: [copy.sha256: staged])
        #expect(LibraryStore.isConsistent(result.state))
        #expect(result.state.photos.map(\.photoId) == ["p-a"], "the smallest id, as for any merged photo")
        #expect(result.state.photos.first?.note == "newer", "the newer edit, whichever record holds it")
        #expect(result.writes.count == 1)
    }

    /// Two different files under one photo id (a device that kept the id while its stored copy
    /// changed, say): the store keeps ids unique, so one waits, said, and the rest comes in.
    @Test func twoPhotosClaimingOneIdShowOneAndHoldTheOtherBack() throws {
        func file(_ c: Character) -> SyncFileInfo {
            SyncFileInfo(sha256: String(repeating: c, count: 64), mimeType: "image/jpeg", ext: "jpg", byteSize: 10, width: 4, height: 2, reducedFrom: nil)
        }
        func record(_ file: SyncFileInfo, id: String, at wall: Int64) -> SyncRecord {
            .photo(SyncMergeTests.photo(ids: [id], file: file, at: SyncStamp(wall: wall, counter: 0, device: "x"),
                                        importedAt: Date(timeIntervalSince1970: Double(wall))))
        }
        var replica = SyncReplica()
        replica.merge(record(file("a"), id: "same", at: 10))
        replica.merge(record(file("b"), id: "same", at: 20))
        replica.merge(record(file("c"), id: "other", at: 30))
        var downloaded: [String: SyncIncomingFile] = [:]
        for c in ["a", "b", "c"] as [Character] {
            downloaded[file(c).sha256] = SyncIncomingFile(info: file(c), stagedFile: "sync-incoming/\(c)", stagedThumbnail: "sync-incoming/\(c).jpg")
        }
        let result = SyncProjection.project(replica, local: AppState.empty, downloaded: downloaded)
        #expect(LibraryStore.isConsistent(result.state))
        #expect(result.state.photos.map(\.sha256) == [file("a").sha256, file("c").sha256], "the first imported, and the unrelated one")
        #expect(result.heldBack == [SyncRecord.photoName(file("b").sha256)])
        #expect(result.quarantined == [SyncRecord.photoName(file("b").sha256)], "not from a newer version")
    }

    /// A photo here whose group has a record this build cannot read stays exactly as this
    /// device has it, like a photo whose only record is a newer version (§9): not the join with
    /// that record's last readable version, which a newer build may since have changed.
    @Test func aPhotoHereStaysAsItIsWhileAnotherRecordOfItsCopyIsNewer() async throws {
        let store = LibraryStore(root: TestSupport.tempDir(), catalog: try TestSupport.catalog())
        try await store.load()
        _ = try await store.importPhotos([try TestSupport.draft(seed: 1)])
        let local = await store.snapshot()
        let own = local.photos[0]
        let s = SyncStamp(wall: 1_800_000_000_000, counter: 0, device: "x")
        var replica = SyncReplica()
        replica.merge(.photo(SyncMergeTests.photo(ids: [own.photoId], file: SyncFileInfo(own), at: s)))
        var made = SyncFileInfo(own)
        made.reducedFrom = ReducedFrom(sha256: String(repeating: "9", count: 64), byteSize: 99, width: 8, height: 4)
        replica.merge(.photo(SyncMergeTests.photo(ids: ["zz-other"], file: made,
                                                  at: SyncStamp(wall: s.wall + 1, counter: 0, device: "y"), note: "last readable")))
        let theirs = SyncRecord.photoName(made.sourceHash)
        replica.merge(SyncEnvelope(type: "MVPhoto", name: theirs, format: SyncEnvelope.currentFormat + 1, payload: Data("{}".utf8)))
        let result = SyncProjection.project(replica, local: local)
        #expect(result.state.photos == local.photos)
        #expect(result.heldBack == [theirs], "said once, by the record that cannot be read")
        #expect(result.quarantined.isEmpty)
    }

    /// The shared copy settled, then A's record rewritten by a newer build that B cannot read.
    /// Returns that record's name and B's own record's name.
    func newerOnA(_ cloud: SyncMemoryCloud, _ a: SyncDevice, _ b: SyncDevice) async throws -> (theirs: String, own: String) {
        try await SyncCheck.settle([a, b])
        let mine = try await a.onlyPhoto()
        let name = SyncRecord.photoName(mine.reducedFrom?.sha256 ?? mine.sha256)
        let future = SyncEnvelope(type: "MVPhoto", name: name, format: SyncEnvelope.currentFormat + 1, payload: Data("{}".utf8))
        let tag = try #require(try await a.session.deviceState()?.tags[name])
        _ = try await cloud.endpoint("N").save([SyncSave(envelope: future, baseTag: tag)])
        return (name, SyncRecord.photoName(mine.sha256))
    }

    /// A photo not here yet whose records this device has read, one of which then turns into a
    /// newer version: it is not shown from the other record alone (its id and values could
    /// change on the upgrade). It waits, said as from a newer version, and nothing downloads.
    /// (A device that never read the newer record cannot know it shares the copy, and shows
    /// the other one as any photo.)
    @Test func aPhotoNotHereYetWaitsWhileOneOfItsRecordsIsNewer() throws {
        let copy = SyncFileInfo(sha256: String(repeating: "a", count: 64), mimeType: "image/jpeg", ext: "jpg",
                                byteSize: 10, width: 4, height: 2, reducedFrom: nil)
        let reduced = SyncFileInfo(sha256: copy.sha256, mimeType: "image/jpeg", ext: "jpg", byteSize: 10, width: 4, height: 2,
                                   reducedFrom: ReducedFrom(sha256: String(repeating: "b", count: 64), byteSize: 99, width: 8, height: 4))
        let s = SyncStamp(wall: 10, counter: 0, device: "x")
        var replica = SyncReplica()
        replica.merge(.photo(SyncMergeTests.photo(ids: ["p-a"], file: reduced, at: s)))
        replica.merge(.photo(SyncMergeTests.photo(ids: ["p-b"], file: copy, at: s)))
        let theirs = SyncRecord.photoName(reduced.sourceHash), other = SyncRecord.photoName(copy.sourceHash)
        replica.merge(SyncEnvelope(type: "MVPhoto", name: theirs, format: SyncEnvelope.currentFormat + 1, payload: Data("{}".utf8)))
        let staged = SyncIncomingFile(info: copy, stagedFile: "sync-incoming/x", stagedThumbnail: "sync-incoming/x.jpg")
        let result = SyncProjection.project(replica, local: AppState.empty, downloaded: [copy.sha256: staged])
        #expect(result.state.photos.isEmpty)
        #expect(result.heldBack == [theirs], "said once, not also for \(other)")
        #expect(result.quarantined.isEmpty, "a newer version explains it")
        #expect(result.missingFiles.isEmpty && result.writes.isEmpty)
    }

    /// Deleting the photo on B while A's record is a newer version: B tombs its own record and
    /// leaves A's alone (it only has A's last readable version and never sends that record), so
    /// nothing waits to be sent forever.
    @Test func aSharedPhotoDeletedWhileOneRecordIsNewerLeavesNothingUnsent() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b, _) = try await sharedCopy(cloud)
        let (theirs, own) = try await newerOnA(cloud, a, b)
        try await b.sync()
        clock.advance()
        try await b.store.deletePhotos(photoIds: [try await b.onlyPhoto().photoId])
        let report = try await b.sync()
        let device = try #require(try await b.session.deviceState())
        #expect(report.unsent == 0, "dirty: \(device.dirty.sorted())")
        let replica = device.replica
        #expect(replica[own].map { !$0.isLive } == true, "B's own record is deleted")
        #expect(replica[theirs]?.isLive == true, "A's is not written")
    }

    /// A deleted record joins its copy's group only when it was deleted together with a member
    /// that came back. A's photo, with a note, is deleted everywhere; later B imports A's stored
    /// bytes (kept from a share) as a photo of its own. That is a new photo: the deleted one's
    /// note does not come back with it, on either device.
    @Test func aPhotoDeletedOnItsOwnDoesNotLendItsNoteToALaterImportOfItsCopy() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        let b = try await SyncDevice("B", cloud: cloud, clock: clock)
        _ = try await a.store.importPhotos([try SyncCheck.wideDraft(seed: 1, maxPixel: 2048)])
        let mine = try await a.onlyPhoto()
        _ = try await a.store.editPhoto(photoId: mine.photoId, PhotoEdit(favorite: true, note: "deleted with it"))
        let url = try #require(await a.store.originalURL(photoId: mine.photoId))
        let shared = try PhotoIngest.makeDraft(data: try Data(contentsOf: url), filename: "shared.jpg", reduce: true, maxPixel: 2048)
        try await SyncCheck.settle([a, b])
        clock.advance()
        try await a.store.deletePhotos(photoIds: [mine.photoId])
        try await SyncCheck.settle([a, b])
        try #require(await b.state().photos.isEmpty)
        clock.advance()
        _ = try await b.store.importPhotos([shared])
        try await SyncCheck.settle([a, b])
        for device in [a, b] {
            let p = try await device.onlyPhoto()
            #expect(p.note.isEmpty && !p.favorite, "\(device.name): note '\(p.note)', favourite \(p.favorite)")
        }
    }
}
