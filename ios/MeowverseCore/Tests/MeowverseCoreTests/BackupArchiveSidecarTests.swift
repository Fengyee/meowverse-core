import Foundation
import Testing
@testable import MeowverseCore

/// Audit round 20, M12: what a backup's manifest and its iCloud info file (the sidecar) say must
/// agree with what is really in the archive, and nothing they declare is trusted for arithmetic
/// or for how much is read. One small synthetic archive; no ZIP fuzzing, no large files.
struct BackupArchiveSidecarTests {
    let fm = FileManager.default
    let catalog: FurnitureCatalog
    let chairAt44 = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2)
    let device = "0123456789ab"
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        catalog = try TestSupport.catalog()
    }

    private func seededStore() async throws -> LibraryStore {
        let store = LibraryStore(root: TestSupport.tempDir().appendingPathComponent("Library", isDirectory: true), catalog: catalog)
        _ = try await store.load()
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 1), placement: chairAt44, displayName: "椅子", decision: .manual)
        return store
    }

    private func export(_ store: LibraryStore) async throws -> URL {
        let url = TestSupport.tempDir().appendingPathComponent("backup.zip")
        _ = try await store.exportBackup(to: url, appVersion: "9.9")
        return url
    }

    /// Rewrites an archive with `edit` applied to its files; ZIP checksums are recomputed, so only
    /// the backup's own checks can catch the change.
    private func rewrite(_ url: URL, _ edit: (inout [String: Data]) throws -> Void) throws -> URL {
        let reader = try ZipReader(fileURL: url, limits: .backup)
        var files: [String: Data] = [:]
        for entry in reader.entries { files[entry.path] = try reader.extract(entry) }
        try edit(&files)
        let out = url.deletingLastPathComponent().appendingPathComponent("rewritten-\(UUID().uuidString).zip")
        let writer = try ZipWriter(url: out)
        for path in files.keys.sorted() { try writer.add(path: path, data: files[path]!) }
        try writer.finish()
        return out
    }

    /// Changes the manifest's entry for `path` (or the manifest itself when `path` is nil).
    private func editManifest(_ files: inout [String: Data], path: String? = nil, _ edit: (inout [String: Any]) -> Void) throws {
        var manifest = try #require(try JSONSerialization.jsonObject(with: files["manifest.json"]!) as? [String: Any])
        if let path {
            var entries = try #require(manifest["files"] as? [[String: Any]])
            let index = try #require(entries.firstIndex { $0["path"] as? String == path })
            edit(&entries[index])
            manifest["files"] = entries
        } else {
            edit(&manifest)
        }
        files["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest)
    }

    private func prepare(_ url: URL, _ store: LibraryStore) throws -> PreparedLibrary {
        try BackupArchive.prepare(file: url, stagingURL: store.makeStagingURL(), catalog: catalog)
    }

    // MARK: Manifest against state (R02-002, A24-08)

    /// The original's bytes still match the state, but the manifest's own line for it says another
    /// size or hash: the archive contradicts itself and is refused.
    @Test func aManifestThatMisdescribesAnOriginalIsRefused() async throws {
        let store = try await seededStore()
        let photo = (await store.snapshot()).photos[0]
        let url = try await export(store)
        try prepare(url, store).discard()

        let wrongHash = try rewrite(url) { try editManifest(&$0, path: photo.originalFile) { $0["sha256"] = String(repeating: "a", count: 64) } }
        #expect(throws: BackupError.damaged("manifestFiles")) { try prepare(wrongHash, store) }
        let wrongSize = try rewrite(url) { try editManifest(&$0, path: photo.originalFile) { $0["byteSize"] = photo.byteSize + 1 } }
        #expect(throws: BackupError.damaged("manifestFiles")) { try prepare(wrongSize, store) }
    }

    /// A thumbnail whose manifest size is wrong is not trusted: it is rebuilt from the original,
    /// and the preview says so.
    @Test func aThumbnailWhoseManifestSizeIsWrongIsRebuilt() async throws {
        let store = try await seededStore()
        let photo = (await store.snapshot()).photos[0]
        let url = try await export(store)
        #expect(try prepare(url, store).preview.notes.isEmpty)
        let wrongSize = try rewrite(url) { try editManifest(&$0, path: photo.thumbnailFile) { $0["byteSize"] = 1 } }
        let prepared = try prepare(wrongSize, store)
        defer { prepared.discard() }
        #expect(prepared.preview.notes == [.thumbnailsRebuilt(1)])
    }

    /// The manifest's counts are what a list may show before opening: they must be the state's.
    @Test func aManifestWhoseCountsDisagreeWithTheStateIsRefused() async throws {
        let store = try await seededStore()
        let url = try await export(store)
        let morePhotos = try rewrite(url) { try editManifest(&$0) { $0["photoCount"] = 40 } }
        #expect(throws: BackupError.damaged("manifestCounts")) { try prepare(morePhotos, store) }
        let moreFurniture = try rewrite(url) { try editManifest(&$0) { $0["furnitureCount"] = 7 } }
        #expect(throws: BackupError.damaged("manifestCounts")) { try prepare(moreFurniture, store) }
    }

    // MARK: Sidecar bounds (B24-01, B24-03)

    private func infoJSON(_ name: CloudBackupName, byteSize: String = "1000", photoCount: String = "1") -> Data {
        Data("""
        {"appVersion":"1","archiveName":"\(name.archiveName)","byteSize":\(byteSize),"createdAt":"2027-01-15T08:00:00Z",\
        "deviceID":"\(name.deviceID)","deviceKind":"iPhone","format":"meowverse-cloud-backup-info","furnitureCount":1,\
        "photoCount":\(photoCount),"revision":\(name.revision),"sha256":"\(String(repeating: "0", count: 64))","version":1}
        """.utf8)
    }

    /// Sizes and counts no backup can have are not a usable info file, so nothing later multiplies
    /// or adds them.
    @Test func anInfoWithAnImpossibleSizeOrCountIsRejected() throws {
        let name = try #require(CloudBackupName(deviceID: device, createdAt: t0, revision: 1))
        #expect(CloudBackupInfo.decode(infoJSON(name), for: name) != nil)
        #expect(CloudBackupInfo.decode(infoJSON(name, byteSize: "\(Int.max)"), for: name) == nil)
        #expect(CloudBackupInfo.decode(infoJSON(name, byteSize: "\(ZipLimits.backup.maxArchiveBytes + 1)"), for: name) == nil)
        #expect(CloudBackupInfo.decode(infoJSON(name, photoCount: "\(Int.max)"), for: name) == nil)
    }

    /// The space a restore asks for, and the total a delete names, never overflow.
    @Test func spaceArithmeticOnListedSizesCannotOverflow() {
        #expect(CloudBackupPolicy.restoreSpaceNeeded(byteSize: 100, isDownloaded: true) == 100 + CloudBackupEngine.restoreSpareBytes)
        #expect(CloudBackupPolicy.restoreSpaceNeeded(byteSize: 100, isDownloaded: false) == 200 + CloudBackupEngine.restoreSpareBytes)
        #expect(CloudBackupPolicy.restoreSpaceNeeded(byteSize: Int.max, isDownloaded: false) == Int.max)
        #expect(CloudBackupPolicy.restoreSpaceNeeded(byteSize: -5, isDownloaded: false) == Int.max)
        #expect(CloudBackupPolicy.totalBytes([Int.max, Int.max, nil, 3]) == Int.max)
        #expect(CloudBackupPolicy.totalBytes([1, nil, 2]) == 3)
    }

    /// A small file is read through a cap: more than an info file can be is refused, however large
    /// the file says it is, without reading it whole.
    @Test func smallFilesAreReadThroughACap() throws {
        let folder = TestSupport.tempDir()
        let fits = folder.appendingPathComponent("fits.json")
        try Data(repeating: 0x20, count: CloudBackupInfo.maxBytes).write(to: fits)
        #expect(try CloudBackupInfo.readBounded(at: fits).count == CloudBackupInfo.maxBytes)
        let over = folder.appendingPathComponent("over.json")
        try Data(repeating: 0x20, count: CloudBackupInfo.maxBytes + 1).write(to: over)
        #expect(throws: CloudBackupError.io(CloudBackupInfo.tooLargeCode)) { try CloudBackupInfo.readBounded(at: over) }
        #expect(throws: CloudBackupError.notFound) { try CloudBackupInfo.readBounded(at: folder.appendingPathComponent("gone.json")) }
    }

    // MARK: A bad sidecar does not block clean-up

    /// An info file of this device that is too large to be one is not "still downloading": its
    /// backup is unverified and rotated out like any other leftover, and the bad info goes with it.
    @Test func anOversizedInfoDoesNotKeepAnOldBackupForever() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        let destination = FolderBackupDestination(folder: folder)
        let old = try #require(CloudBackupName(deviceID: device, createdAt: t0 - 9 * 86_400, revision: 1))
        try Data("an old backup".utf8).write(to: folder.appendingPathComponent(old.archiveName))
        try Data(repeating: 0x20, count: CloudBackupInfo.maxBytes + 1).write(to: folder.appendingPathComponent(old.infoName))

        let listing = try CloudBackupCatalog.load(from: destination, deviceID: device)
        #expect(listing.entries.map(\.condition) == [.unverified])
        #expect(listing.orphanInfoNames == [old.infoName])

        var settings = CloudBackupSettings()
        settings.enabled = true
        settings.account = FolderBackupDestination.defaultAccount
        let context = CloudBackupEngine.Context(deviceID: device, deviceKind: "iPhone", appVersion: "9.9",
                                                workDirectory: TestSupport.tempDir(), catalog: catalog)
        guard case .completed(let record) = try await CloudBackupEngine.backUpIfNeeded(
            store: store, destination: destination, settings: settings, trigger: .manual, context: context, now: t0) else {
            Issue.record("expected a backup"); return
        }
        let left = Set(try fm.contentsOfDirectory(atPath: folder.path))
        #expect(left == [record.archiveName, try #require(CloudBackupName(archiveName: record.archiveName)).infoName])
    }

    // MARK: The downloaded file against its sidecar (A24-07)

    /// The file a restore downloaded is checked against its info file before it is opened: another
    /// valid archive under that name does not pass for it.
    @Test func aDownloadedArchiveMustBeTheOneItsInfoDescribes() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        let destination = FolderBackupDestination(folder: folder)
        var settings = CloudBackupSettings()
        settings.enabled = true
        settings.account = FolderBackupDestination.defaultAccount
        let context = CloudBackupEngine.Context(deviceID: device, deviceKind: "iPhone", appVersion: "9.9",
                                                workDirectory: TestSupport.tempDir(), catalog: catalog)
        guard case .completed(let record) = try await CloudBackupEngine.backUpIfNeeded(
            store: store, destination: destination, settings: settings, trigger: .manual, context: context, now: t0) else {
            Issue.record("expected a backup"); return
        }
        let entry = try #require(try CloudBackupCatalog.load(from: destination, deviceID: device).entries.first)
        let info = try #require(entry.info)
        let placed = try #require(destination.localURL(for: record.archiveName))
        #expect(info.describes(fileAt: placed))

        // Another valid backup of a changed library, put in under the same name.
        _ = try await store.rename(instanceId: (await store.snapshot()).items[0].instanceId, displayName: "另一把椅子")
        let other = try await export(store)
        try fm.removeItem(at: placed)
        try fm.copyItem(at: other, to: placed)
        #expect(!info.describes(fileAt: placed))
        #expect(!info.describes(fileAt: folder.appendingPathComponent("missing.zip")))
    }
}
