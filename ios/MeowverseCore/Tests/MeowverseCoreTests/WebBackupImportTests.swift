import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MeowverseCore

/// A synthetic web backup (manifest version 6) laid out the way `src/storage/archive.ts`
/// `encodeArchive` writes it: `state.json`, `media/<index>/{original,thumbnail,preview}.bin`
/// per photo, `assets/<id>/model.glb`, then `manifest.json`; stored entries. All images are
/// drawn by the test; nothing comes from a real photo.
struct WebFixture {
    struct Photo {
        var id: String
        var bytes: Data
        var filename: String
        var mimeType = "image/jpeg"
        var captureDate: String?
        var captureDateSource = "unknown"
        var favorite = false
        var importedAt = "2026-11-05T12:00:00.123Z"
        var revision = 0
    }

    var version = 6
    var photos: [Photo] = []
    var observations: [[String: Any]] = []
    var gridItems: [[String: Any]] = []
    var photoDetails: [String: Any] = [:]
    var photoAnnotations: [String: Any] = [:]
    var classicFurniture: [[String: Any]] = []
    var analysisRuns: [[String: Any]] = []
    var consents: [[String: Any]] = []
    var assetFiles: [String: Data] = [:]
    var catAppearance: Any = NSNull()
    var catName = "猫猫"
    var roomTheme = "warm"
    var createdAt = "2026-11-08T08:30:00.000Z"
    /// Last-minute edits to the files of the archive (path -> bytes), after the manifest is built.
    var tamper: ((inout [String: Data]) -> Void)?
    /// Edits to the manifest object before it is encoded.
    var editManifest: ((inout [String: Any]) -> Void)?

    static let sofaId = "grid-sofa-1", chairId = "grid-chair-1", stoolId = "grid-stool-1"

