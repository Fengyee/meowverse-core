import Foundation
import Testing
@testable import MeowverseCore

/// Round 7's tall household pieces against a wall (bookcases, fireplaces) must not hide a photo
/// board from the room camera: the placement that would do it is refused, either way round.
/// Furniture from before round 7 (cat trees included) is not judged, as before.
@Suite struct PhotoBoardCoverTests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try FurnitureCatalog.bundled() }

    func floor(_ modelId: String, x: Int, z: Int, width: Int, depth: Int, turn: Int = 0) -> PhotoFurniture {
        PhotoFurniture(instanceId: modelId, modelId: modelId, x: x, z: z, width: width, depth: depth, turn: turn, wall: nil,
                       finish: .original, displayName: modelId, sources: [], tags: [], revision: 1)
    }

    func board(_ wall: WallSide, at x: Int, width: Int = 2) -> PhotoFurniture {
        PhotoFurniture(instanceId: "board-\(wall.rawValue)-\(x)", modelId: "wall-photo-board", x: x, z: 0, width: width,
                       depth: 1, turn: 0, wall: wall, finish: .original, displayName: "照片板", sources: [], tags: [], revision: 1)
    }

    func hides(_ issues: [PlacementIssue]) -> [String] {
        issues.compactMap { if case .hidesPhotoBoard(let id) = $0 { id } else { nil } }
    }

    @Test func aBookcaseRightUnderABoardIsRefused() {
        let hung = board(.back, at: 6)
        let issues = GridRules.validate(floor("mv-bookcase-a", x: 5, z: 0, width: 3, depth: 2).placement,
                                        in: [hung], catalog: catalog)
        #expect(hides(issues) == [hung.instanceId])
    }

    @Test func aBookcaseFurtherAlongTheWallOrOutInTheRoomIsFine() {
        let hung = board(.back, at: 10)
        // Along the wall, clear of the board's span (and of the leftward lean of its shadow).
        #expect(hides(GridRules.validate(floor("mv-bookcase-a", x: 1, z: 0, width: 3, depth: 2).placement,
                                         in: [hung], catalog: catalog)).isEmpty)
        // Three rows out the camera looks over it.
        #expect(hides(GridRules.validate(floor("mv-bookcase-a", x: 9, z: 3, width: 3, depth: 2).placement,
                                         in: [hung], catalog: catalog)).isEmpty)
    }

    /// The camera looks from the front right: a piece's shadow on the back wall leans left, so a
    /// piece just to the right of a board still covers part of it, and one just to its left none.
    @Test func theShadowLeansLeftOnTheBackWall() throws {
        let hearth = try #require(catalog.model(id: "mv-fireplace-a"))
        let hung = board(.back, at: 6).placement
        let right = floor("mv-fireplace-a", x: 8, z: 0, width: 3, depth: 2).placement
        let left = floor("mv-fireplace-a", x: 3, z: 0, width: 3, depth: 2).placement
        #expect(GridRules.boardShareHidden(hung, by: right, model: hearth) > 0.05)
        #expect(GridRules.boardShareHidden(hung, by: left, model: hearth) == 0)
        // Half over the board's span is refused.
        #expect(!hides(GridRules.validate(floor("mv-fireplace-a", x: 7, z: 0, width: 3, depth: 2).placement,
                                          in: [board(.back, at: 6)], catalog: catalog)).isEmpty)
    }

    @Test func theLeftWallCountsToo() {
        let hung = board(.left, at: 5)
        // Turned a quarter so its back is to the left wall: a 2×3 footprint along it.
        let issues = GridRules.validate(floor("mv-bookcase-a", x: 0, z: 5, width: 3, depth: 2, turn: 1).placement,
                                        in: [hung], catalog: catalog)
        #expect(hides(issues) == [hung.instanceId])
    }

    @Test func hangingABoardAboveATallHouseholdPieceIsRefused() {
        let bookcase = floor("mv-bookcase-a", x: 5, z: 0, width: 3, depth: 2)
        let hung = board(.back, at: 5).placement
        #expect(hides(GridRules.validate(hung, in: [bookcase], catalog: catalog)) == [bookcase.instanceId])
        // The suggestion finds a span the bookcase does not cover.
        let model = catalog.model(id: "wall-photo-board")!
        let free = GridRules.firstFreePlacement(for: model, in: [bookcase], catalog: catalog)
        #expect(free != nil && GridRules.validate(free!, in: [bookcase], catalog: catalog).isEmpty)
    }

    /// The rule is round 7's (owner: keep the existing product logic). A cat tree flush under a
    /// board goes in as it always has, either way round, though it hides the board.
    @Test func catTreesStillGoRightUnderABoard() throws {
        for id in ["mv-cat-tree-a", "mv-cat-tree-b", "mv-cat-tree-c"] {
            let tree = floor(id, x: 5, z: 0, width: 4, depth: 4)
            let hung = board(.back, at: 6)
            let model = try #require(catalog.model(id: id))
            #expect(GridRules.boardShareHidden(hung.placement, by: tree.placement, model: model) > 1.0 / 3.0, "\(id) does hide it")
            #expect(GridRules.validate(tree.placement, in: [hung], catalog: catalog).isEmpty, "\(id) placed under the board")
            #expect(GridRules.validate(hung.placement, in: [tree], catalog: catalog).isEmpty, "board hung above \(id)")
        }
    }

    /// Every piece from before round 7, at every catalogue size, flush in the back corner under
    /// a board: no board issue, as before the rule existed.
    @Test func noPieceFromBeforeRound7IsJudgedAgainstABoard() {
        let judged = GridRules.round7SoftFurnishings.union(Self.round10)
        let hung = board(.back, at: 0, width: 4)
        var checked = 0
        for model in catalog.models where model.mount == .floor && model.category.isRecognisedFromPhotos
            && !judged.contains(model.id) {
            for size in model.sizes {
                let piece = floor(model.id, x: 0, z: 0, width: size[0], depth: size[1])
                #expect(hides(GridRules.validate(piece.placement, in: [hung], catalog: catalog)).isEmpty, "\(model.id) \(size)")
                #expect(hides(GridRules.validate(hung.placement, in: [piece], catalog: catalog)).isEmpty, "\(model.id) \(size)")
                checked += 1
            }
        }
        #expect(checked > 44)
    }

    /// The four soft furnishings of round 7 are low: none of them reaches a board.
    @Test func round7SoftFurnishingsNeverReachABoard() {
        let hung = board(.back, at: 6)
        for (id, w, d) in [("mv-toy-e", 2, 2), ("mv-toy-f", 2, 2), ("mv-bed-d", 2, 2), ("mv-bed-e", 3, 2)] {
            #expect(hides(GridRules.validate(floor(id, x: 6, z: 0, width: w, depth: d).placement,
                                             in: [hung], catalog: catalog)).isEmpty, "\(id)")
        }
    }

    static let round10: Set<String> = ["mv-sofa-d", "mv-hideout-d", "mv-chair-d", "mv-chair-e", "mv-toy-g", "mv-bed-f"]

    /// From round 10 on, new pieces are judged like round 7's (lead, 2026-11-19). The cat wheel
    /// is 2.05 tall: flush under a board it hides about half of it, so it is refused there, either
    /// way round, and goes in once it stands out from the wall or along it.
    @Test func theCatWheelMayNotStandFlushUnderABoard() throws {
        let wheel = try #require(catalog.model(id: "mv-toy-g"))
        let hung = board(.back, at: 6)
        let flush = floor("mv-toy-g", x: 6, z: 0, width: 3, depth: 2)
        let share = GridRules.boardShareHidden(hung.placement, by: flush.placement, model: wheel)
        #expect(share > 0.5 && share < 0.6, "\(share)")
        #expect(hides(GridRules.validate(flush.placement, in: [hung], catalog: catalog)) == [hung.instanceId])
        #expect(hides(GridRules.validate(hung.placement, in: [flush], catalog: catalog)) == [flush.instanceId])
        #expect(hides(GridRules.validate(floor("mv-toy-g", x: 6, z: 3, width: 3, depth: 2).placement,
                                         in: [hung], catalog: catalog)).isEmpty)
        #expect(hides(GridRules.validate(floor("mv-toy-g", x: 1, z: 0, width: 3, depth: 2).placement,
                                         in: [hung], catalog: catalog)).isEmpty)
    }

    /// Every round 10 piece is judged; the other five are low enough that none is refused flush
    /// under a board (the ergonomic chair, the tallest at 1.66, hides about a fifth).
    @Test func round10PiecesAreJudgedButOnlyTheWheelIsTallEnoughToHide() throws {
        for id in Self.round10 {
            let model = try #require(catalog.model(id: id))
            #expect(GridRules.keepsClearOfBoards(model), "\(id)")
            guard id != "mv-toy-g" else { continue }
            let size = model.defaultSize
            let piece = floor(id, x: 6, z: 0, width: size[0], depth: size[1])
            #expect(GridRules.boardShareHidden(board(.back, at: 6).placement, by: piece.placement, model: model) <= GridRules.maxBoardShareHidden, "\(id)")
            #expect(hides(GridRules.validate(piece.placement, in: [board(.back, at: 6)], catalog: catalog)).isEmpty, "\(id)")
        }
    }

    /// Low furniture still goes under a board, as it always has.
    @Test func lowPiecesStillFitUnderABoard() {
        let hung = board(.back, at: 6)
        for (id, w, d) in [("mv-sofa-a", 3, 2), ("mv-bed-c", 3, 3), ("mv-window-perch-c", 3, 2)] {
            #expect(hides(GridRules.validate(floor(id, x: 6, z: 0, width: w, depth: d).placement,
                                             in: [hung], catalog: catalog)).isEmpty, "\(id)")
        }
    }

    @Test func theCoveredShareIsGeometric() throws {
        let tall = try #require(catalog.model(id: "mv-bookcase-a"))
        let hung = board(.back, at: 6).placement
        let flush = floor("mv-bookcase-a", x: 6, z: 0, width: 3, depth: 2).placement
        let share = GridRules.boardShareHidden(hung, by: flush, model: tall)
        #expect(share > 0.95, "\(share)")
        var out = flush
        out.z = 4
        #expect(GridRules.boardShareHidden(hung, by: out, model: tall) == 0)
    }
}
