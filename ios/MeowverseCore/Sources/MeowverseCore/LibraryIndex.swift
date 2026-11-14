import Foundation

/// Rooms, cats and where the furniture is, without naming the arrays the file keeps them in.
/// The app reads them only through these.
extension AppState {
    /// Every room, the first one first. Never empty.
    public var allRooms: [Room] { rooms.isEmpty ? [Room(roomId: Self.primaryRoomId)] : rooms }

    public func room(id: String) -> Room? { allRooms.first { $0.roomId == id } }

    /// Every cat, the first one first. Never empty.
    public var allCats: [Cat] { cats.isEmpty ? [Cat(catId: Self.primaryCatId, name: catName)] : cats }

    public func cat(id: String) -> Cat? { allCats.first { $0.catId == id } }

    public var primaryCat: Cat { allCats[0] }

    /// Even without photos or furniture, a room name or a cat's home is worth backing up.
    public var isEmptyForBackup: Bool {
        photos.isEmpty && items.isEmpty && storage.isEmpty
            && allRooms == Self.empty.allRooms && allCats == Self.empty.allCats
    }

    /// The cats to show in a room: those that live there, and those that keep the user company.
    public func cats(inRoom roomId: String) -> [Cat] {
        allCats.filter { $0.roomId == nil || $0.roomId == roomId }
    }

    /// The room a placed piece stands in (the first room when the piece does not say).
    public static func roomId(of piece: PhotoFurniture) -> String { piece.roomId ?? primaryRoomId }

    /// The pieces placed in a room, in the order they were added. An unknown room has none.
    public func furniture(inRoom roomId: String) -> [PhotoFurniture] {
        items.filter { Self.roomId(of: $0) == roomId }
    }

    /// The pieces placed in any room.
    public var placedFurniture: [PhotoFurniture] { items }

    /// The pieces put away. The storage box belongs to no room.
    public var storedFurniture: [PhotoFurniture] { storage }

    /// Every piece the user has: those in rooms first, then those put away.
    public var allFurniture: [PhotoFurniture] { items + storage }

    /// The room a piece stands in, or nil when it is put away or unknown.
    public func roomId(ofFurniture instanceId: String) -> String? {
        item(id: instanceId).map(Self.roomId(of:))
    }
}

/// Both directions of the photo–furniture link, built once from a state.
///
/// The link is stored in one place only, each piece's `sources`. This answers the reverse
/// question (which pieces hold this photo) and the counts without scanning every piece per
/// photo. It is a snapshot: build a new one when the state changes.
public struct LibraryIndex: Sendable {
    private let furnitureById: [String: PhotoFurniture]
    private let photosById: [String: PhotoRecord]
    /// Furniture ids per photo, in `allFurniture` order.
    private let furnitureIdsByPhoto: [String: [String]]
    private let roomByFurniture: [String: String]

    public init(state: AppState) {
        var furniture: [String: PhotoFurniture] = [:]
        var byPhoto: [String: [String]] = [:]
        var rooms: [String: String] = [:]
        for piece in state.allFurniture {
            furniture[piece.instanceId] = piece
            if let room = state.roomId(ofFurniture: piece.instanceId) { rooms[piece.instanceId] = room }
            for source in piece.sources {
                byPhoto[source.photoId, default: []].append(piece.instanceId)
            }
        }
        furnitureById = furniture
        furnitureIdsByPhoto = byPhoto
        roomByFurniture = rooms
        photosById = Dictionary(state.photos.map { ($0.photoId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Every piece that holds the photo: those in rooms first, then those put away.
    public func furniture(ofPhoto photoId: String) -> [PhotoFurniture] {
        (furnitureIdsByPhoto[photoId] ?? []).compactMap { furnitureById[$0] }
    }

    /// The photos on a piece, in the piece's own order. A link whose photo is gone is skipped.
    public func photos(ofFurniture instanceId: String) -> [PhotoRecord] {
        (furnitureById[instanceId]?.sources ?? []).compactMap { photosById[$0.photoId] }
    }

    /// How many pieces hold the photo.
    public func linkCount(ofPhoto photoId: String) -> Int {
        furnitureIdsByPhoto[photoId]?.count ?? 0
    }

    public func isLinked(_ photoId: String) -> Bool { linkCount(ofPhoto: photoId) > 0 }

    /// How many photos a piece holds; 0 for an unknown piece.
    public func photoCount(ofFurniture instanceId: String) -> Int {
        furnitureById[instanceId]?.sources.count ?? 0
    }

    /// The ids of every photo that is on at least one piece.
    public var linkedPhotoIds: Set<String> { Set(furnitureIdsByPhoto.keys) }

    /// The photos on the pieces placed in a room, each once, in library order.
    public func photos(inRoom roomId: String, of state: AppState) -> [PhotoRecord] {
        let wanted = Set(furnitureIdsByPhoto.filter { $0.value.contains { roomByFurniture[$0] == roomId } }.keys)
        return state.photos.filter { wanted.contains($0.photoId) }
    }

    /// When a photo was last put on the piece, or nil when no link of the piece says
    /// (links made before `addedAt` existed, or a piece without photos).
    public func lastPhotoAdded(toFurniture instanceId: String) -> Date? {
        furnitureById[instanceId]?.sources.compactMap(\.addedAt).max()
    }
}
