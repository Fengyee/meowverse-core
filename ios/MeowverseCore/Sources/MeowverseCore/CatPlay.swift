import Foundation

public enum CatPlayItem: String, CaseIterable, Codable, Sendable, Identifiable {
    case toyMouse, toyBall, featherWand
    case treatSalmon, treatChicken, treatBiscuit

    public var id: String { rawValue }

    public var isTreat: Bool {
        switch self {
        case .toyMouse, .toyBall, .featherWand: false
        case .treatSalmon, .treatChicken, .treatBiscuit: true
        }
    }

    public var action: CatAction { isTreat ? .eat : .play }
}

/// A session command. Its identity prevents an old consumption callback clearing a newer treat.
public struct CatPlayRequest: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let item: CatPlayItem
    /// The object occupies this free floor cell. Bella approaches from a neighbouring cell.
    public let cell: GridCell

    public init(id: UUID = UUID(), item: CatPlayItem, cell: GridCell) {
        self.id = id
        self.item = item
        self.cell = cell
    }

    public var point: GridPoint { CatRoutine.cellPoint(cell) }
}

extension CatRoutine {
    public static func floorTrip(items: [PhotoFurniture], from rest: CatRest, catalog: FurnitureCatalog,
                                 to cell: GridCell, action: CatAction) -> CatTrip? {
        let rest = settled(rest, items: items, catalog: catalog)
        guard let path = route(items: items, from: rest.cell, to: cell) else { return nil }
        var end = rest
        end.cell = cell
        end.itemId = nil
        end.siteId = nil
        end.action = action
        return CatVisitPlanner(items: items, rest: rest, catalog: catalog)
            .trip(end: end, path: path, destination: nil, rotation: 0)
    }

    public static func playTrip(items: [PhotoFurniture], from rest: CatRest, catalog: FurnitureCatalog,
                                request: CatPlayRequest) -> CatTrip? {
        let target = request.cell
        guard GridRules.inRoom(x: target.x, z: target.z), !GridRules.blockedCells(items).contains(target) else { return nil }
        let candidates = neighbours(of: target).compactMap { cell in
            floorTrip(items: items, from: rest, catalog: catalog, to: cell, action: request.item.action)
        }
        guard let trip = candidates.min(by: { $0.path.count < $1.path.count }) else { return nil }
        let standing = cellPoint(trip.end.cell), goal = request.point
        let yaw = atan2(goal.x - standing.x, goal.z - standing.z)
        let contact: (x: Double, z: Double)
        switch request.item {
        case .treatSalmon, .treatChicken, .treatBiscuit: contact = (-0.097085, 0.62)
        case .toyMouse, .toyBall: contact = (0.013701, 0.55)
        case .featherWand: contact = (-0.150, 0.807)
        }
        // Match each baked muzzle or paw contact while keeping the root in the adjacent cell.
        let muzzleX = contact.x, muzzleZ = contact.z
        let point = GridPoint(x: goal.x - cos(yaw) * muzzleX - sin(yaw) * muzzleZ, y: 0,
                              z: goal.z + sin(yaw) * muzzleX - cos(yaw) * muzzleZ)
        return CatTrip(end: trip.end, leaving: trip.leaving, path: trip.path, seat: point, rotation: yaw,
                       exitVia: trip.exitVia, entryVia: [], sharedAccessPath: nil,
                       legacyExit: trip.legacyExit, legacyEntry: false)
    }
}
