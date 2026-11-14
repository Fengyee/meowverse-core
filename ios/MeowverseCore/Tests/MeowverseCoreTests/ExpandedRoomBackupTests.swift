import Foundation
import Testing
@testable import MeowverseCore

@Suite struct ExpandedRoomBackupTests {
    private let catalog: FurnitureCatalog
    init() throws { catalog = try TestSupport.catalog() }

    enum HistoricalBuild: CaseIterable {
        case singleRoomV8, multiRoomV8, expandedV9, combinedV10

        var version: Int {
            switch self {
            case .singleRoomV8, .multiRoomV8: 8
            case .expandedV9: 9
            case .combinedV10: 10
            }
        }

        var corner: Int { version == 8 ? 9 : 14 }
        var hasLibraryMetadata: Bool { self != .expandedV9 }
    }

    /// Build the historical state and manifest as JSON, independently of the current Codable writer.
    /// Only the synthetic photo's bytes and hashes vary across platforms.
    private func historicalArchive(build: HistoricalBuild, at url: URL, draft: ImportDraft, source: ReducedFrom) throws {
        let ext = draft.mimeType == "image/heic" ? "heic" : "jpg"
        let stored = "originals/\(draft.sha256).\(ext)", thumbnail = "thumbnails/compact.jpg"
        var photo: [String: Any] = [
            "photoId": "compact", "filename": "large.jpg", "sha256": draft.sha256,
            "mimeType": draft.mimeType, "byteSize": draft.data.count, "width": draft.width, "height": draft.height,
            "originalFile": stored, "thumbnailFile": thumbnail, "captureDate": "2025-06-01",
            "captureDateSource": "exif", "exifCaptureDate": "2025-06-01", "importedAt": "2026-11-01T13:10:00Z",
            "favorite": true, "note": "窗边", "revision": 2, "assetIdentifier": "LOCAL-TEST/L0/001",
            "reducedFrom": ["sha256": source.sha256, "byteSize": source.byteSize, "width": source.width, "height": source.height]
        ]
        var link: [String: Any] = ["photoId": "compact", "origin": "user", "relationToCat": "unclear"]
        var item: [String: Any] = [
            "instanceId": "corner", "modelId": "kenney-stoolBar", "x": build.corner, "z": build.corner,
            "width": 1, "depth": 1, "turn": 0, "finish": "lavender", "displayName": "角落里的凳子",
            "tags": [], "revision": 3
        ]
        if build.hasLibraryMetadata {
            photo["cloudIdentifier"] = "CLOUD-TEST"
            item["locked"] = true
            item["coverPhotoId"] = "compact"
            item["createdAt"] = "2026-11-01T13:10:00Z"
            item["updatedAt"] = "2026-11-01T13:15:00Z"
            link["addedAt"] = "2026-11-01T13:12:00Z"
        }
        item["sources"] = [link]
        var state: [String: Any] = [
            "schemaVersion": build.version, "revision": 3, "catName": "团团", "photos": [photo],
            "observations": [], "items": [item], "storage": []
        ]
        if build == .multiRoomV8 {
            state["rooms"] = [["roomId": "room-1"], ["roomId": "study", "name": "书房"]]
            state["cats"] = [["catId": "cat-1", "name": "团团"], ["catId": "c2", "name": "芝麻", "roomId": "study"]]
            var studyItem = item
            studyItem["instanceId"] = "window"
            studyItem["roomId"] = "study"
            state["items"] = [item, studyItem]
            var stored = studyItem
            stored["instanceId"] = "boxed"
            state["storage"] = [stored]
        }
        let stateData = try JSONSerialization.data(withJSONObject: state)
        func entry(_ path: String, _ bytes: Data) -> [String: Any] {
            ["path": path, "byteSize": bytes.count, "sha256": PhotoIngest.sha256Hex(bytes)]
        }
        let manifest: [String: Any] = [
            "format": "meowverse-ios-backup", "formatVersion": 1, "schemaVersion": build.version,
            "appVersion": "1.0", "createdAt": "2026-11-01T13:15:00Z", "photoCount": 1, "furnitureCount": build == .multiRoomV8 ? 3 : 1,
            "state": entry("state.json", stateData), "files": [entry(stored, draft.data), entry(thumbnail, draft.thumbnailJPEG)]
        ]
        let writer = try ZipWriter(url: url)
        try writer.add(path: "manifest.json", data: JSONSerialization.data(withJSONObject: manifest))
        try writer.add(path: "state.json", data: stateData)
        try writer.add(path: stored, data: draft.data)
        try writer.add(path: thumbnail, data: draft.thumbnailJPEG)
        try writer.finish()
    }

