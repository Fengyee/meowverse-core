import Foundation
import Synchronization
import Testing
@testable import MeowverseCore

/// iCloud Drive backup belongs to the Apple Account the user agreed for (audit FAMILY-4): after
/// an account switch, or on a phone restored under another account, nothing is written into
/// the other account's iCloud Drive until the user answers. Each account has its own folder
/// here, as each has its own iCloud Drive.
struct CloudBackupAccountTests {
    let catalog: FurnitureCatalog
    let chairAt44 = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2)
    let stoolAt00 = Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1)
    let device = "0123456789ab"
    let day: TimeInterval = 24 * 60 * 60
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let alice = CloudBackupAccount.fingerprint(token: Data("token-of-the-first-account".utf8))
    let bob = CloudBackupAccount.fingerprint(token: Data("token-of-the-second-account".utf8))

    init() throws {
        catalog = try TestSupport.catalog()
    }

    private func seededStore() async throws -> LibraryStore {
        let store = LibraryStore(root: TestSupport.tempDir().appendingPathComponent("Library", isDirectory: true), catalog: catalog)
        _ = try await store.load()
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 1), placement: chairAt44, displayName: "窗边的椅子", decision: .manual)
        return store
    }

    private func addStool(_ store: LibraryStore) async throws {
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 2), placement: stoolAt00, displayName: "小凳", decision: .manual)
    }

    private func context() -> CloudBackupEngine.Context {
        CloudBackupEngine.Context(deviceID: device, deviceKind: "iPhone", appVersion: "9.9", workDirectory: TestSupport.tempDir(), catalog: catalog)
    }

    private func run(_ store: LibraryStore, _ destination: any BackupDestination, _ settings: inout CloudBackupSettings,
                     trigger: CloudBackupPolicy.Trigger, now: Date) async throws -> CloudBackupEngine.Outcome {
        let outcome = try await CloudBackupEngine.backUpIfNeeded(
            store: store, destination: destination, settings: settings, trigger: trigger, context: context(), now: now)
        if case .completed(let record) = outcome { settings.lastSuccess = record }
        return outcome
    }

    private func files(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    // MARK: The fingerprint

    @Test func fingerprintIsShortOpaqueAndStable() {
        let token = Data("token-of-the-first-account".utf8)
        #expect(CloudBackupAccount.fingerprint(token: token) == alice)
        #expect(alice != bob)
        #expect(alice.hasPrefix("ud-") && alice.count == 23)
        #expect(alice.dropFirst(3).allSatisfy { $0.isHexDigit && !$0.isUppercase })
        // Not the token itself, nor a plain hash of it that could be matched elsewhere.
        #expect(!alice.contains(token.map { String(format: "%02x", $0) }.joined().prefix(8)))
        #expect(!alice.contains(PhotoIngest.sha256Hex(token).prefix(20)))
    }

    // MARK: The rule

    @Test func accountCheckFollowsTheRememberedAccount() throws {
        let last = CloudBackupRecord(archiveName: "Meowverse-backup-0123456789ab-20270115T080000Z-r3.zip", fingerprint: "f",
                                     revision: 3, date: t0, photoCount: 1, furnitureCount: 1, byteSize: 10)
        let name = try #require(CloudBackupName(archiveName: last.archiveName))
        let present = CloudBackupListing(entries: [CloudBackupEntry(name: name, info: nil, byteSize: 10, isDownloaded: true,
                                                                    upload: .uploaded, condition: .verified, isFromThisDevice: true)])
        func check(_ remembered: String?, _ current: String?, last: CloudBackupRecord? = nil,
                   listing: CloudBackupListing? = CloudBackupListing()) -> CloudBackupPolicy.AccountCheck {
            CloudBackupPolicy.checkAccount(remembered: remembered, current: current, lastSuccess: last, listing: listing)
        }
        #expect(check(alice, alice) == .matches)
        #expect(check(alice, alice, listing: nil) == .matches)
        #expect(check(alice, bob) == .differs)
        #expect(check(alice, bob, last: last, listing: present) == .differs, "a remembered account is never replaced on its own")
        // No account to compare: nothing is decided (and nothing is written while signed out).
        #expect(check(alice, nil) == .unknown)
        #expect(check(nil, nil, last: last, listing: present) == .unknown)
        // Settings from before accounts were remembered: only this device's last backup in this
        // account's folder shows the backup belongs here.
        #expect(check(nil, bob, last: last, listing: present) == .adopt(bob))
        // Nothing shows it either way: not called another account, still nothing written.
        #expect(check(nil, bob, last: last) == .unconfirmed)
        #expect(check(nil, bob) == .unconfirmed)
        #expect(check(nil, bob, last: last, listing: nil) == .unknown, "a folder that could not be read proves nothing")
        var damaged = present
        damaged.entries[0].condition = .damaged
        #expect(check(nil, bob, last: last, listing: damaged) == .unconfirmed)
    }

    @Test func settingsFromBeforeAccountsStillLoadAndTheAccountRoundTrips() throws {
        let old = try JSONDecoder().decode(CloudBackupSettings.self, from: Data(#"{"enabled":true,"damagedNames":[],"restoreOfferDismissed":false}"#.utf8))
        #expect(old.enabled && old.account == nil)
        var settings = CloudBackupSettings()
        settings.enabled = true
        settings.account = alice
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(CloudBackupSettings.self, from: data) == settings)
        #expect(!String(decoding: data, as: UTF8.self).contains("token"))
    }

    // MARK: The engine

    @Test func anotherAccountGetsNothingUntilTheUserAnswers() async throws {
        let store = try await seededStore()
        let aliceFolder = TestSupport.tempDir(), bobFolder = TestSupport.tempDir()
        var settings = CloudBackupSettings()
        settings.enabled = true
        settings.account = alice
        guard case .completed = try await run(store, FolderBackupDestination(folder: aliceFolder, account: alice), &settings,
                                              trigger: .manual, now: t0) else { Issue.record("expected the first backup"); return }
        let aliceFiles = files(aliceFolder)
        #expect(aliceFiles.count == 2)

        // Signed in as someone else, days later, with a changed library: due by every other rule.
        try await addStool(store)
        let bobs = FolderBackupDestination(folder: bobFolder, account: bob)
        for trigger in [CloudBackupPolicy.Trigger.automatic, .manual] {
            #expect(try await run(store, bobs, &settings, trigger: trigger, now: t0 + 3 * day) == .skipped(.otherAccount))
        }
        #expect(files(bobFolder).isEmpty, "nothing reached the other account's iCloud Drive")
        #expect(files(aliceFolder) == aliceFiles)

        // The user chose to keep backing up, to this account.
        settings.account = bob
        guard case .completed = try await run(store, bobs, &settings, trigger: .automatic, now: t0 + 3 * day) else {
            Issue.record("expected a backup after the answer"); return
        }
        #expect(files(bobFolder).count == 2)
        #expect(files(aliceFolder) == aliceFiles, "the first account's backup stays where it was")
    }

    @Test func signedInWithoutAKnownAccountWritesNothing() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        var settings = CloudBackupSettings()
        settings.enabled = true
        settings.account = alice
        let unknown = FolderBackupDestination(folder: folder, account: nil)
        #expect(try await run(store, unknown, &settings, trigger: .manual, now: t0) == .skipped(.accountUnknown))
        #expect(files(folder).isEmpty)
    }

    /// Turned on by a build that did not remember the account.
    @Test func olderSettingsAdoptTheAccountOnlyWhenItHoldsThisDevicesLastBackup() async throws {
        let store = try await seededStore()
        let aliceFolder = TestSupport.tempDir(), bobFolder = TestSupport.tempDir()
        var settings = CloudBackupSettings()
        settings.enabled = true
        settings.account = alice
        guard case .completed = try await run(store, FolderBackupDestination(folder: aliceFolder, account: alice), &settings,
                                              trigger: .manual, now: t0) else { Issue.record("expected the first backup"); return }
        settings.account = nil
        try await addStool(store)

        // A restored phone under another account: its folder does not have the last backup.
        let bobs = FolderBackupDestination(folder: bobFolder, account: bob)
        #expect(try await run(store, bobs, &settings, trigger: .automatic, now: t0 + 3 * day) == .skipped(.accountUnconfirmed))
        #expect(files(bobFolder).isEmpty)

        // The same account: the last backup is there, so backing up carries on.
        let alices = FolderBackupDestination(folder: aliceFolder, account: alice)
        guard case .completed = try await run(store, alices, &settings, trigger: .automatic, now: t0 + 3 * day) else {
            Issue.record("expected the same account to carry on"); return
        }

        // Never backed up yet: nothing shows whose iCloud this is.
        var fresh = CloudBackupSettings()
        fresh.enabled = true
        #expect(try await run(store, FolderBackupDestination(folder: bobFolder, account: bob), &fresh, trigger: .manual, now: t0) == .skipped(.accountUnconfirmed))
        #expect(files(bobFolder).isEmpty)
    }

    /// The account changes while a backup is being built: the archive is not moved in.
    @Test func anAccountSwitchDuringTheBackupStopsItBeforeAnythingIsMovedIn() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        var settings = CloudBackupSettings()
        settings.enabled = true
        settings.account = alice
        for calls in [1, 2] {
            // During the listing, or while the archive is built.
            let switching = SwitchingAccountDestination(base: FolderBackupDestination(folder: folder, account: alice), after: alice, then: bob, calls: calls)
            #expect(try await run(store, switching, &settings, trigger: .manual, now: t0) == .skipped(.otherAccount), "switch after call \(calls)")
            #expect(files(folder).isEmpty)
            #expect(switching.placed.withLock { $0 } == 0)
        }
    }

    /// The switch comes after the archive moved in: no info file goes into the account switched
    /// to, so nothing there counts as a backup.
    @Test func anAccountSwitchAfterTheMoveWritesNoInfoFile() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        var settings = CloudBackupSettings()
        settings.enabled = true
        settings.account = alice
        let switching = SwitchingAccountDestination(base: FolderBackupDestination(folder: folder, account: alice), after: alice, then: bob, calls: 3)
        #expect(try await run(store, switching, &settings, trigger: .manual, now: t0) == .skipped(.otherAccount))
        #expect(switching.placed.withLock { $0 } == 1)
        #expect(!files(folder).contains { $0.hasSuffix(".json") }, "no info file: \(files(folder))")
    }

    /// The switch comes after the new backup is complete: it counts, but nothing is pruned, since
    /// pruning would look into the account switched to.
    @Test func anAccountSwitchBeforePruningPrunesNothing() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        var settings = CloudBackupSettings()
        settings.enabled = true
        settings.account = alice
        let plain = FolderBackupDestination(folder: folder, account: alice)
        guard case .completed = try await run(store, plain, &settings, trigger: .manual, now: t0) else { Issue.record("first"); return }
        let before = files(folder)
        try await addStool(store)
        let switching = SwitchingAccountDestination(base: plain, after: alice, then: bob, calls: 4)
        guard case .completed = try await run(store, switching, &settings, trigger: .manual, now: t0 + day) else {
            Issue.record("the backup itself was complete"); return
        }
        #expect(Set(before).isSubset(of: Set(files(folder))), "the earlier backup was not pruned")
        #expect(files(folder).count == before.count + 2)
        // The control: without the switch, the earlier one is rotated out.
        try await addStool2(store)
        guard case .completed = try await run(store, plain, &settings, trigger: .manual, now: t0 + 2 * day) else { Issue.record("third"); return }
        #expect(files(folder).count == 2)
    }

    private func addStool2(_ store: LibraryStore) async throws {
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 3), placement: Placement(modelId: "kenney-stoolBar", x: 7, z: 0, width: 1, depth: 1),
                                               displayName: "小凳二", decision: .manual)
    }
}

