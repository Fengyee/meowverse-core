import Foundation
import Testing
@testable import MeowverseCore

/// QA round 12, task B (CLOUDKIT-1, CLOUDKIT-4), adversarial cases against 66c1994: photo records
/// that share one stored copy are shown as one photo (`SyncPhotoGroups`), and decoded values out
/// of range make a record unreadable (`SyncRecord.isInRange`).
@Suite struct QARound12SharedCopyTests {
    let clock = SyncTestClock()

    /// A's wide photo O (stored as the reduced copy R) and B holding R's bytes as a source of its
    /// own, imported before B fetched A's record. Same set-up as `SyncSharedCopyTests.sharedCopy`,
    /// with the device names as arguments so a device-id tie-break cannot decide a result, and
    /// optionally a busier library on B (a higher revision outranks A's offered values).
    func sharedCopy(_ cloud: SyncMemoryCloud, names: (String, String), busyB: Bool = false) async throws
        -> (a: SyncDevice, b: SyncDevice) {
        let a = try await SyncDevice(names.0, cloud: cloud, clock: clock)
        let b = try await SyncDevice(names.1, cloud: cloud, clock: clock)
        _ = try await a.store.importPhotos([try SyncCheck.wideDraft(seed: 1, maxPixel: 2048, asset: "asset-A", cloud: "cloud-A")])
        let mine = try await a.onlyPhoto()
        let url = try #require(await a.store.originalURL(photoId: mine.photoId))
        var shared = try PhotoIngest.makeDraft(data: try Data(contentsOf: url), filename: "shared.jpg", reduce: true, maxPixel: 2048)
        try #require(shared.sha256 == mine.sha256 && shared.reducedFrom == nil)
        shared.assetIdentifier = "asset-B"
        shared.cloudIdentifier = "cloud-B"
        try await a.sync()
        clock.advance()
        if busyB {
            for i in 0..<6 { _ = try await b.store.renameCat(catId: AppState.primaryCatId, name: "Cat \(i)") }
        }
        _ = try await b.store.importPhotos([shared])
        return (a, b)
    }

    // MARK: Provenance

