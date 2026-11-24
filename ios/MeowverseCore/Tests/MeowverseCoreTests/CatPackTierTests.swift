import Foundation
import Testing
@testable import MeowverseCore

/// 猫的网格档 (owner, 2026-11-20): the app ships 中 only; 低 (later 高) is downloaded on demand.
/// A tier shares the skeleton and the clips with 中 and replaces only the skinned mesh, the three
/// still poses and the textures it lists (docs/CAT_PACK.md, "画质档").
enum CatTierFixture {
    /// A 低 entry that replaces everything a tier can replace.
    static var fullLow: [String: Any] { [
        "skin": "low-skin.json",
        "poses": ["sit": "low-sit.mesh.json", "loaf": "low-loaf.mesh.json", "sleep": "low-sleep.mesh.json"],
        "materials": ["coat": ["baseColor": "low-coat.png"]],
    ] }

    static func manifest(low: [String: Any]? = fullLow, extraTiers: [String: Any] = [:], version: Int = 2) -> [String: Any] {
        var json = CatPackFixture.manifest(extra: ["version": version])
        var tiers = extraTiers
        if let low { tiers["low"] = low }
        if !tiers.isEmpty { json["tiers"] = tiers }
        return json
    }

    static func gaits() -> Data {
        CatPackFixture.gaits(jointCount: 48, clips: CatGaitRig.requiredClips + CatGaitRig.actionClips, skeleton: CatGaitRig.v2Skeleton)
    }

    /// A skin for the fixture rig: the same joints by name, one triangle on joint `joint`.
    static func skin(jointNames: [String] = (0..<48).map { "joint\($0)" }, skeleton: String? = CatGaitRig.v2Skeleton,
                     format: String = CatSkin.formatName, joint: Int = 2) -> Data {
        var json: [String: Any] = [
            "format": format,
            "jointNames": jointNames,
            "parts": [[
                "material": "coat",
                "positions": [0, 0, 0, 0.5, 0, 0, 0, 0.5, 0],
                "normals": [0, 0, 1, 0, 0, 1, 0, 0, 1],
                "uvs": [0, 0, 1, 0, 0, 1],
                "indices": [0, 1, 2],
                "jointIndices": [joint, 0, 0, 0, joint, 0, 0, 0, joint, 0, 0, 0],
                "weights": [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0],
            ]],
        ]
        if let skeleton { json["skeleton"] = skeleton }
        return CatPackFixture.json(json)
    }

    /// Every file of a v2 pack with a full 低 tier, in one folder (an imported pack).
    static func files(manifest: [String: Any] = manifest()) -> [String: Data] {
        var files = CatPackFixture.files(manifest: manifest)
        files["ground-gaits.json"] = gaits()
        files["low-skin.json"] = skin()
        for pose in ["sit", "loaf", "sleep"] { files["low-\(pose).mesh.json"] = CatPackFixture.poseMesh() }
        files["low-coat.png"] = TestSupport.imageData(width: 4, height: 4, type: .png)
        return files
    }

    static func writeFolder(_ files: [String: Data], prefix: String = "", in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: dir.appending(path: prefix + name)) }
    }

    static func builtIn(_ manifest: [String: Any] = manifest(), in dir: URL) throws -> CatPack {
        var files = files(manifest: manifest)
        // A built-in pack's 低 files are not in the app bundle: they are downloaded.
        for name in ["low-skin.json", "low-sit.mesh.json", "low-loaf.mesh.json", "low-sleep.mesh.json", "low-coat.png"] {
            files[name] = nil
        }
        try writeFolder(files, prefix: "test-cat-", in: dir)
        return try CatPack.builtIn(id: "test-cat", resourceDirectory: dir)
    }

    static var bundledArt: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Meowverse/Resources/Art")
    }
}

@Suite("Cat pack tiers: format")
struct CatPackTierFormatTests {
    @Test("render tiers map one to one onto cat tiers, 低 < 中 < 高")
    func renderTiers() {
        #expect(CatMeshTier(RenderQualityTier.low) == .low)
        #expect(CatMeshTier(RenderQualityTier.medium) == .medium)
        #expect(CatMeshTier(RenderQualityTier.high) == .high)
        #expect(CatMeshTier.low < .medium && CatMeshTier.medium < .high)
    }

    @Test("a manifest from before tiers (no `tiers` key) still reads, and has 中 only")
    func manifestWithoutTiers() throws {
        let json = CatPackFixture.manifest()
        #expect(json["tiers"] == nil)
        let manifest = try CatPackManifest.decode(CatPackFixture.json(json))
        #expect(manifest.tiers == nil)
        #expect(manifest.declaredTiers == [.medium])
        #expect(manifest.tierFiles.isEmpty)
        for tier in CatMeshTier.allCases {
            #expect(manifest.tier(tier) == nil)
            #expect(manifest.files(of: tier).isEmpty)
        }
    }