    @Test(arguments: HistoricalBuild.allCases)
    func historicalArchiveRestoresAndReopensWithItsOriginalHomeAndPhotoLinks(build: HistoricalBuild) async throws {
        let parent = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let picked = ReducedCopyTests.noisyData(width: 2200, height: 800, seed: 42, dateTimeOriginal: "2025:06:01 08:00:00")
        let draft = try PhotoIngest.makeDraft(data: picked, filename: "large.jpg")
        let source = try #require(draft.reducedFrom)
        #expect(source.sha256 == PhotoIngest.sha256Hex(picked) && source.sha256 != draft.sha256)
        let archive = parent.appendingPathComponent("historical.zip")
        try historicalArchive(build: build, at: archive, draft: draft, source: source)

        let root = parent.appendingPathComponent("library"), store = LibraryStore(root: root, catalog: catalog)
        let prepared = try BackupArchive.prepare(file: archive, stagingURL: store.makeStagingURL(), catalog: catalog)
        #expect(prepared.preview.schemaVersion == build.version)
        let restored = try await store.replaceLibrary(with: prepared)
        #expect(restored.schemaVersion == AppState.currentSchemaVersion && restored.catName == "团团")
        let photo = try #require(restored.photo(id: "compact"))
        #expect(photo.reducedFrom == source && photo.assetIdentifier == "LOCAL-TEST/L0/001")
        #expect(photo.cloudIdentifier == (build.hasLibraryMetadata ? "CLOUD-TEST" : nil))
        let item = try #require(restored.item(id: "corner"))
        #expect(item.x == build.corner && item.z == build.corner && item.finish == .lavender)
        #expect(item.sources.map(\.photoId) == ["compact"])
        #expect(item.isLocked == build.hasLibraryMetadata)
        #expect(item.coverPhotoId == (build.hasLibraryMetadata ? "compact" : nil))
        let clock = ISO8601DateFormatter()
        #expect(item.createdAt == (build.hasLibraryMetadata ? clock.date(from: "2026-11-01T13:10:00Z") : nil))
        #expect(item.updatedAt == (build.hasLibraryMetadata ? clock.date(from: "2026-11-01T13:15:00Z") : nil))
        #expect(item.sources.first?.addedAt == (build.hasLibraryMetadata ? clock.date(from: "2026-11-01T13:12:00Z") : nil))
        #expect(restored.furniture(inRoom: AppState.primaryRoomId).map(\.instanceId) == ["corner"])
        if build == .multiRoomV8 {
            #expect(restored.allRooms == [Room(roomId: "room-1"), Room(roomId: "study", name: "书房")])
            #expect(restored.allCats == [Cat(catId: "cat-1", name: "团团"), Cat(catId: "c2", name: "芝麻", roomId: "study")])
            let secondRoom = try #require(restored.furniture(inRoom: "study").first)
            let stored = try #require(restored.storedItem(id: "boxed"))
            #expect(secondRoom.instanceId == "window" && secondRoom.placement == item.placement)
            #expect(stored.roomId == "study" && stored.sources == item.sources && secondRoom.sources == item.sources)
        } else {
            #expect(restored.allRooms == [Room(roomId: "room-1")])
            #expect(restored.allCats == [Cat(catId: "cat-1", name: "团团")])
            #expect(restored.storage.isEmpty)
        }
        #expect(photo.sha256 == draft.sha256 && photo.byteSize == draft.data.count)
        #expect(photo.note == "窗边" && photo.favorite && photo.captureDateSource == .exif && photo.captureDate == "2025-06-01")
        #expect(TestSupport.bytes(root.appendingPathComponent(photo.originalFile)) == draft.data)
        #expect(TestSupport.bytes(root.appendingPathComponent(photo.thumbnailFile)) == draft.thumbnailJPEG)
        let reopened = LibraryStore(root: root, catalog: catalog)
        #expect(try await reopened.load() == restored)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("state.json"))) as? [String: Any]
        #expect(saved?["schemaVersion"] as? Int == AppState.currentSchemaVersion)
    }