    /// A user's confirmed day made on one device before the copy was shared stays the shown day
    /// everywhere: B's import only offers its values.
    @Test(arguments: [("A", "B"), ("B", "A")])
    func aDayConfirmedBeforeTheShareStaysTheDayEverywhere(_ names: (String, String)) async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice(names.0, cloud: cloud, clock: clock)
        let b = try await SyncDevice(names.1, cloud: cloud, clock: clock)
        _ = try await a.store.importPhotos([try SyncCheck.wideDraft(seed: 1, maxPixel: 2048)])
        let mine = try await a.onlyPhoto()
        _ = try await a.store.editPhoto(photoId: mine.photoId, PhotoEdit(captureDate: .set("2020-01-02")))
        let url = try #require(await a.store.originalURL(photoId: mine.photoId))
        let shared = try PhotoIngest.makeDraft(data: try Data(contentsOf: url), filename: "shared.jpg", reduce: true, maxPixel: 2048)
        try await a.sync()
        clock.advance()
        _ = try await b.store.importPhotos([shared])
        try await SyncCheck.settle([a, b])
        for device in [a, b] {
            let p = try await device.onlyPhoto()
            #expect(p.captureDate == "2020-01-02" && p.captureDateSource == .user, "\(device.name): \(p.captureDate ?? "-")/\(p.captureDateSource)")
        }
    }

    /// Control for the next test: one photo, one record. A deletion that did not see an edit made
    /// elsewhere loses to it, and the photo comes back with everything the record held, the
    /// confirmed day and the favourite included (docs/ICLOUD_SYNC.md §4, "unseen write wins").
    @Test func controlOneRecordComesBackWithItsConfirmedDay() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        let b = try await SyncDevice("B", cloud: cloud, clock: clock)
        _ = try await a.store.importPhotos([try SyncCheck.wideDraft(seed: 1, maxPixel: 2048)])
        try await SyncCheck.settle([a, b])
        clock.advance()
        _ = try await a.store.editPhoto(photoId: try await a.onlyPhoto().photoId, PhotoEdit(favorite: true, captureDate: .set("2020-01-02")))
        try await SyncCheck.settle([a, b])
        clock.advance()
        try await a.store.deletePhotos(photoIds: [try await a.onlyPhoto().photoId])
        try await a.sync()
        clock.advance()
        _ = try await b.store.editPhoto(photoId: try await b.onlyPhoto().photoId, PhotoEdit(note: "unseen"))
        try await SyncCheck.settle([a, b])
        for device in [a, b] {
            let p = try await device.onlyPhoto()
            #expect(p.note == "unseen" && p.favorite && p.captureDate == "2020-01-02" && p.captureDateSource == .user)
        }
    }

    /// The same interleaving on the shared copy. The device that confirmed the day and set the
    /// favourite (both written into its own record) deletes the photo, which tombs both records.
    /// The other device, not having seen the deletion, edits the note, which revives only its
    /// own record. The photo comes back, as in the control, but showing only the reviving
    /// record: the confirmed day and the favourite are gone, on every device, and the day falls
    /// back to the file's.
    @Test(arguments: [("A", "B"), ("B", "A")])
    func anUnseenEditThatBringsTheSharedPhotoBackKeepsTheConfirmedDay(_ names: (String, String)) async throws {
        for deleterIsA in [true, false] {
            let cloud = SyncMemoryCloud()
            let (a, b) = try await sharedCopy(cloud, names: names)
            try await SyncCheck.settle([a, b])
            let (deleter, editor) = deleterIsA ? (a, b) : (b, a)
            clock.advance()
            _ = try await deleter.store.editPhoto(photoId: try await deleter.onlyPhoto().photoId,
                                                  PhotoEdit(favorite: true, captureDate: .set("2020-01-02")))
            try await SyncCheck.settle([a, b])
            let before = try await editor.onlyPhoto()
            try #require(before.captureDate == "2020-01-02" && before.favorite, "the edit reached \(editor.name)")
            clock.advance()
            try await deleter.store.deletePhotos(photoIds: [try await deleter.onlyPhoto().photoId])
            try await deleter.sync()
            clock.advance()
            _ = try await editor.store.editPhoto(photoId: before.photoId, PhotoEdit(note: "unseen"))
            try await SyncCheck.settle([a, b])
            for device in [a, b] {
                let p = try await device.onlyPhoto()
                #expect(p.note == "unseen", "\(device.name)")
                #expect(p.favorite, "\(device.name) [\(names.0)/\(names.1) deleter \(deleter.name)]: favourite lost")
                #expect(p.captureDate == "2020-01-02" && p.captureDateSource == .user,
                        "\(device.name) [\(names.0)/\(names.1) deleter \(deleter.name)]: confirmed day lost, shows \(p.captureDate ?? "-")/\(p.captureDateSource)")
            }
        }
    }

    /// A device that joins later takes the copy's history from A's record (`reducedFrom` = O).
    /// Which Photos asset that photo is should come from the same record, and not change on the
    /// next cycle: the fresh-photo branch takes `cloudIdentifier` from the group's join, the
    /// local-photo branch from the device's own record.
    @Test(arguments: [("A", "B"), ("B", "A")])
    func aLaterDevicesPhotoKeepsOneCloudIdentifierFromTheRecordItsHistoryCameFrom(_ names: (String, String)) async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await sharedCopy(cloud, names: names, busyB: true)
        try await SyncCheck.settle([a, b])
        let c = try await SyncDevice("C", cloud: cloud, clock: clock)
        try await c.sync()
        let first = try await c.onlyPhoto()
        try await SyncCheck.settle([a, b, c])
        let later = try await c.onlyPhoto()
        #expect(first.reducedFrom != nil && later.reducedFrom != nil)
        #expect(first.cloudIdentifier == later.cloudIdentifier,
                "C's photo changed asset between cycles: \(first.cloudIdentifier ?? "-") then \(later.cloudIdentifier ?? "-")")
        #expect(first.cloudIdentifier == "cloud-A", "made from O, it is A's asset; got \(first.cloudIdentifier ?? "-")")
    }

    /// The group splits on B when A's record turns into a version B cannot read (a newer build on
    /// A rewrote it). Returns B's photo before and after, and whether B's own record ever learned
    /// the id B showed the photo under.
    func split(_ names: (String, String)) async throws -> (before: PhotoRecord, after: PhotoRecord, ownIds: [String], held: Bool) {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await sharedCopy(cloud, names: names)
        try await SyncCheck.settle([a, b])
        clock.advance()
        _ = try await a.store.editPhoto(photoId: try await a.onlyPhoto().photoId, PhotoEdit(note: "from A"))
        try await SyncCheck.settle([a, b])
        let before = try await b.onlyPhoto()
        try #require(before.note == "from A")
        guard case .photo(let own)? = try await b.session.deviceState()?.replica[SyncRecord.photoName(before.sha256)] else {
            throw CancellationError()
        }
        let mine = try await a.onlyPhoto()
        let name = SyncRecord.photoName(mine.reducedFrom?.sha256 ?? mine.sha256)
        let future = SyncEnvelope(type: "MVPhoto", name: name, format: SyncEnvelope.currentFormat + 1, payload: Data("{}".utf8))
        let tag = try #require(try await a.session.deviceState()?.tags[name])
        _ = try await cloud.endpoint("N").save([SyncSave(envelope: future, baseTag: tag)])
        let report = try await b.sync()
        return (before, try await b.onlyPhoto(), own.photoIds, report.heldBack.contains(name))
    }

    /// A held-back record's photo "stays as this device has it" (docs/ICLOUD_SYNC.md §9). Here
    /// B's photo is then shown from its own record alone and drops what came through A's: the
    /// note A wrote disappears from B's library while A's record is held back.
    @Test(arguments: [("A", "B"), ("B", "A")])
    func aNewerVersionOfTheOtherRecordLeavesTheSharedPhotoAsItIs(_ names: (String, String)) async throws {
        let (_, after, _, held) = try await split(names)
        #expect(held)
        #expect(after.note == "from A", "B shows \(after.note.isEmpty ? "no note" : after.note) while A's record is held back")
    }

    /// The id every device shows the group under (the smallest of all its records' ids) lives only
    /// in the merged view: B's own record keeps only B's id. When A's id is the smaller one, the
    /// split renames B's photo back to B's id (and every link and observation with it), and an
    /// upgrade renames it again. Photo ids are random, so this tries until A's id is the smaller.
    @Test func aSplitKeepsThePhotosId() async throws {
        for _ in 0..<8 {
            let (before, after, ownIds, _) = try await split(("A", "B"))
            guard !ownIds.contains(before.photoId) else { continue }
            #expect(after.photoId == before.photoId, "B's photo \(before.photoId) became \(after.photoId); its record knows \(ownIds)")
            return
        }
        Issue.record("A's id was never the smaller in 8 tries")
    }

    // MARK: The staged quarantine

    /// Drives `SyncProjection.project` into its quarantine loop, which no other test reaches
    /// (with the loop removed, every Sync and QA test still passes). Two photos here; a record
    /// names the first one under the second one's id (a bug, or a damaged record). The build
    /// shows both under that id, the store would refuse it, and stage 1 holds back that record:
    /// the first photo stays as it is, and an unrelated photo from elsewhere still comes in.
    @Test func aRecordThatRenamesAPhotoOntoAnotherIsHeldBackAndTheRestComesIn() async throws {
        let store = LibraryStore(root: TestSupport.tempDir(), catalog: try TestSupport.catalog())
        try await store.load()
        _ = try await store.importPhotos([try TestSupport.draft(seed: 1), try TestSupport.draft(seed: 2)])
        var local = await store.snapshot()
        local.photos.sort { $0.photoId > $1.photoId } // the larger id is shown first
        let (first, second) = (local.photos[0], local.photos[1])
        try #require(LibraryStore.isConsistent(local))
        let s = SyncStamp(wall: 1_800_000_000_000, counter: 0, device: "x")
        var renaming = SyncMergeTests.photo(ids: [first.photoId, second.photoId], file: SyncFileInfo(first), at: s)
        renaming.note = SyncRegister("renamed", s)
        var replica = SyncReplica()
        replica.merge(.photo(renaming))
        let other = SyncFileInfo(sha256: String(repeating: "e", count: 64), mimeType: "image/jpeg", ext: "jpg",
                                 byteSize: 10, width: 4, height: 2, reducedFrom: nil)
        replica.merge(.photo(SyncMergeTests.photo(ids: ["elsewhere"], file: other, at: s)))
        let staged = SyncIncomingFile(info: other, stagedFile: "sync-incoming/e", stagedThumbnail: "sync-incoming/e.jpg")

        let result = SyncProjection.project(replica, local: local, downloaded: [other.sha256: staged])
        #expect(LibraryStore.isConsistent(result.state))
        #expect(result.quarantined == [SyncRecord.photoName(SyncFileInfo(first).sourceHash)])
        #expect(result.heldBack.contains(SyncRecord.photoName(SyncFileInfo(first).sourceHash)))
        #expect(Set(result.state.photos.map(\.photoId)) == [first.photoId, second.photoId, "elsewhere"])
        #expect(result.state.photos.first { $0.photoId == first.photoId }?.note == "", "the first photo as it is")
    }

    /// `sync-state.json` keeps the replica's records as envelopes and reads each with
    /// `SyncEnvelope.decoded()`, which now applies the range check and throws for the whole file
    /// (`SyncReplica.init(from:)`). A record that build 7 merged without the check (it had none)
    /// therefore makes the upgraded device's whole sync file unreadable: it starts over as a
    /// first sync and its unsent edits become offers (docs/ICLOUD_SYNC.md §9; tech-craft: "同步文件
    /// 解不出会从头合并、丢掉未发的修改"). One bad record should be held back by itself here too,
    /// like a newer format.
    @Test func aRecordAnOlderBuildMergedWithoutTheRangeCheckDoesNotLoseTheSyncFile() throws {
        var bad = SyncMergeTests.furniture(SyncStamp(wall: 5, counter: 0, device: "b"))
        bad.place.value.x = Int.max
        var device = SyncDeviceState(device: "devA")
        device.replica.merge(.furniture(bad)) // as build 7's `merge(envelope)` did
        device.dirty = ["cat.cat-1"]          // an edit not sent yet
        let reread = SyncDeviceState.decode(try device.encoded())
        #expect(reread != nil, "the device's sync file is unreadable as a whole")
        #expect(reread?.dirty == ["cat.cat-1"])
        #expect(reread.map { $0.replica.unreadable["furniture.f1"] != nil } == true, "the bad record is held back by itself")
    }

    // MARK: Links

    /// Both devices link their own photo (two ids, one stored copy) to the same piece before
    /// either has seen the other's record. The piece shows one source, nothing waits, and the
    /// library stays consistent.
    @Test(arguments: [("A", "B"), ("B", "A")])
    func oneSharedPieceLinkedToBothIdsShowsOneSource(_ names: (String, String)) async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice(names.0, cloud: cloud, clock: clock)
        let b = try await SyncDevice(names.1, cloud: cloud, clock: clock)
        let chair = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: 9), placement: SyncCheck.chair,
                                                         displayName: "Chair", decision: .manual)
        try await SyncCheck.settle([a, b])
        _ = try await a.store.importPhotos([try SyncCheck.wideDraft(seed: 1, maxPixel: 2048)])
        let mine = try #require(await a.state().photos.first { $0.reducedFrom != nil })
        _ = try await a.store.linkPhotos(photoIds: [mine.photoId], toInstance: chair.instanceId)
        let url = try #require(await a.store.originalURL(photoId: mine.photoId))
        let shared = try PhotoIngest.makeDraft(data: try Data(contentsOf: url), filename: "shared.jpg", reduce: true, maxPixel: 2048)
        try await a.sync()
        clock.advance()
        _ = try await b.store.importPhotos([shared])
        let theirs = try #require(await b.state().photos.first { $0.sha256 == shared.sha256 })
        _ = try await b.store.linkPhotos(photoIds: [theirs.photoId], toInstance: chair.instanceId)
        try await SyncCheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(LibraryStore.isConsistent(state))
            #expect(state.photos.filter { $0.sha256 == shared.sha256 }.count == 1)
            let piece = try #require(state.items.first { $0.instanceId == chair.instanceId })
            let shown = try #require(state.photos.first { $0.sha256 == shared.sha256 }).photoId
            #expect(piece.sources.map(\.photoId).filter { $0 == shown }.count == 1, "\(device.name): \(piece.sources.map(\.photoId))")
            let report = try await device.sync()
            #expect(report.pendingLinks.isEmpty && report.heldBack.isEmpty, "\(device.name): \(report.pendingLinks) \(report.heldBack)")
        }
        // Everything but the stored copy's own history (`reducedFrom`, by design each device's).
        func view(_ d: SyncDevice) async -> SyncCheck.View {
            var v = SyncCheck.view(await d.state())
            v.photos = v.photos.map { $0.replacing(#/ src=[0-9a-f]+/#, with: "") }
            return v
        }
        #expect(await view(a) == view(b))
    }

    /// The photo's file name is shared like its other fields; which one shows should not be the
    /// name the other device's import gave the shared copy. A's photo was picked as `wide-1.jpg`;
    /// B received A's stored copy as `shared.jpg`. Both names are offered (`SyncClock.seed(rank:)`),
    /// so the busier library's wins: here B's, and A's own photo is renamed to the share's name.
    /// `reducedFrom` already prefers the description that knows the copy's history; the name
    /// (and the EXIF day) could follow the same record.
    @Test(arguments: [("A", "B"), ("B", "A")])
    func theOriginalsFileNameIsNotReplacedByTheSharesName(_ names: (String, String)) async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await sharedCopy(cloud, names: names, busyB: true)
        try await SyncCheck.settle([a, b])
        for device in [a, b] {
            let p = try await device.onlyPhoto()
            #expect(p.filename == "wide-1.jpg", "\(device.name) shows \(p.filename ?? "-")")
        }
    }

    // MARK: Values (CLOUDKIT-4)

    static let hash = String(repeating: "c", count: 64)

    /// Honest values the range check must still accept: a web photo of unknown size (0), a
    /// 100 MB original behind a reduced copy, a 65 000 px panorama, a piece left of the origin.
    @Test func honestEdgeValuesStillRead() throws {
        let s = SyncStamp(wall: 1_800_000_000_000, counter: 3, device: "a")
        let web = SyncFileInfo(sha256: Self.hash, mimeType: "image/jpeg", ext: "jpg", byteSize: 10, width: 0, height: 0, reducedFrom: nil)
        #expect(try SyncEnvelope(.photo(SyncMergeTests.photo(ids: ["w"], file: web, at: s))).decoded() != nil)
        let pano = SyncFileInfo(sha256: String(repeating: "d", count: 64), mimeType: "image/jpeg", ext: "jpg", byteSize: 4_000_000,
                                width: 2048, height: 120,
                                reducedFrom: ReducedFrom(sha256: Self.hash, byteSize: PhotoIngest.maxBytes, width: 65_000, height: 3_800))
        #expect(try SyncEnvelope(.photo(SyncMergeTests.photo(ids: ["p"], file: pano, at: s))).decoded() != nil)
        #expect(try SyncEnvelope(.furniture(SyncMergeTests.furniture(s, x: -3))).decoded() != nil)
        // An offer's counter is a library revision, up to `LibraryStore.maxRevision`.
        var offered = SyncMergeTests.photo(ids: ["o"], file: web, at: s)
        offered.note = SyncRegister("n", SyncClock.seed(rank: LibraryStore.maxRevision))
        #expect(try SyncEnvelope(.photo(offered)).decoded() != nil)
    }

    /// Dates are the other decoded values that become integers: a first sync seeds a piece's
    /// stamp from `updatedAt` in milliseconds (`SyncClock.seed(_ date:)`, `Int64(…)`). They do not
    /// trap: records carry ISO 8601 text (`SyncCoding`), which holds no date anywhere near Int64
    /// milliseconds, so a piece written at 1e300 s arrives a few hundred thousand years ahead and
    /// a start over seeds from it. A regression check, end to end.
    @Test func aPieceDatedFarAheadDoesNotTrapTheNextFirstSync() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        let b = try await SyncDevice("B", cloud: cloud, clock: clock)
        let chair = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: 1), placement: SyncCheck.chair,
                                                         displayName: "Chair", decision: .manual)
        try await SyncCheck.settle([a, b])
        let stored = try #require(try await a.session.deviceState()?.replica["furniture.\(chair.instanceId)"])
        guard case .furniture(var bad) = stored else { Issue.record("no chair record"); return }
        bad.updatedAt = Date(timeIntervalSince1970: 1e300)
        bad.createdAt = Date(timeIntervalSince1970: 1e300)
        bad.name = SyncRegister("Far", SyncStamp(wall: SyncClock.millis(clock.now) + 10, counter: 0, device: "zz"))
        let envelope = try SyncEnvelope(.furniture(bad))
        let tag = try #require(try await a.session.deviceState()?.tags[envelope.name])
        _ = try await cloud.endpoint("N").save([SyncSave(envelope: envelope, baseTag: tag)])
        try await b.sync()
        let far = try #require(await b.state().items.first)
        #expect(far.displayName == "Far", "B shows the piece as the record says")
        #expect((far.updatedAt?.timeIntervalSince1970 ?? 0) < Double(Int64.max) / 1000, "arrives bounded by ISO 8601")
        try await b.session.startOver()
        try await b.sync()
        #expect(await b.state().items.first?.displayName == "Far")
    }

    /// A readable stamp may carry any wall time. One at `Int64.max` with the top counter is
    /// adopted, and every tick after it returns the same stamp: later edits on this device no
    /// longer order after earlier ones, a register between two of its own writes is settled by
    /// value bytes.
    @Test func theClockStillMovesAfterTheLargestReadableStamp() throws {
        let top = SyncStamp(wall: .max, counter: SyncStamp.maxCounter, device: "zz")
        #expect(top.isInRange, "a record carrying it is readable")
        var clock = SyncClock(device: "a")
        clock.observe(top)
        let first = clock.tick(now: Date(timeIntervalSince1970: 1_800_000_000))
        let second = clock.tick(now: Date(timeIntervalSince1970: 1_800_000_001))
        #expect(second > first, "\(first) then \(second)")
    }
}