    /// Four photos, three placed pieces (one overlapping another, which the iOS grid rules
    /// would refuse for a new placement), one piece of a model iOS does not have, plus data
    /// from every part of the web state that iOS cannot show.
    static func rich() -> WebFixture {
        var f = WebFixture()
        f.photos = [
            Photo(id: "photo-a", bytes: TestSupport.imageData(seed: 11, dateTimeOriginal: "2026:03:14 09:26:53"), filename: "sofa.jpg",
                  captureDate: "2026-03-14", captureDateSource: "exif", revision: 2),
            Photo(id: "photo-b", bytes: TestSupport.imageData(seed: 12, type: .png), filename: "chair.png", mimeType: "image/png",
                  captureDate: "2025-12-01", captureDateSource: "user", favorite: true, revision: 5),
            Photo(id: "photo-c", bytes: TestSupport.imageData(seed: 13), filename: "loose.jpg"),
            // The record claims an EXIF day the file does not contain.
            Photo(id: "photo-d", bytes: TestSupport.imageData(seed: 14), filename: "claimed.jpg",
                  captureDate: "2024-01-02", captureDateSource: "exif"),
        ]
        func object(_ kind: String, _ relation: String, _ confidence: String) -> [String: Any] {
            ["kind": kind, "description": "synthetic", "appearanceTags": [String](), "relationToCat": relation, "confidence": confidence]
        }
        func observation(_ id: String, photo: String, run: String, origin: String, objects: [[String: Any]]) -> [String: Any] {
            ["observationId": id, "photoId": photo, "runId": run, "origin": origin, "revision": 0, "userReviewed": false,
             "catPresence": "single", "catMatch": "likely", "catPoses": ["sitting"], "objects": objects, "uncertaintyNotes": [String]()]
        }
        f.observations = [
            observation("obs-a", photo: "photo-a", run: "run-remote", origin: "model",
                        objects: [object("rug", "near", "low"), object("sofa", "on", "high")]),
            observation("obs-b", photo: "photo-b", run: "run-fixture", origin: "curated_fixture",
                        objects: [object("chair", "near", "medium")]),
            observation("obs-c", photo: "photo-c", run: "run-remote", origin: "model", objects: [object("window", "background", "low")]),
        ]
        func source(_ photo: String, _ observation: String? = nil, _ index: Int? = nil, origin: String = "user", relation: String = "unclear") -> [String: Any] {
            ["photoId": photo, "observationId": observation ?? NSNull(), "objectIndex": index ?? NSNull(), "origin": origin, "relationToCat": relation]
        }
        func item(_ id: String, _ model: String, _ x: Int, _ z: Int, _ w: Int, _ d: Int, turn: Int = 0, finish: String = "original",
                  name: String, sources: [[String: Any]], tags: [String] = [], revision: Int = 1) -> [String: Any] {
            ["instanceId": id, "modelId": model, "x": x, "z": z, "width": w, "depth": d, "turn": turn, "finish": finish,
             "displayName": name, "sources": sources, "tags": tags, "revision": revision]
        }
        f.gridItems = [
            item(sofaId, "kenney-loungeSofa", 1, 1, 3, 2, turn: 1, finish: "sage", name: "客厅沙发",
                 sources: [source("photo-a", "obs-a", 1, origin: "model", relation: "on"), source("photo-b")], tags: ["最爱"], revision: 4),
            item(chairId, "kenney-chair", 5, 5, 2, 2, name: "书房椅子",
                 sources: [source("photo-b", "obs-b", 0, origin: "curated_fixture", relation: "near")]),
            // Overlaps the sofa: must still load.
            item(stoolId, "kenney-stoolBar", 1, 1, 1, 1, finish: "blue", name: "压在沙发上的凳子", sources: [source("photo-c")]),
            item("grid-future-1", "kenney-future-hammock", 8, 8, 1, 1, name: "未来的吊床", sources: [source("photo-d")]),
        ]
        f.photoDetails = [
            "photo-b": ["note": "她第一次坐上这把椅子", "reviewedAt": "2026-11-06T10:00:00.000Z", "excludedTemplates": [String]()],
            "photo-c": ["note": "", "reviewedAt": NSNull(), "excludedTemplates": [String]()],
        ]
        f.photoAnnotations = ["photo-a": ["categories": ["sofa"], "custom": ["阳台"]]]
        f.classicFurniture = [["furnitureId": "classic-1", "templateId": "sofa", "slotId": "back_left", "displayName": "旧沙发",
                               "evidenceIds": [String](), "addedByProposalId": "p1", "confirmedAt": "2026-11-01T00:00:00.000Z", "revision": 1]]
        f.analysisRuns = [
            ["runId": "run-remote", "mode": "remote", "createdAt": "2026-11-05T12:10:00.000Z"],
            ["runId": "run-fixture", "mode": "fixture", "createdAt": "2026-11-04T09:00:00.000Z"],
        ]
        f.consents = [["consentId": "c1"]]
        f.assetFiles = ["assets/a1/model.glb": Data("glTF-not-read-by-ios".utf8)]
        f.catAppearance = ["assetId": "cat-1", "enabled": true]
        f.catName = "团子"
        f.roomTheme = "dusk"
        return f
    }

    func stateObject() -> [String: Any] {
        [
            "schemaVersion": version, "catAppearance": catAppearance,
            "gridRoom": ["revision": 3, "items": gridItems], "photoAnnotations": photoAnnotations,
            "assetLibrary": ["objects": [Any](), "assets": assetFiles.keys.sorted().map { ["assetId": $0] }, "bindings": [Any]()],
            "revision": 42,
            "photos": photos.map { photo -> [String: Any] in
                ["photoId": photo.id, "filename": photo.filename, "sha256": PhotoIngest.sha256Hex(photo.bytes), "mimeType": photo.mimeType,
                 "byteSize": photo.bytes.count, "width": 64, "height": 32,
                 "originalBlobKey": "\(photo.id)/original", "thumbnailBlobKey": "\(photo.id)/thumbnail-v1", "previewBlobKey": "\(photo.id)/preview-v1",
                 "captureDate": photo.captureDate ?? NSNull(), "captureDateSource": photo.captureDateSource,
                 "captureDatePrecision": photo.captureDate == nil ? "unknown" : "day",
                 "importedAt": photo.importedAt, "favorite": photo.favorite, "revision": photo.revision]
            },
            "observations": observations, "evidence": [Any](), "proposals": [Any](), "furniture": classicFurniture,
            "analysisRuns": analysisRuns, "consents": consents, "photoDetails": photoDetails,
            "cat": ["catId": "cat", "displayName": catName, "appearanceReferencePhotoIds": [String]()],
            "room": ["roomId": "room", "furnitureIds": [String](), "catAnchor": "home", "catAction": "sit", "revision": 0],
            "settings": ["reducedMotion": false, "roomTheme": roomTheme],
        ]
    }

