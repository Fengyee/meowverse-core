import Foundation
import Testing
@testable import MeowverseCore

/// QA review of the sync core (2026-11-18): targeted adversarial cases, each tied to a rule in
/// docs/ICLOUD_SYNC.md or AGENTS.md. A failing test here is a reproduction, not a broken test.
@Suite struct SyncQADefectTests {
    let clock = SyncTestClock()

    func pair(_ cloud: SyncMemoryCloud) async throws -> (QADevice, QADevice) {
        (try await QADevice("A", cloud: cloud, clock: clock), try await QADevice("B", cloud: cloud, clock: clock))
    }

    func sharedChair(_ a: QADevice, _ b: QADevice, seed: Int = 1) async throws -> (photo: String, chair: String) {
        let chair = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: seed), placement: SyncCheck.chair,
                                                         displayName: "Chair", decision: .manual)
        try await QACheck.settle([a, b])
        return (try #require(chair.sources.first?.photoId), chair.instanceId)
    }

    // MARK: Delete against edit (doc §4: "删除方没见过的别处修改会让它回来")

    /// B moves the chair while offline. A, never having seen the move, renames the chair and
    /// then deletes it. The move is an edit the deleting device never saw.
    @Test func anUnseenEditOlderThanTheDeletersOwnLastEditStillBringsThePieceBack() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let (_, chair) = try await sharedChair(a, b)
        await cloud.setOffline("B", true)
        _ = try await b.store.updatePlacement(instanceId: chair, placement: SyncCheck.spot(3))
        try await b.session.captureLocalEdits()
        clock.advance(60)
        _ = try await a.store.rename(instanceId: chair, displayName: "A's name")
        try await a.sync()
        clock.advance(60)
        try await a.store.removeFurniture(instanceId: chair)
        try await a.sync()
        await cloud.setOffline("B", false)
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(state.allFurniture.map(\.instanceId) == [chair], "\(device.name): B's unseen move is lost with the piece")
        }
    }

    /// B has the photo's record but not its file yet (download failing). The user then picks
    /// the same photo on B. A, not having heard of B's import, deletes the photo.
    @Test func aPhotoTheUserJustImportedIsNotRemovedByADeleteThatNeverSawTheImport() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        try await QACheck.settle([a, b])
        let draft = try TestSupport.draft(seed: 60)
        _ = try await a.store.importPhoto(draft: draft)
        try await a.sync()
        b.faults.failDownloads = true
        let first = try await b.sync()
        #expect(first.waitingForFiles == 1)
        clock.advance(60)
        _ = try await b.store.importPhoto(draft: draft)
        try await b.session.captureLocalEdits()
        clock.advance(60)
        try await a.store.deletePhoto(photoId: try #require(await a.state().photos.first?.photoId))
        try await a.sync()
        b.faults.failDownloads = false
        try await QACheck.settle([a, b])
        #expect(await b.state().photos.count == 1, "B's own import, made after A's last edit and unseen by A, was deleted")
        #expect(!TestSupport.listing(b.root.appendingPathComponent("originals")).isEmpty, "B's copy was deleted from disk")
    }

    // MARK: First sync never deletes (doc §7, requirement "首次开启时合并两边且不删除任何东西")

    /// The room and cat are made after sync is on, so their records carry real edit stamps
    /// (made when they were captured, never before `createdAt`), as on a phone.
    @Test func turningSyncOnAgainKeepsARoomAndACatTheCloudDeletedMeanwhile() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        try await QACheck.settle([a, b])
        let study = try await a.store.addRoom(name: "Study")
        let mochi = try await a.store.addCat(name: "Mochi")
        try await QACheck.settle([a, b])
        try await b.session.startOver()
        try await a.store.removeRoom(roomId: study.roomId)
        try await a.store.removeCat(catId: mochi.catId)
        try await a.sync()
        try await QACheck.settle([b, a])
        let state = await b.state()
        #expect(state.allRooms.map(\.roomId).contains(study.roomId), "B's room was deleted by turning sync on")
        #expect(state.allCats.map(\.catId).contains(mochi.catId), "B's cat was deleted by turning sync on")
    }

    /// Like `turningSyncOnAgainKeepsWhatTheCloudDeletedMeanwhile`, but the piece is made after
    /// sync is on. That test's piece exists before the first sync, so both devices seed it with
    /// the same wall time and the tie goes to the larger device id ("devB"): it passes even
    /// when the comeback is not stamped as a new edit.
    @Test func turningSyncOnAgainKeepsAPieceMadeAfterSyncWasOn() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        try await QACheck.settle([a, b])
        let (_, chair) = try await sharedChair(a, b)
        try await b.session.startOver()
        try await a.store.removeFurniture(instanceId: chair)
        try await a.sync()
        try await QACheck.settle([b, a])
        for device in [a, b] {
            #expect(await device.state().allFurniture.map(\.instanceId) == [chair], "\(device.name)")
        }
    }

    // MARK: The library and sync's file disagree

    /// A's state.json is damaged; the store opens the backup, which is one write behind (the
    /// last write was the sync that brought in B's photo). Sync must not read that as A
    /// deleting B's photo and piece.
    @Test func aLibraryOpenedFromItsBackupDoesNotDeleteOnOtherDevices() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        _ = try await a.store.addCat(name: "A's cat")
        try await QACheck.settle([a, b])
        let photo = try await b.store.importPhoto(draft: try TestSupport.draft(seed: 70)).photo
        let lamp = try await b.store.addFurniture(placement: SyncCheck.spot(1), displayName: "B's lamp")
        try await QACheck.settle([a, b])
        #expect(await a.state().photos.map(\.photoId) == [photo.photoId])
        try Data("{ damaged".utf8).write(to: a.root.appendingPathComponent(LibraryStore.stateFile))
        _ = try await a.store.load()
        #expect(await a.store.recoveredFromBackup)
        try await QACheck.settle([a, b])
        let state = await b.state()
        #expect(state.photos.map(\.photoId) == [photo.photoId], "B's photo was deleted everywhere")
        #expect(state.allFurniture.map(\.instanceId) == [lamp.instanceId], "B's lamp was deleted everywhere")
        clock.advance(SyncSession.fileGrace + 60)
        try await QACheck.settle([a, b])
        #expect(!(await cloud.fileHashes).isEmpty || !TestSupport.listing(b.root.appendingPathComponent("originals")).isEmpty,
                "no copy of B's photo is left on any device or in the cloud")
    }

    /// The same, for a value: the backup still has the old name, and sync must not send it as
    /// a new edit over B's rename.
    @Test func aLibraryOpenedFromItsBackupDoesNotSendItsOlderValuesAsNewEdits() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let (_, chair) = try await sharedChair(a, b)
        clock.advance()
        _ = try await b.store.rename(instanceId: chair, displayName: "Renamed on B")
        try await QACheck.settle([a, b])
        try Data("{ damaged".utf8).write(to: a.root.appendingPathComponent(LibraryStore.stateFile))
        _ = try await a.store.load()
        clock.advance()
        try await QACheck.settle([a, b])
        #expect(await b.state().items.first?.displayName == "Renamed on B", "A's stale backup overwrote B's rename")
    }

    /// A corrects a date and un-favourites the photo offline; the edit is captured but not sent.
    /// Then sync's own file is damaged and sync starts over as a first sync.
    @Test func aDamagedSyncFileDoesNotDropAnUnsentCorrection() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let (photo, _) = try await sharedChair(a, b)
        _ = try await b.store.editPhoto(photoId: photo, PhotoEdit(favorite: true, captureDate: .set("2018-01-01")))
        try await QACheck.settle([a, b])
        await cloud.setOffline("A", true)
        clock.advance(3600)
        _ = try await a.store.editPhoto(photoId: photo, PhotoEdit(favorite: false, captureDate: .set("2019-02-02")))
        try await a.session.captureLocalEdits()
        _ = try await a.sync()
        try Data("{".utf8).write(to: a.syncStateURL)
        await cloud.setOffline("A", false)
        try await QACheck.settle([a, b])
        let shown = try #require(await a.state().photos.first)
        #expect(shown.captureDate == "2019-02-02", "the user's later date correction was replaced by the older one")
        #expect(shown.favorite == false, "the user's later un-favourite was undone")
    }

    // MARK: Writes that race a cycle (doc §6 setSetting, requirement "同步过程中用户的新修改不能被盖掉")

    @Test func aSettingChangedWhileASyncIsOnTheNetworkIsKept() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        try await QACheck.settle([a, b])
        await a.gate.arm()
        let running = Task { try await a.sync() }
        await a.gate.waitUntilHeld()
        #expect(try await a.session.setSetting("roomTheme", "autumn"))
        await a.gate.release()
        _ = try await running.value
        try await QACheck.settle([a, b])
        #expect(try await a.session.settings()["roomTheme"] == .some("autumn"), "A's own setting was overwritten by the cycle")
        #expect(try await b.session.settings()["roomTheme"] == .some("autumn"), "the setting never reached B")
    }

    /// Local edits while sync cycles run on the same device (a burst of typing during a sync).
    @Test func editsMadeWhileCyclesRunAreAllKept() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let (photo, chair) = try await sharedChair(a, b)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { for _ in 0..<12 { _ = try? await a.sync() } }
            group.addTask { for _ in 0..<12 { _ = try? await b.sync() } }
            group.addTask {
                for i in 0..<30 {
                    _ = try await a.store.editPhoto(photoId: photo, PhotoEdit(note: "n\(i)"))
                    _ = try await a.store.rename(instanceId: chair, displayName: "c\(i)")
                    await Task.yield()
                }
            }
            try await group.waitForAll()
        }
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(state.photos.first?.note == "n29", "\(device.name)")
            #expect(state.items.first?.displayName == "c29", "\(device.name)")
        }
        await QACheck.expectConverged([a, b])
    }

    /// Doc §8 step 2: the file is in the cloud before the record that points at it. Checked
    /// while A's cycle is held right after sending, before its own file repair could hide it.
    @Test func aPhotoRecordNeverReachesAnotherDeviceBeforeItsFile() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        try await QACheck.settle([a, b])
        _ = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: 82), placement: SyncCheck.chair,
                                                 displayName: "Chair", decision: .manual)
        await a.gate.arm()
        let running = Task { try await a.sync() }
        await a.gate.waitUntilHeld()
        let report = try await b.sync()
        await a.gate.release()
        _ = try await running.value
        #expect(report.received > 0, "A's records were sent before the hold")
        #expect(report.waitingForFiles == 0, "B got a photo record whose file was not in the cloud yet")
    }

    // MARK: Records this build held back (doc §9)

    /// What an older build kept as unreadable must be read again once the app can read it
    /// (simulated: the envelope is current-format but sits in `unreadable`, as after upgrading).
    @Test func aRecordHeldBackByAnOlderBuildIsReadAfterTheUpgrade() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let (_, chair) = try await sharedChair(a, b)
        let name = "furniture.\(chair)"
        try await QACheck.rewriteSyncState(b.store) { json in
            var replica = try #require(json["replica"] as? [String: Any])
            let records = try #require(replica["records"] as? [[String: Any]])
            let envelope = try #require(records.first { $0["name"] as? String == name })
            var unreadable = replica["unreadable"] as? [String: Any] ?? [:]
            unreadable[name] = envelope
            replica["unreadable"] = unreadable
            json["replica"] = replica
        }
        clock.advance()
        _ = try await a.store.rename(instanceId: chair, displayName: "Renamed on A after B upgraded")
        try await QACheck.settle([a, b])
        let report = try await b.sync()
        #expect(!report.heldBack.contains(name), "still held back after the upgrade")
        #expect(await b.state().items.first?.displayName == "Renamed on A after B upgraded", "B never shows A's edit")
        clock.advance()
        _ = try await b.store.rename(instanceId: chair, displayName: "Renamed on B")
        try await QACheck.settle([a, b])
        #expect(await a.state().items.first?.displayName == "Renamed on B", "B's edit never leaves B")
    }

    // MARK: References to things not here

    /// The cover points at a photo whose file has not arrived: the piece must not name a photo
    /// the library does not have.
    @Test func aCoverWaitingForItsFileIsNotAPhotoTheLibraryLacks() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        try await QACheck.settle([a, b])
        let chair = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: 80), placement: SyncCheck.chair,
                                                         displayName: "Chair", decision: .manual)
        let photo = try #require(chair.sources.first?.photoId)
        _ = try await a.store.setCover(instanceId: chair.instanceId, photoId: photo)
        try await a.sync()
        b.faults.failDownloads = true
        let report = try await b.sync()
        #expect(report.waitingForFiles == 1)
        let state = await b.state()
        let piece = try #require(state.items.first)
        if let cover = piece.coverPhotoId {
            #expect(state.photos.contains { $0.photoId == cover }, "cover \(cover) is not in B's library")
        }
    }

    /// B links a photo to another piece while A, not having heard, deletes the photo. Either
    /// the photo comes back or the link goes; the piece must not wait for it forever.
    @Test func aLinkToAPhotoDeletedElsewhereDoesNotWaitForever() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let (photo, _) = try await sharedChair(a, b)
        let lamp = try await b.store.addFurniture(placement: SyncCheck.spot(1), displayName: "Lamp")
        try await QACheck.settle([a, b])
        try await a.store.deletePhoto(photoId: photo)
        try await a.session.captureLocalEdits()
        clock.advance()
        _ = try await b.store.linkPhoto(photoId: photo, toInstance: lamp.instanceId)
        try await b.session.captureLocalEdits()
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let report = try await device.sync()
            let state = await device.state()
            if state.photos.isEmpty {
                #expect(report.pendingLinks[lamp.instanceId] == nil,
                        "\(device.name): the lamp says it waits for a photo that was deleted and will never arrive")
            }
        }
        await QACheck.expectConverged([a, b])
    }

    /// A piece whose record names a room id no device has: the piece waits in storage.
    @Test func aPieceInARoomThatNeverArrivesWaitsInStorage() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        try await QACheck.settle([a, b])
        let study = try await a.store.addRoom(name: "Study")
        let lamp = try await a.store.addFurniture(placement: SyncCheck.spot(1), displayName: "Lamp", roomId: study.roomId)
        try await a.sync()
        // Drop the room record from the cloud's view of B by deleting it at the source: the
        // room exists only in A's library; the lamp's record still points at it.
        try await QACheck.settle([a, b])
        try await a.store.removeRoom(roomId: study.roomId)
        try await QACheck.settle([a, b])
        let state = await b.state()
        #expect(state.items.isEmpty && state.storage.map(\.instanceId) == [lamp.instanceId])
        #expect(LibraryStore.isConsistent(state))
    }

    // MARK: Atomic apply (requirement "本机存档写入必须原子")

    /// A remote photo deletion or a remote new photo, with the store failing at each step of
    /// the apply: what is on disk after a restart is one whole library (every photo has its
    /// files), and the next syncs finish the job.
    @Test(arguments: [StoreStep.writeState, .writeOriginal, .writeThumbnail, .deletionBackupCopy, .deletionBackupSync,
                      .deletionBackupRename, .deletionFileRemoval, .syncStateAfterApply])
    func anApplyThatFailsAtAnyStepLeavesOneWholeLibrary(step: StoreStep) async throws {
        let cloud = SyncMemoryCloud()
        let fault = FaultSwitch(nil)
        let a = try await QADevice("A", cloud: cloud, clock: clock)
        let b = try await QADevice("B", cloud: cloud, clock: clock, fault: fault.handler)
        let (photo, _) = try await sharedChair(a, b)
        try await a.store.deletePhoto(photoId: photo)
        _ = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: 81), placement: SyncCheck.spot(2),
                                                 displayName: "Lamp", decision: .manual)
        try await a.sync()
        fault.arm(step)
        _ = try? await b.sync()
        fault.arm(nil)
        let reopened = try await b.store.load()
        #expect(LibraryStore.isConsistent(reopened), "\(step)")
        #expect(await b.filesAreWhole() == [], "\(step): a photo without its files after the failed apply")
        try await QACheck.settle([a, b])
        await QACheck.expectConverged([a, b])
        #expect(await b.state().photos.count == 1, "\(step)")
        #expect(await b.filesAreWhole() == [], "\(step)")
        #expect(TestSupport.listing(b.root.appendingPathComponent("originals")).count == 1, "\(step): the deleted photo's copy is left on disk")
    }

    // MARK: Delete and import again

    @Test func aPhotoDeletedAndImportedAgainComesBackEverywhereWithItsFile() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let (photo, _) = try await sharedChair(a, b)
        try await a.store.deletePhoto(photoId: photo)
        try await QACheck.settle([a, b])
        clock.advance(SyncSession.fileGrace + 60)
        try await QACheck.settle([a, b])
        #expect(await cloud.fileHashes.isEmpty)
        clock.advance(3600)
        _ = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 1))
        try await QACheck.settle([a, b])
        #expect(await b.state().photos.count == 1)
        #expect(await b.filesAreWhole().isEmpty)
        await QACheck.expectConverged([a, b])
    }

    /// Delete and import again on one device with no sync or capture in between.
    @Test func aPhotoDeletedAndImportedAgainBeforeAnySyncKeepsOnePhoto() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let (photo, _) = try await sharedChair(a, b)
        _ = try await a.store.editPhoto(photoId: photo, PhotoEdit(note: "old note"))
        try await QACheck.settle([a, b])
        try await a.store.deletePhoto(photoId: photo)
        _ = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 1))
        try await QACheck.settle([a, b])
        for device in [a, b] { #expect(await device.state().photos.count == 1, "\(device.name)") }
        #expect(await b.filesAreWhole().isEmpty)
        await QACheck.expectConverged([a, b])
    }

    // MARK: Clocks

    /// A device a year ahead edits once. Edits made afterwards elsewhere, having seen it, win.
    @Test func aDeviceAYearAheadDoesNotFreezeLaterEditsElsewhere() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice("A", cloud: cloud, clock: clock, skew: 365 * 86_400)
        let b = try await QADevice("B", cloud: cloud, clock: clock)
        let (_, chair) = try await sharedChair(a, b)
        _ = try await a.store.rename(instanceId: chair, displayName: "from the future")
        try await QACheck.settle([a, b])
        clock.advance()
        _ = try await b.store.rename(instanceId: chair, displayName: "later on B")
        try await QACheck.settle([a, b])
        #expect(await a.state().items.first?.displayName == "later on B")
    }

    /// Reinstalled (container wiped, new random id): the device gets everything and its first
    /// edit after that wins over what it received.
    @Test func aReinstalledDeviceCatchesUpAndItsNextEditWins() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let (_, chair) = try await sharedChair(a, b)
        _ = try await a.store.rename(instanceId: chair, displayName: "before reinstall")
        try await QACheck.settle([a, b])
        let fresh = try await QADevice("A2", cloud: cloud, clock: clock, skew: -600)
        try await QACheck.settle([fresh, b])
        #expect(await fresh.state().items.first?.displayName == "before reinstall")
        _ = try await fresh.store.rename(instanceId: chair, displayName: "after reinstall")
        try await QACheck.settle([fresh, b])
        #expect(await b.state().items.first?.displayName == "after reinstall", "a slow clock after reinstall loses the user's edit")
        #expect(await fresh.filesAreWhole().isEmpty)
    }

    // MARK: The phone's own identifiers

    /// `assetIdentifier` must not be in anything sync sends or stores, including the files.
    @Test func noLocalIdentifierInAnyUploadedRecordOrFile() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let marker = "QA-LOCAL-ASSET-9F3C/L0/001"
        var draft = try TestSupport.draft(seed: 90)
        draft.assetIdentifier = marker
        draft.cloudIdentifier = "QA-CLOUD-1"
        let photo = try await a.store.importPhoto(draft: draft).photo
        _ = try await a.store.editPhoto(photoId: photo.photoId, PhotoEdit(favorite: true, note: "n"))
        _ = try await a.store.commitNewFurniture(draft: draft, placement: SyncCheck.chair, displayName: "Chair", decision: .manual)
        try await QACheck.settle([a, b])
        try await a.store.deletePhoto(photoId: photo.photoId)
        try await QACheck.settle([a, b])
        for envelope in await cloud.allEnvelopes {
            #expect(!String(decoding: envelope.payload, as: UTF8.self).contains("QA-LOCAL-ASSET"), "\(envelope.name)")
        }
        let data = try #require(try await b.store.readSyncState())
        #expect(!String(decoding: data, as: UTF8.self).contains("QA-LOCAL-ASSET"))
    }
}
