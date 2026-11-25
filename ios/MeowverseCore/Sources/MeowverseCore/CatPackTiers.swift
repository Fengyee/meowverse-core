import Foundation
import Observation

// 猫的网格档 (owner, 2026-11-20). The app bundle carries 中 only: the files every cat pack has
// (`poses`, `groundGaits`, `materials`) are the 中 cat. A pack may add 低 (and later 高) under
// `tiers`; a tier shares the skeleton and every clip with 中 and replaces only the files it
// lists: the skinned mesh (`skin`), the three still poses and textures. Furniture has no tiers.
// Format: docs/CAT_PACK.md, "画质档". Download: docs/CAT_PACK.md, "按需下载".

/// Which cat meshes the room shows. 中 is always there; 低 and 高 only when the pack has them
/// and (for a built-in pack) they are downloaded.
public enum CatMeshTier: String, Sendable, CaseIterable, Comparable, Codable {
    case low, medium, high

    /// 设置 › 画质 as resolved (自动 already decided): the same step for the cat.
    public init(_ quality: RenderQualityTier) {
        switch quality {
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        }
    }

    private var order: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.order < b.order }
}

/// `tiers` in `cat.json`. Only `low` and `high` are read; any other key (a later tier, or a
/// stray `medium`) is ignored, so a newer pack still opens here.
public struct CatPackTiers: Codable, Sendable, Equatable {
    public let low: CatPackTier?
    public let high: CatPackTier?
}

/// One tier: every field is optional and names a file that takes the place of 中's.
public struct CatPackTier: Codable, Sendable, Equatable {
    public struct Poses: Codable, Sendable, Equatable {
        public let sit: String?
        public let loaf: String?
        public let sleep: String?
    }

    /// Fields left out keep 中's value for that role (a 低 awake coat with 中's sleeping coat).
    public struct Material: Codable, Sendable, Equatable {
        public let baseColor: String?
        public let roughness: Double?
        public let sleepBaseColor: String?
        public let sleepRoughness: Double?

        var isEmpty: Bool { baseColor == nil && roughness == nil && sleepBaseColor == nil && sleepRoughness == nil }
    }

    /// A `CatSkin` file: the skinned mesh on 中's skeleton.
    public let skin: String?
    public let poses: Poses?
    /// Keyed by the roles of the manifest's `materials`.
    public let materials: [String: Material]?

    public func poseFile(_ pose: CatPackPose) -> String? {
        switch pose {
        case .sit: poses?.sit
        case .loaf: poses?.loaf
        case .sleep: poses?.sleep
        }
    }

