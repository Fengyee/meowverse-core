import Foundation

/// Which pieces the furniture library shows, and in what order. Every part narrows the result;
/// the defaults show everything in the order the pieces were added.
public struct FurnitureQuery: Sendable, Equatable {
    public enum Place: String, CaseIterable, Sendable {
        case all, room, stored
    }

    public enum Photos: String, CaseIterable, Sendable {
        case any, with, without
    }

    public enum Sort: String, CaseIterable, Sendable {
        /// The order the pieces were added: room first, then the storage box.
        case added
        case name
        case photoCount
        /// When a photo was last put on the piece. Pieces with no recorded time come last.
        case lastPhotoAdded
        /// When the piece was made. Pieces from before that was recorded come last.
        case created
    }

    public var place: Place
    /// Only the pieces placed in this room: a piece that is put away is in no room, so it is
    /// left out whatever `place` says. nil = every room.
    public var roomId: String?
    /// Empty = every category.
    public var categories: Set<FurnitureCategory>
    public var photos: Photos
    public var lockedOnly: Bool
    /// Matched against the name, ignoring case and accents. Blank = no search.
    public var search: String
    public var sort: Sort
    /// `added` and `name` read naturally ascending; the counts and dates start from the most.
    public var ascending: Bool

    public init(place: Place = .all, roomId: String? = nil, categories: Set<FurnitureCategory> = [], photos: Photos = .any,
                lockedOnly: Bool = false, search: String = "", sort: Sort = .added, ascending: Bool = true) {
        self.place = place
        self.roomId = roomId
        self.categories = categories
        self.photos = photos
        self.lockedOnly = lockedOnly
        self.search = search
        self.sort = sort
        self.ascending = ascending
    }

    /// Whether anything but the place and the order is narrowing the list.
    public var isNarrowed: Bool {
        !categories.isEmpty || photos != .any || lockedOnly || roomId != nil
    }

    /// The direction a sort starts in when it is first picked.
    public static func defaultAscending(for sort: Sort) -> Bool {
        switch sort {
        case .added, .name: true
        case .photoCount, .lastPhotoAdded, .created: false
        }
    }
}

public enum FurnitureLibrary {
    /// The "unrecognised" action uses a board in this room. In a single-room home it can also
    /// use a board from storage. Other placements remain available by choosing a piece explicitly.
    public static func photoBoard(for targets: [PhotoFurniture], inRoom roomId: String,
                                 state: AppState, catalog: FurnitureCatalog) -> PhotoFurniture? {
        let eligible = Set(targets.lazy.filter { catalog.model(id: $0.modelId)?.category == .photoBoard }.map(\.instanceId))
        if let local = state.furniture(inRoom: roomId).first(where: { eligible.contains($0.instanceId) }) { return local }
        guard state.allRooms.count == 1 else { return nil }
        return state.storedFurniture.first { eligible.contains($0.instanceId) }
    }

    /// The pieces a query shows, in its order. A piece whose model the catalog does not know
    /// has no category and passes only when no category is asked for. In the two date orders a
    /// piece without a recorded time comes last whichever way the order runs: unknown is not
    /// "oldest". Ties keep the order the pieces were added.
    public static func pieces(in state: AppState, catalog: FurnitureCatalog?, query: FurnitureQuery) -> [PhotoFurniture] {
        let pool: [PhotoFurniture] = switch query.place {
        case .all: state.allFurniture
        case .room: state.placedFurniture
        case .stored: state.storedFurniture
        }
        let inRoom = query.roomId.map { Set(state.furniture(inRoom: $0).map(\.instanceId)) }
        let needle = fold(query.search.trimmingCharacters(in: .whitespacesAndNewlines))
        let kept = pool.filter({ (piece: PhotoFurniture) -> Bool in
            if let inRoom, !inRoom.contains(piece.instanceId) { return false }
            if !query.categories.isEmpty {
                guard let category = catalog?.model(id: piece.modelId)?.category, query.categories.contains(category) else { return false }
            }
            switch query.photos {
            case .any: break
            case .with: if piece.sources.isEmpty { return false }
            case .without: if !piece.sources.isEmpty { return false }
            }
            if query.lockedOnly, !piece.isLocked { return false }
            if !needle.isEmpty, !fold(piece.displayName).contains(needle) { return false }
            return true
        })
        let indexed: [(offset: Int, element: PhotoFurniture)] = kept.enumerated().map { (offset: $0.offset, element: $0.element) }
        let ascending = query.ascending
        /// Known keys in the asked direction, unknown keys last, ties in added order.
        func ordered<Key: Comparable>(_ key: (PhotoFurniture) -> Key?) -> [PhotoFurniture] {
            let keyed = indexed.map { (offset: $0.offset, element: $0.element, key: key($0.element)) }
            let sorted = keyed.sorted(by: { a, b in
                switch (a.key, b.key) {
                case let (x?, y?):
                    if x == y { return a.offset < b.offset }
                    return ascending ? x < y : x > y
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): return a.offset < b.offset
                }
            })
            return sorted.map { $0.element }
        }
        switch query.sort {
        case .added:
            return ascending ? kept : Array(kept.reversed())
        case .name:
            let sorted = indexed.sorted(by: { a, b in
                let order = a.element.displayName.localizedStandardCompare(b.element.displayName)
                if order == .orderedSame { return a.offset < b.offset }
                return (order == .orderedAscending) == ascending
            })
            return sorted.map { $0.element }
        case .photoCount:
            return ordered { $0.sources.count }
        case .lastPhotoAdded:
            return ordered { $0.sources.compactMap(\.addedAt).max() }
        case .created:
            return ordered { $0.createdAt }
        }
    }

    /// The categories the user's pieces actually have, in catalog order, for the filter menu.
    public static func categories(in state: AppState, catalog: FurnitureCatalog?) -> [FurnitureCategory] {
        let present = Set(state.allFurniture.compactMap { catalog?.model(id: $0.modelId)?.category })
        return FurnitureCategory.allCases.filter(present.contains)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
