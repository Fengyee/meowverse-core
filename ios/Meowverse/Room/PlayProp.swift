import MeowverseCore
import RealityKit
import UIKit

/// Original miniature props, assembled once and retained while the interaction changes targets.
final class PlayProp {
    let root = Entity()

    private struct Assembly {
        let entity: Entity
        let moving: Entity
        var bites: [Entity] = []
    }

    private var cache: [CatPlayItem: Assembly] = [:]
    private var selected: CatPlayItem?
    private var shown: Assembly?
    private var phase: TimeInterval = 0

    init() {
        root.name = "play-prop"
        root.isEnabled = false
    }

    func show(_ item: CatPlayItem, at point: SIMD3<Float>) {
        root.position = point
        root.isEnabled = true
        guard selected != item else { return }
        shown?.entity.removeFromParent()
        let assembly = cache[item] ?? make(item)
        cache[item] = assembly
        shown = assembly
        selected = item
        phase = 0
        assembly.moving.transform = .identity
        for bite in assembly.bites {
            bite.isEnabled = true
            bite.scale = SIMD3(repeating: 1)
        }
        root.addChild(assembly.entity)
    }

    /// `time` is the frame delta in seconds, so sheets and backgrounding preserve the phase.
    func update(time: TimeInterval, progress: Double?, active: Bool, reduceMotion: Bool) {
        guard let selected, let shown, active else { return }
        phase += min(max(time, 0), 0.05)
        if selected.isTreat {
            consume(shown.bites, progress: progress ?? 0)
            return
        }
        let wave = reduceMotion ? Float(0) : sin(Float(phase) * 2.7)
        let angle: Float = selected == .featherWand ? wave * 0.10 : wave * 0.06
        shown.moving.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
    }

    func clear() {
        shown?.entity.removeFromParent()
        selected = nil
        shown = nil
        phase = 0
        root.isEnabled = false
    }

    private func consume(_ bites: [Entity], progress: Double) {
        let progress = min(max(progress, 0), 1)
        for (index, bite) in bites.enumerated() {
            let eaten = min(max(progress * Double(bites.count) - Double(index), 0), 1)
            bite.isEnabled = eaten < 1
            bite.scale = SIMD3(repeating: Float(1 - 0.7 * eaten))
        }
    }

    private func make(_ item: CatPlayItem) -> Assembly {
        let entity = Entity(), moving = Entity()
        entity.addChild(moving)
        switch item {
        case .toyMouse, .windUpMouse: mouse(in: moving)
        case .toyBall: ball(in: moving)
        case .featherWand: wand(in: moving)
        case .treatSalmon: return Assembly(entity: entity, moving: moving, bites: salmon(in: moving))
        case .treatChicken: return Assembly(entity: entity, moving: moving, bites: chicken(in: moving))
        case .treatBiscuit: return Assembly(entity: entity, moving: moving, bites: biscuits(in: moving))
        }
        return Assembly(entity: entity, moving: moving)
    }

    private func mouse(in parent: Entity) {
        PlayShape.ellipsoid([0.15, 0.11, 0.23], at: [0, 0.115, 0], color: 0xc7b1a1, in: parent)
        PlayShape.ellipsoid([0.095, 0.085, 0.12], at: [0, 0.105, 0.19], color: 0xc7b1a1, in: parent)
        for x: Float in [-0.085, 0.085] {
            PlayShape.ellipsoid([0.062, 0.071, 0.027], at: [x, 0.225, 0.11], color: 0xb69b88, in: parent)
            PlayShape.ellipsoid([0.039, 0.047, 0.014], at: [x, 0.23, 0.131], color: 0xe6ad9e, in: parent)
            PlayShape.ellipsoid([0.018, 0.021, 0.016], at: [x * 0.70, 0.145, 0.267], color: 0x343d3c, in: parent)
        }
        PlayShape.ellipsoid([0.031, 0.024, 0.025], at: [0, 0.103, 0.307], color: 0xd68f87, in: parent)
        PlayShape.curve([
            [0, 0.075, -0.20], [-0.10, 0.05, -0.31], [-0.21, 0.036, -0.38],
            [-0.29, 0.036, -0.35], [-0.33, 0.036, -0.27],
        ], radius: 0.014, color: 0xc59b8b, in: parent)
        PlayShape.curve([[0, 0.205, -0.09], [0, 0.225, 0.02], [0, 0.20, 0.12]],
                        radius: 0.004, color: 0xe7d8ca, in: parent)
    }

