import MeowverseCore
import OSLog
import RealityKit
import UIKit

/// The shell has independent materials so a new wallpaper never replaces furniture or the cat.
/// Each theme brings a whole-room floor, one wallpaper for both walls (already coloured, so it is
/// drawn untinted) and a plain wall colour for the wall's top, its outer faces and plain walls.
final class RoomShellAppearance {
    private let floor: ModelEntity
    private var floorOcclusion: TextureResource?
    var hasFloorOcclusion: Bool { floorOcclusion != nil }
    private let plinth: ModelEntity
    private let left: ModelEntity
    private let back: ModelEntity
    private let wallFaces: [ModelEntity]
    private let sun = DirectionalLight()
    private let fill = DirectionalLight()
    private var current: RoomAppearance?
    private var currentLight: RoomLightPhase?
    private var currentBackground: UIColor?
    /// The backdrop as one colour, for the postcard, which has no painting behind it.
    private(set) var solidBackdrop = UIColor(hex: RoomTheme.creamOak.art.dayPaper)

    init() {
        let side = Float(GridRules.size)
        let span = RoomShellSize.plinthSpan
        let offset = side / 2
        floor = ModelEntity(mesh: .generatePlane(width: side, depth: side))
        floor.position.y = 0.002
        plinth = ModelEntity(mesh: .generateBox(size: [span, RoomShellSize.plinthDepth, span]))
        plinth.position = [0, -RoomShellSize.plinthDepth / 2, 0]
        left = ModelEntity(mesh: .generateBox(size: [0.24, 3.55, span]))
        left.position = [-offset - 0.12, 1.6, 0]
        back = ModelEntity(mesh: .generateBox(size: [span, 3.55, 0.24]))
        back.position = [0, 1.6, -offset - 0.12]
        // A single rectangular UV face preserves the motif's proportions on each wall.
        let mesh = MeshResource.generatePlane(width: side, height: 3.36)
        let leftPaper = ModelEntity(mesh: mesh)
        leftPaper.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
        leftPaper.position = [-offset + 0.003, 1.69, 0]
        let backPaper = ModelEntity(mesh: mesh)
        backPaper.position = [0, 1.69, -offset + 0.003]
        wallFaces = [leftPaper, backPaper]
    }

    /// `lights`: where the sun and fill hang. Directional lights only need to turn with the room;
    /// `shadowReach` is in the units of that parent (cells in the app, metres on a table in AR).
    func install(on parent: Entity, lights: Entity, shadowReach: Float) {
        parent.addChild(plinth)
        parent.addChild(floor)
        parent.addChild(left)
        parent.addChild(back)
        for face in wallFaces {
            face.isEnabled = false
            parent.addChild(face)
        }
        sunShadow = DirectionalLightComponent.Shadow(maximumDistance: shadowReach, depthBias: 3)
        sun.shadow = sunShadow
        sun.look(at: .zero, from: [3, 12, 7], relativeTo: nil)
        fill.look(at: [0, 1, 0], from: [12, 5, 1], relativeTo: nil)
        lights.addChild(sun)
        lights.addChild(fill)
    }

    /// The sun's shadow as `install` set it up; 画质「低」 turns it off (`setSunShadows`).
    private(set) var sunShadow: DirectionalLightComponent.Shadow?
    /// The sun, so the postcard can give its copy the full shadow back.
    var sunLight: DirectionalLight { sun }
    var castsSunShadows: Bool { sun.components.has(DirectionalLightComponent.Shadow.self) }

    /// Through the component set: `sun.shadow = nil` still read back as set (iOS 27.2 simulator,
    /// read back with `-MeowverseQualityProbe`).
    func setSunShadows(_ on: Bool) {
        guard castsSunShadows != on else { return }
        if on, let sunShadow {
            sun.components.set(sunShadow)
        } else {
            sun.components.remove(DirectionalLightComponent.Shadow.self)
        }
    }

