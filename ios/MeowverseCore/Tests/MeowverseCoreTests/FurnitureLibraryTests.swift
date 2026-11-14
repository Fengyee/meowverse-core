import Foundation
import Testing
@testable import MeowverseCore

/// Lock, cover, album order, batch stow / delete and the furniture library's query
/// (docs/IOS_LIBRARY_MODEL.md, step 3).
@Suite struct FurnitureLibraryTests {
    private func library() async throws -> (root: URL, store: LibraryStore, chair: PhotoFurniture, stool: PhotoFurniture, loose: [PhotoRecord]) {
        let root = TestSupport.tempDir()
        let store = LibraryStore(root: root, catalog: try TestSupport.catalog())
        let chair = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 61),
                                                       placement: Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2),
                                                       displayName: "椅", decision: .manual)
        let stool = try await store.addFurniture(placement: Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1), displayName: "凳")
        var loose: [PhotoRecord] = []
        for seed in 62...64 { loose.append(try await store.addPhoto(draft: try TestSupport.draft(seed: seed))) }
        return (root, store, chair, stool, loose)
    }

    // MARK: Lock

    @Test func aLockedPieceStaysWhereItIsButKeepsTakingPhotosAndNames() async throws {
        let (root, store, chair, _, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await store.setLocked(instanceIds: [chair.instanceId], true) == 1)
        #expect(try await store.setLocked(instanceIds: [chair.instanceId], true) == 0)
        let locked = await store.snapshot()
        #expect(locked.placedFurniture[0].isLocked)

        await #expect(throws: StoreError.locked) {
            try await store.updatePlacement(instanceId: chair.instanceId, placement: Placement(modelId: "kenney-chair", x: 6, z: 6, width: 2, depth: 2))
        }
        await #expect(throws: StoreError.locked) { try await store.stowFurniture(instanceId: chair.instanceId) }
        await #expect(throws: StoreError.locked) { try await store.removeFurniture(instanceId: chair.instanceId) }
        #expect(await store.snapshot() == locked)

        // Photos and the name are not what the lock protects.
        try await store.linkPhotos(photoIds: [loose[0].photoId], toInstance: chair.instanceId)
        _ = try await store.rename(instanceId: chair.instanceId, displayName: "大椅")
        let after = await store.snapshot().placedFurniture[0]
        #expect(after.sources.count == 2 && after.displayName == "大椅" && after.isLocked)

        #expect(try await store.setLocked(instanceIds: [chair.instanceId], false) == 1)
        #expect(await store.snapshot().placedFurniture[0].locked == nil)
        _ = try await store.stowFurniture(instanceId: chair.instanceId)
        #expect(await store.snapshot().storedFurniture.map(\.instanceId) == [chair.instanceId])
    }

    @Test func aPieceThatWasNeverLockedHasNoLockOrCoverInTheFile() async throws {
        let (root, store, _, _, _) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = String(decoding: try LibraryStore.encodeState(await store.snapshot()), as: UTF8.self)
        #expect(!text.contains("\"locked\"") && !text.contains("\"coverPhotoId\""))
    }

    @Test func aLockSurvivesReopeningAndBeingPutAwayIsNotALoophole() async throws {
        let (root, store, _, stool, _) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.stowFurniture(instanceId: stool.instanceId)
        try await store.setLocked(instanceIds: [stool.instanceId], true)
        let reopened = LibraryStore(root: root, catalog: try TestSupport.catalog())
        #expect(try await reopened.load().storedFurniture[0].isLocked)
        await #expect(throws: StoreError.locked) { try await reopened.removeFurniture(instanceId: stool.instanceId) }
        await #expect(throws: StoreError.unknownInstance) { try await reopened.setLocked(instanceIds: [stool.instanceId, "nope"], false) }
        #expect(await reopened.snapshot().storedFurniture[0].isLocked)
    }

    // MARK: Several pieces at once

    @Test func puttingAwayAndDeletingSeveralPiecesIsOneWriteEach() async throws {
        let (root, store, chair, stool, _) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = await store.snapshot().revision
        let stowed = try await store.stowFurniture(instanceIds: [stool.instanceId, chair.instanceId])
        // In room order, whatever order was asked for.
        #expect(stowed.map(\.instanceId) == [chair.instanceId, stool.instanceId])
        var state = await store.snapshot()
        #expect(state.revision == before + 1 && state.placedFurniture.isEmpty && state.storedFurniture.count == 2)
        #expect(state.storedFurniture[0].sources.count == 1)

        // A piece already put away cannot be put away again: nothing changes.
        await #expect(throws: StoreError.unknownInstance) { try await store.stowFurniture(instanceIds: [chair.instanceId]) }

        try await store.removeFurniture(instanceIds: [chair.instanceId, stool.instanceId])
        state = await store.snapshot()
        #expect(state.revision == before + 2 && state.allFurniture.isEmpty)
        // The photos are all still in the library.
        #expect(state.photos.count == 4)
    }

    @Test func oneLockedOrUnknownPieceRejectsTheWholeBatch() async throws {
        let (root, store, chair, stool, _) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.setLocked(instanceIds: [stool.instanceId], true)
        let before = await store.snapshot()
        await #expect(throws: StoreError.locked) { try await store.stowFurniture(instanceIds: [chair.instanceId, stool.instanceId]) }
        await #expect(throws: StoreError.locked) { try await store.removeFurniture(instanceIds: [chair.instanceId, stool.instanceId]) }
        await #expect(throws: StoreError.unknownInstance) { try await store.removeFurniture(instanceIds: [chair.instanceId, "nope"]) }
        #expect(await store.snapshot() == before)
    }

    // MARK: Cover and order

    @Test func theCoverIsTheChosenPhotoWhileItIsOnThePieceOtherwiseTheFirst() async throws {
        let (root, store, chair, _, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = chair.sources[0].photoId, ids = loose.map(\.photoId)
        try await store.linkPhotos(photoIds: ids, toInstance: chair.instanceId)
        #expect(await store.snapshot().placedFurniture[0].cover == first)

        #expect(try await store.setCover(instanceId: chair.instanceId, photoId: ids[1]).cover == ids[1])
        await #expect(throws: StoreError.unknownPhoto) { try await store.setCover(instanceId: chair.instanceId, photoId: "nope") }

        // Taking the cover photo off the piece falls back to the first photo, without a stale claim showing.
        try await store.unlinkPhotos(photoIds: [ids[1]], fromInstance: chair.instanceId)
        #expect(await store.snapshot().placedFurniture[0].cover == first)

        // Choosing the first photo, or nothing, stores no choice.
        #expect(try await store.setCover(instanceId: chair.instanceId, photoId: ids[0]).coverPhotoId == ids[0])
        #expect(try await store.setCover(instanceId: chair.instanceId, photoId: first).coverPhotoId == nil)
        _ = try await store.setCover(instanceId: chair.instanceId, photoId: ids[0])
        #expect(try await store.setCover(instanceId: chair.instanceId, photoId: nil).coverPhotoId == nil)
    }

    @Test func reorderingKeepsEveryLinkAndRejectsAnythingElse() async throws {
        let (root, store, chair, _, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = chair.sources[0].photoId, ids = loose.map(\.photoId)
        try await store.linkPhotos(photoIds: ids, toInstance: chair.instanceId)
        let before = await store.snapshot()
        let order = [ids[2], first, ids[0], ids[1]]
        let item = try await store.reorderPhotos(instanceId: chair.instanceId, order: order)
        #expect(item.sources.map(\.photoId) == order)
        // The first link keeps what it was: made with the piece, not a manual link.
        #expect(item.sources[1].untimed == before.placedFurniture[0].sources[0].untimed)
        // A cover nobody chose is "the first photo", so it follows the order.
        #expect(item.cover == ids[2])
        let revision = await store.snapshot().revision
        // The same order again writes nothing.
        _ = try await store.reorderPhotos(instanceId: chair.instanceId, order: order)
        #expect(await store.snapshot().revision == revision)

        for bad in [[first], order + [first], [ids[2], first, ids[0], "nope"], [first, first, ids[0], ids[1]]] {
            await #expect(throws: StoreError.invalidOrder) { try await store.reorderPhotos(instanceId: chair.instanceId, order: bad) }
        }
        #expect(await store.snapshot().revision == revision)
    }

    // MARK: Query

    private func piece(_ id: String, model: String = "kenney-chair", photos: [PhotoCarrierSource] = [], created: Double? = nil,
                       locked: Bool? = nil) -> PhotoFurniture {
        PhotoFurniture(instanceId: id, modelId: model, x: 0, z: 0, width: 1, depth: 1, turn: 0, finish: .original,
                       displayName: id, sources: photos, tags: [], revision: 1,
                       createdAt: created.map { Date(timeIntervalSince1970: $0) }, locked: locked)
    }

    private func link(_ id: String, at time: Double? = nil) -> PhotoCarrierSource {
        .manual(photoId: id, addedAt: time.map { Date(timeIntervalSince1970: $0) })
    }

    private var state: AppState {
        AppState(revision: 1, photos: [], observations: [],
                 items: [piece("Sofa", photos: [link("a", at: 100), link("b", at: 300)], created: 10),
                         piece("bed 2", photos: [link("c")], locked: true),
                         piece("Bed 10", model: "kenney-stoolBar", created: 30)],
                 storage: [piece("café", photos: [link("d", at: 200)], created: 20)])
    }

    private func names(_ query: FurnitureQuery) throws -> [String] {
        FurnitureLibrary.pieces(in: state, catalog: try TestSupport.catalog(), query: query).map(\.instanceId)
    }

    @Test func importingOffersTheCurrentRoomsBoardAndOnlyReusesStorageInASingleRoomHome() throws {
        let catalog = try FurnitureCatalog.bundled()
        let firstRoom = Room(roomId: AppState.primaryRoomId)
        let secondRoom = Room(roomId: "room-2")
        let firstBoard = piece("first", model: "wall-photo-board")
        var secondBoard = piece("second", model: "wall-photo-board")
        secondBoard.roomId = secondRoom.roomId
        var storedBoard = piece("stored", model: "wall-photo-board")
        storedBoard.roomId = secondRoom.roomId
        var home = AppState(revision: 1, photos: [], observations: [], items: [firstBoard, secondBoard],
                            storage: [storedBoard], rooms: [firstRoom, secondRoom])

        func suggested(_ targets: [PhotoFurniture], in room: Room) -> PhotoFurniture? {
            FurnitureLibrary.photoBoard(for: targets, inRoom: room.roomId, state: home, catalog: catalog)
        }
        #expect(suggested(home.allFurniture, in: secondRoom) == secondBoard)
        // A board already holding this photo was excluded from the eligible attach targets.
        #expect(suggested([firstBoard, storedBoard], in: secondRoom) == nil)
        home.rooms = []
        home.items = [firstBoard]
        #expect(suggested(home.allFurniture, in: firstRoom) == firstBoard)
        #expect(suggested([storedBoard], in: firstRoom) == storedBoard)
        #expect(suggested([], in: firstRoom) == nil)
    }

    @Test func theDefaultQueryShowsEverythingInTheOrderItWasAdded() throws {
        #expect(try names(FurnitureQuery()) == ["Sofa", "bed 2", "Bed 10", "café"])
        #expect(try names(FurnitureQuery(place: .room)) == ["Sofa", "bed 2", "Bed 10"])
        #expect(try names(FurnitureQuery(place: .stored)) == ["café"])
        #expect(!FurnitureQuery(place: .stored, search: "x", sort: .name).isNarrowed)
    }

    @Test func filtersNarrowAndCombine() throws {
        let catalog = try TestSupport.catalog()
        let chair = try #require(catalog.model(id: "kenney-chair")?.category)
        let stool = try #require(catalog.model(id: "kenney-stoolBar")?.category)
        #expect(try names(FurnitureQuery(photos: .without)) == ["Bed 10"])
        #expect(try names(FurnitureQuery(photos: .with)) == ["Sofa", "bed 2", "café"])
        #expect(try names(FurnitureQuery(lockedOnly: true)) == ["bed 2"])
        #expect(try names(FurnitureQuery(place: .room, photos: .with, lockedOnly: true)) == ["bed 2"])
        #expect(try names(FurnitureQuery(search: "  BED ")) == ["bed 2", "Bed 10"])
        #expect(try names(FurnitureQuery(search: "cafe")) == ["café"])
        if chair != stool {
            #expect(try names(FurnitureQuery(categories: [stool])) == ["Bed 10"])
            #expect(FurnitureLibrary.categories(in: state, catalog: catalog) == FurnitureCategory.allCases.filter { [chair, stool].contains($0) })
        }
        #expect(FurnitureQuery(lockedOnly: true).isNarrowed)
        // Without a catalog nothing has a category: a category filter shows nothing rather than guessing.
        #expect(FurnitureLibrary.pieces(in: state, catalog: nil, query: FurnitureQuery(categories: [chair])).isEmpty)
    }

    @Test func sortsRunBothWaysAndAnUnknownTimeIsAlwaysLast() throws {
        // Names sort the way Finder does: "2" before "10", case ignored.
        #expect(try names(FurnitureQuery(sort: .name)) == ["bed 2", "Bed 10", "café", "Sofa"])
        #expect(try names(FurnitureQuery(sort: .name, ascending: false)) == ["Sofa", "café", "Bed 10", "bed 2"])
        #expect(try names(FurnitureQuery(sort: .photoCount, ascending: false)) == ["Sofa", "bed 2", "café", "Bed 10"])
        #expect(try names(FurnitureQuery(sort: .photoCount)) == ["Bed 10", "bed 2", "café", "Sofa"])
        // "bed 2" has a photo without a time and "Bed 10" has no photo: both unknown, both last.
        #expect(try names(FurnitureQuery(sort: .lastPhotoAdded, ascending: false)) == ["Sofa", "café", "bed 2", "Bed 10"])
        #expect(try names(FurnitureQuery(sort: .lastPhotoAdded)) == ["café", "Sofa", "bed 2", "Bed 10"])
        #expect(try names(FurnitureQuery(sort: .created, ascending: false)) == ["Bed 10", "café", "Sofa", "bed 2"])
        #expect(try names(FurnitureQuery(sort: .created)) == ["Sofa", "café", "Bed 10", "bed 2"])
        #expect(try names(FurnitureQuery(sort: .added, ascending: false)) == ["café", "Bed 10", "bed 2", "Sofa"])
        #expect(FurnitureQuery.defaultAscending(for: .name) && !FurnitureQuery.defaultAscending(for: .photoCount))
    }
}
