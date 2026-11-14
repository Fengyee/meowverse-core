import Foundation
import Testing
@testable import MeowverseCore

private func item(_ id: String, _ model: String, x: Int, z: Int, width: Int, depth: Int, turn: Int = 0) -> PhotoFurniture {
    PhotoFurniture(instanceId: id, modelId: model, x: x, z: z, width: width, depth: depth, turn: turn,
                   finish: .original, displayName: id, sources: [.manual(photoId: "p")], tags: [], revision: 1)
}

private func chair(_ id: String = "a", x: Int = 1, z: Int = 1, turn: Int = 0) -> PhotoFurniture {
    item(id, "kenney-chair", x: x, z: z, width: 2, depth: 2, turn: turn)
}

private func cells(of items: [PhotoFurniture]) -> Set<GridCell> {
    Set(items.flatMap { GridRules.occupiedCells(x: $0.x, z: $0.z, width: $0.width, depth: $0.depth, turn: $0.turn) }
        .map { GridCell(x: $0.x, z: $0.z) })
}

/// Ports of tests/unit/grid-world.test.ts (route, approach, seat).
@Suite struct CatGeometryTests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try TestSupport.catalog() }

    @Test func approachCellFollowsTheTurn() {
        // grid-world.test.ts: bench 3x1, turn 1 at (2,3) is approached from [3,4].
        #expect(CatRoutine.approachCell(of: item("b", "kenney-bench", x: 2, z: 3, width: 3, depth: 1, turn: 1)) == GridCell(x: 3, z: 4))
        #expect(CatRoutine.approachCell(of: chair(turn: 0)) == GridCell(x: 2, z: 3))
        #expect(CatRoutine.approachCell(of: chair(turn: 1)) == GridCell(x: 3, z: 2))
        #expect(CatRoutine.approachCell(of: chair(turn: 2)) == GridCell(x: 2, z: 0))
        #expect(CatRoutine.approachCell(of: chair(turn: 3)) == GridCell(x: 0, z: 2))
        #expect(CatRoutine.approachCell(of: Placement(modelId: "kenney-chair", x: 1, z: 1, width: 2, depth: 2)) == GridCell(x: 2, z: 3))
    }

    @Test func cellPointIsTheCellCentre() {
        #expect(CatRoutine.cellPoint(GridRules.entrance) == GridPoint(x: 0, y: 0, z: 7))
        #expect(CatRoutine.cellPoint(GridCell(x: 0, z: 0)) == GridPoint(x: -7, y: 0, z: -7))
    }

    @Test func routeAvoidsFurnitureAndMovesOneCellAtATime() throws {
        let items = [item("sofa", "kenney-loungeSofa", x: 3, z: 4, width: 3, depth: 2)]
        let path = try #require(CatRoutine.route(items: items, from: GridRules.entrance, to: GridCell(x: 4, z: 2)))
        #expect(path.first == GridRules.entrance)
        #expect(path.last == GridCell(x: 4, z: 2))
        let blocked = cells(of: items)
        for (index, cell) in path.enumerated() {
            #expect(!blocked.contains(cell))
            if index > 0 { #expect(abs(cell.x - path[index - 1].x) + abs(cell.z - path[index - 1].z) == 1) }
        }
        // Shortest: 12 rows up and 3 columns across, around the sofa.
        #expect(path.count == 16)
        #expect(CatRoutine.route(items: items, from: GridRules.entrance, to: GridCell(x: 4, z: 4)) == nil)
        #expect(CatRoutine.route(items: items, from: GridCell(x: -1, z: 2), to: GridCell(x: 4, z: 2)) == nil)
        #expect(CatRoutine.route(items: items, from: GridRules.entrance, to: GridCell(x: 4, z: 15)) == nil)
        #expect(CatRoutine.route(items: [], from: GridRules.entrance, to: GridRules.entrance) == [GridRules.entrance])
    }

    @Test func routeIsNilWhenWalledOff() {
        // A chair in the corner behind another chair: its approach cell is taken.
        let items = [chair("a", x: 0, z: 0), chair("b", x: 0, z: 2), chair("c", x: 2, z: 0, turn: 1)]
        #expect(CatRoutine.route(items: items, from: GridRules.entrance, to: GridCell(x: 1, z: 2)) == nil)
    }

    @Test func seatIsInFrontOfTheCentreAndTurnsWithTheFurniture() throws {
        let centre = (x: 1 + 1 - 7.5, z: 1 + 1 - 7.5)
        let seat = try #require(CatRoutine.seatPoint(of: chair(), catalog: catalog))
        #expect(seat.z > centre.z)
        #expect(abs(seat.x - centre.x) < 1e-9)
        // fitModel: scale 1/3, seat height 2.4 / 3.
        #expect(abs(seat.y - 0.8) < 1e-6)
        #expect(abs(seat.z - (centre.z + 0.16 / 3)) < 1e-6)
        let turned = try #require(CatRoutine.seatPoint(of: chair(turn: 1), catalog: catalog))
        #expect(turned.x > centre.x)
        #expect(abs(turned.z - centre.z) < 1e-9)
        #expect(CatRoutine.seatPoint(of: item("x", "nope", x: 0, z: 0, width: 1, depth: 1), catalog: catalog) == nil)
    }

    // grid-world.test.ts: seats of chairs, sofas and beds are at comparable heights.
    @Test func seatHeightsAreComparable() throws {
        func surface(_ model: String, _ w: Int, _ d: Int) throws -> Double {
            try #require(CatRoutine.seatPoint(of: item("s", model, x: 1, z: 1, width: w, depth: d), catalog: catalog)).y
        }
        let sofa = try surface("kenney-loungeSofa", 3, 2), bed = try surface("kenney-bedSingle", 2, 4)
        for model in catalog.models(in: .chair) {
            let height = try surface(model.id, 2, 2)
            #expect(height / sofa > 0.8 && height / sofa < 1.3)
            #expect(height / bed < 1.2)
            // The web grew the model with its footprint; iOS caps the scale at the default size's
            // (GridRules.fit), so a bigger footprint never lowers the seat but need not raise it.
            #expect(try surface(model.id, 3, 3) >= height - 1e-9)
        }
    }
}