    /// Every file this tier names, once each.
    public var files: [String] {
        var names = [skin].compactMap { $0 } + CatPackPose.allCases.compactMap(poseFile)
        for role in (materials ?? [:]).keys.sorted() {
            let material = materials![role]!
            names += [material.baseColor, material.sleepBaseColor].compactMap { $0 }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}

extension CatPackManifest {
    /// nil for 中 (the manifest's own fields).
    public func tier(_ tier: CatMeshTier) -> CatPackTier? {
        switch tier {
        case .low: tiers?.low
        case .medium: nil
        case .high: tiers?.high
        }
    }

    /// 中 and every tier the manifest adds, low to high.
    public var declaredTiers: [CatMeshTier] {
        CatMeshTier.allCases.filter { $0 == .medium || tier($0) != nil }
    }

    /// The files a tier brings; empty for 中.
    public func files(of tier: CatMeshTier) -> [String] { self.tier(tier)?.files ?? [] }

    /// Every tier's files (all distinct from each other and from the base files).
    public var tierFiles: [String] { CatMeshTier.allCases.flatMap(files(of:)) }

    public func poseFile(_ pose: CatPackPose, tier: CatMeshTier) -> String {
        self.tier(tier)?.poseFile(pose) ?? file(for: pose)
    }

    /// nil: the cat wears the skinned mesh in `groundGaits`.
    public func skinFile(tier: CatMeshTier) -> String? { self.tier(tier)?.skin }

    /// The role's material on this tier: the tier's fields over 中's.
    public func material(_ role: String, tier: CatMeshTier) -> Material? {
        guard let base = materials[role] else { return nil }
        guard let over = self.tier(tier)?.materials?[role] else { return base }
        return Material(baseColor: over.baseColor ?? base.baseColor, roughness: over.roughness ?? base.roughness,
                        sleepBaseColor: over.sleepBaseColor ?? base.sleepBaseColor,
                        sleepRoughness: over.sleepRoughness ?? base.sleepRoughness)
    }

    /// The textures the cat wears on this tier, awake and asleep.
    public func textures(tier: CatMeshTier) -> Set<String> {
        Set(materials.keys.compactMap { material($0, tier: tier) }.flatMap { [$0.baseColor, $0.sleepBaseColor].compactMap { $0 } })
    }

    /// A tier that brings any mesh of its own (the skin or a pose) has its own UVs, so 中's
    /// textures would come out scrambled on it. Such a tier must give every role its own
    /// `baseColor`, and its own `sleepBaseColor` wherever 中 has one. Returns the first role
    /// (sorted) that would borrow 中's texture; nil when nothing is borrowed, for 中, for a tier
    /// the pack does not have, and for a tier that replaces only textures (it keeps 中's UVs).
    /// A tier with a gap is never worn (`CatPack.variant`), and an import carrying one is refused.
    public func textureGap(of tier: CatMeshTier) -> String? {
        guard let entry = self.tier(tier) else { return nil }
        guard entry.skin != nil || CatPackPose.allCases.contains(where: { entry.poseFile($0) != nil }) else { return nil }
        for role in materials.keys.sorted() {
            let own = entry.materials?[role]
            if own?.baseColor == nil { return role }
            if materials[role]?.sleepBaseColor != nil, own?.sleepBaseColor == nil { return role }
        }
        return nil
    }

    /// Part of `validate()`: each tier replaces at least one file, names plain files of the right
    /// kind, only replaces roles the pack has, and shares no file with 中 or another tier.
    func validateTiers(check: (String, Set<String>) throws -> Void) throws {
        guard tiers != nil else { return }
        var seen = Set(requiredFiles + optionalFiles + ["cat.json"])
        for name in [CatMeshTier.low, .high] {
            guard let entry = tier(name) else { continue }
            guard !entry.files.isEmpty else { throw CatPackError.badManifest }
            let meshes = [entry.skin].compactMap { $0 } + CatPackPose.allCases.compactMap(entry.poseFile)
            guard Set(meshes).count == meshes.count else { throw CatPackError.badManifest }
            for file in meshes { try check(file, ["json"]) }
            for (role, material) in entry.materials ?? [:] {
                guard materials[role] != nil, !material.isEmpty else { throw CatPackError.badManifest }
                for file in [material.baseColor, material.sleepBaseColor].compactMap({ $0 }) { try check(file, Self.imageExtensions) }
                for value in [material.roughness, material.sleepRoughness].compactMap({ $0 }) {
                    guard value.isFinite, (0...1).contains(value) else { throw CatPackError.badManifest }
                }
            }
            for file in entry.files { guard seen.insert(file).inserted else { throw CatPackError.badManifest } }
        }
    }
}

// MARK: - Skin

/// A tier's skinned mesh (`skin` in a tier): `ground-gaits.json`'s `parts` for another mesh on
/// the same skeleton. The joints (and their bind pose) and the clips are 中's; `jointNames` must
/// list 中's joints in order, so a mesh bound to another skeleton is refused instead of drawn
/// torn apart.
public struct CatSkin: Decodable, Sendable {
    public static let formatName = "meowverse.cat-skin/1"

    public let format: String
    /// The same as the rig's `skeleton` (nil for a 34-joint rig).
    public let skeleton: String?
    public let jointNames: [String]
    public let parts: [CatGaitRig.Part]

    public static func decode(_ data: Data, name: String, for rig: CatGaitRig) throws -> CatSkin {
        guard let skin = try? JSONDecoder().decode(CatSkin.self, from: data), skin.format == formatName,
              skin.skeleton == rig.skeleton, skin.jointNames == rig.joints.map(\.name) else { throw CatPackError.badMesh(name) }
        guard CatPackValidator.fitsMeshBudget(vertices: skin.parts.map { $0.positions.count / 3 },
                                              indices: skin.parts.map { $0.indices.count }) else {
            throw skin.parts.isEmpty ? CatPackError.badMesh(name) : CatPackError.renderBudgetExceeded
        }
        guard skin.parts.allSatisfy({ CatGaitRig.isValid($0, jointCount: rig.joints.count) }) else { throw CatPackError.badMesh(name) }
        return skin
    }
}

extension CatGaitRig {
    /// The same skeleton and clips with the skin's mesh.
    public func wearing(_ skin: CatSkin) -> CatGaitRig {
        CatGaitRig(skeleton: skeleton, scale: scale, joints: joints, parts: skin.parts, clips: clips)
    }
}

// MARK: - Choosing a tier

/// Where a tier's files are: a downloaded asset pack's folder, or an imported pack's own folder.
public struct CatTierLocation: Sendable, Hashable {
    public let directory: URL
    public let prefix: String

    public init(directory: URL, prefix: String = "") {
        self.directory = directory
        self.prefix = prefix
    }

    public func url(for file: String) -> URL {
        directory.appending(path: prefix + file, directoryHint: .notDirectory)
    }
}

/// A cat pack on one tier: which file to read for each part of the cat, and from where.
public struct CatPackVariant: Sendable, Equatable {
    public let pack: CatPack
    public let tier: CatMeshTier
    /// nil on 中.
    public let location: CatTierLocation?

    /// For caches and the room's "which cat is shown" (`-MeowverseCatProbe`).
    public var key: String { "\(pack.cacheKey)#\(tier.rawValue)" }
    public var manifest: CatPackManifest { pack.manifest }

    public var skinFile: String? { manifest.skinFile(tier: tier) }

    /// Whether the room may show this variant on its baked poses when its skeleton does not load
    /// (G24-01). Only 中: a 低/高 whose skin or rig fails is unusable, so the room falls back to 中
    /// (which walks) and says so, instead of a still 低 cat reported as 低 ready.
    public var showsPosesWithoutSkeleton: Bool { tier == .medium }

    public func poseFile(_ pose: CatPackPose) -> String { manifest.poseFile(pose, tier: tier) }
    public func material(_ role: String) -> CatPackManifest.Material? { manifest.material(role, tier: tier) }

    /// The tier's own files come from its location; everything shared comes from the pack.
    public func url(for file: String) -> URL {
        if let location, manifest.files(of: tier).contains(file) { return location.url(for: file) }
        return pack.url(for: file)
    }

    public func data(_ file: String) throws -> Data {
        guard CatPackManifest.isPlainFileName(file) else { throw CatPackError.invalidFileName }
        do { return try Data(contentsOf: url(for: file)) } catch { throw CatPackError.missingFile(file) }
    }
}

extension CatPack {
    /// The pack's own files: 中.
    public var baseVariant: CatPackVariant { CatPackVariant(pack: self, tier: .medium, location: nil) }

    /// An imported pack carries its tiers in its own folder (they were checked on import); a
    /// built-in pack's tiers are downloaded (`CatTierDownloads`).
    public func location(of tier: CatMeshTier, downloaded: CatTierLocation?) -> CatTierLocation? {
        guard tier != .medium, manifest.tier(tier) != nil else { return nil }
        switch origin {
        case .imported: return CatTierLocation(directory: directory, prefix: filePrefix)
        case .builtIn: return downloaded
        }
    }

    /// The room's cat: the wanted tier when it is there, else 中. A tier that failed to load
    /// (`unusable`) is 中 too, and so is one that would borrow 中's textures (`textureGap`).
    public func variant(for wanted: CatMeshTier, downloaded: [CatMeshTier: CatTierLocation],
                        unusable: Set<CatMeshTier> = []) -> CatPackVariant {
        guard !unusable.contains(wanted), manifest.textureGap(of: wanted) == nil,
              let location = location(of: wanted, downloaded: downloaded[wanted]) else { return baseVariant }
        return CatPackVariant(pack: self, tier: wanted, location: location)
    }

    /// For one-off pictures (the postcard): the finest tier there is, never below 中.
    public func bestVariant(downloaded: [CatMeshTier: CatTierLocation], unusable: Set<CatMeshTier> = []) -> CatPackVariant {
        for tier in CatMeshTier.allCases.reversed() where tier > .medium {
            let variant = variant(for: tier, downloaded: downloaded, unusable: unusable)
            if variant.tier == tier { return variant }
        }
        return baseVariant
    }

    /// What a built-in pack can download: one asset pack per tier. Imported packs need none.
    public var downloadRequests: [CatTierRequest] {
        guard origin == .builtIn else { return [] }
        return manifest.declaredTiers.filter { $0 != .medium }.map { CatTierRequest(packID: id, tier: $0, files: manifest.files(of: $0)) }
    }

    public func downloadRequest(for tier: CatMeshTier) -> CatTierRequest? {
        downloadRequests.first { $0.tier == tier }
    }
}

// MARK: - Downloads

/// One downloadable tier of a built-in cat: one Background Assets asset pack
/// (`cat-<id>-<tier>`) whose files sit in `cats/<id>/<tier>/` (docs/CAT_PACK.md, "按需下载").
public struct CatTierRequest: Hashable, Sendable {
    public let packID: String
    public let tier: CatMeshTier
    /// The tier's files, all expected in the folder.
    public let files: [String]

    public init(packID: String, tier: CatMeshTier, files: [String]) {
        self.packID = packID
        self.tier = tier
        self.files = files
    }

    public var assetPackID: String { "cat-\(packID)-\(tier.rawValue)" }
    /// Relative to the asset packs' shared root.
    public var folder: String { "cats/\(packID)/\(tier.rawValue)" }
}

public enum CatTierDownloadFailure: Equatable, Sendable {
    /// The transport threw (no network, no space, not hosted yet). The text is for the log.
    case transport(String)
    /// It finished but a file the manifest names is not in the folder.
    case incomplete(String)
    /// The files were there but the room could not load them (`markUnusable`).
    case unusable
    /// This build or system cannot download asset packs at all.
    case unavailable
}

public enum CatTierDownloadState: Equatable, Sendable {
    /// 未下载
    case notDownloaded
    /// 下载中, with the fraction when the system reports one.
    case downloading(Double?)
    /// 已就绪
    case ready(CatTierLocation)
    /// 失败: 中 is used until `retry`.
    case failed(CatTierDownloadFailure)
}

public enum CatTierTransportError: Error, Equatable {
    case unavailable
}

/// How a tier's files get onto the device. The app uses Background Assets; tests use a fake.
public protocol CatTierTransport: Sendable {
    /// The folder when the asset pack is already on this device; nil when it would have to be
    /// downloaded. Must not download.
    func installed(_ request: CatTierRequest) async -> URL?
    /// Downloads the asset pack (or waits for one in progress) and returns its folder.
    /// `progress` gets fractions from 0 to 1 on any thread. Throw `CatTierTransportError.unavailable`
    /// when this device or build cannot download at all.
    func download(_ request: CatTierRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// No downloads: an older system, or a build without the Background Assets extension.
public struct UnavailableCatTierTransport: CatTierTransport {
    public init() {}
    public func installed(_ request: CatTierRequest) async -> URL? { nil }
    public func download(_ request: CatTierRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        throw CatTierTransportError.unavailable
    }
}

/// 未下载 / 下载中 / 已就绪 / 失败 for every downloadable cat tier. Nothing here blocks: while a
/// tier is not ready the room shows 中. A result that arrives after the tier was cancelled or
/// asked for again is dropped (a run's generation must still be current), so a late download
/// never overwrites a newer state.
@MainActor
@Observable
public final class CatTierDownloads {
    private struct Key: Hashable {
        let packID: String
        let tier: CatMeshTier
    }

    private var states: [Key: CatTierDownloadState] = [:]
    @ObservationIgnored private var runs: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [Key: Int] = [:]
    @ObservationIgnored private let transport: any CatTierTransport

    public init(transport: any CatTierTransport) {
        self.transport = transport
    }

    public func state(of request: CatTierRequest) -> CatTierDownloadState {
        state(packID: request.packID, tier: request.tier)
    }

    public func state(packID: String, tier: CatMeshTier) -> CatTierDownloadState {
        states[Key(packID: packID, tier: tier)] ?? .notDownloaded
    }

    /// The pack's tiers that are 已就绪, for `CatPack.variant`.
    public func downloaded(packID: String) -> [CatMeshTier: CatTierLocation] {
        var result: [CatMeshTier: CatTierLocation] = [:]
        for (key, state) in states where key.packID == packID {
            if case .ready(let location) = state { result[key.tier] = location }
        }
        return result
    }

    /// Tiers that failed to load in the room: shown as 中 until retried.
    public func unusable(packID: String) -> Set<CatMeshTier> {
        Set(states.filter { $0.key.packID == packID && $0.value == .failed(.unusable) }.map(\.key.tier))
    }

    /// Starts a tier that is 未下载. Does nothing while it downloads, once it is ready, or after
    /// it failed: safe to call whenever the room wants the tier.
    public func ensure(_ request: CatTierRequest) {
        guard state(of: request) == .notDownloaded else { return }
        start(request)
    }

    /// Like `ensure`, and also tries a failed tier again (the user picked the tier again, or the
    /// app was opened again).
    public func retry(_ request: CatTierRequest) {
        switch state(of: request) {
        case .notDownloaded: start(request)
        // The folder already on the device is what failed: ask the transport for it again
        // instead of trusting it once more (D24-07).
        case .failed: start(request, trustsInstalled: false)
        case .downloading, .ready: return
        }
    }

    /// Back to 未下载; a run still in flight is dropped when it finishes.
    public func cancel(_ request: CatTierRequest) {
        let key = Key(packID: request.packID, tier: request.tier)
        generations[key, default: 0] += 1
        runs[key]?.cancel()
        runs[key] = nil
        states[key] = nil
    }

    /// The room could not load the tier's files: 中 until `retry`.
    public func markUnusable(packID: String, tier: CatMeshTier) {
        let key = Key(packID: packID, tier: tier)
        generations[key, default: 0] += 1
        runs[key]?.cancel()
        runs[key] = nil
        states[key] = .failed(.unusable)
    }

    /// Waits for the run in flight, if any (tests and drills).
    public func settle(_ request: CatTierRequest) async {
        await runs[Key(packID: request.packID, tier: request.tier)]?.value
    }

    private func start(_ request: CatTierRequest, trustsInstalled: Bool = true) {
        let key = Key(packID: request.packID, tier: request.tier)
        generations[key, default: 0] += 1
        let generation = generations[key]!
        states[key] = .downloading(nil)
        let transport = self.transport
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            guard let self else { return }
            Task { @MainActor in self.progress(key, generation, fraction) }
        }
        runs[key] = Task { [weak self] in
            var outcome: CatTierDownloadState = .notDownloaded
            if trustsInstalled, let folder = await transport.installed(request) {
                outcome = Self.check(folder, for: request)
            }
            // Not on the device, or on it but missing a file: download (D24-07). The downloaded
            // folder's check is final, so a pack that really is incomplete still fails once.
            if case .ready = outcome {} else {
                do {
                    let folder = try await transport.download(request, progress: report)
                    outcome = Self.check(folder, for: request)
                } catch CatTierTransportError.unavailable {
                    outcome = .failed(.unavailable)
                } catch {
                    outcome = .failed(.transport(String(describing: error)))
                }
            }
            self?.finish(key, generation, outcome)
        }
    }

    private nonisolated static func check(_ folder: URL, for request: CatTierRequest) -> CatTierDownloadState {
        let location = CatTierLocation(directory: folder)
        for file in request.files where !FileManager.default.fileExists(atPath: location.url(for: file).path) {
            return .failed(.incomplete(file))
        }
        return .ready(location)
    }

    private func progress(_ key: Key, _ generation: Int, _ fraction: Double) {
        guard generations[key] == generation, case .downloading = states[key] else { return }
        states[key] = .downloading(min(max(fraction, 0), 1))
    }

    private func finish(_ key: Key, _ generation: Int, _ outcome: CatTierDownloadState) {
        guard generations[key] == generation, case .downloading = states[key] else { return }
        states[key] = outcome
        runs[key] = nil
    }
}
