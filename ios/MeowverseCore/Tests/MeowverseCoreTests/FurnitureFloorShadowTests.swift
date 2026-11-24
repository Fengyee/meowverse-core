import Testing
@testable import MeowverseCore

@Suite struct FurnitureFloorShadowTests {
    private let stamp = FurnitureFloorShadowAtlas.Stamp(x: 0, y: 0, width: 3, height: 3)

    private func atlas() throws -> FurnitureFloorShadowAtlas {
        try #require(FurnitureFloorShadowAtlas(width: 3, height: 3, texelsPerCell: 1,
            stamps: ["test": stamp], pixels: [255, 255, 255, 255, 255, 130, 255, 255, 255]))
    }

    @Test func quarterTurnRotatesShadowWithThePiece() throws {
        let atlas = try atlas()
        let first = FurnitureFloorShadowPlacement(modelID: "test", x: 0, z: 0, turn: 0, scale: 1)
        let turned = FurnitureFloorShadowPlacement(modelID: "test", x: 0, z: 0, turn: 1, scale: 1)
        let a = try atlas.visibility(placements: [first], roomCells: 5, edges: 5)
        let b = try atlas.visibility(placements: [turned], roomCells: 5, edges: 5)
        #expect(a[2 * 5 + 3] == 130)
        #expect(b[1 * 5 + 2] == 130)
        #expect(b[2 * 5 + 3] == 255)
    }

    @Test func movedPieceClearsOriginalPositionAndClipsAtTheRoomEdge() throws {
        let atlas = try atlas()
        let moved = FurnitureFloorShadowPlacement(modelID: "test", x: -2, z: 1, turn: 0, scale: 1)
        let result = try atlas.visibility(placements: [moved], roomCells: 5, edges: 5)
        #expect(result[3 * 5 + 1] == 130)
        #expect(result[2 * 5 + 3] == 255)
        let outside = FurnitureFloorShadowPlacement(modelID: "test", x: 2, z: 0, turn: 0, scale: 1)
        #expect(try atlas.visibility(placements: [outside], roomCells: 5, edges: 5).allSatisfy { $0 == 255 })
    }

    @Test func widerPieceAndOverlapUseBoundedVisibility() throws {
        let atlas = try atlas()
        let enlarged = FurnitureFloorShadowPlacement(modelID: "test", x: 0, z: 0, turn: 0, scale: 2)
        let one = try atlas.visibility(placements: [enlarged], roomCells: 5, edges: 5)
        #expect(one[2 * 5 + 4] == 130)
        let both = try atlas.visibility(placements: [enlarged, enlarged], roomCells: 5, edges: 5)
        #expect(both[2 * 5 + 4] == 82)
    }

    @Test func rejectsAtlasEntriesOutsideTheImage() {
        #expect(FurnitureFloorShadowAtlas(width: 2, height: 2, texelsPerCell: 1,
            stamps: ["test": stamp], pixels: [255, 255, 255, 255]) == nil)
    }
}
