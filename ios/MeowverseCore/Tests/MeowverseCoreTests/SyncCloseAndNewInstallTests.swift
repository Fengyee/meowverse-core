import Foundation
import Testing
@testable import MeowverseCore

/// Round-12 audit (docs/audits/2026-11-20): SYNC-1, a clear while a cycle is out on the
/// network must stay cleared; FAMILY-1, a phone set up from a device backup goes on from the
/// sync file it carried instead of starting over. See docs/ICLOUD_SYNC.md §7 and §11.
@Suite struct SyncCloseAndNewInstallTests {
    let clock = SyncTestClock()

    func pair(_ cloud: SyncMemoryCloud) async throws -> (QADevice, QADevice) {
        (try await QADevice("A", cloud: cloud, clock: clock), try await QADevice("B", cloud: cloud, clock: clock))
    }

    /// A piece with a photo from each device, and a photo on its own. Both synced.
    @discardableResult
    func furnish(_ a: QADevice, _ b: QADevice) async throws -> PhotoFurniture {
        try await QACheck.settle([a, b])
        let piece = try await a.store.addFurniture(placement: SyncCheck.spot(1), displayName: "Lamp")
        _ = try await a.store.addSource(draft: try TestSupport.draft(seed: 41), toInstance: piece.instanceId, decision: .manual)
        _ = try await a.store.addPhoto(draft: try TestSupport.draft(seed: 42))
        try await QACheck.settle([a, b])
        _ = try await b.store.addSource(draft: try TestSupport.draft(seed: 43), toInstance: piece.instanceId, decision: .manual)
        try await QACheck.settle([a, b])
        let shared = await b.state()
        #expect(shared.photos.count == 3 && shared.items.count == 1)
        return piece
    }

    /// Polls a condition the session reaches on its own (no sleep decides the outcome).
    func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    // MARK: SYNC-1

    /// The session's half: a cycle out on the network when the library is switched under it
    /// (cleared, restored) used to retry on the new library. That library has no sync file, so
    /// the retry was a first sync: it fetched the whole home, downloaded every photo and wrote
    /// them into the cleared library, under whatever account was signed in. Now it throws to
    /// the app, whose fresh start checks the account first (or which turned sync off).
    @Test func aCycleOutWhenTheLibraryIsClearedDoesNotFillTheClearedLibrary() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        try await furnish(a, b)
        let before = await cloud.allEnvelopes

        await a.gate.arm()
        let cycle = Task { try await a.sync() }
        await a.gate.waitUntilHeld()
        _ = try await a.store.clearAll()
        await a.gate.release()

