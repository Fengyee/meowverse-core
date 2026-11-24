import Foundation
import simd
import Testing
@testable import MeowverseCore

/// The room on a real table in AR (round 11 trial): when 互动 offers it, what the page tells
/// the user, and the tabletop transform behind tap to place, pinch, rotate and drag.
@Suite struct ARTabletopTests {
    // MARK: Entry

    /// No world tracking (the simulator, a Mac running the iPad app): no row at all.
    @Test(arguments: [ARCameraAccess.undetermined, .allowed, .denied, .restricted])
    func noWorldTrackingNoRow(camera: ARCameraAccess) {
        #expect(ARTabletop.entry(worldTracking: false, camera: camera) == .hidden)
    }

    /// Not asked yet counts as allowed: ARKit asks when the session first runs.
    @Test func cameraAllowedOrNotAskedYetOpensTheTabletop() {
        #expect(ARTabletop.entry(worldTracking: true, camera: .allowed) == .available)
        #expect(ARTabletop.entry(worldTracking: true, camera: .undetermined) == .available)
    }

    /// Camera turned off stays visible, so the page can say how to turn it back on.
    @Test func cameraOffKeepsTheRowAndSaysWhy() {
        #expect(ARTabletop.entry(worldTracking: true, camera: .denied) == .cameraOff)
        #expect(ARTabletop.entry(worldTracking: true, camera: .restricted) == .cameraOff)
    }

    // MARK: Hint

    @Test func hintFollowsTheSessionInThisOrder() {
        #expect(ARTabletop.hint(surfaceFound: false, placed: false, interrupted: false, tooWarm: false) == .lookForSurface)
        #expect(ARTabletop.hint(surfaceFound: true, placed: false, interrupted: false, tooWarm: false) == .tapToPlace)
        #expect(ARTabletop.hint(surfaceFound: true, placed: true, interrupted: false, tooWarm: false) == .placed)
        // A placed room stays placed when the surface is lost from view.
        #expect(ARTabletop.hint(surfaceFound: false, placed: true, interrupted: false, tooWarm: false) == .placed)
        #expect(ARTabletop.hint(surfaceFound: true, placed: true, interrupted: false, tooWarm: true) == .tooWarm)
        #expect(ARTabletop.hint(surfaceFound: true, placed: true, interrupted: true, tooWarm: true) == .interrupted)
        #expect(ARTabletop.hint(surfaceFound: false, placed: false, interrupted: true, tooWarm: false) == .interrupted)
    }

    /// Searching a long time without a surface suggests another table; a found one ends that.
    @Test func aLongSearchSuggestsAnotherSurface() {
        #expect(ARTabletop.hint(surfaceFound: false, placed: false, interrupted: false, tooWarm: false, searchedLong: true) == .tryAnotherSurface)
        #expect(ARTabletop.hint(surfaceFound: true, placed: false, interrupted: false, tooWarm: false, searchedLong: true) == .tapToPlace)
        #expect(ARTabletop.hint(surfaceFound: false, placed: true, interrupted: false, tooWarm: false, searchedLong: true) == .placed)
        #expect(ARTabletop.slowSearch == .seconds(15))
    }

    // MARK: Placing

    private static let table: SIMD3<Float> = [0.2, 0.74, -0.5]

    /// The plinth's underside, the corner of the room's front and the back wall's top, in room units.
    private static let plinthBottom = SIMD3<Float>(0, -RoomShellSize.plinthDepth, 0)

    @Test func theRoomStandsOnTheTappedSpotAtTabletopSize() {
        let pose = ARTabletopPose.placed(at: Self.table, facing: [0.2, 1.1, 0.3])
        #expect(pose.edge == ARTabletopPose.defaultEdge)
        // Default: a model of 30–40 cm, as the product brief asks.
        #expect((0.3...0.4).contains(pose.edge))
        #expect(close(pose.world(Self.plinthBottom), Self.table))
        // The floor is the plinth's depth above the table, at this scale.
        #expect(close(pose.world(.zero), Self.table + [0, RoomShellSize.plinthDepth * pose.scale, 0]))
        // The whole plinth is `edge` across.
        let left = pose.world([-RoomShellSize.plinthSpan / 2, 0, 0]), right = pose.world([RoomShellSize.plinthSpan / 2, 0, 0])
        #expect(abs(simd_distance(left, right) - pose.edge) < 1e-5)
    }

