import Foundation
import Testing
@testable import MeowverseCore

private func piece(_ id: String, _ model: String, x: Int, z: Int, width: Int, depth: Int, turn: Int = 0,
                   wall: WallSide? = nil) -> PhotoFurniture {
    PhotoFurniture(instanceId: id, modelId: model, x: x, z: z, width: width, depth: depth, turn: turn, wall: wall,
                   finish: .original, displayName: id, sources: [], tags: [], revision: 1)
}

private func stool(_ id: String, x: Int, z: Int) -> PhotoFurniture {
    piece(id, "kenney-stoolBar", x: x, z: z, width: 1, depth: 1)
}

/// Schema 6 in the store: pieces put away, pieces without photos, and the 5 -> 6 file change.
@Suite struct StoredFurnitureTests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try TestSupport.catalog() }

    let fm = FileManager.default
    let chairAt44 = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2, finish: .sage)
    let stoolAt00 = Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1)

    func editJSON(_ fileURL: URL, _ edit: (inout [String: Any]) -> Void) throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        edit(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)
    }

    /// A state.json exactly as schema 5 wrote it: no `storage`, no `wall` on any piece.
    @Test func schema5FileLoadsUnchangedAndIsRewrittenAsCurrent() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let seedStore = LibraryStore(root: root, catalog: catalog)
        let chair = try await seedStore.commitNewFurniture(draft: try TestSupport.draft(seed: 600), placement: chairAt44, displayName: "椅", decision: .manual)
        _ = try await seedStore.commitNewFurniture(draft: try TestSupport.draft(seed: 601), placement: stoolAt00, displayName: "凳", decision: .manual)
        let seeded = await seedStore.snapshot()
        for name in ["state.json", "state.backup.json"] {
            try editJSON(root.appendingPathComponent(name)) { object in
                object["schemaVersion"] = 5
                #expect(object.removeValue(forKey: "storage") != nil)
                #expect((object["items"] as! [[String: Any]]).allSatisfy { $0["wall"] == nil }, "a floor piece writes no wall key")
            }
        }
        let v5Bytes = try Data(contentsOf: root.appendingPathComponent("state.json"))

        let store = LibraryStore(root: root, catalog: catalog)
        let state = try await store.load()
        #expect(state == seeded, "nothing invented, nothing dropped: same pieces, links and photos, empty storage")
        #expect(state.schemaVersion == AppState.currentSchemaVersion && state.storage.isEmpty)
        #expect(state.items.allSatisfy { $0.wall == nil })
        #expect(try Data(contentsOf: root.appendingPathComponent("state.json")) == v5Bytes, "loading alone writes nothing")

        _ = try await store.stowFurniture(instanceId: chair.instanceId)
        let json = try #require(String(data: Data(contentsOf: root.appendingPathComponent("state.json")), encoding: .utf8))
        #expect(json.contains("\"schemaVersion\":\(AppState.currentSchemaVersion)") && json.contains("\"storage\":[{"))
        let reopened = LibraryStore(root: root, catalog: catalog)
        #expect(try await reopened.load() == (await store.snapshot()))
        #expect(await reopened.integrityReport().isClean)
    }

    @Test func stowKeepsPhotosAndRestorePutsThePieceBack() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let chair = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 610), placement: chairAt44, displayName: "椅", decision: .manual)
        let photoId = chair.sources[0].photoId

        let stowed = try await store.stowFurniture(instanceId: chair.instanceId)
        #expect(stowed.sources == chair.sources && stowed.placement == chair.placement, "the last place stays as a hint")
        #expect(stowed.revision == chair.revision + 1)
        var state = await store.snapshot()
        #expect(state.items.isEmpty && state.storage == [stowed])
        #expect(state.item(id: chair.instanceId) == nil, "item(id:) is the room only")
        #expect(state.storedItem(id: chair.instanceId) == stowed && state.anyItem(id: chair.instanceId) == stowed)
        #expect(state.furniture(containing: photoId) == [stowed])
        #expect(await store.furniture(containingPhoto: photoId) == [stowed])
        #expect(PhotoLibrary.count(in: state, filter: .unlinked) == 0, "a photo on a stored piece is still linked")
        #expect(PhotoLibrary.sections(in: state, filter: .unlinked).isEmpty)
        #expect(state.deletionImpact(photoId: photoId).furnitureToUpdate == [stowed])
        #expect(await store.storageUsage().furnitureCount == 1)
        #expect(await store.integrityReport().isClean)
        // Not in the room: it cannot be stowed twice or moved, and it blocks nothing.
        await #expect(throws: StoreError.unknownInstance) { try await store.stowFurniture(instanceId: chair.instanceId) }
        await #expect(throws: StoreError.unknownInstance) { try await store.updatePlacement(instanceId: chair.instanceId, placement: chairAt44) }
        await #expect(throws: StoreError.unknownInstance) { try await store.restoreFurniture(instanceId: "nope", placement: chairAt44) }

        // A stored piece is still the user's: rename it, give it photos, take one off.
        #expect(try await store.rename(instanceId: chair.instanceId, displayName: " 旧椅子 ").displayName == "旧椅子")
        let loose = try await store.addPhoto(draft: try TestSupport.draft(seed: 611))
        #expect(try await store.linkPhoto(photoId: loose.photoId, toInstance: chair.instanceId).sources.map(\.photoId) == [photoId, loose.photoId])
        await #expect(throws: StoreError.duplicateSource) { try await store.linkPhoto(photoId: loose.photoId, toInstance: chair.instanceId) }
        let third = try await store.addSource(draft: try TestSupport.draft(seed: 612), toInstance: chair.instanceId, decision: .manual)
        #expect(third.sources.count == 3)
        let fewer = try await store.unlinkPhoto(photoId: loose.photoId, fromInstance: chair.instanceId)
        let afterUnlink = await store.snapshot()
        #expect(fewer.sources.count == 2 && afterUnlink.photo(id: loose.photoId) == loose, "only the link goes")
        await #expect(throws: StoreError.unknownPhoto) { try await store.unlinkPhoto(photoId: loose.photoId, fromInstance: chair.instanceId) }
        #expect(afterUnlink.items.isEmpty)

        // Its old place was taken meanwhile: restoring is judged like any new placement.
        let squatter = try await store.addFurniture(placement: Placement(modelId: "kenney-chair", x: 5, z: 5, width: 2, depth: 2), displayName: "")
        let before = await store.snapshot()
        await #expect(throws: StoreError.placement([.overlaps(instanceId: squatter.instanceId)])) {
            try await store.restoreFurniture(instanceId: chair.instanceId, placement: stowed.placement)
        }
        #expect(await store.snapshot() == before)
        let back = try await store.restoreFurniture(instanceId: chair.instanceId, placement: Placement(modelId: "kenney-chair", x: 0, z: 0, width: 2, depth: 2, turn: 1, finish: .blue))
        #expect(back.instanceId == chair.instanceId && back.sources == fewer.sources && back.displayName == "旧椅子")
        #expect(back.x == 0 && back.z == 0 && back.turn == 1)
        #expect(back.finish == .blue && back.revision == fewer.revision + 1)
        state = await store.snapshot()
        #expect(state.storage.isEmpty && state.items.map(\.instanceId) == [squatter.instanceId, chair.instanceId])

        let reopened = LibraryStore(root: root, catalog: catalog)
        #expect(try await reopened.load() == state)
        #expect(await reopened.integrityReport().isClean)
    }

    @Test func stowAndRestoreAreAllOrNothing() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let fault = FaultSwitch(nil)
        let store = LibraryStore(root: root, catalog: catalog, fault: fault.handler)
        let chair = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 620), placement: chairAt44, displayName: "椅", decision: .manual)
        let stateURL = root.appendingPathComponent("state.json")

        for step in ["stow", "restore", "add"] {
            let before = await store.snapshot(), bytes = try Data(contentsOf: stateURL)
            fault.arm(.writeState)
            await #expect(throws: InjectedFault.failed(.writeState)) {
                switch step {
                case "stow": _ = try await store.stowFurniture(instanceId: chair.instanceId)
                case "restore": _ = try await store.restoreFurniture(instanceId: chair.instanceId, placement: chairAt44)
                default: _ = try await store.addFurniture(placement: stoolAt00, displayName: "凳")
                }
            }
            let after = await store.snapshot(), bytesAfter = try Data(contentsOf: stateURL)
            #expect(after == before && bytesAfter == bytes, "\(step)")
            #expect(try await LibraryStore(root: root, catalog: catalog).load() == before, "\(step)")
            // The retry goes through.
            switch step {
            case "stow": _ = try await store.stowFurniture(instanceId: chair.instanceId)
            case "restore": _ = try await store.restoreFurniture(instanceId: chair.instanceId, placement: chairAt44)
            default: _ = try await store.addFurniture(placement: stoolAt00, displayName: "凳")
            }
        }
        let state = await store.snapshot()
        #expect(state.items.count == 2 && state.storage.isEmpty)
    }

    @Test func removingAndPhotoDeletionReachStoredPieces() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let chair = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 630), placement: chairAt44, displayName: "椅", decision: .manual)
        let stoolPiece = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 631), placement: stoolAt00, displayName: "凳", decision: .manual)
        _ = try await store.stowFurniture(instanceId: chair.instanceId)
        _ = try await store.stowFurniture(instanceId: stoolPiece.instanceId)

        // Deleting its only photo empties the stored piece; the piece itself stays put away.
        try await store.deletePhoto(photoId: chair.sources[0].photoId)
        var state = await store.snapshot()
        #expect(state.storage.map(\.instanceId) == [chair.instanceId, stoolPiece.instanceId])
        #expect(state.storedItem(id: chair.instanceId)?.sources == [])
        #expect(state.photos.map(\.photoId) == [stoolPiece.sources[0].photoId])
        #expect(await store.integrityReport().isClean)

        // Deleting a stored piece keeps its photo, now unlinked.
        try await store.removeFurniture(instanceId: stoolPiece.instanceId)
        state = await store.snapshot()
        #expect(state.storage.map(\.instanceId) == [chair.instanceId] && state.photos.count == 1)
        #expect(PhotoLibrary.count(in: state, filter: .unlinked) == 1)
        await #expect(throws: StoreError.unknownInstance) { try await store.removeFurniture(instanceId: stoolPiece.instanceId) }

        // Clear all leaves nothing in storage either.
        #expect(try await store.clearAll() == .empty)
        #expect(try await LibraryStore(root: root, catalog: catalog).load().storage.isEmpty)
    }

    @Test func restoreCountsAgainstTheRoomLimitButStorageDoesNot() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        var ids: [String] = []
        for i in 0..<GridRules.maxItems {
            ids.append(try await store.addFurniture(placement: Placement(modelId: "kenney-stoolBar", x: i % 5 * 2, z: i / 5 * 2, width: 1, depth: 1), displayName: "").instanceId)
        }
        _ = try await store.stowFurniture(instanceId: ids[0])
        // The freed slot is taken by a new piece: the stored one has to wait.
        _ = try await store.addFurniture(placement: Placement(modelId: "kenney-stoolBar", x: 5, z: 5, width: 1, depth: 1), displayName: "")
        await #expect(throws: StoreError.placement([.tooManyItems])) {
            try await store.restoreFurniture(instanceId: ids[0], placement: Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1))
        }
        let state = await store.snapshot()
        #expect(state.items.count == GridRules.maxItems && state.storage.count == 1)
        // More pieces than the room holds, counting storage, is a healthy library.
        #expect(try await LibraryStore(root: root, catalog: catalog).load() == state)
    }

    @Test func loadRefusesTheSameInstanceInTheRoomAndInStorage() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        _ = try await store.addFurniture(placement: chairAt44, displayName: "椅")
        _ = try await store.addFurniture(placement: stoolAt00, displayName: "凳")
        for name in ["state.json", "state.backup.json"] {
            try editJSON(root.appendingPathComponent(name)) { $0["storage"] = [($0["items"] as! [[String: Any]])[0]] }
        }
        await #expect(throws: StoreError.corruptState) { try await LibraryStore(root: root, catalog: catalog).load() }
        // A stored piece's dangling photo link is damage too, exactly as for a piece in the room.
        let dangling = piece("x", "kenney-chair", x: 0, z: 0, width: 2, depth: 2)
        var broken = AppState(revision: 1, photos: [], observations: [], items: [], storage: [dangling])
        #expect(LibraryStore.isConsistent(broken))
        broken.storage[0].sources = [.manual(photoId: "missing")]
        #expect(!LibraryStore.isConsistent(broken))
    }
}