    @Test func sharedHomeExportAdvertisesAnIncompatibleVersionToOlderApps() async throws {
        let parent = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = LibraryStore(root: parent.appendingPathComponent("source"), catalog: catalog)
        let draft = try TestSupport.draft(seed: 73)
        let placement = Placement(modelId: "kenney-stoolBar", x: 14, z: 14, width: 1, depth: 1)
        let study = try await store.addRoom(name: "书房")
        let cat = try await store.addCat(name: "芝麻", roomId: study.roomId)
        let furniture = try await store.commitNewFurniture(draft: draft, placement: placement,
                                                          displayName: "角落里的凳子", decision: .manual, roomId: study.roomId)
        let photoId = try #require(furniture.sources.first?.photoId)
        let archive = parent.appendingPathComponent("room.zip")
        _ = try await store.exportBackup(to: archive, appVersion: "1.0")

        // Readers through v10 probe the manifest before opening the state or staging files.
        let reader = try ZipReader(fileURL: archive, limits: .backup)
        let manifest = try reader.extract(#require(reader.entry("manifest.json")))
        let manifestJSON = try JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        #expect(manifestJSON?["formatVersion"] as? Int == 1)
        #expect(manifestJSON?["schemaVersion"] as? Int == AppState.currentSchemaVersion)
        #expect(AppState.currentSchemaVersion > 10)
        let root = parent.appendingPathComponent("restored"), target = LibraryStore(root: root, catalog: catalog)
        let prepared = try BackupArchive.prepare(file: archive, stagingURL: target.makeStagingURL(), catalog: catalog)
        let restored = try await target.replaceLibrary(with: prepared)
        #expect(restored.schemaVersion == AppState.currentSchemaVersion && restored.items == [furniture])
        #expect(restored.furniture(inRoom: study.roomId).first?.placement == placement)
        #expect(restored.cat(id: cat.catId) == cat)
        let photo = try #require(restored.photo(id: photoId))
        #expect(photo.sha256 == draft.sha256 && TestSupport.bytes(root.appendingPathComponent(photo.originalFile)) == draft.data)
        #expect(await target.integrityReport().isClean)
    }

    @Test(arguments: [8, 11], [(8, 6), (9, 6), (8, 7)])
    func restoreChecksRoomAndCatLimitsBeforeReplacingTheLibrary(version: Int, counts: (Int, Int)) async throws {
        let parent = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let rooms = (1...counts.0).map { ["roomId": "room-\($0)"] }
        let cats = (1...counts.1).map { ["catId": "cat-\($0)", "name": "Pet \($0)"] }
        let rawState: [String: Any] = [
            "schemaVersion": version, "revision": 1, "catName": "Pet 1",
            "rooms": rooms, "cats": cats, "items": [], "photos": [], "observations": []
        ]
        let bytes = try JSONSerialization.data(withJSONObject: rawState)
        let manifest: [String: Any] = [
            "format": "meowverse-ios-backup", "formatVersion": 1, "schemaVersion": version,
            "appVersion": "1.0", "createdAt": "2026-11-01T13:15:00Z", "furnitureCount": 0, "photoCount": 0,
            "state": ["path": "state.json", "byteSize": bytes.count, "sha256": PhotoIngest.sha256Hex(bytes)], "files": []
        ]
        let file = parent.appendingPathComponent("home.zip"), writer = try ZipWriter(url: file)
        try writer.add(path: "manifest.json", data: JSONSerialization.data(withJSONObject: manifest))
        try writer.add(path: "state.json", data: bytes)
        try writer.finish()

        let root = parent.appendingPathComponent("library"), store = LibraryStore(root: root, catalog: catalog)
        let photo = try await store.addPhoto(draft: TestSupport.draft(seed: 39))
        let before = await store.snapshot()
        let staging = store.makeStagingURL()
        if counts.0 > AppState.maxRooms || counts.1 > AppState.maxCats {
            #expect(throws: BackupError.damaged("state")) {
                try BackupArchive.prepare(file: file, stagingURL: staging, catalog: catalog)
            }
            #expect(!FileManager.default.fileExists(atPath: staging.path))
            #expect(try await LibraryStore(root: root, catalog: catalog).load() == before)
            let original = try Data(contentsOf: root.appendingPathComponent(photo.originalFile))
            #expect(PhotoIngest.sha256Hex(original) == photo.sha256)
        } else {
            let prepared = try BackupArchive.prepare(file: file, stagingURL: staging, catalog: catalog)
            let restored = try await store.replaceLibrary(with: prepared)
            #expect(restored.allRooms.count == counts.0 && restored.allCats.count == counts.1)
            #expect(try await LibraryStore(root: root, catalog: catalog).load() == restored)
        }
    }
}
