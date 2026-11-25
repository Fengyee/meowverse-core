import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why a cat pack was refused (docs/CAT_PACK.md). Codes only; a file name appears only after it
/// passed `CatPackManifest.isPlainFileName`.
public enum CatPackError: Error, Equatable, Sendable {
    /// Not a ZIP this app can read (or damaged).
    case notArchive
    /// One file, the total, or the number of files is over `CatPackLimits`.
    case tooLarge
    case renderBudgetExceeded
    /// A name in the archive is not a plain relative name (path traversal, hidden, links).
    case unsafeName
    /// The files are inside a folder instead of at the root of the archive.
    case nestedFolder
    case missingManifest
    case badManifest
    case unsupportedFormat
    /// Written for a newer app.
    case newerVersion(Int)
    case invalidID
    case invalidName
    /// A file named by the manifest has a folder, an odd character or the wrong extension.
    case invalidFileName
    case missingFile(String)
    case badMesh(String)
    case badGaits
    case jointCount(Int)
    case badTexture(String)
    case badInspect
    case badPreview
    /// The id belongs to a built-in cat.
    case reservedID
    case writeFailed
    case notFound
}

public enum CatPackPose: String, Sendable, CaseIterable {
    case sit, loaf, sleep
}

/// `cat.json`.
public struct CatPackManifest: Codable, Sendable, Equatable {
    public static let formatName = "meowverse.cat-pack"
    /// 2: the rig file (`groundGaits`) is a cat-rig v2 skeleton carrying every resting action as a clip.
    public static let currentVersion = 2
    public static let maxNameLength = 40

    public struct Poses: Codable, Sendable, Equatable {
        public let sit: String
        public let loaf: String
        public let sleep: String
    }

    public struct Material: Codable, Sendable, Equatable {
        public let baseColor: String
        public let roughness: Double
        public let sleepBaseColor: String?
        public let sleepRoughness: Double?

        /// The sleeping pose falls back to the awake values.
        public func baseColor(sleeping: Bool) -> String { sleeping ? sleepBaseColor ?? baseColor : baseColor }
        public func roughness(sleeping: Bool) -> Double { sleeping ? sleepRoughness ?? roughness : roughness }
    }

    public let format: String
    public let version: Int
    public let id: String
    public let name: String
    public let poses: Poses
    public let groundGaits: String
    public let materials: [String: Material]
    public let inspect: String?
    public let preview: String?
    public let license: String?
    public let attribution: String?
    /// 低 and 高 meshes (`CatPackTiers.swift`); nil in every pack from before tiers, and in a
    /// pack that only has 中. Optional, so the synthesized decoder reads it with
    /// `decodeIfPresent`: a manifest without the key reads as before. Older app versions ignore
    /// the key and show 中.
    public let tiers: CatPackTiers?

    /// Decodes and validates.
    public static func decode(_ data: Data) throws -> CatPackManifest {
        let manifest: CatPackManifest
        do {
            manifest = try JSONDecoder().decode(CatPackManifest.self, from: data)
        } catch {
            throw CatPackError.badManifest
        }
        try manifest.validate()
        return manifest
    }

