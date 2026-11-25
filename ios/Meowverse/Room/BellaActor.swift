import MeowverseCore
import OSLog
import RealityKit
import UIKit

/// Bella in the room: owns her entities and plays the routine from `CatRoutine`.
///
/// Everything is advanced from the scene's per-frame update (`tick`), so there are no timers or
/// tasks to leak: when the scene stops updating, or the owner stops calling `tick`, she stops.
final class BellaActor {
    /// Size relative to the web cat (`CatRoutine.webScale`, already baked into the meshes).
    /// The room is drawn at about 14 pt per cell on a phone, so at 1.0 a sitting Bella is roughly
    /// 10 pt tall and reads as a prop. Compared on the simulator at 1.3, 1.5 and 1.8: at 1.5 she is
    /// the first thing the eye finds (about 1.1 cells tall sitting, 1.5 long loafing) and her
    /// seated width (0.56 cells) still fits the narrowest seat, a 0.67-cell chair; at 1.8 she is
    /// as big as the chair she sits on.
    static let scale: Float = 1.5

    enum Timing {
        /// Before the very first trip (web: 2 s).
        static let firstRest: TimeInterval = 2
        /// Resting on furniture (web: 10 s) and on the floor (web: 4.5 s).
        static let furnitureRest: TimeInterval = 10
        static let floorRest: TimeInterval = 4.5
        /// How soon she sets off for a piece that was just added.
        static let newFurnitureRest: TimeInterval = 1.2
        /// A jump on or off a seat, plus a little more for each cell it covers (a bed is long).
        static let jump: TimeInterval = 0.42
        static let jumpPerCell: TimeInterval = 0.12
        static let fade: TimeInterval = 0.22
        /// Sitting where she was called to: as long as she stays on a piece she was invited to,
        /// so "come here" is not over before the user has looked at her.
        static let summonedRest: TimeInterval = furnitureRest
    }

    /// Position and heading.
    let root = Entity()
    /// The three static poses use a different baked scale from the gait mesh.
    private let body = Entity()
    private var groundPlayer: GroundGaitPlayer?
    var groundGait: GroundGait = .groundWalk {
        didSet {
            guard groundGait != oldValue, isLoaded, !reduceMotion, currentPlayRequest == nil,
                  case .resting = phase else { return }
            phase = .resting(remaining: 0)
        }
    }
    private var poses: [ArtLibrary.BellaPose: BellaFigure] = [:]
    private var visiblePose: ArtLibrary.BellaPose?
    private var activityTime: TimeInterval = 0
    /// Seconds since the previous tick, for blending between clips.
    private var frameDelta: TimeInterval = 1.0 / 60
    private var activeLastTick = false
    private var invitation: (itemId: String, siteId: String, action: CatAction)?
    /// A "come here" not yet set off on: the floor cell to sit on.
    private var summon: GridCell?
    private(set) var currentPlayRequest: CatPlayRequest?
    private var receivedPlayId: UUID?
    private var playNeedsUpdate = false
    private var enjoyingPlayId: UUID?
    private static let treatDuration: TimeInterval = 4.8
    var onPlayConsumed: ((UUID) -> Void)?
    var onPlayRejected: ((UUID) -> Void)?

    var playIsEnjoying: Bool {
        enjoyingPlayId != nil && enjoyingPlayId == currentPlayRequest?.id
    }

    var playProgress: Double? {
        guard playIsEnjoying, currentPlayRequest?.item.isTreat == true else { return nil }
        return min(activityTime / Self.treatDuration, 1)
    }

    func play(_ request: CatPlayRequest?) {
        guard request?.id != receivedPlayId else { return }
        receivedPlayId = request?.id
        currentPlayRequest = request
        playNeedsUpdate = true
        invitation = nil
        summon = nil
    }

    func invite(itemId: String, siteId: String, action: CatAction) {
        receivedPlayId = nil
        currentPlayRequest = nil
        enjoyingPlayId = nil
        playNeedsUpdate = false
        summon = nil
        invitation = (itemId, siteId, action)
        if case .resting(let remaining) = phase {
            phase = .resting(remaining: min(remaining, Timing.floorRest))
        }
    }

