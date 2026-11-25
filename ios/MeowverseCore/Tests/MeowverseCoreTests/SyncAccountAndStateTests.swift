import Foundation
import Synchronization
import Testing
@testable import MeowverseCore

/// Audit 2026-11-24, M06/M09 (docs/ICLOUD_SYNC.md §6, §7, §10, §11): sync's own file that
/// cannot be read is not a first sync, a newer version's file is left alone, the account the
/// home is bound to survives every start over, the backup rotation never overwrites the only
/// good copy, and a cycle from before a restore writes nothing into the new library.
@Suite(.timeLimit(.minutes(1))) struct SyncAccountAndStateTests {
    let clock = SyncTestClock()

    /// Two iCloud accounts that share nothing, and the one signed in now. Every write each
    /// account received is counted, so "nothing went into B" is checked call by call.
    final class TwoAccounts: Sendable {
        let a = SyncMemoryCloud(), b = SyncMemoryCloud()
        private let signedIn = Mutex("A")
        private let writes = Mutex<[String: Int]>([:])

        init() async {
            await a.setAccount("account-A")
            await b.setAccount("account-B")
        }

        func signIn(_ name: String) { signedIn.withLock { $0 = name } }
        var current: String { signedIn.withLock { $0 } }
        func cloud(_ name: String) -> SyncMemoryCloud { name == "A" ? a : b }
        func noteWrite() { let name = current; writes.withLock { $0[name, default: 0] += 1 } }
        func writesInto(_ name: String) -> Int { writes.withLock { $0[name] ?? 0 } }
    }

    /// Holds the next armed download until released (a cycle out on the network for a photo).
    actor DownloadGate {
        private var armed = false, arrived = false
        private var held: CheckedContinuation<Void, Never>?
        private var waiter: CheckedContinuation<Void, Never>?

        func arm() { armed = true; arrived = false }
        func pass() async {
            guard armed else { return }
            armed = false
            arrived = true
            waiter?.resume()
            waiter = nil
            await withCheckedContinuation { held = $0 }
        }
        func waitUntilHeld() async {
            if arrived { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { held?.resume(); held = nil }
    }

    struct Transport: SyncTransport {
        let accounts: TwoAccounts
        let device: String
        let downloads: DownloadGate

        private var inner: SyncMemoryEndpoint { accounts.cloud(accounts.current).endpoint(device) }

        func accountKey() async throws -> String { try await inner.accountKey() }
        func fetchChanges(since token: SyncToken?) async throws -> SyncFetchResult { try await inner.fetchChanges(since: token) }
        func save(_ records: [SyncSave]) async throws -> [SyncSaveResult] {
            accounts.noteWrite()
            return try await inner.save(records)
        }
        func hasFile(sha256: String) async throws -> Bool { try await inner.hasFile(sha256: sha256) }
        func uploadFile(sha256: String, data: Data) async throws {
            accounts.noteWrite()
            try await inner.uploadFile(sha256: sha256, data: data)
        }
        func downloadFile(sha256: String) async throws -> Data {
            await downloads.pass()
            return try await inner.downloadFile(sha256: sha256)
        }
        func deleteFile(sha256: String) async throws {
            accounts.noteWrite()
            try await inner.deleteFile(sha256: sha256)
        }
    }

    struct Device {
        let root: URL
        let store: LibraryStore
        let session: SyncSession
        let downloads = DownloadGate()

        init(_ name: String, _ accounts: TwoAccounts, clock: SyncTestClock, root: URL? = nil) async throws {
            self.root = root ?? TestSupport.tempDir().appendingPathComponent("Library-\(name)", isDirectory: true)
            let catalog = try TestSupport.catalog()
            store = LibraryStore(root: self.root, catalog: catalog)
            try await store.load()
            session = SyncSession(store: store, transport: Transport(accounts: accounts, device: name, downloads: downloads),
                                  catalog: catalog, deviceID: "dev\(name)", now: clock.reader())
        }

        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
        func bytes(_ name: String) -> Data? { try? Data(contentsOf: url(name)) }
    }

    /// A library with a photo on a piece, synced into account A.
    func syncedInA(_ accounts: TwoAccounts) async throws -> Device {
        let a = try await Device("A", accounts, clock: clock)
        let piece = try await a.store.addFurniture(placement: SyncCheck.spot(1), displayName: "Lamp")
        _ = try await a.store.addSource(draft: try TestSupport.draft(seed: 61), toInstance: piece.instanceId, decision: .manual)
        let report = try await a.session.sync()
        #expect(report.problem == nil && report.sent > 0)
        #expect(try await a.session.deviceState()?.account == "account-A")
        return a
    }

    func expectNothingInB(_ accounts: TwoAccounts, sourceLocation: SourceLocation = #_sourceLocation) async {
        #expect(accounts.writesInto("B") == 0, "a write went into account B", sourceLocation: sourceLocation)
        #expect(await accounts.b.allEnvelopes.isEmpty, sourceLocation: sourceLocation)
        #expect(await accounts.b.fileHashes.isEmpty, sourceLocation: sourceLocation)
    }

    // MARK: AA24-01: both copies of sync's file unreadable

    /// Sync's file and its backup are there but cannot be read, and another account is signed
    /// in. That used to be a first sync, whose new state took whichever account answered: the
    /// home went into account B. Now the cycle stops and says the file is unreadable, before
    /// asking for the account, so the app can check the account it knows (its marker) first.
    @Test func anUnreadableSyncFileIsNotAFirstSyncInAnotherAccount() async throws {
        let accounts = await TwoAccounts()
        let a = try await syncedInA(accounts)
        for name in [LibraryStore.syncStateFile, LibraryStore.syncStateBackupFile] {
            try Data("{ damaged".utf8).write(to: a.url(name))
        }
        accounts.signIn("B")
        await #expect(throws: SyncStateError.unreadable) { try await a.session.sync() }
        await expectNothingInB(accounts)
        #expect(a.bytes(LibraryStore.syncStateFile) == Data("{ damaged".utf8), "the damaged file is left as it was")

        // The app's fresh start passes the account its marker holds: the new state is bound to
        // it, so the next cycle in B stops for the user, and the damaged copies are kept aside.
        try await a.session.startOver(account: "account-A")
        let report = try await a.session.sync()
        #expect(report.problem == .accountChanged && report.sent == 0)
        await expectNothingInB(accounts)
        #expect(a.bytes(LibraryStore.syncStateFile + ".unreadable") == Data("{ damaged".utf8))
        #expect(a.bytes(LibraryStore.syncStateBackupFile + ".unreadable") == Data("{ damaged".utf8))
        #expect(await a.store.snapshot().photos.count == 1, "the library is untouched")
    }

    /// The same damage in the account the home synced with: starting over merges again as a
    /// first sync, and nothing of the library is lost.
    @Test func anUnreadableSyncFileInTheSameAccountStartsOverAndKeepsTheLibrary() async throws {
        let accounts = await TwoAccounts()
        let a = try await syncedInA(accounts)
        for name in [LibraryStore.syncStateFile, LibraryStore.syncStateBackupFile] {
            try Data("{ damaged".utf8).write(to: a.url(name))
        }
        await #expect(throws: SyncStateError.unreadable) { try await a.session.sync() }
        try await a.session.startOver(account: "account-A")
        let report = try await a.session.sync()
        #expect(report.problem == nil)
        #expect(try await a.session.deviceState()?.account == "account-A")
        let kept = await a.store.snapshot()
        #expect(kept.photos.count == 1 && kept.items.count == 1)
        await expectNothingInB(accounts)
    }

    /// The user's explicit answer, "merge into the account signed in now", binds the home to
    /// that account (not to any account that answers later).
    @Test func agreeingToTheAccountSignedInBindsThatAccount() async throws {
        let accounts = await TwoAccounts()
        let a = try await syncedInA(accounts)
        accounts.signIn("B")
        #expect(try await a.session.sync().problem == .accountChanged)
        try await a.session.startOver(acceptingCurrentAccount: true, account: "account-B")
        #expect(try await a.session.deviceState()?.account == "account-B")
        let report = try await a.session.sync()
        #expect(report.problem == nil && report.sent > 0)
        #expect(accounts.writesInto("B") > 0)
    }

    // MARK: CC24-01: a new install in another account, then a restore

    /// A phone set up from a device backup made in account A, signed in to B: the file it goes
    /// on from stays A's, so the app binds its marker to A, not to B. A restore afterwards (no
    /// sync file in the new library) starting over with that marker's account never merges into B.
    @Test func aNewInstallInAnotherAccountKeepsTheBindingThroughARestore() async throws {
        let accounts = await TwoAccounts()
        let a = try await syncedInA(accounts)
        let copy = TestSupport.tempDir().appendingPathComponent("Library-C", isDirectory: true)
        try FileManager.default.copyItem(at: a.root, to: copy)
        let c = try await Device("C", accounts, clock: clock, root: copy)
        accounts.signIn("B")
        #expect(try await c.session.startOnNewInstall() == .kept)
        #expect(try await c.session.deviceState()?.account == "account-A", "what the app writes into its marker")
        #expect(try await c.session.sync().problem == .accountChanged)

        _ = try await c.store.clearAll()
        #expect(try await c.store.readSyncState() == nil)
        try await c.session.startOver(account: "account-A")
        let report = try await c.session.sync()
        #expect(report.problem == .accountChanged && report.sent == 0)
        await expectNothingInB(accounts)
    }

    // MARK: QA G1 (AA24-01 on a new install): unreadable, and no account to check against

    /// A phone set up from a device backup of a library synced into A (no install marker, so
    /// the app takes the new-install path), both copies of sync's file damaged, B signed in.
    /// "Unreadable" is not "no file": nothing says which account the home synced with, so the
    /// new install neither starts over nor binds itself to B. It throws, writes nothing, and
    /// leaves the damaged copies where they are; only the user's explicit answer (turning sync
    /// on again, which asks first) merges into B (QA review round 20, G1).
    @Test func anUnreadableSyncFileOnANewInstallIsNotAFirstSyncInTheAccountSignedIn() async throws {
        let accounts = await TwoAccounts()
        let a = try await syncedInA(accounts)
        let copy = TestSupport.tempDir().appendingPathComponent("Library-C", isDirectory: true)
        try FileManager.default.copyItem(at: a.root, to: copy)
        for name in [LibraryStore.syncStateFile, LibraryStore.syncStateBackupFile] {
            try Data("{ damaged".utf8).write(to: copy.appendingPathComponent(name))
        }
        let c = try await Device("C", accounts, clock: clock, root: copy)
        accounts.signIn("B")
        await #expect(throws: SyncStateError.unreadable) { try await c.session.startOnNewInstall() }
        // The cycle the app would otherwise run next stops on the same file, before the account.
        await #expect(throws: SyncStateError.unreadable) { try await c.session.sync() }
        await expectNothingInB(accounts)
        #expect(c.bytes(LibraryStore.syncStateFile) == Data("{ damaged".utf8), "the damaged file is left as it was")
        #expect(c.bytes(LibraryStore.syncStateBackupFile) == Data("{ damaged".utf8))
        #expect(await c.store.snapshot().photos.count == 1, "the library is untouched")

        // The user turned sync on again and agreed to merge into the account signed in now.
        try await c.session.startOver(acceptingCurrentAccount: true, account: "account-B")
        #expect(c.bytes(LibraryStore.syncStateFile + ".unreadable") == Data("{ damaged".utf8), "kept aside, not deleted")
        let report = try await c.session.sync()
        #expect(report.problem == nil && report.sent > 0)
        #expect(try await c.session.deviceState()?.account == "account-B")
    }

    /// A new install whose library carries no sync file at all is still a first sync, as before.
    @Test func aNewInstallWithNoSyncFileStillStartsOver() async throws {
        let accounts = await TwoAccounts()
        let c = try await Device("C", accounts, clock: clock)
        _ = try await c.store.addFurniture(placement: SyncCheck.spot(1), displayName: "Lamp")
        accounts.signIn("B")
        #expect(try await c.session.startOnNewInstall() == .startedOver)
        #expect(try await c.session.sync().problem == nil)
        #expect(accounts.writesInto("B") > 0)
    }

    // MARK: QA G1, the narrow path: a new install that opened its library from the fallback copy

    /// A phone set up from a device backup of a library synced into A, whose main state file is
    /// damaged: the library opens from `state.backup.json` (the app then takes the fresh-start
    /// path, not the new-install one, and has no install marker to check). `damageSync` also
    /// damages both copies of sync's file.
    func fellBackCopy(of a: Device, _ accounts: TwoAccounts, damageSync: Bool) async throws -> Device {
        _ = try await a.store.rename(instanceId: try #require(await a.store.snapshot().items.first).instanceId, displayName: "Desk lamp")
        try await a.session.sync()
        let copy = TestSupport.tempDir().appendingPathComponent("Library-C", isDirectory: true)
        try FileManager.default.copyItem(at: a.root, to: copy)
        try Data("{ damaged".utf8).write(to: copy.appendingPathComponent(LibraryStore.stateFile))
        if damageSync {
            for name in [LibraryStore.syncStateFile, LibraryStore.syncStateBackupFile] {
                try Data("{ damaged".utf8).write(to: copy.appendingPathComponent(name))
            }
        }
        let c = try await Device("C", accounts, clock: clock, root: copy)
        #expect(await c.store.recoveredFromBackup, "the library opened from its fallback copy")
        return c
    }

    /// Fell back, both sync files unreadable, B signed in, no marker: the account the fresh
    /// start has is only whoever is signed in, not one checked against what the home synced
    /// with. Starting over used to keep the damaged copies aside, bind B and merge the home
    /// into it. It throws now, writes nothing and leaves the files; the app turns sync off,
    /// whose close keeps the damaged copies aside, and nothing ever reaches B.
    @Test func aFellBackNewInstallWithAnUnreadableSyncFileNeverMergesIntoTheAccountSignedIn() async throws {
        let accounts = await TwoAccounts()
        let a = try await syncedInA(accounts)
        let c = try await fellBackCopy(of: a, accounts, damageSync: true)
        accounts.signIn("B")
        await #expect(throws: SyncStateError.unreadable) {
            try await c.session.startOver(account: "account-B", accountChecked: false)
        }
        await expectNothingInB(accounts)
        #expect(c.bytes(LibraryStore.syncStateFile) == Data("{ damaged".utf8), "the damaged file is left as it was")
        #expect(c.bytes(LibraryStore.syncStateBackupFile) == Data("{ damaged".utf8))

        // Sync turned off: the damaged copies are kept aside, not deleted, and nothing runs.
        try await c.session.close(forgetting: true)
        #expect(c.bytes(LibraryStore.syncStateFile + ".unreadable") == Data("{ damaged".utf8), "kept aside, not deleted")
        #expect(c.bytes(LibraryStore.syncStateBackupFile + ".unreadable") == Data("{ damaged".utf8))
        await #expect(throws: CancellationError.self) { try await c.session.sync() }
        await expectNothingInB(accounts)
        #expect(await c.store.snapshot().photos.count == 1, "the library is untouched")
    }

    /// The same fallback with the account checked (this install's marker names A, A signed in):
    /// starting over goes on as before, keeping the damaged copies aside.
    @Test func aFellBackLibraryWithACheckedAccountStillStartsOver() async throws {
        let accounts = await TwoAccounts()
        let a = try await syncedInA(accounts)
        let c = try await fellBackCopy(of: a, accounts, damageSync: true)
        try await c.session.startOver(account: "account-A", accountChecked: true)
        #expect(c.bytes(LibraryStore.syncStateFile + ".unreadable") == Data("{ damaged".utf8))
        let report = try await c.session.sync()
        #expect(report.problem == nil)
        #expect(try await c.session.deviceState()?.account == "account-A")
        await expectNothingInB(accounts)
    }

    /// Fell back with sync's file readable and no marker: the file names the account, so the
    /// start over goes on whatever was checked. In A it merges; in B the next cycle stops.
    @Test func aFellBackLibraryWithAReadableSyncFileStartsOverUncheckedAndKeepsItsAccount() async throws {
        let accounts = await TwoAccounts()
        let a = try await syncedInA(accounts)
        let c = try await fellBackCopy(of: a, accounts, damageSync: false)
        try await c.session.startOver(account: "account-A", accountChecked: false)
        #expect(try await c.session.deviceState()?.account == "account-A")
        #expect(try await c.session.sync().problem == nil)

        let d = try await fellBackCopy(of: a, accounts, damageSync: false)
        accounts.signIn("B")
        try await d.session.startOver(account: "account-B", accountChecked: false)
        #expect(try await d.session.deviceState()?.account == "account-A")
        let report = try await d.session.sync()
        #expect(report.problem == .accountChanged && report.sent == 0)
        await expectNothingInB(accounts)
    }

    // MARK: COMPAT-4: a newer version's file

    func newerVersion(of data: Data) throws -> Data {
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = SyncDeviceState.currentVersion + 1
        return try JSONSerialization.data(withJSONObject: json)
    }

    /// A newer version wrote sync's file (this build was installed over it): this build does not
    /// sync, start over or rebase, and leaves the file as it is, whatever the older backup says.
    @Test func aNewerVersionsSyncFileIsNeitherAFirstSyncNorOverwritten() async throws {
        let accounts = await TwoAccounts()
        let a = try await syncedInA(accounts)
        let newer = try newerVersion(of: try #require(a.bytes(LibraryStore.syncStateFile)))
        try newer.write(to: a.url(LibraryStore.syncStateFile))
        let backup = a.bytes(LibraryStore.syncStateBackupFile)
        #expect(backup != nil)

        await #expect(throws: SyncStateError.newerVersion) { try await a.session.sync() }
        await #expect(throws: SyncStateError.newerVersion) { try await a.session.startOver() }
        await #expect(throws: SyncStateError.newerVersion) { try await a.session.startOnNewInstall() }
        await #expect(throws: SyncStateError.newerVersion) { try await a.session.close(forgetting: true) }
        #expect(a.bytes(LibraryStore.syncStateFile) == newer)
        #expect(a.bytes(LibraryStore.syncStateBackupFile) == backup)
    }

    /// Opening the library from its backup rebases sync's file; a newer version's file is not
    /// rewritten from the older backup copy.
    @Test func aRebaseDoesNotOverwriteANewerVersionsFile() async throws {
        let accounts = await TwoAccounts()
        let a = try await syncedInA(accounts)
        _ = try await a.store.rename(instanceId: try #require(await a.store.snapshot().items.first).instanceId, displayName: "Desk lamp")
        try await a.session.sync()
        let newer = try newerVersion(of: try #require(a.bytes(LibraryStore.syncStateFile)))
        try newer.write(to: a.url(LibraryStore.syncStateFile))
        try Data("{ damaged".utf8).write(to: a.url(LibraryStore.stateFile))
        let reopened = LibraryStore(root: a.root, catalog: try TestSupport.catalog())
        _ = try await reopened.load()
        #expect(await reopened.recoveredFromBackup)
        #expect(a.bytes(LibraryStore.syncStateFile) == newer)
    }

    // MARK: AA24-02: the rotation keeps the only good copy

    /// Sync's file is damaged and its backup good: sync reads the backup. Its next write must
    /// not first turn the damaged file into the backup: until the new file has its name, the
    /// good copy is the only one there is.
    @Test func writingAfterFallingBackKeepsTheGoodBackup() async throws {
        let accounts = await TwoAccounts()
        let a = try await syncedInA(accounts)
        let good = try #require(a.bytes(LibraryStore.syncStateBackupFile))
        #expect(SyncDeviceState.decode(good) != nil)
        try Data("{ damaged".utf8).write(to: a.url(LibraryStore.syncStateFile))
        _ = try await a.store.rename(instanceId: try #require(await a.store.snapshot().items.first).instanceId, displayName: "Desk lamp")
        try await a.session.captureLocalEdits()
        let backup = try #require(a.bytes(LibraryStore.syncStateBackupFile))
        #expect(SyncDeviceState.decode(backup) != nil, "the damaged file replaced the only good copy")
        #expect(SyncDeviceState.decode(try #require(a.bytes(LibraryStore.syncStateFile))) != nil)
    }

    // MARK: D24-05: a damaged cursor

    @Test func aNegativeRepairCursorIsReadAsTheStart() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: try SyncDeviceState(device: "d").encoded()) as? [String: Any])
        json["repairCursor"] = -7
        let read = try #require(SyncDeviceState.decode(try JSONSerialization.data(withJSONObject: json)))
        #expect(read.repairCursor == 0)
    }

    /// A cursor that is negative anyway (or larger than the photos) still checks the photos
    /// in turn: the cycle runs, no index out of range.
    @Test func aCycleWithANegativeCursorRuns() async throws {
        let accounts = await TwoAccounts()
        let a = try await syncedInA(accounts)
        let file = try #require(a.bytes(LibraryStore.syncStateFile))
        var json = try #require(try JSONSerialization.jsonObject(with: file) as? [String: Any])
        json["repairCursor"] = -3
        try JSONSerialization.data(withJSONObject: json).write(to: a.url(LibraryStore.syncStateFile))
        #expect(try await a.session.sync().problem == nil)
    }

    // MARK: DD24-02: a download from before a restore

    /// A cycle out on the network for a photo's file when the library is restored (cleared
    /// here): the download that comes back afterwards is not staged in the new library.
    @Test func aDownloadThatReturnsAfterARestoreIsNotStagedInTheNewLibrary() async throws {
        let accounts = await TwoAccounts()
        let a = try await syncedInA(accounts)
        let b = try await Device("B", accounts, clock: clock)
        // B's first sync goes out for A's photo.
        await b.downloads.arm()
        let cycle = Task { try await b.session.sync() }
        await b.downloads.waitUntilHeld()
        _ = try await b.store.clearAll()
        await b.downloads.release()
        _ = try? await cycle.value
        let incoming = (try? FileManager.default.contentsOfDirectory(atPath: b.url("sync-incoming").path)) ?? []
        #expect(incoming.isEmpty, "the old cycle staged \(incoming.count) files in the restored library")
        #expect(await b.store.snapshot().photos.isEmpty)
        _ = a
    }

    // MARK: GG24-01: the engine's state and the mirror

    private struct RemoveFailure: Error {}

    private final class Disk: @unchecked Sendable {
        var removeFails = false
        func write(_ data: Data, _ url: URL) throws { try data.write(to: url, options: .atomic) }
        func remove(_ url: URL) throws {
            if removeFails { throw RemoveFailure() }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func files(_ folder: URL, _ disk: Disk) -> CloudSyncMirrorFiles {
        CloudSyncMirrorFiles(folder: folder, write: { data, url in try disk.write(data, url) },
                             remove: { url in try disk.remove(url) })
    }

    /// Another account: the transport drops the engine's state and saves an emptied mirror.
    /// Deleting the state failed (only remembered in memory) and the app ends before the
    /// engine saves a new one: after a relaunch the old token must not go with the new mirror.
    @Test func anEngineStateThatCouldNotBeDeletedIsNeverPairedWithANewMirror() throws {
        let folder = TestSupport.tempDir(), disk = Disk()
        var store = files(folder, disk)
        var mirror = store.load()
        mirror.account = "account-A"
        mirror.record(SyncEnvelope(type: "MVFurniture", name: "a", format: 1, payload: Data([1])), tag: "1", systemFields: nil)
        let savedA = store.saveEngineState(Data("token-A".utf8), mirror: mirror)
        #expect(savedA)

        disk.removeFails = true
        store.dropEngineState()
        mirror.reset(account: "account-B")
        _ = store.save(mirror)

        var relaunched = files(folder, disk)
        let reread = relaunched.load()
        if let state = relaunched.engineState() {
            #expect(reread.epoch != mirror.epoch, "the old engine state was paired with the new mirror")
            #expect(state == Data("token-A".utf8) && reread.account == "account-A")
        }

        // Once the old state can go, the new mirror is written and the engine starts afresh.
        disk.removeFails = false
        var again = files(folder, disk)
        _ = again.load()
        again.dropEngineState()
        let savedB = again.save(mirror)
        #expect(savedB)
        var last = files(folder, disk)
        let lastMirror = last.load()
        #expect(lastMirror.epoch == mirror.epoch)
        #expect(last.engineState() == nil)
    }

    /// The normal order still works: state saved with its mirror goes on after a relaunch.
    @Test func anEngineStateSavedWithItsMirrorGoesOnAfterARelaunch() throws {
        let folder = TestSupport.tempDir(), disk = Disk()
        var store = files(folder, disk)
        var mirror = store.load()
        mirror.record(SyncEnvelope(type: "MVFurniture", name: "a", format: 1, payload: Data([1])), tag: "1", systemFields: nil)
        let saved = store.saveEngineState(Data("token-1".utf8), mirror: mirror)
        #expect(saved)
        var relaunched = files(folder, disk)
        let reread = relaunched.load()
        #expect(reread.epoch == mirror.epoch)
        #expect(relaunched.engineState() == Data("token-1".utf8))
    }
}
