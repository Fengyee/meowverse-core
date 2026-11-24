import Foundation
import MeowverseCore
import RealityKit

/// Moves the placed toy for the duration of one interaction. Its saved location and links stay intact.
@MainActor
final class WindUpMouse {
    let id: String
    private let entity: Entity
    private let home: Transform
    private let blocked: Set<GridCell>
    private var cell: GridCell
    private var path: [GridCell]
    private var held: TimeInterval = 0

    init?(piece: PhotoFurniture, entity: Entity, items: [PhotoFurniture], bella: BellaActor) {
        guard let start = CatRoutine.accessCell(of: piece, in: items) else { return nil }
        id = piece.instanceId
        self.entity = entity
        let pose = ArtLibrary.pose(of: piece.placement)
        home = Transform(scale: .one, rotation: pose.orientation, translation: pose.position)
        blocked = GridRules.blockedCells(items)
        cell = start
        path = [start]
        entity.stopAllAnimations()
        entity.transform = home
        // The catalog piece fits a 2×2 display footprint. The running toy fits a one-cell passage.
        let extent = entity.visualBounds(relativeTo: entity).extents
        let length = max(extent.x, extent.z)
        if length > 0.85 { entity.scale = SIMD3(repeating: 0.85 / length) }
        bella.play(CatPlayRequest(item: .windUpMouse, cell: start))
    }

    func tick(_ delta: TimeInterval, bella: BellaActor, reduceMotion: Bool) {
        let dt = min(max(delta, 0), 0.1)
        if let next = path.first {
            let point = CatRoutine.cellPoint(next)
            let target = SIMD3<Float>(Float(point.x), 0, Float(point.z))
            let offset = target - entity.position
            let length = simd_length(offset)
            if length > 0.001 { entity.orientation = simd_quatf(angle: atan2(offset.x, offset.z), axis: [0, 1, 0]) }
            let step = Float(dt) * 2.2
            if reduceMotion || length <= step {
                entity.position = target
                cell = next
                path.removeFirst()
            } else {
                entity.position += offset * (step / length)
            }
            return
        }

        // Give the cat time to reach the mouse and bat it before the spring sends it off again.
        guard !reduceMotion, bella.playIsEnjoying else { return }
        held += dt
        guard held >= 1.6 else { return }
        held = 0
        let half = Float(GridRules.size) / 2
        let cat = GridCell(x: Int(floor(bella.root.position.x + half)), z: Int(floor(bella.root.position.z + half)))
        path = CatRoutine.mouseRun(from: cell, awayFrom: cat, blocked: blocked)
        if let goal = path.last { bella.play(CatPlayRequest(item: .windUpMouse, cell: goal)) }
    }

    func putAway() { entity.transform = home }
}