    /// Talk to Bella's "come here" (docs/TALK_TO_BELLA.md): like an invitation, it takes over
    /// from whatever she is doing; she walks to `cell` on the floor (jumping down first if she is
    /// on a piece) and sits facing the camera, then carries on with her own routine. If the cell
    /// cannot be reached she stays where she is.
    func come(to cell: GridCell) {
        receivedPlayId = nil
        currentPlayRequest = nil
        enjoyingPlayId = nil
        playNeedsUpdate = false
        invitation = nil
        summon = cell
        if case .resting(let remaining) = phase {
            phase = .resting(remaining: min(remaining, Timing.floorRest))
        }
    }

    var toySwing: (itemId: String, angle: Float)? {
        guard activeLastTick, !reduceMotion, case .resting = phase, rest.action == .play,
              let id = rest.itemId else { return nil }
        let strike = groundPlayer?.toyStrike ?? (period: 2.4, contact: 0.58)
        let sinceHit = activityTime.truncatingRemainder(dividingBy: strike.period) - strike.contact
        guard sinceHit > 0 else { return (id, 0) }
        return (id, Float(0.55 * exp(-2.8 * sinceHit) * sin(12 * sinceHit)))
    }

    var reduceMotion = false
    /// 0..<1; injectable so a run can be made deterministic.
    var random: () -> Double = { Double.random(in: 0..<1) }
    /// Called from `tick` when what she is doing changes (never during a SwiftUI view update).
    var onStatus: ((BellaStatus) -> Void)?
    /// Pieces another cat in the room is on or heading for; she leaves them alone on her own
    /// trips (an invitation from the user still goes where it says).
    var avoiding: () -> Set<String> = { [] }

    /// The piece she is on, or on her way to.
    var claimedItemId: String? {
        switch phase {
        case .resting: rest.itemId
        case .walking(let walk): walk.arrival.rest.itemId
        case .fading(let arrival, _, _): arrival.rest.itemId
        }
    }

    /// For a second cat: starts on the floor at `cell` instead of at the door, and sets off
    /// `delay` seconds later than the first cat, so they are not on top of each other.
    /// Call before the first `sync`.
    func start(at cell: GridCell, after delay: TimeInterval) {
        rest = floorRest(at: cell)
        phase = .resting(remaining: Timing.firstRest + delay)
        status = .onFloor(.sit)
    }

    private var catalog: FurnitureCatalog?
    private var items: [PhotoFurniture] = []
    private var synced = false
    private var rest = CatRest.atEntrance
    /// The piece she is resting on, as it was when she got on.
    private var restingOn: PhotoFurniture?
    private var restYaw = BellaActor.cameraYaw
    private var phase = Phase.resting(remaining: Timing.firstRest)
    private var trips = 0
    private var newcomer: String?
    private var status = BellaStatus.atEntrance
    private var reported: BellaStatus?

    private enum Phase {
        case resting(remaining: TimeInterval)
        case walking(Walk)
        /// Reduce Motion: fade out, appear at the destination, fade in.
        case fading(to: Arrival, elapsed: TimeInterval, swapped: Bool)
    }

    private struct Arrival {
        var rest: CatRest
        var item: PhotoFurniture?
        var position: SIMD3<Float>
        var yaw: Float
        var playRequestId: UUID? = nil
        /// She was called here ("come here"), and stays a little longer.
        var summoned = false
    }

    private struct Segment {
        var from: SIMD3<Float>
        var to: SIMD3<Float>
        /// A hop between footholds at different heights: drawn as a `CatHop`, whose apex grows with
        /// the rise and which clears the lip before crossing it. Otherwise a straight line.
        var jumps: Bool
        var accessDuration: TimeInterval = 0
        var floorDistance: Double = 0
        var floorEnd: GridCell? = nil
    }

    private struct Walk {
        var segments: [Segment]
        var index = 0
        var progress: Double = 0
        var completedFloorDistance: Double = 0
        var arrival: Arrival
    }

    /// Facing the camera, as the web cat does when she settles on the floor. The room camera is
    /// orthographic, so this is the same at every cell: the horizontal part of the direction from
    /// the camera's target back to its eye (yaw 0 faces +z, as in `CatTrip.rotation`).
    static let cameraYaw = atan2(RoomProjection.position.x - RoomProjection.target.x,
                                 RoomProjection.position.z - RoomProjection.target.z)

    init() {
        root.name = "bella"
        body.scale = SIMD3(repeating: Self.scale)
        root.addChild(body)
        root.isEnabled = false
    }

    var isLoaded: Bool { skeletal || poses.count == ArtLibrary.BellaPose.allCases.count }

    /// The cat pack and tier whose meshes are shown (`CatPackVariant.key`, e.g. "builtIn:bella:bundle#low").
    private(set) var packKey: String?

