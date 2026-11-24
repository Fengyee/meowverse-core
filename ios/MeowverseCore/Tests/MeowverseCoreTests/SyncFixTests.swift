import Foundation
import Synchronization
import Testing
@testable import MeowverseCore

/// Fixes after the QA review of the sync core (2026-11-18): cases QA read but did not
/// reproduce, and the ones it could not verify. See docs/ICLOUD_SYNC.md.
@Suite struct SyncFixTests {
    let clock = SyncTestClock()

    func pair(_ cloud: SyncMemoryCloud, _ first: String = "A", _ second: String = "B") async throws -> (QADevice, QADevice) {
        (try await QADevice(first, cloud: cloud, clock: clock), try await QADevice(second, cloud: cloud, clock: clock))
    }

    // MARK: Deletions see versions, not one stamp

    /// The rule on records alone: a deletion hides what it saw of each device, and a version
    /// from a device it did not see brings the record back even when that version is older.
    @Test func aDeletionHidesOnlyTheVersionsItSawFromEachDevice() throws {
        func stamp(_ wall: Int64, _ device: String) -> SyncStamp { SyncStamp(wall: wall, counter: 0, device: device) }
        var piece = SyncMergeTests.furniture(stamp(10, "a"))
        var moved = piece
        moved.place.value.x = 9
        moved.place.stamp = stamp(12, "b")
        piece.name = SyncRegister("renamed on a", stamp(20, "a"))
        // a deletes after its own rename at 20 but never saw b's move at 12.
        var deleted = piece
        deleted.tomb = SyncTombstone(seen: SyncRecord.furniture(piece).version, at: stamp(30, "a"))
        #expect(!SyncRecord.furniture(deleted).isLive)
        let merged = try #require(SyncRecord.furniture(deleted).joined(.furniture(moved)))
        #expect(merged.isLive, "b's move is a version the deletion did not see")
        #expect(merged == SyncRecord.furniture(moved).joined(.furniture(deleted)))
        // A version that only adds (an import of a photo already known) counts as well.
        var photo = SyncMergeTests.photo(ids: ["p-a"], file: SyncMergeTests.file("s1", 512), at: stamp(10, "a"))
        var imported = photo
        imported.photoIds = ["p-a", "p-b"]
        imported.edits.add(stamp(11, "b"))
        photo.tomb = SyncTombstone(seen: SyncRecord.photo(photo).version, at: stamp(40, "a"))
        #expect(SyncRecord.photo(photo).joined(.photo(imported))?.isLive == true)
        // Two deletions together hide what either saw.
        var other = imported
        other.tomb = SyncTombstone(seen: SyncRecord.photo(imported).version, at: stamp(41, "b"))
        let both = try #require(SyncRecord.photo(photo).joined(.photo(other)))
        #expect(!both.isLive)
        #expect(both == SyncRecord.photo(other).joined(.photo(photo)))
    }

    /// Records written before deletions kept a version (no `edits`, `seen` one stamp) still read:
    /// a local build with sync on may have put them in a real iCloud.
    @Test func recordsFromBeforeVersionVectorsStillRead() throws {
        let s = SyncStamp(wall: 10, counter: 0, device: "a"), at = SyncStamp(wall: 30, counter: 0, device: "a")
        var piece = SyncMergeTests.furniture(s)
        piece.tomb = SyncTombstone(seen: s, at: at)
        var json = try #require(try JSONSerialization.jsonObject(with: SyncCoding.encoder().encode(piece)) as? [String: Any])
        json["edits"] = nil
        json["tomb"] = ["seen": ["w": 10, "c": 0, "d": "a"], "at": ["w": 30, "c": 0, "d": "a"]]
        let old = try JSONSerialization.data(withJSONObject: json)
        let read = try SyncCoding.decoder().decode(FurnitureSyncRecord.self, from: old)
        #expect(read == piece)
        #expect(!SyncRecord.furniture(read).isLive)
    }

