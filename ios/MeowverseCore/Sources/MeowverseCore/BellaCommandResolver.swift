import Foundation

/// Turns a `BellaCommand` into what this room can do (docs/TALK_TO_BELLA.md). Pure, like
/// `CatRoutine`; reachability is checked from `.atEntrance`, exactly as the Interactions menu
/// checks it.
///
/// - Only pieces the menu lists count: wall pieces and decorative pieces are skipped.
/// - A site is usable when `CatRoutine.invitedTrip` finds a trip to it, the menu's own test.
/// - Of several usable sites the one with the shortest walk wins, then the smaller `instanceId`,
///   then the catalog's site order, so the same room always gives the same answer.
/// - `.noSuchFurniture`: no piece offers the action at all. `.blocked`: some piece does, but no
///   such site can be reached.
public enum BellaCommandResolver {
    public static func resolve(_ command: BellaCommand, items: [PhotoFurniture], catalog: FurnitureCatalog,
                               from rest: CatRest = .atEntrance) -> Result<BellaPlan, BellaRefusal> {
        switch command {
        case .visit(let action, let target?):
            // "相近动作": only when the named kind of piece lacks the action, one step at a time.
            for action in [action] + similar(to: action) {
                switch best(action, in: items, catalog: catalog, from: rest, where: { $0 == target }) {
                case .found(let plan): return .success(plan)
                case .blocked: return .failure(.blocked)
                case .none: continue
                }
            }
            return .failure(.noSuchFurniture(target))
        case .visit(.play, nil):
            // The model may say "visit, play, no piece": the same as the rules' "去玩".
            return resolve(.play(treat: false), items: items, catalog: catalog, from: rest)
        case .visit(let action, nil):
            switch best(action, in: items, catalog: catalog, from: rest, where: { _ in true }) {
            case .found(let plan): return .success(plan)
            case .blocked: return action == .eat ? toy(.treatBiscuit, items: items, catalog: catalog, from: rest) : .failure(.blocked)
            case .none: return action == .eat ? toy(.treatBiscuit, items: items, catalog: catalog, from: rest)
                : .failure(.noSuchFurniture(nil))
            }
        case .play(treat: true):
            return toy(.treatBiscuit, items: items, catalog: catalog, from: rest)
        case .play(treat: false):
            if case .found(let plan) = best(.play, in: items, catalog: catalog, from: rest, where: { _ in true }) {
                return .success(plan)
            }
            return toy(.toyMouse, items: items, catalog: catalog, from: rest)
        case .comeHere:
            return comeHereCell(items: items, catalog: catalog, from: rest).map { .success(.come(to: $0)) }
                ?? .failure(.blocked)
        case .unsupported:
            return .failure(.notUnderstood)
        }
    }

    /// "Here": the reachable floor cell nearest the front of the room, toward the camera.
    ///
    /// The room camera sits at +x, +z (`RoomProjection.position − target` = (14, 12.8, 17) in
    /// the app), so this is the free cell she can walk to whose centre is nearest that point
    /// on the floor plan: the front corner in an empty room. Ties: larger z, then larger x.
    /// Never the entrance (she would just stand in the doorway). nil when she can walk nowhere
    /// but the entrance.
    public static func comeHereCell(items: [PhotoFurniture], catalog: FurnitureCatalog,
                                    from rest: CatRest = .atEntrance) -> GridCell? {
        let start = CatRoutine.settled(rest, items: items, catalog: catalog).cell
        let reachable = GridRules.reachableCells(blocked: GridRules.blockedCells(items), from: start)
        func rank(_ cell: GridCell) -> (Double, Int, Int) {
            let point = CatRoutine.cellPoint(cell)
            let dx = cameraOnFloor.x - point.x, dz = cameraOnFloor.z - point.z
            return (dx * dx + dz * dz, -cell.z, -cell.x)
        }
        return reachable.subtracting([GridRules.entrance]).sorted { rank($0) < rank($1) }.first { cell in
            CatRoutine.floorTrip(items: items, from: rest, catalog: catalog, to: cell, action: .sit) != nil
        }
    }

    /// The room camera's position over the floor, in room space (cell units, centred).
    static let cameraOnFloor = (x: 14.0, z: 17.0)

    // MARK: Furniture

    /// The next action to try when a named piece does not offer one ("相近动作").
    static func similar(to action: CatAction) -> [CatAction] {
        switch action {
        case .loaf: [.sleep, .sit]
        case .sleep: [.loaf]
        case .sit: [.loaf]
        default: []
        }
    }

    /// Kinds of piece "去睡一会儿" and the like go to first when no piece is named, before
    /// any nearer one that also offers the action.
    static func preferred(for action: CatAction) -> [FurnitureCategory] {
        switch action {
        case .sleep: [.bed]
        case .scratch: [.scratcher, .catTree]
        case .hide: [.hideout]
        case .play: [.toy]
        case .dig: [.litterBox]
        case .drink, .eat: [.water]
        case .sit, .loaf: []
        }
    }

    private enum Search {
        case found(BellaPlan)
        /// Some piece offers the action; no site of it can be reached.
        case blocked
        /// No piece offers the action.
        case none
    }

    private static func best(_ action: CatAction, in items: [PhotoFurniture], catalog: FurnitureCatalog,
                             from rest: CatRest, where accepts: (FurnitureCategory) -> Bool) -> Search {
        let preference = preferred(for: action)
        var offered = false
        var winner: (rank: (Int, Int, String), plan: BellaPlan)?
        for item in items where item.wall == nil {
            guard let model = catalog.model(id: item.modelId), !model.isDecorative, accepts(model.category) else { continue }
            for site in model.interactionSites where site.actions.contains(action) {
                offered = true
                guard let trip = CatRoutine.invitedTrip(items: items, from: rest, catalog: catalog, itemId: item.instanceId,
                                                        siteId: site.id, action: action) else { continue }
                let rank = (preference.firstIndex(of: model.category) ?? preference.count, trip.path.count, item.instanceId)
                if winner == nil || rank < winner!.rank {
                    winner = (rank, .invite(itemId: item.instanceId, siteId: site.id, action: action))
                }
                break
            }
        }
        if let winner { return .found(winner.plan) }
        return offered ? .blocked : .none
    }

    // MARK: Toys and treats

    /// A toy or treat, as the menu's "放到空地" places it: only when there is a free cell she
    /// can get to (any but the entrance, `RoomPlaySession.placeNext`).
    private static func toy(_ item: CatPlayItem, items: [PhotoFurniture], catalog: FurnitureCatalog,
                            from rest: CatRest) -> Result<BellaPlan, BellaRefusal> {
        let blocked = GridRules.blockedCells(items)
        for z in 0..<GridRules.size {
            for x in 0..<GridRules.size {
                let cell = GridCell(x: x, z: z)
                guard cell != GridRules.entrance, !blocked.contains(cell) else { continue }
                let request = CatPlayRequest(item: item, cell: cell)
                if CatRoutine.playTrip(items: items, from: rest, catalog: catalog, request: request) != nil {
                    return .success(.play(item))
                }
            }
        }
        return .failure(.blocked)
    }
}
