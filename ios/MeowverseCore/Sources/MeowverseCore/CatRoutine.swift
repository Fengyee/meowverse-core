import Foundation

/// One floor cell of the room.
public struct GridCell: Hashable, Sendable {
    public var x: Int
    public var z: Int

    public init(x: Int, z: Int) {
        self.x = x
        self.z = z
    }
}

/// A point in room space: cell units, room centred on the origin, y up.
public struct GridPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Activities Bella can perform at a catalog interaction site.
public enum CatAction: String, Codable, Sendable, CaseIterable {
    case sit, loaf, sleep, scratch, play, hide
    case eat, drink, dig
}

/// Where Bella is between trips (`CatRest` in src/domain/grid/cat-routine.ts).
public struct CatRest: Equatable, Sendable {
    /// The floor cell she stands on, or the cell beside the furniture she is on that she got on from.
    public var cell: GridCell
    /// The furniture she is resting on; nil on the floor.
    public var itemId: String?
    /// The furniture she visited last, so visits go round in turn.
    public var lastItemId: String?
    public var action: CatAction
    public var siteId: String?
    /// Session-only variation. Each piece advances independently through its available activities.
    var lastActivityByItem: [String: Int] = [:]

    public init(cell: GridCell, itemId: String?, lastItemId: String?, action: CatAction, siteId: String? = nil) {
        self.cell = cell
        self.itemId = itemId
        self.lastItemId = lastItemId
        self.action = action
        self.siteId = siteId
    }

    public static let atEntrance = CatRest(cell: GridRules.entrance, itemId: nil, lastItemId: nil, action: .sit)
}

/// One walk: optionally down from a seat, along floor cells, optionally up onto a seat.
public struct CatTrip: Equatable, Sendable {
    public let end: CatRest
    /// The seat she jumps down from first; nil when she starts on the floor.
    public let leaving: GridPoint?
    /// Floor cells walked, start included. A single cell means she stays where she is.
    public let path: [GridCell]
    /// The seat she jumps onto at the end; nil when she ends on the floor.
    public let seat: GridPoint?
    /// Facing (radians about y, 0 = +z) once settled, as the web computes it.
    public let rotation: Double

    /// Intermediate furniture-local landings, transformed to room space and in travel order.
    public let exitVia: [GridPoint]
    public let entryVia: [GridPoint]
    /// Direct connection between two sites of the same piece when their access paths meet
    /// above the floor. A single point means only the activity changes.
    public let sharedAccessPath: [GridPoint]?
    let legacyExit: Bool
    let legacyEntry: Bool

    /// Height she clears above a seat when jumping on or off, like the web.
    public static let jumpClearance = 0.5

    /// The polyline the web cat follows (`points` of `nextCatTrip`).
    public var points: [GridPoint] {
        if let sharedAccessPath { return sharedAccessPath }
        var points: [GridPoint] = []
        if let leaving, legacyExit, let first = path.first {
            let foot = CatRoutine.cellPoint(first), peak = leaving.y + Self.jumpClearance
            points += [leaving, GridPoint(x: leaving.x, y: peak, z: leaving.z), GridPoint(x: foot.x, y: peak, z: foot.z)]
        } else if let leaving {
            points += [leaving] + exitVia
        }
        points += path.map(CatRoutine.cellPoint)
        if let seat, legacyEntry, let last = path.last {
            let foot = CatRoutine.cellPoint(last), peak = seat.y + Self.jumpClearance
            points += [GridPoint(x: foot.x, y: peak, z: foot.z), GridPoint(x: seat.x, y: peak, z: seat.z), seat]
        } else if let seat {
            points += entryVia + [seat]
        }
        return points
    }
}

/// Bella's routine, ported from `src/domain/grid/world.ts` and `cat-routine.ts`. Pure: the
/// caller supplies the random `sample` in 0...1, so a given room and sample give one trip.
public enum CatRoutine {
    /// `CAT_SCALE`: the web cat's size. The baked iOS meshes already include it.
    public static let webScale = 0.45