    private func ball(in parent: Entity) {
        PlayShape.ellipsoid([0.18, 0.18, 0.18], at: [0, 0.184, 0], color: 0x7faaa0, in: parent)
        for angle: Float in [0, 2.094, 4.189] {
            let patch = PlayShape.ellipsoid([0.08, 0.13, 0.024],
                                            at: [sin(angle) * 0.158, 0.184, cos(angle) * 0.158],
                                            color: 0xeabda1, in: parent)
            patch.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
        }
        PlayShape.ellipsoid([0.064, 0.009, 0.064], at: [0, 0.36, 0], color: 0xf0dfc8, in: parent)
    }

    private func wand(in parent: Entity) {
        PlayShape.rod(from: [-0.35, 0.04, -0.27], to: [0.15, 1.49, -0.17], radius: 0.025,
                      color: 0xbf9367, in: parent)
        PlayShape.rod(from: [-0.35, 0.04, -0.27], to: [-0.25, 0.33, -0.25], radius: 0.036,
                      color: 0x698f88, in: parent)
        PlayShape.curve([[0.15, 1.49, -0.17], [0.25, 1.49, -0.10], [0.30, 1.39, -0.03],
                         [0.28, 1.20, 0], [0.17, 1.04, 0], [0, 0.94, 0]],
                        radius: 0.009, color: 0xa29583, in: parent)
        PlayShape.ellipsoid([0.034, 0.046, 0.034], at: [0, 0.94, 0], color: 0xc6a36f, in: parent)
        feather(at: [-0.035, 0.82, 0], angle: -0.40, color: 0xe5b093, in: parent)
        feather(at: [0.035, 0.82, 0.015], angle: 0.35, color: 0x8ab4aa, in: parent)
        feather(at: [0, 0.80, 0.035], angle: 0.05, color: 0xe8d7ad, in: parent)
    }

    private func feather(at center: SIMD3<Float>, angle: Float, color: UInt32, in parent: Entity) {
        let feather = Entity()
        feather.position = center
        feather.orientation = simd_quatf(angle: angle, axis: [0, 0, 1])
        parent.addChild(feather)
        PlayShape.ellipsoid([0.055, 0.17, 0.017], at: .zero, color: color, in: feather)
        PlayShape.rod(from: [0, -0.17, 0.019], to: [0, 0.19, 0.019], radius: 0.004,
                      color: 0xf3e8cd, in: feather)
        for index in 0..<4 {
            let y = Float(index) * 0.055 - 0.11
            for side: Float in [-1, 1] {
                PlayShape.rod(from: [0, y, 0.02], to: [side * 0.043, y + 0.035, 0.02], radius: 0.0025,
                              color: 0xf3e8cd, in: feather)
            }
        }
    }

    private func salmon(in parent: Entity) -> [Entity] {
        let positions: [SIMD3<Float>] = [[0, 0.022, 0], [-0.17, 0.022, -0.14], [0.15, 0.022, 0.12]]
        return positions.enumerated().map { index, point in
            let bite = Entity()
            bite.position = point
            bite.orientation = simd_quatf(angle: Float(index - 1) * 0.45, axis: [0, 1, 0])
            parent.addChild(bite)
            PlayShape.box([0.17, 0.04, 0.21], at: .zero, radius: 0.016, color: 0xe7936f, in: bite)
            for stripe in 0..<3 {
                let z = Float(stripe) * 0.051 - 0.051
                let vein = PlayShape.box([0.145, 0.004, 0.012], at: [0, 0.022, z],
                                         radius: 0.003, color: 0xf8d9b7, in: bite)
                vein.orientation = simd_quatf(angle: -0.23, axis: [0, 1, 0])
            }
            return bite
        }
    }

