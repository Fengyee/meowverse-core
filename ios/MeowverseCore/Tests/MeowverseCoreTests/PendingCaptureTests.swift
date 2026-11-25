import Foundation
import Testing
@testable import MeowverseCore

/// A capture held until it is confirmed (JOURNEY-NEW-4, owner 2026-11-22): kept across a
/// relaunch, never part of the library, its backups or its exports, and gone after clear-all
/// or a restore.
struct PendingCaptureTests {
    private let fm = FileManager.default

    private func store(_ root: URL) throws -> LibraryStore {
        LibraryStore(root: root, catalog: try TestSupport.catalog())
    }

    private func capture(seed: Int, save: PendingCapture.Save = .notWanted) throws -> PendingCapture {
        PendingCapture(data: try TestSupport.draft(seed: seed).data, save: save)
    }

    private func file(_ root: URL) -> URL { root.appendingPathComponent(PendingCapture.fileName) }

    @Test func aHeldCaptureComesBackAfterARelaunchAndTheLibraryStaysAsItWas() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let first = try store(root)
        let before = try await first.load()
        let held = try capture(seed: 1, save: .refused)
        try await first.keepPendingCapture(held)

        let reopened = try store(root)
        let state = try await reopened.load()
        #expect(state == before, "no record, no revision")
        #expect(state.photos.isEmpty)
        #expect(await reopened.pendingCapture() == held)
        #expect(await reopened.integrityReport().isClean)
    }

    @Test func theFileIsExcludedFromDeviceBackups() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = try store(root)
        _ = try await store.load()
        try await store.keepPendingCapture(try capture(seed: 2))
        let values = try file(root).resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(PendingCapture.tempFileName).path))
    }

    @Test func aNewerCaptureReplacesTheOlderAndOnlyItsOwnRemovalDeletesIt() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = try store(root)
        _ = try await store.load()
        let older = try capture(seed: 3), newer = try capture(seed: 4, save: .failed)
        try await store.keepPendingCapture(older)
        try await store.keepPendingCapture(newer)
        #expect(await store.pendingCapture() == newer)

        await store.removePendingCapture(sha256: older.sha256)
        #expect(await store.pendingCapture() == newer, "the older review ending late leaves the newer capture")
        await store.removePendingCapture(sha256: newer.sha256)
        #expect(await store.pendingCapture() == nil)
        #expect(!fm.fileExists(atPath: file(root).path))
    }

    private func kept(_ root: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix(PendingCapture.keptPrefix) }
            .map { root.appendingPathComponent($0) }
    }

    /// Audit E24-04: a file that cannot be offered is not proof the photo is gone. It is set
    /// aside unchanged, never offered, excluded from device backups, and removed only by
    /// clear-all or a restore (owner to decide any other clean-up).
    @Test(arguments: ["garbage", "truncated", "anotherLibrary", "tampered"])
    func aFileThatCannotBeOfferedIsKeptAsideNotDeleted(_ kind: String) async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = try store(root)
        _ = try await store.load()
        let held = try capture(seed: 5)
        let good = try PendingCapture.encode(held, library: root.lastPathComponent)
        let bytes: Data = switch kind {
        case "garbage": Data("not a capture".utf8)
        case "truncated": good.prefix(good.count - 10)
        case "anotherLibrary": try PendingCapture.encode(held, library: "Library-other")
        default: good.prefix(good.count - 1) + Data([good.last! ^ 0xFF])
        }
        try bytes.write(to: file(root))

        #expect(await store.pendingCapture() == nil)
        #expect(!fm.fileExists(atPath: file(root).path))
        let aside = try #require(kept(root).first)
        #expect(kept(root).count == 1)
        #expect(TestSupport.bytes(aside) == bytes)
        #expect(try aside.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(await store.integrityReport().isClean)
        #expect(await (try self.store(root)).pendingCapture() == nil)
        #expect(kept(root).map(TestSupport.bytes) == [bytes])

        try await store.clearAll()
        #expect(kept(root).isEmpty)
    }

    @Test func anUnreadableFileStaysAndIsOfferedOnceReadable() async throws {
        let root = TestSupport.tempDir()
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file(root).path)
            try? fm.removeItem(at: root)
        }
        let store = try store(root)
        _ = try await store.load()
        let held = try capture(seed: 12)
        try await store.keepPendingCapture(held)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file(root).path)

        #expect(await store.pendingCapture() == nil)
        await store.removePendingCapture(sha256: "0")
        #expect(fm.fileExists(atPath: file(root).path))
        #expect(kept(root).isEmpty, "unreadable is not damaged")

        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file(root).path)
        #expect(await store.pendingCapture() == held)
    }

    @Test func aLateRemovalLeavesAFileItCannotMatch() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = try store(root)
        _ = try await store.load()
        try Data("not a capture".utf8).write(to: file(root))
        await store.removePendingCapture(sha256: try capture(seed: 13).sha256)
        #expect(TestSupport.bytes(file(root)) == Data("not a capture".utf8))
    }

    /// Only a readable, matching copy in the library makes the held file redundant.
    @Test func aCaptureWhoseLibraryCopyIsDamagedIsOfferedNotDeleted() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = try store(root)
        _ = try await store.load()
        let draft = try TestSupport.draft(seed: 14)
        let held = PendingCapture(data: draft.data, save: .failed)
        try await store.keepPendingCapture(held)
        let photo = try await store.addPhoto(draft: draft)
        try Data("rot".utf8).write(to: root.appendingPathComponent(photo.originalFile))

        #expect(await store.pendingCapture() == held)
        #expect(fm.fileExists(atPath: file(root).path))
    }

    /// Audit V24-01: a question or an answer from before a restore or clear-all cannot touch
    /// the library that replaced it.
    @Test func callsFromAnotherLibraryGenerationLeaveTheFile() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = try store(root)
        _ = try await store.load()
        let held = try capture(seed: 15)
        try await store.keepPendingCapture(held)
        let stale = UUID()

        #expect(await store.pendingCapture(generation: stale) == nil)
        await store.removePendingCapture(sha256: held.sha256, generation: stale)
        #expect(fm.fileExists(atPath: file(root).path))
        let current = await store.generation
        #expect(await store.pendingCapture(generation: current) == held)
        await store.removePendingCapture(sha256: held.sha256, generation: current)
        #expect(!fm.fileExists(atPath: file(root).path))
    }

    /// The app stopped after the held copy was written in full, before it took its name.
    @Test func aCompleteTempFromAnInterruptedHoldIsOffered() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = try store(root)
        _ = try await store.load()
        let held = try capture(seed: 16, save: .refused)
        let temp = root.appendingPathComponent(PendingCapture.tempFileName)
        try PendingCapture.encode(held, library: root.lastPathComponent).write(to: temp)

        #expect(await store.pendingCapture() == held)
        #expect(!fm.fileExists(atPath: temp.path))
        #expect(try file(root).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    /// Audit W24-02: repairing a damaged picker tail switches in a new library folder; the
    /// held capture (and anything set aside) goes with it, still out of device backups.
    @Test func repairingAPickerTailKeepsTheHeldCapture() async throws {
        let parent = TestSupport.tempDir(), root = parent.appending(path: "library")
        defer { try? fm.removeItem(at: parent) }
        let writer = try store(root)
        _ = try await writer.addPhoto(draft: TestSupport.draft(seed: 17))
        _ = try await writer.importPickerPhotos([TestSupport.draft(seed: 18)])
        _ = try await writer.importPickerPhotos([TestSupport.draft(seed: 19)])
        let held = try capture(seed: 20, save: .failed)
        try await writer.keepPendingCapture(held)
        let aside = root.appendingPathComponent(PendingCapture.keptPrefix + UUID().uuidString)
        try Data("set aside".utf8).write(to: aside)
        try Data([255]).write(to: root.appending(path: PickerImportJournal.directory).appending(path: "00000002.json"))

        let reader = try store(root)
        _ = try await reader.load()
        #expect(await reader.recoveredFromBackup)
        #expect(try fm.contentsOfDirectory(atPath: parent.path).contains { $0.hasPrefix("library.damaged-") })
        #expect(await reader.pendingCapture() == held)
        #expect(try file(root).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(TestSupport.bytes(aside) == Data("set aside".utf8))
        #expect(try aside.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(await (try self.store(root)).pendingCapture() == held)
    }

    @Test func aCaptureTheLibraryAlreadyHasIsNotOfferedAgain() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = try store(root)
        _ = try await store.load()
        let draft = try TestSupport.draft(seed: 6)
        try await store.keepPendingCapture(PendingCapture(data: draft.data, save: .notWanted))
        // Confirmed, and the app stopped before the review's end removed the file.
        _ = try await store.addPhoto(draft: draft)

        #expect(await store.pendingCapture() == nil)
        #expect(!fm.fileExists(atPath: file(root).path))
    }

    @Test func exportsAndBackupsDoNotCarryIt() async throws {
        let parent = TestSupport.tempDir()
        defer { try? fm.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Library")
        let store = try store(root)
        _ = try await store.load()
        _ = try await store.addPhoto(draft: try TestSupport.draft(seed: 7))
        let held = try capture(seed: 8)
        try await store.keepPendingCapture(held)

        let archive = parent.appendingPathComponent("backup.zip")
        _ = try await store.exportBackup(to: archive, appVersion: "test")
        let reader = try ZipReader(fileURL: archive, limits: .backup)
        #expect(!reader.entries.isEmpty)
        #expect(!reader.entries.contains { $0.path.contains("pending") })
        // The image data, past the encoder's headers that every synthetic photo shares.
        let middle = held.data.dropFirst(held.data.count / 2).prefix(256)
        for entry in reader.entries {
            #expect(try reader.extract(entry).range(of: middle) == nil, "\(entry.path) holds the capture's bytes")
        }
    }

    @Test func clearAllDeletesIt() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = try store(root)
        _ = try await store.load()
        try await store.keepPendingCapture(try capture(seed: 9))
        try await store.clearAll()

        #expect(!fm.fileExists(atPath: file(root).path))
        #expect(await store.pendingCapture() == nil)
        #expect(await LibraryStore(root: root, catalog: try TestSupport.catalog()).pendingCapture() == nil)
    }

    /// Restore switches in a new library folder; the capture leaves with the old one.
    @Test func aRestoreDeletesIt() async throws {
        let parent = TestSupport.tempDir()
        defer { try? fm.removeItem(at: parent) }
        let source = try store(parent.appendingPathComponent("Source"))
        _ = try await source.load()
        _ = try await source.addPhoto(draft: try TestSupport.draft(seed: 10))
        let archive = parent.appendingPathComponent("backup.zip")
        _ = try await source.exportBackup(to: archive, appVersion: "test")

        let root = parent.appendingPathComponent("Library")
        let target = try store(root)
        _ = try await target.load()
        try await target.keepPendingCapture(try capture(seed: 11))
        let prepared = try BackupArchive.prepare(file: archive, stagingURL: target.makeStagingURL(), catalog: try TestSupport.catalog())
        let restored = try await target.replaceLibrary(with: prepared)

        #expect(restored.photos.count == 1)
        #expect(!fm.fileExists(atPath: file(root).path))
        #expect(await target.pendingCapture() == nil)
        let leftovers = ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).filter { $0.hasPrefix("Library") && $0 != "Library" }
        #expect(leftovers.isEmpty, "no displaced folder kept the capture: \(leftovers)")
    }

    @Test func onlyACaptureOutsidePhotosIsHeld() {
        #expect(PendingCapture.Save(.saved(assetIdentifier: "a")) == nil)
        for save in [CameraCapture.LibrarySave.notWanted, .refused, .failed] {
            #expect(PendingCapture.Save(save)?.librarySave == save)
        }
    }
}