    /// The cell in front of a piece of furniture, where Bella gets on if she can. May lie outside
    /// the room or be taken; `accessCell` is where she actually gets on.
    public static func approachCell(of item: PhotoFurniture) -> GridCell {
        approachCell(x: item.x, z: item.z, width: item.width, depth: item.depth, turn: item.turn)
    }

    public static func approachCell(of placement: Placement) -> GridCell {
        approachCell(x: placement.x, z: placement.z, width: placement.width, depth: placement.depth, turn: placement.turn)
    }

    static func approachCell(x: Int, z: Int, width: Int, depth: Int, turn: Int) -> GridCell {
        switch turn {
        case 0: GridCell(x: x + width / 2, z: z + depth)
        case 1: GridCell(x: x + depth, z: z + width / 2)
        case 2: GridCell(x: x + width / 2, z: z - 1)
        default: GridCell(x: x - 1, z: z + width / 2)
        }
    }

    /// The cell Bella gets onto `item` from, in the room `items` (with or without `item` itself
    /// in the list): the front `approachCell` when it is free and she can walk to it from the
    /// entrance, so rooms laid out for the front cell behave as before; otherwise the free
    /// cell beside the piece she can walk to that is nearest to the front one (Manhattan
    /// distance, then smaller z, then smaller x). nil when she cannot get next to the piece at
    /// all, or it hangs on a wall.
    public static func accessCell(of item: PhotoFurniture, in items: [PhotoFurniture]) -> GridCell? {
        let room = items.filter { $0.instanceId != item.instanceId } + [item]
        return accessCell(of: item, reachable: GridRules.reachableCells(blocked: GridRules.blockedCells(room)))
    }

    /// `reachable`: the free cells she can walk to from wherever she starts.
    static func accessCell(of item: PhotoFurniture, reachable: Set<GridCell>) -> GridCell? {
        accessCell(of: item.placement, reachable: reachable)
    }

    private static func accessCell(of p: Placement, reachable: Set<GridCell>) -> GridCell? {
        guard p.wall == nil else { return nil }
        let front = approachCell(of: p)
        if reachable.contains(front) { return front }
        func rank(_ cell: GridCell) -> (Int, Int, Int) { (abs(cell.x - front.x) + abs(cell.z - front.z), cell.z, cell.x) }
        return GridRules.adjacentCells(x: p.x, z: p.z, width: p.width, depth: p.depth, turn: p.turn)
            .filter(reachable.contains).min { rank($0) < rank($1) }
    }

    /// Floor cells to keep clear in the placement editor. When a draft cuts off another piece,
    /// keep its previous access visible so the player can see which way to open up again.
    public static func placementGuideCells(in others: [PhotoFurniture], previewing draft: Placement) -> Set<GridCell> {
        let occupied = GridRules.blockedCells(others)
        let footprint = draft.wall == nil ? GridRules.occupiedCells(x: draft.x, z: draft.z, width: draft.width,
                                                                     depth: draft.depth, turn: draft.turn) : []
        let blocked = occupied.union(footprint.map { GridCell(x: $0.x, z: $0.z) })
        let reachable = GridRules.reachableCells(blocked: blocked)
        let before = GridRules.reachableCells(blocked: occupied)
        var cells: Set<GridCell> = [GridRules.entrance]
        for item in others {
            if let cell = accessCell(of: item, reachable: reachable) ?? accessCell(of: item, reachable: before) {
                cells.insert(cell)
            }
        }
        if let cell = accessCell(of: draft, reachable: reachable) ?? accessCell(of: draft, reachable: before) {
            cells.insert(cell)
        }
        return cells
    }

    /// Centre of a cell on the floor.
    public static func cellPoint(_ cell: GridCell) -> GridPoint {
        let half = Double(GridRules.size) / 2
        return GridPoint(x: Double(cell.x) + 0.5 - half, y: 0, z: Double(cell.z) + 0.5 - half)
    }

