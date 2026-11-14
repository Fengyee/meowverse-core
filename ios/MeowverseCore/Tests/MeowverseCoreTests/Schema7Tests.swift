import Foundation
import Testing
@testable import MeowverseCore

/// Schema 7: `Finish` gains the palette presets apricot, blush and lavender
/// (art/furniture/TECH_SPEC.md §8). Older files load unchanged; a build that knows schema 6 at
/// most refuses a schema 7 file or backup as newer, never as corrupt.
@Suite struct Schema7Tests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try TestSupport.catalog() }

    let fm = FileManager.default

    func editJSON(_ fileURL: URL, _ edit: (inout [String: Any]) -> Void) throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        edit(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)
    }

    @Test func finishesFollowThePresetOrderAfterTheLegacyFour() {
        #expect(Finish.allCases.map(\.rawValue) == ["original", "cream", "sage", "blue", "apricot", "blush", "lavender"])
        #expect(Finish.legacy == [.original, .cream, .sage, .blue])
        #expect(AppState.currentSchemaVersion >= 7)
    }

    /// A state.json exactly as schema 6 wrote it, with every legacy finish: it loads unchanged,
    /// loading writes nothing, and the next save writes the current schema.
    @Test func schema6FileLoadsUnchangedAndIsRewrittenWithTheCurrentVersion() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let seedStore = LibraryStore(root: root, catalog: catalog)
        var seeded: [PhotoFurniture] = []
        for (n, finish) in Finish.legacy.enumerated() {
            let placement = Placement(modelId: "kenney-stoolBar", x: n * 2, z: 0, width: 1, depth: 1, finish: finish)
            seeded.append(try await seedStore.addFurniture(placement: placement, displayName: "凳\(n)"))
        }
        let before = await seedStore.snapshot()
        for name in ["state.json", "state.backup.json"] {
            try editJSON(root.appendingPathComponent(name)) { $0["schemaVersion"] = 6 }
        }
        let v6Bytes = try Data(contentsOf: root.appendingPathComponent("state.json"))
        #expect(String(decoding: v6Bytes, as: UTF8.self).contains("\"finish\":\"cream\""))

        let store = LibraryStore(root: root, catalog: catalog)
        let state = try await store.load()
        #expect(state == before, "same pieces and finishes")
        #expect(state.items.map(\.finish) == Finish.legacy)
        #expect(try Data(contentsOf: root.appendingPathComponent("state.json")) == v6Bytes, "loading alone writes nothing")

        var edited = seeded[0].placement
        edited.finish = .apricot
        _ = try await store.updatePlacement(instanceId: seeded[0].instanceId, placement: edited)
        let json = String(decoding: try Data(contentsOf: root.appendingPathComponent("state.json")), as: UTF8.self)
        #expect(json.contains("\"schemaVersion\":\(AppState.currentSchemaVersion)") && json.contains("\"finish\":\"apricot\""))
    }

    @Test func newFinishesRoundTripThroughTheStore() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        for (n, finish) in [Finish.apricot, .blush, .lavender].enumerated() {
            let placement = Placement(modelId: "kenney-stoolBar", x: n * 2, z: 2, width: 1, depth: 1, finish: finish)
            _ = try await store.addFurniture(placement: placement, displayName: "凳\(n)")
        }
        let written = await store.snapshot()
        let reopened = LibraryStore(root: root, catalog: catalog)
        let read = try await reopened.load()
        #expect(read == written)
        #expect(read.items.map(\.finish) == [.apricot, .blush, .lavender])
        #expect(await reopened.integrityReport().isClean)
    }

    /// What an older build sees: a later schema with a finish it does not know must be reported
    /// as newer (the existing "update the app" message), not as damage. Shown here one version up.
    @Test func aNewerFileWithAnUnknownFinishIsNewerNotCorrupt() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let seedStore = LibraryStore(root: root, catalog: catalog)
        _ = try await seedStore.addFurniture(placement: Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1),
                                             displayName: "凳")
        // One save: there is no state.backup.json yet.
        for name in ["state.json"] {
            try editJSON(root.appendingPathComponent(name)) { object in
                object["schemaVersion"] = AppState.currentSchemaVersion + 1
                var items = object["items"] as! [[String: Any]]
                items[0]["finish"] = "teal"
                object["items"] = items
            }
        }
        let store = LibraryStore(root: root, catalog: catalog)
        await #expect(throws: StoreError.newerSchema) { try await store.load() }
    }

    /// Expanded placements require schema 9 or later in both manifest and state.
    @Test func expandedRoomSurvivesBackupAndRestore() async throws {
        let parent = TestSupport.tempDir()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: parent.appendingPathComponent("a"), catalog: catalog)
        _ = try await store.addFurniture(placement: Placement(modelId: "kenney-stoolBar", x: 14, z: 14, width: 1, depth: 1, finish: .lavender),
                                         displayName: "凳")
        let url = parent.appendingPathComponent("backup.zip")
        _ = try await store.exportBackup(to: url, appVersion: "9.9")
        let target = LibraryStore(root: parent.appendingPathComponent("b"), catalog: catalog)
        let prepared = try BackupArchive.prepare(file: url, stagingURL: target.makeStagingURL(), catalog: catalog)
        #expect(prepared.preview.schemaVersion == AppState.currentSchemaVersion && prepared.preview.schemaVersion >= 9)
        let restored = try await target.replaceLibrary(with: prepared)
        #expect(restored.items.map(\.finish) == [.lavender] && restored.items.first?.x == 14 && restored.items.first?.z == 14)
    }
}
