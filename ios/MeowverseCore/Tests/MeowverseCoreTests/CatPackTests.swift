import Foundation
import Testing
@testable import MeowverseCore

/// Synthetic cat packs: a one-triangle pose mesh, a 34-joint rig with the four gaits, and a PNG coat.
enum CatPackFixture {
    static func manifest(id: String = "test-cat", name: String = "Test Cat", inspect: String? = nil,
                         extra: [String: Any] = [:]) -> [String: Any] {
        var json: [String: Any] = [
            "format": "meowverse.cat-pack",
            "version": 1,
            "id": id,
            "name": name,
            "poses": ["sit": "sit.mesh.json", "loaf": "loaf.mesh.json", "sleep": "sleep.mesh.json"],
            "groundGaits": "ground-gaits.json",
            "materials": ["coat": ["baseColor": "coat.png", "roughness": 0.67]],
            "license": "CC0-1.0",
        ]
        if let inspect { json["inspect"] = inspect }
        for (key, value) in extra { json[key] = value }
        return json
    }

    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// One coat-only part, like the upcoming single-part Bella.
    static func poseMesh(indices: [Int] = [0, 1, 2], targets: [String: Any]? = nil) -> Data {
        var part: [String: Any] = [
            "name": "body", "material": "coat",
            "positions": [0, 0, 0, 1, 0, 0, 0, 1, 0],
            "normals": [0, 0, 1, 0, 0, 1, 0, 0, 1],
            "uvs": [0, 0, 1, 0, 0, 1],
            "indices": indices,
        ]
        if let targets { part["targets"] = targets }
        return json(["parts": [part]])
    }

    static func gaits(jointCount: Int = 34, clips: [String] = CatGaitRig.requiredClips, skeleton: String? = nil) -> Data {
        let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let joints: [[String: Any]] = (0..<jointCount).map { index in
            var joint: [String: Any] = ["name": "joint\(index)", "inverseBind": identity,
                                        "translation": [0, 0.1, 0], "rotation": [0, 0, 0, 1]]
            if index > 0 { joint["parent"] = index - 1 }
            return joint
        }
        let part: [String: Any] = [
            "material": "coat",
            "positions": [0, 0, 0, 1, 0, 0, 0, 1, 0],
            "normals": [0, 0, 1, 0, 0, 1, 0, 0, 1],
            "uvs": [0, 0, 1, 0, 0, 1],
            "indices": [0, 1, 2],
            "jointIndices": Array(repeating: 0, count: 12),
            "weights": [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0],
        ]
        var clipJSON: [String: Any] = [:]
        for clip in clips {
            var entry: [String: Any] = ["duration": 1.0,
                                        "tracks": [["joint": 1, "path": "rotation", "values": [0, 0, 0, 1, 0, 0, 0, 1]]]]
            if CatGaitRig.requiredClips.contains(clip) { entry["stride"] = 0.8 } else { entry["still"] = 0.5 }
            clipJSON[clip] = entry
        }
        var rig: [String: Any] = ["scale": 0.675, "joints": joints, "parts": [part], "clips": clipJSON]
        if let skeleton { rig["skeleton"] = skeleton }
        return json(rig)
    }

    static func png() -> Data { TestSupport.imageData(width: 8, height: 8, type: .png) }

    /// A stand-in USDZ: the importer only checks that it is a ZIP container.
    static func usdz() -> Data {
        RawZip.build([RawZipEntry(name: "model.usdc", payload: Data("PXR-USDC".utf8))])
    }

    static func files(manifest: [String: Any] = manifest()) -> [String: Data] {
        var files: [String: Data] = [
            "cat.json": json(manifest),
            "sit.mesh.json": poseMesh(),
            "loaf.mesh.json": poseMesh(),
            "sleep.mesh.json": poseMesh(),
            "ground-gaits.json": gaits(),
            "coat.png": png(),
        ]
        if manifest["inspect"] != nil { files["inspect.usdz"] = usdz() }
        return files
    }

    static func archive(_ files: [String: Data]) -> Data {
        RawZip.build(files.sorted { $0.key < $1.key }.map { RawZipEntry(name: $0.key, payload: $0.value) })
    }