    /// Shortest 4-connected walk between two free cells that avoids all furniture; nil when
    /// either end is outside the room or occupied, or there is no way through.
    public static func route(items: [PhotoFurniture], from start: GridCell, to end: GridCell) -> [GridCell]? {
        route(blocked: GridRules.blockedCells(items), from: start, to: end)
    }

    static func route(blocked: Set<GridCell>, from start: GridCell, to end: GridCell) -> [GridCell]? {
        guard GridRules.inRoom(x: start.x, z: start.z), GridRules.inRoom(x: end.x, z: end.z),
              !blocked.contains(start), !blocked.contains(end) else { return nil }
        var cameFrom: [GridCell: GridCell] = [:]
        var queue = [start], seen: Set<GridCell> = [start], index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            if current == end {
                var path = [end]
                while let previous = cameFrom[path[path.count - 1]] { path.append(previous) }
                return path.reversed()
            }
            for next in neighbours(of: current) where !blocked.contains(next) && seen.insert(next).inserted {
                cameFrom[next] = current
                queue.append(next)
            }
        }
        return nil
    }

    /// In-room neighbours in the web's expansion order, so equal-length routes match the web.
    static func neighbours(of cell: GridCell) -> [GridCell] {
        [GridCell(x: cell.x + 1, z: cell.z), GridCell(x: cell.x, z: cell.z - 1),
         GridCell(x: cell.x - 1, z: cell.z), GridCell(x: cell.x, z: cell.z + 1)]
            .filter { GridRules.inRoom(x: $0.x, z: $0.z) }
    }

    /// The pose Bella takes on a category of furniture.
    public static func action(on category: FurnitureCategory) -> CatAction {
        switch category {
        case .bed: .sleep
        case .sofa, .bench, .windowPerch: .loaf
        case .chair, .stool, .table, .catTree, .platform: .sit
        case .scratcher: .scratch
        case .hideout: .hide
        case .toy: .play
        case .litterBox: .dig
        case .water: .drink
        // Never used: a wall piece has no interaction sites. Only keeps the switch total.
        case .photoBoard: .sit
        }
    }

    /// Bella's next trip (`nextCatTrip`).
    ///
    /// From the floor she visits the furniture after the one she visited last (the first visit is
    /// picked by `sample`); from furniture she hops down and wanders up to five cells away.
    /// Two things differ from the web on purpose: `preferring` names a piece (a new arrival) she
    /// goes to straight away, even from another piece; and furniture she cannot reach (possible
    /// only in rooms saved before the access rules) is skipped rather than ending the routine.
    /// She gets on from the piece's `accessCell`, and never visits a wall piece.
    /// `avoiding` names pieces she leaves alone this time (another cat is on them or on its way):
    /// they still stand in her way, but she does not pick them, not even as `preferring`.
    public static func nextTrip(items: [PhotoFurniture], from: CatRest, sample: Double, catalog: FurnitureCatalog,
                                preferring preferred: String? = nil, avoiding: Set<String> = []) -> CatTrip {
        let sample = sample.isFinite ? min(max(sample, 0), 1) : 0
        let planner = CatVisitPlanner(items: items, rest: settled(from, items: items, catalog: catalog), catalog: catalog)
        let rest = planner.rest
        if let preferred, preferred != rest.itemId, !avoiding.contains(preferred), let item = items.first(where: { $0.instanceId == preferred }),
           let trip = planner.visit(item: item, sample: sample) { return trip }
        if rest.itemId == nil, !items.isEmpty {
            let last = items.firstIndex { $0.instanceId == rest.lastItemId }
            let first = last.map { ($0 + 1) % items.count } ?? min(Int(sample * Double(items.count)), items.count - 1)
            for offset in 0..<items.count {
                let item = items[(first + offset) % items.count]
                if avoiding.contains(item.instanceId) { continue }
                if let trip = planner.visit(item: item, sample: sample) { return trip }
            }
        }
        let path = floorWalk(blocked: planner.blocked, from: rest.cell, sample: sample)
        var end = rest
        end.cell = path[path.count - 1]
        end.itemId = nil
        end.siteId = nil
        end.action = sample < 0.5 ? .loaf : .sit
        return planner.trip(end: end, path: path, destination: nil, rotation: sample * 2 * .pi)
    }

    public static func invitedTrip(items: [PhotoFurniture], from: CatRest, catalog: FurnitureCatalog,
                                   itemId: String, siteId: String, action: CatAction) -> CatTrip? {
        guard let item = items.first(where: { $0.instanceId == itemId }) else { return nil }
        let planner = CatVisitPlanner(items: items, rest: settled(from, items: items, catalog: catalog), catalog: catalog)
        return planner.visit(item: item, sample: 0, request: (siteId, action))
    }

    private static func floorWalk(blocked: Set<GridCell>, from start: GridCell, sample: Double) -> [GridCell] {
        var choices: [GridCell] = []
        for z in 0..<GridRules.size {
            for x in 0..<GridRules.size where (1...5).contains(abs(start.x - x) + abs(start.z - z)) {
                choices.append(GridCell(x: x, z: z))
            }
        }
        guard !choices.isEmpty else { return [start] }
        let offset = min(Int(Double(choices.count) * sample), choices.count - 1)
        for index in 0..<choices.count {
            if let path = route(blocked: blocked, from: start, to: choices[(offset + index) % choices.count]) { return path }
        }
        return [start]
    }

    /// Reconciles a resting place with a room that changed under it: furniture she was on may
    /// be gone, and furniture may now cover her cell. Returns `rest` unchanged when it still holds.
    public static func settled(_ rest: CatRest, items: [PhotoFurniture], catalog: FurnitureCatalog? = nil) -> CatRest {
        var rest = rest
        let ids = Set(items.map(\.instanceId))
        rest.lastActivityByItem = rest.lastActivityByItem.filter { ids.contains($0.key) }
        let blocked = GridRules.blockedCells(items)
        let owner = items.first { $0.instanceId == rest.itemId }
        // Any cell beside the piece counts: she may have got on from the side (`accessCell`).
        let beside = owner.map { $0.wall == nil
            && GridRules.adjacentCells(x: $0.x, z: $0.z, width: $0.width, depth: $0.depth, turn: $0.turn).contains(rest.cell) }
        if beside != true
            || !hasValidLanding(rest, owner: owner, catalog: catalog, blocked: blocked) {
            rest.moveToFloor()
        }
        let cell = rest.cell
        guard blocked.contains(cell) || !GridRules.inRoom(x: cell.x, z: cell.z) else { return rest }
        var best: (distance: Int, cell: GridCell)?
        for z in 0..<GridRules.size {
            for x in 0..<GridRules.size where !blocked.contains(GridCell(x: x, z: z)) {
                let distance = abs(x - cell.x) + abs(z - cell.z)
                if best == nil || distance < best!.distance { best = (distance, GridCell(x: x, z: z)) }
            }
        }
        rest.cell = best?.cell ?? GridRules.entrance
        rest.moveToFloor()
        return rest
    }

    private static func hasValidLanding(_ rest: CatRest, owner: PhotoFurniture?, catalog: FurnitureCatalog?,
                                        blocked: Set<GridCell>) -> Bool {
        guard let owner, let catalog else { return true }
        guard let model = catalog.model(id: owner.modelId),
              let site = model.interactionSites.first(where: { $0.id == (rest.siteId ?? "seat") }),
              let landing = CatLanding(item: owner, model: model, site: site) else { return false }
        return landing.legacy || landing.isAccessible(from: rest.cell, avoiding: blocked.subtracting(GridRules.blockedCells([owner])))
    }
}

extension CatRest {
    mutating func moveToFloor() {
        itemId = nil
        siteId = nil
        if action != .sit { action = .loaf }
    }
}