    @Test("the bundled Bella manifest, written before tiers, reads with 中 only")
    func bundledBellaManifest() throws {
        let url = CatTierFixture.bundledArt.appending(path: "bella-cat.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        // This test is about a manifest without the key; when the bundled one gains tiers, strip them.
        var old = raw
        old["tiers"] = nil
        let manifest = try CatPackManifest.decode(CatPackFixture.json(old))
        #expect(manifest.declaredTiers == [.medium])
    }

    @Test("a 低 tier lists only the files it replaces")
    func lowTier() throws {
        let manifest = try CatPackManifest.decode(CatPackFixture.json(CatTierFixture.manifest()))
        #expect(manifest.declaredTiers == [.low, .medium])
        let low = try #require(manifest.tier(.low))
        #expect(low.skin == "low-skin.json")
        #expect(Set(manifest.files(of: .low)) == ["low-skin.json", "low-sit.mesh.json", "low-loaf.mesh.json", "low-sleep.mesh.json", "low-coat.png"])
        #expect(manifest.tier(.medium) == nil)
        #expect(manifest.tier(.high) == nil)
        // The base files are not repeated, and the base lists are unchanged.
        #expect(!manifest.requiredFiles.contains("low-skin.json"))
        #expect(Set(manifest.requiredFiles) == ["sit.mesh.json", "loaf.mesh.json", "sleep.mesh.json", "ground-gaits.json", "coat.png"])
    }

    @Test("a tier may replace only some of the meshes; the rest come from 中")
    func partialTier() throws {
        let low: [String: Any] = ["poses": ["sleep": "low-sleep.mesh.json"], "materials": ["coat": ["baseColor": "low-coat.png"]]]
        let manifest = try CatPackManifest.decode(CatPackFixture.json(CatTierFixture.manifest(low: low)))
        #expect(manifest.files(of: .low) == ["low-sleep.mesh.json", "low-coat.png"])
        #expect(manifest.poseFile(.sleep, tier: .low) == "low-sleep.mesh.json")
        #expect(manifest.poseFile(.sit, tier: .low) == "sit.mesh.json")
        #expect(manifest.skinFile(tier: .low) == nil)
        #expect(manifest.material("coat", tier: .low)?.roughness == manifest.materials["coat"]?.roughness)
        // Textures are another matter: CatPackTierTextureTests.
        #expect(manifest.textureGap(of: .low) == nil)
    }

    @Test("a tier's material keeps 中's values for every field it leaves out")
    func materialMerge() throws {
        var json = CatTierFixture.manifest(low: ["materials": ["coat": ["baseColor": "low-coat.webp"]]])
        json["materials"] = ["coat": ["baseColor": "coat.webp", "sleepBaseColor": "sleep-coat.webp", "roughness": 0.7]]
        let manifest = try CatPackManifest.decode(CatPackFixture.json(json))
        let coat = try #require(manifest.material("coat", tier: .low))
        #expect(coat.baseColor(sleeping: false) == "low-coat.webp")
        // Sleeping keeps the sleeping coat (closed eyes) rather than the awake low one.
        #expect(coat.baseColor(sleeping: true) == "sleep-coat.webp")
        #expect(coat.roughness(sleeping: false) == 0.7)
        #expect(manifest.textures(tier: .low) == ["low-coat.webp", "sleep-coat.webp"])
        #expect(manifest.textures(tier: .medium) == ["coat.webp", "sleep-coat.webp"])
    }

    @Test("tier names this version does not know (and a stray 中) are ignored, not refused")
    func unknownTiers() throws {
        let json = CatTierFixture.manifest(extraTiers: ["ultra": ["skin": 42, "whatever": true],
                                                        "medium": ["skin": "medium-skin.json"]])
        let manifest = try CatPackManifest.decode(CatPackFixture.json(json))
        #expect(manifest.declaredTiers == [.low, .medium])
        #expect(manifest.tier(.medium) == nil)
    }

    @Test("a tier entry is checked like the rest of the manifest", arguments: [
        // Nothing to replace.
        #"{"materials": {}}"#,
        #"{}"#,
        // A folder, a wrong extension, a base file reused, cat.json, one file for two meshes.
        #"{"skin": "low/skin.json"}"#,
        #"{"skin": "low-skin.png"}"#,
        #"{"poses": {"sit": "sit.mesh.json"}}"#,
        #"{"skin": "cat.json"}"#,
        #"{"materials": {"coat": {"baseColor": "coat.png"}}}"#,
        #"{"skin": "low.json", "poses": {"sit": "low.json"}}"#,
        // A role the pack does not have, a material that changes nothing, a bad roughness.
        #"{"materials": {"eye": {"baseColor": "low-eye.png"}}}"#,
        #"{"materials": {"coat": {}}}"#,
        #"{"materials": {"coat": {"roughness": 1.5}}}"#,
        // A wrong type.
        #"{"skin": 3}"#,
    ])
    func badTier(entry: String) throws {
        let low = try #require(try JSONSerialization.jsonObject(with: Data(entry.utf8)) as? [String: Any])
        let data = CatPackFixture.json(CatTierFixture.manifest(low: low))
        #expect(throws: CatPackError.self) { try CatPackManifest.decode(data) }
    }

    @Test("two tiers cannot share a file: every tier's files fit in one folder")
    func tiersDoNotShareFiles() {
        let json = CatTierFixture.manifest(extraTiers: ["high": ["skin": "low-skin.json"]])
        #expect(throws: CatPackError.badManifest) { try CatPackManifest.decode(CatPackFixture.json(json)) }
    }

    @Test("the manifest round-trips through Codable with its tiers")
    func roundTrip() throws {
        let manifest = try CatPackManifest.decode(CatPackFixture.json(CatTierFixture.manifest()))
        let again = try CatPackManifest.decode(JSONEncoder().encode(manifest))
        #expect(again == manifest)
    }
}

@Suite("Cat pack tiers: skin")
struct CatSkinTests {
    private func rig() throws -> CatGaitRig { try CatGaitRig.decode(CatTierFixture.gaits()) }

