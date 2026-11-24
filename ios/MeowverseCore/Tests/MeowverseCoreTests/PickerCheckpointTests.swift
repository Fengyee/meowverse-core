import Foundation
import Testing
@testable import MeowverseCore

struct PickerCheckpointTests {
    @Test func importAndFurnitureCheckpointsAreDurableWithoutRewritingTheSnapshot() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try TestSupport.catalog()
        let store = LibraryStore(root: root, catalog: catalog)
        let first = try TestSupport.draft(seed: 1), second = try TestSupport.draft(seed: 2)
        let chair = try await store.commitNewFurniture(draft: first,
            placement: Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2, finish: .sage),
            displayName: "Chair", decision: .manual)
        let file = root.appending(path: LibraryStore.stateFile)
        let initial = try Data(contentsOf: file)
        let results = try await store.importPickerPhotos([first, second, second], to: chair.instanceId)
        #expect(results.map(\.linked) == [false, true, false])
        #expect(results.map(\.inserted) == [false, true, false])
        #expect(try Data(contentsOf: file) == initial)
        let committed = await store.snapshot()
        let reopened = LibraryStore(root: root, catalog: catalog)
        #expect(try await reopened.load() == committed)
        #expect(await reopened.integrityReport().isClean)
        #expect(try Data(contentsOf: file) != initial)
    }

    @Test func committedGroupsSurviveFailedWritesCompactionAndDeletion() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try TestSupport.catalog(), faults = FaultSwitch(nil)
        let store = LibraryStore(root: root, catalog: catalog, fault: faults.handler)
        let first = try TestSupport.draft(seed: 30), second = try TestSupport.draft(seed: 31)
        let id = try await store.importPickerPhotos([first])[0].photo.photoId
        faults.arm(.writeState)
        await #expect(throws: InjectedFault.failed(.writeState)) { try await store.importPickerPhotos([second]) }
        #expect(await store.integrityReport().isClean)
        #expect(await store.snapshot().photos.map(\.photoId) == [id])

        faults.arm(.pickerSnapshotBackupInstalled)
        await #expect(throws: InjectedFault.failed(.pickerSnapshotBackupInstalled)) { try await store.setFavorite(photoIds: [id], true) }
        let recovered = LibraryStore(root: root, catalog: catalog)
        let before = try await recovered.load()
        #expect(before.photos.map(\.photoId) == [id])
        #expect(before.photos.first?.favorite == false)
        #expect(try await recovered.setFavorite(photoIds: [id], true) == 1)
        _ = try await recovered.importPickerPhotos([second])
        try await recovered.deletePhoto(photoId: id)
        try Data([0]).write(to: root.appending(path: LibraryStore.stateFile))
        let afterDeletion = try await LibraryStore(root: root, catalog: catalog).load()
        #expect(afterDeletion.photos.map(\.sha256) == [second.sha256])
        #expect(!TestSupport.listing(root).contains { $0.hasPrefix(PickerImportJournal.directory) })
    }

    @Test func corruptPrimaryAndInterruptedFinalRenameRecoverNewestPhotoAndBackup() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try TestSupport.catalog(), faults = FaultSwitch(nil)
        let store = LibraryStore(root: root, catalog: catalog, fault: faults.handler)
        _ = try await store.addPhoto(draft: TestSupport.draft(seed: 40))
        _ = try await store.importPickerPhotos([TestSupport.draft(seed: 41)])
        let expected = await store.snapshot()
        try Data([0]).write(to: root.appending(path: LibraryStore.stateFile))
        let reader = LibraryStore(root: root, catalog: catalog, fault: faults.handler)
        faults.arm(.pickerSnapshotInstalled)
        #expect(try await reader.load() == expected)
        #expect(TestSupport.listing(root).contains { $0.hasPrefix(PickerImportJournal.directory + "/") })
        _ = try await reader.importPickerPhotos([TestSupport.draft(seed: 42)])
        let next = await reader.snapshot()
        let fresh = LibraryStore(root: root, catalog: catalog)
        #expect(try await fresh.load() == next)
        #expect(await fresh.integrityReport().isClean)
        let parent = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let zip = parent.appending(path: "backup.zip")
        _ = try await fresh.importPickerPhotos([TestSupport.draft(seed: 43)])
        let last = await fresh.snapshot()
        _ = try await fresh.exportBackup(to: zip, appVersion: "test")
        let staged = try BackupArchive.prepare(file: zip, stagingURL: fresh.makeStagingURL(), catalog: catalog)
        #expect(staged.state == last)
        let oldGeneration = await fresh.generation
        _ = try await fresh.clearAll()
        await #expect(throws: CancellationError.self) {
            try await fresh.importPickerPhotos([TestSupport.draft(seed: 44)], generation: oldGeneration)
        }
        #expect(try await LibraryStore(root: root, catalog: catalog).load().photos.isEmpty)
    }

    @Test func checkpointIndexMatchesRebuildIncludingAnEarlierFurnitureOwner() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try TestSupport.catalog()
        let store = LibraryStore(root: root, catalog: catalog)
        let first = try TestSupport.draft(seed: 51), second = try TestSupport.draft(seed: 52)
        func place(_ x: Int) -> Placement { Placement(modelId: "kenney-chair", x: x, z: 4, width: 2, depth: 2, finish: .sage) }
        let chair = try await store.commitNewFurniture(draft: first, placement: place(0), displayName: "1", decision: .manual)
        _ = try await store.commitNewFurniture(draft: second, placement: place(4), displayName: "2", decision: .manual)
        let prior = await store.indexedSnapshot()
        let id = try await store.importPickerPhotos([second], to: chair.instanceId)[0].photo.photoId
        let updated = await store.indexedSnapshot()
        let rebuilt = LibraryIndex(state: updated.state)
        #expect(updated.index.furniture(ofPhoto: id) == rebuilt.furniture(ofPhoto: id))
        #expect(updated.index.photos(ofFurniture: chair.instanceId) == rebuilt.photos(ofFurniture: chair.instanceId))
        #expect(prior.index.linkCount(ofPhoto: id) == 1 && updated.index.linkCount(ofPhoto: id) == 2)
    }

    @Test func cancellationRollsBackOnlyTheCurrentGroup() async throws {
        let root = TestSupport.tempDir(), catalog = try TestSupport.catalog()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = LibraryStore(root: root, catalog: catalog)
        _ = try await initial.importPickerPhotos([TestSupport.draft(seed: 60)])
        await initial.finishPickerImport()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let store = LibraryStore(root: root, catalog: catalog) { step in
            if step == .writeThumbnail {
                didStart.yield(())
                release.wait()
            }
        }
        _ = try await store.load()
        let draft = try TestSupport.draft(seed: 61)
        let child = Task { try await store.importPickerPhotos([draft]) }
        for await _ in started { break }
        let cancelTime = Date()
        child.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await child.value }
        print("PERF07 cancellation_ms=\(-cancelTime.timeIntervalSinceNow * 1000)")
        #expect(await store.integrityReport().isClean)
        #expect(try await LibraryStore(root: root, catalog: catalog).load().photos.count == 1)
        didStart.finish()
    }

    enum CompactionStage: CaseIterable, Sendable {
        case beforeCompaction, backupInstalled, primaryInstalled
    }

    @Test(arguments: CompactionStage.allCases, [false, true])
    func tornTailKeepsTheMostRecentVerifiedSnapshot(stage: CompactionStage, damagePrimary: Bool) async throws {
        let parent = TestSupport.tempDir(), root = parent.appending(path: "library")
        defer { try? FileManager.default.removeItem(at: parent) }
        let catalog = try TestSupport.catalog(), fault = FaultSwitch(nil)
        let store = LibraryStore(root: root, catalog: catalog, fault: fault.handler)
        let chair = try await store.commitNewFurniture(draft: TestSupport.draft(seed: 90),
            placement: Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2, finish: .sage),
            displayName: "Chair", decision: .manual)
        _ = try await store.importPickerPhotos([TestSupport.draft(seed: 91)], to: chair.instanceId)
        let prefix = await store.snapshot()
        _ = try await store.importPickerPhotos([TestSupport.draft(seed: 92)], to: chair.instanceId)
        let full = await store.snapshot()
        if stage != .beforeCompaction {
            fault.arm(stage == .backupInstalled ? .pickerSnapshotBackupInstalled : .pickerSnapshotInstalled)
            await store.finishPickerImport()
        }
        if damagePrimary { try Data([0]).write(to: root.appending(path: LibraryStore.stateFile)) }
        let tail = PickerImportJournal.directory + "/00000002.json"
        try Data([255]).write(to: root.appending(path: tail))
        let files = TestSupport.listing(root)
        let originalBytes = files.map { TestSupport.bytes(root.appending(path: $0)) }

        let reader = LibraryStore(root: root, catalog: catalog)
        let expected = stage == .beforeCompaction ? prefix : full
        let recovered = try await reader.load()
        #expect(recovered.photos.map(\.photoId) == expected.photos.map(\.photoId))
        try #require(recovered == expected)
        #expect(await reader.recoveredFromBackup)
        #expect(await reader.integrityReport().isClean)
        let index = await reader.indexedSnapshot().index
        #expect(index.photos(ofFurniture: chair.instanceId) == expected.photos)
        for photo in expected.photos { #expect(index.linkCount(ofPhoto: photo.photoId) == 1) }
        let archive = try #require(FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("library.damaged-") })
        #expect(TestSupport.listing(archive) == files)
        #expect(files.map { TestSupport.bytes(archive.appending(path: $0)) } == originalBytes)
        #expect(try await LibraryStore(root: root, catalog: catalog).load() == expected)
        #expect(try Data(contentsOf: root.appending(path: LibraryStore.backupFile)) == LibraryStore.encodeState(expected))
        let zip = parent.appending(path: "backup.zip")
        _ = try await reader.exportBackup(to: zip, appVersion: "test")
        let restored = try BackupArchive.prepare(file: zip, stagingURL: reader.makeStagingURL(), catalog: catalog)
        #expect(restored.state == expected)
        _ = try await reader.clearAll()
        #expect(!FileManager.default.fileExists(atPath: archive.path))
    }

    enum LegacyBackup: CaseIterable, Sendable {
        case installed, missingTemp, foreignAtSameRevision, staleHigherRevision
    }

    @Test(arguments: LegacyBackup.allCases)
    func legacyCompactionRequiresBothTheMatchingTempAndJournalLineage(backup: LegacyBackup) async throws {
        let parent = TestSupport.tempDir(), root = parent.appending(path: "library")
        defer { try? FileManager.default.removeItem(at: parent) }
        let catalog = try TestSupport.catalog(), fault = FaultSwitch(nil)
        let writer = LibraryStore(root: root, catalog: catalog, fault: fault.handler)
        _ = try await writer.addPhoto(draft: TestSupport.draft(seed: 94))
        var baseline = await writer.snapshot()
        baseline.revision = LibraryStore.maxRevision - 1
        try LibraryStore.encodeState(baseline).write(to: root.appending(path: LibraryStore.stateFile))

        let store = LibraryStore(root: root, catalog: catalog, fault: fault.handler)
        _ = try await store.importPickerPhotos([TestSupport.draft(seed: 95)])
        let prefix = await store.snapshot()
        _ = try await store.importPickerPhotos([TestSupport.draft(seed: 96)])
        let full = await store.snapshot()
        #expect(full.revision == 1)
        fault.arm(.pickerSnapshotBackupInstalled)
        await store.finishPickerImport()

        let folder = root.appending(path: PickerImportJournal.directory)
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: folder.path) where name.hasPrefix("compaction-") {
            try fm.removeItem(at: folder.appending(path: name))
        }
        let temp = root.appending(path: LibraryStore.tempStateFile)
        switch backup {
        case .installed: break
        case .missingTemp: try fm.removeItem(at: temp)
        case .foreignAtSameRevision, .staleHigherRevision:
            var other = backup == .foreignAtSameRevision ? full : baseline
            other.photos[0].note = "An edit from a different history"
            let bytes = try LibraryStore.encodeState(other)
            try bytes.write(to: root.appending(path: LibraryStore.backupFile))
            try bytes.write(to: temp)
        }
        try Data([0]).write(to: root.appending(path: LibraryStore.stateFile))
        try Data([255]).write(to: folder.appending(path: "00000002.json"))

        let reader = LibraryStore(root: root, catalog: catalog)
        let expected = backup == .installed ? full : prefix
        #expect(try await reader.load() == expected)
        #expect(try await LibraryStore(root: root, catalog: catalog).load() == expected)
    }

    @Test(arguments: [false, true])
    func installedCompactionCanBridgeMissingJournalFiles(appendAfterCompaction: Bool) async throws {
        let parent = TestSupport.tempDir(), root = parent.appending(path: "library")
        defer { try? FileManager.default.removeItem(at: parent) }
        let catalog = try TestSupport.catalog(), fault = FaultSwitch(nil)
        let store = LibraryStore(root: root, catalog: catalog, fault: fault.handler)
        _ = try await store.addPhoto(draft: TestSupport.draft(seed: 111))
        _ = try await store.importPickerPhotos([TestSupport.draft(seed: 112)])
        _ = try await store.importPickerPhotos([TestSupport.draft(seed: 113)])
        fault.arm(.pickerSnapshotBackupInstalled)
        await store.finishPickerImport()
        if appendAfterCompaction { _ = try await store.importPickerPhotos([TestSupport.draft(seed: 114)]) }
        let expected = await store.snapshot()
        let missing = appendAfterCompaction ? "00000001.json" : "00000002.json"
        try FileManager.default.removeItem(at: root.appending(path: PickerImportJournal.directory).appending(path: missing))
        let fresh = LibraryStore(root: root, catalog: catalog)
        #expect(try await fresh.load() == expected)
        #expect(await fresh.recoveredFromBackup)
        #expect(await fresh.integrityReport().isClean)
    }

    enum Damage: CaseIterable, Sendable { case noteByteFlip, falseRevisionMatch }

    @Test(arguments: Damage.allCases, [false, true])
    func exactInstalledBackupSurvivesCorruptButDecodableJournal(damage: Damage, appendAfterSnapshot: Bool) async throws {
        let parent = TestSupport.tempDir(), root = parent.appending(path: "library")
        defer { try? FileManager.default.removeItem(at: parent) }
        let catalog = try TestSupport.catalog(), fault = FaultSwitch(nil)
        let writer = LibraryStore(root: root, catalog: catalog, fault: fault.handler)
        _ = try await writer.addPhoto(draft: TestSupport.draft(seed: 10))
        let baseline = await writer.snapshot()
        _ = try await writer.importPickerPhotos([TestSupport.draft(seed: 11)])
        _ = try await writer.importPickerPhotos([TestSupport.draft(seed: 12)])
        fault.arm(.pickerSnapshotBackupInstalled)
        await writer.finishPickerImport()
        if appendAfterSnapshot {
            _ = try await writer.importPickerPhotos([TestSupport.draft(seed: 13)])
        }
        let committed = await writer.snapshot()
        let file = root.appending(path: PickerImportJournal.directory).appending(path: "00000002.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        switch damage {
        case .falseRevisionMatch:
            object["revision"] = baseline.revision
        case .noteByteFlip:
            var changes = try #require(object["photos"] as? [[String: Any]])
            var photo = try #require(changes[0]["record"] as? [String: Any])
            photo["note"] = "uncommitted note"
            changes[0]["record"] = photo
            object["photos"] = changes
        }
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let damagedBytes = try Data(contentsOf: file)
        let expectedBytes = try committed.photos.map { try Data(contentsOf: root.appending(path: $0.originalFile)) }
        let reader = LibraryStore(root: root, catalog: catalog)
        let reopened = try await reader.load()
        #expect(reopened.photos.map(\.photoId) == committed.photos.map(\.photoId))
        #expect(reopened.photos.map(\.note) == committed.photos.map(\.note))
        #expect(reopened.revision == committed.revision)
        #expect(await reader.recoveredFromBackup)
        let archivedRoot = try #require(FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("library.damaged-") })
        #expect(try Data(contentsOf: archivedRoot.appending(path: PickerImportJournal.directory)
            .appending(path: "00000002.json")) == damagedBytes)
        let retained = committed.photos.map { TestSupport.bytes(root.appending(path: $0.originalFile)) }
        #expect(retained.compactMap { $0 }.count == expectedBytes.count)
        #expect(try await LibraryStore(root: root, catalog: catalog).load() == committed)
    }

    @Test(arguments: [false, true])
    func provenPrimarySurvivesAnOlderOrUnreadableBackup(useOlderBackup: Bool) async throws {
        let parent = TestSupport.tempDir(), root = parent.appending(path: "library")
        defer { try? FileManager.default.removeItem(at: parent) }
        let catalog = try TestSupport.catalog(), fault = FaultSwitch(nil)
        let store = LibraryStore(root: root, catalog: catalog, fault: fault.handler)
        _ = try await store.addPhoto(draft: TestSupport.draft(seed: 15))
        _ = try await store.importPickerPhotos([TestSupport.draft(seed: 16)])
        fault.arm(.pickerSnapshotInstalled)
        await store.finishPickerImport()
        let backup = root.appending(path: LibraryStore.backupFile)
        let older = try Data(contentsOf: backup)
        _ = try await store.importPickerPhotos([TestSupport.draft(seed: 17)])
        let latest = await store.snapshot()
        fault.arm(.pickerSnapshotInstalled)
        await store.finishPickerImport()
        try (useOlderBackup ? older : Data([0])).write(to: backup)
        try Data([255]).write(to: root.appending(path: PickerImportJournal.directory).appending(path: "00000002.json"))

        let fresh = LibraryStore(root: root, catalog: catalog)
        #expect(try await fresh.load() == latest)
        #expect(await fresh.recoveredFromBackup)
        #expect(try await LibraryStore(root: root, catalog: catalog).load() == latest)
    }
}
