import Foundation
import Synchronization
import Testing
@testable import MeowverseCore

/// Audit 2026-11-24 M04 (A24-01, A24-03, B24-05): everything that lists or deletes in iCloud
/// Drive stays in the one account it was confirmed for, and stops when that account is gone.
/// Two independent fake accounts, each with its own folder: every call reaches the folder of
/// whoever is signed in at that moment, as the real container does.
struct DriveBackupLeaseTests {
    let catalog: FurnitureCatalog
    let device = "0123456789ab"
    let day: TimeInterval = 24 * 60 * 60
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let alice = CloudBackupAccount.fingerprint(token: Data("lease-token-of-the-first-account".utf8))
    let bob = CloudBackupAccount.fingerprint(token: Data("lease-token-of-the-second-account".utf8))

    init() throws {
        catalog = try TestSupport.catalog()
    }

    private func seededStore() async throws -> LibraryStore {
        let store = LibraryStore(root: TestSupport.tempDir().appendingPathComponent("Library", isDirectory: true), catalog: catalog)
        _ = try await store.load()
        try await add(store, seed: 1, x: 4)
        return store
    }

    private func add(_ store: LibraryStore, seed: Int, x: Int) async throws {
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: seed),
                                               placement: Placement(modelId: "kenney-stoolBar", x: x, z: 0, width: 1, depth: 1),
                                               displayName: "件\(seed)", decision: .manual)
    }

    private func context(keep: Int = CloudBackupPolicy.keepCount) -> CloudBackupEngine.Context {
        CloudBackupEngine.Context(deviceID: device, deviceKind: "iPhone", appVersion: "9.9", workDirectory: TestSupport.tempDir(),
                                  catalog: catalog, keepCount: keep)
    }

    private func settings(for account: String) -> CloudBackupSettings {
        var settings = CloudBackupSettings()
        settings.enabled = true
        settings.account = account
        return settings
    }

    private func files(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// Two verified backups of this device in `account`'s own folder.
    private func twoBackups(in folder: URL, account: String) async throws -> [CloudBackupName] {
        let store = try await seededStore()
        let plain = FolderBackupDestination(folder: folder, account: account)
        var settings = settings(for: account)
        for (index, now) in [t0, t0 + day].enumerated() {
            if index > 0 { try await add(store, seed: 10 + index, x: index) }
            guard case .completed(let record) = try await CloudBackupEngine.backUpIfNeeded(
                store: store, destination: plain, settings: settings, trigger: .manual, context: context(keep: 2), now: now)
            else { Issue.record("backup \(index)"); return [] }
            settings.lastSuccess = record
        }
        let names = try CloudBackupCatalog.load(from: plain, deviceID: device).entries.map(\.name)
        #expect(names.count == 2)
        return names
    }

    // MARK: A24-01 deleting what the user confirmed

    /// The user confirmed deleting this device's backups in the first account; the account is
    /// switched after the first file went. Nothing is deleted in the second account, and the
    /// delete stops with an error instead of reporting every backup as deleted.
    @Test func deletingStopsWhenTheAccountChangesHalfWay() async throws {
        let aliceFolder = TestSupport.tempDir(), bobFolder = TestSupport.tempDir()
        let shown = try await twoBackups(in: aliceFolder, account: alice)
        // The same names in the second account: the worst case for a delete by name.
        for name in files(aliceFolder) {
            try FileManager.default.createDirectory(at: bobFolder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: aliceFolder.appendingPathComponent(name), to: bobFolder.appendingPathComponent(name))
        }
        let bobBefore = files(bobFolder)
        let drives = TwoAccountDestination(alice: (alice, aliceFolder), bob: (bob, bobFolder))
        drives.switchToBobAfterRemoves = 1
        #expect(throws: CloudBackupError.accountChanged) {
            try CloudBackupEngine.deleteBackups(shown, deviceID: device, account: alice, in: drives)
        }
        #expect(files(bobFolder) == bobBefore, "nothing deleted in the account switched to")
        #expect(drives.removes(in: bob).isEmpty)
        #expect(files(aliceFolder).count == 3, "one file went before the switch: \(files(aliceFolder))")
    }

    /// No switch: exactly the confirmed backups go.
    @Test func deletingInTheConfirmedAccountDeletesWhatWasShown() async throws {
        let aliceFolder = TestSupport.tempDir(), bobFolder = TestSupport.tempDir()
        let shown = try await twoBackups(in: aliceFolder, account: alice)
        let drives = TwoAccountDestination(alice: (alice, aliceFolder), bob: (bob, bobFolder))
        #expect(try CloudBackupEngine.deleteBackups(shown, deviceID: device, account: alice, in: drives) == 2)
        #expect(files(aliceFolder).isEmpty)
    }

    /// Signed in to the other account before the first file: nothing at all is deleted.
    @Test func deletingUnderAnotherAccountDeletesNothing() async throws {
        let aliceFolder = TestSupport.tempDir(), bobFolder = TestSupport.tempDir()
        let shown = try await twoBackups(in: aliceFolder, account: alice)
        let drives = TwoAccountDestination(alice: (alice, aliceFolder), bob: (bob, bobFolder))
        drives.signIn(bob)
        #expect(throws: CloudBackupError.accountChanged) {
            try CloudBackupEngine.deleteBackups(shown, deviceID: device, account: alice, in: drives)
        }
        #expect(files(aliceFolder).count == 4)
        #expect(drives.removes(in: bob).isEmpty)
    }

    // MARK: A24-01 pruning after a backup

    /// The backup finished in the first account; the account is switched after the last check
    /// before pruning, so the prune's own listing is of the second account. Its backups of this
    /// device are not rotated out: nobody wrote a new one there.
    @Test func pruningStaysInTheAccountItWroteTo() async throws {
        let aliceFolder = TestSupport.tempDir(), bobFolder = TestSupport.tempDir()
        _ = try await twoBackups(in: bobFolder, account: bob)
        let bobBefore = files(bobFolder)
        let store = try await seededStore()
        let drives = TwoAccountDestination(alice: (alice, aliceFolder), bob: (bob, bobFolder))
        // Asked before and after the listing, before the move, before the info file, before pruning.
        drives.switchToBobAfterAsks = 5
        guard case .completed = try await CloudBackupEngine.backUpIfNeeded(
            store: store, destination: drives, settings: settings(for: alice), trigger: .manual, context: context(), now: t0 + 3 * day)
        else { Issue.record("the backup itself was complete"); return }
        #expect(files(bobFolder) == bobBefore, "the second account was pruned: \(files(bobFolder))")
        #expect(drives.removes(in: bob).isEmpty)
        #expect(files(aliceFolder).count == 2)
    }

    /// The backup and the prune's listing are both in the first account; the account is
    /// switched after the prune deleted its first file. The second account holds files of the
    /// same names (the worst case for a delete by name): none of them goes, and the prune
    /// deletes nothing more in either account. It stops quietly (a failed prune costs space,
    /// never a backup), so the backup itself still reports complete. QA review round 20,
    /// WEAK-TEST 1: only the check before each file in the loop catches this.
    @Test func pruningStopsWhenTheAccountChangesHalfWay() async throws {
        let aliceFolder = TestSupport.tempDir(), bobFolder = TestSupport.tempDir()
        _ = try await twoBackups(in: aliceFolder, account: alice)
        try FileManager.default.createDirectory(at: bobFolder, withIntermediateDirectories: true)
        for name in files(aliceFolder) {
            try FileManager.default.copyItem(at: aliceFolder.appendingPathComponent(name), to: bobFolder.appendingPathComponent(name))
        }
        let aliceBefore = files(aliceFolder), bobBefore = files(bobFolder)
        #expect(aliceBefore.count == 4)
        let store = try await seededStore()
        try await add(store, seed: 30, x: 7)
        let drives = TwoAccountDestination(alice: (alice, aliceFolder), bob: (bob, bobFolder))
        drives.switchToBobAfterRemoves = 1
        guard case .completed(let record) = try await CloudBackupEngine.backUpIfNeeded(
            store: store, destination: drives, settings: settings(for: alice), trigger: .manual, context: context(keep: 1), now: t0 + 3 * day)
        else { Issue.record("the backup itself was complete"); return }
        #expect(drives.removes(in: bob).isEmpty, "pruned in the account switched to: \(drives.removes(in: bob))")
        #expect(files(bobFolder) == bobBefore)
        #expect(drives.removes(in: alice).count == 1, "the prune went on after the switch: \(drives.removes(in: alice))")
        #expect(files(aliceFolder).contains(record.archiveName))
        #expect(files(aliceFolder).count == aliceBefore.count + 2 - 1)
    }

    /// The control: no switch, and the earlier backup in the same account is rotated out.
    @Test func pruningInTheSameAccountStillRotates() async throws {
        let aliceFolder = TestSupport.tempDir(), bobFolder = TestSupport.tempDir()
        _ = try await twoBackups(in: aliceFolder, account: alice)
        let store = try await seededStore()
        try await add(store, seed: 30, x: 7)
        let drives = TwoAccountDestination(alice: (alice, aliceFolder), bob: (bob, bobFolder))
        guard case .completed(let record) = try await CloudBackupEngine.backUpIfNeeded(
            store: store, destination: drives, settings: settings(for: alice), trigger: .manual, context: context(), now: t0 + 3 * day)
        else { Issue.record("backup"); return }
        #expect(files(aliceFolder).filter { $0.hasSuffix(".zip") } == [record.archiveName])
    }

    // MARK: A24-01 the compensating delete after a failed read-back

    /// The archive moved into the first account; the account is switched before it is read
    /// back. The read-back fails (the file is not in the second account), and taking the new
    /// file out again must not happen in the second account.
    @Test func aFailedReadBackRemovesNothingInAnotherAccount() async throws {
        let aliceFolder = TestSupport.tempDir(), bobFolder = TestSupport.tempDir()
        let store = try await seededStore()
        let drives = TwoAccountDestination(alice: (alice, aliceFolder), bob: (bob, bobFolder))
        drives.switchToBobAfterPlace = true
        let outcome = try? await CloudBackupEngine.backUpIfNeeded(
            store: store, destination: drives, settings: settings(for: alice), trigger: .manual, context: context(), now: t0)
        if case .completed = outcome { Issue.record("a backup that was not read back does not count") }
        #expect(drives.removes(in: bob).isEmpty, "removed in the account switched to: \(drives.removes(in: bob))")
        #expect(files(bobFolder).isEmpty)
        // The archive stays in the first account as an unverified leftover, pruned later there.
        #expect(files(aliceFolder).filter { $0.hasSuffix(".zip") }.count == 1)
        #expect(!files(aliceFolder).contains { $0.hasSuffix(".json") })
    }

    // MARK: A24-03 what a listing can say

    /// Unknown is not empty: only a listing that is current says "no backup".
    @Test func backupPresenceIsThreeState() throws {
        let name = CloudBackupName(deviceID: device, createdAt: t0, revision: 1)!
        let entry = CloudBackupEntry(name: name, info: nil, byteSize: 10, isDownloaded: true, upload: .notApplicable,
                                     condition: .unverified, isFromThisDevice: true)
        var damaged = entry
        damaged.condition = .damaged
        #expect(CloudBackupPolicy.presence(listingIsCurrent: true, entries: [entry]) == .some)
        #expect(CloudBackupPolicy.presence(listingIsCurrent: true, entries: []) == .none)
        #expect(CloudBackupPolicy.presence(listingIsCurrent: true, entries: [damaged]) == .none, "a damaged one cannot restore")
        #expect(CloudBackupPolicy.presence(listingIsCurrent: false, entries: []) == .unknown)
        #expect(CloudBackupPolicy.presence(listingIsCurrent: false, entries: [entry]) == .unknown, "an old listing is not a fact")
    }

    // MARK: B24-05 backups left in the account backup moved away from

    /// The user moves backup from the first account to the second. The first account's
    /// backups are not visible any more, but they are still there: the privacy wording must not
    /// say that nothing is left, even after the second account holds none.
    @Test func movingToAnotherAccountRemembersThatBackupsWereLeftBehind() throws {
        var settings = settings(for: alice)
        settings.lastSuccess = CloudBackupRecord(archiveName: "a.zip", fingerprint: "f", revision: 1, date: t0, photoCount: 1,
                                                 furnitureCount: 1, byteSize: 10)
        settings.moveBackups(to: bob)
        #expect(settings.account == bob)
        #expect(settings.backupsLeftInAnotherAccount)
        #expect(PhotoReach.backupsLeft(listedOwnBackups: 0, lastBackupKept: false, leftInAnotherAccount: settings.backupsLeftInAnotherAccount))
        #expect(PhotoReach(backupOn: false, syncOn: false,
                           backupsLeft: PhotoReach.backupsLeft(listedOwnBackups: 0, lastBackupKept: false,
                                                               leftInAnotherAccount: settings.backupsLeftInAnotherAccount)) != .thisDeviceOnly)

        // Confirming the account that is already remembered, or moving before any backup, leaves nothing behind.
        var first = self.settings(for: alice)
        first.moveBackups(to: alice)
        #expect(!first.backupsLeftInAnotherAccount)
        var never = CloudBackupSettings()
        never.enabled = true
        never.moveBackups(to: bob)
        #expect(!never.backupsLeftInAnotherAccount && never.account == bob)

        // Saved and read back; settings from before the field load as false.
        let decoded = try JSONDecoder().decode(CloudBackupSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.backupsLeftInAnotherAccount)
        #expect(try !JSONDecoder().decode(CloudBackupSettings.self, from: Data(#"{"enabled":true}"#.utf8)).backupsLeftInAnotherAccount)
    }
}

