import Foundation

public enum PlacementIssue: Error, Equatable, Sendable {
    /// Footprint leaves the room, or `turn` is not 0...3.
    case outOfBounds
    case overlaps(instanceId: String)
    case tooManyItems
    /// `(width, depth)` is not one of the model's catalog `sizes`.
    case sizeNotAllowed
    case unknownModel
    /// Covers the entrance cell, which stays free for Bella.
    case blocksEntrance
    /// Bella could not walk from the entrance to any free cell next to this piece, or the piece
    /// would take away the last such cell of one she can reach today.
    case unreachable
    /// A wall-mounted model placed on the floor, or a floor model placed on a wall.
    case wrongMount
    /// A round 7 floor piece would hide more than a third of a photo board from the room camera,
    /// or a board would hang where such a piece hides it. `instanceId` is the other piece.
    case hidesPhotoBoard(instanceId: String)
}

/// Layout rules mirrored from `src/domain/grid/world.ts`.
///
/// Footprint semantics (same as the web): `width`/`depth` are the catalog size before rotation.
/// An odd `turn` swaps them on the grid. The footprint is the rectangle whose top-left cell is
/// `(x, z)` and extends `+x` by the rotated width and `+z` by the rotated depth; rotation never
/// moves the anchor cell.
///
/// Like the web's `placementProblem`, a placement must leave the entrance cell free and Bella a
/// way to every piece, so furniture never walls her off. The web asks for the one cell in front
/// of each piece; here any free cell beside the piece that she can walk to from the entrance
/// will do (`CatRoutine.accessCell`), so users need not keep one particular cell clear. These
/// rules judge only the placement being made: a room saved before they existed still loads, and
/// pieces that were already cut off do not block later edits.
///
/// Wall-mounted pieces (`wall != nil`) are outside all of this: they cover no cell, block
/// nothing and need no access. They have to fit their wall, not overlap each other, and stay
/// in view: a tall round 7 floor piece may not stand where it hides most of a board
/// (`boardShareHidden`, `keepsClearOfBoards`), whichever of the two is placed second.
public enum GridRules {
    public static let size = 15
    public static let maxItems = 20
    /// Centre of the open front edge.
    public static let entrance = GridCell(x: size / 2, z: size - 1)

    /// `fitModel`: uniform scale and pre-scale offset that fit a catalog model into its footprint.
    /// nil for a degenerate model (zero-sized bounds).
    public static func fit(_ model: CatalogModel, width: Int, depth: Int) -> (scale: Double, offset: [Double])? {
        let min = model.bounds.min, max = model.bounds.max
        guard min.count == 3, max.count == 3, model.defaultSize.count == 2, max[0] > min[0], max[2] > min[2] else { return nil }
        func ratio(_ w: Int, _ d: Int) -> Double {
            Swift.min((Double(w) - 0.16) / (max[0] - min[0]), (Double(d) - 0.16) / (max[2] - min[2]))
        }
        let base = ratio(model.defaultSize[0], model.defaultSize[1])
        guard base > 0 else { return nil }
        // Never larger than at the default size: a bigger footprint centres the model in it
        // instead of growing it (a grown fountain bowl would swallow Bella's legs).
        let scale = Swift.min(base, 1.0 / 3.0) * Swift.min(1, ratio(width, depth) / base)
        return (scale, [-(min[0] + max[0]) / 2, -min[1], -(min[2] + max[2]) / 2])
    }

    /// Every floor cell covered by furniture. Wall-mounted pieces cover none.
    public static func blockedCells(_ items: [PhotoFurniture]) -> Set<GridCell> {
        var blocked = Set<GridCell>()
        for item in items where item.wall == nil {
            for cell in occupiedCells(x: item.x, z: item.z, width: item.width, depth: item.depth, turn: item.turn) {
                blocked.insert(GridCell(x: cell.x, z: cell.z))
            }
        }
        return blocked
    }

