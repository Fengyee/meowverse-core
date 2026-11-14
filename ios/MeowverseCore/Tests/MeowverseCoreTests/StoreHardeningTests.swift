import Foundation
import Testing
@testable import MeowverseCore

/// Load-time tolerance (schema, backup recovery, item limit), blob healing and rename.
@Suite struct StoreHardeningTests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try TestSupport.catalog() }

    let fm = FileManager.default
    let chairAt44 = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2)
    let stoolAt00 = Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1)
    let tableAt07 = Placement(modelId: "kenney-table", x: 0, z: 7, width: 3, depth: 2)

    func files(_ root: URL, _ dir: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)) ?? []).sorted()
    }

    /// Rewrites a state file's JSON in place.
    func editJSON(_ fileURL: URL, _ edit: (inout [String: Any]) -> Void) throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        edit(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)
    }

    /// Two committed items, so both state.json and state.backup.json exist.
    func seeded(_ root: URL, fault: (@Sendable (StoreStep) throws -> Void)? = nil) async throws -> (LibraryStore, PhotoFurniture, PhotoFurniture) {
        let store = LibraryStore(root: root, catalog: catalog, fault: fault)
        let a = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 1000), placement: chairAt44,
                                                   displayName: "a", decision: .manual)
        let b = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 1001), placement: stoolAt00,
                                                   displayName: "b", decision: .manual)
        return (store, a, b)
    }

    // MARK: - Schema

    @Test(arguments: [false, true])
    func newerSchemaThrowsDistinctErrorAndTouchesNothing(backupOnly: Bool) async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        _ = try await seeded(root)
        let primary = root.appendingPathComponent("state.json"), backup = root.appendingPathComponent("state.backup.json")
        if backupOnly {
            try Data("{ torn".utf8).write(to: primary)
        }
        try editJSON(backupOnly ? backup : primary) {
            $0["schemaVersion"] = AppState.currentSchemaVersion + 1
            $0["futureField"] = [1, 2]
        }
        let listing = TestSupport.listing(root)
        let primaryBytes = TestSupport.bytes(primary), backupBytes = TestSupport.bytes(backup)

        let store = LibraryStore(root: root, catalog: catalog)
        await #expect(throws: StoreError.newerSchema) { try await store.load() }
        await #expect(throws: StoreError.newerSchema) {
            try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 1002), placement: tableAt07,
                                               displayName: "c", decision: .manual)
        }
        await #expect(throws: StoreError.newerSchema) { try await store.removeFurniture(instanceId: "x") }
        #expect(await store.snapshot() == .empty)
        #expect(await store.recoveredFromBackup == false)
        #expect(TestSupport.listing(root) == listing)
        #expect(TestSupport.bytes(primary) == primaryBytes)
        #expect(TestSupport.bytes(backup) == backupBytes)
    }

    // MARK: - Backup recovery

    @Test(arguments: [8, AppState.currentSchemaVersion + 1])
    func aRollbackCopyKeepsItsPhotoFilesWhenThePrimaryLoads(version: Int) async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let (seed, first, second) = try await seeded(root)
        let snapshot = await seed.snapshot()
        let backupOnlyPhoto = try #require(snapshot.photo(id: second.sources[0].photoId))
        let files = [backupOnlyPhoto.originalFile, backupOnlyPhoto.thumbnailFile].map(root.appendingPathComponent)
        let bytes = try files.map { try Data(contentsOf: $0) }
        let primary = root.appendingPathComponent(LibraryStore.stateFile)
        let rollback = root.appendingPathComponent(LibraryStore.backupFile)
        let singlePieceState = try Data(contentsOf: rollback)
        try Data(contentsOf: primary).write(to: rollback)
        try singlePieceState.write(to: primary)
        try editJSON(rollback) {
            $0["schemaVersion"] = version
            $0["rooms"] = [["roomId": "room-1"], ["roomId": "room-2"]]
        }

        let reopened = LibraryStore(root: root, catalog: catalog)
        #expect(try await reopened.load().items == [first])
        #expect(files.map(TestSupport.bytes) == bytes)

        // A user save rotates the supported primary into the rollback slot. Once neither
        // state can reference these files, ordinary cleanup may reclaim them again.
        try await reopened.setCatName("团团")
        _ = try await LibraryStore(root: root, catalog: catalog).load()
        #expect(files.allSatisfy { !fm.fileExists(atPath: $0.path) })
    }

    @Test func backupFallbackIsReportedAndSkipsOrphanCleanup() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let (seed, a, _) = try await seeded(root)
        #expect(await seed.recoveredFromBackup == false)
        try Data("{ torn".utf8).write(to: root.appendingPathComponent("state.json"))
        let originals = files(root, "originals"), thumbnails = files(root, "thumbnails")
        #expect(originals.count == 2)

        let store = LibraryStore(root: root, catalog: catalog)
        let state = try await store.load()
        #expect(await store.recoveredFromBackup)
        #expect(state.items.map(\.instanceId) == [a.instanceId])
        // b's blobs are unreferenced by the backup, yet must survive a fallback load.
        #expect(files(root, "originals") == originals)
        #expect(files(root, "thumbnails") == thumbnails)
        #expect(await store.integrityReport().orphanFiles.count == 2)

        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 1003), placement: tableAt07,
                                               displayName: "c", decision: .manual)
        #expect(await store.recoveredFromBackup == false)
        let reopened = LibraryStore(root: root, catalog: catalog)
        _ = try await reopened.load()
        #expect(await reopened.recoveredFromBackup == false)
    }

    // MARK: - Item limit

    @Test func moreThanMaxItemsStoredStillLoadsButCannotGrow() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 1010), placement: chairAt44,
                                               displayName: "a", decision: .manual)
        try editJSON(root.appendingPathComponent("state.json")) { object in
            let items = object["items"] as! [[String: Any]]
            var copies: [[String: Any]] = []
            for n in 0...GridRules.maxItems {
                var item = items[0]
                item["instanceId"] = "copy-\(n)"
                copies.append(item)
            }
            object["items"] = copies
        }
        let reopened = LibraryStore(root: root, catalog: catalog)
        let state = try await reopened.load()
        #expect(state.items.count == GridRules.maxItems + 1)
        #expect(await reopened.recoveredFromBackup == false)
        await #expect(throws: StoreError.self) {
            try await reopened.commitNewFurniture(draft: try TestSupport.draft(seed: 1011), placement: tableAt07,
                                                  displayName: "b", decision: .manual)
        }
        // Existing items can still be edited.
        _ = try await reopened.rename(instanceId: "copy-3", displayName: "still editable")
    }

    // MARK: - Healing

    @Test func reimportHealsMissingOriginalAndThumbnail() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let draft = try TestSupport.draft(seed: 1020)
        let first = try await store.commitNewFurniture(draft: draft, placement: chairAt44, displayName: "a", decision: .manual)
        let photoId = first.sources[0].photoId
        let original = try #require(await store.originalURL(photoId: photoId))
        let thumbnail = try #require(await store.thumbnailURL(photoId: photoId))
        try fm.removeItem(at: original)
        try fm.removeItem(at: thumbnail)
        #expect(await store.integrityReport().missingOriginals == [photoId])

        let second = try await store.commitNewFurniture(draft: draft, placement: tableAt07, displayName: "b", decision: .manual)
        #expect(second.sources[0].photoId == photoId)
        #expect(try Data(contentsOf: original) == draft.data)
        #expect(fm.fileExists(atPath: thumbnail.path))
        #expect(await store.integrityReport().isClean)
    }

    @Test func duplicateAddSourceStillHealsAndThrows() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let draft = try TestSupport.draft(seed: 1030)
        let item = try await store.commitNewFurniture(draft: draft, placement: chairAt44, displayName: "a", decision: .manual)
        let photoId = item.sources[0].photoId
        let original = try #require(await store.originalURL(photoId: photoId))
        try Data("rot".utf8).write(to: original)
        let stateBytes = TestSupport.bytes(root.appendingPathComponent("state.json"))

        await #expect(throws: StoreError.duplicateSource) {
            try await store.addSource(draft: draft, toInstance: item.instanceId, decision: .manual)
        }
        #expect(try await store.verifyOriginal(photoId: photoId))
        #expect(TestSupport.bytes(root.appendingPathComponent("state.json")) == stateBytes)
        #expect(await store.integrityReport().isClean)
    }

    /// A heal that happens in a commit which then fails keeps the healed (correct) bytes and
    /// leaves the state untouched; the retry succeeds.
    @Test func healDuringFailedCommitKeepsStateAndRetryWorks() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let fault = FaultSwitch(nil)
        let store = LibraryStore(root: root, catalog: catalog, fault: fault.handler)
        let draft = try TestSupport.draft(seed: 1040)
        let first = try await store.commitNewFurniture(draft: draft, placement: chairAt44, displayName: "a", decision: .manual)
        let photoId = first.sources[0].photoId
        let original = try #require(await store.originalURL(photoId: photoId))
        try draft.data.prefix(10).write(to: original)
        let memory = await store.snapshot()
        let stateBytes = TestSupport.bytes(root.appendingPathComponent("state.json"))

        fault.arm(.writeState)
        await #expect(throws: InjectedFault.failed(.writeState)) {
            try await store.commitNewFurniture(draft: draft, placement: tableAt07, displayName: "b", decision: .manual)
        }
        #expect(await store.snapshot() == memory)
        #expect(TestSupport.bytes(root.appendingPathComponent("state.json")) == stateBytes)
        #expect(try await store.verifyOriginal(photoId: photoId))
        _ = try await store.commitNewFurniture(draft: draft, placement: tableAt07, displayName: "b", decision: .manual)
        #expect(await store.integrityReport().isClean)
    }

    // MARK: - Removal and backup

    @Test func photoDeletionLeavesNoBackupReferenceToDeletedBlobs() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let (store, a, b) = try await seeded(root)
        try await store.deletePhoto(photoId: b.sources[0].photoId)
        try Data("{ torn".utf8).write(to: root.appendingPathComponent("state.json"))

        let reopened = LibraryStore(root: root, catalog: catalog)
        let state = try await reopened.load()
        #expect(await reopened.recoveredFromBackup)
        // Schema 6: "b" stays, without the deleted photo.
        #expect(state.items.map(\.instanceId) == [a.instanceId, b.instanceId])
        #expect(state.item(id: b.instanceId)?.sources == [] && state.photo(id: b.sources[0].photoId) == nil)
        #expect(await reopened.integrityReport().isClean)
    }

    // MARK: - Rename

    @Test func renamePersistsAcrossReopen() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let (store, a, _) = try await seeded(root)
        let revision = await store.snapshot().revision

        let renamed = try await store.rename(instanceId: a.instanceId, displayName: "  Bella's chair \n")
        #expect(renamed.displayName == "Bella's chair")
        #expect(renamed.revision == a.revision + 1)
        #expect(await store.snapshot().revision == revision + 1)

        // Empty / whitespace-only keeps the name and writes nothing.
        let stateBytes = TestSupport.bytes(root.appendingPathComponent("state.json"))
        let kept = try await store.rename(instanceId: a.instanceId, displayName: "   ")
        #expect(kept == renamed)
        #expect(TestSupport.bytes(root.appendingPathComponent("state.json")) == stateBytes)
        await #expect(throws: StoreError.unknownInstance) { try await store.rename(instanceId: "nope", displayName: "x") }

        let reopened = LibraryStore(root: root, catalog: catalog)
        #expect(try await reopened.load().item(id: a.instanceId) == renamed)
    }

    @Test func renameFaultLeavesNameUnchangedAndRetryWorks() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let fault = FaultSwitch(nil)
        let (store, a, _) = try await seeded(root, fault: fault.handler)
        let memory = await store.snapshot()
        let listing = TestSupport.listing(root)
        let stateBytes = TestSupport.bytes(root.appendingPathComponent("state.json"))
        let backupBytes = TestSupport.bytes(root.appendingPathComponent("state.backup.json"))

        fault.arm(.writeState)
        await #expect(throws: InjectedFault.failed(.writeState)) {
            try await store.rename(instanceId: a.instanceId, displayName: "new")
        }
        #expect(await store.snapshot() == memory)
        #expect(TestSupport.listing(root) == listing)
        #expect(TestSupport.bytes(root.appendingPathComponent("state.json")) == stateBytes)
        #expect(TestSupport.bytes(root.appendingPathComponent("state.backup.json")) == backupBytes)

        let renamed = try await store.rename(instanceId: a.instanceId, displayName: "new")
        #expect(renamed.displayName == "new")
        let reopened = LibraryStore(root: root, catalog: catalog)
        #expect(try await reopened.load().item(id: a.instanceId)?.displayName == "new")
    }
}