    @Test("a skin on the same skeleton replaces the mesh and keeps the joints, bind pose and clips")
    func wearing() throws {
        let rig = try rig()
        let skin = try CatSkin.decode(CatTierFixture.skin(), name: "low-skin.json", for: rig)
        let worn = rig.wearing(skin)
        #expect(worn.parts.count == 1)
        #expect(worn.parts[0].jointIndices[0] == 2)
        #expect(worn.parts[0].positions == [0, 0, 0, 0.5, 0, 0, 0, 0.5, 0])
        #expect(worn.joints.map(\.name) == rig.joints.map(\.name))
        #expect(worn.joints.map(\.inverseBind) == rig.joints.map(\.inverseBind))
        #expect(Set(worn.clips.keys) == Set(rig.clips.keys))
        #expect(worn.scale == rig.scale && worn.skeleton == rig.skeleton)
        #expect(worn.playsActions)
        try worn.validate()
    }

    @Test("a skin made for another skeleton is refused", arguments: [
        CatTierFixture.skin(jointNames: (0..<48).map { "bone\($0)" }),
        CatTierFixture.skin(jointNames: (0..<47).map { "joint\($0)" }),
        CatTierFixture.skin(skeleton: nil),
        CatTierFixture.skin(format: "meowverse.cat-skin/9"),
        CatTierFixture.skin(joint: 48),
        CatTierFixture.gaits(),
        Data("{}".utf8),
    ])
    func refused(data: Data) throws {
        let rig = try rig()
        #expect(throws: CatPackError.self) { try CatSkin.decode(data, name: "low-skin.json", for: rig) }
    }
}

@Suite("Cat pack tiers: choosing")
struct CatPackVariantTests {
    @Test("a pack without tiers uses its own files on every 画质 tier",
          arguments: CatMeshTier.allCases)
    func oldPackEveryTier(wanted: CatMeshTier) throws {
        let dir = TestSupport.tempDir()
        try CatTierFixture.writeFolder(CatPackFixture.files(), prefix: "test-cat-", in: dir)
        let pack = try CatPack.builtIn(id: "test-cat", resourceDirectory: dir)
        let somewhere = CatTierLocation(directory: dir.appending(path: "downloaded"))
        let variant = pack.variant(for: wanted, downloaded: [.low: somewhere, .high: somewhere])
        #expect(variant.tier == .medium)
        #expect(variant.location == nil)
        #expect(variant.skinFile == nil)
        for pose in CatPackPose.allCases {
            #expect(variant.url(for: variant.poseFile(pose)) == pack.url(for: pack.manifest.file(for: pose)))
        }
        #expect(variant.material("coat") == pack.manifest.materials["coat"])
        #expect(variant.url(for: "coat.png") == pack.url(for: "coat.png"))
        #expect(pack.bestVariant(downloaded: [.low: somewhere]).tier == .medium)
        #expect(pack.downloadRequests.isEmpty)
    }

