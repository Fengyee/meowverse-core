import Foundation
import Testing
@testable import MeowverseCore

/// QA round 12, task A (SYNC-1, FAMILY-1, SYNC-2 fixes): adversarial cases beside the
/// author's `SyncCloseAndNewInstallTests`. Device-backup copies are made by copying the
/// library folder, as the author's tests do.
@Suite struct QARound12SyncTests {
    let clock = SyncTestClock()

    func pair(_ cloud: SyncMemoryCloud) async throws -> (QADevice, QADevice) {
        (try await QADevice("A", cloud: cloud, clock: clock), try await QADevice("B", cloud: cloud, clock: clock))
    }

    func lamp(_ a: QADevice, _ b: QADevice) async throws -> PhotoFurniture {
        try await QACheck.settle([a, b])
        let piece = try await a.store.addFurniture(placement: SyncCheck.spot(1), displayName: "Lamp")
        _ = try await a.store.addSource(draft: try TestSupport.draft(seed: 81), toInstance: piece.instanceId, decision: .manual)
        try await QACheck.settle([a, b])
        return piece
    }

    /// The device backup as the new phone gets it: the library folder, sync's file in it.
    func newPhone(from old: QADevice, _ name: String, _ cloud: SyncMemoryCloud) async throws -> QADevice {
        let c = try await QADevice(name, cloud: cloud, clock: clock)
        try FileManager.default.removeItem(at: c.root)
        try FileManager.default.copyItem(at: old.root, to: c.root)
        _ = try await c.store.load()
        return c
    }

    func name(_ device: QADevice, _ piece: PhotoFurniture) async -> String? {
        await device.state().allFurniture.first { $0.instanceId == piece.instanceId }?.displayName
    }

    // MARK: FAMILY-1

    /// The old phone saved an edit that sync had not captured yet when the device backup was
    /// made (the app was suspended or ended between the save and the queued capture). Later,
    /// online, the old phone sent that edit and then made a newer one, and was then erased.
    /// Going on from the carried file, the new phone sees the uncaptured gap between the
    /// file's base and its library as its own edit and stamps it now, after the old phone's
    /// newer edit: the stale value replaces the newer one on every device. Starting over (the
    /// behaviour before the fix) kept the newer value, because a first sync only offers.
    @Test func aNewPhoneDoesNotRestampAnEditTheOldPhoneLaterReplaced() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let piece = try await lamp(a, b)

        clock.advance(2)
        _ = try await a.store.rename(instanceId: piece.instanceId, displayName: "Reading lamp")
        // No capture: that night's device backup carries the library ahead of sync's base.
        let c = try await newPhone(from: a, "C", cloud)

        // The next morning the old phone goes on: the rename goes out, then a newer one.
        clock.advance(2)
        try await a.sync()
        clock.advance(2)
        _ = try await a.store.rename(instanceId: piece.instanceId, displayName: "Desk lamp")
        try await a.session.captureLocalEdits()
        try await QACheck.settle([a, b])
        #expect(await name(b, piece) == "Desk lamp")

