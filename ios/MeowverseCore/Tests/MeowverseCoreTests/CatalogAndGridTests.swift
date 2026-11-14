import Foundation
import Testing
@testable import MeowverseCore

@Suite struct CatalogTests {
    @Test func decodesRealCatalog() throws {
        let catalog = try TestSupport.catalog()
        #expect(catalog.models.count == 14)
        let chair = try #require(catalog.model(id: "kenney-chair"))
        #expect(chair.category == .chair)
        #expect(chair.defaultSize == [2, 2])
        #expect(chair.sizes == [[2, 2], [3, 3]])
        #expect(chair.path == "catalog/kenney/chair.json")
        #expect(chair.bytes == 24232)
        #expect(chair.triangles == 168)
        #expect(chair.bounds.min == [-2, 0, 0])
        #expect(abs(chair.orientationY - Double.pi) < 1e-9)
        #expect(chair.seat.position.count == 3)
        #expect(chair.seat.facing == 0)
        for category in [FurnitureCategory.table, .bed, .chair, .sofa, .bench, .stool] {
            #expect(!catalog.models(in: category).isEmpty, "category \(category) has models")
        }
        #expect(catalog.models(in: .table).map(\.id) == ["kenney-table", "kenney-tableRound", "kenney-tableCoffee"])
        #expect(catalog.model(id: "https://bad.test/a.glb") == nil)
    }

    @Test func bundledCatalogPreservesWebModelsAndOffersEveryNativeCategory() throws {
        let catalog = try FurnitureCatalog.bundled()
        for original in try TestSupport.catalog().models {
            // A web model either survives as is or, when aliased, opens as its replacement.
            if catalog.isLegacyAlias(original.id) {
                #expect(catalog.model(id: original.id)?.category == original.category)
            } else {
                #expect(catalog.model(id: original.id) == original)
            }
        }
        for category in FurnitureCategory.allCases {
            #expect(!catalog.models(in: category).isEmpty)
        }
        // Aliased legacy models are reached through their replacement, which is checked here.
        for model in catalog.models where model.sites != nil && !catalog.isLegacyAlias(model.id) {
            let item = PhotoFurniture(instanceId: "piece", modelId: model.id, x: 3, z: 3,
                                      width: model.defaultWidth, depth: model.defaultDepth, turn: 0,
                                      finish: .original, displayName: model.label, sources: [.manual(photoId: "p")],
                                      tags: [], revision: 1)
            for site in model.interactionSites {
                for action in site.actions {
                    let trip = CatRoutine.invitedTrip(items: [item], from: .atEntrance, catalog: catalog,
                                                     itemId: item.instanceId, siteId: site.id, action: action)
                    #expect(trip?.end.siteId == site.id && trip?.end.action == action, "\(model.id)/\(site.id)")
                }
            }
        }
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) { try FurnitureCatalog(data: Data("{}".utf8)) }
    }
}

