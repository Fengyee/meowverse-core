import Foundation
import Testing
@testable import MeowverseCore

/// Several rooms and several cats: what the file keeps, what each room judges a placement
/// against, and what removing a room or a cat leaves behind.
@Suite struct RoomsAndCatsTests {
    private func home() async throws -> (root: URL, store: LibraryStore, chair: PhotoFurniture) {
        let root = TestSupport.tempDir()
        let store = LibraryStore(root: root, catalog: try TestSupport.catalog())
        let chair = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 71),
                                                       placement: Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2),
                                                       displayName: "椅", decision: .manual)
        return (root, store, chair)
    }

    private let spot = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2)

    // MARK: The default home

    @Test func aHomeWithOneRoomAndOneCatWritesNoRoomsOrCats() async throws {
        let (root, store, _) = try await home()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = await store.snapshot()
        #expect(state.allRooms == [Room(roomId: AppState.primaryRoomId)])
        #expect(state.allCats == [Cat(catId: AppState.primaryCatId, name: state.catName)])
        #expect(state.furniture(inRoom: AppState.primaryRoomId).count == 1)
        let text = String(decoding: try LibraryStore.encodeState(state), as: UTF8.self)
        #expect(!text.contains("\"rooms\"") && !text.contains("\"cats\"") && !text.contains("\"roomId\""))
    }

    @Test func goingBackToOneUnnamedRoomAndOneCatLeavesTheFileAsItWas() async throws {
        let (root, store, _) = try await home()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = await store.snapshot()
        let room = try await store.addRoom(name: "书房")
        let cat = try await store.addCat(name: "团子")
        try await store.removeRoom(roomId: room.roomId)
        try await store.removeCat(catId: cat.catId)
        // Only the count of writes tells the two apart.
        var after = await store.snapshot()
        #expect(after.rooms.isEmpty && after.cats.isEmpty)
        after.revision = before.revision
        #expect(after == before)
    }

    // MARK: Rooms

    @Test func eachRoomHasItsOwnFloor() async throws {
        let (root, store, chair) = try await home()
        defer { try? FileManager.default.removeItem(at: root) }
        let study = try await store.addRoom(name: "  书房 ")
        #expect(study.name == "书房")
        // The same spot is taken in the first room and free in the new one.
        await #expect(throws: StoreError.self) { try await store.addFurniture(placement: spot, displayName: "二") }
        let second = try await store.addFurniture(placement: spot, displayName: "二", roomId: study.roomId)
        #expect(second.roomId == study.roomId)
        let state = await store.snapshot()
        #expect(state.furniture(inRoom: AppState.primaryRoomId).map(\.instanceId) == [chair.instanceId])
        #expect(state.furniture(inRoom: study.roomId).map(\.instanceId) == [second.instanceId])
        #expect(state.placedFurniture.count == 2)
        #expect(state.roomId(ofFurniture: chair.instanceId) == AppState.primaryRoomId)
        await #expect(throws: StoreError.unknownRoom) { try await store.addFurniture(placement: spot, displayName: "三", roomId: "nope") }

        let reopened = LibraryStore(root: root, catalog: try TestSupport.catalog())
        #expect(try await reopened.load() == state)
    }

    @Test func aPieceMovesToAnotherRoomAndBackWithItsPhotos() async throws {
        let (root, store, chair) = try await home()
        defer { try? FileManager.default.removeItem(at: root) }
        let study = try await store.addRoom()
        let moved = try await store.updatePlacement(instanceId: chair.instanceId, placement: Placement(modelId: "kenney-chair", x: 0, z: 0, width: 2, depth: 2), roomId: study.roomId)
        #expect(moved.roomId == study.roomId && moved.sources.count == 1)
        #expect(await store.snapshot().furniture(inRoom: AppState.primaryRoomId).isEmpty)
        // A change of place alone keeps the room.
        let nudged = try await store.updatePlacement(instanceId: chair.instanceId, placement: spot)
        #expect(nudged.roomId == study.roomId)
        let back = try await store.updatePlacement(instanceId: chair.instanceId, placement: spot, roomId: AppState.primaryRoomId)
        #expect(back.roomId == nil)
        await #expect(throws: StoreError.unknownRoom) { try await store.updatePlacement(instanceId: chair.instanceId, placement: spot, roomId: "nope") }
    }

    @Test func aPieceComesOutOfTheBoxIntoTheRoomAsked() async throws {
        let (root, store, chair) = try await home()
        defer { try? FileManager.default.removeItem(at: root) }
        let study = try await store.addRoom()
        _ = try await store.stowFurniture(instanceId: chair.instanceId)
        let out = try await store.restoreFurniture(instanceId: chair.instanceId, placement: spot, roomId: study.roomId)
        #expect(out.roomId == study.roomId)
        _ = try await store.stowFurniture(instanceId: chair.instanceId)
        let home = try await store.restoreFurniture(instanceId: chair.instanceId, placement: spot)
        #expect(home.roomId == nil)
    }

    @Test func renamingRoomsAndTheLimit() async throws {
        let (root, store, _) = try await home()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await store.renameRoom(roomId: AppState.primaryRoomId, name: "客厅").name == "客厅")
        #expect(await store.snapshot().allRooms.map(\.name) == ["客厅"])
        #expect(try await store.renameRoom(roomId: AppState.primaryRoomId, name: " ").name == nil)
        #expect(await store.snapshot().rooms.isEmpty)
        await #expect(throws: StoreError.unknownRoom) { try await store.renameRoom(roomId: "nope", name: "x") }
        for _ in 1..<AppState.maxRooms { _ = try await store.addRoom() }
        await #expect(throws: StoreError.tooManyRooms) { try await store.addRoom() }
        #expect(await store.snapshot().allRooms.count == AppState.maxRooms)
    }

    @Test func removingARoomPutsItsFurnitureAwayAndKeepsThePhotos() async throws {
        let (root, store, chair) = try await home()
        defer { try? FileManager.default.removeItem(at: root) }
        let study = try await store.addRoom(name: "书房")
        let cat = try await store.addCat(name: "团子", roomId: study.roomId)
        _ = try await store.updatePlacement(instanceId: chair.instanceId, placement: spot, roomId: study.roomId)
        let photos = await store.snapshot().photos

        await #expect(throws: StoreError.firstRoom) { try await store.removeRoom(roomId: AppState.primaryRoomId) }
        await #expect(throws: StoreError.unknownRoom) { try await store.removeRoom(roomId: "nope") }

        // A locked piece keeps the room.
        try await store.setLocked(instanceIds: [chair.instanceId], true)
        let locked = await store.snapshot()
        await #expect(throws: StoreError.locked) { try await store.removeRoom(roomId: study.roomId) }
        #expect(await store.snapshot() == locked)
        try await store.setLocked(instanceIds: [chair.instanceId], false)

        try await store.removeRoom(roomId: study.roomId)
        let state = await store.snapshot()
        #expect(state.allRooms.map(\.roomId) == [AppState.primaryRoomId])
        #expect(state.placedFurniture.isEmpty)
        #expect(state.storedFurniture.map(\.instanceId) == [chair.instanceId])
        #expect(state.storedFurniture[0].roomId == nil && state.storedFurniture[0].sources.count == 1)
        #expect(state.photos == photos)
        // The cat that lived there keeps the user company now.
        #expect(state.cat(id: cat.catId)?.roomId == nil)
        let reopened = LibraryStore(root: root, catalog: try TestSupport.catalog())
        #expect(try await reopened.load() == state)
    }

    // MARK: Cats

    @Test func catsAreAddedRenamedMovedAndRemoved() async throws {
        let (root, store, _) = try await home()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = await store.snapshot().catName
        let study = try await store.addRoom()
        let tuanzi = try await store.addCat(name: " 团子 ")
        #expect(tuanzi.name == "团子" && tuanzi.roomId == nil)
        var state = await store.snapshot()
        #expect(state.allCats.map(\.name) == [first, "团子"])
        #expect(state.cats(inRoom: study.roomId).count == 2)

        _ = try await store.setCatRoom(catId: tuanzi.catId, roomId: study.roomId)
        state = await store.snapshot()
        #expect(state.cats(inRoom: AppState.primaryRoomId).map(\.catId) == [AppState.primaryCatId])
        #expect(state.cats(inRoom: study.roomId).map(\.catId) == [AppState.primaryCatId, tuanzi.catId])
        await #expect(throws: StoreError.unknownRoom) { try await store.setCatRoom(catId: tuanzi.catId, roomId: "nope") }
        await #expect(throws: StoreError.unknownCat) { try await store.setCatRoom(catId: "nope", roomId: nil) }

        // The first cat's name is the name older files know, whichever way it is changed.
        _ = try await store.renameCat(catId: AppState.primaryCatId, name: "贝拉")
        #expect(await store.snapshot().catName == "贝拉")
        _ = try await store.setCatName("Bella")
        state = await store.snapshot()
        #expect(state.primaryCat.name == "Bella" && state.catName == "Bella")
        await #expect(throws: StoreError.invalidName) { try await store.renameCat(catId: tuanzi.catId, name: "  ") }

        await #expect(throws: StoreError.firstCat) { try await store.removeCat(catId: AppState.primaryCatId) }
        try await store.removeCat(catId: tuanzi.catId)
        #expect(await store.snapshot().allCats.map(\.catId) == [AppState.primaryCatId])
        let reopened = LibraryStore(root: root, catalog: try TestSupport.catalog())
        #expect(try await reopened.load() == (await store.snapshot()))
    }

    @Test func thereIsALimitOnCats() async throws {
        let (root, store, _) = try await home()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1..<AppState.maxCats { _ = try await store.addCat(name: "猫\(index)") }
        await #expect(throws: StoreError.tooManyCats) { try await store.addCat(name: "多") }
    }

    // MARK: Two cats, one room

    @Test func aCatLeavesAloneThePieceAnotherCatHasTaken() throws {
        let catalog = try TestSupport.catalog()
        func chair(_ id: String, x: Int) -> PhotoFurniture {
            PhotoFurniture(instanceId: id, modelId: "kenney-chair", x: x, z: 1, width: 2, depth: 2, turn: 0,
                           finish: .original, displayName: id, sources: [], tags: [], revision: 1)
        }
        let items = [chair("a", x: 1), chair("b", x: 6)]
        // Alone, the first trip from the door goes to a piece; `sample` 0 picks the first one.
        #expect(CatRoutine.nextTrip(items: items, from: .atEntrance, sample: 0, catalog: catalog).end.itemId == "a")
        #expect(CatRoutine.nextTrip(items: items, from: .atEntrance, sample: 0, catalog: catalog, avoiding: ["a"]).end.itemId == "b")
        // A new arrival is not rushed to when another cat already has it.
        #expect(CatRoutine.nextTrip(items: items, from: .atEntrance, sample: 0, catalog: catalog, preferring: "b", avoiding: ["b"]).end.itemId == "a")
        // Everything taken: she stays on the floor.
        let stroll = CatRoutine.nextTrip(items: items, from: .atEntrance, sample: 0, catalog: catalog, avoiding: ["a", "b"])
        #expect(stroll.end.itemId == nil)
    }

    // MARK: The furniture library

    @Test func theFurnitureLibraryCanShowOneRoom() async throws {
        let (root, store, chair) = try await home()
        defer { try? FileManager.default.removeItem(at: root) }
        let study = try await store.addRoom()
        let second = try await store.addFurniture(placement: spot, displayName: "二", roomId: study.roomId)
        let state = await store.snapshot()
        var query = FurnitureQuery()
        query.place = .room
        #expect(FurnitureLibrary.pieces(in: state, catalog: nil, query: query).count == 2)
        query.roomId = study.roomId
        #expect(FurnitureLibrary.pieces(in: state, catalog: nil, query: query).map(\.instanceId) == [second.instanceId])
        query.roomId = AppState.primaryRoomId
        #expect(FurnitureLibrary.pieces(in: state, catalog: nil, query: query).map(\.instanceId) == [chair.instanceId])
        // A room narrows every place; a piece that is put away is in no room.
        #expect(query.isNarrowed)
        query.place = .all
        #expect(FurnitureLibrary.pieces(in: state, catalog: nil, query: query).map(\.instanceId) == [chair.instanceId])
        query.place = .stored
        #expect(FurnitureLibrary.pieces(in: state, catalog: nil, query: query).isEmpty)
    }

    // MARK: Files that do not add up

    @Test func aFileThatPointsAtAMissingRoomIsRefused() async throws {
        let (root, store, _) = try await home()
        defer { try? FileManager.default.removeItem(at: root) }
        var state = await store.snapshot()
        state.cats = [Cat(catId: AppState.primaryCatId, name: state.catName), Cat(catId: "c2", name: "团子", roomId: "gone")]
        #expect(!LibraryStore.isConsistent(state))
        state.cats = [Cat(catId: AppState.primaryCatId, name: "另一个名字")]
        #expect(!LibraryStore.isConsistent(state))
        state.cats = []
        state.rooms = [Room(roomId: "r2"), Room(roomId: AppState.primaryRoomId)]
        #expect(!LibraryStore.isConsistent(state))
        state.rooms = []
        #expect(LibraryStore.isConsistent(state))
    }
}