    @Test("the bundled Bella resolves to her own files on every tier")
    func bundledBella() throws {
        let art = CatTierFixture.bundledArt
        guard FileManager.default.fileExists(atPath: art.appending(path: "bella-cat.json").path) else { return }
        let pack = try CatPack.builtIn(id: "bella", resourceDirectory: art)
        guard pack.manifest.tiers == nil else { return }
        for wanted in CatMeshTier.allCases {
            let variant = pack.variant(for: wanted, downloaded: [:])
            #expect(variant.tier == .medium)
            #expect(variant.url(for: variant.poseFile(.sit)).lastPathComponent == "bella-sit.mesh.json")
            #expect(variant.key == pack.cacheKey + "#medium")
        }
    }

    @Test("a built-in pack uses 低 only once it is downloaded")
    func builtInLow() throws {
        let dir = TestSupport.tempDir()
        let pack = try CatTierFixture.builtIn(in: dir)
        #expect(pack.variant(for: .low, downloaded: [:]).tier == .medium)

        let folder = CatTierLocation(directory: dir.appending(path: "cats/test-cat/low"))
        let low = pack.variant(for: .low, downloaded: [.low: folder])
        #expect(low.tier == .low)
        #expect(low.key == pack.cacheKey + "#low")
        #expect(low.skinFile == "low-skin.json")
        #expect(low.url(for: "low-skin.json") == folder.directory.appending(path: "low-skin.json"))
        #expect(low.url(for: low.poseFile(.loaf)) == folder.directory.appending(path: "low-loaf.mesh.json"))
        // Shared files stay where they are: the clips (ground-gaits) come from the bundle.
        #expect(low.url(for: "ground-gaits.json") == pack.url(for: "ground-gaits.json"))
        #expect(low.material("coat")?.baseColor == "low-coat.png")

        // Unusable (it failed to load) falls back to 中 until asked again.
        #expect(pack.variant(for: .low, downloaded: [.low: folder], unusable: [.low]).tier == .medium)
        // 中 and 高 (not in this pack) are 中.
        #expect(pack.variant(for: .medium, downloaded: [.low: folder]).tier == .medium)
        #expect(pack.variant(for: .high, downloaded: [.low: folder]).tier == .medium)
        #expect(pack.downloadRequests.map(\.tier) == [.low])
    }

    @Test("an imported pack carries its tiers in its own folder; nothing is downloaded")
    func importedLow() throws {
        let dir = TestSupport.tempDir()
        let url = try CatPackFixture.write(CatPackFixture.archive(CatTierFixture.files()), in: dir)
        let store = CatPackStore(root: dir.appending(path: "CatPacks"), reservedIDs: ["bella"])
        try store.commit(try store.stage(archiveAt: url))
        let pack = CatPack(installed: try #require(store.installed().first))
        #expect(pack.downloadRequests.isEmpty)
        let low = pack.variant(for: .low, downloaded: [:])
        #expect(low.tier == .low)
        #expect(FileManager.default.fileExists(atPath: low.url(for: "low-skin.json").path))
        #expect(FileManager.default.fileExists(atPath: low.url(for: low.poseFile(.sit)).path))
        #expect(pack.variant(for: .low, downloaded: [:], unusable: [.low]).tier == .medium)
    }

    @Test("查看 3D 模型 and the postcard use the best tier there is: never 低")
    func best() throws {
        let dir = TestSupport.tempDir()
        let high: [String: Any] = ["poses": ["sit": "high-sit.mesh.json"], "materials": ["coat": ["baseColor": "high-coat.png"]]]
        let pack = try CatTierFixture.builtIn(CatTierFixture.manifest(extraTiers: ["high": high]), in: dir)
        let low = CatTierLocation(directory: dir.appending(path: "low"))
        let top = CatTierLocation(directory: dir.appending(path: "high"))
        #expect(pack.bestVariant(downloaded: [.low: low]).tier == .medium)
        #expect(pack.bestVariant(downloaded: [.low: low, .high: top]).tier == .high)
        #expect(pack.bestVariant(downloaded: [.high: top], unusable: [.high]).tier == .medium)
        #expect(pack.downloadRequests.map(\.tier) == [.low, .high])
        let request = try #require(pack.downloadRequests.first)
        #expect(request.assetPackID == "cat-test-cat-low")
        #expect(request.folder == "cats/test-cat/low")
        #expect(Set(request.files) == Set(pack.manifest.files(of: .low)))
    }
}

@Suite("Cat pack tiers: import")
struct CatPackTierImportTests {
    private func stage(_ files: [String: Data], limits: CatPackLimits = .standard) throws -> (CatPackStore, StagedCatPack) {
        let dir = TestSupport.tempDir()
        let url = try CatPackFixture.write(CatPackFixture.archive(files), in: dir)
        let store = CatPackStore(root: dir.appending(path: "CatPacks"), reservedIDs: ["bella"], limits: limits)
        return (store, try store.stage(archiveAt: url))
    }

