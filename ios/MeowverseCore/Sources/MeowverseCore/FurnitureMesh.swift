import Foundation

/// A baked furniture mesh file (`Resources/Art/<modelId>.json`) decoded into drawable parts:
/// one part per material group, each with its own compact vertex buffer.
///
/// Version 1 is the original triangle soup (no UVs, `groups[].start/count` in vertices).
/// Version 2 (art/furniture/TECH_SPEC.md §2) is indexed with smooth normals, UV0 and semantic
/// material slots; `groups[].start/count` index into `indices`.
public struct FurnitureMesh: Sendable {
    public struct Material: Sendable, Equatable {
        public let name: String
        /// The semantic slot (v2), the key into `FurnitureLooks`; nil for v1 materials.
        public let slot: String?
        /// sRGB 0...1, the colour when no look applies.
        public let color: [Float]
    }

    public struct Part: Sendable {
        /// The source mesh's name; `toy-ball` is the swinging pendant.
        public let meshName: String?
        public let pivot: [Float]?
        public let positions: [Float]
        public let normals: [Float]
        /// Two per vertex, origin bottom-left; nil in v1.
        public let uvs: [Float]?
        public let indices: [UInt32]
        public let material: Material

        public var isPendant: Bool { meshName == FurnitureMesh.pendantName && pivot?.count == 3 }
        public var vertexCount: Int { positions.count / 3 }
    }

    public enum DecodeError: Error, Equatable {
        case unsupportedVersion(Int)
        case invalid(String)
    }

    public static let pendantName = "toy-ball"

    public let version: Int
    public let parts: [Part]

    public var triangleCount: Int { parts.reduce(0) { $0 + $1.indices.count / 3 } }

    private struct File: Decodable {
        struct Group: Decodable { let start: Int; let count: Int; let materialIndex: Int? }
        struct Material: Decodable { let name: String; let slot: String?; let color: [Float] }
        struct Mesh: Decodable {
            let name: String?
            let pivot: [Float]?
            let positions: [Float]
            let normals: [Float]
            let uvs: [Float]?
            let indices: [UInt32]?
            let groups: [Group]
            let materials: [Material]
        }
        let version: Int?
        let meshes: [Mesh]
    }

    public static func decode(_ data: Data) throws -> FurnitureMesh {
        let file = try JSONDecoder().decode(File.self, from: data)
        let version = file.version ?? 1
        guard (1...2).contains(version) else { throw DecodeError.unsupportedVersion(version) }
        var parts: [Part] = []
        for mesh in file.meshes {
            guard mesh.positions.count % 3 == 0, mesh.normals.count == mesh.positions.count,
                  mesh.positions.allSatisfy(\.isFinite), mesh.normals.allSatisfy(\.isFinite)
            else { throw DecodeError.invalid("buffers") }
            switch version {
            case 1: parts += try soupParts(mesh)
            case 2: parts += try indexedParts(mesh)
            default: throw DecodeError.unsupportedVersion(version)
            }
        }
        return FurnitureMesh(version: version, parts: parts)
    }

    private static func material(_ mesh: File.Mesh, _ index: Int?) -> Material {
        let index = index ?? 0
        guard mesh.materials.indices.contains(index) else { return Material(name: "", slot: nil, color: [0.8, 0.8, 0.8]) }
        let source = mesh.materials[index]
        let rgb = source.color.count >= 3 ? Array(source.color.prefix(3)) : [0.8, 0.8, 0.8]
        return Material(name: source.name, slot: source.slot, color: rgb)
    }

    /// v1: a single-material mesh is exported without groups (three.js convention). A group that
    /// runs past the buffers is skipped, as the original loader did.
    private static func soupParts(_ mesh: File.Mesh) throws -> [Part] {
        let vertices = mesh.positions.count / 3
        let groups = mesh.groups.isEmpty ? [File.Group(start: 0, count: vertices, materialIndex: 0)] : mesh.groups
        return groups.compactMap { group in
            guard group.start >= 0, group.count > 0, group.start + group.count <= vertices else { return nil }
            let range = (group.start * 3)..<((group.start + group.count) * 3)
            return Part(meshName: mesh.name, pivot: mesh.pivot, positions: Array(mesh.positions[range]),
                        normals: Array(mesh.normals[range]), uvs: nil,
                        indices: (0..<UInt32(group.count)).map { $0 }, material: material(mesh, group.materialIndex))
        }
    }

    private static func indexedParts(_ mesh: File.Mesh) throws -> [Part] {
        let vertices = mesh.positions.count / 3
        guard let indices = mesh.indices, indices.count % 3 == 0, indices.allSatisfy({ Int($0) < vertices })
        else { throw DecodeError.invalid("indices") }
        if let uvs = mesh.uvs, uvs.count != vertices * 2 || !uvs.allSatisfy(\.isFinite) { throw DecodeError.invalid("uvs") }
        var covered = 0
        var parts: [Part] = []
        for group in mesh.groups {
            guard group.start == covered, group.count > 0, group.count % 3 == 0, group.start + group.count <= indices.count
            else { throw DecodeError.invalid("groups") }
            covered += group.count
            let slice = indices[group.start..<(group.start + group.count)]
            let low = Int(slice.min() ?? 0), high = Int(slice.max() ?? 0)
            parts.append(Part(
                meshName: mesh.name, pivot: mesh.pivot,
                positions: Array(mesh.positions[(low * 3)..<((high + 1) * 3)]),
                normals: Array(mesh.normals[(low * 3)..<((high + 1) * 3)]),
                uvs: mesh.uvs.map { Array($0[(low * 2)..<((high + 1) * 2)]) },
                indices: slice.map { $0 - UInt32(low) },
                material: material(mesh, group.materialIndex)))
        }
        guard covered == indices.count else { throw DecodeError.invalid("groups") }
        return parts
    }
}