    /// The skeleton player while it is loaded (nil for baked poses): the postcard dresses a copy
    /// of its entity in a finer tier's mesh.
    var skeletalPlayer: GroundGaitPlayer? { groundPlayer }

    func load(from art: CatArt, catalog: FurnitureCatalog) async throws {
        try Task.checkCancellation()
        self.catalog = catalog
        var player: GroundGaitPlayer?
        do {
            player = try await GroundGaitPlayer.load(from: art)
        } catch {
            try Task.checkCancellation()
            Logger(subsystem: "Meowverse", category: "art").error("Ground gaits unavailable: \(String(describing: error), privacy: .public)")
            // A downloaded tier whose skin or rig fails is unusable, not a still cat shown as
            // that tier: the room falls back to 中 (G24-01).
            guard art.variant.showsPosesWithoutSkeleton else { throw error }
        }
        var loaded: [ArtLibrary.BellaPose: BellaFigure] = [:]
        if player?.playsActions != true {
            for pose in ArtLibrary.BellaPose.allCases {
                let figure = try await art.bella(pose)
                figure.entity.isEnabled = false
                loaded[pose] = figure
            }
        }
        try Task.checkCancellation()
        packKey = art.variant.key
        if let player {
            player.entity.isEnabled = false
            root.addChild(player.entity)
            groundPlayer = player
        }
        for figure in loaded.values { body.addChild(figure.entity) }
        poses = loaded
        if hasBeenPlaced {
            resume()
        } else {
            place(at: rest, on: restingOn)
            hasBeenPlaced = true
        }
    }

    /// Whether an earlier `load` has put her in the room. After that, `root` keeps tracking the
    /// routine while no meshes are loaded (`sync` still moves it), so another pack carries on.
    private var hasBeenPlaced = false

    /// Another pack's meshes take over mid-action. Nothing about the routine restarts: the exact
    /// play contact and heading on `root`, the phase (a treat or toy waits indefinitely), the
    /// clip time and the play request she is honouring all stay, so a treat she was eating is
    /// still finished after its full duration and a walk or fade in progress completes.
    private func resume() {
        switch phase {
        case .resting:
            show(rest.action.pose)
            poseAtRest(rest.action, flat: scratchesFlat(at: rest))
        case .walking(let walk):
            pose(along: walk, delta: 0)
        case .fading(let arrival, _, let swapped):
            let shown = swapped ? arrival.rest : rest
            show(shown.action.pose)
            poseAtRest(shown.action, flat: scratchesFlat(at: shown))
        }
    }

    /// Drops the current cat's entities so another pack can be loaded. Where she is and what
    /// she is doing are kept; the next `load` resumes the new cat from the same instant.
    func unload() {
        for figure in poses.values { figure.entity.removeFromParent() }
        poses = [:]
        visiblePose = nil
        groundPlayer?.entity.removeFromParent()
        groundPlayer = nil
        body.isEnabled = true
        packKey = nil
    }

    // MARK: Room changes

    /// Follows the saved room. A change under her feet puts her somewhere valid at once; a new
    /// piece becomes her next destination.
    func sync(items newItems: [PhotoFurniture], catalog: FurnitureCatalog) {
        self.catalog = catalog
        let old = items
        items = newItems
        defer { synced = true }
        guard old.map(Footprint.init) != newItems.map(Footprint.init) else { return }
        if currentPlayRequest != nil { playNeedsUpdate = true }

        if synced, let added = newItems.last(where: { new in !old.contains { $0.instanceId == new.instanceId } }) {
            newcomer = added.instanceId
        }
        switch phase {
        case .walking, .fading:
            // The route was planned for the old room: stop where she is, on the floor.
            let half = Float(GridRules.size) / 2
            let cell = GridCell(x: Int((root.position.x + half).rounded(.down)), z: Int((root.position.z + half).rounded(.down)))
            rest = CatRoutine.settled(floorRest(at: cell), items: newItems, catalog: catalog)
            restingOn = nil
            restYaw = Self.cameraYaw
            place(at: rest, on: nil)
        case .resting:
            var next = rest
            if let on = restingOn, newItems.first(where: { $0.instanceId == on.instanceId }).map(Footprint.init) != Footprint(on) {
                // Her seat moved or went away: she is left on the floor where she got on.
                next.itemId = nil
                next.siteId = nil
                next.action = .loaf
            }
            next = CatRoutine.settled(next, items: newItems, catalog: catalog)
            let moved = rest.cell != next.cell || rest.itemId != next.itemId || rest.siteId != next.siteId
            rest = next
            if moved {
                restingOn = newItems.first { $0.instanceId == rest.itemId }
                if restingOn == nil { restYaw = Self.cameraYaw }
                place(at: rest, on: restingOn)
            }
        }
        if case .resting(let remaining) = phase, newcomer != nil {
            phase = .resting(remaining: min(remaining, Timing.newFurnitureRest))
        }
    }