    public func validate() throws {
        guard format == Self.formatName else { throw CatPackError.unsupportedFormat }
        guard version >= 1 else { throw CatPackError.badManifest }
        guard version <= Self.currentVersion else { throw CatPackError.newerVersion(version) }
        guard Self.isValidID(id) else { throw CatPackError.invalidID }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxNameLength else { throw CatPackError.invalidName }
        guard !materials.isEmpty else { throw CatPackError.badManifest }
        func check(_ file: String, _ extensions: Set<String>) throws {
            guard Self.isPlainFileName(file), file != "cat.json",
                  extensions.contains((file as NSString).pathExtension.lowercased()) else { throw CatPackError.invalidFileName }
        }
        for file in [poses.sit, poses.loaf, poses.sleep, groundGaits] { try check(file, ["json"]) }
        for (role, material) in materials {
            guard !role.isEmpty, role.count <= 40 else { throw CatPackError.badManifest }
            try check(material.baseColor, Self.imageExtensions)
            if let sleep = material.sleepBaseColor { try check(sleep, Self.imageExtensions) }
            for value in [material.roughness, material.sleepRoughness].compactMap({ $0 }) {
                guard value.isFinite, (0...1).contains(value) else { throw CatPackError.badManifest }
            }
        }
        if let inspect { try check(inspect, ["usdz"]) }
        if let preview { try check(preview, Self.imageExtensions) }
        try validateTiers(check: check)
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

    public func file(for pose: CatPackPose) -> String {
        switch pose {
        case .sit: poses.sit
        case .loaf: poses.loaf
        case .sleep: poses.sleep
        }
    }

    /// Meshes, gaits and every texture the materials reference; no duplicates.
    public var requiredFiles: [String] {
        var files = [poses.sit, poses.loaf, poses.sleep, groundGaits]
        for role in materials.keys.sorted() {
            let material = materials[role]!
            files.append(material.baseColor)
            if let sleep = material.sleepBaseColor { files.append(sleep) }
        }
        var seen = Set<String>()
        return files.filter { seen.insert($0).inserted }
    }

    public var optionalFiles: [String] { [inspect, preview].compactMap { $0 } }

    /// Lowercase ASCII letters, digits and hyphens, 1–40 long.
    public static func isValidID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...40).contains(bytes.count) else { return false }
        return bytes.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == UInt8(ascii: "-") }
    }

    /// A name with no folder: the ZIP reader's safe-path rule minus `/`, at most 100 bytes.
    public static func isPlainFileName(_ name: String) -> Bool {
        name.utf8.count <= 100 && !name.contains("/") && ZipReader.isSafePath(name)
    }
}

/// A cat pack whose files can be read: built in (`<id>-<file>` in the app bundle) or imported
/// (`Application Support/CatPacks/<id>/<file>`).
public struct CatPack: Sendable, Equatable, Identifiable {
    public enum Origin: String, Sendable { case builtIn, imported }

    public let manifest: CatPackManifest
    public let origin: Origin
    public let directory: URL
    public let filePrefix: String
    /// Changes when an imported pack is replaced, so caches keyed by `cacheKey` never serve old art.
    public let revision: String

    public var id: String { manifest.id }
    public var cacheKey: String { "\(origin.rawValue):\(id):\(revision)" }

    public init(manifest: CatPackManifest, origin: Origin, directory: URL, filePrefix: String, revision: String) {
        self.manifest = manifest
        self.origin = origin
        self.directory = directory
        self.filePrefix = filePrefix
        self.revision = revision
    }

    public init(installed: InstalledCatPack) {
        self.init(manifest: installed.manifest, origin: .imported, directory: installed.directory, filePrefix: "", revision: installed.revision)
    }

    /// Reads `<id>-cat.json` from a flat resource folder (the app bundle).
    public static func builtIn(id: String, resourceDirectory: URL) throws -> CatPack {
        guard CatPackManifest.isValidID(id) else { throw CatPackError.invalidID }
        let url = resourceDirectory.appending(path: "\(id)-cat.json", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: url) else { throw CatPackError.missingManifest }
        let manifest = try CatPackManifest.decode(data)
        guard manifest.id == id else { throw CatPackError.invalidID }
        return CatPack(manifest: manifest, origin: .builtIn, directory: resourceDirectory, filePrefix: id + "-", revision: "bundle")
    }

    /// `file` must be one of the manifest's names (or `cat.json`).
    public func url(for file: String) -> URL {
        directory.appending(path: filePrefix + file, directoryHint: .notDirectory)
    }

    public func data(_ file: String) throws -> Data {
        guard CatPackManifest.isPlainFileName(file) else { throw CatPackError.invalidFileName }
        do { return try Data(contentsOf: url(for: file)) } catch { throw CatPackError.missingFile(file) }
    }

