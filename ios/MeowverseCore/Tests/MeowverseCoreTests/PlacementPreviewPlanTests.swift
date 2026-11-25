import MeowverseCore
import Testing

/// The placement preview loads a draft's 3D model once and moves it with the draft
/// (l-placement-preview): moving or turning never loads it again; another model, size, finish,
/// lifted piece or detail level does.
@Suite struct PlacementPreviewPlanTests {
    private func sofa(x: Int = 3, z: Int = 3, turn: Int = 0, width: Int = 2, finish: Finish = .original,
                      wall: WallSide? = nil) -> Placement {
        Placement(modelId: "mv-sofa-e", x: x, z: z, width: width, depth: 1, turn: turn, finish: finish, wall: wall)
    }

    private func key(_ placement: Placement, lifted: String? = nil, details: Int = 1) -> PlacementPreviewKey<Int> {
        PlacementPreviewKey(placement, lifted: lifted, details: details)
    }

    @Test func movingANewDraftKeepsItsModel() {
        let plan = PlacementPreviewPlan.plan(held: key(sofa()), wanted: key(sofa(z: 2)), shows: true)
        #expect(plan == PlacementPreviewPlan(keepsHeld: true, startsLoad: false))
    }

    @Test func turningANewDraftKeepsItsModel() {
        let plan = PlacementPreviewPlan.plan(held: key(sofa()), wanted: key(sofa(turn: 1)), shows: true)
        #expect(plan == PlacementPreviewPlan(keepsHeld: true, startsLoad: false))
    }

    @Test func movingAWallDraftAcrossWallsKeepsItsModel() {
        let plan = PlacementPreviewPlan.plan(held: key(sofa(wall: .back)), wanted: key(sofa(x: 1, wall: .left)), shows: true)
        #expect(plan.keepsHeld && !plan.startsLoad)
    }

    /// Through a cell it may not take and back: the model is kept (hidden there), not loaded again.
    @Test func anInvalidCellKeepsTheModelWithoutLoading() {
        let plan = PlacementPreviewPlan.plan(held: key(sofa()), wanted: key(sofa(x: 0)), shows: false)
        #expect(plan == PlacementPreviewPlan(keepsHeld: true, startsLoad: false))
    }

    @Test func aFirstInvalidCellLoadsNothing() {
        let plan = PlacementPreviewPlan.plan(held: nil, wanted: key(sofa()), shows: false)
        #expect(plan == PlacementPreviewPlan(keepsHeld: false, startsLoad: false))
    }

    @Test func aFirstValidCellLoads() {
        let plan = PlacementPreviewPlan.plan(held: nil, wanted: key(sofa()), shows: true)
        #expect(plan == PlacementPreviewPlan(keepsHeld: false, startsLoad: true))
    }

    @Test func anotherSizeFinishOrDetailLoadsAgain() {
        for wanted in [key(sofa(width: 3)), key(sofa(finish: .sage)), key(sofa(), details: 2),
                       PlacementPreviewKey(Placement(modelId: "mv-bed-a", x: 3, z: 3, width: 2, depth: 1), lifted: nil, details: 1)] {
            let plan = PlacementPreviewPlan.plan(held: key(sofa()), wanted: wanted, shows: true)
            #expect(plan == PlacementPreviewPlan(keepsHeld: false, startsLoad: true))
        }
    }

    @Test func anotherShapeOnAnInvalidCellDropsTheOldModel() {
        let plan = PlacementPreviewPlan.plan(held: key(sofa()), wanted: key(sofa(width: 3)), shows: false)
        #expect(plan == PlacementPreviewPlan(keepsHeld: false, startsLoad: false))
    }

    @Test func liftedPieceKeepsItsModelButAnotherPieceDoesNot() {
        #expect(PlacementPreviewPlan.plan(held: key(sofa(), lifted: "a"), wanted: key(sofa(z: 1), lifted: "a"), shows: true).keepsHeld)
        let other = PlacementPreviewPlan.plan(held: key(sofa(), lifted: "a"), wanted: key(sofa(), lifted: "b"), shows: true)
        #expect(other == PlacementPreviewPlan(keepsHeld: false, startsLoad: true))
        let added = PlacementPreviewPlan.plan(held: key(sofa(), lifted: "a"), wanted: key(sofa()), shows: true)
        #expect(!added.keepsHeld)
    }

    @Test func noDraftDropsEverything() {
        let plan = PlacementPreviewPlan.plan(held: key(sofa()), wanted: nil, shows: false)
        #expect(plan == PlacementPreviewPlan(keepsHeld: false, startsLoad: false))
    }

    @Test func modelShowsWhereValidOrLifted() {
        #expect(PlacementPreviewPlan.showsModel(valid: true, lifted: nil))
        #expect(!PlacementPreviewPlan.showsModel(valid: false, lifted: nil))
        #expect(PlacementPreviewPlan.showsModel(valid: false, lifted: "a"))
    }
}
