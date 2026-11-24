import Foundation
import simd

/// The room's base and walls in room units (one cell = 1), as `RoomShellAppearance` builds them.
public enum RoomShellSize {
    /// The plinth is the floor plus a 0.15 rim on every side.
    public static let plinthSpan = Float(GridRules.size) + 0.3
    /// The plinth's top is the floor (y = 0); its underside is this far below.
    public static let plinthDepth: Float = 0.36
    /// Where the app's fixed camera stands, seen from above (`RoomProjection.position` x and z):
    /// the open corner of the room, the side all furniture is drawn for.
    public static let designedEye = SIMD2<Float>(14, 17)
}

/// What 互动 shows for "放到桌上看看".
public enum ARTabletopEntry: Equatable, Sendable {
    /// The device cannot track the world (the simulator, the iPad app on a Mac). AR is a side
    /// feature, so there is no row rather than a row that can never work.
    case hidden
    case available
    /// Camera access is off. The row stays, and the page says how to turn it on.
    case cameraOff
}

public enum ARCameraAccess: Sendable {
    case undetermined, allowed, denied, restricted
}

/// The one line of guidance on the AR page.
public enum ARTabletopHint: Equatable, Sendable {
    case lookForSurface
    /// No surface after `ARTabletop.slowSearch`: a brighter table with some texture.
    case tryAnotherSurface
    case tapToPlace
    case placed
    /// The session lost the camera (another app took it, iPad multitasking).
    case interrupted
    /// The phone is running hot: the cat rests until it cools down.
    case tooWarm
}

public enum ARTabletop {
    public static func entry(worldTracking: Bool, camera: ARCameraAccess) -> ARTabletopEntry {
        guard worldTracking else { return .hidden }
        switch camera {
        case .denied, .restricted: return .cameraOff
        case .undetermined, .allowed: return .available
        }
    }

    /// How long the page looks for a surface before suggesting another one.
    public static let slowSearch = Duration.seconds(15)

    public static func hint(surfaceFound: Bool, placed: Bool, interrupted: Bool, tooWarm: Bool,
                            searchedLong: Bool = false) -> ARTabletopHint {
        if interrupted { return .interrupted }
        if tooWarm { return .tooWarm }
        if placed { return .placed }
        if surfaceFound { return .tapToPlace }
        return searchedLong ? .tryAnotherSurface : .lookForSurface
    }

    /// Where a ray from the camera meets the horizontal plane at `planeY`, in world metres.
    /// nil when it runs level with the plane, away from it, or meets it further than
    /// `maxDistance` (a finger dragged towards the horizon would fling the room away).
    public static func floorHit(origin: SIMD3<Float>, direction: SIMD3<Float>, planeY: Float,
                                maxDistance: Float = 5) -> SIMD3<Float>? {
        let length = simd_length(direction)
        guard length > 0, length.isFinite else { return nil }
        let unit = direction / length
        guard abs(unit.y) > 1e-4 else { return nil }
        let distance = (planeY - origin.y) / unit.y
        guard distance > 0, distance <= maxDistance else { return nil }
        var hit = origin + unit * distance
        hit.y = planeY
        return hit
    }
}

/// The room as a model on a table: where its plinth stands, which way it turns and how big it
/// is. The room's own coordinates (cells, floor centre at the origin) are scaled, turned about
/// the vertical and moved so the plinth's underside rests on `base`.
public struct ARTabletopPose: Equatable, Sendable {
    /// The centre of the plinth's underside, in world metres.
    public var base: SIMD3<Float>
    /// Turn about the vertical, in radians, as `simd_quatf(angle:axis: [0, 1, 0])`.
    public var yaw: Float
    /// The plinth's width across, in metres.
    public var edge: Float

    /// About 36 cm across: a model that fits on a coffee table (product brief: 30–40 cm).
    public static let defaultEdge: Float = 0.36
    /// No life-size room in the first version; never so small a piece cannot be tapped.
    public static let edges: ClosedRange<Float> = 0.15...1.2

    public init(base: SIMD3<Float>, yaw: Float, edge: Float = defaultEdge) {
        self.base = base
        self.yaw = yaw
        self.edge = min(max(edge, Self.edges.lowerBound), Self.edges.upperBound)
    }

    /// Put down at `hit` with the open corner, the side the furniture is drawn for, towards
    /// the phone at `camera`.
    public static func placed(at hit: SIMD3<Float>, facing camera: SIMD3<Float>) -> Self {
        let dx = camera.x - hit.x, dz = camera.z - hit.z
        let toCamera = dx * dx + dz * dz > 1e-8 ? atan2(dx, dz) : 0
        let designed = atan2(RoomShellSize.designedEye.x, RoomShellSize.designedEye.y)
        return Self(base: hit, yaw: toCamera - designed)
    }

    /// Metres per room unit (cell).
    public var scale: Float { edge / RoomShellSize.plinthSpan }
    public var rotation: simd_quatf { simd_quatf(angle: yaw, axis: [0, 1, 0]) }
    /// Where the room's origin, the centre of its floor, stands in the world.
    public var translation: SIMD3<Float> { base + [0, RoomShellSize.plinthDepth * scale, 0] }

    /// A point of the room, in room units, in world metres.
    public func world(_ local: SIMD3<Float>) -> SIMD3<Float> {
        translation + rotation.act(local * scale)
    }

    /// Pinch: scales about the plinth, which stays on the table. A factor that is not a
    /// positive finite number changes nothing.
    public func scaled(by factor: Float) -> Self {
        guard factor.isFinite, factor > 0 else { return self }
        return Self(base: base, yaw: yaw, edge: edge * factor)
    }

    public func turned(by radians: Float) -> Self {
        guard radians.isFinite else { return self }
        return Self(base: base, yaw: yaw + radians, edge: edge)
    }

    /// Drag: carried by the finger's way across the table, never up or down.
    public func moved(from start: SIMD3<Float>, to end: SIMD3<Float>) -> Self {
        let delta = end - start
        guard delta.x.isFinite, delta.z.isFinite else { return self }
        return Self(base: base + [delta.x, 0, delta.z], yaw: yaw, edge: edge)
    }
}