    @Test("a pack with a 低 tier installs the tier's files with the rest")
    func installsTierFiles() throws {
        let (store, staged) = try stage(CatTierFixture.files())
        try store.commit(staged)
        let folder = store.directory(for: "test-cat")
        for name in CatTierFixture.files().keys {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: name).path), "\(name)")
        }
    }

    @Test("a pack missing or with a broken tier file is refused whole")
    func brokenTier() throws {
        var files = CatTierFixture.files()
        files["low-sit.mesh.json"] = nil
        #expect(throws: CatPackError.missingFile("low-sit.mesh.json")) { try stage(files) }

        files = CatTierFixture.files()
        files["low-sleep.mesh.json"] = CatPackFixture.poseMesh(indices: [0, 1, 7])
        #expect(throws: CatPackError.badMesh("low-sleep.mesh.json")) { try stage(files) }

        files = CatTierFixture.files()
        files["low-skin.json"] = CatTierFixture.skin(jointNames: (0..<48).map { "bone\($0)" })
        #expect(throws: CatPackError.badMesh("low-skin.json")) { try stage(files) }

        files = CatTierFixture.files()
        files["low-coat.png"] = Data("nope".utf8)
        #expect(throws: CatPackError.badTexture("low-coat.png")) { try stage(files) }
    }

    @Test("the texture budget is per tier: the room never wears 中 and 低 at once")
    func budgetPerTier() throws {
        var limits = CatPackLimits.standard
        // 中 wears the 8 × 8 coat (64), 低 the 4 × 4 one (16): each fits 64, together they do not.
        limits.maxTotalTexturePixels = 64
        _ = try stage(CatTierFixture.files(), limits: limits)

        // A 低 coat larger than the budget is refused even though 中 fits.
        var files = CatTierFixture.files()
        files["low-coat.png"] = TestSupport.imageData(width: 16, height: 16, type: .png)
        #expect(throws: CatPackError.renderBudgetExceeded) { try stage(files, limits: limits) }
    }

    @Test("a pack without tiers imports exactly as before")
    func oldPackImports() throws {
        let (store, staged) = try stage(CatPackFixture.files())
        try store.commit(staged)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.directory(for: "test-cat").path)
        #expect(Set(names) == Set(CatPackFixture.files().keys))
    }
}

/// A tier with its own meshes has its own UVs (2026-11-20): 中's textures laid on them come out
/// scrambled, so such a tier must bring a texture for every role, and a sleeping one wherever 中
/// has one. A tier that borrows one is unusable (the room shows 中); an import is refused.
@Suite("Cat pack tiers: own textures")
struct CatPackTierTextureTests {
    private static var sleepingMid: [String: Any] { ["coat": ["baseColor": "coat.png", "sleepBaseColor": "sleep-coat.png", "roughness": 0.7]] }

    private func manifest(low: [String: Any], materials: [String: Any]? = nil) throws -> CatPackManifest {
        var json = CatTierFixture.manifest(low: low)
        if let materials { json["materials"] = materials }
        return try CatPackManifest.decode(CatPackFixture.json(json))
    }

    @Test("a tier with its own meshes and its own texture for every role borrows nothing")
    func complete() throws {
        #expect(try manifest(low: CatTierFixture.fullLow).textureGap(of: .low) == nil)
        var low = CatTierFixture.fullLow
        low["materials"] = ["coat": ["baseColor": "low-coat.png", "sleepBaseColor": "low-sleep-coat.png"]]
        #expect(try manifest(low: low, materials: Self.sleepingMid).textureGap(of: .low) == nil)
        // 中 never borrows; a pack without the tier has no gap either.
        #expect(try manifest(low: CatTierFixture.fullLow).textureGap(of: .medium) == nil)
        #expect(try manifest(low: CatTierFixture.fullLow).textureGap(of: .high) == nil)
    }