    static func write(_ data: Data, in dir: URL, name: String = "pack.meowcat") throws -> URL {
        let url = dir.appending(path: name)
        try data.write(to: url)
        return url
    }
}

@Suite("Cat pack manifest")
struct CatPackManifestTests {
    @Test("the documented manifest decodes, materials resolve sleep fallbacks")
    func decodesExample() throws {
        var json = CatPackFixture.manifest(id: "bella", name: "Bella", inspect: "inspect.usdz")
        json["materials"] = [
            "coat": ["baseColor": "coat.webp", "roughness": 0.67],
            "eye": ["baseColor": "eye.png", "roughness": 0.21, "sleepBaseColor": "closed-eyes.webp", "sleepRoughness": 0.9],
        ]
        json["preview"] = "preview.png"
        let manifest = try CatPackManifest.decode(CatPackFixture.json(json))
        #expect(manifest.id == "bella")
        #expect(manifest.file(for: .sleep) == "sleep.mesh.json")
        let coat = try #require(manifest.materials["coat"])
        #expect(coat.baseColor(sleeping: true) == "coat.webp")
        #expect(coat.roughness(sleeping: true) == 0.67)
        let eye = try #require(manifest.materials["eye"])
        #expect(eye.baseColor(sleeping: true) == "closed-eyes.webp")
        #expect(eye.roughness(sleeping: true) == 0.9)
        #expect(eye.baseColor(sleeping: false) == "eye.png")
        #expect(Set(manifest.requiredFiles) == ["sit.mesh.json", "loaf.mesh.json", "sleep.mesh.json", "ground-gaits.json",
                                               "coat.webp", "eye.png", "closed-eyes.webp"])
        #expect(Set(manifest.optionalFiles) == ["inspect.usdz", "preview.png"])
    }

    @Test("ids: lowercase letters, digits and hyphens, 1-40 long", arguments: [
        ("bella", true), ("cat-2", true), ("a", true), (String(repeating: "a", count: 40), true),
        ("", false), (String(repeating: "a", count: 41), false), ("Bella", false), ("cat_2", false),
        ("../bella", false), ("bel/la", false), ("bel la", false), ("猫", false), (".hidden", false),
    ])
    func idCharset(id: String, valid: Bool) {
        #expect(CatPackManifest.isValidID(id) == valid)
    }

    @Test("file names must be plain names without folders", arguments: [
        ("coat.webp", true), ("sit.mesh.json", true), ("closed-eyes_2.png", true),
        ("../coat.webp", false), ("textures/coat.webp", false), ("/coat.webp", false), (".coat", false),
        ("", false), ("..", false), ("coat\\x.png", false),
    ])
    func fileNames(name: String, valid: Bool) {
        #expect(CatPackManifest.isPlainFileName(name) == valid)
    }

    @Test("bad manifests are refused with a specific reason")
    func refusals() {
        func reason(_ edit: (inout [String: Any]) -> Void) -> CatPackError? {
            var json = CatPackFixture.manifest()
            edit(&json)
            do { _ = try CatPackManifest.decode(CatPackFixture.json(json)); return nil } catch { return error as? CatPackError }
        }
        #expect(reason { $0["format"] = "something-else" } == .unsupportedFormat)
        #expect(reason { $0["version"] = 3 } == .newerVersion(3))
        #expect(reason { $0["version"] = 0 } == .badManifest)
        #expect(reason { $0["id"] = "Bad_ID" } == .invalidID)
        #expect(reason { $0["name"] = "   " } == .invalidName)
        #expect(reason { $0["groundGaits"] = "../gaits.json" } == .invalidFileName)
        #expect(reason { $0["poses"] = ["sit": "a/sit.mesh.json", "loaf": "l.json", "sleep": "s.json"] } == .invalidFileName)
        #expect(reason { $0["materials"] = ["coat": ["baseColor": "coat.gif", "roughness": 0.5]] } == .invalidFileName)
        #expect(reason { $0["materials"] = ["coat": ["baseColor": "coat.png", "roughness": 1.5]] } == .badManifest)
        #expect(reason { $0["materials"] = [String: Any]() } == .badManifest)
        #expect(reason { $0["inspect"] = "model.glb" } == .invalidFileName)
        #expect(reason { $0["id"] = nil } == .badManifest)
        #expect(throws: CatPackError.badManifest) { try CatPackManifest.decode(Data("not json".utf8)) }
        #expect(reason { _ in } == nil)
    }
}