/// Schema 6: a piece may be placed straight from the catalog and never needs a photo.
@Suite struct PhotolessFurnitureTests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try TestSupport.catalog() }

    @Test func aPieceFromTheCatalogHasNoPhotosAndClaimsNothing() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let chairAt44 = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2, turn: 1, finish: .sage)
        let chair = try await store.addFurniture(placement: chairAt44, displayName: "  ")
        #expect(chair.sources.isEmpty && chair.placement == chairAt44 && chair.revision == 1)
        #expect(chair.displayName == "椅子" || chair.displayName == catalog.model(id: "kenney-chair")?.label, "a blank name falls back to the model's")
        #expect(try await store.addFurniture(placement: Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1), displayName: " 脚凳 ").displayName == "脚凳")
        var state = await store.snapshot()
        #expect(state.photos.isEmpty && state.observations.isEmpty && state.items.count == 2)
        #expect(await store.integrityReport().isClean)
        #expect(TestSupport.listing(root).filter { $0.hasPrefix("originals/") || $0.hasPrefix("thumbnails/") }.isEmpty)

        // The same placement rules as a piece that came from a photo.
        await #expect(throws: StoreError.placement([.overlaps(instanceId: chair.instanceId)])) {
            try await store.addFurniture(placement: chairAt44, displayName: "又一把")
        }
        await #expect(throws: StoreError.placement([.unknownModel])) {
            try await store.addFurniture(placement: Placement(modelId: "nope", x: 7, z: 0, width: 1, depth: 1), displayName: "")
        }
        #expect(await store.snapshot() == state)

        // It reloads (the old load check required a source), and takes photos later.
        let reopened = LibraryStore(root: root, catalog: catalog)
        #expect(try await reopened.load() == state)
        let photo = try await reopened.addPhoto(draft: try TestSupport.draft(seed: 640))
        let linked = try await reopened.linkPhoto(photoId: photo.photoId, toInstance: chair.instanceId)
        #expect(linked.sources.map(\.untimed) == [.manual(photoId: photo.photoId)])
        // Taking the last photo off, or deleting it, leaves the piece in place.
        #expect(try await reopened.unlinkPhoto(photoId: photo.photoId, fromInstance: chair.instanceId).sources.isEmpty)
        _ = try await reopened.linkPhoto(photoId: photo.photoId, toInstance: chair.instanceId)
        let relinked = await reopened.snapshot()
        #expect(relinked.deletionImpact(photoId: photo.photoId).furnitureToUpdate.map(\.instanceId) == [chair.instanceId])
        try await reopened.deletePhoto(photoId: photo.photoId)
        state = await reopened.snapshot()
        #expect(state.items.count == 2 && state.item(id: chair.instanceId)?.sources == [] && state.photos.isEmpty)
        #expect(state.item(id: chair.instanceId)?.placement == chairAt44)
    }
}

