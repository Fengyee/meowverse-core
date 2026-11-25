import ImageIO
import MeowverseCore
import OSLog
import RealityKit
import UIKit

/// Decoded art from `Resources/Art` (see art-provenance.json for sources, hashes and licences).
/// Geometry and transforms mirror the web renderer so both builds show the same room.
final class ArtLibrary {
    nonisolated enum ArtError: Error { case missing(String) }

    let catalog: FurnitureCatalog
    let attribution: String
    /// Palette looks of the v2 furniture library; empty if the file is missing (v1 tints apply).
    let looks: FurnitureLooks
    private let baseColors = FurnitureBaseColors()
    private let surfaceMaps = FurnitureSurfaceMaps()

    struct FurnitureDetails: Equatable {
        var textureLimit: Int
        var surfaceMaps: Bool

        static let full = Self(textureLimit: FurnitureBaseColors.fullSize, surfaceMaps: true)
        static let flat = Self(textureLimit: 0, surfaceMaps: false)
    }
    private var furnitureParts: [String: [FurniturePart]] = [:]
    private var lastPartLoad: Task<[FurniturePart], Error>?
    private var partLoads: [String: Task<[FurniturePart], Error>] = [:]
    private var patternLoads: [String: Task<TextureResource, Error>] = [:]
    private var catResources: CatArt?
    /// Composed pattern tiles, keyed by pattern file and layer colours.
    private var patternTiles: [String: TextureResource] = [:]

    /// Removed in `deinit`: a portrait makes its own short-lived library.
    nonisolated(unsafe) private var memoryWarnings: (any NSObjectProtocol)?