@Suite struct GridRulesTests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try TestSupport.catalog() }

    func chair(_ id: String = "a", x: Int = 1, z: Int = 1) -> PhotoFurniture {
        PhotoFurniture(instanceId: id, modelId: "kenney-chair", x: x, z: z, width: 2, depth: 2, turn: 0,
                       finish: .original, displayName: "c", sources: [.manual(photoId: "p")], tags: [], revision: 1)
    }

    func placement(x: Int = 1, z: Int = 1, width: Int = 2, depth: Int = 2, turn: Int = 0, model: String = "kenney-chair") -> Placement {
        Placement(modelId: model, x: x, z: z, width: width, depth: depth, turn: turn, finish: .original)
    }

    // grid-world.test.ts: bench 3x1, turn 1 at (2,3) -> [[2,3],[2,4],[2,5]]
    @Test func rotatedBenchCellsMatchWeb() {
        let cells = GridRules.occupiedCells(x: 2, z: 3, width: 3, depth: 1, turn: 1)
        #expect(cells.map { [$0.x, $0.z] } == [[2, 3], [2, 4], [2, 5]])
        let flat = GridRules.occupiedCells(x: 2, z: 3, width: 3, depth: 1, turn: 2)
        #expect(flat.map { [$0.x, $0.z] } == [[2, 3], [3, 3], [4, 3]])
        #expect(GridRules.occupiedCells(x: 0, z: 0, width: 0, depth: 1, turn: 0).isEmpty)
    }

    @Test func validPlacementHasNoIssues() {
        #expect(GridRules.validate(placement(), in: [], catalog: catalog).isEmpty)
    }

    // The old edge is now usable, and a rotated piece must fit the new edge.
    @Test func boundsAndTurns() {
        #expect(GridRules.validate(placement(x: 14), in: [], catalog: catalog) == [.outOfBounds])
        #expect(GridRules.validate(placement(x: -1), in: [], catalog: catalog) == [.outOfBounds])
        // Its front faces the room edge; since schema 6 Bella may get on from the side instead.
        #expect(GridRules.validate(placement(x: 13, z: 13), in: [], catalog: catalog).isEmpty)
        #expect(GridRules.validate(placement(x: 9, z: 7), in: [], catalog: catalog).isEmpty)
        #expect(GridRules.validate(placement(turn: 4), in: [], catalog: catalog) == [.outOfBounds])
        // Bench 3x1 at x=14: fits only when turned (1 wide on x, 3 deep on z).
        let bench = placement(x: 14, z: 0, width: 3, depth: 1, turn: 0, model: "kenney-bench")
        #expect(GridRules.validate(bench, in: [], catalog: catalog) == [.outOfBounds])
        var turned = bench; turned.turn = 3 // front towards the room, so Bella can get on
        #expect(GridRules.validate(turned, in: [], catalog: catalog).isEmpty)
        turned.z = 13
        #expect(GridRules.validate(turned, in: [], catalog: catalog) == [.outOfBounds])
    }

    // grid-world.test.ts: overlapping chairs; width 9 / unknown model rejected.
    @Test func overlapSizesAndModels() {
        #expect(GridRules.validate(placement(), in: [chair()], catalog: catalog) == [.overlaps(instanceId: "a")])
        #expect(GridRules.validate(placement(x: 2, z: 2), in: [chair()], catalog: catalog) == [.overlaps(instanceId: "a")])
        #expect(GridRules.validate(placement(x: 3), in: [chair()], catalog: catalog).isEmpty)
        #expect(GridRules.validate(placement(), in: [chair()], catalog: catalog, ignoring: "a").isEmpty)
        #expect(GridRules.validate(placement(width: 9), in: [], catalog: catalog).contains(.sizeNotAllowed))
        #expect(GridRules.validate(placement(width: 2, depth: 3), in: [], catalog: catalog) == [.sizeNotAllowed])
        #expect(GridRules.validate(placement(width: 3, depth: 3), in: [], catalog: catalog).isEmpty)
        #expect(GridRules.validate(placement(model: "https://bad.test/a.glb"), in: [], catalog: catalog) == [.unknownModel])
    }

    @Test func maxTwentyItems() {
        // 20 1x1 stools fill two rows.
        let stools = (0..<20).map { i in
            PhotoFurniture(instanceId: "s\(i)", modelId: "kenney-stoolBar", x: i % 10, z: i / 10, width: 1, depth: 1,
                           turn: 0, finish: .original, displayName: "s", sources: [.manual(photoId: "p")], tags: [], revision: 1)
        }
        let p = placement(x: 5, z: 5, width: 1, depth: 1, model: "kenney-stoolBar")
        #expect(GridRules.validate(p, in: Array(stools.prefix(19)), catalog: catalog).isEmpty)
        #expect(GridRules.validate(p, in: stools, catalog: catalog) == [.tooManyItems])
        // Moving an existing one is still allowed.
        var move = p; move.modelId = "kenney-stoolBar"
        #expect(GridRules.validate(move, in: stools, catalog: catalog, ignoring: "s0").isEmpty)
        let stool = catalog.model(id: "kenney-stoolBar")!
        #expect(GridRules.firstFreePlacement(for: stool, in: stools, catalog: catalog) == nil)
    }

    @Test func firstFreePlacementPrefersCentre() throws {
        let model = try #require(catalog.model(id: "kenney-chair"))
        let first = try #require(GridRules.firstFreePlacement(for: model, in: [], catalog: catalog))
        #expect(first == Placement(modelId: "kenney-chair", x: 6, z: 6, width: 2, depth: 2, turn: 0, finish: .original))
        let next = try #require(GridRules.firstFreePlacement(for: model, in: [chair(x: 6, z: 6)], catalog: catalog))
        #expect(GridRules.validate(next, in: [chair(x: 6, z: 6)], catalog: catalog).isEmpty)
        let bed = try #require(catalog.model(id: "kenney-bedDouble"))
        let bedPlacement = try #require(GridRules.firstFreePlacement(for: bed, in: [], catalog: catalog))
        #expect([bedPlacement.width, bedPlacement.depth] == bed.defaultSize)
        #expect(GridRules.validate(bedPlacement, in: [], catalog: catalog).isEmpty)
    }

    @Test func movingAFloorPieceKeepsItsRememberedSpotOrFindsOneAtItsOwnSize() throws {
        var armchair = chair(x: 1, z: 1)
        armchair.width = 3
        armchair.depth = 3
        armchair.turn = 2
        armchair.finish = .sage
        #expect(GridRules.placementForTransfer(armchair.placement, in: [], catalog: catalog) == armchair.placement)
        let occupied = [chair("other", x: 1, z: 1)]
        let moved = try #require(GridRules.placementForTransfer(armchair.placement, in: occupied, catalog: catalog))
        #expect(moved.width == 3 && moved.depth == 3 && moved.finish == .sage && moved.turn == 2)
        #expect(GridRules.validate(moved, in: occupied, catalog: catalog).isEmpty)
    }

    @Test func movingALargePhotoBoardNeedsAFullWidthOpening() throws {
        let catalog = try FurnitureCatalog.bundled()
        let model = try #require(catalog.model(id: "wall-photo-board"))
        let board = Placement(modelId: model.id, x: 0, z: 0, width: 3, depth: 1, finish: .lavender, wall: .left)
        func occupied(_ wall: WallSide, at x: Int) -> PhotoFurniture {
            PhotoFurniture(instanceId: "\(wall.rawValue)-\(x)", modelId: model.id, x: x, z: 0, width: 2, depth: 1,
                           turn: 0, wall: wall, finish: .original, displayName: "板", sources: [], tags: [], revision: 1)
        }
        let obstacle = occupied(.left, at: 0)
        let moved = try #require(GridRules.placementForTransfer(board, in: [obstacle], catalog: catalog))
        #expect(moved.width == 3 && moved.depth == 1 && moved.finish == .lavender && moved.wall == .left)
        #expect(GridRules.validate(moved, in: [obstacle], catalog: catalog).isEmpty)

        let narrowGaps = [WallSide.left, .back].flatMap { wall in
            stride(from: 0, to: GridRules.size, by: 4).map { occupied(wall, at: $0) }
        }
        #expect(GridRules.firstFreePlacement(for: model, in: narrowGaps, catalog: catalog)?.width == 2)
        #expect(GridRules.placementForTransfer(board, in: narrowGaps, catalog: catalog) == nil)
    }
}