    /// The high-resolution model, when the manifest names one and it is there.
    public var inspectURL: URL? {
        guard let inspect = manifest.inspect else { return nil }
        let url = url(for: inspect)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - Geometry

/// A baked static pose (`sit.mesh.json` …). Units are room cells, +Y up, feet on y = 0, facing +Z.
public struct CatPoseMesh: Decodable, Sendable {
    public struct Offsets: Decodable, Sendable {
        public let indices: [Int]
        public let positions: [Float]
        public let normals: [Float]
    }

    public struct Part: Decodable, Sendable {
        public let name: String
        public let material: String
        public let positions: [Float]
        public let normals: [Float]
        public let uvs: [Float]
        public let indices: [UInt32]
        /// Vertex offsets for the interaction poses; nil for parts that never move.
        public let targets: [String: Offsets]?
    }

    public let parts: [Part]

    public static func decode(_ data: Data, name: String = "mesh") throws -> CatPoseMesh {
        guard let mesh = try? JSONDecoder().decode(CatPoseMesh.self, from: data) else { throw CatPackError.badMesh(name) }
        guard !mesh.parts.isEmpty else { throw CatPackError.badMesh(name) }
        guard CatPackValidator.fitsMeshBudget(vertices: mesh.parts.map { $0.positions.count / 3 },
                                              indices: mesh.parts.map { $0.indices.count }) else { throw CatPackError.renderBudgetExceeded }
        guard mesh.isValid else { throw CatPackError.badMesh(name) }
        return mesh
    }

    var isValid: Bool {
        parts.allSatisfy { part in
            let count = part.positions.count / 3
            guard count > 0, !part.material.isEmpty, part.positions.count == count * 3,
                  part.normals.count == part.positions.count, part.uvs.count == count * 2,
                  !part.indices.isEmpty, part.indices.count.isMultiple(of: 3),
                  part.indices.allSatisfy({ Int($0) < count }) else { return false }
            return (part.targets ?? [:]).values.allSatisfy { offsets in
                offsets.positions.count == offsets.indices.count * 3 && offsets.normals.count == offsets.positions.count
                    && offsets.indices.allSatisfy { (0..<count).contains($0) }
            }
        }
    }
}

/// `ground-gaits.json`: one skinned mesh, the bind pose and the four floor gaits. A cat-rig v2 file
/// (`skeleton` = `v2Skeleton`, made by scripts/cat-rig) also carries every resting action as a clip, so the
/// room plays sitting, lying, sleeping and the furniture actions on the skeleton instead of baked poses.
public struct CatGaitRig: Decodable, Sendable {
    public static let jointCount = 34
    public static let v2Skeleton = "meowverse.cat-rig/2"
    public static let v2JointRange = 20...128
    public static let requiredClips = ["ground_walk", "graceful_walk", "ground_run", "ground_jump"]
    /// The resting actions a v2 rig must carry (docs/CAT_RIG.md).
    public static let actionClips = ["sit", "loaf", "sleep", "scratch", "bat_high", "bat_ground", "peek_out", "eat", "drink", "dig"]

    public struct Joint: Decodable, Sendable {
        public let name: String
        public let parent: Int?
        /// Column-major 4 × 4.
        public let inverseBind: [Float]
        public let translation: SIMD3<Float>
        public let rotation: SIMD4<Float>
    }

    public struct Part: Decodable, Sendable {
        public let material: String
        public let positions, normals, uvs: [Float]
        public let indices: [UInt32]
        /// Four influences per vertex.
        public let jointIndices: [Int]
        public let weights: [Float]
    }

    public struct Clip: Decodable, Sendable {
        public struct Track: Decodable, Sendable {
            public enum Path: String, Decodable, Sendable { case translation, rotation }
            public let joint: Int
            public let path: Path
            public let values: [Float]
            public var width: Int { path == .rotation ? 4 : 3 }
        }
        public let duration, stride: Double
        /// Loops (most clips) or holds its last frame.
        public let loop: Bool
        /// The fraction of the clip shown as a still frame when motion is reduced.
        public let still: Double
        public let tracks: [Track]

        /// Reduce the numerator before dividing so that a looping clip cannot overflow at large elapsed times.
        public static func phase(_ progress: Double, period: Double, looping: Bool) -> Double {
            guard progress.isFinite, period.isFinite, period > 0, progress > 0 else { return 0 }
            if looping { return progress.truncatingRemainder(dividingBy: period) / period }
            return min(progress, period) / period
        }

        enum CodingKeys: String, CodingKey { case duration, stride, loop, still, tracks }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            duration = try container.decode(Double.self, forKey: .duration)
            stride = try container.decodeIfPresent(Double.self, forKey: .stride) ?? 0
            loop = try container.decodeIfPresent(Bool.self, forKey: .loop) ?? true
            still = try container.decodeIfPresent(Double.self, forKey: .still) ?? 0
            tracks = try container.decode([Track].self, forKey: .tracks)
        }
    }

    /// nil for the 34-joint rig; `v2Skeleton` for rigs made by scripts/cat-rig.
    public let skeleton: String?
    public let scale: Float
    public let joints: [Joint]
    public let parts: [Part]
    public let clips: [String: Clip]

    public static func decode(_ data: Data) throws -> CatGaitRig {
        guard let rig = try? JSONDecoder().decode(CatGaitRig.self, from: data) else { throw CatPackError.badGaits }
        try rig.validate()
        return rig
    }

    /// Every resting action plays on the skeleton.
    public var playsActions: Bool { skeleton == Self.v2Skeleton }

    public func validate() throws {
        if let skeleton {
            guard skeleton == Self.v2Skeleton else { throw CatPackError.badGaits }
            guard Self.v2JointRange.contains(joints.count) else { throw CatPackError.jointCount(joints.count) }
        } else {
            guard joints.count == Self.jointCount else { throw CatPackError.jointCount(joints.count) }
        }
        guard scale.isFinite, scale > 0, Set(joints.map(\.name)).count == joints.count else { throw CatPackError.badGaits }
        for (index, joint) in joints.enumerated() {
            guard !joint.name.isEmpty, joint.inverseBind.count == 16,
                  joint.parent.map({ $0 >= 0 && $0 < index }) ?? true,
                  joint.inverseBind.allSatisfy(\.isFinite),
                  (0..<3).allSatisfy({ joint.translation[$0].isFinite }),
                  Self.isUnitQuaternion(joint.rotation) else { throw CatPackError.badGaits }
        }
        guard !parts.isEmpty else { throw CatPackError.badGaits }
        guard CatPackValidator.fitsMeshBudget(vertices: parts.map { $0.positions.count / 3 },
                                              indices: parts.map { $0.indices.count }),
              clips.count <= 128,
              clips.values.reduce(0, { $0 + $1.tracks.count }) <= 4_096,
              clips.values.reduce(0, { $0 + $1.tracks.reduce(0, { $0 + $1.values.count }) }) <= 2_097_152
        else { throw CatPackError.renderBudgetExceeded }
        for part in parts where !Self.isValid(part, jointCount: joints.count) { throw CatPackError.badGaits }
        for name in Self.requiredClips {
            guard let clip = clips[name], (0.001...1_000).contains(clip.stride) else { throw CatPackError.badGaits }
        }
        if playsActions {
            for name in Self.actionClips where clips[name] == nil { throw CatPackError.badGaits }
        }
        for clip in clips.values {
            guard (0.001...3_600).contains(clip.duration), (0...1_000).contains(clip.stride),
                  clip.still.isFinite, (0...1).contains(clip.still),
                  !clip.tracks.isEmpty, clip.tracks.allSatisfy({ track in
                      joints.indices.contains(track.joint) && track.values.count >= track.width
                          && track.values.count.isMultiple(of: track.width)
                          && track.values.allSatisfy(\.isFinite)
                          && (track.path != .rotation || Swift.stride(from: 0, to: track.values.count, by: 4).allSatisfy { i in
                              Self.isUnitQuaternion(SIMD4(track.values[i], track.values[i + 1], track.values[i + 2], track.values[i + 3]))
                          })
                  }) else { throw CatPackError.badGaits }
        }
    }

    /// One skinned part: consistent arrays, four influences per vertex, joints in range.
    /// Shared with a tier's `CatSkin`.
    static func isValid(_ part: Part, jointCount: Int) -> Bool {
        let count = part.positions.count / 3
        return count > 0 && !part.material.isEmpty && part.positions.count == count * 3
            && part.normals.count == part.positions.count && part.uvs.count == count * 2
            && part.weights.count == count * 4 && part.jointIndices.count == part.weights.count
            && !part.indices.isEmpty && part.indices.count.isMultiple(of: 3)
            && part.indices.allSatisfy({ Int($0) < count })
            && part.jointIndices.allSatisfy({ (0..<jointCount).contains($0) })
            && part.positions.allSatisfy(\.isFinite) && part.normals.allSatisfy(\.isFinite) && part.uvs.allSatisfy(\.isFinite)
            && (0..<count).allSatisfy({ vertex in
                let w = part.weights[vertex * 4 ..< vertex * 4 + 4]
                return w.allSatisfy({ $0.isFinite && $0 >= 0 }) && abs(w.reduce(0, +) - 1) <= weightTolerance
            })
    }

    /// The exporter (scripts/cat-rig) writes normalised weights and unit quaternions; this allows
    /// for its float rounding, not for a different meaning (D24-06).
    static let weightTolerance: Float = 0.01

    /// A rotation RealityKit can use as is: finite and of unit length, within export rounding.
    /// A zero or scaled quaternion would collapse or stretch the joint.
    static func isUnitQuaternion(_ q: SIMD4<Float>) -> Bool {
        guard (0..<4).allSatisfy({ q[$0].isFinite }) else { return false }
        return abs((q * q).sum() - 1) <= 0.02
    }
}

// MARK: - Validation

public enum CatPackValidator {
    /// Largest texture edge accepted (pixels).
    public static let maxTextureEdge = 8192

