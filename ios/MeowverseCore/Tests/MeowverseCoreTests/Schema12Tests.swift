import Foundation
import Testing
@testable import MeowverseCore

/// Schema 12: ten household categories (bookcase … fireplace, art/furniture/TECH_SPEC.md §8).
/// A schema 11 build cannot decode them (`ObservedObject.kind`, catalog lookups), so it must
/// report a file that may hold one as newer, never as damaged. Older files load unchanged.
@Suite struct Schema12Tests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try FurnitureCatalog.bundled() }

    let fm = FileManager.default

    static let household: [String] = ["bookcase", "sideboard", "mediaConsole", "writingDesk", "vanity",
                                      "coatRack", "floorLamp", "roomDivider", "plantStand", "fireplace"]

    func installSchema11(at root: URL) throws {
        let source = try #require(Bundle.module.url(forResource: "schema11-library", withExtension: nil))
        try fm.copyItem(at: source, to: root)
    }

    @Test func householdCategoriesNeedSchema12() {
        #expect(AppState.currentSchemaVersion == 12)
        for raw in Self.household { #expect(FurnitureCategory(rawValue: raw) != nil, "\(raw)") }
        // The first fourteen keep their order and meaning; the wall board stays where it was.
        #expect(FurnitureCategory.allCases.prefix(15).map(\.rawValue) == [
            "chair", "stool", "bench", "table", "bed", "sofa", "scratcher", "catTree", "platform", "hideout", "toy",
            "litterBox", "windowPerch", "water", "photoBoard"])
    }

    /// Bytes the schema 11 store wrote (two rooms, two cats, a legacy id, a wall board, a stowed
    /// piece, palette finishes). They load as they are, loading writes nothing, and the next save
    /// writes schema 12 without touching the old pieces.
    @Test func aSchema11LibraryFromTheOldWriterLoadsUnchanged() async throws {
        let parent = TestSupport.tempDir()
        defer { try? fm.removeItem(at: parent) }
        let root = parent.appendingPathComponent("lib")
        try installSchema11(at: root)
        let stateURL = root.appendingPathComponent(LibraryStore.stateFile)
        let v11Bytes = try Data(contentsOf: stateURL)
        #expect(String(decoding: v11Bytes, as: UTF8.self).contains("\"schemaVersion\":11"))

        let store = LibraryStore(root: root, catalog: catalog)
        let state = try await store.load()
        #expect(state.items.map(\.modelId) == ["mv-sofa-a", "kenney-stoolBar", "mv-cat-tree-a", "wall-photo-board"])
        #expect(state.items.map(\.finish) == [.lavender, .cream, .original, .original])
        #expect(state.storage.map(\.modelId) == ["mv-bed-c"] && state.storage.first?.finish == .apricot)
        #expect(state.allRooms.count == 2 && state.allCats.map(\.name) == ["Kitty", "团子"])
        #expect(state.items[3].wall == .back)
        #expect(catalog.model(id: "kenney-stoolBar")?.id == "mv-stool-a", "the legacy id still resolves through its alias")
        #expect(await store.integrityReport().isClean)
        #expect(try Data(contentsOf: stateURL) == v11Bytes, "loading alone writes nothing")

        let bookcase = Placement(modelId: "mv-bookcase-a", x: 6, z: 6, width: 3, depth: 2, finish: .sage)
        _ = try await store.addFurniture(placement: bookcase, displayName: "书架")
        let written = String(decoding: try Data(contentsOf: stateURL), as: UTF8.self)
        #expect(written.contains("\"schemaVersion\":\(AppState.currentSchemaVersion)"))
        let reopened = try await LibraryStore(root: root, catalog: catalog).load()
        #expect(Array(reopened.items.prefix(4)) == state.items, "old pieces are written back unchanged")
        #expect(reopened.storage == state.storage && reopened.rooms == state.rooms && reopened.cats == state.cats)
        #expect(reopened.items.last?.modelId == "mv-bookcase-a")
    }

    @Test func householdPiecesRoundTripThroughTheStore() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        _ = try await store.addFurniture(placement: Placement(modelId: "mv-bookcase-a", x: 0, z: 0, width: 3, depth: 2, finish: .blush),
                                         displayName: "书架")
        _ = try await store.addFurniture(placement: Placement(modelId: "mv-fireplace-a", x: 5, z: 0, width: 3, depth: 2),
                                         displayName: "暖炉")
        let written = await store.snapshot()
        let read = try await LibraryStore(root: root, catalog: catalog).load()
        #expect(read == written)
        #expect(read.items.compactMap { catalog.model(id: $0.modelId)?.category } == [.bookcase, .fireplace])
    }

    /// What a schema 11 build sees, shown one version up: a later file holding a category this
    /// build does not know is newer (the "update the app" message), not damage.
    @Test func aNewerFileWithAnUnknownCategoryIsNewerNotCorrupt() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        try fm.removeItem(at: root)
        try installSchema11(at: root)
        let stateURL = root.appendingPathComponent(LibraryStore.stateFile)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        object["schemaVersion"] = AppState.currentSchemaVersion + 1
        object["observations"] = [["observationId": "o1", "photoId": "p1", "objects": [["kind": "hammock", "label": "hammock", "confidence": 1]]]]
        try JSONSerialization.data(withJSONObject: object).write(to: stateURL)
        try fm.removeItem(at: root.appendingPathComponent(LibraryStore.backupFile))
        guard case .newer(let version) = LibraryStore.decodeState(try Data(contentsOf: stateURL)) else {
            Issue.record("must be reported as newer"); return
        }
        #expect(version == AppState.currentSchemaVersion + 1)
        await #expect(throws: StoreError.newerSchema) { try await LibraryStore(root: root, catalog: catalog).load() }
    }

    @Test func aBackupWithHouseholdFurnitureCarriesSchema12AndRestores() async throws {
        let parent = TestSupport.tempDir()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: parent.appendingPathComponent("a"), catalog: catalog)
        _ = try await store.addFurniture(placement: Placement(modelId: "mv-fireplace-a", x: 2, z: 0, width: 3, depth: 2, finish: .apricot),
                                         displayName: "暖炉")
        let url = parent.appendingPathComponent("backup.zip")
        _ = try await store.exportBackup(to: url, appVersion: "9.9")
        let target = LibraryStore(root: parent.appendingPathComponent("b"), catalog: catalog)
        let prepared = try BackupArchive.prepare(file: url, stagingURL: target.makeStagingURL(), catalog: catalog)
        #expect(prepared.preview.schemaVersion == 12)
        let restored = try await target.replaceLibrary(with: prepared)
        #expect(restored.items.map(\.modelId) == ["mv-fireplace-a"] && restored.items.first?.finish == .apricot)
    }
}