    func files() throws -> [(String, Data)] {
        let stateData = try JSONSerialization.data(withJSONObject: stateObject())
        var ordered: [(String, Data)] = [("state.json", stateData)]
        var media: [[String: Any]] = []
        let derivative = TestSupport.imageData(width: 16, height: 8, seed: 99)
        for (index, photo) in photos.enumerated() {
            for kind in ["original", "thumbnail", "preview"] {
                let bytes = kind == "original" ? photo.bytes : derivative
                let path = String(format: "media/%06d/%@.bin", index, kind)
                ordered.append((path, bytes))
                media.append(["path": path, "blobKey": "\(photo.id)/\(kind == "original" ? "original" : "\(kind)-v1")", "photoId": photo.id,
                              "kind": kind, "mimeType": kind == "original" ? photo.mimeType : "image/jpeg",
                              "byteSize": bytes.count, "sha256": PhotoIngest.sha256Hex(bytes)])
            }
        }
        var assets: [[String: Any]] = []
        for path in assetFiles.keys.sorted() {
            let bytes = assetFiles[path]!
            ordered.append((path, bytes))
            assets.append(["path": path, "blobKey": String(path.dropLast(4)), "assetId": "a1", "sha256": PhotoIngest.sha256Hex(bytes), "byteSize": bytes.count])
        }
        var manifest: [String: Any] = [
            "format": "meowverse-backup", "version": version, "assets": assets, "createdAt": createdAt,
            "state": ["path": "state.json", "byteSize": stateData.count, "sha256": PhotoIngest.sha256Hex(stateData)],
            "media": media,
        ]
        editManifest?(&manifest)
        ordered.append(("manifest.json", try JSONSerialization.data(withJSONObject: manifest)))
        if let tamper {
            var map = Dictionary(uniqueKeysWithValues: ordered)
            tamper(&map)
            ordered = ordered.compactMap { path, _ in map[path].map { (path, $0) } }
        }
        return ordered
    }

    func write(to url: URL) throws {
        let writer = try ZipWriter(url: url)
        for (path, data) in try files() { try writer.add(path: path, data: data) }
        try writer.finish()
    }
}

struct WebBackupImportTests {
    let fm = FileManager.default
    let catalog: FurnitureCatalog

    init() throws {
        catalog = try TestSupport.catalog()
    }

    private func sandbox() -> (parent: URL, root: URL) {
        let parent = TestSupport.tempDir()
        return (parent, parent.appendingPathComponent("Library", isDirectory: true))
    }