/// Ports of tests/unit/cat-routine.test.ts, plus the iOS additions.
@Suite struct CatRoutineTests {
    let catalog: FurnitureCatalog
    let bed = item("bed", "kenney-bedSingle", x: 0, z: 0, width: 2, depth: 4)
    let chairItem = item("chair", "kenney-chair", x: 6, z: 0, width: 2, depth: 2)
    let sofa = item("sofa", "kenney-loungeSofa", x: 3, z: 4, width: 3, depth: 2)
    init() throws { catalog = try TestSupport.catalog() }

    @Test func walksBetweenFloorCellsInAnEmptyRoom() {
        let trip = CatRoutine.nextTrip(items: [], from: .atEntrance, sample: 0.6, catalog: catalog)
        #expect(trip.points.first == CatRoutine.cellPoint(GridRules.entrance))
        #expect(trip.points.last == CatRoutine.cellPoint(trip.end.cell))
        #expect(trip.end.cell != GridRules.entrance)
        #expect(trip.end.itemId == nil)
        #expect(trip.end.action == .sit)
        #expect(trip.leaving == nil && trip.seat == nil)
        for index in 1..<trip.points.count {
            let p = trip.points[index], q = trip.points[index - 1]
            #expect(p.y == 0)
            #expect(abs(p.x - q.x) + abs(p.z - q.z) == 1)
        }
        #expect(CatRoutine.nextTrip(items: [], from: .atEntrance, sample: 0.2, catalog: catalog).end.action == .loaf)
        // Same sample, same trip.
        #expect(CatRoutine.nextTrip(items: [], from: .atEntrance, sample: 0.6, catalog: catalog) == trip)
    }