    init() throws {
        catalog = try FurnitureCatalog.bundled()
        attribution = (try? String(decoding: Self.data("ATTRIBUTION", "txt"), as: UTF8.self)) ?? ""
        looks = FurnitureLooks.bundled
        memoryWarnings = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseCaches() }
        }
    }

    deinit {
        if let memoryWarnings { NotificationCenter.default.removeObserver(memoryWarnings) }
    }

    /// Low memory (G24-02): forget the decoded meshes and composed pattern tiles kept for reuse.
    /// Pieces already in a room keep theirs; the next piece of that model decodes it again.
    /// Loads in flight are left to finish.
    func releaseCaches() {
        furnitureParts.removeAll()
        patternTiles.removeAll()
    }

    nonisolated static func data(_ name: String, _ ext: String) throws -> Data {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { throw ArtError.missing("\(name).\(ext)") }
        return try Data(contentsOf: url)
    }

    // MARK: Furniture

    private struct FurniturePart {
        let mesh: MeshResource
        let material: FurnitureMesh.Material
        let toyPivot: SIMD3<Float>?
        let hasOcclusion: Bool
    }

    struct Fit {
        let scale: Float
        let offset: SIMD3<Float>
        let height: Float
    }

    /// `fitModel` in src/domain/grid/world.ts.
    static func fit(_ model: CatalogModel, width: Int, depth: Int) -> Fit {
        let min = model.bounds.min.map(Float.init), max = model.bounds.max.map(Float.init)
        func ratio(_ w: Int, _ d: Int) -> Float {
            Swift.min((Float(w) - 0.16) / (max[0] - min[0]), (Float(d) - 0.16) / (max[2] - min[2]))
        }
        let base = ratio(model.defaultSize[0], model.defaultSize[1])
        // Never larger than at the default size: a bigger footprint centres the model in it
        // instead of growing it (a grown fountain bowl would swallow Bella's legs).
        let scale = Swift.min(base, 1.0 / 3.0) * Swift.min(1, ratio(width, depth) / base)
        return Fit(
            scale: scale,
            offset: [-(min[0] + max[0]) / 2, -min[1], -(min[2] + max[2]) / 2],
            height: (max[1] - min[1]) * scale)
    }

    static func rotatedSize(width: Int, depth: Int, turn: Int) -> (w: Float, d: Float) {
        turn % 2 == 1 ? (Float(depth), Float(width)) : (Float(width), Float(depth))
    }

    /// Centre of the footprint on the floor, room centred on the origin.
    static func worldPoint(x: Int, z: Int, width: Int, depth: Int, turn: Int) -> SIMD3<Float> {
        let size = rotatedSize(width: width, depth: depth, turn: turn)
        let half = Float(GridRules.size) / 2
        return [Float(x) + size.w / 2 - half, 0, Float(z) + size.d / 2 - half]
    }

    /// world = T(worldPoint) · Ry(turn·π/2) · S(s) · Ry(orientationY) · T(offset) · v
    /// A wall model has no baked mesh: it is drawn by `photoBoardEntity`, on the back wall while
    /// its placement names none yet.
    func furnitureEntity(model: CatalogModel, placement: Placement, opacity: Float = 1,
                         details: FurnitureDetails = .full,
                         occlusion: Bool = true) async throws -> Entity {
        if model.mount == .wall {
            var hung = placement
            hung.wall = placement.wall ?? .back
            let board = photoBoardEntity(placement: hung, opacity: opacity)
            if details.surfaceMaps {
                try await applyFurnitureDetails(to: board, placement: hung, details: details)
            }
            return board
        }
        let parts = try await parts(for: model)
        try Task.checkCancellation()
        let fit = Self.fit(model, width: placement.width, depth: placement.depth)
        let root = Entity()
        (root.position, root.orientation) = Self.pose(of: placement)

        let scaled = Entity()
        scaled.scale = SIMD3(repeating: fit.scale)
        scaled.orientation = simd_quatf(angle: Float(model.orientationY), axis: [0, 1, 0])
        root.addChild(scaled)

        let shifted = Entity()
        shifted.position = fit.offset
        scaled.addChild(shifted)

        var pendant: Entity?
        for part in parts {
            try Task.checkCancellation()
            var material = await self.material(for: part.material, modelId: model.id, finish: placement.finish)
            if opacity < 1 { material.blending = .transparent(opacity: .init(floatLiteral: opacity)) }
            let child = ModelEntity(mesh: part.mesh, materials: [material])
            if let slot = part.material.slot { child.name = FurnitureOcclusion.name(of: slot, baked: part.hasOcclusion) }
            if let pivot = part.toyPivot {
                if pendant == nil {
                    let joint = Entity()
                    joint.name = Self.pendantName
                    joint.position = pivot
                    shifted.addChild(joint)
                    pendant = joint
                }
                child.position = -pivot
                pendant?.addChild(child)
            } else {
                shifted.addChild(child)
            }
        }

        // One box for picking: footprint × fitted height, in the un-turned local frame.
        let footprint = SIMD3<Float>(Float(placement.width) - 0.1, max(fit.height, 0.3), Float(placement.depth) - 0.1)
        let shape = ShapeResource.generateBox(size: footprint).offsetBy(translation: [0, footprint.y / 2, 0])
        root.components.set(CollisionComponent(shapes: [shape]))
        if details != .flat {
            try await applyFurnitureDetails(to: root, placement: placement, details: details)
        }
        FurnitureOcclusion.set(occlusion, on: root)
        return root
    }

    func hasFurnitureBaseColors(_ modelID: String) -> Bool { baseColors.contains(modelID) }

    func applyFurnitureDetails(to entity: Entity, placement: Placement, details: FurnitureDetails) async throws {
        guard let model = catalog.model(id: placement.modelId) else { return }
        try await baseColors.apply(to: entity, modelID: model.id, finish: placement.finish, looks: looks, limit: details.textureLimit)
        try await applySurfaceMaps(to: entity, model: model.id, finish: placement.finish, enabled: details.surfaceMaps)
    }

    func applySurfaceMaps(to entity: Entity, model: String, finish: Finish = .original, enabled: Bool) async throws {
        try await surfaceMaps.apply(to: entity, model: model, finish: finish, looks: looks, enabled: enabled)
    }

    static let pendantName = "hanging-toy"

    /// Mesh format v1 (flat triangle soup) or v2 (indexed, smooth normals, UV0, slots): see
    /// `FurnitureMesh` and art/furniture/TECH_SPEC.md.
    private func parts(for model: CatalogModel) async throws -> [FurniturePart] {
        if let cached = furnitureParts[model.id] { return cached }
        if let pending = partLoads[model.id] { return try await pending.value }
        let previous = lastPartLoad
        let task = Task {
            _ = await previous?.result
            return try await Self.makeParts(model.id)
        }
        lastPartLoad = task
        partLoads[model.id] = task
        defer { partLoads[model.id] = nil }
        let parts = try await task.value
        furnitureParts[model.id] = parts
        return parts
    }

    private static func makeParts(_ modelID: String) async throws -> [FurniturePart] {
        let interval = Perf.signposter.beginInterval("FurnitureMesh")
        defer { Perf.signposter.endInterval("FurnitureMesh", interval) }
        let (decoded, occlusion) = try await AppModel.offMain {
            let mesh = try FurnitureMesh.decode(Self.data(modelID, "json"))
            let occlusion = FurnitureOcclusion.usesBakedMesh ? BakedFurnitureOcclusion.bundled?.parts(for: modelID, mesh: mesh) : nil
            return (mesh, occlusion)
        }
        var parts: [FurniturePart] = []
        for (index, part) in decoded.parts.enumerated() {
            let (positions, normals, uv) = try await AppModel.offMain {
                (Self.vectors(part.positions[...]), Self.vectors(part.normals[...]), part.uvs.map { uvs in
                    (0..<(uvs.count / 2)).map { SIMD2<Float>(uvs[$0 * 2], uvs[$0 * 2 + 1]) }
                })
            }
            let pivot = part.isPendant ? part.pivot.map { SIMD3<Float>($0[0], $0[1], $0[2]) } : nil
            if let uv, let values = occlusion?[index] {
                do {
                    let tangentSpace = part.material.slot.map { FurnitureSurfaceMaps.supports(model: modelID, slot: $0) } ?? false
                    let mesh = try await FurnitureOcclusionMesh.make(positions: positions, normals: normals, uv: uv,
                                                                     indices: part.indices, values: values, tangentSpace: tangentSpace)
                    parts.append(FurniturePart(mesh: mesh, material: part.material, toyPivot: pivot, hasOcclusion: true))
                    continue
                } catch {
                    try Task.checkCancellation()
                    Logger(subsystem: "app.meowverse", category: "art").error("Furniture occlusion mesh \(modelID, privacy: .public)/\(index) unavailable: \(error.localizedDescription, privacy: .public)")
                }
            }
            var descriptor = MeshDescriptor(name: "\(modelID)-\(index)")
            descriptor.positions = MeshBuffer(positions)
            descriptor.normals = MeshBuffer(normals)
            if let uv { descriptor.textureCoordinates = MeshBuffer(uv) }
            descriptor.primitives = .triangles(part.indices)
            let mesh = try await MeshResource(from: [descriptor])
            parts.append(FurniturePart(mesh: mesh, material: part.material, toyPivot: pivot, hasOcclusion: false))
        }
        return parts
    }

    /// A v2 slot with a palette look gets its preset's physical material and pattern; anything
    /// else (v1 art, a missing look) keeps the original flat colour with the finish tint.
    private func material(for source: FurnitureMesh.Material, modelId: String, finish: Finish) async -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.metallic = .init(floatLiteral: 0)
        guard let slot = source.slot, let look = looks.material(modelId: modelId, finish: finish, slot: slot) else {
            let rgb = source.color
            material.baseColor = .init(tint: Self.color([rgb[0], rgb[1], rgb[2]], materialName: source.name, finish: finish))
            material.roughness = .init(floatLiteral: 0.72)
            return material
        }
        let base = UIColor(red: look.color[0], green: look.color[1], blue: look.color[2], alpha: 1)
        material.roughness = .init(floatLiteral: Float(look.roughness))
        material.metallic = .init(floatLiteral: Float(look.metallic))
        material.clearcoat = .init(floatLiteral: Float(look.clearcoat))
        material.clearcoatRoughness = .init(floatLiteral: Float(look.clearcoatRoughness))
        if look.sheen > 0 {
            let s = CGFloat(look.sheen)
            material.sheen = .init(tint: UIColor(red: look.color[0] * s, green: look.color[1] * s, blue: look.color[2] * s, alpha: 1))
        }
        if let pattern = look.pattern, let tile = try? await patternTile(pattern, base: look.color) {
            material.baseColor = .init(tint: .white, texture: .init(tile))
            let period = Float(max(pattern.periodCells, 0.001))
            material.textureCoordinateTransform = .init(offset: .zero, scale: SIMD2(repeating: 1 / period),
                                                        rotation: Float(pattern.angleDeg) * .pi / 180)
        } else {
            material.baseColor = .init(tint: base)
        }
        return material
    }

    /// The mask's layers composed over the slot colour, once per colour set (TECH_SPEC §3).
    private func patternTile(_ pattern: FurnitureLooks.Pattern, base: [Double]) async throws -> TextureResource {
        let key = "\(pattern.file)|\(base)|\(pattern.layers)"
        if let cached = patternTiles[key] { return cached }
        if let pending = patternLoads[key] { return try await pending.value }
        let task = Task {
            let interval = Perf.signposter.beginInterval("FurniturePattern")
            defer { Perf.signposter.endInterval("FurniturePattern", interval) }
            let image = try await AppModel.offMain { try Self.patternImage(pattern, base: base) }
            return try await TextureResource(image: image, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
        }
        patternLoads[key] = task
        defer { patternLoads[key] = nil }
        let texture = try await task.value
        patternTiles[key] = texture
        return texture
    }

    nonisolated private static func patternImage(_ pattern: FurnitureLooks.Pattern, base: [Double]) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(try Self.data(pattern.file, "png") as CFData, nil),
              let mask = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ArtError.missing(pattern.file) }
        let width = mask.width, height = mask.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        // Device RGB, no colour management: the mask holds coverage values, not colours.
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ArtError.missing(pattern.file) }
        let tile = PatternTile.compose(mask: rgba, channels: 4, base: base, layers: pattern.layers)
        guard let provider = CGDataProvider(data: Data(tile) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ArtError.missing(pattern.file) }
        return image
    }

    /// `buildCatalogModel` tinting: lerp toward the finish colour in linear light.
    nonisolated static func color(_ srgb: SIMD3<Float>, materialName: String, finish: Finish) -> UIColor {
        let tint: SIMD3<Float>? = switch finish {
        case .original: nil
        case .cream: [0xdb, 0xc9, 0xa9]
        case .sage: [0xa9, 0xb7, 0xa0]
        case .blue: [0x9d, 0xb8, 0xce]
        // Legacy (v1) art in a preset finish: the preset swatch as the tint.
        case .apricot: [0xf2, 0xb4, 0x8f]
        case .blush: [0xeb, 0xb7, 0xbe]
        case .lavender: [0xbd, 0xb0, 0xda]
        }
        var linear = toLinear(srgb)
        if let tint {
            let structural = materialName.range(of: "wood|metal|dark", options: [.regularExpression, .caseInsensitive]) != nil
            let amount: Float = structural ? 0.32 : 0.72
            linear += (toLinear(tint / 255) - linear) * amount
        }
        let out = toSRGB(linear)
        return UIColor(red: CGFloat(out.x), green: CGFloat(out.y), blue: CGFloat(out.z), alpha: 1)
    }

    nonisolated private static func toLinear(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3((0..<3).map { c[$0] <= 0.04045 ? c[$0] / 12.92 : pow((c[$0] + 0.055) / 1.055, 2.4) })
    }

    nonisolated private static func toSRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3((0..<3).map { c[$0] <= 0.0031308 ? c[$0] * 12.92 : 1.055 * pow(c[$0], 1 / 2.4) - 0.055 })
    }

    nonisolated fileprivate static func vectors(_ flat: ArraySlice<Float>) -> [SIMD3<Float>] {
        let base = flat.startIndex
        return (0..<(flat.count / 3)).map { [flat[base + $0 * 3], flat[base + $0 * 3 + 1], flat[base + $0 * 3 + 2]] }
    }

    // MARK: Cat (from the active cat pack)

    typealias BellaPose = CatPackPose
    typealias BellaMesh = CatPoseMesh

    /// The room's cat on one tier (画质档, docs/CAT_PACK.md). One is kept: a tier or pack switch
    /// decodes the new files once.
    func resources(for variant: CatPackVariant) -> CatArt {
        if let catResources, catResources.variant.key == variant.key { return catResources }
        let resources = CatArt(variant: variant)
        catResources = resources
        return resources
    }
}