    // MARK: Per frame

    /// Advances the routine. `active` is false while the room is covered or being edited: she
    /// holds still (mid-step if need be) and no rest time passes.
    func tick(_ delta: TimeInterval, active: Bool) {
        defer { report() }
        activeLastTick = active
        guard isLoaded, active else { return }
        let delta = min(max(delta, 0), 0.05)
        frameDelta = delta
        switch phase {
        case .resting(let remaining):
            if honorPlay() { return }
            if honorInvitation() { return }
            if honorSummon() { return }
            activityTime += delta
            poseAtRest(rest.action, flat: scratchesFlat(at: rest))
            if consumeTreatIfFinished() { return }
            if remaining > delta {
                phase = .resting(remaining: remaining - delta)
            } else {
                startTrip()
            }
        case .walking(let walk):
            advanceWalk(walk, delta: delta)
        case .fading(let arrival, let elapsed, let swapped):
            advanceFade(to: arrival, elapsed: elapsed + delta, swapped: swapped)
        }
    }

    private func advanceWalk(_ previous: Walk, delta: TimeInterval) {
        var walk = previous
        if reduceMotion {
            phase = .fading(to: walk.arrival, elapsed: 0, swapped: false)
            return
        }
        let secondsPerCell = groundPlayer.map { $0.duration(groundGait) / $0.stride(groundGait) } ?? 1
        var available = delta
        while walk.index < walk.segments.count {
            let segment = walk.segments[walk.index]
            let duration = segment.floorDistance > 0 ? segment.floorDistance * secondsPerCell : segment.accessDuration
            let remaining = (1 - walk.progress) * duration
            if available < remaining {
                walk.progress += available / duration
                pose(along: walk, delta: delta)
                phase = .walking(walk)
                return
            }
            available -= remaining
            walk.completedFloorDistance += segment.floorDistance
            walk.index += 1
            walk.progress = 0
            if let cell = segment.floorEnd, playNeedsUpdate || invitation != nil || summon != nil {
                let onFloor = floorRest(at: cell)
                if honorPlay(from: onFloor, floorDistance: walk.completedFloorDistance) { return }
                if honorInvitation(from: onFloor, floorDistance: walk.completedFloorDistance) { return }
                if honorSummon(from: onFloor, floorDistance: walk.completedFloorDistance) { return }
            }
        }
        arrive(walk.arrival)
    }

    private func advanceFade(to arrival: Arrival, elapsed: TimeInterval, swapped: Bool) {
        let didSwap = swapped || elapsed >= Timing.fade
        if didSwap, !swapped { apply(arrival) }
        let opacity = didSwap ? (elapsed - Timing.fade) / Timing.fade : 1 - elapsed / Timing.fade
        root.components.set(OpacityComponent(opacity: Float(min(max(opacity, 0), 1))))
        if elapsed >= Timing.fade * 2 {
            root.components.remove(OpacityComponent.self)
            finishTrip(arrival)
        } else {
            phase = .fading(to: arrival, elapsed: elapsed, swapped: didSwap)
        }
    }

    private func floorRest(at cell: GridCell) -> CatRest {
        var landing = rest
        landing.cell = cell
        landing.itemId = nil
        landing.siteId = nil
        landing.action = .sit
        return landing
    }

    private func report() {
        guard isLoaded, reported != status else { return }
        reported = status
        onStatus?(status)
    }

    // MARK: Trips

    private func startTrip() {
        guard let catalog else { return }
        let sample = random()
        let trip = CatRoutine.nextTrip(items: items, from: rest, sample: sample, catalog: catalog, preferring: newcomer,
                                       avoiding: avoiding())
        newcomer = nil
        begin(trip, sample: sample)
    }

