import MeowverseCore
import SwiftUI

/// Rooms and cats on screen. Kept in one value so AppModel gains one property.
struct HomeUIState {
    /// "房间和猫咪": the page that adds, renames and removes rooms and cats.
    var managerShown = false
    /// 设置's 「猫咪的名字和模型」 row: when 设置 has closed, the room opens 猫咪管理.
    var catsAfterSettings = false
}

extension AppModel {
    // MARK: Several rooms and cats

    /// Whether a second room or cat can be made (`FeatureFlags.severalRoomsAndCats`, or the test
    /// switch `-MeowverseSeveralHomes` in DEBUG and drill builds).
    ///
    /// It gates making new ones only. Rooms and cats that are already in the library (a restored
    /// backup, say) show, switch, rename and delete without it.
    var offersSeveralHomes: Bool { FeatureFlags.severalRoomsAndCats || options.severalHomes }

    // MARK: The room on screen

    /// The room the screen shows. Falls back to the first room when the chosen one is gone.
    var currentRoomId: String {
        state.room(id: chosenRoomId) != nil ? chosenRoomId : AppState.primaryRoomId
    }

    var currentRoom: Room { state.room(id: currentRoomId) ?? state.allRooms[0] }

    /// The pieces placed in the room on screen.
    var roomFurniture: [PhotoFurniture] { state.furniture(inRoom: currentRoomId) }

    var hasSeveralRooms: Bool { state.allRooms.count > 1 }

    /// The name shown for a room: the user's, or a default that needs no saving.
    func roomName(_ room: Room) -> String {
        if let name = room.name { return name }
        let index = state.allRooms.firstIndex { $0.roomId == room.roomId } ?? 0
        return index == 0 ? String(localized: "\(Wording.subject(catName))的房间") : Wording.numberedRoom(index + 1)
    }

    /// The name of the room a placed piece stands in; nil for a piece that is put away.
    func roomName(ofFurniture instanceId: String) -> String? {
        state.roomId(ofFurniture: instanceId).flatMap(state.room(id:)).map(roomName)
    }

    private var chosenRoomKey: String { "currentRoom." + options.storeFolder }

    func loadChosenRoom() {
        chosenRoomId = UserDefaults.standard.string(forKey: chosenRoomKey) ?? AppState.primaryRoomId
    }

    /// Shows another room. The cat starts at that room's door.
    func showRoom(_ roomId: String) {
        guard state.room(id: roomId) != nil, roomId != currentRoomId else { return }
        chosenRoomId = roomId
        UserDefaults.standard.set(roomId, forKey: chosenRoomKey)
        pieces.located = nil
        bellaStatus = .atEntrance
    }

    /// Shows the room a placed piece stands in.
    func showRoom(ofFurniture instanceId: String) {
        if let roomId = state.roomId(ofFurniture: instanceId) { showRoom(roomId) }
    }

    // MARK: Changing rooms

    /// Makes a room and shows it. The one way to make one, so the refusal holds for every caller.
    func addRoom(name: String) async -> PhotoSaveFailure? {
        guard offersSeveralHomes else { return PhotoSaveFailure(message: String(localized: "这个版本不能新建房间。"), error: nil) }
        switch await perform({ try await $0.addRoom(name: name) }) {
        case .success(let room):
            showRoom(room.roomId)
            return nil
        case .failure(let failure): return failure
        }
    }

    func renameRoom(_ roomId: String, to name: String) async -> PhotoSaveFailure? {
        failure(of: await perform { _ = try await $0.renameRoom(roomId: roomId, name: name) })
    }

    /// Removes a room: its furniture goes to the storage box with its photos.
    func removeRoom(_ roomId: String) async -> PhotoSaveFailure? {
        guard !state.furniture(inRoom: roomId).contains(where: \.isLocked) else {
            return PhotoSaveFailure(message: String(localized: "这个房间里有已锁定的家具。先解锁或搬到别的房间，再删除房间。"), error: .locked)
        }
        if pieces.query.roomId == roomId { pieces.query.roomId = nil }
        return failure(of: await perform { try await $0.removeRoom(roomId: roomId) })
    }

    /// Moves a placed piece to another room and shows it there. It keeps its spot when that is
    /// free in the new room, and takes the first free one otherwise.
    func moveFurniture(_ instanceId: String, toRoom roomId: String) async -> PhotoSaveFailure? {
        guard let item = furniture(instanceId), let catalog, catalog.model(id: item.modelId) != nil else {
            return PhotoSaveFailure(message: String(localized: "这件家具已经不在了。"), error: .unknownInstance)
        }
        guard !item.isLocked else { return PhotoSaveFailure(message: Self.photoMessage(for: StoreError.locked), error: .locked) }
        // A place edit like move, stow and restore: sync holds it back here (COMPAT-2).
        if let refusal = placeEditRefusal([instanceId]) { return PhotoSaveFailure(message: refusal, error: nil) }
        let there = state.furniture(inRoom: roomId)
        guard let spot = GridRules.placementForTransfer(item.placement, in: there, catalog: catalog) else {
            return PhotoSaveFailure(message: String(localized: "那个房间放不下这件家具了。先在那边腾出位置。"), error: nil)
        }
        let result = await perform { _ = try await $0.updatePlacement(instanceId: instanceId, placement: spot, roomId: roomId) }
        if case .failure(let failure) = result { return failure }
        showRoom(roomId)
        locate(instanceId)
        return nil
    }

    // MARK: Cats

    /// The cats the room on screen shows: those that live there and those that keep you company.
    var roomCats: [Cat] { state.cats(inRoom: currentRoomId) }

    /// The cat the caption, invitations and play follow: the first one in the room. nil when
    /// every cat lives in another room.
    var leadCat: Cat? { roomCats.first }

    /// The name the room's caption uses.
    var leadCatName: String { leadCat?.name ?? catName }

    var hasSeveralCats: Bool { state.allCats.count > 1 }

    /// Where a cat is, for a row: "跟着你" or the room it lives in.
    func whereabouts(of cat: Cat) -> String {
        guard let roomId = cat.roomId, let room = state.room(id: roomId) else { return String(localized: "跟着你") }
        return String(localized: "住在「\(roomName(room))」")
    }

    /// Adds a cat. The one way to add one, so the refusal holds for every caller.
    func addCat(name: String) async -> PhotoSaveFailure? {
        guard offersSeveralHomes else { return PhotoSaveFailure(message: String(localized: "这个版本不能添加猫咪。"), error: nil) }
        return failure(of: await perform { _ = try await $0.addCat(name: name) })
    }

    /// `generation`: the library the name was typed for; another one refuses it.
    func renameCat(_ catId: String, to name: String, generation: UUID? = nil) async -> PhotoSaveFailure? {
        failure(of: await perform { _ = try await $0.renameCat(catId: catId, name: name, generation: generation) })
    }

    /// Says where a cat lives; nil = it keeps you company in whichever room you look at.
    func setCatRoom(_ catId: String, _ roomId: String?) async -> PhotoSaveFailure? {
        failure(of: await perform { _ = try await $0.setCatRoom(catId: catId, roomId: roomId) })
    }

    func removeCat(_ catId: String) async -> PhotoSaveFailure? {
        failure(of: await perform { try await $0.removeCat(catId: catId) })
    }

    private func failure<T>(of result: Result<T, PhotoSaveFailure>) -> PhotoSaveFailure? {
        if case .failure(let failure) = result { return failure }
        return nil
    }
}

extension Wording {
    /// The default name of a room the user has not named ("房间 2").
    static func numberedRoom(_ number: Int) -> String {
        String(localized: "房间 \(String(number))")
    }
}