    /// Sync's own file from before this round (with `uploadedFiles`, without `collectedFiles`)
    /// still reads, so an edit waiting to be sent is not dropped by a fresh start.
    @Test func syncsOwnFileFromBeforeStillReads() throws {
        var device = SyncDeviceState(device: "devA")
        device.dirty = ["room.r1"]
        var json = try #require(try JSONSerialization.jsonObject(with: device.encoded()) as? [String: Any])
        json["collectedFiles"] = nil
        json["uploadedFiles"] = ["abc"]
        let read = try #require(SyncDeviceState.decode(try JSONSerialization.data(withJSONObject: json)))
        #expect(read.dirty == ["room.r1"] && read.collectedFiles.isEmpty)
    }

    // MARK: First sync again

    /// `turningSyncOnAgainKeepsWhatTheCloudDeletedMeanwhile` with the roles swapped: the device
    /// with the smaller id turns sync on again, so the result cannot come from the id order.
    @Test func turningSyncOnAgainKeepsWhatTheCloudDeletedWhicheverDeviceIdIsLarger() async throws {
        for (keeper, deleter) in [("A", "B"), ("B", "A")] {
            let cloud = SyncMemoryCloud()
            let (k, d) = try await pair(cloud, keeper, deleter)
            let chair = try await d.store.commitNewFurniture(draft: try TestSupport.draft(seed: 1), placement: SyncCheck.chair,
                                                             displayName: "Chair", decision: .manual)
            let photo = try #require(chair.sources.first?.photoId)
            try await QACheck.settle([d, k])
            try await k.session.startOver()
            try await d.store.deletePhoto(photoId: photo)
            try await d.store.removeFurniture(instanceId: chair.instanceId)
            try await d.sync()
            try await QACheck.settle([k, d])
            for device in [k, d] {
                let state = await device.state()
                #expect(state.photos.map(\.photoId) == [photo] && state.items.map(\.instanceId) == [chair.instanceId],
                        "\(device.name), keeper \(keeper)")
            }
            await QACheck.expectConverged([k, d])
        }
    }

    // MARK: Links and deleted photos

    /// B links a photo to a lamp while A, not having heard, deletes the photo: the link is a use
    /// of the photo the deletion never saw, so the photo comes back with the link on both.
    @Test func aPhotoLinkedWhileItWasDeletedElsewhereComesBackWithTheLink() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let chair = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: 81), placement: SyncCheck.chair,
                                                         displayName: "Chair", decision: .manual)
        let photo = try #require(chair.sources.first?.photoId)
        let lamp = try await b.store.addFurniture(placement: SyncCheck.spot(1), displayName: "Lamp")
        try await QACheck.settle([a, b])
        try await a.store.deletePhoto(photoId: photo)
        try await a.session.captureLocalEdits()
        clock.advance()
        _ = try await b.store.linkPhoto(photoId: photo, toInstance: lamp.instanceId)
        try await b.session.captureLocalEdits()
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(state.photos.map(\.photoId) == [photo], "\(device.name): the linked photo was deleted")
            #expect(state.allFurniture.first { $0.instanceId == lamp.instanceId }?.sources.map(\.photoId) == [photo], "\(device.name)")
        }
        #expect(await a.filesAreWhole() == [])
        #expect(await b.filesAreWhole() == [])
        await QACheck.expectConverged([a, b])
    }

    /// A link to a photo every device has deleted is not "waiting": that photo will not arrive.
    @Test func aLinkToADeletedPhotoIsNotCountedAsWaiting() throws {
        let s = SyncStamp(wall: 10, counter: 0, device: "a")
        var photo = SyncMergeTests.photo(ids: ["p-gone"], file: SyncMergeTests.file("s9", 512), at: s)
        photo.tomb = SyncTombstone(seen: SyncRecord.photo(photo).version, at: SyncStamp(wall: 20, counter: 0, device: "a"))
        var piece = SyncMergeTests.furniture(s)
        piece.links["p-gone"] = SyncRegister(PhotoCarrierSource(photoId: "p-gone", observationId: nil, objectIndex: nil,
                                                                origin: .user, relationToCat: .unclear), s)
        var replica = SyncReplica()
        replica.merge(.photo(photo))
        replica.merge(.furniture(piece))
        let result = SyncProjection.project(replica, local: .empty, catalog: nil)
        #expect(result.state.allFurniture.first?.sources == [])
        #expect(result.pendingLinks.isEmpty)
    }

    // MARK: Photo ids from the web version

    /// The web importer keeps a web photo's id as it was (up to 200 bytes, any characters). The
    /// photo still reaches other devices: there its thumbnail is named after the file, not the id.
    @Test func aWebPhotoIdThatIsNotAFileNameStillReachesOtherDevices() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let imported = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 78)).photo
        let webId = "web/../照片 #" + String(repeating: "x", count: 120)
        var state = await a.store.snapshot()
        state.photos[0] = PhotoRecord(
            photoId: webId, filename: imported.filename, sha256: imported.sha256, mimeType: imported.mimeType,
            byteSize: imported.byteSize, width: imported.width, height: imported.height, originalFile: imported.originalFile,
            thumbnailFile: imported.thumbnailFile, captureDate: imported.captureDate, captureDateSource: imported.captureDateSource,
            exifCaptureDate: imported.exifCaptureDate, importedAt: imported.importedAt, favorite: imported.favorite,
            note: imported.note, revision: imported.revision, reducedFrom: imported.reducedFrom)
        try LibraryStore.encodeState(state).write(to: a.root.appendingPathComponent(LibraryStore.stateFile))
        _ = try await a.store.load()
        try await QACheck.settle([a, b])
        let report = try await b.sync()
        #expect(report.heldBack.isEmpty)
        let onB = try #require(await b.state().photos.first)
        #expect(onB.photoId == webId)
        #expect(!onB.thumbnailFile.contains(webId) && onB.thumbnailFile.hasPrefix("\(LibraryStore.thumbnailsDir)/"))
        #expect(await b.filesAreWhole() == [])
        #expect(LibraryStore.isConsistent(try await b.store.load()))
    }

    // MARK: Cleaning up the cloud's files

    /// A uploads a photo and is never heard from again (a phone given away, or one that started
    /// over and forgot what it uploaded). B deletes the photo: a day later the file leaves the
    /// cloud all the same, and a copy another photo still uses stays.
    @Test func filesOfADeletedPhotoLeaveTheCloudEvenWhenTheDeviceThatUploadedThemIsGone() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let gone = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 76)).photo
        let kept = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 77)).photo
        try await QACheck.settle([a, b])
        #expect(await cloud.fileHashes == [gone.sha256, kept.sha256])
        try await b.store.deletePhoto(photoId: gone.photoId)
        try await b.sync()
        clock.advance(SyncSession.fileGrace + 60)
        try await b.sync()
        #expect(await cloud.fileHashes == [kept.sha256], "only A ever uploaded the file, and A is gone")
        // Each file is deleted once, not on every cycle.
        let device = try #require(try await b.session.deviceState())
        #expect(device.collectedFiles == [gone.sha256])
        try await b.sync()
        #expect(await b.state().photos.map(\.photoId) == [kept.photoId])
    }

    /// Two photo records list one copy (a photo imported again from another's reduced copy):
    /// the deleted one's clean-up leaves the file the live one still uses.
    @Test func aCopyALivePhotoStillHasStaysWhenAnotherRecordOfItIsDeleted() async throws {
        let cloud = SyncMemoryCloud()
        let b = try await QADevice("B", cloud: cloud, clock: clock)
        let s = SyncStamp(wall: 10, counter: 0, device: "x")
        var dead = SyncMergeTests.photo(ids: ["p-dead"], file: SyncMergeTests.file("5ha", 512, source: "src-one"), at: s)
        dead.tomb = SyncTombstone(seen: SyncRecord.photo(dead).version, at: SyncStamp(wall: 20, counter: 0, device: "x"))
        let live = SyncMergeTests.photo(ids: ["p-live"], file: SyncMergeTests.file("5ha", 512, source: "src-two"), at: s)
        let other = cloud.endpoint("X")
        try await other.uploadFile(sha256: "5ha", data: Data("bytes".utf8))
        _ = try await other.save([SyncSave(envelope: try SyncEnvelope(.photo(dead)), baseTag: nil),
                                  SyncSave(envelope: try SyncEnvelope(.photo(live)), baseTag: nil)])
        clock.advance(SyncSession.fileGrace + 60)
        try await b.sync()
        try await b.sync()
        #expect(await cloud.fileHashes == ["5ha"])
    }

    // MARK: Records this build cannot read

    /// Two versions of one record in a format this build does not know: every device keeps the
    /// same one whatever order they arrive in, and once the app can read them it reads them and
    /// fetches everything again, so a device that kept an older version still gets the newest.
    @Test func unreadableVersionsAreKeptTheSameWayEverywhereAndReadAfterTheUpgrade() throws {
        let record = SyncRecord.furniture(SyncMergeTests.furniture(SyncStamp(wall: 1, counter: 0, device: "a")))
        var one = try SyncEnvelope(record), two = one
        one.format = SyncEnvelope.currentFormat + 1
        two.format = SyncEnvelope.currentFormat + 1
        one.payload = Data("{\"v\":1}".utf8)
        two.payload = Data("{\"v\":2}".utf8)
        var forward = SyncReplica(), backward = SyncReplica()
        forward.merge(one)
        forward.merge(two)
        backward.merge(two)
        backward.merge(one)
        #expect(forward == backward)

        // After the upgrade (simulated: a held-back envelope this build reads).
        var device = SyncDeviceState(device: "devA")
        device.replica.merge(try SyncEnvelope(record))
        var heldBack = try SyncEnvelope(record)
        heldBack.payload = try SyncEnvelope(.furniture(SyncMergeTests.furniture(SyncStamp(wall: 5, counter: 0, device: "b"), name: "Newer"))).payload
        var probe = device.replica
        probe.merge(heldBack)
        #expect(probe.unreadable.isEmpty, "a readable version is merged, not held back")
        var json = try #require(try JSONSerialization.jsonObject(with: device.encoded()) as? [String: Any])
        var replica = try #require(json["replica"] as? [String: Any])
        replica["unreadable"] = [heldBack.name: try JSONSerialization.jsonObject(with: SyncCoding.encoder().encode(heldBack))]
        json["replica"] = replica
        json["token"] = ["value": "42"]
        let upgraded = try #require(SyncDeviceState.decode(try JSONSerialization.data(withJSONObject: json)))
        #expect(upgraded.replica.unreadable.isEmpty)
        guard case .furniture(let piece) = upgraded.replica[heldBack.name] else { Issue.record("not read"); return }
        #expect(piece.name.value == "Newer")
        #expect(upgraded.token == nil, "everything is fetched again")
    }

    // MARK: One device, two callers

    /// Two `sync()` calls on one device at once (a push and the app coming to the foreground).
    /// The second applies B's rename; B renames again. The first, held on the network all along,
    /// must not then take the library (holding the rename it never saw) for A's own newer edit
    /// and send it over B's latest name.
    @Test func twoSyncsAtOnceOnOneDeviceLoseNothingEitherLearned() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let lamp = try await b.store.addFurniture(placement: SyncCheck.spot(1), displayName: "Lamp")
        try await QACheck.settle([a, b])
        clock.advance()
        _ = try await b.store.rename(instanceId: lamp.instanceId, displayName: "Desk lamp")
        try await b.sync()
        await a.gate.arm()
        let first = Task { try await a.sync() }
        await a.gate.waitUntilHeld()
        let done = Mutex(false)
        let second = Task {
            defer { done.withLock { $0 = true } }
            return try await a.sync()
        }
        // Let the second run as far as it can: to its end, or until it waits for the first.
        for _ in 0..<300 {
            if done.withLock({ $0 }) { break }
            if await a.session.waitingCycles > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        clock.advance()
        _ = try await b.store.rename(instanceId: lamp.instanceId, displayName: "Reading lamp")
        try await b.sync()
        await a.gate.release()
        _ = try await first.value
        _ = try await second.value
        try await QACheck.settle([a, b])
        for device in [a, b] {
            #expect(await device.state().allFurniture.first?.displayName == "Reading lamp",
                    "\(device.name): B's latest rename was overwritten")
        }
        await QACheck.expectConverged([a, b])
    }

    // MARK: A merge past the room's rules

    /// Doc §7 (pending the owner): pieces two devices placed on the same spots are all kept, on
    /// top of each other, even past the 20 a room takes; the user moves or puts away the extra.
    /// What matters to the engine: nothing is dropped and the library still opens.
    @Test func aMergePastTheRoomsLimitKeepsEveryPieceAndTheLibraryOpens() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        try await QACheck.settle([a, b])
        var ids = Set<String>()
        for device in [a, b] {
            for i in 0..<12 {
                ids.insert(try await device.store.addFurniture(placement: SyncCheck.spot(i), displayName: "\(device.name)\(i)").instanceId)
            }
        }
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(Set(state.allFurniture.map(\.instanceId)) == ids, "\(device.name)")
            #expect(state.items.count == 24 && state.items.count > GridRules.maxItems)
            #expect(LibraryStore.isConsistent(state))
            #expect(try await device.store.load().items.count == 24, "\(device.name) opens again")
        }
        await QACheck.expectConverged([a, b])
    }

    // MARK: Two installs with one device id

    /// A phone set up from A's device backup carries A's library and sync file, and so A's
    /// device id (the app starts such an install over; this is the engine's own check). Once A
    /// hears a write under its id that it never made, it moves to a new id, so its deletions
    /// stop hiding the copy's edits as if A had seen them.
    @Test func aDeviceThatHearsItsIdFromAnotherInstallTakesANewOne() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let lamp = try await a.store.addFurniture(placement: SyncCheck.spot(1), displayName: "Lamp")
        try await QACheck.settle([a, b])
        let c = try await QADevice("C", cloud: cloud, clock: clock)
        try FileManager.default.removeItem(at: c.root)
        try FileManager.default.copyItem(at: a.root, to: c.root)
        _ = try await c.store.load()
        #expect(try await c.session.deviceState()?.clock.device == "devA")

        clock.advance()
        _ = try await c.store.rename(instanceId: lamp.instanceId, displayName: "Copy's lamp")
        try await c.sync()
        try await a.sync()
        let id = try #require(try await a.session.deviceState()?.clock.device)
        #expect(id != "devA", "A heard a write under its id it never made")

        // The copy renames offline; A, not having heard, renames later and then removes it.
        clock.advance()
        _ = try await c.store.rename(instanceId: lamp.instanceId, displayName: "Copy's lamp again")
        try await c.session.captureLocalEdits()
        clock.advance()
        _ = try await a.store.rename(instanceId: lamp.instanceId, displayName: "A's lamp")
        try await a.session.captureLocalEdits()
        try await a.store.removeFurniture(instanceId: lamp.instanceId)
        try await a.sync()
        try await QACheck.settle([c, a, b])
        for device in [a, b, c] {
            #expect(await device.state().allFurniture.map(\.instanceId) == [lamp.instanceId],
                    "\(device.name): the copy's rename A never saw was hidden by A's deletion")
        }
        await QACheck.expectConverged([a, b, c])
    }

    // MARK: Starting over keeps the account

    /// Doc §10: the home never goes into another account without the user's answer. Starting
    /// over (sync turned off and on, or after the cloud data was deleted) forgets the records,
    /// not which account they belonged to; only the user's answer moves on to the new one.
    @Test func startingOverDoesNotMergeTheHomeIntoAnotherAccount() async throws {
        let cloud = SyncMemoryCloud()
        let (a, _) = try await pair(cloud)
        _ = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 95))
        try await QACheck.settle([a])
        let before = await cloud.allEnvelopes
        try await a.session.startOver()
        await cloud.setAccount("account-2")
        let report = try await a.sync()
        #expect(report.problem == .accountChanged && report.sent == 0 && !report.applied)
        #expect(await cloud.allEnvelopes == before, "nothing went into the other account")
        // The user agreed to go on in the account signed in now.
        try await a.session.startOver(acceptingCurrentAccount: true)
        let next = try await a.sync()
        #expect(next.problem == nil)
        #expect(try await a.session.deviceState()?.account == "account-2")
    }

    // MARK: The library goes back while sync's file stays

    /// Like `aLibraryOpenedFromItsBackupDoesNotDeleteOnOtherDevices`, but the user saves several
    /// times before sync runs, so the library's revision passes sync's base again: only a rebase
    /// at the moment the backup is opened can tell the gap from a deletion.
    @Test func editsAfterOpeningTheBackupDoNotTurnTheGapIntoADeletion() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        _ = try await a.store.addCat(name: "A's cat")
        try await QACheck.settle([a, b])
        let photo = try await b.store.importPhoto(draft: try TestSupport.draft(seed: 71)).photo
        try await QACheck.settle([a, b])
        #expect(await a.state().photos.map(\.photoId) == [photo.photoId])
        try Data("{ damaged".utf8).write(to: a.root.appendingPathComponent(LibraryStore.stateFile))
        _ = try await a.store.load()
        #expect(await a.store.recoveredFromBackup)
        let study = try await a.store.addRoom(name: "Study")
        _ = try await a.store.renameRoom(roomId: study.roomId, name: "Studio")
        _ = try await a.store.renameRoom(roomId: study.roomId, name: "Atelier")
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(state.photos.map(\.photoId) == [photo.photoId], "\(device.name): B's photo was deleted")
            #expect(state.allRooms.map(\.name).contains("Atelier"), "\(device.name): the edits after opening the backup are kept")
        }
    }

    /// A damaged picker checkpoint is quarantined (the store switches in a new folder) while a
    /// cycle is out on the network. The tail photo was already captured and sent; it must not be
    /// deleted everywhere, and sync's own file must survive the switch.
    @Test func aPickerQuarantineDuringACycleDeletesNothingElsewhere() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        try await QACheck.settle([a, b])
        _ = try await a.store.importPickerPhotos([try TestSupport.draft(seed: 72)])
        let tail = try await a.store.importPickerPhotos([try TestSupport.draft(seed: 73)])
        let tailPhoto = try #require(tail.first?.photo.photoId)
        try await a.session.captureLocalEdits()
        await a.gate.arm()
        let running = Task { try await a.sync() }
        await a.gate.waitUntilHeld()
        try Data([255]).write(to: a.root.appending(path: PickerImportJournal.directory + "/00000002.json"))
        let reopened = try await a.store.load()
        #expect(!reopened.photos.map(\.photoId).contains(tailPhoto), "the tail is quarantined")
        #expect(FileManager.default.fileExists(atPath: a.syncStateURL.path), "sync's file went with the switch")
        await a.gate.release()
        _ = try await running.value
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(state.photos.count == 2, "\(device.name): the quarantined photo was deleted")
            #expect(state.photos.contains { $0.photoId == tailPhoto }, "\(device.name)")
        }
        #expect(await a.filesAreWhole() == [])
        await QACheck.expectConverged([a, b])
    }
}