    @Test func visitsFurnitureInTurnAndRestsByCategory() throws {
        let items = [bed, chairItem]
        let first = CatRoutine.nextTrip(items: items, from: .atEntrance, sample: 0, catalog: catalog)
        #expect(first.end.action == .sleep)
        #expect(first.end.itemId == "bed")
        #expect(first.end.cell == CatRoutine.approachCell(of: bed))
        #expect(first.points.last == CatRoutine.seatPoint(of: bed, catalog: catalog))
        #expect(first.seat == CatRoutine.seatPoint(of: bed, catalog: catalog))
        #expect(first.rotation == 0)
        // Up to the peak above the foot, across, down onto the seat.
        #expect(first.points.count == first.path.count + 3)

        let walk = CatRoutine.nextTrip(items: items, from: first.end, sample: 0, catalog: catalog)
        #expect(walk.points.first == first.points.last)
        #expect(walk.leaving == first.seat)
        #expect(walk.end.itemId == nil)
        #expect(walk.end.lastItemId == "bed")
        #expect(!cells(of: items).contains(walk.end.cell))

        let second = CatRoutine.nextTrip(items: items, from: walk.end, sample: 0.9, catalog: catalog)
        #expect(second.end.itemId == "chair")
        #expect(second.end.action == .sit)

        let back = CatRoutine.nextTrip(items: items, from: CatRest(cell: second.end.cell, itemId: nil, lastItemId: "chair", action: .sit),
                                       sample: 0.5, catalog: catalog)
        #expect(back.end.itemId == "bed")
    }

    @Test func sofasAndBenchesAreForLoafing() {
        let bench = item("bench", "kenney-bench", x: 0, z: 0, width: 3, depth: 1)
        #expect(CatRoutine.nextTrip(items: [sofa], from: .atEntrance, sample: 0, catalog: catalog).end.action == .loaf)
        #expect(CatRoutine.nextTrip(items: [bench], from: .atEntrance, sample: 0, catalog: catalog).end.action == .loaf)
        let turned = item("sofa", "kenney-loungeSofa", x: 0, z: 3, width: 3, depth: 2, turn: 1)
        #expect(CatRoutine.nextTrip(items: [turned], from: .atEntrance, sample: 0, catalog: catalog).rotation == Double.pi / 2)
    }

    @Test func firstVisitIsPickedBySample() {
        let items = [bed, chairItem]
        #expect(CatRoutine.nextTrip(items: items, from: .atEntrance, sample: 0.4, catalog: catalog).end.itemId == "bed")
        #expect(CatRoutine.nextTrip(items: items, from: .atEntrance, sample: 0.6, catalog: catalog).end.itemId == "chair")
        #expect(CatRoutine.nextTrip(items: items, from: .atEntrance, sample: 1, catalog: catalog).end.itemId == "chair")
    }

    @Test func aPreferredPieceIsVisitedNextEvenFromAnotherPiece() throws {
        let items = [bed, chairItem, sofa]
        // From the floor: the web order would pick the bed; the new sofa wins.
        let direct = CatRoutine.nextTrip(items: items, from: .atEntrance, sample: 0, catalog: catalog, preferring: "sofa")
        #expect(direct.end.itemId == "sofa")
        #expect(direct.end.lastItemId == "sofa")
        // From the bed: hop down, walk, hop up, without a floor rest in between.
        let onBed = CatRest(cell: CatRoutine.approachCell(of: bed), itemId: "bed", lastItemId: "bed", action: .sleep)
        let trip = CatRoutine.nextTrip(items: items, from: onBed, sample: 0, catalog: catalog, preferring: "sofa")
        #expect(trip.end.itemId == "sofa")
        #expect(trip.leaving == CatRoutine.seatPoint(of: bed, catalog: catalog))
        #expect(trip.path.first == onBed.cell)
        #expect(trip.path.last == CatRoutine.approachCell(of: sofa))
        #expect(trip.points.first == trip.leaving)
        #expect(trip.points.last == trip.seat)
        // Already on it, or gone: the ordinary routine applies.
        #expect(CatRoutine.nextTrip(items: items, from: onBed, sample: 0, catalog: catalog, preferring: "bed").end.itemId == nil)
        #expect(CatRoutine.nextTrip(items: items, from: .atEntrance, sample: 0, catalog: catalog, preferring: "gone").end.itemId == "bed")
    }