@Suite("Cat pack meshes and gaits")
struct CatPackGeometryTests {
    @Test("a single coat-only part is a valid pose mesh")
    func singlePart() throws {
        let mesh = try CatPoseMesh.decode(CatPackFixture.poseMesh())
        #expect(mesh.parts.count == 1)
        #expect(mesh.parts[0].material == "coat")
    }

    @Test("out-of-range indices and mismatched offsets are refused")
    func badMesh() {
        #expect(throws: CatPackError.self) { try CatPoseMesh.decode(CatPackFixture.poseMesh(indices: [0, 1, 7])) }
        #expect(throws: CatPackError.self) { try CatPoseMesh.decode(CatPackFixture.poseMesh(indices: [0, 1])) }
        let offsets: [String: Any] = ["leftPaw": ["indices": [9], "positions": [1, 1, 1], "normals": [0, 0, 0]]]
        #expect(throws: CatPackError.self) { try CatPoseMesh.decode(CatPackFixture.poseMesh(targets: offsets)) }
        #expect(throws: CatPackError.self) { try CatPoseMesh.decode(CatPackFixture.json(["parts": [Any]()])) }
    }

    @Test("the rig needs exactly 34 joints and all four gaits")
    func rig() throws {
        let rig = try CatGaitRig.decode(CatPackFixture.gaits())
        #expect(rig.joints.count == 34)
        #expect(throws: CatPackError.jointCount(33)) { try CatGaitRig.decode(CatPackFixture.gaits(jointCount: 33)) }
        #expect(throws: CatPackError.badGaits) {
            try CatGaitRig.decode(CatPackFixture.gaits(clips: ["ground_walk", "ground_run", "ground_jump"]))
        }
    }

    @Test("a cat-rig v2 file carries the resting actions on its own skeleton")
    func rigV2() throws {
        let clips = CatGaitRig.requiredClips + CatGaitRig.actionClips
        let rig = try CatGaitRig.decode(CatPackFixture.gaits(jointCount: 44, clips: clips, skeleton: CatGaitRig.v2Skeleton))
        #expect(rig.playsActions)
        #expect(rig.clips["sit"]?.stride == 0)
        #expect(rig.clips["sit"]?.still == 0.5)
        #expect(rig.clips["sit"]?.loop == true)
        let legacy = try CatGaitRig.decode(CatPackFixture.gaits())
        #expect(!legacy.playsActions)
        #expect(throws: CatPackError.badGaits) {
            try CatGaitRig.decode(CatPackFixture.gaits(jointCount: 44, clips: CatGaitRig.requiredClips, skeleton: CatGaitRig.v2Skeleton))
        }
        #expect(throws: CatPackError.badGaits) {
            try CatGaitRig.decode(CatPackFixture.gaits(jointCount: 44, clips: clips, skeleton: "someone-else/1"))
        }
        #expect(throws: CatPackError.jointCount(8)) {
            try CatGaitRig.decode(CatPackFixture.gaits(jointCount: 8, clips: clips, skeleton: CatGaitRig.v2Skeleton))
        }
    }

    @Test("unsafe action durations and gait strides are rejected before installation",
          arguments: [-1.0, 0, 2.3e-308, Double.greatestFiniteMagnitude])
    func extremeTimings(value: Double) throws {
        let data = CatPackFixture.gaits(clips: CatGaitRig.requiredClips + CatGaitRig.actionClips,
                                       skeleton: CatGaitRig.v2Skeleton)
        var rig = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let clips = try #require(rig["clips"] as? [String: [String: Any]])
        for (name, field) in [("sit", "duration"), ("ground_walk", "stride")] {
            var changed = clips
            changed[name]?[field] = value
            rig["clips"] = changed
            #expect(throws: CatPackError.badGaits) { try CatGaitRig.decode(CatPackFixture.json(rig)) }
        }
    }

    @Test("the vertex and index budgets are cumulative across parts")
    func meshBudget() {
        #expect(CatPackValidator.fitsMeshBudget(vertices: [32_768, 32_768], indices: [196_608, 196_608]))
        #expect(!CatPackValidator.fitsMeshBudget(vertices: [32_768, 32_769], indices: [3, 3]))
        #expect(!CatPackValidator.fitsMeshBudget(vertices: [3, 3], indices: [196_608, 196_611]))
    }

    @Test("clamped and looping playback always supply a finite phase")
    func safePlayback() {
        #expect(CatGaitRig.Clip.phase(4.2, period: 2.3e-308, looping: true).isFinite)
        #expect(CatGaitRig.Clip.phase(.infinity, period: 1, looping: true) == 0)
        #expect(CatGaitRig.Clip.phase(.nan, period: 1, looping: false) == 0)
        #expect(CatGaitRig.Clip.phase(4.25, period: 1, looping: true) == 0.25)
        #expect(CatGaitRig.Clip.phase(4.25, period: 1, looping: false) == 1)
    }

    @Test("the bundled Bella pack follows the contract")
    func bundledBella() throws {
        let art = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Meowverse/Resources/Art")
        let manifestURL = art.appending(path: "bella-cat.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
        let pack = try CatPack.builtIn(id: "bella", resourceDirectory: art)
        // A built-in pack's 低/高 files are downloaded, not bundled (docs/CAT_PACK.md, "按需下载").
        try CatPackValidator.validate(manifest: pack.manifest, tiers: []) { name in
            FileManager.default.fileExists(atPath: pack.url(for: name).path) ? try pack.data(name) : nil
        }
        #expect(pack.origin == .builtIn)
        #expect(pack.url(for: "coat.webp").lastPathComponent == "bella-coat.webp")
    }
}

