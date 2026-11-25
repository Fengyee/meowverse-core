import Foundation
import Synchronization
import Testing
@testable import MeowverseCore

/// Audit 2026-11-24 M05 (A24-02, A24-06): a backup belongs to the library it started from. If
/// that library is cleared or replaced while the backup runs, the old library is not published
/// into iCloud Drive afterwards. Each stage is held by a gate, one operation at a time.
struct DriveBackupOwnershipTests {
    let catalog: FurnitureCatalog
    let device = "0123456789ab"
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let alice = CloudBackupAccount.fingerprint(token: Data("ownership-token".utf8))

    init() throws {
        catalog = try TestSupport.catalog()
    }

    private func seededStore() async throws -> LibraryStore {
        let store = LibraryStore(root: TestSupport.tempDir().appendingPathComponent("Library", isDirectory: true), catalog: catalog)
        _ = try await store.load()
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 1),
                                               placement: Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2),
                                               displayName: "窗边的椅子", decision: .manual)
        return store
    }

    private func files(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// The library is cleared while the engine waits at account question `stage` (3: before the
    /// move in, 4: before the info file). Nothing of the old library is left counting as a
    /// backup, and no archive of it stays in iCloud Drive.
    @Test(arguments: [3, 4])
    func aLibraryClearedDuringTheBackupIsNotPublished(stage: Int) async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        let gate = GatedAccountDestination(base: FolderBackupDestination(folder: folder, account: alice), holdAt: stage)
        var settings = CloudBackupSettings()
        settings.enabled = true
        settings.account = alice
        let context = CloudBackupEngine.Context(deviceID: device, deviceKind: "iPhone", appVersion: "9.9",
                                                workDirectory: TestSupport.tempDir(), catalog: catalog)
        let frozen = settings
        let backup = Task {
            try await CloudBackupEngine.backUpIfNeeded(store: store, destination: gate, settings: frozen, trigger: .manual,
                                                       context: context, now: t0)
        }
        await gate.reached()
        try await store.clearAll()
        gate.release()
        let result = await backup.result
        if case .success(.completed) = result { Issue.record("stage \(stage): the cleared library was published") }
        #expect(!files(folder).contains { $0.hasSuffix(".zip") }, "stage \(stage): \(files(folder))")
        #expect(!files(folder).contains { $0.hasSuffix(".json") })
    }

    /// Cleared while held before the move in: the old library's archive never goes into iCloud
    /// Drive at all, not even for a moment before being taken out again (a crash in between
    /// would leave it there). The final state alone cannot tell this apart from the later
    /// check before the info file; the moves the destination saw can. QA review round 20,
    /// WEAK-TEST 2.
    @Test func aLibraryClearedBeforeTheMoveInIsNeverMovedIn() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        let gate = GatedAccountDestination(base: FolderBackupDestination(folder: folder, account: alice), holdAt: 3)
        var settings = CloudBackupSettings()
        settings.enabled = true
        settings.account = alice
        let context = CloudBackupEngine.Context(deviceID: device, deviceKind: "iPhone", appVersion: "9.9",
                                                workDirectory: TestSupport.tempDir(), catalog: catalog)
        let frozen = settings
        let backup = Task {
            try await CloudBackupEngine.backUpIfNeeded(store: store, destination: gate, settings: frozen, trigger: .manual,
                                                       context: context, now: t0)
        }
        await gate.reached()
        try await store.clearAll()
        gate.release()
        _ = await backup.result
        #expect(gate.placed.isEmpty, "the cleared library was moved into iCloud Drive: \(gate.placed)")
        #expect(gate.removed.isEmpty)
        #expect(files(folder).isEmpty)
    }

    /// The control: nothing changes while held, and the backup completes.
    @Test func aHeldBackupOfAnUnchangedLibraryCompletes() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        let gate = GatedAccountDestination(base: FolderBackupDestination(folder: folder, account: alice), holdAt: 3)
        var settings = CloudBackupSettings()
        settings.enabled = true
        settings.account = alice
        let context = CloudBackupEngine.Context(deviceID: device, deviceKind: "iPhone", appVersion: "9.9",
                                                workDirectory: TestSupport.tempDir(), catalog: catalog)
        let frozen = settings
        let backup = Task {
            try await CloudBackupEngine.backUpIfNeeded(store: store, destination: gate, settings: frozen, trigger: .manual,
                                                       context: context, now: t0)
        }
        await gate.reached()
        gate.release()
        guard case .completed = try await backup.value else { Issue.record("completes"); return }
        #expect(files(folder).count == 2)
    }

    // MARK: A24-06 a download that stops moving

    @Test func aDownloadWithoutProgressIsStalledAfterTheLimit() {
        let limit = CloudDownloadWatch.stallLimit
        var watch = CloudDownloadWatch(start: t0)
        #expect(!watch.isStalled(at: t0 + limit - 1))
        #expect(watch.isStalled(at: t0 + limit))
        // An unknown amount is not progress.
        watch.note(nil, at: t0 + 10)
        #expect(watch.isStalled(at: t0 + limit))
        // Any new amount is; the same amount again is not.
        watch.note(0.2, at: t0 + 100)
        #expect(!watch.isStalled(at: t0 + 100 + limit - 1))
        watch.note(0.2, at: t0 + 200)
        #expect(watch.isStalled(at: t0 + 100 + limit))
        watch.note(0.3, at: t0 + 300)
        #expect(!watch.isStalled(at: t0 + 300 + limit - 1))
        #expect(limit >= 60, "slow networks still move within a minute")
    }
}

/// Holds the engine at the `holdAt`-th account question until `release()`: a gate for one
/// stage of one backup.
final class GatedAccountDestination: BackupDestination {
    let base: FolderBackupDestination
    let holdAt: Int
    private let asked = Mutex(0)
    private let arrived = DispatchSemaphore(value: 0)
    private let open = DispatchSemaphore(value: 0)
    private let calls = Mutex<(placed: [String], removed: [String])>(([], []))

    /// Every name moved in, and every name removed, in order.
    var placed: [String] { calls.withLock { $0.placed } }
    var removed: [String] { calls.withLock { $0.removed } }

    init(base: FolderBackupDestination, holdAt: Int) {
        self.base = base
        self.holdAt = holdAt
    }

    /// Waits until the engine is held.
    func reached() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.arrived.wait()
                continuation.resume()
            }
        }
    }

    func release() { open.signal() }

    func availability() -> CloudAvailability { base.availability() }
    func accountFingerprint() -> String? {
        let count = asked.withLock { value -> Int in
            value += 1
            return value
        }
        if count == holdAt {
            arrived.signal()
            open.wait()
        }
        return base.accountFingerprint()
    }
    func list() throws -> [CloudBackupFile] { try base.list() }
    func readSmallFile(_ name: String) throws -> Data { try base.readSmallFile(name) }
    func place(_ local: URL, as name: String) throws {
        calls.withLock { $0.placed.append(name) }
        try base.place(local, as: name)
    }
    func writeSmallFile(_ data: Data, as name: String) throws { try base.writeSmallFile(data, as: name) }
    func remove(_ name: String) throws {
        calls.withLock { $0.removed.append(name) }
        try base.remove(name)
    }
    func localURL(for name: String) -> URL? { base.localURL(for: name) }
    func download(_ name: String, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        try await base.download(name, progress: progress)
    }
}