    @Test func unreachableFurnitureIsSkippedInsteadOfStallingTheRoutine() {
        // Legacy room: "a" sits in the corner with another chair on its approach cell.
        let items = [chair("a", x: 0, z: 0), chair("b", x: 0, z: 2), chair("c", x: 2, z: 0, turn: 1)]
        let trip = CatRoutine.nextTrip(items: items, from: .atEntrance, sample: 0, catalog: catalog)
        #expect(trip.end.itemId == "b")
        // Asked to go to the walled-in one, and nothing else to visit: she still wanders the floor.
        let onB = CatRest(cell: GridCell(x: 1, z: 4), itemId: "b", lastItemId: "b", action: .sit)
        let stuck = CatRoutine.nextTrip(items: items, from: onB, sample: 0.3, catalog: catalog, preferring: "a")
        #expect(stuck.end.itemId == nil)
        #expect(stuck.path.count > 1)
        // A stool facing the wall was unreachable under the front-cell rule; now she gets on
        // from the side (the two side cells tie, the smaller z wins).
        let facingWall = [item("s", "kenney-stoolBar", x: 14, z: 14, width: 1, depth: 1)]
        let side = CatRoutine.nextTrip(items: facingWall, from: .atEntrance, sample: 0.3, catalog: catalog, preferring: "s")
        #expect(side.end.itemId == "s")
        #expect(side.end.cell == GridCell(x: 14, z: 13) && side.path.last == side.end.cell)
    }

    @Test func aBoxedInCatStaysPut() {
        // Stools on every neighbour of (0,0): no floor cell within reach.
        let stools = [item("s1", "kenney-stoolBar", x: 1, z: 0, width: 1, depth: 1), item("s2", "kenney-stoolBar", x: 0, z: 1, width: 1, depth: 1)]
        let rest = CatRest(cell: GridCell(x: 0, z: 0), itemId: nil, lastItemId: nil, action: .sit)
        let trip = CatRoutine.nextTrip(items: stools, from: rest, sample: 0.7, catalog: catalog)
        #expect(trip.path == [GridCell(x: 0, z: 0)])
        #expect(trip.end.cell == GridCell(x: 0, z: 0))
    }

    @Test func settlingMovesHerOffFurnitureThatAppearedUnderHer() {
        let onSofa = CatRest(cell: CatRoutine.approachCell(of: sofa), itemId: "sofa", lastItemId: "sofa", action: .loaf)
        // Unchanged room: nothing to do.
        #expect(CatRoutine.settled(onSofa, items: [sofa]) == onSofa)
        // Sofa removed: she is on the floor where she got on.
        let removed = CatRoutine.settled(onSofa, items: [])
        #expect(removed == CatRest(cell: onSofa.cell, itemId: nil, lastItemId: "sofa", action: .loaf))
        // A sleeping cat whose bed is gone does not sleep on the floor.
        let onBed = CatRest(cell: CatRoutine.approachCell(of: bed), itemId: "bed", lastItemId: "bed", action: .sleep)
        #expect(CatRoutine.settled(onBed, items: []).action == .loaf)
        // Furniture now covers her floor cell: nearest free cell.
        let floor = CatRest(cell: GridCell(x: 4, z: 4), itemId: nil, lastItemId: nil, action: .sit)
        let moved = CatRoutine.settled(floor, items: [sofa])
        #expect(!cells(of: [sofa]).contains(moved.cell))
        #expect(abs(moved.cell.x - 4) + abs(moved.cell.z - 4) == 1)
        // Legacy room with the entrance covered.
        let onEntrance = item("t", "kenney-table", x: 6, z: 13, width: 3, depth: 2)
        let start = CatRoutine.settled(.atEntrance, items: [onEntrance])
        #expect(!cells(of: [onEntrance]).contains(start.cell))
    }
}

