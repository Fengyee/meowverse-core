import Foundation
import Synchronization
import Testing
@testable import MeowverseCore

/// Round 12 QA of task D (audit FAMILY-4): iCloud Drive backup tied to the Apple Account it
/// was turned on for. Each account has its own folder, as each has its own iCloud Drive.
/// The two tests marked "QA finding" fail on 4cd4e71; the rest guard what already holds.
struct QACloudBackupAccountTests {
    let catalog: FurnitureCatalog
    let chairAt44 = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2)
    let stoolAt00 = Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1)
    let stoolAt70 = Placement(modelId: "kenney-stoolBar", x: 7, z: 0, width: 1, depth: 1)
    let device = "0123456789ab"
    let otherDevice = "ba9876543210"
    let hour: TimeInterval = 60 * 60
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let alice = CloudBackupAccount.fingerprint(token: Data("qa-token-of-the-first-account".utf8))
    let bob = CloudBackupAccount.fingerprint(token: Data("qa-token-of-the-second-account".utf8))

    init() throws {
        catalog = try TestSupport.catalog()
    }

    private func seededStore() async throws -> LibraryStore {
        let store = LibraryStore(root: TestSupport.tempDir().appendingPathComponent("Library", isDirectory: true), catalog: catalog)
        _ = try await store.load()
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 1), placement: chairAt44, displayName: "窗边的椅子", decision: .manual)
        return store
    }

    private func add(_ store: LibraryStore, seed: Int, at placement: Placement) async throws {
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: seed), placement: placement, displayName: "件\(seed)", decision: .manual)
    }

    private func context(_ deviceID: String? = nil) -> CloudBackupEngine.Context {
        CloudBackupEngine.Context(deviceID: deviceID ?? device, deviceKind: "iPhone", appVersion: "9.9", workDirectory: TestSupport.tempDir(), catalog: catalog)
    }

    private func run(_ store: LibraryStore, _ destination: any BackupDestination, _ settings: inout CloudBackupSettings,
                     trigger: CloudBackupPolicy.Trigger, now: Date, deviceID: String? = nil) async throws -> CloudBackupEngine.Outcome {
        let outcome = try await CloudBackupEngine.backUpIfNeeded(
            store: store, destination: destination, settings: settings, trigger: trigger, context: context(deviceID), now: now)
        if case .completed(let record) = outcome { settings.lastSuccess = record }
        return outcome
    }

    private func files(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    // MARK: QA finding: an account nobody showed to be different is called "another account"

    /// Backup turned on while signed out (no account remembered) and never backed up, or turned on
    /// by an older build and never backed up: the user signs in to their own and only account.
    /// Nothing shows it is another account, yet the outcome is `.otherAccount`, which the app
    /// words as “这台 iPhone 现在登录的是另一个 Apple 账户” on the page and in the notice.
    /// Not uploading is right; saying the account is someone else's is not.
    @Test func qaFindingAnAccountThatWasNeverComparedIsNotCalledAnother() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        var settings = CloudBackupSettings()
        settings.enabled = true // account nil, lastSuccess nil
        let outcome = try await run(store, FolderBackupDestination(folder: folder, account: alice), &settings, trigger: .manual, now: t0)
        #expect(files(folder).isEmpty, "nothing is uploaded before the user answers")
        #expect(outcome != .skipped(.otherAccount), "nothing showed this is another account than the one backup was turned on for")
        #expect(CloudBackupPolicy.checkAccount(remembered: nil, current: alice, lastSuccess: nil, listing: CloudBackupListing()) != .differs)
    }

    // MARK: QA finding: the account is read after the listing it is judged by

    /// Settings from before the account was remembered. The listing is taken while signed in to
    /// the first account (it holds this device's last backup); the account is switched before
    /// the token is read. The listing of the first account then "proves" the second one: it is
    /// adopted and the library goes into the second account's iCloud Drive without asking.
    /// `refreshCloudBackups` reads in the same order and saves the adopted account for good.
    @Test func qaFindingASwitchBetweenTheListingAndTheTokenDoesNotAdoptTheNewAccount() async throws {
        let store = try await seededStore()
        let aliceFolder = TestSupport.tempDir(), bobFolder = TestSupport.tempDir()
        var settings = CloudBackupSettings()
        settings.enabled = true
        settings.account = alice
        guard case .completed = try await run(store, FolderBackupDestination(folder: aliceFolder, account: alice), &settings,
                                              trigger: .manual, now: t0) else { Issue.record("expected the first backup"); return }
        settings.account = nil // as an older build saved it
        try await add(store, seed: 2, at: stoolAt00)

        let switching = QASwitchAfterListingDestination(
            first: FolderBackupDestination(folder: aliceFolder, account: alice),
            then: FolderBackupDestination(folder: bobFolder, account: bob))
        let outcome = try await run(store, switching, &settings, trigger: .automatic, now: t0 + 30 * hour)
        #expect(files(bobFolder).isEmpty, "the second account's iCloud Drive got a backup nobody agreed to")
        if case .completed = outcome { Issue.record("backed up into the account switched to during the listing") }
    }

    // MARK: Holds: the existing rules, across a switch and the user's answer

    /// After "keep backing up to this account": one backup per device in the new account (the
    /// old account is never rotated or pruned from here), the 24-hour rule, "unchanged", and
    /// another device's backup in the same folder left alone.
    @Test func afterTheAnswerRotationAndTheDailyRuleWorkInTheNewAccountOnly() async throws {
        let store = try await seededStore()
        let aliceFolder = TestSupport.tempDir(), bobFolder = TestSupport.tempDir()
        let alices = FolderBackupDestination(folder: aliceFolder, account: alice)
        let bobs = FolderBackupDestination(folder: bobFolder, account: bob)
        var settings = CloudBackupSettings()
        settings.enabled = true
        settings.account = alice
        guard case .completed = try await run(store, alices, &settings, trigger: .manual, now: t0) else { Issue.record("first"); return }
        let aliceFiles = files(aliceFolder)

        // Another device of Bob's already keeps a backup in Bob's folder.
        let iPad = try await seededStore()
        var iPadSettings = CloudBackupSettings()
        iPadSettings.enabled = true
        iPadSettings.account = bob
        guard case .completed = try await run(iPad, bobs, &iPadSettings, trigger: .manual, now: t0, deviceID: otherDevice) else {
            Issue.record("iPad"); return
        }
        let iPadFiles = files(bobFolder)

        // Switched to Bob, answered "keep backing up". Alice's last backup is not in Bob's folder,
        // so the first automatic trigger backs up at once, even within 24 hours of Alice's.
        settings.account = bob
        guard case .completed = try await run(store, bobs, &settings, trigger: .automatic, now: t0 + hour) else {
            Issue.record("expected a backup in Bob's account"); return
        }
        #expect(files(bobFolder).count == iPadFiles.count + 2)
        // Unchanged, then too soon.
        #expect(try await run(store, bobs, &settings, trigger: .automatic, now: t0 + 2 * hour) == .skipped(.unchanged))
        try await add(store, seed: 2, at: stoolAt00)
        guard case .skipped(.tooSoon) = try await run(store, bobs, &settings, trigger: .automatic, now: t0 + 3 * hour) else {
            Issue.record("expected the daily rule"); return
        }
        // A day later: a new one, the previous one of this device is rotated out, the iPad's stays.
        guard case .completed(let newest) = try await run(store, bobs, &settings, trigger: .automatic, now: t0 + 26 * hour) else {
            Issue.record("expected the next day's backup"); return
        }
        let mine = files(bobFolder).filter { $0.contains(device) }
        #expect(mine.count == 2 && mine.contains(newest.archiveName), "one backup of this device: \(mine)")
        #expect(Set(iPadFiles).isSubset(of: Set(files(bobFolder))), "another device's backup is never pruned")
        #expect(files(aliceFolder) == aliceFiles, "nothing in the first account was rotated or pruned")

        // Signed out, then back in to Bob: carries on without asking.
        let signedOut = FolderBackupDestination(folder: bobFolder, account: nil)
        try await add(store, seed: 3, at: stoolAt70)
        #expect(try await run(store, signedOut, &settings, trigger: .automatic, now: t0 + 60 * hour) == .skipped(.accountUnknown))
        guard case .completed = try await run(store, bobs, &settings, trigger: .automatic, now: t0 + 61 * hour) else {
            Issue.record("expected the same account to carry on after signing in again"); return
        }
    }

    /// Turning backup off from the other account deletes only what was listed there and is this
    /// device's: the first account's backups and the other device's are untouched.
    @Test func deletingFromTheOtherAccountTouchesOnlyWhatWasListedThere() async throws {
        let store = try await seededStore()
        let aliceFolder = TestSupport.tempDir(), bobFolder = TestSupport.tempDir()
        var settings = CloudBackupSettings()
        settings.enabled = true
        settings.account = alice
        guard case .completed = try await run(store, FolderBackupDestination(folder: aliceFolder, account: alice), &settings,
                                              trigger: .manual, now: t0) else { Issue.record("first"); return }
        let aliceFiles = files(aliceFolder)
        let iPad = try await seededStore()
        var iPadSettings = CloudBackupSettings()
        iPadSettings.enabled = true
        iPadSettings.account = bob
        let bobs = FolderBackupDestination(folder: bobFolder, account: bob)
        guard case .completed = try await run(iPad, bobs, &iPadSettings, trigger: .manual, now: t0, deviceID: otherDevice) else {
            Issue.record("iPad"); return
        }
        let listing = try CloudBackupCatalog.load(from: bobs, deviceID: device)
        #expect(listing.entries.filter(\.isFromThisDevice).isEmpty)
        let deleted = try CloudBackupEngine.deleteBackups(listing.entries.map(\.name), deviceID: device, in: bobs)
        #expect(deleted == 0)
        #expect(files(bobFolder).count == 2)
        #expect(files(aliceFolder) == aliceFiles)
    }

    // MARK: The fingerprint

    /// Opaque and fixed-length whatever the token's size; does not contain the token's bytes in
    /// any common text form; one token, one fingerprint (the same on every launch).
    @Test func fingerprintNeverCarriesTheToken() {
        for size in [0, 1, 16, 32, 200, 4096] {
            let token = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
            let print = CloudBackupAccount.fingerprint(token: token)
            #expect(print.count == 23 && print.hasPrefix("ud-"))
            #expect(print == CloudBackupAccount.fingerprint(token: token))
            if size >= 8 {
                let hex = token.prefix(8).map { String(format: "%02x", $0) }.joined()
                #expect(!print.contains(hex) && !print.contains(token.prefix(8).base64EncodedString().prefix(8)))
            }
        }
        #expect(CloudBackupAccount.fingerprint(token: Data([1])) != CloudBackupAccount.fingerprint(token: Data([1, 0])))
    }
}

/// Lists the first account's folder, and is the second account from then on: an Apple Account
/// switch right after the listing.
final class QASwitchAfterListingDestination: BackupDestination {
    let first: FolderBackupDestination
    let then: FolderBackupDestination
    let switched = Mutex(false)

    init(first: FolderBackupDestination, then: FolderBackupDestination) {
        self.first = first
        self.then = then
    }

    private var current: FolderBackupDestination { switched.withLock { $0 } ? then : first }

    func availability() -> CloudAvailability { current.availability() }
    func accountFingerprint() -> String? { current.accountFingerprint() }
    func list() throws -> [CloudBackupFile] {
        let result = try current.list()
        switched.withLock { $0 = true }
        return result
    }
    func readSmallFile(_ name: String) throws -> Data { try current.readSmallFile(name) }
    func place(_ local: URL, as name: String) throws { try current.place(local, as: name) }
    func writeSmallFile(_ data: Data, as name: String) throws { try current.writeSmallFile(data, as: name) }
    func remove(_ name: String) throws { try current.remove(name) }
    func localURL(for name: String) -> URL? { current.localURL(for: name) }
    func download(_ name: String, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        try await current.download(name, progress: progress)
    }
}