        // The old phone is erased; the new one starts days later.
        clock.advance(3600)
        #expect(try await c.session.startOnNewInstall() == .kept)
        try await QACheck.settle([b, c])
        for device in [b, c] {
            #expect(await name(device, piece) == "Desk lamp",
                    "\(device.name): the old phone's newer rename is not replaced by the value it had at the backup")
        }
    }

    /// An older sync file (no `collectedFiles`, `repairCursor`, `token`) still lets a new
    /// install go on, and its unsent edit is sent.
    @Test func aNewPhoneGoesOnFromAnOlderFormatFile() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let piece = try await lamp(a, b)
        await cloud.setOffline("A", true)
        clock.advance(2)
        _ = try await a.store.rename(instanceId: piece.instanceId, displayName: "Reading lamp")
        try await a.session.captureLocalEdits()
        let c = try await newPhone(from: a, "C", cloud)
        for file in [LibraryStore.syncStateFile, LibraryStore.syncStateBackupFile] {
            let url = c.root.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url),
                  var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for key in ["collectedFiles", "repairCursor", "token"] { json.removeValue(forKey: key) }
            try JSONSerialization.data(withJSONObject: json).write(to: url)
        }
        #expect(try await c.session.startOnNewInstall() == .kept)
        try await QACheck.settle([b, c])
        #expect(await name(b, piece) == "Reading lamp")
        await QACheck.expectConverged([b, c])
    }

    /// A photo the old phone added offline (captured, its file never uploaded) reaches the
    /// other devices from the new phone, file and all.
    @Test func aNewPhoneUploadsAPhotoTheOldPhoneNeverSent() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        _ = try await lamp(a, b)
        await cloud.setOffline("A", true)
        let photo = try await a.store.addPhoto(draft: try TestSupport.draft(seed: 82))
        try await a.session.captureLocalEdits()
        let c = try await newPhone(from: a, "C", cloud)
        #expect(try await c.session.startOnNewInstall() == .kept)
        try await QACheck.settle([b, c])
        #expect(await b.state().photos.contains { $0.photoId == photo.photoId }, "the offline photo reached B")
        #expect(await b.filesAreWhole().isEmpty)
        await QACheck.expectConverged([b, c])
    }

    /// Two phones set up from the same backup: each goes on under its own id, so one's
    /// removal does not hide the other's rename it had not seen.
    @Test func twoPhonesFromOneBackupKeepEachOthersUnseenEdits() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let piece = try await lamp(a, b)
        let c = try await newPhone(from: a, "C", cloud)
        let d = try await newPhone(from: a, "D", cloud)
        #expect(try await c.session.startOnNewInstall() == .kept)
        #expect(try await d.session.startOnNewInstall() == .kept)
        clock.advance(2)
        _ = try await d.store.rename(instanceId: piece.instanceId, displayName: "D's lamp")
        try await d.session.captureLocalEdits()
        clock.advance(2)
        try await c.store.removeFurniture(instanceId: piece.instanceId)
        try await c.sync()
        try await QACheck.settle([b, c, d])
        for device in [b, c, d] {
            #expect(await name(device, piece) == "D's lamp", "\(device.name): D's unseen rename survives C's removal")
        }
        let ids = [try await c.session.deviceState()?.clock.device, try await d.session.deviceState()?.clock.device]
        #expect(ids[0] != ids[1] && !ids.contains("devA"))
    }

    /// The new id is what keeps an edit alive (not only the bookkeeping): the new phone renames
    /// the lamp offline; the old phone, not having heard, edits it later and then removes it.
    /// Under one shared id the removal's version covers the new phone's earlier rename, and the
    /// rename is lost although the old phone never saw it.
    @Test func theOldPhonesLaterRemovalDoesNotCoverTheNewPhonesUnseenRename() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let piece = try await lamp(a, b)
        let c = try await newPhone(from: a, "C", cloud)
        #expect(try await c.session.startOnNewInstall() == .kept)
        clock.advance(2)
        _ = try await c.store.rename(instanceId: piece.instanceId, displayName: "C's lamp")
        try await c.session.captureLocalEdits()
        clock.advance(2)
        let photo = try #require(await a.state().items.first?.sources.first?.photoId)
        _ = try await a.store.setFavorite(photoIds: [photo], true)
        _ = try await a.store.rename(instanceId: piece.instanceId, displayName: "A's lamp")
        try await a.session.captureLocalEdits()
        clock.advance(2)
        try await a.store.removeFurniture(instanceId: piece.instanceId)
        try await a.sync()
        try await QACheck.settle([a, b, c])
        for device in [a, b, c] {
            #expect(await name(device, piece) != nil, "\(device.name): C's rename, unseen by A, keeps the lamp")
        }
        await QACheck.expectConverged([a, b, c])
    }

    // MARK: SYNC-1

    /// Two closes at once (turning off twice, a clear right after a toggle): both return once
    /// the held cycle stopped, neither throws, and a clear after them stays empty.
    @Test func closingTwiceAtOnceBothReturnAndTheClearStaysEmpty() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let piece = try await lamp(a, b)
        clock.advance(2)
        _ = try await b.store.rename(instanceId: piece.instanceId, displayName: "B's lamp")
        try await b.sync()

        await a.gate.arm()
        let cycle = Task { try await a.sync() }
        await a.gate.waitUntilHeld()
        let first = Task { try await a.session.close(forgetting: true) }
        let second = Task { try await a.session.close(forgetting: true) }
        try? await Task.sleep(for: .milliseconds(20))
        await a.gate.release()
        try await first.value
        try await second.value
        await #expect(throws: CancellationError.self) { try await cycle.value }
        #expect(await name(a, piece) == "Lamp")
        _ = try await a.store.clearAll()
        await #expect(throws: CancellationError.self) { try await a.sync() }
        let cleared = await a.state()
        #expect(cleared.photos.isEmpty && cleared.allFurniture.isEmpty)
    }

    /// Sync turned off with the toggle (the close is not awaited by anyone), then 清除全部数据
    /// at once: the clear does not wait for the close here (`syncWasOn` is already false), so
    /// the clear lands while the cycle is still held. The cycle must still not refill the
    /// cleared library, and the close's forgetting, which now runs on the new library, must
    /// leave nothing a later sync would read as a base.
    @Test func aClearRightAfterTurningOffStaysEmptyWithoutWaitingForTheClose() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        _ = try await lamp(a, b)
        let before = await cloud.allEnvelopes

        await a.gate.arm()
        let cycle = Task { try await a.sync() }
        await a.gate.waitUntilHeld()
        cycle.cancel()
        let closing = Task { try await a.session.close(forgetting: true) }
        _ = try await a.store.clearAll()
        await a.gate.release()
        await #expect(throws: CancellationError.self) { try await cycle.value }
        try await closing.value

        let cleared = await a.state()
        #expect(cleared.photos.isEmpty && cleared.allFurniture.isEmpty, "the cleared library stays empty")
        let left = try await a.session.deviceState()
        #expect(left?.base == nil && left?.dirty.isEmpty != false, "nothing a later sync reads as this library's base")
        #expect(await cloud.allEnvelopes == before, "nothing in the cloud changed")
    }

    /// A cycle cancelled after its push went out (the fetch is held): sync's file still says
    /// the edit is unsent, with the old tag. Another device then removes the piece, having
    /// seen the edit. The resend must not bring the piece back.
    @Test func aCycleCancelledAfterItsPushDoesNotUndoALaterRemoval() async throws {
        let cloud = SyncMemoryCloud()
        let (a, b) = try await pair(cloud)
        let piece = try await lamp(a, b)
        clock.advance(2)
        _ = try await a.store.rename(instanceId: piece.instanceId, displayName: "Reading lamp")
        try await a.session.captureLocalEdits()

        await a.gate.arm()
        let cycle = Task { try await a.sync() }
        await a.gate.waitUntilHeld()
        cycle.cancel()
        await a.gate.release()
        await #expect(throws: CancellationError.self) { try await cycle.value }

        try await b.sync()
        #expect(await name(b, piece) == "Reading lamp", "the push did go out")
        clock.advance(2)
        try await b.store.removeFurniture(instanceId: piece.instanceId)
        try await b.sync()
        try await QACheck.settle([a, b])
        for device in [a, b] {
            #expect(await name(device, piece) == nil, "\(device.name): the removal stays")
        }
        await QACheck.expectConverged([a, b])
    }
}