/// Two Apple Accounts on one device, each with its own iCloud Drive folder. Calls reach the
/// folder of the account signed in at that moment. Switches when told: after a number of
/// account questions, after a number of removes, or right after a move in.
final class TwoAccountDestination: BackupDestination {
    private let folders: [String: FolderBackupDestination]
    private let bob: String
    private let current: Mutex<String>
    private let asked = Mutex(0)
    private let removed = Mutex<[String: [String]]>([:])
    private let settingsLock = Mutex<(asks: Int?, removes: Int?, place: Bool)>((nil, nil, false))

    var switchToBobAfterAsks: Int? {
        get { settingsLock.withLock { $0.asks } }
        set { settingsLock.withLock { $0.asks = newValue } }
    }
    var switchToBobAfterRemoves: Int? {
        get { settingsLock.withLock { $0.removes } }
        set { settingsLock.withLock { $0.removes = newValue } }
    }
    var switchToBobAfterPlace: Bool {
        get { settingsLock.withLock { $0.place } }
        set { settingsLock.withLock { $0.place = newValue } }
    }

    init(alice: (String, URL), bob: (String, URL)) {
        folders = [alice.0: FolderBackupDestination(folder: alice.1, account: alice.0),
                   bob.0: FolderBackupDestination(folder: bob.1, account: bob.0)]
        self.bob = bob.0
        current = Mutex(alice.0)
    }