    @discardableResult
    private func honorPlay(from landing: CatRest? = nil, floorDistance: Double = 0) -> Bool {
        guard playNeedsUpdate, let catalog else { return false }
        playNeedsUpdate = false
        enjoyingPlayId = nil
        if let landing {
            rest = landing
            restingOn = nil
            root.position = Self.vector(CatRoutine.cellPoint(landing.cell))
        }
        guard let request = currentPlayRequest else {
            if landing != nil || rest.itemId == nil {
                rest.action = .sit
                apply(Arrival(rest: rest, item: nil, position: root.position, yaw: restYaw))
                status = .onFloor(.sit)
                phase = .resting(remaining: Timing.floorRest)
                return true
            }
            return false
        }
        guard let trip = CatRoutine.playTrip(items: items, from: rest, catalog: catalog, request: request) else {
            currentPlayRequest = nil
            if rest.itemId == nil { rest.action = .sit }
            place(at: rest, on: restingOn)
            onPlayRejected?(request.id)
            return true
        }
        newcomer = nil
        begin(trip, sample: 0.5, floorDistance: floorDistance, playRequestId: request.id)
        return true
    }

    private func consumeTreatIfFinished() -> Bool {
        guard let request = currentPlayRequest, request.item.isTreat,
              enjoyingPlayId == request.id, activityTime >= Self.treatDuration else { return false }
        currentPlayRequest = nil
        enjoyingPlayId = nil
        rest.action = .sit
        activityTime = 0
        show(.sit)
        poseAtRest(.sit)
        status = .onFloor(.sit)
        phase = .resting(remaining: Timing.newFurnitureRest)
        onPlayConsumed?(request.id)
        return true
    }

    @discardableResult
    private func honorInvitation(from landing: CatRest? = nil, floorDistance: Double = 0) -> Bool {
        guard let request = invitation, let catalog else { return false }
        invitation = nil
        let origin = landing ?? rest
        guard let trip = CatRoutine.invitedTrip(items: items, from: origin, catalog: catalog,
                                                itemId: request.itemId, siteId: request.siteId, action: request.action) else { return false }
        if let landing {
            rest = landing
            restingOn = nil
            root.position = Self.vector(CatRoutine.cellPoint(landing.cell))
        }
        newcomer = nil
        begin(trip, sample: 0.5, floorDistance: floorDistance)
        return true
    }

    /// Sets off for the cell of a "come here", from where she is or from the floor cell her walk
    /// just reached (`landing`). Unreachable: the request is dropped and she carries on.
    @discardableResult
    private func honorSummon(from landing: CatRest? = nil, floorDistance: Double = 0) -> Bool {
        guard let cell = summon, let catalog else { return false }
        summon = nil
        let origin = landing ?? rest
        guard let trip = CatRoutine.floorTrip(items: items, from: origin, catalog: catalog, to: cell, action: .sit) else { return false }
        if let landing {
            rest = landing
            restingOn = nil
            root.position = Self.vector(CatRoutine.cellPoint(landing.cell))
        }
        newcomer = nil
        begin(trip, sample: 0.5, floorDistance: floorDistance, summoned: true)
        return true
    }

    private func begin(_ trip: CatTrip, sample: Double, floorDistance: Double = 0, playRequestId: UUID? = nil,
                       summoned: Bool = false) {
        enjoyingPlayId = nil
        let item = trip.end.itemId.flatMap { id in items.first { $0.instanceId == id } }
        let end = trip.seat.map(Self.vector) ?? Self.vector(CatRoutine.cellPoint(trip.end.cell))
        let yaw = playRequestId != nil ? Float(trip.rotation)
            : summoned ? Self.cameraYaw
            : item.map { restingYaw(on: $0, front: Float(trip.rotation)) } ?? Self.cameraYaw + Float(sample - 0.5) * 1.4
        let arrival = Arrival(rest: trip.end, item: item, position: end, yaw: yaw, playRequestId: playRequestId,
                              summoned: summoned)
        if let id = rest.itemId, id == trip.end.itemId, rest.siteId == trip.end.siteId {
            arrive(arrival)
            return
        }
        var segments = Self.segments(for: trip, leavingAction: rest.action)
        if rest.itemId == nil, !segments.isEmpty {
            segments[0].from = root.position
            if segments[0].floorDistance > 0 {
                segments[0].floorDistance = Double(simd_distance(root.position, segments[0].to))
            }
        }
        guard !segments.isEmpty else {
            // Boxed in: nowhere to go, so she just shifts her pose where she is.
            apply(arrival)
            finishTrip(arrival)
            return
        }
        if reduceMotion || (groundPlayer == nil && segments.contains { $0.floorDistance > 0 }) {
            // No walk to describe: the caption goes straight to where she ends up.
            phase = .fading(to: arrival, elapsed: 0, swapped: false)
        } else {
            let walk = Walk(segments: segments, completedFloorDistance: floorDistance, arrival: arrival)
            pose(along: walk, delta: 0)
            phase = .walking(walk)
        }
    }

