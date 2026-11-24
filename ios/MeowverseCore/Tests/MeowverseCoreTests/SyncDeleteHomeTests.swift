import Foundation
import Testing
@testable import MeowverseCore

/// "清除全部数据" with sync on asks whether to delete the home in iCloud too
/// (docs/ICLOUD_SYNC.md §7, §12 item 6). Deleting it there is the user's explicit choice: every
/// device ends up empty, and the cleared device's first sync must not bring anything back.
/// Clearing only this device turns its sync off and leaves the cloud and the others alone.
@Suite("Sync: clearing with or without the home in iCloud")
struct SyncDeleteHomeTests {
    let clock = SyncTestClock()

    func pair(_ cloud: SyncMemoryCloud = SyncMemoryCloud()) async throws -> (SyncDevice, SyncDevice) {
        (try await SyncDevice("A", cloud: cloud, clock: clock), try await SyncDevice("B", cloud: cloud, clock: clock))
    }

    /// A home worth deleting: a piece with a photo from each device, a stored piece, a photo on
    /// its own, a second room and cat, the first room and cat renamed. Both devices synced.
    func furnishedHome(_ a: SyncDevice, _ b: SyncDevice) async throws {
        try await SyncCheck.settle([a, b])
        let recognition = RecognitionResult(analyzer: "test", analyzerRevision: 1,
                                            objects: [ObservedObject(kind: .chair, label: "chair", confidence: 0.9)], catLikely: nil)
        let chair = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: 1), placement: SyncCheck.chair, displayName: "Chair",
                                                         decision: SourceDecision(recognition: recognition, acceptedObjectIndex: 0))
        _ = try await a.store.addPhoto(draft: try TestSupport.draft(seed: 2))
        let shelf = try await a.store.addFurniture(placement: SyncCheck.spot(0), displayName: "Shelf")
        _ = try await a.store.stowFurniture(instanceId: shelf.instanceId)
        let study = try await a.store.addRoom(name: "Study")
        _ = try await a.store.addCat(name: "Momo", roomId: study.roomId)
        _ = try await a.store.renameRoom(roomId: AppState.primaryRoomId, name: "Living room")
        _ = try await a.store.setCatName("Bella")
        try await SyncCheck.settle([a, b])
        _ = try await b.store.addSource(draft: try TestSupport.draft(seed: 3), toInstance: chair.instanceId, decision: .manual)
        try await SyncCheck.settle([a, b])
        let shared = await b.state()
        #expect(shared.photos.count == 3 && shared.items.count == 1 && shared.storage.count == 1)
        #expect(shared.allRooms.count == 2 && shared.allCats.count == 2 && shared.catName == "Bella")
        #expect(shared.observations.count == 1)
    }

    /// Only the records an empty home has are left alive in the cloud.
    func expectCloudEmpty(_ cloud: SyncMemoryCloud, sourceLocation: SourceLocation = #_sourceLocation) async {
        let live = await cloud.allEnvelopes.compactMap { $0.decoded() }.filter(\.isLive).map(\.name).sorted()
        #expect(live == ["cat.\(AppState.primaryCatId)", "home", "room.\(AppState.primaryRoomId)"], sourceLocation: sourceLocation)
    }

    func expectEmpty(_ device: SyncDevice, sourceLocation: SourceLocation = #_sourceLocation) async {
        let state = await device.state()
        let empty = AppState.empty
        #expect(state.photos.isEmpty && state.observations.isEmpty, "\(device.name) has no photos", sourceLocation: sourceLocation)
        #expect(state.items.isEmpty && state.storage.isEmpty, "\(device.name) has no furniture", sourceLocation: sourceLocation)
        #expect(state.allRooms.map(\.roomId) == [AppState.primaryRoomId], sourceLocation: sourceLocation)
        #expect(state.allRooms.first?.name == empty.allRooms.first?.name, "the first room's name is reset", sourceLocation: sourceLocation)
        #expect(state.allCats.map(\.catId) == [AppState.primaryCatId], sourceLocation: sourceLocation)
        #expect(state.catName == empty.catName, "the first cat's name is reset", sourceLocation: sourceLocation)
        #expect(state.allCats.first?.roomId == empty.allCats.first?.roomId, sourceLocation: sourceLocation)
    }

    // MARK: Delete the home in iCloud too

    @Test func deletingTheHomeInICloudEmptiesEveryDeviceAndNothingComesBack() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        try await furnishedHome(a, b)
        clock.advance()
        let report = try await a.session.deleteHomeInCloud()
        #expect(report.problem == nil && report.unsent == 0, "every deletion reached the cloud")
        await expectCloudEmpty(cloud)
        // The app clears this device next; its first sync finds only the deletions.
        _ = try await a.store.clearAll()
        try await SyncCheck.settle([a, b])
        await expectEmpty(a)
        await expectEmpty(b)
        #expect(try await b.reopened().photos.isEmpty)
        await SyncCheck.expectConverged([a, b])
        // B turning sync on again (a first sync) does not bring the home back either.
        try await b.session.startOver()
        try await SyncCheck.settle([a, b])
        await expectEmpty(a)
        await expectEmpty(b)
    }

    @Test func aDeviceThatNeverSyncedTheLatestStillDeletesEverythingInTheCloud() async throws {
        // A last synced before B added a photo: the deletion fetches first, so it covers it.
        let (a, b) = try await pair()
        try await furnishedHome(a, b)
        _ = try await b.store.addPhoto(draft: try TestSupport.draft(seed: 7))
        try await b.sync()
        clock.advance()
        let report = try await a.session.deleteHomeInCloud()
        #expect(report.problem == nil && report.unsent == 0)
        _ = try await a.store.clearAll()
        try await SyncCheck.settle([a, b])
        await expectEmpty(a)
        await expectEmpty(b)
    }

    @Test func aPhotoWhoseFileNeverArrivedIsDeletedToo() async throws {
        // B's photo record reached A, its file did not: A does not show it, but deletes it.
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        try await furnishedHome(a, b)
        let late = try await b.store.addPhoto(draft: try TestSupport.draft(seed: 8))
        try await b.sync()
        try await cloud.endpoint("B").deleteFile(sha256: late.sha256)
        try await a.sync()
        #expect(await a.state().photos.count == 3, "A waits for the new photo's file")
        let report = try await a.session.deleteHomeInCloud()
        #expect(report.problem == nil && report.unsent == 0)
        _ = try await a.store.clearAll()
        try await SyncCheck.settle([a, b])
        await expectEmpty(b)
    }

    @Test func anEditElsewhereThatTheDeletionNeverSawStays() async throws {
        // As with any deletion (§4): B's edit A had not seen keeps that photo, and only that.
        let (a, b) = try await pair()
        try await furnishedHome(a, b)
        let photo = try #require(await b.state().photos.first { $0.note.isEmpty })
        _ = try await b.store.editPhoto(photoId: photo.photoId, PhotoEdit(note: "B, offline"))
        try await b.session.captureLocalEdits()
        clock.advance()
        _ = try await a.session.deleteHomeInCloud()
        _ = try await a.store.clearAll()
        try await SyncCheck.settle([a, b])
        let left = await b.state()
        #expect(left.photos.map(\.note) == ["B, offline"])
        #expect(left.items.isEmpty && left.storage.isEmpty && left.allRooms.count == 1 && left.allCats.count == 1)
        await SyncCheck.expectConverged([a, b])
    }

    @Test func ifClearingThisDeviceFailsTheNextSyncEmptiesItAndAnUnsentEditDoesNotBringAPhotoBack() async throws {
        let (a, b) = try await pair()
        try await furnishedHome(a, b)
        // An edit here that no capture recorded yet, then the deletion; the clear never happens.
        let photo = try #require(await a.state().photos.first)
        _ = try await a.store.editPhoto(photoId: photo.photoId, PhotoEdit(note: "just now"))
        clock.advance()
        let report = try await a.session.deleteHomeInCloud()
        #expect(report.problem == nil && report.unsent == 0)
        try await SyncCheck.settle([a, b])
        await expectEmpty(a)
        await expectEmpty(b)
    }

    @Test func offlineNothingIsDeletedAnywhere() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        try await furnishedHome(a, b)
        let before = await cloud.allEnvelopes
        await cloud.setOffline("A", true)
        await #expect(throws: SyncTransportError.offline) { try await a.session.deleteHomeInCloud() }
        await cloud.setOffline("A", false)
        // Nothing was recorded either: the next ordinary cycles delete nothing.
        try await SyncCheck.settle([a, b])
        #expect(await cloud.allEnvelopes == before)
        #expect(await a.state().photos.count == 3)
        #expect(await b.state().photos.count == 3)
    }

    @Test func inAnotherAccountNothingIsDeleted() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        try await furnishedHome(a, b)
        let before = await cloud.allEnvelopes
        await cloud.setAccount("account-2")
        await #expect(throws: SyncTransportError.accountChanged) { try await a.session.deleteHomeInCloud() }
        #expect(await cloud.allEnvelopes == before)
    }

    @Test func aDeletionCutOffHalfwayFinishesWithTheNextSync() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        try await furnishedHome(a, b)
        clock.advance()
        await cloud.dropAfterSaving("A", count: 2)
        let report = try await a.session.deleteHomeInCloud()
        #expect(report.problem == .offline && report.unsent > 0, "recorded, not all sent")
        // The app keeps this device's library then; the next cycle sends the rest and empties it.
        try await SyncCheck.settle([a, b])
        await expectEmpty(a)
        await expectEmpty(b)
    }

    // MARK: Clear only this device

    @Test func clearingOnlyThisDeviceLeavesTheCloudAndTheOthersAlone() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        try await furnishedHome(a, b)
        let before = await cloud.allEnvelopes
        let shared = SyncCheck.view(await b.state())
        // What the app does: sync off on A (it forgets what it knew), then the clear.
        try await a.session.startOver()
        _ = try await a.store.clearAll()
        // A no longer syncs; B goes on, and edits there do not reach A.
        try await SyncCheck.settle([b])
        #expect(await cloud.allEnvelopes == before, "nothing in the cloud changed")
        #expect(SyncCheck.view(await b.state()) == shared)
        _ = try await b.store.addPhoto(draft: try TestSupport.draft(seed: 9))
        try await SyncCheck.settle([b])
        #expect(await b.state().photos.count == 4)
        let cleared = await a.state()
        #expect(cleared.photos.isEmpty && cleared.items.isEmpty)
        #expect(await cloud.allEnvelopes.compactMap { $0.decoded() }.allSatisfy(\.isLive), "no deletion was sent")
    }
}