/// Answers `first` for the first `calls` questions, then `then`: an Apple Account switch in the
/// middle of a backup. The engine asks before and after the listing, before the archive moves
/// in, before the info file and before pruning (calls 1 to 5).
final class SwitchingAccountDestination: BackupDestination {
    let base: FolderBackupDestination
    let first: String
    let then: String
    let calls: Int
    let asked = Mutex(0)
    let placed = Mutex(0)

    init(base: FolderBackupDestination, after first: String, then: String, calls: Int = 1) {
        self.base = base
        self.first = first
        self.then = then
        self.calls = calls
    }

    func availability() -> CloudAvailability { base.availability() }
    func accountFingerprint() -> String? {
        asked.withLock { count in
            count += 1
            return count <= calls ? first : then
        }
    }
    func list() throws -> [CloudBackupFile] { try base.list() }
    func readSmallFile(_ name: String) throws -> Data { try base.readSmallFile(name) }
    func place(_ local: URL, as name: String) throws {
        placed.withLock { $0 += 1 }
        try base.place(local, as: name)
    }
    func writeSmallFile(_ data: Data, as name: String) throws { try base.writeSmallFile(data, as: name) }
    func remove(_ name: String) throws { try base.remove(name) }
    func localURL(for name: String) -> URL? { base.localURL(for: name) }
    func download(_ name: String, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        try await base.download(name, progress: progress)
    }
}
