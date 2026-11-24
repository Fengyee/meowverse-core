import CoreGraphics
import Foundation
import Metal
import MeowverseCore
import OSLog
import RealityKit

nonisolated struct BakedFurnitureOcclusion: Sendable {
    private struct Index: Decodable {
        struct Model: Decodable { let offset: Int; let parts: [Int] }
        let version: Int
        let models: [String: Model]
    }

    private let index: Index
    private let bytes: Data

    static let bundled: Self? = {
        do {
            let index = try JSONDecoder().decode(Index.self, from: ArtLibrary.data("furniture-occlusion", "json"))
            let bytes = try ArtLibrary.data("furniture-occlusion", "bin")
            guard index.version == 1 else { throw ArtLibrary.ArtError.missing("furniture-occlusion version") }
            return Self(index: index, bytes: bytes)
        } catch {
            Logger(subsystem: "app.meowverse", category: "art").error("Furniture occlusion unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    func parts(for id: String, mesh: FurnitureMesh) -> [Data]? {
        guard let model = index.models[id], model.parts == mesh.parts.map(\.vertexCount),
              model.offset >= 0, model.offset <= bytes.count,
              model.parts.reduce(0, +) <= bytes.count - model.offset else { return nil }
        var offset = model.offset
        return model.parts.map { count in
            defer { offset += count }
            return bytes[offset..<(offset + count)]
        }
    }
}

enum FurnitureOcclusion {
    private static let prefix = "occlusion:"
    private static let none = PhysicallyBasedMaterial.AmbientOcclusion()

    #if DEBUG || DRILLS
    private nonisolated static let mode: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-MeowverseFurnitureOcclusion"),
              args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }()

    /// The comparison's reference can use the original mesh path as well as disabling the material.
    nonisolated static var usesBakedMesh: Bool { mode != "legacy" }
    #else
    nonisolated static let usesBakedMesh = true
    #endif

    static func enabled(_ setting: Bool) -> Bool {
        #if DEBUG || DRILLS
        switch mode {
        case "on": return true
        case "off", "legacy": return false
        default: break
        }
        #endif
        return setting
    }

    // Sample an interpolated vertex weight through the material’s second UV channel.
    // All models share this ramp, so each mesh only adds scalar values and a UV stream.
    private static let texture: MaterialParameters.Texture? = {
        let values = Data((0...255).map(UInt8.init))
        let gray = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: values as CFData),
              let image = CGImage(width: 256, height: 1, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: 256, space: gray, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        do {
            let ramp = try TextureResource(image: image, options: .init(semantic: .raw, mipmapsMode: .none))
            let descriptor = MTLSamplerDescriptor()
            descriptor.sAddressMode = .clampToEdge
            descriptor.tAddressMode = .clampToEdge
            descriptor.minFilter = .linear
            descriptor.magFilter = .linear
            var texture = MaterialParameters.Texture(ramp, sampler: .init(descriptor))
            texture.uvIndex = 1
            return texture
        } catch {
            Logger(subsystem: "app.meowverse", category: "art").error("Furniture occlusion ramp unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    static func name(of slot: String, baked: Bool) -> String { baked ? prefix + slot : slot }
    static func slot(_ name: String) -> String { name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name }

    static func set(_ enabled: Bool, on entity: Entity) {
        if entity.name.hasPrefix(prefix), let model = entity as? ModelEntity,
           var component = model.model, var material = component.materials.first as? PhysicallyBasedMaterial {
            if enabled, material.ambientOcclusion.texture == nil, let texture {
                material.ambientOcclusion = .init(texture: texture)
                component.materials = [material]
                model.model = component
            } else if !enabled, material.ambientOcclusion.texture != nil {
                material.ambientOcclusion = none
                component.materials = [material]
                model.model = component
            }
        }
        for child in entity.children { set(enabled, on: child) }
    }
}

enum FurnitureOcclusionMesh {
    private nonisolated struct XYZ: Sendable {
        var x: Float
        var y: Float
        var z: Float
        init(_ vector: SIMD3<Float>) { (x, y, z) = (vector.x, vector.y, vector.z) }
    }

    private struct Vertex {
        var position: XYZ
        var normal: XYZ
        var uv: SIMD2<Float>
        var occlusion: SIMD2<Float>
    }

    private nonisolated struct Basis: Sendable {
        var tangent: XYZ
        var bitangent: XYZ
    }

    private nonisolated static func basis(positions: [SIMD3<Float>], normals: [SIMD3<Float>], uv: [SIMD2<Float>],
                              indices: [UInt32]) -> [Basis] {
        var tangents = positions.map { _ in SIMD3<Float>.zero }
        var bitangents = tangents
        for offset in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[offset]), b = Int(indices[offset + 1]), c = Int(indices[offset + 2])
            let edge1 = positions[b] - positions[a], edge2 = positions[c] - positions[a]
            let uv1 = uv[b] - uv[a], uv2 = uv[c] - uv[a]
            let determinant = uv1.x * uv2.y - uv1.y * uv2.x
            guard abs(determinant) > 1e-8 else { continue }
            let inverse = 1 / determinant
            let tangent = (edge1 * uv2.y - edge2 * uv1.y) * inverse
            let bitangent = (edge2 * uv1.x - edge1 * uv2.x) * inverse
            for index in [a, b, c] {
                tangents[index] += tangent
                bitangents[index] += bitangent
            }
        }
        return positions.indices.map { index in
            let n = simd_normalize(normals[index])
            let raw = tangents[index] - n * simd_dot(n, tangents[index])
            let fallback: SIMD3<Float> = abs(n.y) < 0.95 ? [0, 1, 0] : [1, 0, 0]
            let t = simd_normalize(simd_length_squared(raw) > 1e-10 ? raw : simd_cross(fallback, n))
            let b = simd_cross(n, t)
            return Basis(tangent: XYZ(t), bitangent: XYZ(simd_dot(b, bitangents[index]) < 0 ? -b : b))
        }
    }

    static func make(positions: [SIMD3<Float>], normals: [SIMD3<Float>], uv: [SIMD2<Float>],
                     indices: [UInt32], values: Data, tangentSpace: Bool = false) async throws -> MeshResource {
        var descriptor = LowLevelMesh.Descriptor(
            vertexCapacity: positions.count,
            vertexAttributes: [
                .init(semantic: .position, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.position)!),
                .init(semantic: .normal, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.normal)!),
                .init(semantic: .uv0, format: .float2, offset: MemoryLayout<Vertex>.offset(of: \.uv)!),
                .init(semantic: .uv1, format: .float2, offset: MemoryLayout<Vertex>.offset(of: \.occlusion)!),
            ],
            vertexLayouts: [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)],
            indexCapacity: indices.count)
        if tangentSpace {
            descriptor.vertexAttributes += [
                .init(semantic: .tangent, format: .float3, layoutIndex: 1, offset: MemoryLayout<Basis>.offset(of: \.tangent)!),
                .init(semantic: .bitangent, format: .float3, layoutIndex: 1, offset: MemoryLayout<Basis>.offset(of: \.bitangent)!),
            ]
            descriptor.vertexLayouts.append(.init(bufferIndex: 1, bufferStride: MemoryLayout<Basis>.stride))
        }
        let textureUV = uv.map { SIMD2($0.x, 1 - $0.y) }
        var bounds = BoundingBox()
        let vertices = positions.indices.map { i in
            bounds.formUnion(positions[i])
            return Vertex(position: XYZ(positions[i]), normal: XYZ(normals[i]), uv: textureUV[i],
                          occlusion: [(Float(values[values.startIndex + i]) + 0.5) / 256, 0.5])
        }
        let mesh = try LowLevelMesh(descriptor: descriptor)
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { dest in vertices.withUnsafeBytes { dest.copyMemory(from: $0) } }
        if tangentSpace {
            let frames = try await AppModel.offMain {
                basis(positions: positions, normals: normals, uv: textureUV, indices: indices)
            }
            mesh.withUnsafeMutableBytes(bufferIndex: 1) { dest in frames.withUnsafeBytes { dest.copyMemory(from: $0) } }
        }
        mesh.withUnsafeMutableIndices { dest in indices.withUnsafeBytes { dest.copyMemory(from: $0) } }
        mesh.parts.replaceAll([.init(indexCount: indices.count, bounds: bounds)])
        return try await MeshResource(from: mesh)
    }
}