    public static let roomTextureEdge = 2048

    static func fitsMeshBudget(vertices: [Int], indices: [Int]) -> Bool {
        (1...128).contains(vertices.count) && vertices.reduce(0, +) <= 65_536 && indices.reduce(0, +) <= 393_216
    }

    /// Checks every distinct file. The texture budget counts the source dimensions before downsampling,
    /// per tier: the room wears one tier's textures at a time.
    ///
    /// `tiers`: which of the manifest's tiers to check as well; nil checks every tier it declares
    /// (an imported pack carries them all). A built-in pack's tiers are downloaded, not in the
    /// bundle, so its bundle is checked with `tiers: []`.
    public static func validate(manifest: CatPackManifest, limits: CatPackLimits = .standard, tiers: [CatMeshTier]? = nil,
                                file: (String) throws -> Data?) throws {
        let textures = Set(manifest.materials.values.flatMap { [$0.baseColor, $0.sleepBaseColor].compactMap { $0 } })
        var remaining = limits.maxTotalTexturePixels
        var pixels: [String: Int] = [:]
        var rig: CatGaitRig?
        for name in Set(manifest.requiredFiles + manifest.optionalFiles).sorted() {
            guard let data = try file(name) else { throw CatPackError.missingFile(name) }
            if CatPackPose.allCases.contains(where: { manifest.file(for: $0) == name }) {
                _ = try CatPoseMesh.decode(data, name: name)
            }
            if name == manifest.groundGaits { rig = try CatGaitRig.decode(data) }
            if textures.contains(name) {
                guard let count = imagePixels(data) else { throw CatPackError.badTexture(name) }
                guard count <= remaining else { throw CatPackError.renderBudgetExceeded }
                remaining -= count
                pixels[name] = count
            }
            if name == manifest.inspect {
                guard data.count > 4, data.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]) else { throw CatPackError.badInspect }
            }
            if name == manifest.preview, imagePixels(data) == nil { throw CatPackError.badPreview }
        }