    @Test("a tier that replaces any mesh but borrows 中's texture has a gap", arguments: [
        // The skin alone, one pose alone: 中's coat would be laid on the tier's UVs.
        #"{"skin": "low-skin.json"}"#,
        #"{"poses": {"sleep": "low-sleep.mesh.json"}}"#,
        // A material that only changes roughness keeps 中's texture.
        #"{"skin": "low-skin.json", "materials": {"coat": {"roughness": 0.5}}}"#,
    ])
    func borrowsAwakeTexture(entry: String) throws {
        let low = try #require(try JSONSerialization.jsonObject(with: Data(entry.utf8)) as? [String: Any])
        #expect(try manifest(low: low).textureGap(of: .low) == "coat")
    }

    @Test("when 中 has a sleeping coat, a tier with its own meshes needs its own sleeping coat")
    func borrowsSleepingTexture() throws {
        #expect(try manifest(low: CatTierFixture.fullLow, materials: Self.sleepingMid).textureGap(of: .low) == "coat")
    }

    @Test("every role counts, not only the coat")
    func everyRole() throws {
        let mid: [String: Any] = ["coat": ["baseColor": "coat.png", "roughness": 0.7], "eye": ["baseColor": "eye.png", "roughness": 0.2]]
        #expect(try manifest(low: CatTierFixture.fullLow, materials: mid).textureGap(of: .low) == "eye")
    }

    @Test("a tier that replaces only textures keeps 中's meshes and UVs, so it may borrow the rest")
    func texturesOnly() throws {
        let low: [String: Any] = ["materials": ["coat": ["baseColor": "low-coat.png"]]]
        #expect(try manifest(low: low, materials: Self.sleepingMid).textureGap(of: .low) == nil)
    }

    @Test("a built-in tier with a gap is never worn: the room and the postcard show 中")
    func builtInGapIsMedium() throws {
        let dir = TestSupport.tempDir()
        let low: [String: Any] = ["skin": "low-skin.json", "poses": ["sit": "low-sit.mesh.json"]]
        let high: [String: Any] = ["poses": ["sit": "high-sit.mesh.json"]]
        let pack = try CatTierFixture.builtIn(CatTierFixture.manifest(low: low, extraTiers: ["high": high]), in: dir)
        let somewhere = CatTierLocation(directory: dir.appending(path: "downloaded"))
        #expect(pack.variant(for: .low, downloaded: [.low: somewhere]).tier == .medium)
        #expect(pack.variant(for: .high, downloaded: [.high: somewhere]).tier == .medium)
        #expect(pack.bestVariant(downloaded: [.low: somewhere, .high: somewhere]).tier == .medium)
    }

    @Test("an imported pack whose tier borrows a texture is refused whole")
    func importRefused() throws {
        let dir = TestSupport.tempDir()
        let store = CatPackStore(root: dir.appending(path: "CatPacks"), reservedIDs: ["bella"])

        var json = CatTierFixture.manifest(low: ["skin": "low-skin.json"])
        var files = CatTierFixture.files(manifest: json)
        files["low-coat.png"] = nil
        let borrowed = try CatPackFixture.write(CatPackFixture.archive(files), in: dir, name: "borrowed.meowcat")
        #expect(throws: CatPackError.badManifest) { try store.stage(archiveAt: borrowed) }

        json = CatTierFixture.manifest()
        json["materials"] = Self.sleepingMid
        files = CatTierFixture.files(manifest: json)
        files["sleep-coat.png"] = TestSupport.imageData(width: 4, height: 4, type: .png)
        let sleeping = try CatPackFixture.write(CatPackFixture.archive(files), in: dir, name: "sleeping.meowcat")
        #expect(throws: CatPackError.badManifest) { try store.stage(archiveAt: sleeping) }
        #expect(try store.installed().isEmpty)
    }

    @Test("every built-in cat's 低 brings its own textures and is downloadable")
    func bundledCats() throws {
        let art = CatTierFixture.bundledArt
        let ids = try FileManager.default.contentsOfDirectory(atPath: art.path)
            .filter { $0.hasSuffix("-cat.json") }.map { String($0.dropLast("-cat.json".count)) }.sorted()
        guard !ids.isEmpty else { return }
        for id in ids {
            let pack = try CatPack.builtIn(id: id, resourceDirectory: art)
            guard pack.manifest.tier(.low) != nil else { continue }
            #expect(pack.manifest.textureGap(of: .low) == nil, "\(id)")
            #expect(pack.downloadRequests.map(\.assetPackID) == ["cat-\(id)-low"], "\(id)")
            // The tier's files are downloaded, not in the bundle.
            for file in pack.manifest.files(of: .low) {
                #expect(!FileManager.default.fileExists(atPath: pack.url(for: file).path), "\(id): \(file)")
            }
        }
    }
}

// MARK: - Downloads

