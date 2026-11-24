import Foundation
import Testing
@testable import MeowverseCore

/// QA review, round 2 (2026-11-18): turning sync on with real data on two devices. A first sync
/// must merge both sides, delete nothing, and keep every user choice that is newer than the other
/// side's data (docs/ICLOUD_SYNC.md §7: data from before sync "一定输给开启后的真实修改").
///
/// "A copy" below is a library that was the same as another device's at some point: restored
/// from that device's backup, or the folder copied before either device turned sync on.
@Suite struct SyncQA2FirstSyncTests {
    let clock = SyncTestClock()

    /// A device whose library starts as a copy of `source`'s (no sync file in it yet).
    func copy(of source: QADevice, named name: String, cloud: SyncMemoryCloud) async throws -> QADevice {
        let copy = try await QADevice(name, cloud: cloud, clock: clock)
        try FileManager.default.removeItem(at: copy.root)
        try FileManager.default.copyItem(at: source.root, to: copy.root)
        _ = try await copy.store.load()
        #expect(try await copy.session.deviceState() == nil, "the copy has no sync file")
        return copy
    }

    // MARK: Choices made after sync was on

    /// A turns sync on, then takes a favourite off a photo, clears its note and its typed day.
    /// B, a copy of A's library from before, turns sync on afterwards. B's values are older than
    /// A's choices; they must not come back on either device.
    @Test func aCopyTurningSyncOnLaterDoesNotUndoChoicesMadeAfterSyncWasOn() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice("A", cloud: cloud, clock: clock)
        let photo = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 201)).photo
        _ = try await a.store.editPhoto(photoId: photo.photoId,
                                        PhotoEdit(favorite: true, note: "at the vet", captureDate: .set("2020-01-01")))
        let b = try await copy(of: a, named: "B", cloud: cloud)
        try await a.sync()
        clock.advance(60)
        _ = try await a.store.editPhoto(photoId: photo.photoId, PhotoEdit(favorite: false, note: "", captureDate: .clear))
        try await a.sync()
        clock.advance(60)
        try await QACheck.settle([b, a])
        for device in [a, b] {
            let shown = try #require(await device.state().photos.first)
            #expect(!shown.favorite, "\(device.name): the favourite A took off after sync was on came back")
            #expect(shown.note == "", "\(device.name): the note A cleared after sync was on came back")
            #expect(shown.captureDateSource != .user, "\(device.name): the day A cleared after sync was on came back")
        }
        await QACheck.expectConverged([a, b])
    }

    /// The same through the app's own path: A turns sync on, edits, and later opens its library
    /// from an older copy (a restore of an older backup, then the app's fresh start). The older
    /// copy must not undo the edit everywhere.
    @Test func restoringAnOlderBackupDoesNotUndoAChoiceMadeSince() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice("A", cloud: cloud, clock: clock)
        let b = try await QADevice("B", cloud: cloud, clock: clock)
        let photo = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 202)).photo
        _ = try await a.store.setFavorite(photoIds: [photo.photoId], true)
        let backup = TestSupport.tempDir().appendingPathComponent("older-copy", isDirectory: true)
        try FileManager.default.copyItem(at: a.root, to: backup)
        try await QACheck.settle([a, b])
        clock.advance(3600)
        // On B, after sync was on: the user takes the favourite off.
        _ = try await b.store.setFavorite(photoIds: [photo.photoId], false)
        try await QACheck.settle([b, a])
        #expect(await a.state().photos.first?.favorite == false)
        // A restores the older backup (the library folder is replaced, no sync file in it).
        clock.advance(3600)
        try FileManager.default.removeItem(at: a.root)
        try FileManager.default.copyItem(at: backup, to: a.root)
        _ = try await a.store.load()
        try await a.session.startOver()
        try await QACheck.settle([a, b])
        for device in [a, b] {
            #expect(await device.state().photos.first?.favorite == false,
                    "\(device.name): the older backup's favourite overrode the user's later choice")
        }
    }

    // MARK: Names that have no time of their own

    /// Two separate libraries. On A the user named the cat; B still has the default name. Turning
    /// sync on must keep the name the user gave, whichever device id happens to be larger.
    @Test(arguments: [("A", "B"), ("B", "A")])
    func theCatsNameIsNotReplacedByTheOtherDevicesDefault(namer: String, other: String) async throws {
        let cloud = SyncMemoryCloud()
        let n = try await QADevice(namer, cloud: cloud, clock: clock)
        let o = try await QADevice(other, cloud: cloud, clock: clock)
        _ = try await n.store.setCatName("Mochi")
        _ = try await n.store.importPhoto(draft: try TestSupport.draft(seed: 203))
        _ = try await o.store.importPhoto(draft: try TestSupport.draft(seed: 204))
        #expect(await o.state().catName == AppState.defaultCatName)
        try await n.sync()
        try await o.sync()
        try await QACheck.settle([n, o])
        for device in [n, o] {
            #expect(await device.state().catName == "Mochi",
                    "\(device.name): the cat the user named on \(namer) is called the default again (namer \(namer))")
            #expect(await device.state().photos.count == 2, "\(device.name)")
        }
    }

    /// B is a copy of A's library. Afterwards, still before sync, A renames a room and a cat and a
    /// piece. Turning sync on must keep A's newer names whichever id is larger. The piece is the
    /// control: it has `updatedAt`, rooms and cats have no time of their own.
    @Test(arguments: [("A", "B"), ("B", "A")])
    func renamesMadeOnOneCopyBeforeSyncSurviveWhicheverIdIsLarger(renamer: String, other: String) async throws {
        let cloud = SyncMemoryCloud()
        let r = try await QADevice(renamer, cloud: cloud, clock: clock)
        let study = try await r.store.addRoom(name: "Study")
        let mimi = try await r.store.addCat(name: "Mimi")
        let lamp = try await r.store.addFurniture(placement: SyncCheck.spot(1), displayName: "Lamp")
        let o = try await copy(of: r, named: other, cloud: cloud)
        // The store's `updatedAt` is real time in whole seconds (`LibraryStore.now()`).
        try await Task.sleep(for: .milliseconds(1100))
        _ = try await r.store.renameRoom(roomId: study.roomId, name: "Atelier")
        _ = try await r.store.renameCat(catId: mimi.catId, name: "Momo")
        _ = try await r.store.rename(instanceId: lamp.instanceId, displayName: "Desk lamp")
        try await o.sync()
        try await r.sync()
        try await QACheck.settle([o, r])
        for device in [r, o] {
            let state = await device.state()
            #expect(state.allFurniture.first { $0.instanceId == lamp.instanceId }?.displayName == "Desk lamp",
                    "\(device.name): control (renamer \(renamer))")
            #expect(state.room(id: study.roomId)?.name == "Atelier",
                    "\(device.name): the room's newer name was lost (renamer \(renamer))")
            #expect(state.allCats.first { $0.catId == mimi.catId }?.name == "Momo",
                    "\(device.name): the cat's newer name was lost (renamer \(renamer))")
        }
        await QACheck.expectConverged([r, o])
    }

    // MARK: Nothing is deleted

    /// Two failures in a row: `state.json` is damaged (the library opens from its backup and
    /// sync is rebased), the user edits a few times, then sync's own file is damaged too and
    /// sync reads `sync-state.backup.json`. That copy must be rebased as well, or the gap between
    /// the backup library and sync's older base reads as the user deleting B's photo and lamp
    /// (the second rebase write no other test exercised).
    @Test func aDamagedSyncFileAfterOpeningTheLibrarysBackupDeletesNothingElsewhere() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice("A", cloud: cloud, clock: clock)
        let b = try await QADevice("B", cloud: cloud, clock: clock)
        _ = try await a.store.addCat(name: "A's cat")
        try await QACheck.settle([a, b])
        let photo = try await b.store.importPhoto(draft: try TestSupport.draft(seed: 205)).photo
        let lamp = try await b.store.addFurniture(placement: SyncCheck.spot(1), displayName: "B's lamp")
        try await QACheck.settle([a, b])
        try Data("{ damaged".utf8).write(to: a.root.appendingPathComponent(LibraryStore.stateFile))
        _ = try await a.store.load()
        #expect(await a.store.recoveredFromBackup)
        let study = try await a.store.addRoom(name: "Study")
        _ = try await a.store.renameRoom(roomId: study.roomId, name: "Studio")
        _ = try await a.store.renameRoom(roomId: study.roomId, name: "Atelier")
        try Data("{ damaged".utf8).write(to: a.syncStateURL)
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(state.photos.map(\.photoId) == [photo.photoId], "\(device.name): B's photo was deleted everywhere")
            #expect(state.allFurniture.map(\.instanceId) == [lamp.instanceId], "\(device.name): B's lamp was deleted everywhere")
        }
    }

    /// The owner's case in small: two separate libraries, each with photos on pieces, extra rooms
    /// and a cat, one photo imported on both. Both turn sync on, one after the other; every photo,
    /// piece, room and cat of either side is on both devices with its file, and a second round
    /// changes nothing.
    @Test func twoRealLibrariesTurningSyncOnKeepEverythingOfBoth() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice("A", cloud: cloud, clock: clock)
        let b = try await QADevice("B", cloud: cloud, clock: clock)
        var photos = Set<String>(), pieces = Set<String>(), rooms = Set<String>(), cats = Set<String>()
        for (device, base) in [(a, 210), (b, 220)] {
            for i in 0..<3 {
                let piece = try await device.store.commitNewFurniture(draft: try TestSupport.draft(seed: base + i),
                                                                      placement: SyncCheck.spot(i + (device.name == "A" ? 0 : 4)),
                                                                      displayName: "\(device.name)\(i)", decision: .manual)
                pieces.insert(piece.instanceId)
                let photoId = try #require(piece.sources.first?.photoId)
                photos.insert(try #require(await device.state().photo(id: photoId)?.sha256))
            }
            let shared = try await device.store.importPhoto(draft: try TestSupport.draft(seed: 230)).photo
            photos.insert(shared.sha256)
            rooms.insert(try await device.store.addRoom(name: "\(device.name) room").roomId)
            cats.insert(try await device.store.addCat(name: "\(device.name) cat").catId)
        }
        try await a.sync()
        try await b.sync()
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(Set(state.photos.map(\.sha256)) == photos, "\(device.name): photos")
            #expect(Set(state.allFurniture.map(\.instanceId)) == pieces, "\(device.name): pieces")
            #expect(state.allFurniture.allSatisfy { $0.sources.count == 1 }, "\(device.name): a piece lost its photo")
            #expect(rooms.isSubset(of: Set(state.allRooms.map(\.roomId))), "\(device.name): rooms")
            #expect(cats.isSubset(of: Set(state.allCats.map(\.catId))), "\(device.name): cats")
            #expect(await device.filesAreWhole() == [], "\(device.name)")
            let again = try await device.sync()
            #expect(!again.applied && again.sent == 0 && again.unsent == 0)
        }
        await QACheck.expectConverged([a, b])
    }
}
