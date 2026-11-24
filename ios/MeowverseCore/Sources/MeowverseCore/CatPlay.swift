import Foundation

public enum CatPlayItem: String, CaseIterable, Codable, Sendable, Identifiable {
    case toyMouse, toyBall, featherWand, windUpMouse
    case treatSalmon, treatChicken, treatBiscuit

    public var id: String { rawValue }

    public enum Contact: Sendable {
        case groundPaw, raisedPaw, muzzle

        public var clipName: String {
            switch self {
            case .groundPaw: "bat_ground"
            case .raisedPaw: "bat_high"
            case .muzzle: "eat"
            }
        }

        /// Horizontal offset of the baked paw or muzzle from the cat's root, in cells.
        fileprivate var offset: (x: Double, z: Double) {
            switch self {
            case .groundPaw: (0.013701, 0.55)
            case .raisedPaw: (-0.150, 0.807)
            case .muzzle: (-0.097085, 0.62)
            }
        }
    }

    public var contact: Contact {
        switch self {
        case .toyMouse, .toyBall, .windUpMouse: .groundPaw
        case .featherWand: .raisedPaw
        case .treatSalmon, .treatChicken, .treatBiscuit: .muzzle
        }
    }

    public var isTreat: Bool { contact == .muzzle }

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
    /// A short dash through unobstructed floor cells, favouring steps away from the cat.
    public static func mouseRun(from start: GridCell, awayFrom cat: GridCell, blocked: Set<GridCell>) -> [GridCell] {
        var visited = blocked.union([start, GridRules.entrance])
        var path: [GridCell] = []
        func distance(_ cell: GridCell) -> Int {
            let dx = cell.x - cat.x, dz = cell.z - cat.z
            return dx * dx + dz * dz
        }
        for _ in 0..<3 {
            let choices = neighbours(of: path.last ?? start).filter { !visited.contains($0) }
            guard let next = choices.max(by: { distance($0) < distance($1) }) else { break }
            visited.insert(next)
            path.append(next)
        }
        return path
    }

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
        let contact = request.item.contact.offset
        let point = GridPoint(x: goal.x - cos(yaw) * contact.x - sin(yaw) * contact.z, y: 0,
                              z: goal.z + sin(yaw) * contact.x - cos(yaw) * contact.z)
        return CatTrip(end: trip.end, leaving: trip.leaving, path: trip.path, seat: point, rotation: yaw,
                       exitVia: trip.exitVia, entryVia: [], sharedAccessPath: nil,
                       legacyExit: trip.legacyExit, legacyEntry: false)
    }
}
