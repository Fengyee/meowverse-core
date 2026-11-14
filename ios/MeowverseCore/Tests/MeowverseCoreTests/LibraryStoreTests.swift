import CryptoKit
import Foundation
import Testing
@testable import MeowverseCore

@Suite struct LibraryStoreTests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try TestSupport.catalog() }

    let chairAt44 = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2, turn: 0, finish: .sage)

    func recognition(_ kinds: [FurnitureCategory]) -> RecognitionResult {
        RecognitionResult(analyzer: "test", analyzerRevision: 1,
                          objects: kinds.enumerated().map { ObservedObject(kind: $1, label: $1.rawValue, confidence: 0.9 - Double($0) * 0.1) },
                          catLikely: nil)
    }

    func originalsCount(_ root: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("originals").path).count) ?? -1
    }

    @Test func emptyStoreLoads() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        #expect(try await store.load() == .empty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("originals").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("thumbnails").path))
    }

    @Test func commitSurvivesRelaunch() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = try TestSupport.draft(seed: 1)
        let store = LibraryStore(root: root, catalog: catalog)
        try await store.load()
        let item = try await store.commitNewFurniture(draft: draft, placement: chairAt44, displayName: "  阅读椅 ", decision: .manual)
        #expect(item.displayName == "阅读椅")
        #expect(item.revision == 1)
        let photoId = try #require(item.sources.first?.photoId)
        let before = await store.snapshot()
        #expect(before.revision == 1)

        // "Force-quit": a brand-new store over the same root.
        let reopened = LibraryStore(root: root, catalog: catalog)
        let after = try await reopened.load()
        #expect(after == before)
        #expect(after.items.map(\.instanceId) == [item.instanceId])
        #expect(after.items.first?.sources.first?.photoId == photoId)
        let url = try #require(await reopened.originalURL(photoId: photoId))
        let bytes = try Data(contentsOf: url)
        #expect(bytes == draft.data)
        #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == draft.sha256)
        #expect(try await reopened.verifyOriginal(photoId: photoId))
        #expect(await reopened.integrityReport().isClean)
        #expect(await reopened.furniture(containingPhoto: photoId).map(\.instanceId) == [item.instanceId])
        let record = try #require(after.photo(id: photoId))
        #expect(record.originalFile == "originals/\(draft.sha256).jpeg")
        #expect(record.thumbnailFile == "thumbnails/\(photoId).jpg")
        #expect(record.filename == "synthetic-1.jpg")
        let thumb = try #require(await reopened.thumbnailURL(photoId: photoId))
        #expect(try Data(contentsOf: thumb) == draft.thumbnailJPEG)
    }

    @Test func stateJsonUsesContractKeys() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(), placement: chairAt44, displayName: "c", decision: .manual)
        let json = try #require(String(data: Data(contentsOf: root.appendingPathComponent("state.json")), encoding: .utf8))
        for key in ["\"instanceId\"", "\"modelId\"", "\"relationToCat\":\"unclear\"", "\"observationId\":null",
                    "\"objectIndex\":null", "\"origin\":\"user\"", "\"captureDateSource\":\"unknown\"", "\"schemaVersion\":\(AppState.currentSchemaVersion)", "\"catName\":\"Kitty\"", "\"favorite\":false", "\"note\":\"\"",
                    "\"captureDate\":null", "\"exifCaptureDate\":null"] {
            #expect(json.contains(key), "state.json contains \(key)")
        }
        #expect(json.range(of: #""importedAt":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ""#, options: .regularExpression) != nil)
    }

    @Test func duplicateImportReusesPhotoAndBlob() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        try await store.load()
        let first = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 2), placement: chairAt44, displayName: "a", decision: .manual)
        // Same bytes, new draft object (new draft id).
        let again = try TestSupport.draft(seed: 2)
        #expect(await store.existingPhoto(matching: again)?.photoId == first.sources[0].photoId)
        let table = Placement(modelId: "kenney-table", x: 0, z: 0, width: 3, depth: 2)
        let second = try await store.commitNewFurniture(draft: again, placement: table, displayName: "b", decision: .manual)
        #expect(second.sources[0].photoId == first.sources[0].photoId)
        #expect(second.instanceId != first.instanceId)
        let state = await store.snapshot()
        #expect(state.photos.count == 1)
        #expect(originalsCount(root) == 1)
        let thumbs = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("thumbnails").path)
        #expect(thumbs.count == 1)
        #expect(await store.furniture(containingPhoto: first.sources[0].photoId).count == 2)
    }

    @Test func addSourceAndDuplicateSource() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let item = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 3), placement: chairAt44, displayName: "a", decision: .manual)
        let added = try await store.addSource(draft: try TestSupport.draft(seed: 4), toInstance: item.instanceId,
                                              decision: SourceDecision(recognition: recognition([.chair]), acceptedObjectIndex: 0))
        #expect(added.sources.count == 2)
        #expect(added.revision == 2)
        #expect(added.sources[1].origin == .model)
        let before = await store.snapshot()
        let listing = TestSupport.listing(root)
        await #expect(throws: StoreError.duplicateSource) {
            try await store.addSource(draft: try TestSupport.draft(seed: 3), toInstance: item.instanceId, decision: .manual)
        }
        await #expect(throws: StoreError.unknownInstance) {
            try await store.addSource(draft: try TestSupport.draft(seed: 5), toInstance: "nope", decision: .manual)
        }
        #expect(await store.snapshot() == before)
        #expect(TestSupport.listing(root) == listing)
        #expect(await store.integrityReport().isClean)
    }

    @Test func sourceOriginRuleAtCommit() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)

        // Accepted & category matches -> model origin with exact observation reference.
        let rec = recognition([.sofa, .chair])
        let accepted = try await store.commitNewFurniture(
            draft: try TestSupport.draft(seed: 10), placement: chairAt44, displayName: "a",
            decision: SourceDecision(recognition: rec, acceptedObjectIndex: 1))
        let s = accepted.sources[0]
        #expect(s.origin == .model && s.objectIndex == 1 && s.relationToCat == .unclear)
        let state1 = await store.snapshot()
        let observationId = try #require(s.observationId)
        let obs = try #require(state1.observation(id: observationId))
        #expect(obs.photoId == s.photoId && obs.origin == .model && obs.mode == .onDevice)
        #expect(obs.objects == rec.objects && obs.analyzer == "test" && obs.analyzerRevision == 1)

        // Overridden (user picked a table, suggestion was sofa) -> user, nil refs, observation still stored.
        let table = Placement(modelId: "kenney-table", x: 0, z: 0, width: 3, depth: 2)
        let overridden = try await store.commitNewFurniture(
            draft: try TestSupport.draft(seed: 11), placement: table, displayName: "b",
            decision: SourceDecision(recognition: recognition([.sofa]), acceptedObjectIndex: nil))
        #expect(overridden.sources[0].untimed == .manual(photoId: overridden.sources[0].photoId))
        // Accepted index whose kind does not match the placed model -> also user.
        let mismatch = try await store.commitNewFurniture(
            draft: try TestSupport.draft(seed: 12), placement: Placement(modelId: "kenney-bench", x: 0, z: 8, width: 3, depth: 1),
            displayName: "c", decision: SourceDecision(recognition: recognition([.sofa]), acceptedObjectIndex: 0))
        #expect(mismatch.sources[0].origin == .user && mismatch.sources[0].observationId == nil)
        let state = await store.snapshot()
        #expect(state.observations.count == 3)
        #expect(state.observations.contains { $0.photoId == overridden.sources[0].photoId })
        // Manual decision stores no observation.
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 13),
                                               placement: Placement(modelId: "kenney-stoolBar", x: 9, z: 0, width: 1, depth: 1),
                                               displayName: "d", decision: .manual)
        #expect(await store.snapshot().observations.count == 3)
        #expect(await store.integrityReport().isClean)
    }

    @Test(arguments: [StoreStep.writeOriginal, .writeThumbnail, .writeState])
    func injectedFailureIsAllOrNothing(step: StoreStep) async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fault = FaultSwitch(nil)
        let store = LibraryStore(root: root, catalog: catalog, fault: fault.handler)
        // Seed one committed item so there is a real state.json + backup to protect.
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 20), placement: chairAt44, displayName: "a", decision: .manual)
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 21),
                                               placement: Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1),
                                               displayName: "b", decision: .manual)
        let stateBytes = TestSupport.bytes(root.appendingPathComponent("state.json"))
        let backupBytes = TestSupport.bytes(root.appendingPathComponent("state.backup.json"))
        let listing = TestSupport.listing(root)
        let memory = await store.snapshot()

        let draft = try TestSupport.draft(seed: 22)
        let table = Placement(modelId: "kenney-table", x: 0, z: 7, width: 3, depth: 2)
        fault.arm(step)
        await #expect(throws: InjectedFault.failed(step)) {
            try await store.commitNewFurniture(draft: draft, placement: table, displayName: "c",
                                               decision: SourceDecision(recognition: recognition([.table]), acceptedObjectIndex: 0))
        }
        #expect(TestSupport.bytes(root.appendingPathComponent("state.json")) == stateBytes)
        #expect(TestSupport.bytes(root.appendingPathComponent("state.backup.json")) == backupBytes)
        #expect(TestSupport.listing(root) == listing)
        #expect(await store.snapshot() == memory)

        // Retry of the same call succeeds.
        let item = try await store.commitNewFurniture(draft: draft, placement: table, displayName: "c",
                                                      decision: SourceDecision(recognition: recognition([.table]), acceptedObjectIndex: 0))
        #expect(await store.snapshot().revision == memory.revision + 1)
        #expect(await store.integrityReport().isClean)
        let reopened = LibraryStore(root: root, catalog: catalog)
        #expect(try await reopened.load().item(id: item.instanceId) == item)
    }

    @Test func injectedStateFailureOnUpdateAndAddSource() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fault = FaultSwitch(nil)
        let store = LibraryStore(root: root, catalog: catalog, fault: fault.handler)
        let item = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 30), placement: chairAt44, displayName: "a", decision: .manual)
        let stateBytes = TestSupport.bytes(root.appendingPathComponent("state.json"))
        let listing = TestSupport.listing(root)
        let memory = await store.snapshot()

        var moved = chairAt44; moved.x = 0; moved.turn = 1
        fault.arm(.writeState)
        await #expect(throws: InjectedFault.failed(.writeState)) { try await store.updatePlacement(instanceId: item.instanceId, placement: moved) }
        fault.arm(.writeThumbnail)
        let extra = try TestSupport.draft(seed: 31)
        await #expect(throws: InjectedFault.failed(.writeThumbnail)) { try await store.addSource(draft: extra, toInstance: item.instanceId, decision: .manual) }
        fault.arm(.writeState)
        await #expect(throws: InjectedFault.failed(.writeState)) { try await store.removeFurniture(instanceId: item.instanceId) }
        #expect(TestSupport.bytes(root.appendingPathComponent("state.json")) == stateBytes)
        #expect(TestSupport.listing(root) == listing)
        #expect(await store.snapshot() == memory)

        let updated = try await store.updatePlacement(instanceId: item.instanceId, placement: moved)
        #expect(updated.x == 0 && updated.turn == 1 && updated.revision == 2)
        _ = try await store.addSource(draft: extra, toInstance: item.instanceId, decision: .manual)
        #expect(await store.integrityReport().isClean)
    }

    @Test func placementValidatedBeforeAnyWrite() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let a = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 40), placement: chairAt44, displayName: "a", decision: .manual)
        let listing = TestSupport.listing(root)
        await #expect(throws: StoreError.placement([.overlaps(instanceId: a.instanceId)])) {
            try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 41), placement: chairAt44, displayName: "b", decision: .manual)
        }
        await #expect(throws: StoreError.placement([.outOfBounds])) {
            try await store.updatePlacement(instanceId: a.instanceId, placement: Placement(modelId: "kenney-chair", x: 14, z: 0, width: 2, depth: 2))
        }
        #expect(TestSupport.listing(root) == listing)
        // Moving onto its own old cells is fine.
        var shift = chairAt44; shift.x = 5
        #expect(try await store.updatePlacement(instanceId: a.instanceId, placement: shift).x == 5)
    }

    @Test func modelChangeAcrossCategoryDowngradesModelSources() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let a = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 45), placement: chairAt44, displayName: "a",
                                                   decision: SourceDecision(recognition: recognition([.chair]), acceptedObjectIndex: 0))
        #expect(a.sources[0].origin == .model)
        let same = try await store.updatePlacement(instanceId: a.instanceId, placement: Placement(modelId: "kenney-chairRounded", x: 4, z: 4, width: 2, depth: 2))
        #expect(same.sources[0].origin == .model)
        let sofa = try await store.updatePlacement(instanceId: a.instanceId, placement: Placement(modelId: "kenney-loungeSofa", x: 4, z: 4, width: 3, depth: 2))
        #expect(sofa.sources[0] == .manual(photoId: a.sources[0].photoId))
        #expect(await store.integrityReport().isClean)
    }

    @Test func corruptPrimaryFallsBackToBackup() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let first = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 50), placement: chairAt44, displayName: "a", decision: .manual)
        let afterFirst = await store.snapshot()
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 51),
                                               placement: Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1),
                                               displayName: "b", decision: .manual)
        let backupBytes = try #require(TestSupport.bytes(root.appendingPathComponent("state.backup.json")))
        try Data("{ not json".utf8).write(to: root.appendingPathComponent("state.json"))

        let reopened = LibraryStore(root: root, catalog: catalog)
        let loaded = try await reopened.load()
        #expect(loaded == afterFirst)
        #expect(loaded.item(id: first.instanceId) != nil)
        // The second photo's blobs are orphans now (reported, not deleted while on the backup).
        #expect(!(await reopened.integrityReport().orphanFiles.isEmpty))
        // Next commit rewrites primary, keeping the good backup intact.
        _ = try await reopened.commitNewFurniture(draft: try TestSupport.draft(seed: 52),
                                                  placement: Placement(modelId: "kenney-stoolBar", x: 9, z: 0, width: 1, depth: 1),
                                                  displayName: "c", decision: .manual)
        #expect(TestSupport.bytes(root.appendingPathComponent("state.backup.json")) == backupBytes)
        let third = LibraryStore(root: root, catalog: catalog)
        #expect(try await third.load().items.count == 2)
    }

    @Test func bothCorruptThrowsAndNeverWrites() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = LibraryStore(root: root, catalog: catalog)
        _ = try await seed.commitNewFurniture(draft: try TestSupport.draft(seed: 60), placement: chairAt44, displayName: "a", decision: .manual)
        _ = try await seed.commitNewFurniture(draft: try TestSupport.draft(seed: 61),
                                              placement: Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1),
                                              displayName: "b", decision: .manual)
        let garbage = Data("garbage".utf8), garbage2 = Data("{\"schemaVersion\":1}".utf8)
        try garbage.write(to: root.appendingPathComponent("state.json"))
        try garbage2.write(to: root.appendingPathComponent("state.backup.json"))
        let listing = TestSupport.listing(root)

        let store = LibraryStore(root: root, catalog: catalog)
        await #expect(throws: StoreError.corruptState) { try await store.load() }
        await #expect(throws: StoreError.corruptState) {
            try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 62),
                                               placement: Placement(modelId: "kenney-stoolBar", x: 9, z: 9, width: 1, depth: 1),
                                               displayName: "c", decision: .manual)
        }
        await #expect(throws: StoreError.corruptState) { try await store.removeFurniture(instanceId: "x") }
        #expect(TestSupport.bytes(root.appendingPathComponent("state.json")) == garbage)
        #expect(TestSupport.bytes(root.appendingPathComponent("state.backup.json")) == garbage2)
        #expect(TestSupport.listing(root) == listing)
        #expect(await store.snapshot() == .empty)
    }

    /// Removing furniture never deletes photos; deleting the photos is a separate, explicit step.
    @Test func removeFurnitureKeepsPhotosUntilTheyAreDeleted() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let shared = try TestSupport.draft(seed: 70)
        let a = try await store.commitNewFurniture(draft: shared, placement: chairAt44, displayName: "a",
                                                   decision: SourceDecision(recognition: recognition([.chair]), acceptedObjectIndex: 0))
        let a2 = try await store.addSource(draft: try TestSupport.draft(seed: 71), toInstance: a.instanceId, decision: .manual)
        let b = try await store.commitNewFurniture(draft: shared, placement: Placement(modelId: "kenney-table", x: 0, z: 0, width: 3, depth: 2),
                                                   displayName: "b", decision: .manual)
        let sharedId = a.sources[0].photoId, onlyA = a2.sources[1].photoId
        #expect(originalsCount(root) == 2)

        try await store.removeFurniture(instanceId: a.instanceId)
        var state = await store.snapshot()
        #expect(state.items.map(\.instanceId) == [b.instanceId])
        #expect(state.photo(id: sharedId) != nil, "still referenced by b")
        #expect(state.photo(id: onlyA) != nil, "kept in the library, unlinked")
        #expect(state.furniture(containing: onlyA).isEmpty)
        #expect(originalsCount(root) == 2)
        #expect(try await store.verifyOriginal(photoId: onlyA))
        #expect(await store.integrityReport().isClean)

        try await store.removeFurniture(instanceId: b.instanceId)
        state = await store.snapshot()
        #expect(state.items.isEmpty && state.photos.count == 2 && state.observations.count == 1)
        #expect(originalsCount(root) == 2)
        #expect(await store.integrityReport().isClean)
        await #expect(throws: StoreError.unknownInstance) { try await store.removeFurniture(instanceId: b.instanceId) }

        try await store.deletePhoto(photoId: onlyA)
        #expect(originalsCount(root) == 1)
        #expect(await store.originalURL(photoId: onlyA) == nil)
        try await store.deletePhoto(photoId: sharedId)
        #expect(await store.snapshot().photos.isEmpty)
        #expect(await store.snapshot().observations.isEmpty)
        #expect(originalsCount(root) == 0)
        #expect(await store.integrityReport().isClean)
    }

    @Test func integrityReportFindsProblemsAndLoadCleansOrphans() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let a = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 80), placement: chairAt44, displayName: "a", decision: .manual)
        let photoId = a.sources[0].photoId
        let original = try #require(await store.originalURL(photoId: photoId))
        try Data("tampered".utf8).write(to: original)
        try FileManager.default.removeItem(at: try #require(await store.thumbnailURL(photoId: photoId)))
        try Data("x".utf8).write(to: root.appendingPathComponent("originals/stray.bin"))
        let report = await store.integrityReport()
        #expect(report.hashMismatches == [photoId])
        #expect(report.missingThumbnails == [photoId])
        #expect(report.orphanFiles == ["originals/stray.bin"])
        #expect(!report.isClean)
        #expect(try await store.verifyOriginal(photoId: photoId) == false)
        await #expect(throws: StoreError.unknownPhoto) { try await store.verifyOriginal(photoId: "nope") }

        let reopened = LibraryStore(root: root, catalog: catalog)
        try await reopened.load()
        #expect(await reopened.integrityReport().orphanFiles.isEmpty)
    }
}
