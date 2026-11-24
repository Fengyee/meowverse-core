import Foundation
import Synchronization
import Testing
@testable import MeowverseCore

/// Fixes for the QA review, round 2 (2026-11-18): the rules the fixes rely on that the QA
/// reproductions (`SyncQA2*Tests`) do not pin down on their own.
@Suite struct SyncQA2FixTests {
    let clock = SyncTestClock()

    /// A device whose library starts as a copy of `source`'s (no sync file in it yet).
    func copy(of source: QADevice, named name: String, cloud: SyncMemoryCloud) async throws -> QADevice {
        let copy = try await QADevice(name, cloud: cloud, clock: clock)
        try FileManager.default.removeItem(at: copy.root)
        try FileManager.default.copyItem(at: source.root, to: copy.root)
        _ = try await copy.store.load()
        return copy
    }

    func notes(_ devices: [QADevice]) async -> [String] {
        var out: [String] = []
        for device in devices { out.append(await device.state().photos.first?.note ?? "-") }
        return out
    }

    // MARK: Notes on a first sync (D1)

    /// Two separate libraries with the same photo and different notes: both notes are kept
    /// (owner 2026-11-18), the cloud's first.
    @Test func twoDifferentNotesFromBeforeSyncAreBothKept() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice("A", cloud: cloud, clock: clock)
        let b = try await QADevice("B", cloud: cloud, clock: clock)
        for (device, note) in [(a, "from A"), (b, "from B")] {
            let photo = try await device.store.importPhoto(draft: try TestSupport.draft(seed: 301)).photo
            _ = try await device.store.editPhoto(photoId: photo.photoId, PhotoEdit(note: note))
        }
        try await a.sync()
        try await b.sync()
        try await QACheck.settle([a, b])
        #expect(await notes([a, b]) == ["from A\n\nfrom B", "from A\n\nfrom B"])
    }

    /// A note written with sync on still gets the older, different note of a copy next to it
    /// (owner 2026-11-18: merged even when the cloud's is newer).
    @Test func aNewNoteKeepsTheCopysOlderNoteNextToIt() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice("A", cloud: cloud, clock: clock)
        let photo = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 302)).photo
        _ = try await a.store.editPhoto(photoId: photo.photoId, PhotoEdit(note: "old"))
        let b = try await copy(of: a, named: "B", cloud: cloud)
        try await a.sync()
        clock.advance(60)
        _ = try await a.store.editPhoto(photoId: photo.photoId, PhotoEdit(note: "new"))
        try await a.sync()
        try await QACheck.settle([b, a])
        #expect(await notes([a, b]) == ["new\n\nold", "new\n\nold"])
    }

    /// A note shortened with sync on stays short: the copy's longer, older text, which already
    /// holds the new one, does not come back.
    @Test func aNoteShortenedWithSyncOnDoesNotGrowBack() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice("A", cloud: cloud, clock: clock)
        let photo = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 303)).photo
        _ = try await a.store.editPhoto(photoId: photo.photoId, PhotoEdit(note: "at the vet, all fine"))
        let b = try await copy(of: a, named: "B", cloud: cloud)
        try await a.sync()
        clock.advance(60)
        _ = try await a.store.editPhoto(photoId: photo.photoId, PhotoEdit(note: "at the vet"))
        try await a.sync()
        try await QACheck.settle([b, a])
        #expect(await notes([a, b]) == ["at the vet", "at the vet"])
    }

    // MARK: A photo that cannot be uploaded (D3, S12)

    /// This device's stored copy of a new photo is gone (or damaged): the photo waits, the
    /// cycle says so, and everything else still goes both ways.
    @Test func aPhotoWhoseCopyCannotBeReadIsReportedAndHoldsNothingElseBack() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice("A", cloud: cloud, clock: clock)
        let b = try await QADevice("B", cloud: cloud, clock: clock)
        let study = try await a.store.addRoom(name: "Study")
        try await QACheck.settle([a, b])
        let photo = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 310)).photo
        try FileManager.default.removeItem(at: a.root.appendingPathComponent(photo.originalFile))
        _ = try await a.store.renameRoom(roomId: study.roomId, name: "Atelier")
        let lamp = try await b.store.addFurniture(placement: SyncCheck.spot(2), displayName: "Lamp")
        try await b.sync()
        let report = try await a.sync()
        #expect(report.problem != nil && report.photosNotUploaded == 1, "the photo held back silently")
        #expect(report.unsent == 1)
        try await b.sync()
        #expect(await b.state().room(id: study.roomId)?.name == "Atelier")
        #expect(await b.state().photos.isEmpty, "a record without a file in the cloud")
        #expect(await a.state().allFurniture.contains { $0.instanceId == lamp.instanceId })
    }

    // MARK: Downloads are kept on disk (D4, S10)

    /// A write of the library that fails after every photo was downloaded: the next cycle
    /// downloads none of them again, and once the photos are in, nothing is left staged.
    @Test func downloadsOutlastAFailedWriteAndLeaveNothingBehind() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice("A", cloud: cloud, clock: clock)
        for i in 0..<3 { _ = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 320 + i)) }
        try await a.sync()
        let fault = FaultSwitch(nil)
        let root = TestSupport.tempDir().appendingPathComponent("Library-B", isDirectory: true)
        let catalog = try TestSupport.catalog()
        let store = LibraryStore(root: root, catalog: catalog, fault: fault.handler)
        try await store.load()
        let counter = CountingTransport(inner: cloud.endpoint("B"))
        let b = SyncSession(store: store, transport: counter, catalog: catalog, deviceID: "devB", now: clock.reader())
        fault.arm(.writeState)
        await #expect(throws: InjectedFault.failed(.writeState)) { try await b.sync() }
        #expect(counter.downloads.withLock { $0 } == 3)
        #expect(await store.snapshot().photos.isEmpty)
        let report = try await b.sync()
        #expect(report.applied && report.waitingForFiles == 0)
        #expect(counter.downloads.withLock { $0 } == 3, "downloaded again after the failed write")
        #expect(await store.snapshot().photos.count == 3)
        let staged = root.appendingPathComponent(LibraryStore.syncIncomingDir)
        #expect(TestSupport.listing(staged).isEmpty, "staged copies left behind")
        #expect(await store.integrityReport().isClean)
    }

    // MARK: Clean-up (D5, D6, S9)

    /// A photo comes back after its files left the cloud: B uploads the file but its save
    /// fails. C, which never cleaned up this file, judges on the records alone that it is a
    /// deleted photo's; the cloud says it was stored just now, so it stays.
    @Test func aFileStoredJustNowStaysThoughTheRecordsSayItsPhotoIsDeleted() async throws {
        let cloud = SyncMemoryCloud(clock: clock.reader())
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        let b = try await SyncDevice("B", cloud: cloud, clock: clock)
        let c = try await SyncDevice("C", cloud: cloud, clock: clock)
        let photo = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 330)).photo
        try await SyncCheck.settle([a, b, c])
        try await b.session.startOver()
        try await a.store.deletePhoto(photoId: photo.photoId)
        try await a.sync()
        try await c.sync()
        clock.advance(SyncSession.fileGrace + 60)
        try await a.sync()
        #expect(await !cloud.fileHashes.contains(photo.sha256))
        await cloud.failSaves("B", count: 1)
        let cut = try await b.sync()
        #expect(cut.problem == .offline)
        #expect(await cloud.fileHashes.contains(photo.sha256), "B put the file up")
        clock.advance(60)
        try await c.sync()
        #expect(await cloud.fileHashes.contains(photo.sha256), "C deleted a file the cloud had stored a minute ago")
        try await SyncCheck.settle([b, a, c])
        #expect(await a.state().photos.map(\.sha256) == [photo.sha256])
    }

    /// Deleting most of the home at once (here 21 of 24 photos) is held: no file goes until
    /// the deletion is a week old, and the cycle reports how many it kept.
    @Test func aCleanUpOfMostOfTheFilesWaitsAWeek() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        var photos: [PhotoRecord] = []
        for i in 0..<24 { photos.append(try await a.store.importPhoto(draft: try TestSupport.draft(seed: 400 + i)).photo) }
        try await a.sync()
        #expect(await cloud.fileHashes.count == 24)
        try await a.store.deletePhotos(photoIds: photos.prefix(21).map(\.photoId))
        try await a.sync()
        clock.advance(SyncSession.fileGrace + 60)
        let held = try await a.sync()
        #expect(held.cleanupHeld == 21)
        #expect(await cloud.fileHashes.count == 24, "most of the cloud's files deleted in one go")
        clock.advance(SyncSession.largeCleanupGrace)
        let report = try await a.sync()
        #expect(report.cleanupHeld == 0)
        #expect(await cloud.fileHashes == Set(photos.suffix(3).map(\.sha256)))
    }

    /// An ordinary clean-up larger than one cycle's share goes over several cycles.
    @Test func oneCycleDeletesAtMostItsShareOfFiles() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        var photos: [PhotoRecord] = []
        let total = 2 * SyncSession.collectLimit + 8, gone = SyncSession.collectLimit + 3
        for i in 0..<total { photos.append(try await a.store.importPhoto(draft: try TestSupport.draft(seed: 500 + i)).photo) }
        try await a.sync()
        try await a.store.deletePhotos(photoIds: photos.prefix(gone).map(\.photoId))
        try await a.sync()
        clock.advance(SyncSession.fileGrace + 60)
        let first = try await a.sync()
        #expect(first.cleanupHeld == 0)
        #expect(await cloud.fileHashes.count == total - SyncSession.collectLimit)
        try await a.sync()
        #expect(await cloud.fileHashes.count == total - gone)
    }

    // MARK: Coming back on a first sync (QA mutation gap)

    /// B, with sync off, renames a room and a cat that A then deletes. When B turns sync on
    /// again they come back under B's names, on both devices: the comeback is a real write, not
    /// an offer that the names from before the deletion would beat. Made after the first settle
    /// and run both ways round, so no device id decides it.
    @Test(arguments: [("A", "B"), ("B", "A")])
    func aRoomAndACatThatComeBackKeepTheNamesTheyHadHere(deleter: String, keeper: String) async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice(deleter, cloud: cloud, clock: clock)
        let b = try await QADevice(keeper, cloud: cloud, clock: clock)
        try await QACheck.settle([a, b])
        let study = try await a.store.addRoom(name: "Study")
        let mimi = try await a.store.addCat(name: "Mimi")
        try await QACheck.settle([a, b])
        try await b.session.startOver()
        clock.advance(60)
        _ = try await b.store.renameRoom(roomId: study.roomId, name: "Atelier")
        _ = try await b.store.renameCat(catId: mimi.catId, name: "Momo")
        clock.advance(60)
        try await a.store.removeRoom(roomId: study.roomId)
        try await a.store.removeCat(catId: mimi.catId)
        try await a.sync()
        clock.advance(60)
        try await QACheck.settle([b, a])
        for device in [a, b] {
            let state = await device.state()
            #expect(state.room(id: study.roomId)?.name == "Atelier", "\(device.name) (deleter \(deleter))")
            #expect(state.allCats.first { $0.catId == mimi.catId }?.name == "Momo", "\(device.name) (deleter \(deleter))")
        }
    }

    // MARK: Names with no time of their own (D2)

    /// Two separate libraries named the first cat and the first room differently, with the same
    /// number of saves. The rule (pending the owner) settles on the same names whichever device
    /// has the larger id and whichever turns sync on first: the smaller name's bytes.
    @Test(arguments: [("A", "B"), ("B", "A")])
    func twoNamesFromBeforeSyncSettleTheSameWayWhicheverIdIsLarger(first: String, second: String) async throws {
        let cloud = SyncMemoryCloud()
        let x = try await QADevice(first, cloud: cloud, clock: clock)
        let y = try await QADevice(second, cloud: cloud, clock: clock)
        for (device, cat, room) in [(x, "Mochi", "Study"), (y, "Luna", "Atelier")] {
            _ = try await device.store.setCatName(cat)
            _ = try await device.store.renameRoom(roomId: AppState.primaryRoomId, name: room)
        }
        #expect(await x.state().revision == y.state().revision)
        try await x.sync()
        try await y.sync()
        try await QACheck.settle([x, y])
        for device in [x, y] {
            let state = await device.state()
            #expect(state.catName == "Luna", "\(device.name) (first \(first))")
            #expect(state.room(id: AppState.primaryRoomId)?.name == "Atelier", "\(device.name) (first \(first))")
        }
    }
}

/// Passes every call on and counts the downloads.
final class CountingTransport: SyncTransport {
    let inner: SyncMemoryEndpoint
    let downloads = Mutex(0)

    init(inner: SyncMemoryEndpoint) { self.inner = inner }

    func accountKey() async throws -> String { try await inner.accountKey() }
    func fetchChanges(since token: SyncToken?) async throws -> SyncFetchResult { try await inner.fetchChanges(since: token) }
    func save(_ records: [SyncSave]) async throws -> [SyncSaveResult] { try await inner.save(records) }
    func hasFile(sha256: String) async throws -> Bool { try await inner.hasFile(sha256: sha256) }
    func uploadFile(sha256: String, data: Data) async throws { try await inner.uploadFile(sha256: sha256, data: data) }
    func downloadFile(sha256: String) async throws -> Data {
        downloads.withLock { $0 += 1 }
        return try await inner.downloadFile(sha256: sha256)
    }
    func deleteFile(sha256: String) async throws { try await inner.deleteFile(sha256: sha256) }
}
