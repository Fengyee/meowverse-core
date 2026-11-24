import Foundation
import Testing
@testable import MeowverseCore

/// COMPAT-2: a device that doesn't have a piece's model must not send its stand-in back. Model,
/// spot, finish and storage are one register, so any place edit there would carry the old model.
/// Each test runs with both device names: the id decides ties.
@Suite(.timeLimit(.minutes(2))) struct SyncOlderCatalogTests {
    static let names = [["A", "B"], ["B", "A"]]
    static let restyled = "kenney-chairRounded"

    private static func olderCatalog() throws -> FurnitureCatalog {
        var json = try #require(JSONSerialization.jsonObject(with: TestSupport.catalogData()) as? [String: Any])
        let models = try #require(json["models"] as? [[String: Any]])
        json["models"] = models.filter { $0["id"] as? String != restyled }
        let older = try FurnitureCatalog(data: JSONSerialization.data(withJSONObject: json))
        try #require(older.model(id: restyled) == nil)
        return older
    }

    /// A chair both devices have, then restyled on the newer one into a model the older lacks.
    private func restyledChair(_ names: [String], skew: TimeInterval = 0) async throws
        -> (new: SyncDevice, old: SyncDevice, id: String, clock: SyncTestClock) {
        let cloud = SyncMemoryCloud(), clock = SyncTestClock()
        let new = try await SyncDevice(names[0], cloud: cloud, clock: clock, skew: skew)
        let old = try await SyncDevice(names[1], cloud: cloud, clock: clock, skew: skew, catalog: Self.olderCatalog())
        try await SyncCheck.settle([new, old])
        let chair = try await new.store.addFurniture(placement: SyncCheck.chair, displayName: "Chair")
        try await SyncCheck.settle([new, old])
        clock.advance(5)
        var styled = SyncCheck.chair
        styled.modelId = Self.restyled
        _ = try await new.store.updatePlacement(instanceId: chair.instanceId, placement: styled)
        try await SyncCheck.settle([new, old])
        let held = try #require(await old.state().allFurniture.first { $0.instanceId == chair.instanceId })
        try #require(held.modelId == SyncCheck.chair.modelId)
        clock.advance(5)
        return (new, old, chair.instanceId, clock)
    }

    private func expectRestyleKept(_ device: SyncDevice, _ id: String) async throws {
        let state = await device.state()
        let piece = try #require(state.items.first { $0.instanceId == id }, "the piece was put away")
        #expect(piece.modelId == Self.restyled)
        #expect(piece.x == SyncCheck.chair.x && piece.z == SyncCheck.chair.z)
    }

    @Test(arguments: names) func aMoveOnTheOlderDeviceKeepsTheRestyle(names: [String]) async throws {
        let (new, old, id, _) = try await restyledChair(names)
        var moved = SyncCheck.chair
        moved.x = 8
        moved.z = 0
        _ = try await old.store.updatePlacement(instanceId: id, placement: moved)
        try await SyncCheck.settle([old, new])
        try await expectRestyleKept(new, id)
    }

    @Test(arguments: names) func puttingItAwayOnTheOlderDeviceKeepsTheRestyle(names: [String]) async throws {
        let (new, old, id, _) = try await restyledChair(names)
        _ = try await old.store.stowFurniture(instanceId: id)
        try await SyncCheck.settle([old, new])
        try await expectRestyleKept(new, id)
    }

    /// Only the place is held back: what doesn't carry the model still syncs.
    @Test(arguments: names) func aRenameOnTheOlderDeviceStillSyncs(names: [String]) async throws {
        let (new, old, id, _) = try await restyledChair(names)
        _ = try await old.store.rename(instanceId: id, displayName: "Window chair")
        try await SyncCheck.settle([old, new])
        try await expectRestyleKept(new, id)
        #expect(await new.state().items.first { $0.instanceId == id }?.displayName == "Window chair")
    }

    /// Turning sync on again seeds the place from the library, stamped with its last change.
    @Test(arguments: names) func startingOverOnTheOlderDeviceKeepsTheRestyle(names: [String]) async throws {
        // The seed's stamp is the library's own time, on the real clock: sync's clocks run an hour
        // behind it, so the move is later than the restyle.
        let behind = Date().timeIntervalSince(SyncTestClock().now) - 3600
        let (new, old, id, _) = try await restyledChair(names, skew: behind)
        var moved = SyncCheck.chair
        moved.x = 8
        moved.z = 0
        _ = try await old.store.updatePlacement(instanceId: id, placement: moved)
        try await old.session.startOver()
        try await SyncCheck.settle([old, new])
        try await expectRestyleKept(new, id)
    }

    /// After the update the piece shows the restyle, not what was held back meanwhile.
    @Test(arguments: names) func updatingTheOlderDeviceBringsTheRestyle(names: [String]) async throws {
        let (new, old, id, clock) = try await restyledChair(names)
        var moved = SyncCheck.chair
        moved.x = 8
        moved.z = 0
        _ = try await old.store.updatePlacement(instanceId: id, placement: moved)
        try await old.sync()
        let catalog = try TestSupport.catalog()
        let store = LibraryStore(root: old.root, catalog: catalog)
        try await store.load()
        let session = SyncSession(store: store, transport: old.cloud.endpoint(old.name), catalog: catalog,
                                  deviceID: "dev\(old.name)", now: clock.reader())
        _ = try await session.sync()
        let updated = await store.snapshot()
        #expect(updated.items.first { $0.instanceId == id }?.modelId == Self.restyled)
        try await expectRestyleKept(new, id)
    }

    /// The interface refuses the place edit, so it has to know: after a relaunch with no network too.
    @Test(arguments: names) func theOlderDeviceKnowsThePieceWithoutANetwork(names: [String]) async throws {
        let (_, old, id, clock) = try await restyledChair(names)
        #expect(try await old.sync().piecesFromNewerVersion == [id])
        await old.cloud.setOffline(old.name, true)
        let relaunched = SyncSession(store: old.store, transport: old.cloud.endpoint(old.name), catalog: try Self.olderCatalog(),
                                     deviceID: "dev\(old.name)", now: clock.reader())
        #expect(await relaunched.standing()?.piecesFromNewerVersion == [id])
        #expect(try await relaunched.sync().piecesFromNewerVersion == [id])
    }

    /// JOURNEY-FAMILY-6: the piece doesn't show here, its photo does, and that photo is on furniture.
    @Test(arguments: names) func photosOfAPieceOnlyTheNewerVersionShowsAreNotUnfiled(names: [String]) async throws {
        let cloud = SyncMemoryCloud(), clock = SyncTestClock()
        let new = try await SyncDevice(names[0], cloud: cloud, clock: clock)
        var styled = SyncCheck.chair
        styled.modelId = Self.restyled
        let chair = try await new.store.addFurniture(placement: styled, displayName: "Chair")
        let photo = try await new.store.importPhoto(draft: try TestSupport.draft(seed: 606)).photo
        _ = try await new.store.linkPhoto(photoId: photo.photoId, toInstance: chair.instanceId)
        let loose = try await new.store.importPhoto(draft: try TestSupport.draft(seed: 607)).photo
        try await new.sync()

        let old = try await SyncDevice(names[1], cloud: cloud, clock: clock, catalog: Self.olderCatalog())
        let report = try await old.sync()
        let state = await old.state()
        try #require(state.allFurniture.isEmpty && state.photos.count == 2)
        #expect(report.photosOnNewerPieces == [photo.photoId])
        #expect(await old.session.standing()?.photosOnNewerPieces == [photo.photoId])
        let unfiled = PhotoLibrary.sections(in: state, filter: .unlinked, linkedElsewhere: [photo.photoId]).flatMap(\.photos)
        #expect(unfiled.map(\.photoId) == [loose.photoId])
        #expect(PhotoLibrary.count(in: state, filter: .unlinked, linkedElsewhere: [photo.photoId]) == 1)
    }
}