    /// `seeThrough`: the view is transparent and the room page paints the backdrop behind it.
    /// `cameraFeed`: AR, the camera's picture is the background and stays.
    func apply(_ appearance: RoomAppearance, lightPhase: RoomLightPhase, to view: ARView, seeThrough: Bool = false,
               cameraFeed: Bool = false) {
        solidBackdrop = appearance.backdrop(in: lightPhase)
        let background = seeThrough ? UIColor.clear : solidBackdrop
        if !cameraFeed, currentBackground != background {
            // With the tone curve the paper is painted behind the 3D, so the curve leaves it alone.
            let paintedBehind = seeThrough || RoomLook.current != nil
            view.environment.background = .color(paintedBehind ? .clear : background)
            view.backgroundColor = paintedBehind ? background : nil
            view.isOpaque = !paintedBehind
            currentBackground = background
        }
        if currentLight != lightPhase {
            lightPhase.apply(to: sun, fill: fill)
            // Not on a table: AR has no tone curve to bring the headroom back.
            if !cameraFeed { RoomLook.current?.light(view, sun: sun, fill: fill, phase: lightPhase) }
            currentLight = lightPhase
        }
        guard current != appearance else { return }
        let themeChanged = current?.theme != appearance.theme
        current = appearance
        let theme = appearance.theme
        let textures = Self.textures(for: theme)
        if themeChanged {
            var ground = PhysicallyBasedMaterial()
            ground.roughness = 0.94
            if let texture = textures.floor {
                ground.baseColor = .init(texture: .init(texture))
            } else {
                ground.baseColor = .init(tint: UIColor(hex: theme.art.floor))
            }
            ground.ambientOcclusion = .init(texture: floorOcclusion.map { .init($0) })
            floor.model?.materials = [ground]
            plinth.model?.materials = [Self.paint(theme.art.floor)]
            let edge = Self.paint(theme.art.wall)
            left.model?.materials = [edge]
            back.model?.materials = [edge]
        }
        let paper = appearance.plainWalls ? nil : textures.wall
        for face in wallFaces {
            face.isEnabled = paper != nil
            if let paper {
                var material = Self.paint(0xffffff)
                material.baseColor.texture = .init(paper)
                face.model?.materials = [material]
            }
        }
    }

    func setFloorOcclusion(_ texture: TextureResource?) {
        guard floorOcclusion !== texture else { return }
        floorOcclusion = texture
        Self.applyFloorOcclusion(texture, to: floor)
    }

    func isFloor(_ entity: Entity) -> Bool { entity === floor }

    static func applyFloorOcclusion(_ texture: TextureResource?, to entity: Entity) {
        guard let floor = entity as? ModelEntity, var model = floor.model,
              var ground = model.materials.first as? PhysicallyBasedMaterial else { return }
        ground.ambientOcclusion = .init(texture: texture.map { .init($0) })
        model.materials = [ground]
        floor.model = model
    }

    private static func paint(_ hex: UInt32) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.roughness = 0.9
        material.metallic = .init(floatLiteral: 0)
        material.baseColor = .init(tint: UIColor(hex: hex))
        return material
    }

    // MARK: Textures

    /// Only the shown theme's textures stay loaded (about 6 MB with mipmaps); the dressing tray
    /// loads the next one as a chip is tapped.
    private static var loaded: (theme: RoomTheme, floor: TextureResource?, wall: TextureResource?)?

    static func textures(for theme: RoomTheme) -> (floor: TextureResource?, wall: TextureResource?) {
        if let loaded, loaded.theme == theme { return (loaded.floor, loaded.wall) }
        let started = ContinuousClock.now
        let floor = texture(theme.resource("floor"))
        let wall = texture(theme.resource("wall"))
        loaded = (theme, floor, wall)
        Logger(subsystem: "Meowverse", category: "room-theme")
            .notice("Loaded \(theme.rawValue, privacy: .public) textures in \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        return (floor, wall)
    }

    private static func texture(_ url: URL?) -> TextureResource? {
        guard let image = RoomThemeImages.cgImage(url) else { return nil }
        return try? TextureResource.generate(from: image, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
    }
}