    private func chicken(in parent: Entity) -> [Entity] {
        let positions: [SIMD3<Float>] = [[0, 0.022, 0], [-0.17, 0.022, 0.10], [0.15, 0.022, -0.12]]
        return positions.enumerated().map { index, point in
            let bite = Entity()
            bite.position = point
            bite.orientation = simd_quatf(angle: Float(index) * 0.7, axis: [0, 1, 0])
            parent.addChild(bite)
            PlayShape.box([0.15, 0.04, 0.12], at: .zero, radius: 0.016, color: 0xe9c897, in: bite)
            for line in 0..<2 {
                PlayShape.box([0.008, 0.003, 0.085], at: [Float(line) * 0.052 - 0.026, 0.022, 0],
                              radius: 0.002, color: 0xf8e4c4, in: bite)
            }
            return bite
        }
    }

    private func biscuits(in parent: Entity) -> [Entity] {
        let positions: [SIMD3<Float>] = [[0, 0.023, 0], [-0.18, 0.023, -0.13], [0.18, 0.023, 0.12]]
        return positions.enumerated().map { index, point in
            let bite = Entity()
            bite.position = point
            bite.orientation = simd_quatf(angle: Float(index - 1) * 0.75, axis: [0, 1, 0])
            parent.addChild(bite)
            PlayShape.ellipsoid([0.085, 0.025, 0.13], at: .zero, color: 0xcfa169, in: bite)
            for x: Float in [-0.043, 0.043] {
                let fin = PlayShape.box([0.072, 0.036, 0.11], at: [x, 0, -0.12],
                                        radius: 0.018, color: 0xcfa169, in: bite)
                fin.orientation = simd_quatf(angle: x < 0 ? -0.5 : 0.5, axis: [0, 1, 0])
            }
            PlayShape.ellipsoid([0.012, 0.003, 0.012], at: [0, 0.025, 0.065], color: 0x926b43, in: bite)
            for z: Float in [-0.025, 0.015] {
                PlayShape.box([0.075, 0.003, 0.007], at: [0, 0.025, z],
                              radius: 0.002, color: 0xe4bd87, in: bite)
            }
            return bite
        }
    }
}

private enum PlayShape {
    static func material(_ hex: UInt32) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(hex: hex))
        material.roughness = .init(floatLiteral: 0.82)
        material.metallic = .init(floatLiteral: 0)
        return material
    }

    @discardableResult
    static func ellipsoid(_ radii: SIMD3<Float>, at point: SIMD3<Float>, color: UInt32, in parent: Entity) -> Entity {
        let entity = ModelEntity(mesh: .generateSphere(radius: 1), materials: [material(color)])
        entity.position = point
        entity.scale = radii
        parent.addChild(entity)
        return entity
    }

    @discardableResult
    static func box(_ size: SIMD3<Float>, at point: SIMD3<Float>, radius: Float, color: UInt32, in parent: Entity) -> Entity {
        let corner = min(radius, min(size.x, size.y, size.z) * 0.49)
        let entity = ModelEntity(mesh: .generateBox(size: size, cornerRadius: corner), materials: [material(color)])
        entity.position = point
        parent.addChild(entity)
        return entity
    }

    static func rod(from start: SIMD3<Float>, to end: SIMD3<Float>, radius: Float, color: UInt32, in parent: Entity) {
        let direction = end - start, length = simd_length(direction)
        let entity = ModelEntity(mesh: .generateCylinder(height: length, radius: radius), materials: [material(color)])
        entity.position = (start + end) / 2
        entity.orientation = simd_quatf(from: [0, 1, 0], to: direction / length)
        parent.addChild(entity)
    }

    static func curve(_ points: [SIMD3<Float>], radius: Float, color: UInt32, in parent: Entity) {
        for (start, end) in zip(points, points.dropFirst()) {
            rod(from: start, to: end, radius: radius, color: color, in: parent)
        }
        for point in points.dropFirst().dropLast() {
            ellipsoid(SIMD3(repeating: radius), at: point, color: color, in: parent)
        }
    }
}