@Suite("Cat pack import")
struct CatPackImportTests {
    private func store(_ root: URL, limits: CatPackLimits = .standard) -> CatPackStore {
        CatPackStore(root: root.appending(path: "CatPacks"), reservedIDs: ["bella"], limits: limits)
    }

    private func stageError(_ files: [String: Data], limits: CatPackLimits = .standard) throws -> CatPackError? {
        let dir = TestSupport.tempDir()
        let url = try CatPackFixture.write(CatPackFixture.archive(files), in: dir)
        let packs = store(dir, limits: limits)
        do {
            _ = try packs.stage(archiveAt: url)
            return nil
        } catch {
            // A refused pack leaves nothing behind.
            #expect(packs.installed().isEmpty)
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: packs.root.path)) ?? []
            #expect(leftovers.isEmpty)
            return error as? CatPackError
        }
    }

    @Test("a valid pack stages, commits, lists and resolves its files")
    func roundTrip() throws {
        let dir = TestSupport.tempDir()
        let files = CatPackFixture.files(manifest: CatPackFixture.manifest(inspect: "inspect.usdz"))
        let url = try CatPackFixture.write(CatPackFixture.archive(files), in: dir)
        let packs = store(dir)
        let staged = try packs.stage(archiveAt: url)
        #expect(staged.manifest.id == "test-cat")
        #expect(!staged.replacesExisting)
        #expect(packs.installed().isEmpty, "nothing is visible before commit")
        try packs.commit(staged)
        let installed = packs.installed()
        #expect(installed.map(\.manifest.id) == ["test-cat"])
        let pack = CatPack(installed: try #require(installed.first))
        #expect(pack.origin == .imported)
        #expect(try pack.data("coat.png") == files["coat.png"])
        #expect(pack.inspectURL?.lastPathComponent == "inspect.usdz")
        #expect(FileManager.default.fileExists(atPath: pack.url(for: "cat.json").path))
    }

    @Test("re-importing the same id is flagged and replaces the old files")
    func replace() throws {
        let dir = TestSupport.tempDir()
        let packs = store(dir)
        let first = try CatPackFixture.write(CatPackFixture.archive(CatPackFixture.files()), in: dir, name: "a.meowcat")
        try packs.commit(try packs.stage(archiveAt: first))
        let oldRevision = try #require(packs.installed().first).revision

        var files = CatPackFixture.files(manifest: CatPackFixture.manifest(name: "Renamed"))
        files["coat.png"] = TestSupport.imageData(width: 16, height: 16, seed: 3, type: .png)
        let second = try CatPackFixture.write(CatPackFixture.archive(files), in: dir, name: "b.meowcat")
        let staged = try packs.stage(archiveAt: second)
        #expect(staged.replacesExisting)
        try packs.commit(staged)
        let installed = try #require(packs.installed().first)
        #expect(packs.installed().count == 1)
        #expect(installed.manifest.name == "Renamed")
        #expect(installed.revision != oldRevision)
        #expect(try CatPack(installed: installed).data("coat.png") == files["coat.png"])
        let hidden = try FileManager.default.contentsOfDirectory(atPath: packs.root.path).filter { $0.hasPrefix(".") }
        #expect(hidden.isEmpty)
    }

    @Test("a discarded staging leaves nothing; delete removes an installed pack")
    func discardAndDelete() throws {
        let dir = TestSupport.tempDir()
        let packs = store(dir)
        let url = try CatPackFixture.write(CatPackFixture.archive(CatPackFixture.files()), in: dir)
        packs.discard(try packs.stage(archiveAt: url))
        #expect(try FileManager.default.contentsOfDirectory(atPath: packs.root.path).isEmpty)
        try packs.commit(try packs.stage(archiveAt: url))
        try packs.delete(id: "test-cat")
        #expect(packs.installed().isEmpty)
        #expect(throws: CatPackError.self) { try packs.delete(id: "../CatPacks") }
    }

    @Test("path traversal and folders inside the archive are refused")
    func traversal() throws {
        var files = CatPackFixture.files()
        files["../evil.json"] = Data("x".utf8)
        #expect(try stageError(files) == .unsafeName)

        var nested = CatPackFixture.files()
        nested["textures/coat.png"] = nested["coat.png"]
        #expect(try stageError(nested) == .nestedFolder)
    }

    @Test("oversized files and archives are refused")
    func oversize() throws {
        let small = CatPackLimits(maxFileBytes: 1_000, maxTotalBytes: 1_000_000, maxEntries: 32)
        #expect(try stageError(CatPackFixture.files(), limits: small) == .tooLarge)
        let total = CatPackLimits(maxFileBytes: 1_000_000, maxTotalBytes: 2_000, maxEntries: 32)
        #expect(try stageError(CatPackFixture.files(), limits: total) == .tooLarge)
        #expect(CatPackLimits.standard.maxFileBytes == 40 * 1_048_576)
        #expect(CatPackLimits.standard.maxTotalBytes == 120 * 1_048_576)
    }

    @Test("missing or broken pieces are refused")
    func broken() throws {
        var files = CatPackFixture.files()
        files["cat.json"] = nil
        #expect(try stageError(files) == .missingManifest)

        files = CatPackFixture.files()
        files["sleep.mesh.json"] = nil
        #expect(try stageError(files) == .missingFile("sleep.mesh.json"))

        files = CatPackFixture.files(manifest: CatPackFixture.manifest(inspect: "inspect.usdz"))
        files["inspect.usdz"] = nil
        #expect(try stageError(files) == .missingFile("inspect.usdz"))

        files = CatPackFixture.files()
        files["loaf.mesh.json"] = CatPackFixture.poseMesh(indices: [0, 1, 9])
        #expect(try stageError(files) == .badMesh("loaf.mesh.json"))

        files = CatPackFixture.files()
        files["ground-gaits.json"] = CatPackFixture.gaits(jointCount: 20)
        #expect(try stageError(files) == .jointCount(20))

        files = CatPackFixture.files()
        files["coat.png"] = Data("not an image".utf8)
        #expect(try stageError(files) == .badTexture("coat.png"))

        files = CatPackFixture.files(manifest: CatPackFixture.manifest(inspect: "inspect.usdz"))
        files["inspect.usdz"] = Data("not a usdz".utf8)
        #expect(try stageError(files) == .badInspect)

        #expect(try stageError(CatPackFixture.files(manifest: CatPackFixture.manifest(id: "bella"))) == .reservedID)
        #expect(try stageError(["cat.json": Data("{}".utf8)]) == .badManifest)
    }

    @Test("a file that is not a ZIP is refused")
    func notZip() throws {
        let dir = TestSupport.tempDir()
        let url = try CatPackFixture.write(Data("hello".utf8), in: dir)
        #expect(throws: CatPackError.notArchive) { try store(dir).stage(archiveAt: url) }
    }

    @Test("the pixel budget counts a shared awake and sleeping texture only once")
    func textureBudget() throws {
        let shared: [String: [String: Any]] = ["coat": ["baseColor": "coat.png", "sleepBaseColor": "coat.png", "roughness": 0.7]]
        var files = CatPackFixture.files(manifest: CatPackFixture.manifest(extra: ["materials": shared]))
        var limits = CatPackLimits.standard
        limits.maxTotalTexturePixels = 64  // The fixture is 8 × 8.
        #expect(try stageError(files, limits: limits) == nil)
        var distinct = shared
        distinct["coat"]?["sleepBaseColor"] = "sleep.png"
        files["cat.json"] = CatPackFixture.json(CatPackFixture.manifest(extra: ["materials": distinct]))
        files["sleep.png"] = files["coat.png"]
        #expect(try stageError(files, limits: limits) == .renderBudgetExceeded)
    }

    @Test("startup restores the parked version if the replacement did not commit", arguments: [false, true])
    func interruptedReplacement(committed: Bool) throws {
        let dir = TestSupport.tempDir()
        let packs = store(dir)
        func stage(_ name: String) throws -> StagedCatPack {
            let files = CatPackFixture.files(manifest: CatPackFixture.manifest(name: name))
            let url = try CatPackFixture.write(CatPackFixture.archive(files), in: dir)
            return try packs.stage(archiveAt: url)
        }
        try packs.commit(stage("First"))
        let next = try stage("Second")
        let live = packs.directory(for: "test-cat")
        let fm = FileManager.default
        try fm.moveItem(at: live, to: packs.root.appending(path: ".old-legacy"))
        if committed { try fm.moveItem(at: next.stagingURL, to: live) }
        packs.removeLeftovers()
        packs.removeLeftovers()
        let pack = CatPack(installed: try #require(packs.installed().first))
        #expect(pack.manifest.name == (committed ? "Second" : "First"))
        try CatPackValidator.validate(manifest: pack.manifest) { try pack.data($0) }
        #expect(try fm.contentsOfDirectory(atPath: packs.root.path) == ["test-cat"])
    }

    @Test("unlisted extra files are not installed")
    func extras() throws {
        let dir = TestSupport.tempDir()
        var files = CatPackFixture.files()
        files["notes.txt"] = Data("hi".utf8)
        let url = try CatPackFixture.write(CatPackFixture.archive(files), in: dir)
        let packs = store(dir)
        try packs.commit(try packs.stage(archiveAt: url))
        let folder = packs.root.appending(path: "test-cat")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "notes.txt").path))
    }

    @Test("leftover staging folders are cleaned and invalid folders are not listed")
    func leftovers() throws {
        let dir = TestSupport.tempDir()
        let packs = store(dir)
        let fm = FileManager.default
        try fm.createDirectory(at: packs.root.appending(path: ".staging-old"), withIntermediateDirectories: true)
        try fm.createDirectory(at: packs.root.appending(path: "Not_Valid"), withIntermediateDirectories: true)
        // A folder whose manifest names a different id is ignored.
        let other = packs.root.appending(path: "other")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try CatPackFixture.json(CatPackFixture.manifest(id: "someone-else")).write(to: other.appending(path: "cat.json"))
        packs.removeLeftovers()
        #expect(!fm.fileExists(atPath: packs.root.appending(path: ".staging-old").path))
        #expect(packs.installed().isEmpty)
    }
}
