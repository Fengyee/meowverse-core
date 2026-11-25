import Foundation
import Synchronization
import Testing
@testable import MeowverseCore

/// Audit round 20, M13: rotation of this device's iCloud Drive backups under a clock that jumps
/// back, uploads that catch up later, and how a failure is named. Fake clock (`now:`) and a fake
/// upload state; no real iCloud.
struct CloudBackupRetentionTests {
    let fm = FileManager.default
    let catalog: FurnitureCatalog
    let chairAt44 = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2)
    let device = "0123456789ab"
    let day: TimeInterval = 24 * 60 * 60
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

    private func settings() -> CloudBackupSettings {
        var settings = CloudBackupSettings()
        settings.enabled = true
        settings.account = FolderBackupDestination.defaultAccount
        return settings
    }

    /// One trigger, folded into the settings as the app does; the product's keep count of one.
    @discardableResult
    private func run(_ store: LibraryStore, _ destination: any BackupDestination, _ settings: inout CloudBackupSettings,
                     trigger: CloudBackupPolicy.Trigger, now: Date) async throws -> CloudBackupEngine.Outcome {
        let context = CloudBackupEngine.Context(deviceID: device, deviceKind: "iPhone", appVersion: "9.9",
                                                workDirectory: TestSupport.tempDir(), catalog: catalog)
        let outcome = try await CloudBackupEngine.backUpIfNeeded(
            store: store, destination: destination, settings: settings, trigger: trigger, context: context, now: now)
        if case .completed(let record) = outcome { settings.lastSuccess = record }
        return outcome
    }

    private func edit(_ store: LibraryStore, _ name: String) async throws {
        _ = try await store.rename(instanceId: (await store.snapshot()).items[0].instanceId, displayName: name)
    }

    private func archives(_ folder: URL) -> Set<String> {
        Set(((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".zip") })
    }

    // MARK: B24-02

    /// The clock went back after a backup was written: the next backup's name sorts older than the
    /// one before it. The backup just written and verified is not rotated out in the same run.
    @Test func aBackupWrittenAfterTheClockWentBackIsNotPrunedAtOnce() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        let destination = FolderBackupDestination(folder: folder)
        var settings = settings()
        guard case .completed(let future) = try await run(store, destination, &settings, trigger: .manual, now: t0 + 10 * day) else {
            Issue.record("first backup did not run"); return
        }
        try await edit(store, "改过的椅子")
        guard case .completed(let written) = try await run(store, destination, &settings, trigger: .manual, now: t0) else {
            Issue.record("second backup did not run"); return
        }
        #expect(archives(folder).contains(written.archiveName), "the backup just written is still there")
        #expect(archives(folder).contains(future.archiveName), "and the one before it stays until it is safely superseded")
        let listing = try CloudBackupCatalog.load(from: destination, deviceID: device)
        #expect(listing.entries.first { $0.name.archiveName == written.archiveName }?.condition == .verified)
        // An unchanged library is not written again, and rotation still keeps the last success.
        #expect(try await run(store, destination, &settings, trigger: .automatic, now: t0 + 2 * day) == .skipped(.unchanged))
        #expect(archives(folder).contains(written.archiveName))
    }

    @Test func pruneNeverListsAProtectedBackup() {
        func entry(_ date: Date, revision: Int) -> CloudBackupEntry {
            CloudBackupEntry(name: CloudBackupName(deviceID: device, createdAt: date, revision: revision)!, info: nil, byteSize: 1,
                             isDownloaded: true, upload: .notApplicable, condition: .verified, isFromThisDevice: true)
        }
        let future = entry(t0 + 10 * day, revision: 1), written = entry(t0, revision: 2)
        #expect(CloudBackupPolicy.prune([future, written], keep: 1) == [written.name.archiveName, written.name.infoName])
        #expect(CloudBackupPolicy.prune([future, written], keep: 1, protecting: [written.name.archiveName]).isEmpty)
    }

    // MARK: B24-09

    /// The last backup was still uploading when it was written, so the one before it (in iCloud)
    /// stayed. Once the upload has caught up and nothing in the library changed, the older one is
    /// rotated out instead of staying for ever.
    @Test func anOlderBackupIsRotatedOutOnceTheUploadCaughtUp() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        let destination = UploadStateDestination(base: FolderBackupDestination(folder: folder))
        var settings = settings()
        guard case .completed(let first) = try await run(store, destination, &settings, trigger: .manual, now: t0) else {
            Issue.record("first backup did not run"); return
        }
        destination.setUploaded(first.archiveName)
        try await edit(store, "改过的椅子")
        guard case .completed(let second) = try await run(store, destination, &settings, trigger: .manual, now: t0 + day) else {
            Issue.record("second backup did not run"); return
        }
        #expect(archives(folder) == [first.archiveName, second.archiveName], "the uploaded one stays while the new one uploads")

        destination.setUploaded(second.archiveName)
        #expect(try await run(store, destination, &settings, trigger: .automatic, now: t0 + 3 * day) == .skipped(.unchanged))
        #expect(archives(folder) == [second.archiveName])
        let firstName = try #require(CloudBackupName(archiveName: first.archiveName))
        #expect(!fm.fileExists(atPath: folder.appendingPathComponent(firstName.infoName).path))
    }

    // MARK: B24-10

    /// iCloud being full is named as iCloud being full, not as the phone's storage.
    @Test func failureCodesTellICloudQuotaFromDeviceSpace() {
        #expect(CloudBackupEngine.failureCode(CloudBackupError.quotaExceeded) == "quota")
        #expect(CloudBackupEngine.failureCode(CloudBackupError.io("space")) == "space")
        #expect(CloudBackupEngine.failureCode(BackupError.tooLarge) == "tooLarge")
        #expect(CloudBackupEngine.failureCode(BackupError.libraryDamaged(2)) == "libraryDamaged")
        #expect(CloudBackupEngine.failureCode(CloudBackupError.unavailable(.signedOut)) == "signedOut")
        #expect(CloudBackupEngine.failureCode(CloudBackupError.unavailable(.containerUnavailable)) == "containerUnavailable")
        #expect(CloudBackupEngine.failureCode(CloudBackupError.verificationFailed("x")) == "verification")
        #expect(CloudBackupEngine.failureCode(CloudBackupError.io("place")) == "other")
    }
}

/// A plain folder whose files report an upload state, as iCloud Drive's do: pending until told.
final class UploadStateDestination: BackupDestination {
    let base: FolderBackupDestination
    private let uploaded = Mutex<Set<String>>([])

    init(base: FolderBackupDestination) {
        self.base = base
    }

    func setUploaded(_ name: String) {
        uploaded.withLock { _ = $0.insert(name) }
    }

    func availability() -> CloudAvailability { base.availability() }
    func accountFingerprint() -> String? { base.accountFingerprint() }
    func list() throws -> [CloudBackupFile] {
        let done = uploaded.withLock { $0 }
        return try base.list().map { file in
            var file = file
            file.upload = done.contains(file.name) ? .uploaded : .pending
            return file
        }
    }
    func readSmallFile(_ name: String) throws -> Data { try base.readSmallFile(name) }
    func place(_ local: URL, as name: String) throws { try base.place(local, as: name) }
    func writeSmallFile(_ data: Data, as name: String) throws { try base.writeSmallFile(data, as: name) }
    func remove(_ name: String) throws { try base.remove(name) }
    func localURL(for name: String) -> URL? { base.localURL(for: name) }
    func download(_ name: String, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        try await base.download(name, progress: progress)
    }
}