        await #expect(throws: SyncApplyError.libraryReplaced) { try await cycle.value }
        let cleared = await a.state()
        #expect(cleared.photos.isEmpty && cleared.allFurniture.isEmpty, "the cleared library stays empty")
        #expect(try await a.store.readSyncState() == nil, "no first sync ran on the new library")
        #expect(await cloud.allEnvelopes == before, "nothing in the cloud changed")
    }

    /// The order the app keeps when the user clears only this device with sync on
    /// (`AppModel.clearAllData(.thisDevice)` through `disableCloudSync`): close the session,
    /// which waits for the cycle out on the network to stop, then clear. The cycle stops before
    /// it changes the library, and nothing queued behind it runs on the closed session.
    @Test func closingWaitsForTheCycleOnTheNetworkAndTheClearStaysEmpty() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let piece = try await furnish(a, b)
        // Something for A's cycle to bring in, were it to finish.
        clock.advance(2)
        _ = try await b.store.rename(instanceId: piece.instanceId, displayName: "B's lamp")
        try await b.sync()

        await a.gate.arm()
        let cycle = Task { try await a.sync() }
        await a.gate.waitUntilHeld()
        // A capture queued behind the cycle, as the app's queue may hold one.
        let capture = Task { try await a.session.captureLocalEdits() }
        let closing = Task { try await a.session.close(forgetting: true) }
        let waits = await eventually { await a.session.waitingCycles == 2 }
        #expect(waits, "close waits for the cycle out on the network")
        await a.gate.release()
        try await closing.value

        await #expect(throws: CancellationError.self) { try await cycle.value }
        await #expect(throws: CancellationError.self) { try await capture.value }
        #expect(await a.state().items.first?.displayName == "Lamp", "the stopped cycle did not change the library")
        let forgotten = try #require(try await a.session.deviceState())
        #expect(forgotten.base == nil && forgotten.replica.records.isEmpty, "what sync knew is forgotten")

        _ = try await a.store.clearAll()
        // Calls that reach the closed session later (the app's queue, a push) do nothing.
        await #expect(throws: CancellationError.self) { try await a.sync() }
        await #expect(throws: CancellationError.self) { try await a.session.startOver() }
        await #expect(throws: CancellationError.self) { try await a.session.captureLocalEdits() }
        #expect(try await a.session.setSetting("k", "v") == false)
        let cleared = await a.state()
        #expect(cleared.photos.isEmpty && cleared.allFurniture.isEmpty)
        #expect(try await a.store.readSyncState() == nil)
        #expect(await cloud.allEnvelopes.compactMap { $0.decoded() }.allSatisfy(\.isLive), "no deletion was sent")
    }

    /// A cycle cancelled from outside (a push's or the background's time ran out) stops at its
    /// next step instead of carrying on with every call failing, and changes nothing.
    @Test func aCancelledCycleStopsBeforeItChangesTheLibrary() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let piece = try await furnish(a, b)
        clock.advance(2)
        _ = try await b.store.rename(instanceId: piece.instanceId, displayName: "B's lamp")
        try await b.sync()

        await a.gate.arm()
        let cycle = Task { try await a.sync() }
        await a.gate.waitUntilHeld()
        cycle.cancel()
        await a.gate.release()
        await #expect(throws: CancellationError.self) { try await cycle.value }
        #expect(await a.state().items.first?.displayName == "Lamp")
        // The session is not closed: the next cycle takes the rename.
        try await QACheck.settle([a, b])
        #expect(await a.state().items.first?.displayName == "B's lamp")
    }

    /// QA round 12, F3: a sync build finds its settings on and its marker there, but the library
    /// has no sync file at all (a build without the replacement record cleared or restored it).
    /// The app asks instead of merging; this is how it tells.
    @Test func whetherALibraryHasASyncFile() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        #expect(await SyncSession.hasSyncFile(a.store) == false, "never synced")
        try await furnish(a, b)
        #expect(await SyncSession.hasSyncFile(a.store))
        // Only the copy before it is left (a crash while replacing it): still synced.
        try FileManager.default.removeItem(at: a.syncStateURL)
        #expect(FileManager.default.fileExists(atPath: a.root.appendingPathComponent(LibraryStore.syncStateBackupFile).path))
        #expect(await SyncSession.hasSyncFile(a.store))
        _ = try await b.store.clearAll()
        #expect(await SyncSession.hasSyncFile(b.store) == false, "cleared")
    }

    // MARK: FAMILY-1

    /// A phone set up from a device backup gets the library folder, sync's file in it included,
    /// but not the app's own `Sync/` folder (kept out of device backups). Starting over there
    /// dropped the edits the old phone had recorded but never sent, and a first sync brought
    /// back everything deleted elsewhere since the backup, on every device. The new phone goes
    /// on from the file under a new device id instead.
    @Test func aPhoneSetUpFromADeviceBackupSendsTheEditsItCarriedAndKeepsLaterDeletions() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let lamp = try await furnish(a, b)
        let shelf = try await a.store.addFurniture(placement: SyncCheck.spot(3), displayName: "Shelf")
        try await QACheck.settle([a, b])
        let home = await a.state()
        let linked = Set(home.items.flatMap { $0.sources.map(\.photoId) })
        let loose = try #require(home.photos.first { !linked.contains($0.photoId) })

        // A, offline: renames the lamp and deletes the loose photo. Recorded, never sent.
        await cloud.setOffline("A", true)
        clock.advance(2)
        _ = try await a.store.rename(instanceId: lamp.instanceId, displayName: "Reading lamp")
        try await a.session.captureLocalEdits()
        clock.advance(2)
        try await a.store.deletePhoto(photoId: loose.photoId)
        try await a.session.captureLocalEdits()

        // That night's device backup becomes the new phone C; A is erased and never syncs again.
        let c = try await QADevice("C", cloud: cloud, clock: clock)
        try FileManager.default.removeItem(at: c.root)
        try FileManager.default.copyItem(at: a.root, to: c.root)
        _ = try await c.store.load()

        // After the backup, B removes the shelf.
        clock.advance(2)
        try await b.store.removeFurniture(instanceId: shelf.instanceId)
        try await b.sync()

        // What the app does on an install that never synced this library (no marker).
        #expect(try await c.session.startOnNewInstall() == .kept)
        try await QACheck.settle([c, b])
        for device in [b, c] {
            let s = await device.state()
            #expect(s.allFurniture.first { $0.instanceId == lamp.instanceId }?.displayName == "Reading lamp",
                    "\(device.name): the rename the old phone never sent survives")
            #expect(!s.photos.contains { $0.photoId == loose.photoId }, "\(device.name): the photo deleted offline stays deleted")
            #expect(!s.allFurniture.contains { $0.instanceId == shelf.instanceId },
                    "\(device.name): the shelf removed after the backup stays removed")
        }
        #expect(try await c.session.deviceState()?.clock.device != "devA", "the new phone writes under its own id")
        await QACheck.expectConverged([b, c])
    }

    /// An edit the old phone saved but never captured before the backup (the library is ahead
    /// of the file's base) still goes out from the new phone when nobody changed it later. It
    /// is stamped at the old phone's last known time (QA round 12, F1), which is after the
    /// value it replaced: an offer would have lost to that value.
    @Test func aNewPhoneSendsAnEditTheOldPhoneSavedButNeverCaptured() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let lamp = try await furnish(a, b)
        clock.advance(2)
        _ = try await a.store.rename(instanceId: lamp.instanceId, displayName: "Reading lamp")
        let c = try await QADevice("C", cloud: cloud, clock: clock)
        try FileManager.default.removeItem(at: c.root)
        try FileManager.default.copyItem(at: a.root, to: c.root)
        _ = try await c.store.load()
        clock.advance(3600)
        #expect(try await c.session.startOnNewInstall() == .kept)
        try await QACheck.settle([c, b])
        #expect(await b.state().allFurniture.first { $0.instanceId == lamp.instanceId }?.displayName == "Reading lamp")
        await QACheck.expectConverged([b, c])
    }

    /// The old phone was not erased after all: both go on. Each writes under its own id, so a
    /// deletion on one never hides an edit the other made that it had not seen.
    @Test func theOldPhoneComingBackDoesNotHideTheNewPhonesEdits() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let lamp = try await furnish(a, b)
        let c = try await QADevice("C", cloud: cloud, clock: clock)
        try FileManager.default.removeItem(at: c.root)
        try FileManager.default.copyItem(at: a.root, to: c.root)
        _ = try await c.store.load()
        #expect(try await c.session.startOnNewInstall() == .kept)

        // C renames the lamp; A, not having heard, removes it later.
        clock.advance(2)
        _ = try await c.store.rename(instanceId: lamp.instanceId, displayName: "C's lamp")
        try await c.sync()
        clock.advance(2)
        try await a.store.removeFurniture(instanceId: lamp.instanceId)
        try await a.session.captureLocalEdits()
        try await QACheck.settle([a, b, c])
        for device in [a, b, c] {
            #expect(await device.state().allFurniture.first { $0.instanceId == lamp.instanceId }?.displayName == "C's lamp",
                    "\(device.name): C's rename A never saw was not hidden by A's removal")
        }
        await QACheck.expectConverged([a, b, c])
    }

    /// Nothing to go on from (sync's file and its backup unreadable): the new install starts
    /// over, as before, and its first sync merges without losing the library.
    @Test func aNewInstallWithAnUnreadableSyncFileStartsOver() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        try await furnish(a, b)
        let c = try await QADevice("C", cloud: cloud, clock: clock)
        try FileManager.default.removeItem(at: c.root)
        try FileManager.default.copyItem(at: a.root, to: c.root)
        for name in [LibraryStore.syncStateFile, LibraryStore.syncStateBackupFile] {
            try Data("not json".utf8).write(to: c.root.appendingPathComponent(name))
        }
        _ = try await c.store.load()
        #expect(try await c.session.startOnNewInstall() == .startedOver)
        try await QACheck.settle([c, b])
        #expect(await c.state().photos.count == 3)
        await QACheck.expectConverged([b, c])
    }

    /// Going on from the carried file keeps which account it belongs to: in another account
    /// the next cycle waits for the user, and nothing goes into that account.
    @Test func aNewInstallInAnotherAccountWaitsForTheUser() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let lamp = try await furnish(a, b)
        clock.advance(2)
        _ = try await a.store.rename(instanceId: lamp.instanceId, displayName: "Reading lamp")
        try await a.session.captureLocalEdits()
        let c = try await QADevice("C", cloud: cloud, clock: clock)
        try FileManager.default.removeItem(at: c.root)
        try FileManager.default.copyItem(at: a.root, to: c.root)
        _ = try await c.store.load()
        await cloud.setAccount("account-2")
        let before = await cloud.allEnvelopes

        #expect(try await c.session.startOnNewInstall() == .kept)
        let report = try await c.sync()
        #expect(report.problem == .accountChanged && report.sent == 0 && !report.applied)
        #expect(await cloud.allEnvelopes == before, "nothing went into the other account")
    }
}
