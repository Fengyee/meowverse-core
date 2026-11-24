import MeowverseCore
import RealityKit
import UIKit

/// Where wall-mounted pieces sit in room space. The walls' inner faces are the planes x = −5
/// (`.left`) and z = −5 (`.back`); a piece's offset counts cells from the corner they share.
nonisolated enum WallGeometry {
    private static let half = Float(GridRules.size) / 2
    /// Height of a wall piece's centre above the floor: clear of most furniture, below the wall top.
    static let centreHeight: Float = 2.0
    static let pieceHeight: Float = 1.15
    /// Wall left bare at each end of a span, so neighbouring pieces do not touch.
    static let inset: Float = 0.12
    /// How far the thickest part of a piece stands out from the wall.
    static let thickness: Float = 0.09

    /// Points into the room.
    static func normal(_ wall: WallSide) -> SIMD3<Float> { wall == .left ? [1, 0, 0] : [0, 0, 1] }

    /// Along the wall, towards larger offsets.
    static func along(_ wall: WallSide) -> SIMD3<Float> { wall == .left ? [0, 0, 1] : [1, 0, 0] }

    /// Turns a piece modelled facing +z so that it faces into the room.
    static func rotation(_ wall: WallSide) -> simd_quatf {
        simd_quatf(angle: wall == .left ? .pi / 2 : 0, axis: [0, 1, 0])
    }

    /// Centre of a span on the wall's inner face.
    static func centre(wall: WallSide, x: Int, width: Int) -> SIMD3<Float> {
        along(wall) * (Float(x) + Float(width) / 2 - half) - normal(wall) * half + [0, centreHeight, 0]
    }

    /// On screen a larger offset runs to the right on the back wall and to the left on the left
    /// wall (see `RoomProjection.right`), so "one cell to the right" depends on the wall.
    static func offsetStep(towardsScreenRight steps: Int, on wall: WallSide?) -> Int {
        wall == .left ? -steps : steps
    }
}

