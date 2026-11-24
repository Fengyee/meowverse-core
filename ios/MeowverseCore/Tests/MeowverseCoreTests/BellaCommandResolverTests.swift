import Foundation
import Testing
@testable import MeowverseCore

/// What a room makes of a `BellaCommand` (docs/TALK_TO_BELLA.md "指令和房间的对应"), on the
/// real bundled catalog. Every invitation must be one the Interactions menu would enable.
@Suite struct BellaCommandResolverTests {
    private let catalog: FurnitureCatalog
    init() throws { catalog = try FurnitureCatalog.bundled() }

    private func piece(_ id: String, _ modelId: String, x: Int, z: Int, turn: Int = 0,
                       wall: WallSide? = nil) throws -> PhotoFurniture {
        let model = try #require(catalog.model(id: modelId))
        return PhotoFurniture(instanceId: id, modelId: modelId, x: x, z: z, width: model.defaultWidth,
                              depth: model.defaultDepth, turn: turn, wall: wall, finish: .original,
                              displayName: model.label, sources: [], tags: [], revision: 1)
    }

    private func resolve(_ command: BellaCommand, _ items: [PhotoFurniture]) -> Result<BellaPlan, BellaRefusal> {
        BellaCommandResolver.resolve(command, items: items, catalog: catalog)
    }

