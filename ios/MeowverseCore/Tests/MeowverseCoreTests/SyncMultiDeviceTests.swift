import Foundation
import Testing
@testable import MeowverseCore

/// Two or three devices, each with a real library on disk, syncing through the fake cloud.
@Suite struct SyncMultiDeviceTests {
    let clock = SyncTestClock()

    func pair(_ cloud: SyncMemoryCloud = SyncMemoryCloud()) async throws -> (SyncDevice, SyncDevice) {
        (try await SyncDevice("A", cloud: cloud, clock: clock), try await SyncDevice("B", cloud: cloud, clock: clock))
    }

    /// A photo on a chair on A, then both devices synced.
    func sharedChairWithPhoto(_ a: SyncDevice, _ b: SyncDevice) async throws -> (photo: String, chair: String) {
        let chair = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: 1), placement: SyncCheck.chair,
                                                         displayName: "Chair", decision: .manual)
        try await SyncCheck.settle([a, b])
        return (try #require(chair.sources.first?.photoId), chair.instanceId)
    }

    // MARK: Same field, different fields

    @Test func concurrentEditsOfOneFieldEndWithTheLaterEditOnBothDevices() async throws {
        let (a, b) = try await pair()
        let (photo, _) = try await sharedChairWithPhoto(a, b)
        _ = try await a.store.editPhoto(photoId: photo, PhotoEdit(note: "from A"))
        try await a.session.captureLocalEdits()
        clock.advance()
        _ = try await b.store.editPhoto(photoId: photo, PhotoEdit(note: "from B, later"))
        try await b.session.captureLocalEdits()
        clock.advance()
        // A sends after B edited: the order of sending does not decide, the order of editing does.
        try await b.sync()
        try await a.sync()
        try await SyncCheck.settle([a, b])
        #expect(try await a.onlyPhoto().note == "from B, later")
        #expect(try await b.onlyPhoto().note == "from B, later")
        await SyncCheck.expectConverged([a, b])
    }

    @Test func editsOfDifferentFieldsBothSurvive() async throws {
        let (a, b) = try await pair()
        let (photo, chair) = try await sharedChairWithPhoto(a, b)
        _ = try await a.store.editPhoto(photoId: photo, PhotoEdit(favorite: true))
        _ = try await a.store.rename(instanceId: chair, displayName: "Grandma's chair")
        _ = try await b.store.editPhoto(photoId: photo, PhotoEdit(note: "sunny afternoon"))
        _ = try await b.store.updatePlacement(instanceId: chair, placement: Placement(modelId: "kenney-chair", x: 8, z: 8, width: 2, depth: 2))
        try await SyncCheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(state.photos[0].favorite && state.photos[0].note == "sunny afternoon")
            #expect(state.items[0].displayName == "Grandma's chair" && state.items[0].x == 8)
        }
        await SyncCheck.expectConverged([a, b])
    }

    @Test func photosAddedToOnePieceOnTwoDevicesAreAllKept() async throws {
        let (a, b) = try await pair()
        let (_, chair) = try await sharedChairWithPhoto(a, b)
        _ = try await a.store.addSource(draft: try TestSupport.draft(seed: 2), toInstance: chair, decision: .manual)
        _ = try await b.store.addSource(draft: try TestSupport.draft(seed: 3), toInstance: chair, decision: .manual)
        try await SyncCheck.settle([a, b])
        #expect(await a.state().items[0].sources.count == 3)
        await SyncCheck.expectConverged([a, b])
    }

    // MARK: Delete against edit

    @Test func anEditTheDeletingDeviceNeverSawBringsThePieceBack() async throws {
        let (a, b) = try await pair()
        let (photo, chair) = try await sharedChairWithPhoto(a, b)
        try await a.store.removeFurniture(instanceId: chair)
        try await a.session.captureLocalEdits()
        clock.advance()
        _ = try await b.store.rename(instanceId: chair, displayName: "Kept chair")
        try await SyncCheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(state.items.map(\.displayName) == ["Kept chair"])
            #expect(state.items.first?.sources.map(\.photoId) == [photo], "the photo link comes back with it")
        }
        await SyncCheck.expectConverged([a, b])
    }

    @Test func anEarlierEditTheDeletingDeviceHadNotReceivedAlsoBringsThePieceBack() async throws {
        let (a, b) = try await pair()
        let (_, chair) = try await sharedChairWithPhoto(a, b)
        // B renames first but does not sync; A deletes later without having seen it.
        _ = try await b.store.rename(instanceId: chair, displayName: "Renamed first")
        try await b.session.captureLocalEdits()
        clock.advance(60)
        try await a.store.removeFurniture(instanceId: chair)
        try await a.sync()
        try await SyncCheck.settle([a, b])
        #expect(await a.state().items.map(\.displayName) == ["Renamed first"])
        await SyncCheck.expectConverged([a, b])
    }

    @Test func aDeletionAfterSeeingTheEditRemovesThePieceEverywhere() async throws {
        let (a, b) = try await pair()
        let (photo, chair) = try await sharedChairWithPhoto(a, b)
        _ = try await b.store.rename(instanceId: chair, displayName: "Renamed")
        try await SyncCheck.settle([a, b])
        try await a.store.removeFurniture(instanceId: chair)
        try await SyncCheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(state.allFurniture.isEmpty)
            #expect(state.photos.map(\.photoId) == [photo], "removing a piece never deletes its photo")
        }
    }

    @Test func aPhotoDeletedOnOneDeviceLeavesEveryPieceOnEveryDevice() async throws {
        let (a, b) = try await pair()
        let (photo, chair) = try await sharedChairWithPhoto(a, b)
        try await a.store.deletePhoto(photoId: photo)
        try await SyncCheck.settle([a, b])
        let state = await b.state()
        #expect(state.photos.isEmpty)
        #expect(state.items.map(\.instanceId) == [chair])
        #expect(state.items[0].sources.isEmpty, "now truthfully without photos")
        #expect(try await b.reopened().photos.isEmpty)
        #expect(TestSupport.listing(b.root.appendingPathComponent("originals")).isEmpty, "the copy is gone from disk")
        #expect(await a.cloud.fileHashes.count == 1, "the cloud keeps the file for a day, for an edit still on its way")
        clock.advance(SyncSession.fileGrace + 60)
        try await SyncCheck.settle([a, b])
        #expect(await a.cloud.fileHashes.isEmpty, "then it is gone from the cloud too")
    }

    @Test func aPhotoBroughtBackAfterItsFileLeftTheCloudIsUploadedAgain() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let c = try await SyncDevice("C", cloud: cloud, clock: clock)
        let (photo, _) = try await sharedChairWithPhoto(a, b)
        try await SyncCheck.settle([a, b, c])
        // A deletes; C, not having heard, edits; the edit lands while the file is still there,
        // and then the file goes anyway (another device's clean-up raced it).
        try await a.store.deletePhoto(photoId: photo)
        try await a.session.captureLocalEdits()
        clock.advance()
        _ = try await c.store.editPhoto(photoId: photo, PhotoEdit(note: "still here"))
        try await c.sync()
        let sha = try await c.onlyPhoto().sha256
        // A day later A's cycle is cut off before it hears of C's edit: it must not clean up
        // files on that stale view.
        clock.advance(SyncSession.fileGrace + 60)
        await cloud.dropAfterSaving("A", count: 0)
        #expect(try await a.sync().problem == .offline)
        #expect(await cloud.fileHashes == [sha], "no clean-up without a fresh fetch")
        try await cloud.endpoint("X").deleteFile(sha256: sha)
        try await SyncCheck.settle([a, b, c])
        #expect(await cloud.fileHashes == [sha])
        for device in [a, b, c] {
            #expect(try await device.onlyPhoto().note == "still here", "\(device.name) has the photo back")
        }
        await SyncCheck.expectConverged([a, b, c])
    }

    // MARK: One photo imported on two devices

    @Test func onePhotoImportedOnTwoDevicesBecomesOnePhotoWithEachDeviceKeepingItsCopy() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let c = try await SyncDevice("C", cloud: cloud, clock: clock)
        let large = try SyncCheck.wideDraft(seed: 4, maxPixel: 2048), small = try SyncCheck.wideDraft(seed: 4, maxPixel: 1024)
        #expect(large.reducedFrom?.sha256 == small.reducedFrom?.sha256 && large.sha256 != small.sha256)
        let mine = try await a.store.importPhoto(draft: large).photo
        let chair = try await b.store.commitNewFurniture(draft: small, placement: SyncCheck.chair, displayName: "Chair", decision: .manual)
        let theirs = try #require(chair.sources.first?.photoId)
        _ = try await b.store.editPhoto(photoId: theirs, PhotoEdit(note: "on B"))
        try await SyncCheck.settle([a, b, c])

        let one = min(mine.photoId, theirs)
        for device in [a, b, c] {
            let state = await device.state()
            #expect(state.photos.map(\.photoId) == [one], "\(device.name): one photo, the same id everywhere")
            #expect(state.items.first?.sources.map(\.photoId) == [one])
            #expect(state.photos.first?.note == "on B")
        }
        #expect(try await a.onlyPhoto().sha256 == large.sha256, "A keeps its 2048 px copy")
        #expect(try await b.onlyPhoto().sha256 == small.sha256, "B keeps its 1024 px copy")
        #expect(try await c.onlyPhoto().sha256 == large.sha256, "C gets the best copy")
        #expect(await cloud.fileHashes == [large.sha256], "the smaller copy left the cloud once the best was there")
        await SyncCheck.expectConverged([a, b, c])
        #expect(try await b.reopened().photos.map(\.photoId) == [one])
    }

    // MARK: Offline, delivery, failures

    @Test func aDeviceOfflineForManyEditsMergesWhenItComesBack() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let (photo, chair) = try await sharedChairWithPhoto(a, b)
        await cloud.setOffline("A", true)
        _ = try await a.store.addRoom(name: "Study")
        _ = try await a.store.addFurniture(placement: SyncCheck.spot(1), displayName: "Lamp")
        _ = try await a.store.editPhoto(photoId: photo, PhotoEdit(captureDate: .set("2019-05-04")))
        let offline = try await a.sync()
        #expect(offline.problem == .offline && offline.unsent > 0)
        _ = try await b.store.addCat(name: "Mochi")
        _ = try await b.store.rename(instanceId: chair, displayName: "B's chair")
        try await b.sync()
        await cloud.setOffline("A", false)
        try await SyncCheck.settle([a, b])
        let state = await b.state()
        #expect(state.allRooms.map(\.name) == [nil, "Study"])
        #expect(Set(state.items.map(\.displayName)) == ["B's chair", "Lamp"])
        #expect(state.photos[0].captureDate == "2019-05-04" && state.photos[0].captureDateSource == .user)
        #expect(state.allCats.map(\.name) == ["Kitty", "Mochi"])
        await SyncCheck.expectConverged([a, b])
    }

    @Test func duplicateAndOutOfOrderDeliveriesChangeNothingOnceSettled() async throws {
        let cloud = SyncMemoryCloud(seed: 3)
        await cloud.setMessyDelivery(true)
        let (a, b) = try await pair(cloud)
        let c = try await SyncDevice("C", cloud: cloud, clock: clock)
        let (photo, chair) = try await sharedChairWithPhoto(a, b)
        var order = SeededRandom(seed: 11)
        for round in 0..<4 {
            _ = try await a.store.rename(instanceId: chair, displayName: "Chair \(round)")
            clock.advance()
            _ = try await b.store.editPhoto(photoId: photo, PhotoEdit(note: "note \(round)"))
            clock.advance()
            _ = try await c.store.addFurniture(placement: SyncCheck.spot(round + 4), displayName: "Piece \(round)")
            for device in [c, a, b].shuffled(using: &order) { try await device.sync() }
        }
        try await SyncCheck.settle([a, b, c])
        await SyncCheck.expectConverged([a, b, c])
        let settled = await a.state()
        #expect(settled.items.first { $0.instanceId == chair }?.displayName == "Chair 3")
        #expect(settled.photos[0].note == "note 3")
        // Old and repeated versions keep coming; nothing moves.
        for device in [a, b, c] {
            let report = try await device.sync()
            #expect(!report.applied, "\(device.name) changed on a repeat delivery")
        }
        #expect(await a.state() == settled)
    }


    @Test func aSaveCutOffHalfwayIsRetriedWithoutLossOrDuplicates() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        for seed in 10..<14 {
            _ = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: seed), placement: SyncCheck.spot(seed),
                                                     displayName: "Piece \(seed)", decision: .manual)
        }
        await cloud.dropAfterSaving("A", count: 3)
        let cut = try await a.sync()
        #expect(cut.problem == .offline)
        await cloud.failSaves("A", count: 1)
        #expect(try await a.sync().problem == .offline)
        try await SyncCheck.settle([a, b])
        let state = await b.state()
        #expect(state.photos.count == 4 && state.items.count == 4)
        #expect(state.items.allSatisfy { $0.sources.count == 1 })
        await SyncCheck.expectConverged([a, b])
    }

    @Test func aStoreWriteThatFailsMidApplyIsRetriedWithNothingHalfDone() async throws {
        let cloud = SyncMemoryCloud()
        let fault = FaultSwitch(nil)
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        let b = try await SyncDevice("B", cloud: cloud, clock: clock, fault: fault.handler)
        try await SyncCheck.settle([a, b])
        _ = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: 20), placement: SyncCheck.chair,
                                                 displayName: "Chair", decision: .manual)
        try await a.sync()
        fault.arm(.writeState)
        await #expect(throws: InjectedFault.failed(.writeState)) { try await b.sync() }
        #expect(await b.state().photos.isEmpty)
        #expect(try await b.reopened().photos.isEmpty, "nothing half-written on disk")
        #expect(TestSupport.listing(b.root.appendingPathComponent("originals")).isEmpty, "the new copy was rolled back")
        try await SyncCheck.settle([a, b])
        #expect(try await b.reopened().items.first?.sources.count == 1)
        await SyncCheck.expectConverged([a, b])
    }

    @Test func aCrashBetweenTheLibraryWriteAndSyncsOwnFileDoesNotReplayTheRemoteChangeAsNew() async throws {
        let cloud = SyncMemoryCloud()
        let fault = FaultSwitch(nil)
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        let b = try await SyncDevice("B", cloud: cloud, clock: clock, fault: fault.handler)
        let (_, chair) = try await sharedChairWithPhoto(a, b)
        _ = try await a.store.rename(instanceId: chair, displayName: "X")
        try await a.sync()
        clock.advance()
        // B writes the rename into its library, then dies before remembering that it did.
        fault.arm(.syncStateAfterApply)
        await #expect(throws: InjectedFault.failed(.syncStateAfterApply)) { try await b.sync() }
        #expect(try await b.reopened().items.first?.displayName == "X")
        // A renames again; B, restarted, must not send "X" back as if it were B's newer edit.
        clock.advance()
        _ = try await a.store.rename(instanceId: chair, displayName: "Y")
        try await a.sync()
        clock.advance()
        let restarted = SyncSession(store: b.store, transport: cloud.endpoint("B"), catalog: try TestSupport.catalog(),
                                    deviceID: "devB", now: clock.reader())
        try await restarted.sync()
        try await SyncCheck.settle([a, b])
        #expect(await a.state().items.first?.displayName == "Y")
        await SyncCheck.expectConverged([a, b])
    }

    // MARK: User corrections and stale data

    @Test func aUsersDateCorrectionSurvivesAStaleDeviceAndOldDeliveries() async throws {
        let cloud = SyncMemoryCloud(seed: 5)
        let (a, b) = try await pair(cloud)
        let (photo, _) = try await sharedChairWithPhoto(a, b)
        let exif = try await a.onlyPhoto().captureDate
        // B goes quiet with the old date; A corrects the date.
        await cloud.setOffline("B", true)
        clock.advance(3600)
        _ = try await a.store.editPhoto(photoId: photo, PhotoEdit(captureDate: .set("2017-08-09")))
        try await a.sync()
        // B, still with the file's date, edits something else and comes back much later.
        _ = try await b.store.setFavorite(photoIds: [photo], true)
        clock.advance(86_400)
        await cloud.setOffline("B", false)
        await cloud.setMessyDelivery(true)
        try await SyncCheck.settle([a, b])
        for device in [a, b] {
            let shown = try await device.onlyPhoto()
            #expect(shown.captureDate == "2017-08-09" && shown.captureDateSource == .user)
            #expect(shown.exifCaptureDate == exif, "the file's own date is kept for undo")
            #expect(shown.favorite)
        }
        // Clearing the correction is a user edit too, and goes back to the file's day everywhere.
        _ = try await b.store.editPhoto(photoId: photo, PhotoEdit(captureDate: .clear))
        try await SyncCheck.settle([a, b])
        #expect(try await a.onlyPhoto().captureDate == exif)
        #expect(try await a.onlyPhoto().captureDateSource == (exif == nil ? .unknown : .exif))
    }

    @Test func aLateApplyIsRefusedWhenTheUserEditedMeanwhile() async throws {
        let (a, b) = try await pair()
        let (photo, _) = try await sharedChairWithPhoto(a, b)
        let (seen, generation) = try await b.store.syncSnapshot()
        _ = try await b.store.editPhoto(photoId: photo, PhotoEdit(note: "typed just now"))
        var stale = seen
        stale.photos[0].note = "from an old sync cycle"
        await #expect(throws: SyncApplyError.localChanged) {
            try await b.store.applySynced(stale, ifRevision: seen.revision, generation: generation, writes: []) { _ in Data() }
        }
        #expect(try await b.onlyPhoto().note == "typed just now")
        try await SyncCheck.settle([a, b])
        #expect(try await a.onlyPhoto().note == "typed just now")
    }

    @Test func aRestoreOrClearWhileSyncingNeverDeletesOnOtherDevices() async throws {
        let (a, b) = try await pair()
        let (photo, chair) = try await sharedChairWithPhoto(a, b)
        _ = try await a.store.clearAll()
        try await SyncCheck.settle([a, b])
        let state = await b.state()
        #expect(state.photos.map(\.photoId) == [photo] && state.items.map(\.instanceId) == [chair])
        // The cleared device merges as on a first sync: what the cloud has comes back to it.
        #expect(await a.state().items.map(\.instanceId) == [chair])
        await SyncCheck.expectConverged([a, b])
    }

    // MARK: Local identifiers

    @Test func photoLibraryIdentifiersOfOneDeviceNeverReachAnother() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let localA = "A-LOCAL-ID-4711/L0/001", localB = "B-LOCAL-ID-0815/L0/001"
        let draftA = try SyncCheck.wideDraft(seed: 5, maxPixel: 1024, asset: localA, cloud: "CLOUD-ID-1")
        let photo = try await a.store.importPhoto(draft: draftA).photo
        try await SyncCheck.settle([a, b])
        for envelope in await cloud.allEnvelopes {
            #expect(!String(decoding: envelope.payload, as: UTF8.self).contains("LOCAL-ID"))
        }
        #expect(try await b.onlyPhoto().assetIdentifier == nil)
        #expect(try await b.onlyPhoto().cloudIdentifier == "CLOUD-ID-1", "the cross-device id is shared")
        // B picks the same photo from its own library: B learns its own identifier.
        let draftB = try SyncCheck.wideDraft(seed: 5, maxPixel: 2048, asset: localB, cloud: "CLOUD-ID-1")
        #expect(try await b.store.importPhoto(draft: draftB).photo.photoId == photo.photoId)
        _ = try await a.store.editPhoto(photoId: photo.photoId, PhotoEdit(note: "keep going"))
        try await SyncCheck.settle([a, b])
        #expect(try await a.reopened().photos.first?.assetIdentifier == localA)
        #expect(try await b.reopened().photos.first?.assetIdentifier == localB)
        for envelope in await cloud.allEnvelopes {
            #expect(!String(decoding: envelope.payload, as: UTF8.self).contains("LOCAL-ID"))
        }
        let state = try await #require(b.session.deviceState())
        #expect(!String(decoding: try SyncCoding.encoder().encode(state.replica), as: UTF8.self).contains("LOCAL-ID"))
    }

    // MARK: First sync, quota, rooms, newer records

    @Test func turningSyncOnMergesBothLibrariesAndKeepsBothNotes() async throws {
        let (a, b) = try await pair()
        // The same photo in both libraries before sync, with different notes; and other things.
        let shared = try TestSupport.draft(seed: 30)
        let onA = try await a.store.importPhoto(draft: shared).photo
        _ = try await a.store.editPhoto(photoId: onA.photoId, PhotoEdit(note: "A remembers"))
        _ = try await a.store.addFurniture(placement: SyncCheck.spot(1), displayName: "A's lamp")
        let onB = try await b.store.importPhoto(draft: shared).photo
        _ = try await b.store.editPhoto(photoId: onB.photoId, PhotoEdit(favorite: true, note: "B remembers"))
        _ = try await b.store.addFurniture(placement: SyncCheck.spot(2), displayName: "B's sofa")
        try await SyncCheck.settle([a, b])
        let state = await a.state()
        #expect(state.photos.count == 1)
        #expect(state.photos[0].note.contains("A remembers") && state.photos[0].note.contains("B remembers"))
        #expect(state.photos[0].favorite)
        #expect(Set(state.items.map(\.displayName)) == ["A's lamp", "B's sofa"])
        await SyncCheck.expectConverged([a, b])
    }

    @Test func aFirstSyncNeverShortensANoteOrDropsOneWrittenBeforeSync() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let c = try await SyncDevice("C", cloud: cloud, clock: clock)
        let shared = try TestSupport.draft(seed: 31)
        let onA = try await a.store.importPhoto(draft: shared).photo
        _ = try await b.store.importPhoto(draft: shared).photo
        _ = try await c.store.importPhoto(draft: shared).photo
        try await SyncCheck.settle([a])
        // After sync is on, A writes a note that happens to contain B's old one.
        _ = try await a.store.editPhoto(photoId: onA.photoId, PhotoEdit(note: "asleep on the sofa"))
        try await a.sync()
        _ = try await b.store.editPhoto(photoId: try await b.onlyPhoto().photoId, PhotoEdit(note: "sofa"))
        _ = try await c.store.editPhoto(photoId: try await c.onlyPhoto().photoId, PhotoEdit(note: "first day home"))
        try await SyncCheck.settle([a, b, c])
        let note = try await a.onlyPhoto().note
        #expect(note.contains("asleep on the sofa"), "B's first sync must not cut A's note down to its own")
        #expect(note.contains("first day home"), "C's note from before sync is kept next to A's later one")
        await SyncCheck.expectConverged([a, b, c])
    }

    @Test func turningSyncOnAgainKeepsWhatTheCloudDeletedMeanwhile() async throws {
        let (a, b) = try await pair()
        let (photo, chair) = try await sharedChairWithPhoto(a, b)
        // B stops syncing (its sync memory is gone) while A deletes the photo and the chair.
        try await b.session.startOver()
        try await a.store.deletePhoto(photoId: photo)
        try await a.store.removeFurniture(instanceId: chair)
        try await a.sync()
        // B turns sync on again with both still in its library: nothing of B's is deleted.
        try await SyncCheck.settle([b, a])
        for device in [a, b] {
            let state = await device.state()
            #expect(state.photos.map(\.photoId) == [photo] && state.items.map(\.instanceId) == [chair])
            #expect(state.items.first?.sources.map(\.photoId) == [photo])
        }
        await SyncCheck.expectConverged([a, b])
    }

    @Test func aSettingFollowsTheUserAndTheLaterChoiceWins() async throws {
        let (a, b) = try await pair()
        #expect(try await a.session.setSetting("roomTheme", "autumn") == false, "nothing to merge with before the first sync")
        try await SyncCheck.settle([a, b])
        try await a.session.setSetting("roomTheme", "winter")
        clock.advance()
        try await b.session.setSetting("roomTheme", "spring")
        try await b.session.setSetting("reminders", nil)
        try await a.sync()
        try await SyncCheck.settle([a, b])
        for device in [a, b] {
            let settings = try await device.session.settings()
            #expect(settings["roomTheme"] == .some("spring"), "\(device.name)")
            #expect(settings.keys.contains("reminders") && settings["reminders"] == .some(nil))
        }
    }

    @Test func whenICloudIsFullThePhotoWaitsAndItsPieceSaysSo() async throws {
        let cloud = SyncMemoryCloud()
        await cloud.setQuota(0)
        let (a, b) = try await pair(cloud)
        let chair = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: 40), placement: SyncCheck.chair,
                                                         displayName: "Chair", decision: .manual)
        let report = try await a.sync()
        #expect(report.problem == .quotaExceeded && report.unsent == 1)
        try await b.sync()
        var state = await b.state()
        #expect(state.photos.isEmpty && state.items.map(\.instanceId) == [chair.instanceId])
        #expect(try await b.sync().pendingLinks == [chair.instanceId: 1], "the piece is waiting for a photo, not without one")
        await cloud.setQuota(nil)
        try await SyncCheck.settle([a, b])
        state = await b.state()
        #expect(state.photos.count == 1 && state.items[0].sources.count == 1)
    }

    @Test func aPieceMovedIntoARoomDeletedElsewhereWaitsInTheStorageBox() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let study = try await a.store.addRoom(name: "Study")
        let lamp = try await a.store.addFurniture(placement: SyncCheck.spot(1), displayName: "Lamp")
        try await SyncCheck.settle([a, b])
        try await a.store.removeRoom(roomId: study.roomId)
        try await a.session.captureLocalEdits()
        clock.advance()
        _ = try await b.store.updatePlacement(instanceId: lamp.instanceId, placement: SyncCheck.spot(1), roomId: study.roomId)
        try await SyncCheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(state.allRooms.count == 1)
            #expect(state.storage.map(\.instanceId) == [lamp.instanceId] && state.items.isEmpty)
        }
        await SyncCheck.expectConverged([a, b])
    }

    @Test func aRecordFromANewerAppIsKeptAndLeftAlone() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let (_, chair) = try await sharedChairWithPhoto(a, b)
        // A newer build rewrites the chair in a format this build cannot read.
        let name = "furniture.\(chair)"
        let future = SyncEnvelope(type: "MVFurniture", name: name, format: SyncEnvelope.currentFormat + 1,
                                  payload: Data("{\"from\":\"the future\"}".utf8))
        let tag = try #require(try await a.session.deviceState()?.tags[name])
        _ = try await cloud.endpoint("N").save([SyncSave(envelope: future, baseTag: tag)])
        _ = try await a.store.rename(instanceId: chair, displayName: "Edited on an old build")
        let report = try await a.sync()
        #expect(report.heldBack.contains(name))
        #expect(await cloud.allEnvelopes.first { $0.name == name } == future, "the old build never overwrites it")
        #expect(await a.state().items.first?.displayName == "Edited on an old build", "and keeps its own copy")
    }
}