/// A transport whose downloads the test finishes by hand.
actor FakeTierTransport: CatTierTransport {
    private var installedFolders: [String: URL] = [:]
    private var waiting: [String: [CheckedContinuation<URL, any Error>]] = [:]
    private(set) var downloads: [String] = []
    private var progressSinks: [String: @Sendable (Double) -> Void] = [:]

    func preinstall(_ id: String, at url: URL) { installedFolders[id] = url }

    nonisolated func installed(_ request: CatTierRequest) async -> URL? { await installedFolder(request.assetPackID) }
    private func installedFolder(_ id: String) -> URL? { installedFolders[id] }

    nonisolated func download(_ request: CatTierRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Task { await self.park(request.assetPackID, continuation, progress) }
        }
    }

    private func park(_ id: String, _ continuation: CheckedContinuation<URL, any Error>, _ progress: @escaping @Sendable (Double) -> Void) {
        downloads.append(id)
        waiting[id, default: []].append(continuation)
        progressSinks[id] = progress
    }

    func parked(_ id: String) -> Int { waiting[id]?.count ?? 0 }

    func report(_ id: String, _ fraction: Double) { progressSinks[id]?(fraction) }

    func finish(_ id: String, with result: Result<URL, any Error>) {
        guard var queue = waiting[id], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        waiting[id] = queue
        next.resume(with: result)
    }
}

struct FakeTransportFailure: Error {}

/// A broken store can leave `settle` waiting on a fake download nobody finishes: the time limit
/// turns that into a failure instead of a run that never ends.
@MainActor
@Suite("Cat pack tiers: downloads", .timeLimit(.minutes(1)))
struct CatTierDownloadTests {
    private func request(files: [String] = ["low-skin.json"]) -> CatTierRequest {
        CatTierRequest(packID: "bella", tier: .low, files: files)
    }

    private func folder(with files: [String] = ["low-skin.json"]) throws -> URL {
        let dir = TestSupport.tempDir().appending(path: "cats/bella/low")
        try CatTierFixture.writeFolder(Dictionary(uniqueKeysWithValues: files.map { ($0, Data("{}".utf8)) }), in: dir)
        return dir
    }

