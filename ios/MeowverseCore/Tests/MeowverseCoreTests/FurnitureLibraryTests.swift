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
        await #expect(throws: StoreError.locked) {
            try await reopened.restoreFurniture(instanceId: stool.instanceId, placement: stool.placement)
        }
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

    // MARK: Taking photos off from the photo library, and taking that back

    private func modelOriginChair(_ store: LibraryStore) async throws -> PhotoFurniture {
        let recognition = RecognitionResult(analyzer: "test", analyzerRevision: 1,
                                            objects: [ObservedObject(kind: .chair, label: "chair", confidence: 0.9)], catLikely: true)
        return try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 65),
                                                  placement: Placement(modelId: "kenney-chair", x: 8, z: 8, width: 2, depth: 2),
                                                  displayName: "认出来的椅", decision: SourceDecision(recognition: recognition, acceptedObjectIndex: 0))
    }

    /// One write takes a photo off every piece it is on (or only the pieces named), the photo
    /// and the pieces stay, and undoing puts each link back where it was with its own origin,
    /// observation and relation: undo never turns a recognised link into a hand-made one.
    @Test func takingPhotosOffSeveralPiecesIsOneWriteAndUndoRestoresEachLinkExactly() async throws {
        let (root, store, chair, stool, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = try await modelOriginChair(store)
        let shared = try #require(seen.sources.first)
        #expect(shared.origin == .model && shared.observationId != nil)
        let ids = loose.map(\.photoId)
        try await store.linkPhotos(photoIds: [ids[0], shared.photoId, ids[1]], toInstance: chair.instanceId)
        try await store.linkPhotos(photoIds: [shared.photoId], toInstance: stool.instanceId)
        _ = try await store.linkPhotos(photoIds: [ids[2]], toInstance: seen.instanceId)
        _ = try await store.setCover(instanceId: chair.instanceId, photoId: shared.photoId)
        let before = await store.snapshot()

        // Only the stool: the photo stays on the other two.
        let one = try await store.unlinkPhotos(photoIds: [shared.photoId], fromInstances: [stool.instanceId])
        #expect(one.removed.map(\.instanceId) == [stool.instanceId])
        #expect(await store.snapshot().revision == before.revision + 1)
        #expect(try await store.undoUnlink(one) == 1)
        let undone = await store.snapshot()
        for piece in before.allFurniture {
            // Only the bookkeeping moves on; links, order and cover are as they were.
            #expect(undone.anyFurniture(piece.instanceId)?.sources == piece.sources)
            #expect(undone.anyFurniture(piece.instanceId)?.coverPhotoId == piece.coverPhotoId)
        }

        // Every piece at once, in one write: the photo is back in "not in any furniture".
        let revision = await store.snapshot().revision
        let all = try await store.unlinkPhotos(photoIds: [shared.photoId], fromInstances: nil)
        var state = await store.snapshot()
        #expect(state.revision == revision + 1)
        #expect(Set(all.removed.map(\.instanceId)) == [chair.instanceId, stool.instanceId, seen.instanceId])
        #expect(state.allFurniture.allSatisfy { !$0.sources.contains { $0.photoId == shared.photoId } })
        #expect(state.photos.contains { $0.photoId == shared.photoId }, "the photo stays in the library")
        #expect(state.observations.contains { $0.observationId == shared.observationId }, "and so does what was recognised")
        #expect(state.anyFurniture(seen.instanceId)?.sources.map(\.photoId) == [ids[2]], "the piece stays, with its other photo")

        #expect(try await store.undoUnlink(all) == 3)
        state = await store.snapshot()
        for piece in before.allFurniture {
            let now = try #require(state.anyFurniture(piece.instanceId))
            #expect(now.sources == piece.sources, "\(piece.displayName): same links, same order, same provenance")
            #expect(now.cover == piece.cover)
        }
        let back = try #require(state.anyFurniture(seen.instanceId)?.sources.first)
        #expect(back.origin == .model && back.observationId == shared.observationId && back.relationToCat == shared.relationToCat)
    }

    /// Undo comes late: what the user did meanwhile wins. A photo put back by hand, a piece
    /// deleted, a photo deleted are each left as they are, and nothing else is written.
    @Test func undoingATakeOffLeavesWhatChangedMeanwhileAlone() async throws {
        let (root, store, chair, stool, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = loose.map(\.photoId)
        try await store.linkPhotos(photoIds: ids, toInstance: chair.instanceId)
        try await store.linkPhotos(photoIds: [ids[0], ids[1]], toInstance: stool.instanceId)
        let receipt = try await store.unlinkPhotos(photoIds: ids, fromInstances: nil)
        #expect(receipt.removed.count == 5)

        // Meanwhile: ids[0] goes back on the chair by hand, the stool is deleted, ids[2] is deleted.
        try await store.linkPhotos(photoIds: [ids[0]], toInstance: chair.instanceId)
        let byHand = try #require(await store.snapshot().anyFurniture(chair.instanceId)?.sources.last)
        try await store.removeFurniture(instanceId: stool.instanceId)
        try await store.deletePhoto(photoId: ids[2])

        #expect(try await store.undoUnlink(receipt) == 1, "only ids[1] on the chair comes back")
        let sources = try #require(await store.snapshot().anyFurniture(chair.instanceId)?.sources)
        // ids[1] goes back to its old place, after the link made by hand.
        #expect(sources.map(\.photoId) == [chair.sources[0].photoId, ids[0], ids[1]])
        #expect(sources[1] == byHand, "the link made by hand is the user's, not replaced by the old one")

        let revision = await store.snapshot().revision
        #expect(try await store.undoUnlink(receipt) == 0)
        #expect(await store.snapshot().revision == revision, "nothing left to undo writes nothing")
    }

    /// Unknown photos or pieces reject the whole call; a photo not on a named piece is skipped.
    @Test func takingOffRejectsUnknownsAndSkipsPhotosThatAreNotThere() async throws {
        let (root, store, chair, stool, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = await store.snapshot()
        await #expect(throws: StoreError.unknownPhoto) { try await store.unlinkPhotos(photoIds: ["nope"], fromInstances: nil) }
        await #expect(throws: StoreError.unknownInstance) {
            try await store.unlinkPhotos(photoIds: [chair.sources[0].photoId], fromInstances: [chair.instanceId, "nope"])
        }
        let nothing = try await store.unlinkPhotos(photoIds: [loose[0].photoId], fromInstances: [stool.instanceId])
        #expect(nothing.removed.isEmpty)
        #expect(await store.snapshot() == before, "nothing to take off writes nothing")
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

private extension AppState {
    /// A piece in a room or in the storage box.
    func anyFurniture(_ instanceId: String) -> PhotoFurniture? {
        allFurniture.first { $0.instanceId == instanceId }
    }
}
