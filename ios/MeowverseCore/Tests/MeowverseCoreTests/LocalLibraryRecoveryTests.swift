import Foundation
import Testing
@testable import MeowverseCore

/// Disaster recovery of the local library (audit 2026-11-24, M01): missing, corrupt and
/// unreadable state are three different things, and only the first, on an empty folder,
/// may start an empty library. Small synthetic libraries only.
@Suite struct LocalLibraryRecoveryTests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try TestSupport.catalog() }
    let fm = FileManager.default
    let chairAt44 = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2)
    let stoolAt00 = Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1)

    /// Two committed items, so the primary holds both and the backup only the first.
    func seeded(_ root: URL) async throws -> LibraryStore {
        let store = LibraryStore(root: root, catalog: catalog)
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 2000), placement: chairAt44,
                                               displayName: "a", decision: .manual)
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 2001), placement: stoolAt00,
                                               displayName: "b", decision: .manual)
        return store
    }

    func setReadable(_ file: URL, _ readable: Bool) throws {
        try fm.setAttributes([.posixPermissions: readable ? 0o644 : 0o000], ofItemAtPath: file.path)
    }

    func isIO(_ error: any Error) -> Bool {
        if case StoreError.io = error { return true }
        return false
    }

    // MARK: - T24-01: missing state with surviving media

    @Test func missingSnapshotsNeverEraseSurvivingMedia() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let seed = try await seeded(root)
        let paths = await seed.snapshot().photos.flatMap { [$0.originalFile, $0.thumbnailFile] }
        #expect(paths.count == 4)
        let media = paths.map { root.appendingPathComponent($0) }
        let bytes = media.map(TestSupport.bytes)
        try fm.removeItem(at: root.appendingPathComponent(LibraryStore.stateFile))
        try fm.removeItem(at: root.appendingPathComponent(LibraryStore.backupFile))
        let listing = TestSupport.listing(root)

        let reopened = LibraryStore(root: root, catalog: catalog)
        await #expect(throws: StoreError.corruptState) { try await reopened.load() }
        // A failed open must not turn the next change into an empty library's save.
        await #expect(throws: StoreError.corruptState) { try await reopened.setCatName("Recovered") }
        #expect(TestSupport.listing(root) == listing)
        #expect(media.map(TestSupport.bytes) == bytes)
        await #expect(throws: StoreError.corruptState) { try await LibraryStore(root: root, catalog: catalog).load() }
        #expect(media.map(TestSupport.bytes) == bytes)
    }

    @Test func onlyAThumbnailLeftStillRequiresRecovery() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let photo = try await store.addPhoto(draft: try TestSupport.draft(seed: 2003))
        for name in [LibraryStore.stateFile, LibraryStore.backupFile, photo.originalFile] {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
        let file = root.appendingPathComponent(photo.thumbnailFile)
        let bytes = TestSupport.bytes(file)
        await #expect(throws: StoreError.corruptState) { try await LibraryStore(root: root, catalog: catalog).load() }
        #expect(TestSupport.bytes(file) == bytes)
    }

    /// A folder from before the new-library marker, with files and no state: kept.
    @Test func filesWithoutStateInAnUnmarkedFolderRequireRecovery() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("originals"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("originals/\(String(repeating: "a", count: 64)).jpeg")
        try Data([9, 9, 9]).write(to: file)
        await #expect(throws: StoreError.corruptState) { try await LibraryStore(root: root, catalog: catalog).load() }
        #expect(TestSupport.bytes(file) == Data([9, 9, 9]))
    }

    /// Control: an empty folder is a new library and works normally; its marker goes at the
    /// first commit, so losing both state files afterwards is recovery, not a new library.
    @Test func aNewLibraryLosesItsMarkerAtTheFirstCommit() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let marker = root.appendingPathComponent(LibraryStore.newLibraryMarker)
        let store = LibraryStore(root: root, catalog: catalog)
        #expect(try await store.load() == .empty)
        #expect(fm.fileExists(atPath: marker.path))
        _ = try await store.addPhoto(draft: try TestSupport.draft(seed: 2002))
        #expect(!fm.fileExists(atPath: marker.path))
        #expect(try await LibraryStore(root: root, catalog: catalog).load().photos.count == 1)
    }

    @Test func aFirstPickerCheckpointAlsoRemovesTheMarker() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        _ = try await store.importPickerPhotos([TestSupport.draft(seed: 2004)])
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(LibraryStore.newLibraryMarker).path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(LibraryStore.stateFile).path), "the journal alone holds it")
        try fm.removeItem(at: root.appending(path: PickerImportJournal.directory))
        await #expect(throws: StoreError.corruptState) { try await LibraryStore(root: root, catalog: catalog).load() }
    }

    // MARK: - Unreadable is unknown, not corrupt

    @Test func anUnreadablePrimaryIsUnknownAndTheOlderBackupDoesNotReplaceIt() async throws {
        let root = TestSupport.tempDir()
        let primary = root.appendingPathComponent(LibraryStore.stateFile)
        defer { try? setReadable(primary, true); try? fm.removeItem(at: root) }
        let expected = try await seeded(root).snapshot()
        try setReadable(primary, false)
        let listing = TestSupport.listing(root)

        let store = LibraryStore(root: root, catalog: catalog)
        do { _ = try await store.load(); Issue.record("an unreadable primary opened") } catch {
            #expect(isIO(error), "unknown, not corrupt: \(error)")
        }
        do { try await store.setCatName("x"); Issue.record("a change was saved over an unreadable primary") } catch {
            #expect(isIO(error))
        }
        #expect(TestSupport.listing(root) == listing)

        try setReadable(primary, true)
        #expect(try await LibraryStore(root: root, catalog: catalog).load() == expected)
    }

    @Test func anUnreadableBackupBehindACorruptPrimaryIsUnknown() async throws {
        let root = TestSupport.tempDir()
        let backup = root.appendingPathComponent(LibraryStore.backupFile)
        defer { try? setReadable(backup, true); try? fm.removeItem(at: root) }
        _ = try await seeded(root)
        try Data("{ torn".utf8).write(to: root.appendingPathComponent(LibraryStore.stateFile))
        try setReadable(backup, false)
        do { _ = try await LibraryStore(root: root, catalog: catalog).load(); Issue.record("opened") } catch {
            #expect(isIO(error), "\(error)")
        }
        try setReadable(backup, true)
        let store = LibraryStore(root: root, catalog: catalog)
        #expect(try await store.load().items.count == 1)
        #expect(await store.recoveredFromBackup)
    }

    // MARK: - T24-03: an unreadable checkpoint

    @Test func anUnreadableCheckpointFailsClosedAndReplaysInFullOnceReadable() async throws {
        let root = TestSupport.tempDir()
        let checkpoint = root.appending(path: PickerImportJournal.directory).appending(path: "00000002.json")
        defer { try? setReadable(checkpoint, true); try? fm.removeItem(at: root) }
        let writer = LibraryStore(root: root, catalog: catalog)
        _ = try await writer.addPhoto(draft: TestSupport.draft(seed: 2010))
        _ = try await writer.importPickerPhotos([TestSupport.draft(seed: 2011)])
        _ = try await writer.importPickerPhotos([TestSupport.draft(seed: 2012)])
        let committed = await writer.snapshot()
        try setReadable(checkpoint, false)
        let parent = root.deletingLastPathComponent()
        let siblings = try fm.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix(root.lastPathComponent) }
        let listing = TestSupport.listing(root)

        let reader = LibraryStore(root: root, catalog: catalog)
        do { _ = try await reader.load(); Issue.record("opened without the checkpoint") } catch {
            #expect(isIO(error), "\(error)")
        }
        #expect(TestSupport.listing(root) == listing)
        #expect(try fm.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix(root.lastPathComponent) } == siblings,
                "no quarantine for a file that is only unreadable")

        try setReadable(checkpoint, true)
        #expect(try await LibraryStore(root: root, catalog: catalog).load() == committed)
    }

    // MARK: - T24-02: retiring the journal

    @Test func aRetiredJournalThatCannotBeRemovedDoesNotBlockLaterWrites() async throws {
        let root = TestSupport.tempDir()
        let folder = root.appending(path: PickerImportJournal.directory)
        // A directory whose contents cannot be removed: the rename succeeds, the cleanup fails.
        let stuck = folder.appending(path: "stuck")
        var retiredStuck: [URL] { ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix(PickerImportJournal.retiredDirectory) }
            .map { root.appending(path: $0).appending(path: "stuck") } }
        defer {
            for dir in retiredStuck + [stuck] { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
            try? fm.removeItem(at: root)
        }
        let store = LibraryStore(root: root, catalog: catalog)
        let id = try await store.addPhoto(draft: TestSupport.draft(seed: 2020)).photoId
        _ = try await store.importPickerPhotos([TestSupport.draft(seed: 2021)])
        try fm.createDirectory(at: stuck, withIntermediateDirectories: false)
        try Data([1]).write(to: stuck.appending(path: "x"))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stuck.path)

        #expect(try await store.setFavorite(photoIds: [id], true) == 1)
        #expect(!fm.fileExists(atPath: folder.path))
        #expect(try await store.setFavorite(photoIds: [id], false) == 1)
        // A new picker group starts a new journal and compacts while the old leftover stays.
        _ = try await store.importPickerPhotos([TestSupport.draft(seed: 2022)])
        await store.finishPickerImport()
        #expect(!fm.fileExists(atPath: folder.path))
        #expect(try await store.setFavorite(photoIds: [id], true) == 1)
        let expected = await store.snapshot()
        #expect(expected.photos.count == 3)
        #expect(try await LibraryStore(root: root, catalog: catalog).load() == expected)
    }

    // MARK: - T24-06: thumbnail repair

    @Test func reimportReplacesACorruptThumbnail() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let draft = try TestSupport.draft(seed: 2030)
        let photoId = try await store.addPhoto(draft: draft).photoId
        let thumbnail = try #require(await store.thumbnailURL(photoId: photoId))
        try Data("rot".utf8).write(to: thumbnail)

        _ = try await store.addPhoto(draft: draft)
        let repaired = try #require(TestSupport.bytes(thumbnail))
        #expect(PhotoIngest.downsampledImage(data: repaired, maxPixel: 16) != nil)
        #expect(!TestSupport.listing(root).contains { $0.hasSuffix("-tmp") }, "no temporary file left")
    }
}