    private static func segments(for trip: CatTrip, leavingAction: CatAction) -> [Segment] {
        guard let first = trip.path.first, let last = trip.path.last else { return [] }
        func access(_ points: [GridPoint], crawling: Bool = false) -> [Segment] {
            zip(points, points.dropFirst()).compactMap { a, b in
                let from = vector(a), to = vector(b), reach = TimeInterval(simd_distance(from, to))
                guard reach > 0.001 else { return nil }
                let jump = !crawling && abs(from.y - to.y) > 0.12
                return Segment(from: from, to: to, jumps: jump,
                               accessDuration: jump ? Timing.jump + Timing.jumpPerCell * reach : max(0.18, 0.52 * reach))
            }
        }
        if let path = trip.sharedAccessPath { return access(path) }
        var legs: [Segment] = []
        if let leaving = trip.leaving {
            legs = access([leaving] + trip.exitVia + [CatRoutine.cellPoint(first)], crawling: leavingAction == .hide)
            if !legs.isEmpty { legs[legs.count - 1].floorEnd = first }
        }
        for (a, b) in zip(trip.path, trip.path.dropFirst()) {
            let from = vector(CatRoutine.cellPoint(a)), to = vector(CatRoutine.cellPoint(b))
            let distance = Double(simd_distance(from, to))
            guard distance > 0 else { continue }
            legs.append(Segment(from: from, to: to, jumps: false,
                                floorDistance: distance, floorEnd: b))
        }
        if let seat = trip.seat { legs += access([CatRoutine.cellPoint(last)] + trip.entryVia + [seat], crawling: trip.end.action == .hide) }
        return legs
    }

    private func arrive(_ arrival: Arrival) {
        apply(arrival)
        finishTrip(arrival)
    }

    private func apply(_ arrival: Arrival) {
        root.position = arrival.position
        root.orientation = simd_quatf(angle: arrival.yaw, axis: [0, 1, 0])
        body.position = .zero
        body.orientation = simd_quatf(angle: 0, axis: [1, 0, 0])
        activityTime = 0
        show(arrival.rest.action.pose)
        poseAtRest(arrival.rest.action, flat: scratchesFlat(at: arrival.rest))
    }

    /// Whether the site she rests at is low: a horizontal board (`paw-flat`), scratched with the
    /// flat forepaw strokes instead of the raised ones, or a toy lying on the floor
    /// (`bat-ground`), batted with the ground paw instead of the raised one.
    private func scratchesFlat(at rest: CatRest) -> Bool {
        guard rest.action == .scratch || rest.action == .play, let itemId = rest.itemId,
              let item = items.first(where: { $0.instanceId == itemId }),
              let model = catalog?.model(id: item.modelId),
              let site = model.interactionSites.first(where: { $0.id == (rest.siteId ?? "seat") }) else { return false }
        return rest.action == .play ? site.batsAtGround : site.scratchesFlat
    }

    private func finishTrip(_ arrival: Arrival) {
        rest = arrival.rest
        restingOn = arrival.item
        restYaw = arrival.yaw
        trips += 1
        if let request = currentPlayRequest, request.id == arrival.playRequestId, !playNeedsUpdate {
            enjoyingPlayId = request.id
            status = .enjoying(request.item)
            phase = .resting(remaining: .infinity)
            return
        }
        if let item = arrival.item {
            let label = catalog?.model(id: item.modelId)?.sites?.first { $0.id == arrival.rest.siteId }?.label
            status = .onFurniture(item.instanceId, arrival.rest.action, label)
        } else {
            status = .onFloor(arrival.rest.action)
        }
        let wait = arrival.summoned ? Timing.summonedRest : arrival.item != nil ? Timing.furnitureRest : Timing.floorRest
        phase = .resting(remaining: newcomer != nil ? Timing.newFurnitureRest : wait)
    }