    func signIn(_ account: String) { current.withLock { $0 = account } }
    func removes(in account: String) -> [String] { removed.withLock { $0[account] ?? [] } }

    private var drive: (String, FolderBackupDestination) {
        let account = current.withLock { $0 }
        return (account, folders[account]!)
    }

    func availability() -> CloudAvailability { .available }
    func accountFingerprint() -> String? {
        let account = current.withLock { $0 }
        let count = asked.withLock { value -> Int in
            value += 1
            return value
        }
        if let after = switchToBobAfterAsks, count >= after { signIn(bob) }
        return account
    }
    func list() throws -> [CloudBackupFile] { try drive.1.list() }
    func readSmallFile(_ name: String) throws -> Data { try drive.1.readSmallFile(name) }
    func place(_ local: URL, as name: String) throws {
        try drive.1.place(local, as: name)
        if switchToBobAfterPlace { signIn(bob) }
    }
    func writeSmallFile(_ data: Data, as name: String) throws { try drive.1.writeSmallFile(data, as: name) }
    func remove(_ name: String) throws {
        let (account, folder) = drive
        try folder.remove(name)
        let count = removed.withLock { all -> Int in
            all[account, default: []].append(name)
            return all.values.reduce(0) { $0 + $1.count }
        }
        if let after = switchToBobAfterRemoves, count >= after { signIn(bob) }
    }
    func localURL(for name: String) -> URL? { drive.1.localURL(for: name) }
    func download(_ name: String, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        try await drive.1.download(name, progress: progress)
    }
}