/// Schema 6 access rule: any free cell beside a piece that Bella can walk to, front preferred.
@Suite struct AccessCellTests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try TestSupport.catalog() }

    @Test func theFrontCellWinsWheneverSheCanWalkToIt() {
        // Rooms laid out under the front-cell rule: nothing changes for them.
        for turn in 0...3 {
            let chair = piece("c", "kenney-chair", x: 4, z: 4, width: 2, depth: 2, turn: turn)
            #expect(CatRoutine.accessCell(of: chair, in: [chair]) == CatRoutine.approachCell(of: chair))
            #expect(CatRoutine.accessCell(of: chair, in: []) == CatRoutine.approachCell(of: chair), "the piece need not be in the list")
        }
    }

    @Test func placementGuidesKeepTheRoomEntranceAndFollowTheActualAccessCells() {
        let chair = piece("c", "kenney-chair", x: 4, z: 4, width: 2, depth: 2)
        let board = piece("board", "kenney-photoBoard", x: 4, z: 0, width: 2, depth: 1, wall: .back)
        var draft = stool("s", x: 5, z: 6).placement
        let guides = CatRoutine.placementGuideCells(in: [chair, board], previewing: draft)
        #expect(guides == [GridRules.entrance, GridCell(x: 4, z: 6), GridCell(x: 5, z: 7)])
        draft.turn = 1
        #expect(CatRoutine.placementGuideCells(in: [chair, board], previewing: draft)
                == [GridRules.entrance, GridCell(x: 4, z: 6), GridCell(x: 6, z: 6)])
    }

    @Test func aBlockedLastAccessStaysMarkedWhileDraggingAcrossIt() {
        let corner = [stool("a", x: 0, z: 0), stool("b", x: 1, z: 0)]
        let draft = stool("s", x: 0, z: 1).placement
        #expect(CatRoutine.placementGuideCells(in: corner, previewing: draft).contains(GridCell(x: 0, z: 1)))
        let doorway = stool("door", x: GridRules.entrance.x, z: GridRules.entrance.z).placement
        #expect(CatRoutine.placementGuideCells(in: corner, previewing: doorway).contains(GridRules.entrance))
        #expect(CatRoutine.placementGuideCells(in: corner, previewing: doorway).contains(GridCell(x: 0, z: 1)))
    }

    @Test func otherwiseTheNearestFreeCellBesideItDeterministically() {
        // Front (5,6) taken by a stool: the other cell of the front row is one step from it.
        let chair = piece("c", "kenney-chair", x: 4, z: 4, width: 2, depth: 2)
        let room = [chair, stool("s", x: 5, z: 6)]
        #expect(CatRoutine.accessCell(of: chair, in: room) == GridCell(x: 4, z: 6))
        // Whole front row taken: (6,5) on the right is two steps from the front cell, (3,5) three.
        let frontRow = room + [stool("t", x: 4, z: 6)]
        #expect(CatRoutine.accessCell(of: chair, in: frontRow) == GridCell(x: 6, z: 5))
        // Front (14,15) outside the room: (12,14) and (14,12) are both three steps away; the smaller z wins.
        let atEdge = piece("e", "kenney-chair", x: 13, z: 13, width: 2, depth: 2)
        #expect(CatRoutine.accessCell(of: atEdge, in: [atEdge]) == GridCell(x: 14, z: 12))
        // Same distance and same z: the smaller x wins.
        let wide = piece("w", "kenney-bench", x: 4, z: 5, width: 3, depth: 1)
        let rows = [4, 6].flatMap { z in (4...6).map { stool("r\($0)\(z)", x: $0, z: z) } }
        #expect(CatRoutine.accessCell(of: wide, in: [wide] + rows) == GridCell(x: 3, z: 5))
        // No free cell beside it, or only one she cannot walk to: nil.
        let corner = [stool("a", x: 0, z: 0), stool("b", x: 1, z: 0), stool("c", x: 0, z: 1)]
        #expect(CatRoutine.accessCell(of: corner[0], in: corner) == nil)
        let sealed = [stool("p", x: 1, z: 0), stool("q", x: 2, z: 0), stool("r", x: 1, z: 1), stool("s", x: 0, z: 1)]
        #expect(CatRoutine.accessCell(of: sealed[0], in: sealed) == nil, "(0,0) is free but sealed in")
        #expect(CatRoutine.accessCell(of: sealed[1], in: sealed) == GridCell(x: 2, z: 1))
    }

    @Test func bellaWalksToTheAccessCellAndStaysSettledThere() throws {
        // The bed's front cell is under a stool; the old routine skipped the bed for good.
        let bed = piece("bed", "kenney-bedDouble", x: 3, z: 2, width: 3, depth: 3)
        let room = [bed, stool("s", x: 4, z: 5)]
        #expect(GridRules.validate(room[1].placement, in: [bed], catalog: catalog).isEmpty, "the old rule refused this stool")
        let access = try #require(CatRoutine.accessCell(of: bed, in: room))
        #expect(access != CatRoutine.approachCell(of: bed))
        let trip = CatRoutine.nextTrip(items: room, from: .atEntrance, sample: 0, catalog: catalog, preferring: "bed")
        #expect(trip.end.itemId == "bed" && trip.end.cell == access && trip.path.last == access)
        #expect(trip.path.first == GridRules.entrance && trip.seat == CatRoutine.seatPoint(of: bed, catalog: catalog))
        let blocked = GridRules.blockedCells(room)
        #expect(trip.path.allSatisfy { !blocked.contains($0) })
        let invited = try #require(CatRoutine.invitedTrip(items: room, from: .atEntrance, catalog: catalog, itemId: "bed", siteId: "seat", action: .sleep))
        #expect(invited.end.cell == access)
        // Resting there holds while the room is unchanged, and she leaves from that cell.
        #expect(CatRoutine.settled(trip.end, items: room, catalog: catalog) == trip.end)
        let leaving = CatRoutine.nextTrip(items: room, from: trip.end, sample: 0.4, catalog: catalog)
        #expect(leaving.end.itemId == nil && leaving.path.first == access)
        // A rest whose cell is not beside the piece is not a rest on that piece.
        var adrift = trip.end
        adrift.cell = GridCell(x: 8, z: 8)
        #expect(CatRoutine.settled(adrift, items: room, catalog: catalog).itemId == nil)
    }
}