    /// Puts her at a resting place without any animation.
    private func place(at rest: CatRest, on item: PhotoFurniture?) {
        let seat = item.flatMap { item in catalog.flatMap { CatRoutine.seatPoint(of: item, catalog: $0, siteId: rest.siteId) } }
        let position = seat.map(Self.vector) ?? Self.vector(CatRoutine.cellPoint(rest.cell))
        root.components.remove(OpacityComponent.self)
        apply(Arrival(rest: rest, item: item, position: position, yaw: restYaw))
        if item == nil {
            status = trips == 0 && rest == .atEntrance ? .atEntrance : .onFloor(rest.action)
        }
        let wait = trips == 0 ? Timing.firstRest : Timing.floorRest
        phase = .resting(remaining: newcomer != nil ? Timing.newFurnitureRest : wait)
    }

    /// Which way she faces once settled on a piece. The web cat always faces out of the front,
    /// but she is longer than a seat is deep, so on anything with a backrest that pushes her
    /// hindquarters through it. There she lies along the seat instead, towards whichever end
    /// shows the viewer her face. Stools and tables have no back: she simply faces the viewer.
    /// A bed is longer than she is in every direction and keeps the web's facing.
    private func restingYaw(on item: PhotoFurniture, front: Float) -> Float {
        guard let model = catalog?.model(id: item.modelId), model.sites == nil else { return front }
        switch model.category {
        case .bed, .scratcher, .catTree, .platform, .hideout, .toy, .litterBox, .windowPerch, .water, .photoBoard,
             .bookcase, .sideboard, .mediaConsole, .writingDesk, .vanity, .coatRack, .floorLamp, .roomDivider, .plantStand, .fireplace:
            return front
        case .stool, .table:
            return Self.cameraYaw
        case .chair, .sofa, .bench:
            let ends = [front + .pi / 2, front - .pi / 2]
            return ends.max { cos($0 - Self.cameraYaw) < cos($1 - Self.cameraYaw) } ?? front
        }
    }

    // MARK: Motion

    private func pose(along walk: Walk, delta: TimeInterval) {
        let segment = walk.segments[walk.index]
        let progress = walk.progress
        let t = Float(progress)
        if segment.jumps {
            let hop = CatHop(from: SIMD3<Double>(segment.from), to: SIMD3<Double>(segment.to))
            root.position = SIMD3<Float>(hop.position(at: Double(t)))
        } else {
            root.position = segment.from + (segment.to - segment.from) * t
        }

        let dx = segment.to.x - segment.from.x, dz = segment.to.z - segment.from.z
        if abs(dx) + abs(dz) > 0.05 {
            // Turn towards the direction of travel, quickly but not in a single frame.
            let target = atan2(dx, dz)
            let current = 2 * atan2(root.orientation.imag.y, root.orientation.real)
            var difference = (target - current).truncatingRemainder(dividingBy: 2 * .pi)
            if difference > .pi { difference -= 2 * .pi }
            if difference < -.pi { difference += 2 * .pi }
            let turn = min(1, Float(delta) * 14)
            root.orientation = simd_quatf(angle: current + difference * turn, axis: [0, 1, 0])
        }
        if segment.floorDistance > 0, let groundPlayer {
            body.isEnabled = false
            groundPlayer.entity.isEnabled = true
            groundPlayer.show(groundGait, distance: walk.completedFloorDistance + segment.floorDistance * progress, delta: delta)
            status = .walking(to: walk.arrival.item?.instanceId, gait: groundGait)
        } else {
            show(.loaf)
            if skeletal, let groundPlayer {
                let clip = groundPlayer.has("access_loaf") ? "access_loaf" : "loaf"
                groundPlayer.show(clip: clip, time: 0, delta: delta)
            } else {
                poses[.loaf]?.setWeights(.zero)
                let lean: Float = segment.jumps ? 0.32 : 0
                body.orientation = simd_quatf(angle: -lean * cos(.pi * t), axis: [1, 0, 0])
            }
            status = .walking(to: walk.arrival.item?.instanceId)
        }
        if let request = currentPlayRequest, request.id == walk.arrival.playRequestId {
            status = .following(request.item)
        }
    }

    /// A cat-rig v2 pack: every resting action is a clip on the skinned mesh (docs/CAT_RIG.md).
    private var skeletal: Bool { groundPlayer?.playsActions == true }

    /// Furniture toys present a raised target. Free play supplies its own contact.
    private var playContact: CatPlayItem.Contact { currentPlayRequest?.item.contact ?? .raisedPaw }