    private func siblings(_ parent: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).filter { $0.hasPrefix("Library.") }.sorted()
    }

    @Test func richBackupCarriesOverPhotosFurnitureSourcesAndUserEdits() async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let fixture = WebFixture.rich()
        let url = parent.appendingPathComponent("meowverse-backup-2026-11-08.zip")
        try fixture.write(to: url)

        let store = LibraryStore(root: root, catalog: catalog)
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 1), placement: Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2), displayName: "旧的", decision: .manual)
        let prepared = try BackupArchive.prepare(file: url, stagingURL: store.makeStagingURL(), catalog: catalog)

        // Preview: what it is, and everything that will not come along.
        let preview = prepared.preview
        #expect(preview.kind == .webBackup && preview.formatVersion == 6 && preview.schemaVersion == 6 && preview.appVersion == nil)
        #expect(preview.createdAt == ISO8601DateFormatter().date(from: "2026-11-08T08:30:00Z"))
        #expect(preview.photoCount == 4, "no photo is dropped")
        #expect(preview.furnitureCount == 3)
        #expect(preview.catName == "团子")
        #expect(preview.originalBytes == fixture.photos.reduce(0) { $0 + $1.bytes.count })
        #expect(preview.notes.contains(.classicFurniture(1)))
        #expect(preview.notes.contains(.customModels(1)))
        #expect(preview.notes.contains(.customCat))
        #expect(preview.notes.contains(.analysisRecords(runs: 2, consents: 1, observations: 1)))
        #expect(preview.notes.contains(.photoAnnotations(1)))
        #expect(preview.notes.contains(.reviewMarks(1)))
        #expect(preview.notes.contains(.roomTheme))
        #expect(preview.notes.contains(.unknownModels(["未来的吊床"])))
        #expect(preview.notes.contains(.datesFromFile(1)))
        #expect(preview.notes.contains(.thumbnailsRebuilt(4)))
        #expect(!preview.notes.contains { if case .sourcesMadeManual = $0 { true } else { false } })

        let state = try await store.replaceLibrary(with: prepared)
        #expect(state.schemaVersion == AppState.currentSchemaVersion && state.revision == 42 && state.catName == "团子")

        // Photos: stable ids, byte-identical originals, dates never invented.
        #expect(state.photos.map(\.photoId) == ["photo-a", "photo-b", "photo-c", "photo-d"])
        for (photo, source) in zip(state.photos, fixture.photos) {
            #expect(TestSupport.bytes(root.appendingPathComponent(photo.originalFile)) == source.bytes)
            #expect(photo.sha256 == PhotoIngest.sha256Hex(source.bytes) && photo.byteSize == source.bytes.count)
            #expect(photo.filename == source.filename)
            #expect(photo.importedAt == ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z"))
            #expect(try await store.verifyOriginal(photoId: photo.photoId))
        }
        let a = state.photos[0], b = state.photos[1], c = state.photos[2], d = state.photos[3]
        #expect(a.captureDate == "2026-03-14" && a.captureDateSource == .exif && a.exifCaptureDate == "2026-03-14")
        #expect(a.revision == 2 && a.mimeType == "image/jpeg" && a.width == 64 && a.height == 32)
        #expect(b.captureDate == "2025-12-01" && b.captureDateSource == .user && b.exifCaptureDate == nil)
        #expect(b.favorite && b.note == "她第一次坐上这把椅子" && b.mimeType == "image/png" && b.revision == 5)
        #expect(c.captureDate == nil && c.captureDateSource == .unknown && !c.favorite && c.note.isEmpty)
        #expect(d.captureDate == nil && d.captureDateSource == .unknown, "an EXIF day the file does not contain is not kept")

        // Furniture: ids, model, placement, finish, name, tags, revision.
        #expect(state.items.map(\.instanceId) == [WebFixture.sofaId, WebFixture.chairId, WebFixture.stoolId])
        let sofa = state.items[0], chair = state.items[1], stool = state.items[2]
        #expect(sofa.modelId == "kenney-loungeSofa" && sofa.x == 1 && sofa.z == 1 && sofa.width == 3 && sofa.depth == 2)
        #expect(sofa.turn == 1 && sofa.finish == .sage && sofa.displayName == "客厅沙发" && sofa.tags == ["最爱"] && sofa.revision == 4)
        #expect(stool.x == 1 && stool.z == 1 && stool.finish == .blue, "a placement the iOS grid rules would refuse still loads")
        #expect(!GridRules.validate(stool.placement, in: state.items, catalog: catalog, ignoring: stool.instanceId).isEmpty)

        // Sources: photo, origin and relation; the recognition record is carried with its mode.
        #expect(sofa.sources.map(\.photoId) == ["photo-a", "photo-b"])
        #expect(sofa.sources[0].origin == .model && sofa.sources[0].relationToCat == .on && sofa.sources[0].observationId == "obs-a")
        #expect(sofa.sources[0].objectIndex == 0, "the rug before the sofa is not a furniture kind; the index is remapped")
        #expect(sofa.sources[1] == .manual(photoId: "photo-b"))
        #expect(chair.sources == [PhotoCarrierSource(photoId: "photo-b", observationId: "obs-b", objectIndex: 0, origin: .curatedFixture, relationToCat: .near)])
        #expect(stool.sources == [.manual(photoId: "photo-c")])
        #expect(state.observations.map(\.observationId) == ["obs-a", "obs-b"], "only observations a source points at")
        let obsA = state.observations[0], obsB = state.observations[1]
        #expect(obsA.photoId == "photo-a" && obsA.origin == .model && obsA.mode == .remote && obsA.analyzer == "web-remote")
        #expect(obsA.objects == [ObservedObject(kind: .sofa, label: "web:sofa", confidence: 0.9)])
        #expect(obsA.createdAt == ISO8601DateFormatter().date(from: "2026-11-05T12:10:00Z"))
        #expect(obsB.origin == .curatedFixture && obsB.mode == .fixture && obsB.objects.first?.kind == .chair)
        for item in state.items {
            for source in item.sources { #expect(LibraryStore.sourceIsValid(source, item: item, in: state, catalog: catalog)) }
        }

        // The result is a healthy library: files match records, it reopens, it can be edited,
        // deleted from and exported again.
        #expect(await store.integrityReport().isClean)
        #expect(siblings(parent).isEmpty)
        let reopened = LibraryStore(root: root, catalog: catalog)
        #expect(try await reopened.load() == state)
        _ = try await reopened.editPhoto(photoId: "photo-b", PhotoEdit(captureDate: .clear))
        try await reopened.deletePhoto(photoId: "photo-c")
        // Schema 6: the stool loses its only photo and stays.
        #expect(await reopened.snapshot().items.map(\.instanceId) == [WebFixture.sofaId, WebFixture.chairId, WebFixture.stoolId])
        #expect(await reopened.snapshot().item(id: WebFixture.stoolId)?.sources == [])
        _ = try await reopened.updatePlacement(instanceId: WebFixture.chairId, placement: Placement(modelId: "kenney-chair", x: 6, z: 6, width: 2, depth: 2))
        #expect(await reopened.snapshot().item(id: WebFixture.chairId)?.sources.first?.origin == .curatedFixture)
        #expect(await reopened.integrityReport().isClean)
        let again = parent.appendingPathComponent("again.zip")
        _ = try await reopened.exportBackup(to: again, appVersion: "1")
        let roundTrip = try BackupArchive.prepare(file: again, stagingURL: reopened.makeStagingURL(), catalog: catalog)
        #expect(try await reopened.replaceLibrary(with: roundTrip) == (await reopened.snapshot()))
    }

    /// The archive in Resources was produced by the web app's own `encodeArchive`
    /// (scripts/ios/make-web-backup-fixture.test.ts), not by this test target.
    @Test func backupWrittenByTheRealWebWriterImports() async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let url = try #require(Bundle.module.url(forResource: "web-v6-synthetic", withExtension: "zip"))
        struct Hashes: Decodable { let originals: [String: String] }
        let hashes = try JSONDecoder().decode(Hashes.self, from: Data(contentsOf: #require(Bundle.module.url(forResource: "web-v6-synthetic.sha256", withExtension: "json"))))

        let store = LibraryStore(root: root, catalog: catalog)
        let prepared = try BackupArchive.prepare(file: url, stagingURL: store.makeStagingURL(), catalog: catalog)
        #expect(prepared.preview.kind == .webBackup && prepared.preview.formatVersion == 6)
        #expect(prepared.preview.photoCount == 3 && prepared.preview.furnitureCount == 2 && prepared.preview.catName == "团子")
        #expect(prepared.preview.notes == [.roomTheme, .thumbnailsRebuilt(3)])
        let state = try await store.replaceLibrary(with: prepared)

        #expect(state.revision == 7)
        #expect(state.photos.map(\.photoId) == ["web-photo-1", "web-photo-2", "web-photo-3"])
        for photo in state.photos {
            #expect(photo.sha256 == hashes.originals[photo.photoId], "the hash the web app computed")
            #expect(LibraryStore.hashFile(root.appendingPathComponent(photo.originalFile)) == photo.sha256)
            #expect(photo.mimeType == "image/png" && photo.width == 64 && photo.height == 48)
            #expect(fm.fileExists(atPath: root.appendingPathComponent(photo.thumbnailFile).path))
        }
        let first = state.photos[0]
        #expect(first.captureDate == "2025-12-01" && first.captureDateSource == .user && first.exifCaptureDate == nil)
        #expect(first.favorite && first.note == "她第一次跳上这张沙发" && first.revision == 3)
        #expect(state.photos[1].captureDate == nil && state.photos[1].captureDateSource == .unknown)
        #expect(state.photos[2].importedAt == ISO8601DateFormatter().date(from: "2026-11-06T08:15:30Z"))

        let sofa = try #require(state.item(id: "web-sofa-1")), stool = try #require(state.item(id: "web-stool-1"))
        #expect(sofa.modelId == "kenney-loungeSofa" && sofa.x == 1 && sofa.z == 1 && sofa.width == 3 && sofa.depth == 2 && sofa.turn == 0)
        #expect(sofa.finish == .sage && sofa.displayName == "客厅沙发" && sofa.tags == ["最爱"] && sofa.revision == 2)
        #expect(sofa.sources == [
            PhotoCarrierSource(photoId: "web-photo-1", observationId: "web-obs-1", objectIndex: 0, origin: .curatedFixture, relationToCat: .on),
            .manual(photoId: "web-photo-2"),
        ])
        #expect(stool.modelId == "kenney-stoolBar" && stool.x == 6 && stool.z == 2 && stool.sources == [.manual(photoId: "web-photo-3")])
        let observation = try #require(state.observation(id: "web-obs-1"))
        #expect(observation.mode == .fixture && observation.origin == .curatedFixture)
        #expect(observation.objects == [ObservedObject(kind: .sofa, label: "web:sofa", confidence: 0.9)])
        // What the web accepted as a valid room is also valid under the iOS grid rules.
        for item in state.items {
            #expect(GridRules.validate(item.placement, in: state.items, catalog: catalog, ignoring: item.instanceId).isEmpty)
        }
        #expect(await store.integrityReport().isClean)
        #expect(try await LibraryStore(root: root, catalog: catalog).load() == state)
    }

    @Test func aSourceWhoseRecognitionRecordCannotBeMatchedStaysLinkedAndIsReported() throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        var fixture = WebFixture.rich()
        // Point the sofa's first source at the rug (not a furniture kind on iOS).
        var sources = fixture.gridItems[0]["sources"] as! [[String: Any]]
        sources[0]["objectIndex"] = 0
        fixture.gridItems[0]["sources"] = sources
        fixture.catName = String(repeating: "喵", count: 30)
        let url = parent.appendingPathComponent("b.zip")
        try fixture.write(to: url)
        let prepared = try BackupArchive.prepare(file: url, stagingURL: LibraryStore(root: root, catalog: catalog).makeStagingURL(), catalog: catalog)
        defer { prepared.discard() }
        #expect(prepared.preview.notes.contains(.sourcesMadeManual(1)))
        #expect(prepared.preview.notes.contains(.catNameShortened))
        #expect(prepared.preview.catName == String(repeating: "喵", count: 20))
        let sofa = try #require(prepared.state.item(id: WebFixture.sofaId))
        #expect(sofa.sources[0] == PhotoCarrierSource(photoId: "photo-a", observationId: nil, objectIndex: nil, origin: .user, relationToCat: .on))
        #expect(prepared.state.photos.count == 4)
    }

    @Test func emptyWebBackupImportsAsAnEmptyRoom() throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let url = parent.appendingPathComponent("empty.zip")
        try WebFixture().write(to: url)
        let prepared = try BackupArchive.prepare(file: url, stagingURL: LibraryStore(root: root, catalog: catalog).makeStagingURL(), catalog: catalog)
        defer { prepared.discard() }
        #expect(prepared.preview.photoCount == 0 && prepared.preview.furnitureCount == 0 && prepared.preview.notes.isEmpty)
        #expect(prepared.preview.catName == "猫猫")
    }

    @Test func unsupportedDamagedOrUnreadableWebBackupsLeaveTheRoomUntouched() async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: root, catalog: catalog)
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 1), placement: Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2), displayName: "旧的", decision: .manual)
        let state = await store.snapshot()
        let before = TestSupport.listing(root).map { ($0, TestSupport.bytes(root.appendingPathComponent($0))) }

        func attempt(_ label: String, _ change: (inout WebFixture) -> Void) -> BackupError? {
            var fixture = WebFixture.rich()
            change(&fixture)
            let url = parent.appendingPathComponent("case-\(UUID().uuidString).zip")
            var thrown: BackupError?
            do {
                try fixture.write(to: url)
                let prepared = try BackupArchive.prepare(file: url, stagingURL: store.makeStagingURL(), catalog: catalog)
                prepared.discard()
                Issue.record("\(label): accepted")
            } catch let error as BackupError {
                thrown = error
            } catch {
                Issue.record("\(label): unexpected \(error)")
            }
            #expect(siblings(parent).isEmpty, "\(label): staging left behind")
            let after = TestSupport.listing(root).map { ($0, TestSupport.bytes(root.appendingPathComponent($0))) }
            #expect(after.map(\.0) == before.map(\.0) && after.map(\.1) == before.map(\.1), "\(label): live library changed")
            return thrown
        }

        #expect(attempt("older version") { $0.version = 5 } == .unsupportedVersion)
        #expect(attempt("newer version") { $0.version = 7 } == .newerVersion)
        // An original replaced by other valid image bytes (ZIP checksums are all correct).
        #expect(attempt("swapped original") { $0.tamper = { $0["media/000000/original.bin"] = TestSupport.imageData(seed: 500) } } == .damaged("photoRecord"))
        #expect(attempt("altered original") {
            $0.tamper = { files in
                var bytes = files["media/000001/original.bin"]!
                bytes[bytes.count - 2] ^= 1
                files["media/000001/original.bin"] = bytes
            }
        } == .damaged("originalHash"))
        #expect(attempt("missing media file") { $0.tamper = { $0["media/000002/original.bin"] = nil } } == .damaged("entries"))
        #expect(attempt("extra file") { $0.editManifest = { $0["assets"] = [Any]() } } == .damaged("entries"))
        #expect(attempt("state hash") { $0.editManifest = { manifest in
            var state = manifest["state"] as! [String: Any]
            state["sha256"] = String(repeating: "0", count: 64)
            manifest["state"] = state
        } } == .damaged("stateHash"))
        // Intact bytes that are not an image this device can decode: nothing is imported.
        #expect(attempt("undecodable original") { $0.photos[2].bytes = Data((0..<500).map { UInt8($0 % 200) }) } == .unreadablePhotos(1))
        #expect(attempt("source without photo") {
            $0.gridItems[2]["sources"] = [["photoId": "ghost", "observationId": NSNull(), "objectIndex": NSNull(), "origin": "user", "relationToCat": "unclear"]]
        } == .damaged("source"))
        #expect(attempt("bad quarter turn") { $0.gridItems[1]["turn"] = 7 } == .damaged("item"))
        // Palette presets are native (schema 7); the web contract never had them.
        #expect(attempt("native-only finish") { $0.gridItems[1]["finish"] = "apricot" } == .damaged("item"))
        #expect(attempt("duplicate photo id") { $0.photos[1].id = "photo-a" } != nil)
        #expect(attempt("user date that is not a day") { $0.photos[1].captureDate = "2025-13-40" } == .damaged("captureDate"))
        #expect(attempt("note too long") {
            $0.photoDetails["photo-a"] = ["note": String(repeating: "长", count: 2001), "reviewedAt": NSNull(), "excludedTemplates": [String]()]
        } == .damaged("note"))

        #expect(await store.snapshot() == state)
        #expect(await store.integrityReport().isClean)
    }
}