    /// Free cells Bella can walk to from `origin` (the entrance by default), `origin` included.
    /// Empty when `origin` itself is covered or outside the room.
    static func reachableCells(blocked: Set<GridCell>, from origin: GridCell = entrance) -> Set<GridCell> {
        guard inRoom(x: origin.x, z: origin.z), !blocked.contains(origin) else { return [] }
        var seen: Set<GridCell> = [origin], queue = [origin], index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            for next in CatRoutine.neighbours(of: current) where !blocked.contains(next) && seen.insert(next).inserted {
                queue.append(next)
            }
        }
        return seen
    }

    /// In-room cells orthogonally next to a floor footprint (not part of it), free or not.
    static func adjacentCells(x: Int, z: Int, width: Int, depth: Int, turn: Int) -> Set<GridCell> {
        let own = Set(occupiedCells(x: x, z: z, width: width, depth: depth, turn: turn).map { GridCell(x: $0.x, z: $0.z) })
        return Set(own.flatMap(CatRoutine.neighbours)).subtracting(own)
    }

    /// `[width, depth]` as laid out on the grid after `turn`.
    public static func rotatedSize(width: Int, depth: Int, turn: Int) -> (width: Int, depth: Int) {
        turn % 2 != 0 ? (depth, width) : (width, depth)
    }

    /// Cells covered by a footprint, row-major (x fastest), like the web `occupiedCells`.
    /// Returns `[]` for non-positive or oversized footprints.
    public static func occupiedCells(x: Int, z: Int, width: Int, depth: Int, turn: Int) -> [(x: Int, z: Int)] {
        let (w, d) = rotatedSize(width: width, depth: depth, turn: turn)
        guard w >= 1, d >= 1, w <= size, d <= size else { return [] }
        var cells: [(x: Int, z: Int)] = []
        cells.reserveCapacity(w * d)
        for i in 0..<(w * d) {
            cells.append((x: x + i % w, z: z + i / w))
        }
        return cells
    }

    public static func inRoom(x: Int, z: Int) -> Bool {
        x >= 0 && z >= 0 && x < size && z < size
    }

    /// All problems with placing `p` among `items` (an empty array means valid).
    /// `ignoring` excludes one existing instance (the one being moved).
    public static func validate(_ p: Placement, in items: [PhotoFurniture], catalog: FurnitureCatalog,
                                ignoring instanceId: String? = nil) -> [PlacementIssue] {
        var issues: [PlacementIssue] = []
        let everyOther = items.filter { $0.instanceId != instanceId }

        if let model = catalog.model(id: p.modelId) {
            if (model.mount == .wall) != (p.wall != nil) { issues.append(.wrongMount) }
            if !model.allows(width: p.width, depth: p.depth) { issues.append(.sizeNotAllowed) }
        } else {
            issues.append(.unknownModel)
        }
        // One limit for the whole room, wall pieces included.
        if everyOther.count >= maxItems { issues.append(.tooManyItems) }
        if let wall = p.wall {
            return issues + wallIssues(p, on: wall, others: everyOther, catalog: catalog)
        }
        // Wall pieces take no floor: they neither overlap a floor piece nor stand in Bella's way.
        let others = everyOther.filter { $0.wall == nil }

        guard (0...3).contains(p.turn) else {
            issues.append(.outOfBounds)
            return issues
        }
        let cells = occupiedCells(x: p.x, z: p.z, width: p.width, depth: p.depth, turn: p.turn)
        if cells.isEmpty || !cells.allSatisfy({ inRoom(x: $0.x, z: $0.z) }) {
            issues.append(.outOfBounds)
        }
        let mine = Set(cells.map { GridCell(x: $0.x, z: $0.z) })
        if mine.contains(entrance) { issues.append(.blocksEntrance) }
        var fits = !issues.contains(.outOfBounds) && !issues.contains(.blocksEntrance)
        for other in others {
            let theirs = occupiedCells(x: other.x, z: other.z, width: other.width, depth: other.depth, turn: other.turn)
            if theirs.contains(where: { mine.contains(GridCell(x: $0.x, z: $0.z)) }) {
                issues.append(.overlaps(instanceId: other.instanceId))
                fits = false
            }
        }
        if fits, cutsOffBella(p, cells: mine, others: others) { issues.append(.unreachable) }
        if let model = catalog.model(id: p.modelId), model.mount == .floor, keepsClearOfBoards(model) {
            for board in everyOther where board.wall != nil && boardShareHidden(board.placement, by: p, model: model) > maxBoardShareHidden {
                issues.append(.hidesPhotoBoard(instanceId: board.instanceId))
            }
        }
        return issues
    }

    // MARK: Photo boards stay in view

    /// The pieces judged against boards: round 7's household categories and soft furnishings, and
    /// every piece from round 10 on (lead, 2026-11-19; the cat wheel is the tall one). The pieces
    /// from before round 7 keep the behaviour they always had (owner: keep the existing product
    /// logic), so a cat tree may still stand flush under a board, whichever comes second. Add each
    /// new round's ids to `newPieces`.
    public static let round7SoftFurnishings: Set<String> = ["mv-toy-e", "mv-toy-f", "mv-bed-d", "mv-bed-e"]
    public static let newPieces: Set<String> = ["mv-sofa-d", "mv-hideout-d", "mv-chair-d", "mv-chair-e", "mv-toy-g", "mv-bed-f"]
    public static func keepsClearOfBoards(_ model: CatalogModel) -> Bool {
        !model.category.isRecognisedFromPhotos || round7SoftFurnishings.contains(model.id) || newPieces.contains(model.id)
    }

    /// More of a board than this hidden behind one floor piece refuses the placement.
    public static let maxBoardShareHidden = 1.0 / 3.0
    /// A board's face on its wall, in cells above the floor and inset from its span's ends:
    /// the same numbers as `WallGeometry` in the app (centre 2.0, height 1.15, inset 0.12).
    static let boardBottom = 2.0 - 1.15 / 2, boardTop = 2.0 + 1.15 / 2, boardInset = 0.12
    /// The room camera looks along −(14, 12.8, 17) (`RoomProjection.position − target` in the
    /// app). Per cell a ray travels towards a wall it moves this far along the wall (towards
    /// smaller offsets) and this far down.
    static func shadowSlope(_ wall: WallSide) -> (along: Double, down: Double) {
        wall == .back ? (14 / 17, 12.8 / 17) : (17 / 14, 12.8 / 14)
    }

    /// Share (0...1) of the board at `board` that the floor piece `piece` (of `model`) hides from
    /// the room camera. The piece counts as a solid box as tall as its fitted model.
    public static func boardShareHidden(_ board: Placement, by piece: Placement, model: CatalogModel) -> Double {
        guard let wall = board.wall, piece.wall == nil, let fit = fit(model, width: piece.width, depth: piece.depth),
              model.bounds.min.count == 3, model.bounds.max.count == 3 else { return 0 }
        let height = fit.scale * (model.bounds.max[1] - model.bounds.min[1])
        guard height > boardBottom else { return 0 }
        let (w, d) = rotatedSize(width: piece.width, depth: piece.depth, turn: piece.turn)
        // Along the wall (u) and out from it (depth), in cells.
        let (u0, u1, near, far) = wall == .back
            ? (Double(piece.x), Double(piece.x + w), Double(piece.z), Double(piece.z + d))
            : (Double(piece.z), Double(piece.z + d), Double(piece.x), Double(piece.x + w))
        let slope = shadowSlope(wall)
        let left = Double(board.x) + boardInset, right = Double(board.x + board.width) - boardInset
        let samples = 48
        var hidden = 0.0
        for i in 0..<samples {
            let u = left + (right - left) * (Double(i) + 0.5) / Double(samples)
            // The nearest slice of the piece whose shadow reaches this column is the tallest.
            let nearest = max(near, (u0 - u) / slope.along)
            guard nearest <= min(far, (u1 - u) / slope.along) else { continue }
            let top = min(height - slope.down * nearest, boardTop)
            hidden += max(0, top - boardBottom) / (boardTop - boardBottom)
        }
        return hidden / Double(samples)
    }

    /// A wall placement only has to lie on its wall and keep clear of the other pieces there.
    /// The two walls meet in the corner without overlapping.
    private static func wallIssues(_ p: Placement, on wall: WallSide, others: [PhotoFurniture],
                                   catalog: FurnitureCatalog) -> [PlacementIssue] {
        guard p.turn == 0, p.z == 0, p.depth == 1, p.width >= 1, p.x >= 0, p.x + p.width <= size else {
            return [.outOfBounds]
        }
        return others.filter { $0.wall == wall && $0.x < p.x + p.width && p.x < $0.x + $0.width }
            .map { .overlaps(instanceId: $0.instanceId) }
            + others.filter { piece in
                guard piece.wall == nil, let model = catalog.model(id: piece.modelId), keepsClearOfBoards(model) else { return false }
                return boardShareHidden(p, by: piece.placement, model: model) > maxBoardShareHidden
            }.map { .hidesPhotoBoard(instanceId: $0.instanceId) }
    }

    /// True when Bella cannot get to `p` from the entrance, or `p` takes away the last access
    /// of a piece she can get to without it. A room whose entrance is already covered is left
    /// alone. `others` are floor pieces only.
    private static func cutsOffBella(_ p: Placement, cells: Set<GridCell>, others: [PhotoFurniture]) -> Bool {
        let before = blockedCells(others)
        guard !before.contains(entrance) else { return false }
        let reachable = reachableCells(blocked: before.union(cells))
        if reachable.isDisjoint(with: adjacentCells(x: p.x, z: p.z, width: p.width, depth: p.depth, turn: p.turn)) { return true }
        let reachableBefore = reachableCells(blocked: before)
        return others.contains { other in
            let beside = adjacentCells(x: other.x, z: other.z, width: other.width, depth: other.depth, turn: other.turn)
            return !reachableBefore.isDisjoint(with: beside) && reachable.isDisjoint(with: beside)
        }
    }

    /// Uses the remembered spot first. A replacement spot must fit the piece at its current size.
    public static func placementForTransfer(_ remembered: Placement, in items: [PhotoFurniture],
                                            catalog: FurnitureCatalog) -> Placement? {
        if validate(remembered, in: items, catalog: catalog).isEmpty { return remembered }
        guard let model = catalog.model(id: remembered.modelId), model.allows(width: remembered.width, depth: remembered.depth),
              (model.mount == .wall) == (remembered.wall != nil), (0...3).contains(remembered.turn) else { return nil }
        return firstFreePlacement(like: remembered, in: items, catalog: catalog)
    }

    /// The valid placement of `model` at its default size closest to the room centre
    /// (turn 0 preferred on ties, then smaller z, then smaller x). nil when none fits.
    /// Placements whose front cell Bella can walk to come first, as before the access rule
    /// was relaxed: a suggestion should not make her climb on from the side when it need not.
    /// A wall model gets a wall placement instead: the back wall first (the one facing the
    /// viewer), then the left; on a wall the free span nearest its middle, the smaller offset
    /// on ties.
    public static func firstFreePlacement(for model: CatalogModel, in items: [PhotoFurniture],
                                          catalog: FurnitureCatalog) -> Placement? {
        let initial = Placement(modelId: model.id, x: 0, z: 0, width: model.defaultWidth, depth: model.defaultDepth,
                                wall: model.mount == .wall ? .back : nil)
        return firstFreePlacement(like: initial, in: items, catalog: catalog)
    }

    private static func firstFreePlacement(like initial: Placement, in items: [PhotoFurniture],
                                           catalog: FurnitureCatalog) -> Placement? {
        guard items.count < maxItems else { return nil }
        let width = initial.width, depth = initial.depth
        if let preferredWall = initial.wall {
            guard width <= size else { return nil }
            for wall in [preferredWall, preferredWall == .back ? .left : .back] {
                let free = (0...(size - width))
                    .map { Placement(modelId: initial.modelId, x: $0, z: 0, width: width, depth: depth, finish: initial.finish, wall: wall) }
                    .filter { validate($0, in: items, catalog: catalog).isEmpty }
                if let best = free.min(by: { abs(2 * $0.x + width - size) < abs(2 * $1.x + width - size) }) { return best }
            }
            return nil
        }
        // Check the nearest candidates first. Flood-filling the expanded grid for every
        // possible placement stalls the placement editor even when its centre is empty.
        guard width <= size, depth <= size else { return nil }
        var candidates: [(distance: Int, rotation: Int, placement: Placement)] = []
        for rotation in 0...1 {
            let turn = (initial.turn + rotation) % 4
            let (w, d) = rotatedSize(width: width, depth: depth, turn: turn)
            for z in 0...(size - d) {
                for x in 0...(size - w) {
                    let dx = 2 * x + w - size, dz = 2 * z + d - size
                    let placement = Placement(modelId: initial.modelId, x: x, z: z, width: width, depth: depth,
                                              turn: turn, finish: initial.finish)
                    candidates.append((dx * dx + dz * dz, rotation, placement))
                }
            }
        }
        candidates.sort { ($0.distance, $0.rotation, $0.placement.z, $0.placement.x)
                        < ($1.distance, $1.rotation, $1.placement.z, $1.placement.x) }
        let taken = blockedCells(items)
        var sideAccess: Placement?
        for (_, _, candidate) in candidates where validate(candidate, in: items, catalog: catalog).isEmpty {
            let own = occupiedCells(x: candidate.x, z: candidate.z, width: width, depth: depth, turn: candidate.turn)
            let blocked = taken.union(own.map { GridCell(x: $0.x, z: $0.z) })
            if reachableCells(blocked: blocked).contains(CatRoutine.approachCell(of: candidate)) { return candidate }
            if sideAccess == nil { sideAccess = candidate }
        }
        return sideAccess
    }
}
