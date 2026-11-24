import Foundation
import ImageIO
import Metal
import MeowverseCore
import OSLog
import RealityKit

@MainActor
final class FurnitureSurfaceMaps {
    private struct Surface {
        let roughness: PhysicallyBasedMaterial.Roughness
        let normal: PhysicallyBasedMaterial.Normal
    }

    private struct Binding: Decodable {
        let profile: String
        let baseRoughness: Float?
        let roughnessScale: Float?
    }

    private struct Pattern: Decodable {
        let profile: String
        let quarterTurn: String?
    }

    private struct Index: Decodable {
        let version: Int
        let models: [String: [String: Binding]]
        let patterns: [String: Pattern]
        let metallicAccent: String
        let references: [String: Float]

        func profile(for binding: Binding, slot: String, look: FurnitureLooks.MaterialLook?) -> String {
            if binding.roughnessScale != nil { return binding.profile }
            if let motif = look?.pattern, let rule = patterns[motif.id] {
                return motif.angleDeg == 90 ? rule.quarterTurn ?? rule.profile : rule.profile
            }
            if slot == "accent", (look?.metallic ?? 0) >= 0.1 { return metallicAccent }
            return binding.profile
        }
    }

    private final class CachedTexture {
        weak var resource: TextureResource?
        init(_ resource: TextureResource) { self.resource = resource }
    }

    private static let logger = Logger(subsystem: "app.meowverse", category: "furniture-maps")
    private static let index: Index? = {
        do {
            let data = try ArtLibrary.data("furniture-surface-maps", "json")
            let index = try JSONDecoder().decode(Index.self, from: data)
            guard index.version == 2 else { throw ArtLibrary.ArtError.missing("supported surface map index") }
            return index
        } catch {
            logger.error("Furniture surface index unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    private static let sampler: MaterialParameters.Texture.Sampler = {
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .repeat
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        descriptor.maxAnisotropy = 4
        return .init(descriptor)
    }()

    private var cached: [String: CachedTexture] = [:]
    private var loading: [String: Task<TextureResource, any Error>] = [:]

    static func supports(model: String, slot: String?) -> Bool {
        if let slot { return index?.models[model]?[slot] != nil }
        return index?.models[model] != nil
    }

    func apply(to entity: Entity, model: String, finish: Finish, looks: FurnitureLooks, enabled: Bool) async throws {
        guard let index = Self.index, let slots = index.models[model] else { return }
        var materials: [String: Surface] = [:]
        for (slot, binding) in slots.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let look = looks.material(modelId: model, finish: finish, slot: slot)
            let base = binding.baseRoughness ?? look.map { Float($0.roughness) } ?? 0.72
            materials[slot] = Surface(roughness: .init(scale: base), normal: .init())
            guard enabled else { continue }
            let profile = index.profile(for: binding, slot: slot, look: look)
            let reference = index.references[profile] ?? 1
            let scale = binding.roughnessScale ?? min(1, base / reference)
            do {
                materials[slot] = try await surface(profile, scale: scale)
            } catch {
                try Task.checkCancellation()
                Self.logger.error("Material \(model, privacy: .public)/\(slot, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        try Task.checkCancellation()
        Self.bind(materials, to: entity)
    }

    private func surface(_ profile: String, scale: Float) async throws -> Surface {
        let roughness = try await texture(profile, channel: "roughness", semantic: .raw)
        let normal = try await texture(profile, channel: "normal", semantic: .normal)
        return Surface(roughness: .init(scale: scale, texture: .init(roughness, sampler: Self.sampler)),
                       normal: .init(texture: .init(normal, sampler: Self.sampler)))
    }

    private static func bind(_ surfaces: [String: Surface], to entity: Entity) {
        if let surface = surfaces[FurnitureOcclusion.slot(entity.name)], let piece = entity as? ModelEntity,
           var model = piece.model, var material = model.materials.first as? PhysicallyBasedMaterial {
            material.roughness = surface.roughness
            material.normal = surface.normal
            model.materials = [material]
            piece.model = model
        }
        for child in entity.children { bind(surfaces, to: child) }
    }

    private func texture(_ type: String, channel: String, semantic: TextureResource.Semantic) async throws -> TextureResource {
        let name = "surface-\(type)-\(channel)"
        if let resource = cached[name]?.resource { return resource }
        if let task = loading[name] { return try await task.value }
        let task = Task {
            let image = try await AppModel.offMain {
                let bytes = try ArtLibrary.data(name, "png")
                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ArtLibrary.ArtError.missing(name) }
                return image
            }
            let resource = try await TextureResource(image: image, withName: name,
                options: .init(semantic: semantic, mipmapsMode: .allocateAndGenerateAll))
            cached[name] = CachedTexture(resource)
            return resource
        }
        loading[name] = task
        defer { loading[name] = nil }
        return try await task.value
    }
}