    /// The room turns its open corner, the side the app's fixed camera looks from, to the phone.
    @Test(arguments: [SIMD3<Float>(0.2, 1.1, 0.3), [1.2, 1.0, -0.5], [0.2, 1.0, -1.4], [-0.9, 0.9, -0.9], [-0.6, 1.3, 0.1]])
    func theOpenCornerFacesThePhone(camera: SIMD3<Float>) {
        let pose = ARTabletopPose.placed(at: Self.table, facing: camera)
        let designed = simd_normalize(SIMD3<Float>(RoomShellSize.designedEye.x, 0, RoomShellSize.designedEye.y))
        let turned = pose.rotation.act(designed)
        var toCamera = camera - Self.table
        toCamera.y = 0
        #expect(close(turned, simd_normalize(toCamera)))
        // Only a turn about the vertical: the floor stays level.
        #expect(close(pose.rotation.act([0, 1, 0]), [0, 1, 0]))
    }

    @Test func aPhoneStraightAboveStillGivesALevelRoom() {
        let pose = ARTabletopPose.placed(at: Self.table, facing: Self.table + [0, 0.6, 0])
        #expect(pose.yaw.isFinite)
        #expect(close(pose.rotation.act([0, 1, 0]), [0, 1, 0]))
    }

    // MARK: Pinch, rotate, drag

    @Test func pinchScalesAboutThePlinthAndKeepsItOnTheTable() {
        let start = ARTabletopPose.placed(at: Self.table, facing: [0.2, 1.1, 0.3])
        let bigger = start.scaled(by: 1.5)
        #expect(abs(bigger.edge - start.edge * 1.5) < 1e-5)
        #expect(close(bigger.world(Self.plinthBottom), Self.table))
        #expect(bigger.yaw == start.yaw)
    }

    /// No life-size room in the first version, and never too small to tap a piece.
    @Test func pinchStopsAtTheLimits() {
        let start = ARTabletopPose.placed(at: Self.table, facing: [0.2, 1.1, 0.3])
        #expect(start.scaled(by: 100).edge == ARTabletopPose.edges.upperBound)
        #expect(start.scaled(by: 0.01).edge == ARTabletopPose.edges.lowerBound)
        #expect(ARTabletopPose.edges.upperBound <= 1.2)
        // A broken gesture value changes nothing.
        #expect(start.scaled(by: 0) == start)
        #expect(start.scaled(by: .nan) == start)
        #expect(start.scaled(by: -2) == start)
        #expect(start.scaled(by: .infinity) == start)
    }

    @Test func rotateTurnsAboutTheVerticalWithoutMovingTheRoom() {
        let start = ARTabletopPose.placed(at: Self.table, facing: [0.2, 1.1, 0.3])
        let turned = start.turned(by: .pi / 3)
        #expect(abs(turned.yaw - (start.yaw + .pi / 3)) < 1e-5)
        #expect(close(turned.world(Self.plinthBottom), Self.table))
        #expect(turned.edge == start.edge)
        #expect(start.turned(by: .nan) == start)
    }

    /// The drag carries the room by the finger's way across the table, never up or down.
    @Test func dragMovesAlongTheTable() {
        let start = ARTabletopPose.placed(at: Self.table, facing: [0.2, 1.1, 0.3])
        let moved = start.moved(from: [0.1, 0.74, -0.4], to: [0.25, 0.79, -0.6])
        #expect(close(moved.base, Self.table + [0.15, 0, -0.2]))
        #expect(moved.yaw == start.yaw && moved.edge == start.edge)
    }

    // MARK: Finger on the table

    @Test func aRayDownMeetsTheTable() throws {
        let hit = try #require(ARTabletop.floorHit(origin: [0, 1.2, 0], direction: simd_normalize([0.3, -1, -0.4]), planeY: 0.74))
        #expect(abs(hit.y - 0.74) < 1e-5)
        #expect(close(hit, [0.138, 0.74, -0.184]))
    }

    @Test func raysThatNeverMeetTheTableNearbyGiveNothing() {
        // Level with the table, pointing up, or meeting it far off towards the horizon.
        #expect(ARTabletop.floorHit(origin: [0, 1.2, 0], direction: [1, 0, 0], planeY: 0.74) == nil)
        #expect(ARTabletop.floorHit(origin: [0, 1.2, 0], direction: simd_normalize([0, 1, -1]), planeY: 0.74) == nil)
        #expect(ARTabletop.floorHit(origin: [0, 1.2, 0], direction: simd_normalize([0, -0.01, -1]), planeY: 0.74) == nil)
        #expect(ARTabletop.floorHit(origin: [0, 1.2, 0], direction: simd_normalize([0, -0.01, -1]), planeY: 0.74, maxDistance: 100) != nil)
    }

    private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, within tolerance: Float = 1e-3) -> Bool {
        simd_distance(a, b) < tolerance
    }
}