    /// The invitation, checked against the menu's own test: `invitedTrip` from the entrance.
    private func invitation(_ result: Result<BellaPlan, BellaRefusal>, in items: [PhotoFurniture],
                            sourceLocation: SourceLocation = #_sourceLocation) -> (item: String, site: String, action: CatAction)? {
        guard case .success(.invite(let item, let site, let action)) = result else {
            Issue.record("expected an invitation, got \(result)", sourceLocation: sourceLocation)
            return nil
        }
        #expect(CatRoutine.invitedTrip(items: items, from: .atEntrance, catalog: catalog, itemId: item,
                                       siteId: site, action: action) != nil, sourceLocation: sourceLocation)
        let offered = items.first { $0.instanceId == item }.flatMap { catalog.model(id: $0.modelId) }?
            .interactionSites.first { $0.id == site }?.actions ?? []
        #expect(offered.contains(action), sourceLocation: sourceLocation)
        return (item, site, action)
    }

    /// A 3x2 sofa in the back-left corner with every cell beside it taken: there is a sofa, but
    /// Bella cannot get to it (a room saved before the access rules).
    private func walledInSofa() throws -> [PhotoFurniture] {
        [try piece("sofa", "mv-sofa-a", x: 0, z: 0),
         try piece("bench", "mv-bench-a", x: 0, z: 2),
         try piece("stool-1", "mv-stool-a", x: 3, z: 0),
         try piece("stool-2", "mv-stool-a", x: 3, z: 1)]
    }

    // MARK: .visit with a named piece

    @Test func liesOnTheSofa() throws {
        let room = [try piece("sofa", "mv-sofa-a", x: 6, z: 5)]
        let found = try #require(invitation(resolve(.visit(action: .loaf, target: .sofa), room), in: room))
        #expect(found.item == "sofa" && found.action == .loaf)
    }

    @Test func noSofaInTheRoom() throws {
        let room = [try piece("bed", "mv-bed-a", x: 6, z: 5)]
        #expect(resolve(.visit(action: .loaf, target: .sofa), room) == .failure(.noSuchFurniture(.sofa)))
        #expect(resolve(.visit(action: .loaf, target: .sofa), []) == .failure(.noSuchFurniture(.sofa)))
    }

    @Test func sofaThatCannotBeReachedIsBlocked() throws {
        let room = try walledInSofa()
        #expect(CatRoutine.accessCell(of: room[0], in: room) == nil)
        #expect(resolve(.visit(action: .loaf, target: .sofa), room) == .failure(.blocked))
        // Nothing else in the room counts for a named piece, even though the bench offers loaf.
        #expect(resolve(.visit(action: .sleep, target: .sofa), room) == .failure(.blocked))
    }

    @Test func fallsBackToTheNearestActionOnlyWhenThePieceLacksIt() throws {
        // A stool offers only sit: lie → sleep → sit.
        let stool = [try piece("stool", "mv-stool-a", x: 7, z: 7)]
        #expect(invitation(resolve(.visit(action: .loaf, target: .stool), stool), in: stool)?.action == .sit)
        // A chair has sit and loaf: sleep → loaf.
        let chair = [try piece("chair", "mv-chair-a", x: 7, z: 7)]
        #expect(invitation(resolve(.visit(action: .sleep, target: .chair), chair), in: chair)?.action == .loaf)
        // A cushion bed has sleep and loaf: sit → loaf.
        let bed = [try piece("bed", "mv-bed-d", x: 7, z: 7)]
        #expect(invitation(resolve(.visit(action: .sit, target: .bed), bed), in: bed)?.action == .loaf)
        // The original action wins when the piece has it.
        #expect(invitation(resolve(.visit(action: .sit, target: .chair), chair), in: chair)?.action == .sit)
        // sleep only steps to loaf, never to sit.
        #expect(resolve(.visit(action: .sleep, target: .stool), stool) == .failure(.noSuchFurniture(.stool)))
        // No similar action for drinking.
        #expect(resolve(.visit(action: .drink, target: .sofa), [try piece("sofa", "mv-sofa-a", x: 6, z: 5)])
                == .failure(.noSuchFurniture(.sofa)))
    }

    @Test func noFallbackWithoutANamedPiece() throws {
        let stool = [try piece("stool", "mv-stool-a", x: 7, z: 7)]
        #expect(resolve(.visit(action: .loaf, target: nil), stool) == .failure(.noSuchFurniture(nil)))
        #expect(resolve(.visit(action: .sleep, target: nil), []) == .failure(.noSuchFurniture(nil)))
    }

    @Test func picksTheNearestOfSeveralThenTheSmallerId() throws {
        // "near" is a few steps from the entrance, "far" in the back corner.
        let far = try piece("a-far", "mv-sofa-a", x: 0, z: 0), near = try piece("z-near", "mv-sofa-a", x: 6, z: 9)
        let room = [far, near]
        #expect(invitation(resolve(.visit(action: .loaf, target: .sofa), room), in: room)?.item == "z-near")
        // Mirror images either side of the entrance are equally far: the smaller id wins,
        // whatever order the room lists them in.
        let left = try piece("b-left", "mv-sofa-a", x: 3, z: 10), right = try piece("a-right", "mv-sofa-a", x: 9, z: 10)
        for room in [[left, right], [right, left]] {
            #expect(invitation(resolve(.visit(action: .loaf, target: .sofa), room), in: room)?.item == "a-right")
        }
        // A reachable piece wins over one Bella cannot get to.
        var walled = try walledInSofa()
        walled.append(try piece("other-sofa", "mv-sofa-b", x: 10, z: 3))
        #expect(invitation(resolve(.visit(action: .loaf, target: .sofa), walled), in: walled)?.item == "other-sofa")
    }

    @Test func skipsWallAndDecorativePieces() throws {
        let room = [try piece("lamp", "mv-floor-lamp-a", x: 4, z: 4),
                    try piece("board", "wall-photo-board", x: 3, z: 0, wall: .back)]
        #expect(resolve(.visit(action: .sit, target: .floorLamp), room) == .failure(.noSuchFurniture(.floorLamp)))
        #expect(resolve(.visit(action: .sit, target: .photoBoard), room) == .failure(.noSuchFurniture(.photoBoard)))
        #expect(resolve(.visit(action: .sit, target: nil), room) == .failure(.noSuchFurniture(nil)))
    }

    @Test func legacyModelsUseTheirSeat() throws {
        // A retired id resolves through its alias, as saved rooms do.
        let room = [try piece("old", "kenney-loungeSofa", x: 6, z: 5)]
        #expect(invitation(resolve(.visit(action: .loaf, target: .sofa), room), in: room)?.item == "old")
    }

    /// Each kind of piece, alone in the room, takes the pose its own category suggests (or a
    /// similar one), so "去<家具>" works for everything that offers something to do.
    @Test func everyCatalogPieceAloneAnswersItsOwnCategory() throws {
        for model in catalog.models where catalog.aliases[model.id] == nil && model.mount == .floor {
            let placement = try #require(GridRules.firstFreePlacement(for: model, in: [], catalog: catalog))
            let item = PhotoFurniture(instanceId: model.id, modelId: model.id, x: placement.x, z: placement.z,
                                      width: placement.width, depth: placement.depth, turn: placement.turn,
                                      finish: .original, displayName: model.label, sources: [], tags: [], revision: 1)
            let action = CatRoutine.action(on: model.category)
            let chain: [CatAction] = switch action {
            case .loaf: [.loaf, .sleep, .sit]
            case .sleep: [.sleep, .loaf]
            case .sit: [.sit, .loaf]
            default: [action]
            }
            let offered = Set(model.interactionSites.flatMap(\.actions))
            let result = resolve(.visit(action: action, target: model.category), [item])
            if let expected = chain.first(where: offered.contains) {
                #expect(invitation(result, in: [item])?.action == expected, "\(model.id)")
            } else {
                #expect(result == .failure(.noSuchFurniture(model.category)), "\(model.id)")
            }
        }
    }

    // MARK: .visit with any piece

    @Test func napPrefersABedOverANearerSofa() throws {
        let sofa = try piece("sofa", "mv-sofa-a", x: 6, z: 9), bed = try piece("bed", "mv-bed-a", x: 0, z: 0)
        let room = [sofa, bed]
        #expect(invitation(resolve(.visit(action: .sleep, target: nil), room), in: room)?.item == "bed")
        // Without a bed she naps where she can.
        #expect(invitation(resolve(.visit(action: .sleep, target: nil), [sofa]), in: [sofa])?.item == "sofa")
        // A bed she cannot reach does not stop her napping on the sofa.
        let blockedBed = [try piece("bed", "mv-bed-d", x: 0, z: 0), try piece("s1", "mv-stool-a", x: 2, z: 0),
                          try piece("s2", "mv-stool-a", x: 2, z: 1), try piece("s3", "mv-stool-a", x: 0, z: 2),
                          try piece("s4", "mv-stool-a", x: 1, z: 2), sofa]
        #expect(invitation(resolve(.visit(action: .sleep, target: nil), blockedBed), in: blockedBed)?.item == "sofa")
    }

    @Test func drinkScratchHideAndDig() throws {
        let room = [try piece("water", "mv-water-b", x: 1, z: 1), try piece("scratcher", "mv-scratcher-a", x: 11, z: 1),
                    try piece("box", "mv-hideout-d", x: 1, z: 8), try piece("litter", "mv-litter-box-a", x: 11, z: 8)]
        let cases: [(CatAction, String)] = [(.drink, "water"), (.scratch, "scratcher"), (.hide, "box"), (.dig, "litter")]
        for (action, expected) in cases {
            #expect(invitation(resolve(.visit(action: action, target: nil), room), in: room)?.item == expected)
            #expect(resolve(.visit(action: action, target: nil), []) == .failure(.noSuchFurniture(nil)))
        }
        // Scratching also happens on a cat tree.
        let tree = [try piece("tree", "mv-cat-tree-a", x: 5, z: 4)]
        #expect(invitation(resolve(.visit(action: .scratch, target: nil), tree), in: tree)?.site == "scratch")
    }

    @Test func blockedWhenEveryPieceThatOffersTheActionIsCutOff() throws {
        // A 3x3 litter box in the back-left corner, every cell beside it taken.
        let litter = [try piece("litter", "mv-litter-box-a", x: 0, z: 0), try piece("bench", "mv-bench-a", x: 0, z: 3),
                      try piece("s1", "mv-stool-a", x: 3, z: 0), try piece("s2", "mv-stool-a", x: 3, z: 1),
                      try piece("s3", "mv-stool-a", x: 3, z: 2)]
        #expect(CatRoutine.accessCell(of: litter[0], in: litter) == nil)
        #expect(resolve(.visit(action: .dig, target: nil), litter) == .failure(.blocked))
    }

    // MARK: .play and eating

    @Test func playUsesAToyInTheRoomFirst() throws {
        let room = [try piece("toy", "mv-toy-a", x: 3, z: 3)]
        let found = invitation(resolve(.play(treat: false), room), in: room)
        #expect(found?.item == "toy" && found?.action == .play)
        let tree = [try piece("tree", "mv-cat-tree-a", x: 5, z: 4)]
        #expect(invitation(resolve(.play(treat: false), tree), in: tree)?.site == "play")
    }

    @Test func playWithoutAToyBringsOutTheFeltMouse() throws {
        #expect(resolve(.play(treat: false), []) == .success(.play(.toyMouse)))
        let sofa = [try piece("sofa", "mv-sofa-a", x: 6, z: 5)]
        #expect(resolve(.play(treat: false), sofa) == .success(.play(.toyMouse)))
        // The cat wheel is a toy without a play site: it does not count.
        let wheel = [try piece("wheel", "mv-toy-g", x: 6, z: 5)]
        #expect(resolve(.play(treat: false), wheel) == .success(.play(.toyMouse)))
    }

    @Test func treatsAreAlwaysTheFishBiscuit() throws {
        let room = [try piece("toy", "mv-toy-a", x: 3, z: 3), try piece("food", "mv-water-a", x: 9, z: 3)]
        #expect(resolve(.play(treat: true), room) == .success(.play(.treatBiscuit)))
        #expect(resolve(.play(treat: true), []) == .success(.play(.treatBiscuit)))
    }

    @Test func eatingGoesToAFoodBowlOrFallsBackToATreat() throws {
        let room = [try piece("food", "mv-water-a", x: 9, z: 3)]
        let found = invitation(resolve(.visit(action: .eat, target: nil), room), in: room)
        #expect(found?.item == "food" && found?.site == "kibble")
        #expect(resolve(.visit(action: .eat, target: nil), []) == .success(.play(.treatBiscuit)))
        // A water bowl offers no food.
        let water = [try piece("water", "mv-water-b", x: 9, z: 3)]
        #expect(resolve(.visit(action: .eat, target: nil), water) == .success(.play(.treatBiscuit)))
        // A named piece without food is not replaced by a treat.
        #expect(resolve(.visit(action: .eat, target: .water), water) == .failure(.noSuchFurniture(.water)))
    }

    @Test func playAndTreatsNeedSomeFloorSheCanReach() throws {
        // Every neighbour of the entrance taken: no spot to put a toy down that she can walk to.
        let shut = [try piece("l", "mv-stool-a", x: 6, z: 14), try piece("r", "mv-stool-a", x: 8, z: 14),
                    try piece("u", "mv-stool-a", x: 7, z: 13)]
        #expect(resolve(.play(treat: false), shut) == .failure(.blocked))
        #expect(resolve(.play(treat: true), shut) == .failure(.blocked))
        #expect(resolve(.visit(action: .eat, target: nil), shut) == .failure(.blocked))
    }

    // MARK: .comeHere

    @Test func comeHereGoesToTheFrontCorner() throws {
        let cell = try #require(BellaCommandResolver.comeHereCell(items: [], catalog: catalog))
        #expect(cell == GridCell(x: GridRules.size - 1, z: GridRules.size - 1))
        #expect(resolve(.comeHere, []) == .success(.come(to: cell)))
    }

    @Test func comeHereStepsAroundFurnitureInTheCorner() throws {
        // A 2x2 chair covering the front corner: the nearest free cell toward the camera.
        let room = [try piece("chair", "mv-chair-a", x: 13, z: 13)]
        let cell = try #require(BellaCommandResolver.comeHereCell(items: room, catalog: catalog))
        #expect(cell == GridCell(x: 12, z: 14))
        #expect(!GridRules.blockedCells(room).contains(cell))
        #expect(CatRoutine.floorTrip(items: room, from: .atEntrance, catalog: catalog, to: cell, action: .sit) != nil)
        // Same room, same answer.
        #expect(BellaCommandResolver.comeHereCell(items: room, catalog: catalog) == cell)
    }

    @Test func comeHereNeverPicksAnUnreachableCellOrTheEntrance() throws {
        // The front corner is free but fenced off by a bench and a stool.
        let room = [try piece("bench", "mv-bench-a", x: 12, z: 13), try piece("stool", "mv-stool-a", x: 12, z: 14)]
        let cell = try #require(BellaCommandResolver.comeHereCell(items: room, catalog: catalog))
        #expect(cell != GridCell(x: 14, z: 14) && cell != GridRules.entrance)
        #expect(CatRoutine.floorTrip(items: room, from: .atEntrance, catalog: catalog, to: cell, action: .sit) != nil)
        // Only the entrance itself is left: nowhere to come to.
        let shut = [try piece("l", "mv-stool-a", x: 6, z: 14), try piece("r", "mv-stool-a", x: 8, z: 14),
                    try piece("u", "mv-stool-a", x: 7, z: 13)]
        #expect(BellaCommandResolver.comeHereCell(items: shut, catalog: catalog) == nil)
        #expect(resolve(.comeHere, shut) == .failure(.blocked))
    }

    @Test func comeHereStartsFromWhereSheRests() throws {
        // Resting in the walled-off front corner pocket, "here" is in that pocket.
        let room = [try piece("bench", "mv-bench-a", x: 12, z: 13), try piece("stool", "mv-stool-a", x: 12, z: 14)]
        let rest = CatRest(cell: GridCell(x: 13, z: 14), itemId: nil, lastItemId: nil, action: .sit)
        #expect(BellaCommandResolver.comeHereCell(items: room, catalog: catalog, from: rest) == GridCell(x: 14, z: 14))
    }

    // MARK: Not understood

    @Test func unsupportedIsNotUnderstood() throws {
        #expect(resolve(.unsupported, []) == .failure(.notUnderstood))
        #expect(resolve(.unsupported, [try piece("sofa", "mv-sofa-a", x: 6, z: 5)]) == .failure(.notUnderstood))
    }
}