        for tier in (tiers ?? manifest.declaredTiers) where tier != .medium {
            guard let entry = manifest.tier(tier) else { continue }
            // Its own meshes on 中's textures come out scrambled (`textureGap`): refused, not shown.
            guard manifest.textureGap(of: tier) == nil else { throw CatPackError.badManifest }
            for name in entry.files {
                guard let data = try file(name) else { throw CatPackError.missingFile(name) }
                if name == entry.skin {
                    guard let rig else { throw CatPackError.badGaits }
                    _ = try CatSkin.decode(data, name: name, for: rig)
                } else if CatPackPose.allCases.contains(where: { entry.poseFile($0) == name }) {
                    _ = try CatPoseMesh.decode(data, name: name)
                } else {
                    guard let count = imagePixels(data) else { throw CatPackError.badTexture(name) }
                    pixels[name] = count
                }
            }
            let worn = manifest.textures(tier: tier).reduce(0) { $0 + (pixels[$1] ?? 0) }
            guard worn <= limits.maxTotalTexturePixels else { throw CatPackError.renderBudgetExceeded }
        }
    }

    public static func imagePixels(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png, .jpeg, .webP].map(\.identifier).contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...maxTextureEdge).contains(width), (1...maxTextureEdge).contains(height) else { return nil }
        return width * height
    }
}