/// The wall-mounted photo board: a wall span, no floor cells, nothing for Bella to climb.
@Suite struct WallPieceTests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try FurnitureCatalog.bundled() }

    func board(_ id: String = "board", x: Int = 4, width: Int = 2, wall: WallSide = .back) -> PhotoFurniture {
        piece(id, "wall-photo-board", x: x, z: 0, width: width, depth: 1, wall: wall)
    }

    func onWall(x: Int = 4, z: Int = 0, width: Int = 2, depth: Int = 1, turn: Int = 0, wall: WallSide? = .back,
                model: String = "wall-photo-board") -> Placement {
        Placement(modelId: model, x: x, z: z, width: width, depth: depth, turn: turn, wall: wall)
    }

    @Test func theBundledCatalogOffersTheBoardWithoutTouchingTheBakedFiles() throws {
        let model = try #require(catalog.model(id: "wall-photo-board"))
        #expect(model.label == "照片板" && model.category == .photoBoard && model.mount == .wall)
        #expect(model.sizes == [[2, 1], [3, 1]] && model.defaultSize == [2, 1])
        #expect(catalog.models(in: .photoBoard) == [model] && FurnitureCatalog.builtInModels == [model])
        #expect(model.interactionSites.isEmpty && model.path.isEmpty, "drawn by the app: no baked asset, nothing to sit on")
        #expect(catalog.models.filter { $0.mount == .wall } == [model], "a catalog file without `mount` means floor")
        // The generated files themselves do not carry it (their --check scripts compare them to the art).
        #expect(try TestSupport.catalog().model(id: "wall-photo-board") == nil)
        #expect(FurnitureCategory(rawValue: "photoBoard") == .photoBoard)
    }

    @Test func aWallPlacementMustFitItsWallAndItsModel() {
        #expect(GridRules.validate(onWall(), in: [], catalog: catalog).isEmpty)
        #expect(GridRules.validate(onWall(x: 0, wall: .left), in: [], catalog: catalog).isEmpty)
        #expect(GridRules.validate(onWall(x: 12, width: 3), in: [], catalog: catalog).isEmpty)
        #expect(GridRules.validate(onWall(x: 13, width: 3), in: [], catalog: catalog) == [.outOfBounds])
        #expect(GridRules.validate(onWall(x: -1), in: [], catalog: catalog) == [.outOfBounds])
        #expect(GridRules.validate(onWall(z: 1), in: [], catalog: catalog) == [.outOfBounds])
        #expect(GridRules.validate(onWall(turn: 1), in: [], catalog: catalog) == [.outOfBounds])
        #expect(GridRules.validate(onWall(width: 4), in: [], catalog: catalog) == [.sizeNotAllowed])
        #expect(GridRules.validate(onWall(width: 1, depth: 2), in: [], catalog: catalog) == [.sizeNotAllowed, .outOfBounds])
        // The mount has to match the model, both ways.
        #expect(GridRules.validate(onWall(wall: nil), in: [], catalog: catalog) == [.wrongMount])
        #expect(GridRules.validate(onWall(width: 2, depth: 2, model: "kenney-chair"), in: [], catalog: catalog) == [.wrongMount, .outOfBounds])
        #expect(GridRules.validate(onWall(model: "nope"), in: [], catalog: catalog) == [.unknownModel])
        // Boards overlap only along the same wall; the walls meet in the corner without clashing.
        let hung = [board("a", x: 4), board("l", x: 0, wall: .left)]
        #expect(GridRules.validate(onWall(x: 5), in: hung, catalog: catalog) == [.overlaps(instanceId: "a")])
        #expect(GridRules.validate(onWall(x: 6), in: hung, catalog: catalog).isEmpty)
        #expect(GridRules.validate(onWall(x: 0), in: hung, catalog: catalog).isEmpty)
        #expect(GridRules.validate(onWall(x: 1, wall: .left), in: hung, catalog: catalog) == [.overlaps(instanceId: "l")])
        #expect(GridRules.validate(onWall(x: 5), in: hung, catalog: catalog, ignoring: "a").isEmpty, "moving a board ignores itself")
        // One limit for the room, boards included.
        let full = (0..<GridRules.maxItems).map { stool("s\($0)", x: $0 % 10, z: $0 / 10 * 2) }
        #expect(GridRules.validate(onWall(), in: full, catalog: catalog) == [.tooManyItems])
        #expect(GridRules.firstFreePlacement(for: catalog.model(id: "wall-photo-board")!, in: full, catalog: catalog) == nil)
    }

    @Test func aWallPieceTakesNoFloorAndIsNotInBellasWay() throws {
        let hung = [board("b", x: 4), board("l", x: 3, width: 3, wall: .left)]
        #expect(GridRules.blockedCells(hung).isEmpty)
        // Floor pieces go right under a board, in the cells its coordinates would name on the floor.
        let chairUnder = Placement(modelId: "kenney-chair", x: 4, z: 0, width: 2, depth: 2)
        #expect(GridRules.validate(chairUnder, in: hung, catalog: catalog).isEmpty)
        #expect(GridRules.validate(chairUnder, in: hung, catalog: catalog) == GridRules.validate(chairUnder, in: [], catalog: catalog))
        // A "board" row that would wall off the back of the room if it stood on the floor.
        let row = (0..<3).map { board("r\($0)", x: $0 * 3, width: 3) }
        let behind = Placement(modelId: "kenney-stoolBar", x: 5, z: 0, width: 1, depth: 1)
        #expect(GridRules.validate(behind, in: row, catalog: catalog).isEmpty)
        #expect(CatRoutine.route(items: hung, from: GridRules.entrance, to: GridCell(x: 4, z: 0))?.count == 18)
        // Bella never heads for a board and has no way onto one.
        #expect(CatRoutine.accessCell(of: hung[0], in: hung) == nil)
        #expect(CatRoutine.seatPoint(of: hung[0], catalog: catalog) == nil)
        for sample in [0, 0.3, 0.99] {
            let trip = CatRoutine.nextTrip(items: hung, from: .atEntrance, sample: sample, catalog: catalog, preferring: "b")
            #expect(trip.end.itemId == nil && trip.seat == nil)
        }
        #expect(CatRoutine.invitedTrip(items: hung, from: .atEntrance, catalog: catalog, itemId: "b", siteId: "seat", action: .sit) == nil)
        let chair = piece("c", "kenney-chair", x: 4, z: 4, width: 2, depth: 2)
        #expect(CatRoutine.nextTrip(items: hung + [chair], from: .atEntrance, sample: 0, catalog: catalog).end.itemId == "c")
        // A rest that names a board (a hand-made state) drops to the floor.
        let onBoard = CatRest(cell: GridCell(x: 4, z: 1), itemId: "b", lastItemId: "b", action: .sit)
        #expect(CatRoutine.settled(onBoard, items: hung, catalog: catalog).itemId == nil)
        // A floor placement is judged the same with or without boards around.
        #expect(GridRules.firstFreePlacement(for: catalog.model(id: "kenney-chair")!, in: hung, catalog: catalog)
                == GridRules.firstFreePlacement(for: catalog.model(id: "kenney-chair")!, in: [], catalog: catalog))
    }

    @Test func suggestedBoardPlacementIsTheMiddleOfTheBackWallThenTheLeft() throws {
        let model = try #require(catalog.model(id: "wall-photo-board"))
        #expect(GridRules.firstFreePlacement(for: model, in: [], catalog: catalog) == onWall(x: 6))
        // Middle taken: the nearest free span; equally near on both sides, the smaller offset.
        #expect(GridRules.firstFreePlacement(for: model, in: [board("a", x: 6)], catalog: catalog) == onWall(x: 8))
        #expect(GridRules.firstFreePlacement(for: model, in: [board("a", x: 6), board("b", x: 8)], catalog: catalog) == onWall(x: 4))
        // Back wall full: the left wall, then nothing.
        let back = (0..<5).map { board("b\($0)", x: $0 * 3, width: 3) }
        #expect(GridRules.firstFreePlacement(for: model, in: back, catalog: catalog) == onWall(x: 6, wall: .left))
        let both = back + back.map { board($0.instanceId + "l", x: $0.x, width: 3, wall: .left) }
        #expect(GridRules.firstFreePlacement(for: model, in: both, catalog: catalog) == nil)
    }

    @Test func theStoreHangsABoardAndKeepsItsWallAcrossReloadStowAndRestore() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let hung = try await store.addFurniture(placement: onWall(x: 4, width: 3, wall: .left), displayName: "")
        #expect(hung.wall == .left && hung.displayName == "照片板" && hung.placement == onWall(x: 4, width: 3, wall: .left))
        // Photos go onto it by hand, or with a recognition that found no furniture.
        let portrait = try await store.addPhoto(draft: try TestSupport.draft(seed: 650))
        _ = try await store.linkPhoto(photoId: portrait.photoId, toInstance: hung.instanceId)
        let nothingFound = SourceDecision(recognition: RecognitionResult(analyzer: "test", analyzerRevision: 1, objects: [], catLikely: true), acceptedObjectIndex: nil)
        let two = try await store.addSource(draft: try TestSupport.draft(seed: 651), toInstance: hung.instanceId, decision: nothingFound)
        #expect(two.sources.count == 2 && two.sources.allSatisfy { $0.origin == .user && $0.observationId == nil })
        await #expect(throws: StoreError.placement([.wrongMount])) {
            try await store.updatePlacement(instanceId: hung.instanceId, placement: Placement(modelId: "wall-photo-board", x: 4, z: 4, width: 3, depth: 1))
        }
        let moved = try await store.updatePlacement(instanceId: hung.instanceId, placement: onWall(x: 0, width: 2, wall: .back))
        #expect(moved.wall == .back && moved.width == 2 && moved.sources == two.sources)
        // A chair right under it is fine.
        _ = try await store.addFurniture(placement: Placement(modelId: "kenney-chair", x: 0, z: 0, width: 2, depth: 2), displayName: "")

        let stowed = try await store.stowFurniture(instanceId: hung.instanceId)
        #expect(stowed.wall == .back)
        let back = try await store.restoreFurniture(instanceId: hung.instanceId, placement: onWall(x: 6, wall: .left))
        #expect(back.wall == .left && back.sources == two.sources)
        let state = await store.snapshot()
        let json = try #require(String(data: Data(contentsOf: root.appendingPathComponent("state.json")), encoding: .utf8))
        #expect(json.components(separatedBy: "\"wall\":\"left\"").count == 2, "written for the board only")
        #expect(try await LibraryStore(root: root, catalog: catalog).load() == state)
        #expect(await store.integrityReport().isClean)
    }
}
