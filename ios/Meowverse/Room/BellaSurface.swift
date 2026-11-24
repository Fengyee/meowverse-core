import MeowverseCore
import RealityKit

struct BellaPoseWeights: Equatable {
    var leftPaw: Float = 0
    var rightPaw: Float = 0
    var bat: Float = 0
    var peek: Float = 0
    var eat: Float = 0
    var drink: Float = 0
    var digLeft: Float = 0
    var digRight: Float = 0
    var groundBat: Float = 0
    var flatLeft: Float = 0
    var flatRight: Float = 0

    static let zero = Self()
    var values: [Float] { [leftPaw, rightPaw, bat, peek, eat, drink, digLeft, digRight, groundBat, flatLeft, flatRight] }
}

/// The skinning bake stores only vertices affected by each foreleg or neck pose.
/// Each actor owns its mesh buffers so simultaneous room views can animate independently.
final class BellaSurface {
    enum Target: String, CaseIterable {
        case leftPaw, rightPaw, bat, peek, eat, drink, digLeft, digRight, groundBat, flatLeft, flatRight
    }

    private struct Vertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var uv: SIMD2<Float>
    }

    private struct Delta {
        let index: Int
        let position: SIMD3<Float>
        let normal: SIMD3<Float>
    }

    let mesh: LowLevelMesh
    private let vertices: [Vertex]
    private let shapes: [[Delta]]
    private var weights = BellaPoseWeights.zero

    init(part: ArtLibrary.BellaMesh.Part) throws {
        let count = part.positions.count / 3
        self.vertices = (0..<count).map { i in
            Vertex(position: Self.vector(part.positions, i), normal: Self.vector(part.normals, i),
                   uv: [part.uvs[i * 2], 1 - part.uvs[i * 2 + 1]])
        }
        shapes = try Target.allCases.map { target in
            guard let offsets = part.targets?[target.rawValue] else { return [] }
            guard offsets.positions.count == offsets.indices.count * 3,
                  offsets.normals.count == offsets.positions.count,
                  offsets.indices.allSatisfy({ (0..<count).contains($0) }) else {
                throw ArtLibrary.ArtError.missing("invalid Bella pose offsets: \(target.rawValue)")
            }
            return offsets.indices.enumerated().map { i, vertex in
                Delta(index: vertex, position: Self.vector(offsets.positions, i) / 10000,
                      normal: Self.vector(offsets.normals, i) / 10000)
            }
        }
        let descriptor = LowLevelMesh.Descriptor(
            vertexCapacity: count,
            vertexAttributes: [.init(semantic: .position, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.position)!),
                               .init(semantic: .normal, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.normal)!),
                               .init(semantic: .uv0, format: .float2, offset: MemoryLayout<Vertex>.offset(of: \.uv)!)],
            vertexLayouts: [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)],
            indexCapacity: part.indices.count)
        mesh = try LowLevelMesh(descriptor: descriptor)
        mesh.withUnsafeMutableIndices { bytes in
            part.indices.withUnsafeBytes { bytes.copyMemory(from: $0) }
        }
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { bytes in
            vertices.withUnsafeBytes { bytes.copyMemory(from: $0) }
        }
        var bounds = BoundingBox()
        for v in vertices { bounds.formUnion(v.position) }
        for delta in shapes.joined() { bounds.formUnion(vertices[delta.index].position + delta.position) }
        mesh.parts.replaceAll([.init(indexCount: part.indices.count, bounds: bounds)])
    }

    func setWeights(_ next: BellaPoseWeights) {
        guard next != weights else { return }
        weights = next
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { bytes in
            vertices.withUnsafeBytes { bytes.copyMemory(from: $0) }
            let output = bytes.bindMemory(to: Vertex.self)
            for (shape, weight) in zip(shapes, next.values) where weight != 0 {
                for delta in shape {
                    output[delta.index].position += weight * delta.position
                    output[delta.index].normal += weight * delta.normal
                }
            }
        }
    }

    private static func vector(_ values: [Float], _ vertex: Int) -> SIMD3<Float> {
        [values[vertex * 3], values[vertex * 3 + 1], values[vertex * 3 + 2]]
    }
}

struct BellaFigure {
    let entity: Entity
    let surfaces: [BellaSurface]

    func setWeights(_ weights: BellaPoseWeights) {
        for surface in surfaces { surface.setWeights(weights) }
    }
}