/// Entrance and reachability rules from `placementProblem` in src/domain/grid/world.ts.
@Suite struct CatAccessRulesTests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try TestSupport.catalog() }

    func placement(x: Int = 1, z: Int = 1, width: Int = 2, depth: Int = 2, turn: Int = 0, model: String = "kenney-chair") -> Placement {
        Placement(modelId: model, x: x, z: z, width: width, depth: depth, turn: turn, finish: .original)
    }

    // A chair on the last row can cover the entrance.
    @Test func entranceCellStaysFree() {
        #expect(GridRules.validate(placement(x: 7, z: 13), in: [], catalog: catalog) == [.blocksEntrance])
        #expect(GridRules.validate(placement(x: 6, z: 13), in: [], catalog: catalog).contains(.blocksEntrance))
        #expect(GridRules.validate(placement(x: 5, z: 7), in: [], catalog: catalog).isEmpty)
    }

    // Schema 6 relaxes the web rule: any free cell beside the piece will do, not only the front one.
    @Test func aPieceNeedsAReachableCellBesideIt() {
        // Front against the bottom edge, or taken by another piece: the old rule said
        // `.unreachable`; the sides are free, so both are fine now.
        #expect(GridRules.validate(placement(x: 13, z: 13), in: [], catalog: catalog).isEmpty)
        #expect(GridRules.validate(placement(x: 13, z: 13, turn: 2), in: [], catalog: catalog).isEmpty)
        #expect(GridRules.validate(placement(x: 1, z: 1), in: [chair("b", x: 1, z: 3)], catalog: catalog).isEmpty)
        // Old and new rule agree: a stool in the corner behind two others has no free cell beside it.
        let corner = [item("s1", "kenney-stoolBar", x: 1, z: 0, width: 1, depth: 1), item("s2", "kenney-stoolBar", x: 0, z: 1, width: 1, depth: 1)]
        #expect(GridRules.validate(placement(x: 0, z: 0, width: 1, depth: 1, model: "kenney-stoolBar"), in: corner, catalog: catalog) == [.unreachable])
        // A free cell beside it that Bella cannot walk to does not count.
        // Here (0,0) stays free but is sealed in by the new stool itself.
        let pocket = [(2, 0), (1, 1), (0, 1)].map { item("p\($0.0)\($0.1)", "kenney-stoolBar", x: $0.0, z: $0.1, width: 1, depth: 1) }
        #expect(GridRules.validate(placement(x: 1, z: 0, width: 1, depth: 1, model: "kenney-stoolBar"), in: pocket, catalog: catalog) == [.unreachable])
    }

    // grid-world.test.ts: "does not trap existing furniture behind a new obstacle".
    @Test func aNewPieceMustNotTrapAnExistingOne() {
        let old = chair("a", x: 0, z: 0)
        // Covers the front cell of "a" only: its right side stays open (the old rule refused this).
        #expect(GridRules.validate(placement(x: 0, z: 2), in: [old], catalog: catalog).isEmpty)
        // With the front already taken, closing the right side takes away its last access.
        let frontTaken = [old, chair("b", x: 0, z: 2)]
        #expect(GridRules.validate(placement(x: 2, z: 0), in: frontTaken, catalog: catalog) == [.unreachable])
        #expect(GridRules.validate(placement(x: 3, z: 2), in: [old], catalog: catalog).isEmpty)
    }

    @Test func movingAPieceIgnoresItsOwnCells() {
        #expect(GridRules.validate(placement(x: 2), in: [chair()], catalog: catalog, ignoring: "a").isEmpty)
    }

    @Test func overlapAndBoundsAreReportedWithoutAReachabilityVerdict() {
        #expect(GridRules.validate(placement(x: 14), in: [], catalog: catalog) == [.outOfBounds])
        #expect(GridRules.validate(placement(), in: [chair()], catalog: catalog) == [.overlaps(instanceId: "a")])
    }

    @Test func roomsSavedBeforeTheseRulesStayEditable() {
        // "a" was already trapped by "b": that is not the new piece's fault.
        let legacy = [chair("a", x: 0, z: 0), chair("b", x: 0, z: 2)]
        #expect(GridRules.validate(placement(x: 6, z: 4), in: legacy, catalog: catalog).isEmpty)
        // ...and "b" can be moved away, or stay where it is.
        #expect(GridRules.validate(placement(x: 3, z: 2), in: legacy, catalog: catalog, ignoring: "b").isEmpty)
        // A piece already on the entrance: nothing can be reached from there, so only the
        // direct rules apply until it is moved.
        let onEntrance = [item("t", "kenney-table", x: 6, z: 13, width: 3, depth: 2)]
        #expect(GridRules.validate(placement(x: 6, z: 4), in: onEntrance, catalog: catalog).isEmpty)
        #expect(GridRules.validate(placement(x: 3, z: 5, width: 3, depth: 2, model: "kenney-table"), in: onEntrance, catalog: catalog, ignoring: "t").isEmpty)
        #expect(GridRules.validate(placement(x: 7, z: 13), in: onEntrance, catalog: catalog, ignoring: "t") == [.blocksEntrance])
    }

    @Test func suggestedPlacementsAreAlwaysReachable() throws {
        var items: [PhotoFurniture] = []
        for (index, model) in catalog.models.enumerated() {
            guard let p = GridRules.firstFreePlacement(for: model, in: items, catalog: catalog) else { continue }
            #expect(GridRules.validate(p, in: items, catalog: catalog).isEmpty)
            items.append(PhotoFurniture(instanceId: "i\(index)", modelId: p.modelId, x: p.x, z: p.z, width: p.width, depth: p.depth,
                                        turn: p.turn, finish: .original, displayName: model.label, sources: [.manual(photoId: "p")], tags: [], revision: 1))
        }
        #expect(items.count >= 6)
        #expect(!cells(of: items).contains(GridRules.entrance))
        for item in items {
            let access = try #require(CatRoutine.accessCell(of: item, in: items))
            #expect(CatRoutine.route(items: items, from: GridRules.entrance, to: access) != nil)
        }
    }
}

@Suite struct CatScenarioTests {
    @Test func sofaFacingTheBackWallIsVisitedFromTheChair() throws {
        let catalog = try TestSupport.catalog()
        let chair = item("chair", "kenney-chair", x: 4, z: 4, width: 2, depth: 2)
        let sofa = item("sofa", "kenney-loungeSofa", x: 6, z: 8, width: 3, depth: 2, turn: 2)
        let onChair = CatRest(cell: CatRoutine.approachCell(of: chair), itemId: "chair", lastItemId: "chair", action: .sit)
        let trip = CatRoutine.nextTrip(items: [chair, sofa], from: onChair, sample: 0.3, catalog: catalog, preferring: "sofa")
        #expect(trip.end.itemId == "sofa")
        #expect(trip.end.cell == GridCell(x: 7, z: 7))
        let fromFloor = CatRest(cell: GridCell(x: 8, z: 5), itemId: nil, lastItemId: "chair", action: .loaf)
        #expect(CatRoutine.nextTrip(items: [chair, sofa], from: fromFloor, sample: 0.3, catalog: catalog).end.itemId == "sofa")
    }
}
