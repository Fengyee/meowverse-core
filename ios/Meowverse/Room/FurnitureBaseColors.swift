import ImageIO
import Metal
import MeowverseCore
import OSLog
import RealityKit
import UIKit

final class FurnitureBaseColors {
    static let fullSize = RenderQualityTier.high.settings.furnitureTextureLimit
    private static let sampler: MaterialParameters.Texture.Sampler = {
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .repeat
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        return .init(descriptor)
    }()
    private let maps: [String: [String: String]]
    private let textures = NSCache<NSString, TextureResource>()
    private var loads: [String: Task<TextureResource, Error>] = [:]
    private let logger = Logger(subsystem: "Meowverse", category: "art")

    init() {
        do {
            maps = try JSONDecoder().decode([String: [String: String]].self,
                                            from: ArtLibrary.data("furniture-base-colors", "json"))
        } catch {
            maps = [:]
            logger.error("Furniture base colour index unavailable: \(error.localizedDescription, privacy: .public)")
        }
        textures.totalCostLimit = 8 * 1024 * 1024
    }

    func contains(_ modelID: String) -> Bool { maps[modelID] != nil }

    func apply(to root: Entity, modelID: String, finish: Finish, looks: FurnitureLooks, limit: Int) async throws {
        guard let slots = maps[modelID] else { return }
        var colors: [String: PhysicallyBasedMaterial.BaseColor] = [:]
        for (slot, file) in slots.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            guard let rgb = looks.material(modelId: modelID, finish: finish, slot: slot)?.color else { continue }
            let flat = UIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
            colors[slot] = .init(tint: flat)
            if limit > 0 {
                do {
                    let texture = try await texture(file, limit: limit)
                    colors[slot] = .init(tint: .white, texture: .init(texture, sampler: Self.sampler))
                } catch {
                    logger.error("Furniture albedo \(file, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        try Task.checkCancellation()
        Self.apply(colors, to: root)
    }

    private static func apply(_ colors: [String: PhysicallyBasedMaterial.BaseColor], to entity: Entity) {
        if let baseColor = colors[FurnitureOcclusion.slot(entity.name)], let piece = entity as? ModelEntity,
           var model = piece.model, var material = model.materials.first as? PhysicallyBasedMaterial {
            material.baseColor = baseColor
            model.materials = [material]
            piece.model = model
        }
        for child in entity.children { apply(colors, to: child) }
    }

    private func texture(_ file: String, limit: Int) async throws -> TextureResource {
        let key = "\(file)-\(limit)"
        if let texture = textures.object(forKey: key as NSString) { return texture }
        if let task = loads[key] { return try await task.value }
        let task = Task {
            let interval = Perf.signposter.beginInterval("FurnitureAlbedo")
            defer { Perf.signposter.endInterval("FurnitureAlbedo", interval) }
            let image = try await AppModel.offMain { try Self.image(file, limit: limit) }
            let texture = try await TextureResource(image: image, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
            textures.setObject(texture, forKey: key as NSString, cost: image.width * image.height * 4 * 4 / 3)
            return texture
        }
        loads[key] = task
        defer { loads[key] = nil }
        return try await task.value
    }

    nonisolated private static func image(_ file: String, limit: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(try ArtLibrary.data(file, "png") as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
              ] as CFDictionary) else { throw ArtLibrary.ArtError.missing(file) }
        return image
    }
}