    /// Lets the transport's parking task and the store's task run.
    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<2_000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("timed out")
    }

    @Test("nothing is downloaded until asked; then 未下载 → 下载中 → 已就绪")
    func happyPath() async throws {
        let transport = FakeTierTransport()
        let downloads = CatTierDownloads(transport: transport)
        let request = request()
        #expect(downloads.state(of: request) == .notDownloaded)
        #expect(downloads.downloaded(packID: "bella").isEmpty)

        downloads.ensure(request)
        #expect(downloads.state(of: request) == .downloading(nil))
        await waitUntil { await transport.parked(request.assetPackID) == 1 }
        await transport.report(request.assetPackID, 0.4)
        await waitUntil { downloads.state(of: request) == .downloading(0.4) }

        let url = try folder()
        await transport.finish(request.assetPackID, with: .success(url))
        await downloads.settle(request)
        #expect(downloads.state(of: request) == .ready(CatTierLocation(directory: url)))
        #expect(downloads.downloaded(packID: "bella") == [.low: CatTierLocation(directory: url)])
        #expect(await transport.downloads == ["cat-bella-low"])
    }

    @Test("an asset pack already on the device is ready without a download")
    func alreadyInstalled() async throws {
        let transport = FakeTierTransport()
        let url = try folder()
        await transport.preinstall("cat-bella-low", at: url)
        let downloads = CatTierDownloads(transport: transport)
        downloads.ensure(request())
        await downloads.settle(request())
        #expect(downloads.state(of: request()) == .ready(CatTierLocation(directory: url)))
        #expect(await transport.downloads.isEmpty)
    }

    @Test("asking again while it downloads or once it is ready starts nothing new")
    func idempotent() async throws {
        let transport = FakeTierTransport()
        let downloads = CatTierDownloads(transport: transport)
        let request = request()
        downloads.ensure(request)
        downloads.ensure(request)
        downloads.retry(request)
        await waitUntil { await transport.parked(request.assetPackID) == 1 }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await transport.parked(request.assetPackID) == 1)
        await transport.finish(request.assetPackID, with: .success(try folder()))
        await downloads.settle(request)
        downloads.ensure(request)
        downloads.retry(request)
        await downloads.settle(request)
        #expect(await transport.downloads.count == 1)
    }

    @Test("a failed download stays failed until it is retried; ensure does not retry")
    func failure() async throws {
        let transport = FakeTierTransport()
        let downloads = CatTierDownloads(transport: transport)
        let request = request()
        downloads.ensure(request)
        await waitUntil { await transport.parked(request.assetPackID) == 1 }
        await transport.finish(request.assetPackID, with: .failure(FakeTransportFailure()))
        await downloads.settle(request)
        guard case .failed(.transport) = downloads.state(of: request) else {
            Issue.record("expected a transport failure, got \(downloads.state(of: request))")
            return
        }
        #expect(downloads.downloaded(packID: "bella").isEmpty)
        downloads.ensure(request)
        await downloads.settle(request)
        #expect(await transport.downloads.count == 1)

        downloads.retry(request)
        #expect(downloads.state(of: request) == .downloading(nil))
        await waitUntil { await transport.parked(request.assetPackID) == 1 }
        await transport.finish(request.assetPackID, with: .success(try folder()))
        await downloads.settle(request)
        #expect(downloads.downloaded(packID: "bella")[.low] != nil)
    }

    @Test("a folder missing one of the tier's files is a failure, not 已就绪")
    func incomplete() async throws {
        let transport = FakeTierTransport()
        let downloads = CatTierDownloads(transport: transport)
        let request = request(files: ["low-skin.json", "low-sit.mesh.json"])
        downloads.ensure(request)
        await waitUntil { await transport.parked(request.assetPackID) == 1 }
        await transport.finish(request.assetPackID, with: .success(try folder(with: ["low-skin.json"])))
        await downloads.settle(request)
        #expect(downloads.state(of: request) == .failed(.incomplete("low-sit.mesh.json")))
        #expect(downloads.downloaded(packID: "bella").isEmpty)
    }

    @Test("a download that finishes after it was cancelled does not come back as 已就绪")
    func lateResult() async throws {
        let transport = FakeTierTransport()
        let downloads = CatTierDownloads(transport: transport)
        let request = request()
        downloads.ensure(request)
        await waitUntil { await transport.parked(request.assetPackID) == 1 }
        downloads.cancel(request)
        #expect(downloads.state(of: request) == .notDownloaded)
        await transport.finish(request.assetPackID, with: .success(try folder()))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(downloads.state(of: request) == .notDownloaded)
        #expect(downloads.downloaded(packID: "bella").isEmpty)
    }

    @Test("an old download finishing late does not overwrite a newer one's result")
    func olderRunLosesToNewer() async throws {
        let transport = FakeTierTransport()
        let downloads = CatTierDownloads(transport: transport)
        let request = request()
        downloads.ensure(request)
        await waitUntil { await transport.parked(request.assetPackID) == 1 }
        downloads.cancel(request)
        downloads.ensure(request)
        await waitUntil { await transport.parked(request.assetPackID) == 2 }
        // The first (cancelled) run fails late; the second is still downloading.
        await transport.finish(request.assetPackID, with: .failure(FakeTransportFailure()))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(downloads.state(of: request) == .downloading(nil))
        let url = try folder()
        await transport.finish(request.assetPackID, with: .success(url))
        await downloads.settle(request)
        #expect(downloads.state(of: request) == .ready(CatTierLocation(directory: url)))
    }

    @Test("a tier that fails to load is marked unusable and the room falls back to 中")
    func unusable() async throws {
        let transport = FakeTierTransport()
        let url = try folder()
        await transport.preinstall("cat-bella-low", at: url)
        let downloads = CatTierDownloads(transport: transport)
        let request = request()
        downloads.ensure(request)
        await downloads.settle(request)
        downloads.markUnusable(packID: "bella", tier: .low)
        #expect(downloads.state(of: request) == .failed(.unusable))
        #expect(downloads.unusable(packID: "bella") == [.low])
        #expect(downloads.downloaded(packID: "bella").isEmpty)
        // Not retried by itself.
        downloads.ensure(request)
        #expect(downloads.state(of: request) == .failed(.unusable))
    }

    @Test("an imported pack's tier can be marked unusable too, so it falls back to 中")
    func unusableImported() throws {
        let downloads = CatTierDownloads(transport: FakeTierTransport())
        downloads.markUnusable(packID: "test-cat", tier: .low)
        #expect(downloads.unusable(packID: "test-cat") == [.low])
        #expect(downloads.unusable(packID: "bella").isEmpty)
    }

    @Test("a transport that is not set up fails at once, without blocking")
    func unavailable() async throws {
        let downloads = CatTierDownloads(transport: UnavailableCatTierTransport())
        let request = request()
        downloads.ensure(request)
        await downloads.settle(request)
        #expect(downloads.state(of: request) == .failed(.unavailable))
    }
}