    private func clipName(for action: CatAction, flat: Bool) -> String {
        let name: String
        switch action {
        case .sit: name = "sit"
        case .loaf: name = "loaf"
        case .sleep: name = "sleep"
        // A low horizontal board (`paw-flat`) has no upright surface to claw: she treads it instead.
        case .scratch: name = flat && groundPlayer?.has("knead") == true ? "knead" : "scratch"
        case .play: name = flat ? CatPlayItem.Contact.groundPaw.clipName : playContact.clipName
        case .hide: name = "peek_out"
        case .eat: name = CatPlayItem.Contact.muzzle.clipName
        case .drink: name = "drink"
        case .dig: name = "dig"
        }
        return groundPlayer?.has(name) == true ? name : action.pose.rawValue
    }

    private func poseAtRest(_ action: CatAction, flat: Bool = false) {
        if skeletal, let groundPlayer {
            let name = clipName(for: action, flat: flat)
            if reduceMotion {
                groundPlayer.showStill(clip: name)
            } else {
                groundPlayer.show(clip: name, time: activityTime, delta: frameDelta)
            }
            return
        }
        let time = Float(activityTime)
        let weights: BellaPoseWeights
        switch action {
        case .scratch where flat:
            // Paws alternate reaching onto the board and pulling back; neither leaves it entirely.
            let stroke: Float = reduceMotion ? 0.65 : 0.5 + 0.5 * cos(time * 7)
            weights = BellaPoseWeights(flatLeft: 0.4 + 0.6 * stroke, flatRight: 1 - 0.6 * stroke)
        case .scratch:
            let stroke: Float = reduceMotion ? 0.65 : 0.5 + 0.5 * cos(time * 7)
            weights = BellaPoseWeights(leftPaw: 0.28 + 0.72 * stroke, rightPaw: 1 - 0.72 * stroke)
        case .play:
            // A short swipe, then a pause to watch the toy swing.
            let phase = time.truncatingRemainder(dividingBy: 2.4)
            let swipe = max(0, 1 - abs(phase - 0.58) / 0.31)
            let extensionWeight: Float = reduceMotion ? 0.87 : swipe * swipe * (3 - 2 * swipe)
            if playContact == .groundPaw {
                weights = BellaPoseWeights(groundBat: 0.24 + 0.76 * extensionWeight)
            } else {
                weights = BellaPoseWeights(rightPaw: 0.38 * (1 - extensionWeight), bat: extensionWeight)
            }
        case .hide:
            weights = BellaPoseWeights(peek: reduceMotion ? 0.6 : 0.5 + 0.5 * cos(time * 1.4))
        case .eat:
            let settle: Float = reduceMotion ? 1 : min(time / 0.45, 1)
            let nibble = reduceMotion ? 1 : 0.97 + 0.03 * cos(time * 11)
            weights = BellaPoseWeights(eat: settle * nibble)
        case .drink:
            let settle: Float = reduceMotion ? 1 : min(time / 0.45, 1)
            let lap = reduceMotion ? 1 : 0.985 + 0.015 * cos(time * 15)
            weights = BellaPoseWeights(drink: settle * lap)
        case .dig:
            let stroke = reduceMotion ? 0.5 : 0.5 + 0.5 * cos(time * 5.8)
            weights = BellaPoseWeights(digLeft: stroke, digRight: 1 - stroke)
        case .sit, .loaf, .sleep:
            weights = .zero
        }
        poses[action.pose]?.setWeights(weights)
    }

    private func show(_ pose: ArtLibrary.BellaPose) {
        if skeletal, let groundPlayer {
            body.isEnabled = false
            groundPlayer.entity.isEnabled = true
            return
        }
        groundPlayer?.entity.isEnabled = false
        body.isEnabled = true
        guard pose != visiblePose else { return }
        if let visiblePose { poses[visiblePose]?.entity.isEnabled = false }
        poses[pose]?.entity.isEnabled = true
        visiblePose = pose
    }

    private static func vector(_ point: GridPoint) -> SIMD3<Float> {
        [Float(point.x), Float(point.y), Float(point.z)]
    }

    /// What matters to the routine about a piece of furniture; a rename is not a change.
    private struct Footprint: Equatable {
        let id: String, modelId: String, x: Int, z: Int, width: Int, depth: Int, turn: Int

        init(_ item: PhotoFurniture) {
            id = item.instanceId
            modelId = item.modelId
            x = item.x
            z = item.z
            width = item.width
            depth = item.depth
            turn = item.turn
        }
    }
}

extension CatAction {
    var pose: ArtLibrary.BellaPose {
        switch self {
        case .sit, .play, .scratch: .sit
        case .loaf, .hide, .eat, .drink: .loaf
        case .dig: .sit
        case .sleep: .sleep
        }
    }
}
