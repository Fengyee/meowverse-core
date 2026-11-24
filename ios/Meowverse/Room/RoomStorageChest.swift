import MeowverseCore
import RealityKit
import UIKit

/// A freestanding treasure chest beside the open right-hand edge of the miniature.
enum RoomStorageChest {
    static let position = SIMD3<Float>(Float(GridRules.size) / 2 + 3.15, -0.30, 2.85)
    static let halfWidth: Float = 1.15
    static let halfDepth: Float = 0.76
    static let height: Float = 1.48

    static let surfaceID = "storage-chest"

    private struct Surface {
        let material: PhysicallyBasedMaterial
        let slot: String
    }

    @MainActor static func make() -> Entity {
        let root = Entity()
        root.name = "storage-chest"
        root.position = position

        func finish(_ color: UInt32, metal: Float = 0, slot: String = "wood") -> Surface {
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: UIColor(hex: color))
            m.metallic = .init(floatLiteral: metal)
            m.roughness = .init(floatLiteral: metal > 0 ? 0.54 : 0.86)
            return Surface(material: m, slot: slot)
        }
        let walnut = finish(0x6c4336), rosewood = finish(0xa35b43), cedar = finish(0xba744f)
        let brass = finish(0xe6b459, metal: 0.28, slot: "metal"), highlight = finish(0xffda83, metal: 0.20, slot: "metal")
        let enamel = finish(0x426f65, slot: "enamel")
        func part(_ mesh: MeshResource, _ surface: Surface,
                  at: SIMD3<Float>, scale: SIMD3<Float> = SIMD3(repeating: 1), angle: Float = 0) {
            let piece = ModelEntity(mesh: mesh, materials: [surface.material])
            piece.name = surface.slot
            piece.position = at
            piece.scale = scale
            piece.orientation = simd_quatf(angle: angle, axis: [0, 0, 1])
            root.addChild(piece)
        }
        func box(_ size: SIMD3<Float>, _ surface: Surface, at: SIMD3<Float>, radius: Float) {
            part(.generateBox(size: size, cornerRadius: radius), surface, at: at)
        }

        box([2.22, 0.16, 1.26], walnut, at: [0, 0.10, 0], radius: 0.05)
        box([2.20, 0.79, 1.23], rosewood, at: [0, 0.52, 0], radius: 0.08)
        let barrel = MeshResource.generateCylinder(height: 1, radius: 1)
        // The lower half of the barrel nestles into the body, leaving the arched lid visible.
        part(barrel, cedar, at: [0, 0.87, 0], scale: [0.57, 2.22, 0.62], angle: .pi / 2)
        box([halfWidth * 2, 0.105, 1.33], walnut, at: [0, 0.87, 0], radius: 0.035)
        for x: Float in [-0.73, 0.73] {
            part(barrel, brass, at: [x, 0.87, 0], scale: [height - 0.87, 0.16, 0.65], angle: .pi / 2)
            for z: Float in [-0.62, 0.62] {
                box([0.16, 0.77, 0.08], brass, at: [x, 0.51, z], radius: 0.035)
            }
        }
        let sphere = MeshResource.generateSphere(radius: 1)
        part(sphere, brass, at: [0, 0.83, 0.63], scale: [0.255, 0.25, 0.085])
        part(sphere, enamel, at: [0, 0.83, 0.688], scale: [0.198, 0.194, 0.042])
        part(sphere, highlight, at: [0, 0.80, 0.73], scale: [0.091, 0.071, 0.021])
        let toes: [(Float, Float)] = [(-0.10, 0.87), (0, 0.91), (0.10, 0.87)]
        for (x, y) in toes {
            part(sphere, highlight, at: [x, y, 0.728], scale: [0.042, 0.048, 0.018])
        }
        return root
    }
}