/// A load keeps its own pack, tier and cache across every suspension, including after a pack or
/// tier switch. Every file is read through the variant: a tier's own files from where it was
/// downloaded (or the imported pack's folder), everything shared (the clips) from the pack.
final class CatArt {
    let variant: CatPackVariant
    var pack: CatPack { variant.pack }
    private var poses: [CatPackPose: CatPoseMesh] = [:]
    private var textures: [String: TextureResource] = [:]
    private var texturePixels = 0
    private var decodedRig: CatGaitRig?

    init(variant: CatPackVariant) { self.variant = variant }

    /// 中's skeleton and clips, wearing the tier's skinned mesh when it has one.
    func rig() async throws -> CatGaitRig {
        try Task.checkCancellation()
        if let decodedRig { return decodedRig }
        let rig = try await AppModel.offMain { [variant] in
            let rig = try CatGaitRig.decode(variant.data(variant.manifest.groundGaits))
            guard let skin = variant.skinFile else { return rig }
            return rig.wearing(try CatSkin.decode(variant.data(skin), name: skin, for: rig))
        }
        try Task.checkCancellation()
        decodedRig = rig
        return rig
    }

    /// The cat in grid-cell units, feet on y = 0, facing +Z. Parsing happens off the main thread.
    /// A pose may have any number of parts; each part's `material` role is looked up in the manifest.
    func bella(_ pose: CatPackPose) async throws -> BellaFigure {
        try Task.checkCancellation()
        let decoded: CatPoseMesh
        if let cached = poses[pose] {
            decoded = cached
        } else {
            decoded = try await AppModel.offMain { [variant] in
                let name = variant.poseFile(pose)
                return try CatPoseMesh.decode(variant.data(name), name: name)
            }
            try Task.checkCancellation()
            poses[pose] = decoded
        }
        let root = Entity()
        var surfaces: [BellaSurface] = []
        for part in decoded.parts {
            let mesh: MeshResource
            if part.targets != nil {
                let surface = try BellaSurface(part: part)
                mesh = try await MeshResource(from: surface.mesh)
                surfaces.append(surface)
            } else {
                var descriptor = MeshDescriptor(name: part.name)
                descriptor.positions = MeshBuffer(ArtLibrary.vectors(part.positions[...]))
                descriptor.normals = MeshBuffer(ArtLibrary.vectors(part.normals[...]))
                descriptor.textureCoordinates = MeshBuffer((0..<(part.uvs.count / 2)).map {
                    SIMD2<Float>(part.uvs[$0 * 2], 1 - part.uvs[$0 * 2 + 1])
                })
                descriptor.primitives = .triangles(part.indices)
                mesh = try await MeshResource(from: [descriptor])
            }

            let material = try await bellaMaterial(part.material, sleeping: pose == .sleep)
            root.addChild(ModelEntity(mesh: mesh, materials: [material]))
        }
        return BellaFigure(entity: root, surfaces: surfaces)
    }

