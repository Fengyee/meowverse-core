import Foundation
import ImageIO
import MeowverseCore
import OSLog
import RealityKit

@MainActor
final class RoomFloorShadows {
    private var layout: [FurnitureFloorShadowPlacement] = []
    private var pending: Task<Void, Never>?

    func update(_ placements: [FurnitureFloorShadowPlacement], apply: @escaping (TextureResource?) -> Void) {
        guard placements != layout else { return }
        layout = placements
        pending?.cancel()
        apply(nil)
        guard !placements.isEmpty else { pending = nil; return }
        pending = Task { [weak self] in
            do {
                let texture = try await Self.texture(for: placements)
                try Task.checkCancellation()
                apply(texture)
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Floor occlusion unavailable: \(error.localizedDescription, privacy: .public)")
            }
            if !Task.isCancelled { self?.pending = nil }
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        layout = []
    }

    static func placements(for items: [PhotoFurniture], excluding lifted: String? = nil,
                           catalog: FurnitureCatalog) -> [FurnitureFloorShadowPlacement] {
        items.sorted { $0.instanceId < $1.instanceId }.compactMap { item in
            guard item.instanceId != lifted, item.wall == nil,
                  let model = catalog.model(id: item.modelId), model.mount != .wall else { return nil }
            let base = ArtLibrary.fit(model, width: model.defaultWidth, depth: model.defaultSize[1]).scale
            let fit = ArtLibrary.fit(model, width: item.width, depth: item.depth).scale
            let center = ArtLibrary.worldPoint(x: item.x, z: item.z, width: item.width, depth: item.depth, turn: item.turn)
            return .init(modelID: model.id, x: center.x, z: center.z, turn: item.turn, scale: fit / base)
        }
    }

    static func texture(for placements: [FurnitureFloorShadowPlacement]) async throws -> TextureResource? {
        guard !placements.isEmpty else { return nil }
        let render = Task.detached(priority: .userInitiated) { try FloorShadowSource.image(for: placements) }
        let image = try await withTaskCancellationHandler {
            try await render.value
        } onCancel: {
            render.cancel()
        }
        try Task.checkCancellation()
        guard let image else { return nil }
        return try await TextureResource(image: image, options: .init(semantic: .raw, mipmapsMode: .allocateAndGenerateAll))
    }

    private static let logger = Logger(subsystem: "app.meowverse", category: "floor-occlusion")
}

private nonisolated enum FloorShadowSource {
    private static let edges = 384
    private struct Index: Decodable {
        let version: Int
        let width: Int
        let height: Int
        let texelsPerCell: Int
        let models: [String: FurnitureFloorShadowAtlas.Stamp]
    }

    // ImageIO expands the atlas once. Stamps are CPU data and never enter the GPU texture cache.
    private static let atlas: Result<FurnitureFloorShadowAtlas, any Error> = Result {
        let index = try JSONDecoder().decode(Index.self, from: ArtLibrary.data("furniture-floor-shadows", "json"))
        let png = try ArtLibrary.data("furniture-floor-shadows", "png")
        guard index.version == 1,
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == index.width, image.height == index.height, image.bitsPerPixel == 8,
              let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data),
              CFDataGetLength(data) >= image.bytesPerRow * image.height else {
            throw ArtLibrary.ArtError.missing("furniture floor occlusion atlas")
        }
        var pixels: [UInt8] = []
        pixels.reserveCapacity(image.width * image.height)
        for row in 0..<image.height {
            pixels.append(contentsOf: UnsafeBufferPointer(start: pointer + row * image.bytesPerRow, count: image.width))
        }
        guard let atlas = FurnitureFloorShadowAtlas(width: image.width, height: image.height, texelsPerCell: index.texelsPerCell,
                                                     stamps: index.models, pixels: pixels) else {
            throw ArtLibrary.ArtError.missing("furniture floor occlusion stamp index")
        }
        return atlas
    }

    static func image(for placements: [FurnitureFloorShadowPlacement]) throws -> CGImage? {
        let atlas = try atlas.get()
        guard placements.contains(where: { atlas.contains(modelID: $0.modelID) }) else { return nil }
        let bytes = try atlas.visibility(placements: placements, roomCells: GridRules.size, edges: edges)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: edges, height: edges, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: edges,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
