import MeowverseCore
import UIKit

// The pages a chapter can begin on (LINES.md T5.10), and the facts about this home the tour's
// chapters depend on, read the same way for the tour and for Settings' list.

/// The photo library, the furniture library and the Play panel each carry an invisible probe on
/// their root (`tourAnchor(TourPages.anchor(...))`). The page is up when that probe is in the
/// topmost layer: a push inside the page takes its root out of the window, a sheet over it is a
/// layer further up. The company page is counted by `TourCompanyPageSeen` instead.
@MainActor
enum TourPages {
    static let all: [TourSurface] = [.photoLibrary, .furnitureLibrary, .interactionPanel]

    static func anchor(_ page: TourSurface) -> String {
        switch page {
        case .photoLibrary: "page-photo-library"
        case .furnitureLibrary: "page-furniture-library"
        case .interactionPanel: "page-play"
        default: ""
        }
    }

    static func isUp(_ page: TourSurface, in window: UIWindow?) -> Bool {
        let id = anchor(page)
        guard !id.isEmpty, let window, let root = window.rootViewController,
              let probe = TourAnchorRegistry.shared.probe(id, in: window) else { return false }
        var top = root
        while let next = top.presentedViewController { top = next }
        return probe.isDescendant(of: top.view)
    }
}

/// What the chapters of T5 need to know about this home (LINES.md T5.10).
@MainActor
enum TourFacts {
    /// The pieces the Play panel offers the cat: not on a wall, not only for show
    /// (`InteractionPicker`).
    static func catPieces(_ model: AppModel) -> [PhotoFurniture] {
        model.roomFurniture.filter { item in
            item.wall == nil && model.catalog?.model(id: item.modelId)?.isDecorative != true
        }
    }

    /// The cat can get to at least one place on the piece: the panel does not grey all of it out.
    static func reachable(_ item: PhotoFurniture, _ model: AppModel) -> Bool {
        guard let catalog = model.catalog, let piece = catalog.model(id: item.modelId),
              CatRoutine.accessCell(of: item, in: model.roomFurniture) != nil else { return false }
        return piece.interactionSites.contains { site in
            site.actions.first.map {
                CatRoutine.invitedTrip(items: model.roomFurniture, from: .atEntrance, catalog: catalog,
                                       itemId: item.instanceId, siteId: site.id, action: $0) != nil
            } ?? false
        }
    }

    /// 10.2's piece in the furniture library's list: the first piece in the room, not locked if
    /// there is one; with none in the room, the first in the storage box. nil in the grid of covers,
    /// which has no 「⋯」 (LINES.md T5.10, T5.14). `FurnitureListView` puts the anchor on it.
    static func pieceMenuPiece(_ model: AppModel) -> PhotoFurniture? {
        guard !model.pieces.grid else { return nil }
        let shown = model.shownFurniture
        let inRoom = shown.filter { model.furniture($0.instanceId) != nil }
        return inRoom.first { !$0.isLocked } ?? inRoom.first ?? shown.first
    }

    static func pieceMenu(_ model: AppModel) -> TourScript.PieceMenu {
        guard let piece = pieceMenuPiece(model) else { return .none }
        return model.furniture(piece.instanceId) == nil ? .stored : .room
    }
}