    /// The manifest's material for a mesh role; a role the manifest does not list is neutral grey.
    func bellaMaterial(_ role: String, sleeping: Bool) async throws -> PhysicallyBasedMaterial {
        try Task.checkCancellation()
        var material = PhysicallyBasedMaterial()
        material.metallic = .init(floatLiteral: 0)
        material.faceCulling = .none
        if let spec = variant.material(role) {
            material.baseColor = .init(texture: .init(try await texture(spec.baseColor(sleeping: sleeping))))
            material.roughness = .init(floatLiteral: Float(spec.roughness(sleeping: sleeping)))
        } else {
            material.baseColor = .init(tint: UIColor(white: 0.8, alpha: 1))
            material.roughness = .init(floatLiteral: 0.82)
        }
        return material
    }

    private func texture(_ file: String) async throws -> TextureResource {
        if let cached = textures[file] { return cached }
        let remaining = CatPackLimits.standard.maxTotalTexturePixels - texturePixels
        let (image, pixels) = try await AppModel.offMain { [variant] in
            let data = try variant.data(file)
            guard let pixels = CatPackValidator.imagePixels(data) else { throw CatPackError.badTexture(file) }
            guard pixels <= remaining else { throw CatPackError.renderBudgetExceeded }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = Self.thumbnail(from: source, edge: CatPackValidator.roomTextureEdge)
            else { throw CatPackError.badTexture(file) }
            return (image, pixels)
        }
        try Task.checkCancellation()
        let texture = try await TextureResource(image: image, options: .init(semantic: .color))
        try Task.checkCancellation()
        if let cached = textures[file] { return cached }
        guard pixels <= CatPackLimits.standard.maxTotalTexturePixels - texturePixels else { throw CatPackError.renderBudgetExceeded }
        textures[file] = texture
        texturePixels += pixels
        return texture
    }

    nonisolated static func thumbnail(from source: CGImageSource, edge: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: edge
        ] as CFDictionary)
    }
}

extension FurnitureLooks {
    /// The bundled palette looks (`furniture-looks.json`); empty when missing, so v1 tints apply.
    nonisolated static let bundled = (try? FurnitureLooks(data: ArtLibrary.data("furniture-looks", "json"))) ?? .empty
}