/// The photo board, drawn from boxes: a wooden frame, a cork panel and a few pinned pictures.
/// The pictures are fixed shapes in the room's palette, never the user's photos. The room and
/// the model preview both draw from this one list.
nonisolated enum PhotoBoardDesign {
    /// A box in the board's own frame: origin at the centre of the span on the wall face,
    /// +x to the right as seen from the room, +y up, +z out of the wall.
    struct Box {
        let size: SIMD3<Float>
        let centre: SIMD3<Float>
        /// Rotation about +z, for pictures pinned slightly askew.
        var tilt: Float = 0
        let color: UIColor
        let surface: String
    }

    private static let frameBar: Float = 0.1
    private static let pictureColors: [UInt32] = [0x9db8ce, 0xd9987c, 0xa9b7a0, 0xe9cf8c, 0xb9a3c4]
    private static let pinColors: [UInt32] = [0xc8574a, 0x4f7a8c, 0xe0a83a]
    private static let tilts: [Float] = [-0.1, 0.07, -0.04, 0.12, -0.08]

    static func boxes(width: Int, finish: Finish) -> [Box] {
        let w = Float(width) - 2 * WallGeometry.inset, h = WallGeometry.pieceHeight
        let depth = WallGeometry.thickness
        let wood = ArtLibrary.color([0.69, 0.53, 0.35], materialName: "wood", finish: finish)
        let cork = ArtLibrary.color([0.85, 0.72, 0.55], materialName: "cork", finish: finish)
        var boxes = [
            Box(size: [w - 2 * frameBar, h - 2 * frameBar, 0.04], centre: [0, 0, 0.02], color: cork, surface: "cork"),
            Box(size: [w, frameBar, depth], centre: [0, (h - frameBar) / 2, depth / 2], color: wood, surface: "wood"),
            Box(size: [w, frameBar, depth], centre: [0, -(h - frameBar) / 2, depth / 2], color: wood, surface: "wood"),
            Box(size: [frameBar, h - 2 * frameBar, depth], centre: [(w - frameBar) / 2, 0, depth / 2], color: wood, surface: "wood"),
            Box(size: [frameBar, h - 2 * frameBar, depth], centre: [-(w - frameBar) / 2, 0, depth / 2], color: wood, surface: "wood"),
        ]
        let count = 2 * width - 1
        let pitch = (w - 2 * frameBar) / Float(count)
        for index in 0..<count {
            let portrait = index.isMultiple(of: 2)
            let centre = SIMD2<Float>((Float(index) - Float(count - 1) / 2) * pitch, portrait ? 0.08 : -0.1)
            boxes += picture(size: portrait ? [0.36, 0.46] : [0.44, 0.36], centre: centre,
                             tilt: tilts[index % tilts.count], color: pictureColors[index % pictureColors.count],
                             pin: pinColors[index % pinColors.count])
        }
        return boxes
    }

    /// White paper, a two-tone picture on it and a pin through the top edge.
    private static func picture(size: SIMD2<Float>, centre: SIMD2<Float>, tilt: Float, color: UInt32, pin: UInt32) -> [Box] {
        func placed(_ size: SIMD3<Float>, x: Float, y: Float, z: Float, _ color: UIColor, surface: String = "paper") -> Box {
            let turned = SIMD2(x * cos(tilt) - y * sin(tilt), x * sin(tilt) + y * cos(tilt))
            return Box(size: size, centre: [centre.x + turned.x, centre.y + turned.y, z], tilt: tilt, color: color, surface: surface)
        }
        let margin: Float = 0.035
        let inner = SIMD2<Float>(size.x - 2 * margin, size.y - 3 * margin)
        let ground = inner.y * 0.38
        let tone = rgb(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        tone.getRed(&r, green: &g, blue: &b, alpha: &a)
        let shade = UIColor(red: r * 0.74, green: g * 0.78, blue: b * 0.74, alpha: 1)
        return [
            placed([size.x, size.y, 0.012], x: 0, y: 0, z: 0.047, rgb(0xfbf8f0)),
            placed([inner.x, inner.y, 0.006], x: 0, y: margin / 2, z: 0.056, tone),
            placed([inner.x, ground, 0.006], x: 0, y: margin / 2 - (inner.y - ground) / 2, z: 0.061, shade),
            placed([0.05, 0.05, 0.024], x: 0, y: size.y / 2 - 0.04, z: 0.066, rgb(pin), surface: "pin"),
        ]
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

extension ArtLibrary {
    /// Position and facing of a piece's root entity; `lift` raises a floor piece and brings a
    /// wall piece out from its wall.
    static func pose(of placement: Placement, lift: Float = 0) -> (position: SIMD3<Float>, orientation: simd_quatf) {
        if let wall = placement.wall {
            return (WallGeometry.centre(wall: wall, x: placement.x, width: placement.width) + WallGeometry.normal(wall) * lift,
                    WallGeometry.rotation(wall))
        }
        return (worldPoint(x: placement.x, z: placement.z, width: placement.width, depth: placement.depth, turn: placement.turn) + [0, lift, 0],
                simd_quatf(angle: Float(placement.turn) * .pi / 2, axis: [0, 1, 0]))
    }

    /// The photo board hanging on `placement.wall`.
    func photoBoardEntity(placement: Placement, opacity: Float) -> Entity {
        let root = Entity()
        (root.position, root.orientation) = Self.pose(of: placement)
        for box in PhotoBoardDesign.boxes(width: placement.width, finish: placement.finish) {
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: box.color)
            material.roughness = .init(floatLiteral: 0.85)
            material.metallic = .init(floatLiteral: 0)
            if opacity < 1 { material.blending = .transparent(opacity: .init(floatLiteral: opacity)) }
            let part = ModelEntity(mesh: .generateBox(size: box.size), materials: [material])
            part.name = box.surface
            part.position = box.centre
            part.orientation = simd_quatf(angle: box.tilt, axis: [0, 0, 1])
            root.addChild(part)
        }
        // One box for picking: the whole span, a little proud of the wall.
        let shape = ShapeResource.generateBox(size: [Float(placement.width) - 0.1, WallGeometry.pieceHeight, 0.2])
            .offsetBy(translation: [0, 0, 0.1])
        root.components.set(CollisionComponent(shapes: [shape]))
        return root
    }
}
