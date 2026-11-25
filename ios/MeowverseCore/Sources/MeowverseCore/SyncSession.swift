import Foundation
import os

// Multi-device iCloud sync: one device's sync cycle. See docs/ICLOUD_SYNC.md.
//
// capture this device's edits → save them (durably, before any network) → send → fetch →
// download the copies new photos need → build the library from the merged records → switch
// to it in one store write, only if nothing changed meanwhile (else capture again).

public enum SyncApplyError: Error, Sendable, Equatable {
    /// The library changed after sync read it. Nothing was written.
    case localChanged
    /// The library was restored or cleared after sync read it. Nothing was written.
    case libraryReplaced
    /// The built library fails the store's own checks: a bug, nothing was written.
    case inconsistent
}

/// Why sync's own file (`LibraryStore.syncStateFile`, or the copy before it) cannot be used.
/// Neither is "no file": a library without one merges as on first sync, these never do.
public enum SyncStateError: Error, Sendable, Equatable {
    /// The file and its backup are there and neither can be read. Not a first sync: which
    /// account the home synced with is in there, so a new state would take whichever account
    /// answers (audit AA24-01). The app checks the account it knows, then starts over, which
    /// keeps the unreadable copies aside. Knowing none (a new install, no marker), it turns sync
    /// off; turning it on again asks first (QA review round 20, G1).
    case unreadable
    /// A newer version of the app wrote it: this version leaves it as it is and does not sync
    /// this library (no first sync, no start over, no rebase; COMPAT-4).
    case newerVersion
}

/// Everything sync remembers on one device, in the library folder (`LibraryStore.syncStateFile`).
public struct SyncDeviceState: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version = Self.currentVersion
    public var clock: SyncClock
    /// The account this state belongs to (`SyncTransport.accountKey`).
    public var account: String?
    public var replica = SyncReplica()
    /// The library as sync last wrote or read it; nil before the first sync.
    public var base: AppState?
    /// Records with edits the server has not confirmed.
    public var dirty = Set<String>()
    public var tags: [String: String] = [:]
    public var token: SyncToken?
    /// Cloud files this device already deleted as no longer needed, while that still holds (so
    /// it does not delete them again every cycle). Any device cleans up, from the records alone.
    public var collectedFiles = Set<String>()
    /// Where the next file check starts in this device's photos (see `repairFiles`).
    public var repairCursor = 0

    public init(device: String) {
        clock = SyncClock(device: device)
    }

    private enum CodingKeys: String, CodingKey {
        case version, clock, account, replica, base, dirty, tags, token, collectedFiles, repairCursor
    }

    /// A file from an earlier build lacks the newer fields: they start empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        clock = try c.decode(SyncClock.self, forKey: .clock)
        account = try c.decodeIfPresent(String.self, forKey: .account)
        replica = try c.decode(SyncReplica.self, forKey: .replica)
        base = try c.decodeIfPresent(AppState.self, forKey: .base)
        dirty = try c.decode(Set<String>.self, forKey: .dirty)
        tags = try c.decode([String: String].self, forKey: .tags)
        token = try c.decodeIfPresent(SyncToken.self, forKey: .token)
        collectedFiles = try c.decodeIfPresent(Set<String>.self, forKey: .collectedFiles) ?? []
        // Only ever written in range; a damaged value starts the checks from the first photo (D24-05).
        repairCursor = max(0, try c.decodeIfPresent(Int.self, forKey: .repairCursor) ?? 0)
    }

    func encoded() throws -> Data { try SyncCoding.encoder().encode(self) }

    static func decode(_ data: Data) -> SyncDeviceState? {
        if case .valid(let state) = read(data) { return state }
        return nil
    }

    enum Read {
        case valid(SyncDeviceState)
        /// Written by a newer version: kept, never replaced by this one.
        case newer
        case unreadable
    }

    private struct VersionProbe: Decodable { let version: Int }

    /// The version is read on its own first: a newer version may have changed everything else.
    static func read(_ data: Data) -> Read {
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data), probe.version > currentVersion { return .newer }
        guard var state = try? SyncCoding.decoder().decode(SyncDeviceState.self, from: data),
              state.version <= currentVersion else { return .unreadable }
        if state.replica.readHeldBack() { state.token = nil }
        return .valid(state)
    }
}

public struct SyncReport: Sendable, Equatable {
    public var sent = 0
    public var received = 0
    /// The library changed.
    public var applied = false
    /// Photos whose copy could not be downloaded yet.
    public var waitingForFiles = 0
    /// Photos whose every copy arrived damaged or can't be read by this device: not waiting, and
    /// not downloaded again while the app runs. The next launch tries once more.
    public var unusableFiles = 0
    /// Links on pieces whose photo or observation has not arrived.
    public var pendingLinks: [String: Int] = [:]
    /// Pieces whose model only a newer version of the app has.
    public var piecesFromNewerVersion: Set<String> = []
    /// Photos here that are on those pieces.
    public var photosOnNewerPieces: Set<String> = []
    /// Records this device does not show as merged; what they describe stays as it is here.
    public var heldBack: [String] = []
    /// The part of `heldBack` a newer version of the app would not explain: records that could
    /// not be read (values out of range) or that clash with others here
    /// (`SyncProjectionResult.quarantined`). The interface must not tell the user to update.
    public var quarantined: [String] = []
    /// Records still to send.
    public var unsent = 0
    /// What stopped part of the cycle; the rest of the cycle still ran where it could.
    public var problem: SyncTransportError?
    /// Photos whose file this device could not get into the cloud this cycle (the cloud refused
    /// it, or this device's stored copy cannot be read). Their records wait here, counted in
    /// `unsent`; a full iCloud is not counted (it has its own problem, `quotaExceeded`).
    public var photosNotUploaded = 0
    /// Cloud files clean-up left in place this cycle because it would have deleted an unusually
    /// large share of them at once (`SyncSession.largeCleanup`); they go once the deletion is a
    /// week old. Space is taken meanwhile, nothing is lost.
    public var cleanupHeld = 0
    /// The library committed a deletion (from another device, or one this device made earlier)
    /// but its local files are not all removed yet. The store retries on its next read or write
    /// and on the next launch; until then the deleted photo's files are still on this device.
    public var localCleanupPending = false
    /// Sync's own file could not be written at the end of `deleteHomeInCloud`. What the report
    /// says about the cloud stands; the file on disk is one write behind (it still lists as
    /// unsent records the cloud already has, and the next cycle sends them again, harmlessly).
    public var localStateUnsaved = false
}

extension SyncTransportError {
    /// An error about one file only: the photo waits, the rest of the cycle goes on. Any
    /// other error means the cloud cannot be used right now.
    var concernsOneFile: Bool {
        switch self {
        case .quotaExceeded, .missingFile, .rejected: true
        case .offline, .signedOut, .accountChanged, .cloudDataDeleted, .retryLater: false
        }
    }
}

/// First come, first served, for one actor's async sections; the owning actor keeps it safe.
/// Leaving hands the lock straight to the next waiter.
struct AsyncLock {
    var busy = false
    var waiters: [CheckedContinuation<Void, Never>] = []

    var waiting: Int { waiters.count }

    mutating func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

public actor SyncSession {
    private let store: LibraryStore
    private let transport: any SyncTransport
    private let catalog: FurnitureCatalog?
    private let now: @Sendable () -> Date
    private let deviceID: String
    private let log = Logger(subsystem: "app.meowverse", category: "sync")
    static let batchSize = 200
    /// A deleted photo's files stay in the cloud this long, for an edit made elsewhere before
    /// the deletion arrived to bring the photo back with them.
    public static let fileGrace: TimeInterval = 24 * 3600
    /// Photos whose cloud files one cycle checks.
    static let repairBatch = 20
    /// Cloud files one cycle deletes at most.
    static let collectLimit = 50
    /// A clean-up of at least this many files that is also more than half of all copies the
    /// records name waits until the deletions are `largeCleanupGrace` old.
    static let largeCleanupFloor = 20
    static let largeCleanupGrace: TimeInterval = 7 * 24 * 3600

    // One writer at a time. The actor alone does not give that: every `await` lets another call
    // in, and a cycle holds its copy of sync's file across the network. Cycles, captures and
    // starting over run one after another; any read-modify-write of the file holds `file`,
    // never across the network. A setting written while a cycle is out goes into every write
    // that cycle still makes.
    private var cycleLock = AsyncLock()
    private var fileLock = AsyncLock()
    private var settingsMeanwhile: [String: SyncRegister<String?>] = [:]
    /// Set by `close`: nothing more runs in this session.
    private var closed = false
    /// Files that arrived but can't be used, by hash; not downloaded again by this session.
    private var unusable = Set<String>()
    /// Cloud copies checked whole by clean-up (`isSound`), by hash; not fetched again.
    private var soundFiles = Set<String>()
    /// The running cycle's clock, so a setting written meanwhile is stamped after what it saw.
    private var cycleClock: SyncClock?

    /// Callers waiting for the cycle that runs (tests read it).
    var waitingCycles: Int { cycleLock.waiting }

    private func lockCycle() async {
        guard cycleLock.busy else { cycleLock.busy = true; return }
        await withCheckedContinuation { cycleLock.waiters.append($0) }
    }

    private func unlockCycle() {
        settingsMeanwhile = [:]
        cycleClock = nil
        cycleLock.leave()
    }

    private func lockFile() async {
        guard fileLock.busy else { fileLock.busy = true; return }
        await withCheckedContinuation { fileLock.waiters.append($0) }
    }

    private func unlockFile() { fileLock.leave() }

    /// Every call that reads or writes sync's file starts here, after taking its lock: once the
    /// session is closed it does nothing.
    private func checkOpen() throws {
        if closed { throw CancellationError() }
    }

    /// The session was closed, or the task running the cycle was cancelled (a push's or the
    /// background's time ran out): the cycle stops at its next step, before it changes the
    /// library. Carrying on would only fail every call and report the cloud as busy.
    private var stopped: Bool { closed || Task.isCancelled }

    private func stopIfAsked() throws {
        if stopped { throw CancellationError() }
    }

    /// Writes the cycle's copy of sync's file, with any setting written meanwhile.
    private func save(_ device: inout SyncDeviceState, _ generation: UUID) async throws {
        await lockFile()
        defer { unlockFile() }
        absorbSettings(&device)
        try await store.writeSyncState(try device.encoded(), generation: generation)
    }

    private func absorbSettings(_ device: inout SyncDeviceState) {
        defer { cycleClock = device.clock }
        guard !settingsMeanwhile.isEmpty else { return }
        var home = device.replica.home
        for (key, register) in settingsMeanwhile {
            home.settings[key] = home.settings[key].map { $0.joined(register) } ?? register
            device.clock.observe(register.stamp)
        }
        if device.replica.merge(.home(home)) { device.dirty.insert(SyncRecord.home(home).name) }
    }

    /// `deviceID` only for tests; a device otherwise makes a random one on its first sync.
    public init(store: LibraryStore, transport: any SyncTransport, catalog: FurnitureCatalog? = nil,
                deviceID: String = SyncClock.newDeviceID(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.transport = transport
        self.catalog = catalog
        self.deviceID = deviceID
        self.now = now
    }

    /// One full cycle. A local edit during the cycle is captured and the cycle built again.
    /// A call while another cycle runs waits for it, then runs its own.
    @discardableResult
    public func sync() async throws -> SyncReport {
        await lockCycle()
        defer { unlockCycle() }
        var attempt = 0
        while true {
            try stopIfAsked()
            do {
                return try await cycle()
            } catch SyncApplyError.localChanged where attempt < 4 {
                attempt += 1
            } catch SyncApplyError.libraryReplaced where attempt < 4 {
                // Reopened from an older copy meanwhile: the store rebased sync's file onto it,
                // so start again on that. A restore or a clear left no file: going on would be a
                // first sync on the new library, under whatever account is signed in, which
                // brought a cleared home back from the cloud (audit round 12, SYNC-1). What
                // happens to that library is the app's call (its fresh start checks the account
                // first; clearing turned sync off).
                try stopIfAsked()
                guard try await storedDevice() != nil else { throw SyncApplyError.libraryReplaced }
                attempt += 1
            }
        }
    }

    /// Ends this session for good: sync turned off, or the library is about to be cleared.
    /// The cycle running now stops at its next step, before it changes the library, and every
    /// call after this one (a cycle, a capture, starting over) does nothing and throws
    /// `CancellationError`. Returns only once nothing of this session runs any more, so the
    /// caller can then switch the library knowing no cycle carries on into the new one.
    /// `forgetting` then replaces sync's file as `startOver` does (it throws only for that).
    public func close(forgetting: Bool = false) async throws {
        closed = true
        // The cycle out on the network, and every call queued before this one, end first.
        await lockCycle()
        defer { unlockCycle() }
        await lockFile()
        defer { unlockFile() }
        log.notice("sync: session closed")
        if forgetting { try await forget(acceptingCurrentAccount: false, account: nil) }
    }

    /// Forgets everything sync knew (sync turned off, the cloud data deleted, or the user agreed
    /// to use another account). The library is not touched; the next sync merges it as a first.
    /// Which account the home synced with is kept: in another account the next sync stops with
    /// `accountChanged`, until the user's answer passes `acceptingCurrentAccount: true`.
    ///
    /// `account` is the account the caller checked (the one it knows the home synced with, or
    /// the one the user agreed to): the new state is bound to it when the file names none (no
    /// file, an unreadable one), so the next cycle in any other account stops too, instead of
    /// taking whichever account answers (audit AA24-01, CC24-01). With `acceptingCurrentAccount`
    /// it replaces the file's account. An unreadable file and its backup are kept aside (the
    /// `.unreadable` copies); a newer version's file is never replaced (`SyncStateError.newerVersion`).
    ///
    /// `accountChecked: false` says `account` is only the one signed in now, not one checked
    /// against what the home synced with (a new install with no marker that opened its library
    /// from the fallback copy). With an unreadable file that is not enough to bind: it throws
    /// `SyncStateError.unreadable`, writing nothing and leaving the copies where they are, as
    /// `startOnNewInstall` does (QA review round 20, G1, the fallback path).
    public func startOver(acceptingCurrentAccount: Bool = false, account: String? = nil, accountChecked: Bool = true) async throws {
        await lockCycle()
        defer { unlockCycle() }
        try checkOpen()
        await lockFile()
        defer { unlockFile() }
        try await forget(acceptingCurrentAccount: acceptingCurrentAccount, account: account,
                         unreadableNeedsCheck: !accountChecked && !acceptingCurrentAccount)
    }

    /// `startOver` without the locks (the caller holds both).
    private func forget(acceptingCurrentAccount: Bool, account: String?, unreadableNeedsCheck: Bool = false) async throws {
        let (_, generation) = try await store.syncSnapshot()
        let stored = try await storedRead()
        var fresh = SyncDeviceState(device: deviceID)
        switch stored {
        case .newer:
            throw SyncStateError.newerVersion
        case .unreadable:
            if unreadableNeedsCheck {
                log.error("sync: unreadable sync file and no account checked, not started over")
                throw SyncStateError.unreadable
            }
            try await store.setAsideUnreadableSyncState(generation: generation)
        case .valid(let device):
            if !acceptingCurrentAccount { fresh.account = device.account }
        case .absent:
            break
        }
        fresh.account = fresh.account ?? account
        try await store.writeSyncState(try fresh.encoded(), generation: generation)
        // Turned off: downloads waiting to be shown are not kept.
        await store.pruneSyncIncoming(keeping: nil)
    }

    public enum InstallStart: Sendable, Equatable {
        /// Goes on from the sync file the library carried, under a new device id.
        case kept
        /// Nothing to go on from: started over, as `startOver` does.
        case startedOver
    }

    /// The start on an install that never synced this library before, with sync on: a phone set
    /// up from another phone's device backup. The backup carries the library and sync's file in
    /// it, but not the app's own sync folder (kept out of device backups). Starting over there
    /// dropped the edits the old phone recorded but never sent, and its first sync brought back,
    /// on every device, whatever was deleted elsewhere after the backup (a first sync deletes
    /// nothing; audit round 12, FAMILY-1). Going on from the file keeps both right: the unsent
    /// edits go out, and deletions made since arrive over versions the copy had seen.
    ///
    /// It goes on under a new device id, as `checkOwnId` would once it heard the old phone: two
    /// installs under one id would hide each other's unseen edits behind their deletions. The
    /// file's account is kept, so in another account the next cycle stops with `accountChanged`.
    /// Starts over only when there is no file, or the one there is from before any sync.
    ///
    /// Both copies there and neither readable throws `SyncStateError.unreadable`, writing
    /// nothing and leaving them where they are: the account the home synced with is in there,
    /// and a new install has nothing else to check it against (no marker of its own). Starting
    /// over took whichever account answered (QA review round 20, G1, the new-install side of
    /// AA24-01). Only the user's explicit answer goes on (`startOver(acceptingCurrentAccount:)`).
    public func startOnNewInstall() async throws -> InstallStart {
        await lockCycle()
        defer { unlockCycle() }
        try checkOpen()
        await lockFile()
        defer { unlockFile() }
        let (snapshot, generation) = try await store.syncSnapshot()
        let stored = try await storedRead()
        if case .unreadable = stored {
            log.error("sync: new install with an unreadable sync file, not started over")
            throw SyncStateError.unreadable
        }
        // A newer version's file is left alone (`forget` throws).
        guard case .valid(var device) = stored, device.base != nil else {
            try await forget(acceptingCurrentAccount: false, account: nil)
            log.notice("sync: new install with nothing to go on from, started over")
            return .startedOver
        }
        device.clock = device.clock.renamed(newOwnId(replacing: device.clock.device))
        // The library may be ahead of the file's base: edits the old phone saved but never
        // captured before the backup was made. They were made then, not now: stamped at the
        // old phone's last known time, they lose to anything it or another device did later
        // (stamped now, a stale value replaced the old phone's newer edit on every device).
        let then = Date(timeIntervalSince1970: TimeInterval(device.clock.last.wall) / 1000)
        _ = capture(&device, snapshot, at: then)
        // This install's transport has fetched nothing yet: the next fetch starts at the
        // beginning (merging what the file already holds again changes nothing).
        device.token = nil
        try await store.writeSyncState(try device.encoded(), generation: generation)
        log.notice("sync: new install goes on from the library's sync file under a new id")
        return .kept
    }

    /// Whether the library holds sync's file, or the copy before it. A library sync never ran
    /// on, and one a restore or a clear switched in, has neither. A file that cannot be read
    /// still counts: it is there, and `storedDevice` deals with it.
    public static func hasSyncFile(_ store: LibraryStore) async -> Bool {
        if (try? await store.readSyncState()) != nil { return true }
        return (try? await store.readSyncStateBackup()) != nil
    }

    /// An id for this device that is not `old`.
    private func newOwnId(replacing old: String) -> String {
        deviceID != old ? deviceID : "\(old.prefix(32))-\(SyncClock.newDeviceID().prefix(6))"
    }

    /// The user chose to delete the home in iCloud as well (clearing all data with sync on):
    /// every device that syncs ends up with an empty home, as a deletion a first sync does not
    /// undo. The records are brought up to date first; then every photo (shown here or still
    /// waiting for its file), recognition result, piece, room and cat is deleted, and the first
    /// room and cat are put back as an empty library has them. Like any deletion it removes
    /// what this device has seen: an edit made elsewhere that never reached it stays (§4).
    /// The library is not touched; the app clears it next, and its first sync finds only the
    /// deletions. Records a newer build wrote are left as they are.
    ///
    /// Throws, with nothing recorded, when the cloud cannot be reached or another account is
    /// signed in. A report with a problem or `unsent` above zero means the deletions are
    /// recorded but not all sent: the next sync sends the rest, and empties this library too.
    public func deleteHomeInCloud() async throws -> SyncReport {
        await lockCycle()
        defer { unlockCycle() }
        try checkOpen()
        var report = SyncReport()
        let (snapshot, generation) = try await store.syncSnapshot()
        var device = try await storedDevice() ?? SyncDeviceState(device: deviceID)
        let account = try await transport.accountKey()
        if let known = device.account, known != account { throw SyncTransportError.accountChanged }
        device.account = account
        try await fetch(&device, &report)

        let stamp = device.clock.tick(now: now())
        let empty = AppState.empty
        // A photo shown through several records of one stored copy is deleted as an ordinary
        // deletion of it is (`SyncCapture.photos`): each record names the others it was deleted
        // with, held-back ones included, so an unseen edit that brings one back brings the photo
        // back whole (audit 2026-11-24, DD24-01).
        var together: [String: [String]] = [:]
        for group in SyncPhotoGroups(device.replica).groups where group.members.count > 1 {
            let listed = group.names.filter { name in
                guard device.replica.unreadable[name] == nil else { return true }
                return device.replica[name]?.isLive == true
            }
            guard listed.count > 1 else { continue }
            for name in listed { together[name] = listed.sorted() }
        }
        // Records this build cannot read are left as they are (a newer build may have written
        // them): said, so the deletion is not reported as complete (D24-01).
        report.heldBack = device.replica.unreadable.keys.filter { $0 != SyncRecord.home(device.replica.home).name }.sorted()
        for (name, record) in device.replica.records.sorted(by: { $0.key < $1.key }) where device.replica.unreadable[name] == nil {
            let tomb = { SyncTombstone.join(record.tomb, SyncTombstone(seen: record.version, at: stamp, together: together[name])) }
            var next: SyncRecord?
            switch record {
            case .home:
                break
            case .room(var room) where room.roomId == AppState.primaryRoomId:
                let name = empty.allRooms.first?.name
                if room.name.value != name { room.name = SyncRegister(name, stamp); next = SyncRecord.room(room).written(stamp) }
            case .cat(var cat) where cat.catId == AppState.primaryCatId:
                let first = empty.allCats.first
                if cat.name.value != empty.catName { cat.name = SyncRegister(empty.catName, stamp) }
                if cat.roomId.value != first?.roomId { cat.roomId = SyncRegister(first?.roomId, stamp) }
                if .cat(cat) != record { next = SyncRecord.cat(cat).written(stamp) }
            case _ where !record.isLive:
                break
            case .photo(var r): r.tomb = tomb(); next = .photo(r)
            case .observation(var r): r.tomb = tomb(); next = .observation(r)
            case .furniture(var r): r.tomb = tomb(); next = .furniture(r)
            case .room(var r): r.tomb = tomb(); next = .room(r)
            case .cat(var r): r.tomb = tomb(); next = .cat(r)
            }
            if let next, device.replica.merge(next) { device.dirty.insert(name) }
        }
        // Whatever the library holds now is not an edit to send after this: if clearing it
        // fails, the next cycle empties it from the records instead of bringing anything back.
        device.base = snapshot
        try await save(&device, generation)
        do { try await push(&device, snapshot, &report) } catch let error as SyncTransportError {
            report.problem = report.problem ?? error
        }
        report.unsent = device.dirty.count
        // What went out is in the cloud whatever happens here: a failed write of sync's own file
        // is said, not thrown as if nothing were deleted anywhere (C24-06). The file on disk is
        // the one saved before sending, with every deletion in it: the next cycle resends them.
        do { try await save(&device, generation) } catch {
            report.localStateUnsaved = true
            log.error("sync: home deleted in the cloud, sync's own file not saved")
        }
        log.notice("sync: home deleted in the cloud, unsent=\(report.unsent, privacy: .public) held=\(report.heldBack.count, privacy: .public)")
        return report
    }

    /// For the interface before a cycle has run or while there is no network: nil until this
    /// device has synced.
    public func standing() async -> SyncStanding? {
        guard let device = try? await storedDevice(), device.base != nil,
              let (snapshot, _) = try? await store.syncSnapshot() else { return nil }
        let projection = SyncProjection.project(device.replica, local: snapshot, catalog: catalog)
        var standing = SyncStanding()
        standing.pendingLinks = projection.pendingLinks
        standing.piecesFromNewerVersion = projection.piecesFromNewerVersion
        standing.photosOnNewerPieces = projection.photosOnNewerPieces
        return standing
    }

    /// A cycle that ends before its projection still says what the records it has already say.
    private func noteStanding(_ report: inout SyncReport, _ device: SyncDeviceState, _ snapshot: AppState) {
        guard device.base != nil else { return }
        let projection = SyncProjection.project(device.replica, local: snapshot, catalog: catalog)
        report.pendingLinks = projection.pendingLinks
        report.piecesFromNewerVersion = projection.piecesFromNewerVersion
        report.photosOnNewerPieces = projection.photosOnNewerPieces
    }

    public func deviceState() async throws -> SyncDeviceState? {
        try await storedDevice()
    }

    /// Sync's own file, or the one before it when it cannot be read (damaged, or a crash in the
    /// middle of replacing it). nil only when there is neither: a first sync. Files that are
    /// there but none can be read, or a newer version's, throw (`SyncStateError`); a read that
    /// fails throws the store's error. None of them is taken for "no file".
    private func storedDevice() async throws -> SyncDeviceState? {
        switch try await storedRead() {
        case .absent: return nil
        case .valid(let device): return device
        case .newer: throw SyncStateError.newerVersion
        case .unreadable: throw SyncStateError.unreadable
        }
    }

    private enum Stored {
        case absent, valid(SyncDeviceState), newer, unreadable
    }

    private func storedRead() async throws -> Stored {
        let primary = try await store.readSyncState()
        if let primary {
            switch SyncDeviceState.read(primary) {
            case .valid(let device): return .valid(device)
            case .newer: return .newer
            case .unreadable: break
            }
        }
        let backup = try await store.readSyncStateBackup()
        if let backup {
            switch SyncDeviceState.read(backup) {
            case .valid(let device):
                log.error("sync: own file unreadable, using the previous one")
                return .valid(device)
            case .newer: return .newer
            case .unreadable: break
            }
        }
        if primary == nil, backup == nil { return .absent }
        log.error("sync: own file and the previous one unreadable")
        return .unreadable
    }

    /// Records this device's edits without the network, so they are ordered by when they were
    /// made and not by when the device was next online. Call after each save. Does nothing
    /// before the first sync, which needs the cloud's records first. While a cycle runs this
    /// waits for it (the cycle captures what it finds when it starts or starts again).
    public func captureLocalEdits() async throws {
        await lockCycle()
        defer { unlockCycle() }
        try checkOpen()
        await lockFile()
        defer { unlockFile() }
        let (snapshot, generation) = try await store.syncSnapshot()
        guard var device = try await storedDevice(), device.base != nil else { return }
        guard capture(&device, snapshot) else { return }
        try await store.writeSyncState(try device.encoded(), generation: generation)
    }

    /// Records a setting that follows the user to their other devices (the app picks the keys,
    /// docs/ICLOUD_SYNC.md); sent on the next sync. Before the first sync there is nothing to
    /// merge with yet: returns false, and the app passes its current values again after it.
    /// Does not wait for a cycle out on the network: the cycle keeps the setting in what it writes.
    @discardableResult
    public func setSetting(_ key: String, _ value: String?) async throws -> Bool {
        await lockFile()
        defer { unlockFile() }
        guard !closed else { return false }
        let (_, generation) = try await store.syncSnapshot()
        guard var device = try await storedDevice(), device.base != nil else { return false }
        if let running = cycleClock { device.clock.observe(running.last) }
        var home = device.replica.home
        if let old = home.settings[key], old.value == value, settingsMeanwhile[key] == nil { return true }
        let register = SyncRegister(value, device.clock.tick(now: now()))
        home.settings[key] = register
        if device.replica.merge(.home(home)) { device.dirty.insert(SyncRecord.home(home).name) }
        try await store.writeSyncState(try device.encoded(), generation: generation)
        if cycleLock.busy { settingsMeanwhile[key] = register }
        return true
    }

    /// The synced settings as merged so far; nil values were cleared on some device.
    public func settings() async throws -> [String: String?] {
        guard let device = try await storedDevice() else { return [:] }
        return device.replica.home.settings.mapValues(\.value)
    }

    /// Returns false when there was nothing to record. `at` stamps the edits at another time
    /// than now (see `startOnNewInstall`).
    private func capture(_ device: inout SyncDeviceState, _ snapshot: AppState, at time: Date? = nil) -> Bool {
        guard device.base != snapshot else { return false }
        if let base = device.base, snapshot.revision < base.revision {
            // The library is older than what sync last saw (opened from its backup; the store
            // normally rebases sync when that happens). Nothing in the gap is the user's doing:
            // start from the library as it is, and let the records bring the newer state back.
            log.notice("sync: library older than sync's base, rebased")
            device.base = snapshot
            return true
        }
        // What sync would have made of the library it last saw: a field (or a deletion) that
        // already matches it is a remote change sync applied, not an edit.
        let before = SyncProjection.project(device.replica, local: device.base ?? snapshot, catalog: catalog).state
        let changed = SyncCapture.capture(base: device.base, current: snapshot, projected: before, catalog: catalog,
                                          into: &device.replica, clock: &device.clock, now: time ?? now())
        device.dirty.formUnion(changed)
        device.base = snapshot
        return true
    }

    private func cycle() async throws -> SyncReport {
        var report = SyncReport()
        let (snapshot, generation) = try await store.syncSnapshot()
        var device = try await storedDevice() ?? SyncDeviceState(device: deviceID)
        // Edits are on disk before anything is sent; offline they wait there.
        if device.base != nil, capture(&device, snapshot) {
            try await save(&device, generation)
        }

        let account: String
        do { account = try await transport.accountKey() } catch let error as SyncTransportError {
            report.problem = error
            report.unsent = device.dirty.count
            noteStanding(&report, device, snapshot)
            return report
        }
        try stopIfAsked()
        if let known = device.account, known != account {
            report.problem = .accountChanged
            noteStanding(&report, device, snapshot)
            return report
        }
        device.account = account

        // Turning sync on: see everything first, so this device adds to the cloud's records.
        var offeredNotes: [String: SyncRegister<String>] = [:]
        if device.base == nil {
            do { try await fetch(&device, &report) } catch let error as SyncTransportError {
                report.problem = error
                return report
            }
            try stopIfAsked()
            let before = SyncProjection.project(device.replica, local: snapshot, catalog: catalog).state
            device.dirty.formUnion(SyncCapture.capture(base: nil, current: snapshot, projected: before, catalog: catalog,
                                                       into: &device.replica, clock: &device.clock, now: now()))
            // The notes this first sync offers, for a save that meets another first sync (C24-04).
            for name in device.dirty {
                if case .photo(let photo) = device.replica[name] { offeredNotes[name] = photo.note }
            }
            device.base = snapshot
            try await save(&device, generation)
        }

        var fetched = false
        do {
            try await push(&device, snapshot, &report, offeredNotes: offeredNotes)
            try await fetch(&device, &report)
            fetched = true
        } catch let error as SyncTransportError {
            report.problem = report.problem ?? error
        }
        try stopIfAsked()
        cycleClock = device.clock
        // Files are only judged on a view fresh from the server.
        if fetched {
            await repairFiles(&device, snapshot, &report)
            await collectFiles(&device, &report)
        }

        var projection = SyncProjection.project(device.replica, local: snapshot, catalog: catalog)
        let downloaded = await arrivedFiles(projection.missingFiles, online: report.problem != .offline, generation: generation)
        if !downloaded.isEmpty {
            projection = SyncProjection.project(device.replica, local: snapshot, downloaded: downloaded, catalog: catalog)
        }
        report.unusableFiles = projection.missingFiles.count { copies in
            let fetchable = copies.filter { BackupArchive.isHash($0.sha256) }
            return !fetchable.isEmpty && fetchable.allSatisfy { unusable.contains($0.sha256) }
        }
        report.waitingForFiles = projection.missingFiles.count - report.unusableFiles
        report.pendingLinks = projection.pendingLinks
        report.piecesFromNewerVersion = projection.piecesFromNewerVersion
        report.photosOnNewerPieces = projection.photosOnNewerPieces
        report.heldBack = projection.heldBack
        report.quarantined = projection.quarantined
        try stopIfAsked()
        // From here to the end the file is this cycle's: a setting written meanwhile waits.
        await lockFile()
        defer { unlockFile() }
        absorbSettings(&device)
        report.unsent = device.dirty.count

        if projection.state != snapshot || !projection.writes.isEmpty {
            // What was fetched is on disk before the library changes: if the app dies between
            // the two writes, the next capture sees the library matches these records and does
            // not take the remote changes for this device's own, newer edits.
            try await store.writeSyncState(try device.encoded(), generation: generation)
            let settled = device
            do {
                _ = try await store.applySynced(projection.state, ifRevision: snapshot.revision, generation: generation,
                                                writes: projection.writes) { committed in
                    var next = settled
                    next.base = committed
                    return try next.encoded()
                }
            } catch SyncApplyError.localChanged {
                // Keep what was learned; `base` is still the snapshot, so the new edit is captured.
                try await store.writeSyncState(try device.encoded(), generation: generation)
                throw SyncApplyError.localChanged
            }
            report.applied = true
        } else {
            try await store.writeSyncState(try device.encoded(), generation: generation)
        }
        // A deletion committed whose local files are not all removed yet (the store retries):
        // the cycle is not reported as if they were gone (audit 2026-11-24, DD24-03).
        report.localCleanupPending = await store.deletionPending
        // Staged copies this cycle wrote are gone; the rest stay only while still waited for.
        await store.pruneSyncIncoming(keeping: Set(projection.missingFiles.flatMap { $0.map(\.sha256) }))
        log.info("sync: sent=\(report.sent, privacy: .public) received=\(report.received, privacy: .public) applied=\(report.applied, privacy: .public) waiting=\(report.waitingForFiles, privacy: .public)")
        return report
    }

    /// For each photo still to come (its copies, best first), a copy it can be shown with: one
    /// staged by an earlier attempt or cycle, else downloaded now, checked and staged on disk
    /// before the next download starts (one file in memory at a time).
    /// Staged only into the library `generation` names: a download that returns after a restore
    /// or a clear writes nothing into the new library (DD24-02).
    private func arrivedFiles(_ missing: [[SyncFileInfo]], online: Bool, generation: UUID) async -> [String: SyncIncomingFile] {
        var arrived: [String: SyncIncomingFile] = [:]
        next: for copies in missing {
            for info in copies {
                if let staged = await store.stagedSyncedFile(info) {
                    arrived[info.sha256] = staged
                    continue next
                }
            }
            guard online, !stopped else { continue }
            for info in copies where BackupArchive.isHash(info.sha256) && !unusable.contains(info.sha256) {
                let data: Data
                do {
                    data = try await transport.downloadFile(sha256: info.sha256)
                } catch SyncTransportError.rejected {
                    // It came, and isn't what its name says.
                    unusable.insert(info.sha256)
                    continue
                } catch {
                    continue // not there yet, or the cloud can't be reached: it waits
                }
                guard let thumbnail = SyncIncomingFile.thumbnail(of: data, for: info) else {
                    unusable.insert(info.sha256)
                    log.error("sync: a downloaded photo file can't be used here")
                    continue
                }
                guard let file = try? await store.stageSyncedFile(data, thumbnailJPEG: thumbnail, info: info, generation: generation) else { continue }
                arrived[info.sha256] = file
                break
            }
        }
        return arrived
    }

    /// Sends dirty records, the file first for a photo whose copy is this device's. A conflict
    /// is merged and sent again (up to three rounds); a record the server already holds as
    /// merged is no longer dirty. `offeredNotes`: on the cycle that turns sync on, the photo
    /// notes it offered (see `SyncCapture.concurrentFirstSyncNote`).
    private func push(_ device: inout SyncDeviceState, _ local: AppState, _ report: inout SyncReport,
                      offeredNotes: [String: SyncRegister<String>] = [:]) async throws {
        var offeredNotes = offeredNotes
        let localFiles = Dictionary(local.photos.map { ($0.sha256, $0.photoId) }, uniquingKeysWith: { a, _ in a })
        var blocked = Set<String>()
        for _ in 0..<3 {
            let names = device.dirty.subtracting(blocked).sorted()
            guard !names.isEmpty else { return }
            var saves: [SyncSave] = []
            var uploaded: [String: (sha256: String, photoId: String)] = [:]
            for name in names {
                guard device.replica.unreadable[name] == nil, let record = device.replica[name] else {
                    device.dirty.remove(name)
                    continue
                }
                if case .photo(let photo) = record, record.isLive,
                   let mine = photo.copies.first(where: { localFiles[$0.sha256] != nil }), let photoId = localFiles[mine.sha256] {
                    try stopIfAsked()
                    do {
                        // The file goes before the record that points at it. This device's copy
                        // goes when it is the best, or when the best is not in the cloud (the
                        // photo came back after its files were removed).
                        let needed = mine == photo.file ? true : try await !transport.hasFile(sha256: photo.file.sha256)
                        if needed, try await !transport.hasFile(sha256: mine.sha256) {
                            guard let url = await store.originalURL(photoId: photoId), let data = try? Data(contentsOf: url),
                                  PhotoIngest.sha256Hex(data) == mine.sha256 else {
                                // This device's copy is missing or damaged: the photo waits
                                // here, and the user is told; everything else still goes.
                                log.error("sync: a photo's stored copy cannot be read for upload")
                                report.problem = report.problem ?? .rejected("localCopy")
                                report.photosNotUploaded += 1
                                blocked.insert(name)
                                continue
                            }
                            try await transport.uploadFile(sha256: mine.sha256, data: data)
                            device.collectedFiles.remove(mine.sha256)
                            uploaded[name] = (mine.sha256, photoId)
                        }
                    } catch let error as SyncTransportError where error.concernsOneFile {
                        // The photo waits here (a full iCloud, or this file refused); everything
                        // else still goes, and the fetch still runs.
                        report.problem = error == .quotaExceeded ? error : report.problem ?? error
                        if error != .quotaExceeded { report.photosNotUploaded += 1 }
                        blocked.insert(name)
                        continue
                    }
                }
                saves.append(SyncSave(envelope: try SyncEnvelope(record), baseTag: device.tags[name]))
            }
            for start in stride(from: 0, to: saves.count, by: Self.batchSize) {
                var batch = Array(saves[start..<min(start + Self.batchSize, saves.count)])
                // A file this push put up may already be gone again: removed by a device that
                // judged on records alone and had not heard of the photo coming back. Checked
                // once more right before its record goes, and put up again if so.
                for index in batch.indices.reversed() {
                    let name = batch[index].envelope.name
                    guard let file = uploaded[name] else { continue }
                    do {
                        // The cloud itself, not an answer remembered from the upload (D24-02).
                        guard try await !transport.confirmFile(sha256: file.sha256) else { continue }
                        guard let url = await store.originalURL(photoId: file.photoId), let data = try? Data(contentsOf: url),
                              PhotoIngest.sha256Hex(data) == file.sha256 else { throw SyncTransportError.rejected("localCopy") }
                        try await transport.uploadFile(sha256: file.sha256, data: data)
                        log.notice("sync: a file was removed before its record was sent; uploaded again")
                    } catch let error as SyncTransportError where error.concernsOneFile {
                        report.problem = error == .quotaExceeded ? error : report.problem ?? error
                        if error != .quotaExceeded { report.photosNotUploaded += 1 }
                        blocked.insert(name)
                        batch.remove(at: index)
                    }
                }
                for result in try await transport.save(batch) {
                    switch result {
                    case .saved(let name, let tag):
                        device.tags[name] = tag
                        device.dirty.remove(name)
                        report.sent += 1
                    case .conflict(let server):
                        let name = server.envelope.name
                        device.tags[name] = server.tag
                        if let theirs = server.envelope.decoded() {
                            checkOwnId(theirs, &device)
                            device.clock.observe(theirs.newestStamp)
                        }
                        let mine = device.replica[name]
                        device.replica.merge(server.envelope)
                        // Another first sync got there first with its own note: both are kept,
                        // as two parts, when both are still what the two first syncs offered.
                        if let offered = offeredNotes[name], case .photo(let was)? = mine, was.note == offered,
                           case .photo(let theirs)? = server.envelope.decoded(),
                           let both = SyncCapture.concurrentFirstSyncNote(theirs.note, offered),
                           device.replica.unreadable[name] == nil, case .photo(var merged)? = device.replica[name] {
                            merged.note = both
                            device.replica.merge(SyncRecord.photo(merged).written(device.clock.tick(now: now())))
                            offeredNotes[name] = both
                        }
                        if server.envelope.decoded() == device.replica[name] { device.dirty.remove(name) }
                    case .failed(let name, let error):
                        blocked.insert(name)
                        report.problem = report.problem ?? error
                    }
                }
            }
        }
    }

    private func fetch(_ device: inout SyncDeviceState, _ report: inout SyncReport) async throws {
        var token = device.token
        while true {
            try stopIfAsked()
            let page = try await transport.fetchChanges(since: token)
            for server in page.records {
                let name = server.envelope.name
                if let record = server.envelope.decoded() {
                    checkOwnId(record, &device)
                    device.clock.observe(record.newestStamp)
                }
                if device.replica.merge(server.envelope) { report.received += 1 }
                // The merge holds the server's version, so the next save may replace it.
                device.tags[name] = server.tag
                // A server version that is what this device holds needs no resend.
                if server.envelope.decoded() == device.replica[name] { device.dirty.remove(name) }
            }
            token = page.token
            if !page.moreComing { break }
        }
        device.token = token
    }

    /// A write under this device's id that its clock never reached was made by another install
    /// with the same id (a phone set up from this one's device backup carries its sync file).
    /// Sharing an id, either one's deletions would hide the other's unseen edits as seen; from
    /// here on this device writes under a new id. Only once sync has a base: a first sync
    /// fetches this id's earlier writes, which a fresh clock has not reached either.
    private func checkOwnId(_ record: SyncRecord, _ device: inout SyncDeviceState) {
        let old = device.clock.device
        guard device.base != nil, let stamp = record.newestStamp(of: old), stamp > device.clock.last else { return }
        device.clock = device.clock.renamed(newOwnId(replacing: old))
        log.error("sync: another install writes under this device's id; this one takes a new id")
    }

    /// Deletes from the cloud the copies nobody needs, judged on the records alone so that any
    /// device does it (the one that uploaded a file may be gone, or may have started over):
    /// those of photos deleted more than `fileGrace` ago, and a copy no longer the best once
    /// the best is there. A copy any live photo still has is kept; so is everything while
    /// records this build cannot read are held back, since they may name copies too.
    ///
    /// Because a view can be wrong, three more guards: a file the cloud stored within
    /// `fileGrace` stays (a photo coming back uploads its file before its record arrives); a
    /// deleted photo that a live piece links to under a write its record has not heard of
    /// keeps its files (this view missed the version that brought it back); and one cycle
    /// deletes at most `collectLimit` files, none at all of an unusually large share
    /// (`largeCleanup`) until that deletion is a week old, reported in `cleanupHeld`.
    private func collectFiles(_ device: inout SyncDeviceState, _ report: inout SyncReport) async {
        guard device.replica.unreadable.isEmpty, !stopped else { return }
        let photos = device.replica.photos.sorted(by: { $0.sourceHash < $1.sourceHash })
        let comingBack = Self.photosLinkedUnheard(device.replica)
        // A deleted record shown again with a live one of its stored copy (`SyncPhotoGroups`)
        // is part of a photo shown: its copies, and the best of the whole photo's, stay
        // (audit 2026-11-24, C24-01).
        var shown = Set<String>(), groupBest = Set<String>()
        for group in SyncPhotoGroups(device.replica).groups {
            shown.formUnion(group.members.map(\.sourceHash))
            groupBest.insert(group.merged.file.sha256)
        }
        func kept(_ record: PhotoSyncRecord) -> Bool {
            SyncRecord.photo(record).isLive || comingBack.contains(record.sourceHash) || shown.contains(record.sourceHash)
        }
        let live = photos.filter(kept)
        let best = Set(live.map(\.file.sha256)).union(groupBest), inUse = Set(live.flatMap { $0.copies.map(\.sha256) })
        var soundChecks = 0
        let nowDate = now()
        let cutoff = SyncClock.millis(nowDate.addingTimeInterval(-Self.fileGrace))
        var unneeded = Set<String>()
        var deletedAt: [String: Int64] = [:]
        for record in photos {
            if kept(record) {
                let extra = record.copies.map(\.sha256).filter { !best.contains($0) }
                guard !extra.isEmpty else { continue }
                if Set(extra).isSubset(of: device.collectedFiles) {
                    unneeded.formUnion(extra)
                    continue
                }
                guard (try? await transport.hasFile(sha256: record.file.sha256)) == true,
                      await isSound(record.file, checks: &soundChecks) else { continue }
                unneeded.formUnion(extra)
            } else if let tomb = record.tomb, tomb.at.wall <= cutoff {
                for sha in record.copies.map(\.sha256) where !inUse.contains(sha) {
                    unneeded.insert(sha)
                    deletedAt[sha] = max(deletedAt[sha] ?? 0, tomb.at.wall)
                }
            }
        }
        // A file needed again (a photo back) is deleted again when it is unneeded once more.
        device.collectedFiles.formIntersection(unneeded)
        var due = unneeded.subtracting(device.collectedFiles).sorted()
        let named = Set(photos.flatMap { $0.copies.map(\.sha256) })
        if Self.largeCleanup(due.count, of: named.count) {
            // Rather more space taken than a wrong view emptying the cloud: only what was
            // deleted a week ago or more goes, and the rest is reported.
            let weekAgo = SyncClock.millis(nowDate.addingTimeInterval(-Self.largeCleanupGrace))
            let ready = due.filter { (deletedAt[$0] ?? .max) <= weekAgo }
            report.cleanupHeld = due.count - ready.count
            log.notice("sync: clean-up of \(due.count, privacy: .public) of \(named.count, privacy: .public) files held")
            due = ready
        }
        var deleted = 0
        for sha in due where deleted < Self.collectLimit {
            // An answer that failed is not "the cloud can't tell": the file waits for one
            // (audit 2026-11-24, D24-03).
            let stored: Date?
            do { stored = try await transport.fileStoredAt(sha256: sha) } catch { continue }
            if let stored, stored > nowDate.addingTimeInterval(-Self.fileGrace) { continue }
            guard (try? await transport.deleteFile(sha256: sha)) != nil else { continue }
            device.collectedFiles.insert(sha)
            deleted += 1
        }
    }

    /// Whether the cloud's copy of `info` is whole: fetched and checked against its name before
    /// a lesser copy is deleted for it. A best copy stored damaged would otherwise pass for one
    /// that is there, and the sound copies devices fall back to would go (audit 2026-11-24,
    /// C24-07). A few checks per cycle; a copy found sound is not fetched again this session,
    /// and one found damaged is kept as unusable. Any other failure: not now.
    private func isSound(_ info: SyncFileInfo, checks: inout Int) async -> Bool {
        if soundFiles.contains(info.sha256) { return true }
        guard !unusable.contains(info.sha256), checks < Self.repairBatch, !stopped else { return false }
        checks += 1
        let data: Data
        do { data = try await transport.downloadFile(sha256: info.sha256) } catch SyncTransportError.rejected {
            unusable.insert(info.sha256)
            return false
        } catch {
            return false
        }
        guard data.count == info.byteSize, PhotoIngest.sha256Hex(data) == info.sha256 else {
            unusable.insert(info.sha256)
            log.error("sync: the cloud's best copy of a photo is damaged; its other copies stay")
            return false
        }
        soundFiles.insert(info.sha256)
        return true
    }

    /// One cycle's clean-up is unusually large: at least `largeCleanupFloor` files and more
    /// than half of all the copies the records name.
    static func largeCleanup(_ count: Int, of named: Int) -> Bool {
        count >= largeCleanupFloor && count * 2 > named
    }

    /// Source hashes of deleted photos that a live piece links to under a write the photo's
    /// record has not heard of. Linking a photo also writes its record (`SyncCapture.touch`, the
    /// same stamp), so in a whole view such a photo is live: here a version is missing.
    static func photosLinkedUnheard(_ replica: SyncReplica) -> Set<String> {
        var recordOf: [String: PhotoSyncRecord] = [:]
        for record in replica.photos { for id in record.photoIds { recordOf[id] = record } }
        var out = Set<String>()
        for piece in replica.furniture where SyncRecord.furniture(piece).isLive {
            for (photoId, link) in piece.links where link.value != nil {
                guard let photo = recordOf[photoId], !SyncRecord.photo(photo).isLive else { continue }
                let heard = SyncRecord.photo(photo).version[link.stamp.device]
                if heard.map({ $0 < link.stamp }) ?? true { out.insert(photo.sourceHash) }
            }
        }
        return out
    }

    /// A photo shown here whose files the cloud no longer has (removed by another device whose
    /// deletion lost to a later edit) is uploaded again from this device's copy. A few photos
    /// per cycle, in turn, so every photo is checked over time without a request per photo.
    private func repairFiles(_ device: inout SyncDeviceState, _ local: AppState, _ report: inout SyncReport) async {
        var held: [(record: PhotoSyncRecord, mine: SyncFileInfo, photoId: String)] = []
        let localBySha = Dictionary(local.photos.map { ($0.sha256, $0.photoId) }, uniquingKeysWith: { a, _ in a })
        // A photo still to send is left to `push`, which puts its file up first.
        for record in device.replica.photos.sorted(by: { $0.sourceHash < $1.sourceHash })
        where SyncRecord.photo(record).isLive && !device.dirty.contains(SyncRecord.photoName(record.sourceHash)) {
            if let mine = record.copies.first(where: { localBySha[$0.sha256] != nil }) { held.append((record, mine, localBySha[mine.sha256]!)) }
        }
        guard !held.isEmpty else { return }
        let start = ((device.repairCursor % held.count) + held.count) % held.count
        for offset in 0..<min(Self.repairBatch, held.count) where !stopped {
            let (record, mine, photoId) = held[(start + offset) % held.count]
            guard (try? await transport.hasFile(sha256: record.file.sha256)) == false,
                  (try? await transport.hasFile(sha256: mine.sha256)) == false else { continue }
            guard let url = await store.originalURL(photoId: photoId), let data = try? Data(contentsOf: url),
                  PhotoIngest.sha256Hex(data) == mine.sha256 else {
                // The cloud lacks the file and this device's copy cannot be read: said, not hidden.
                log.error("sync: a photo's stored copy cannot be read to upload it again")
                report.problem = report.problem ?? .rejected("localCopy")
                report.photosNotUploaded += 1
                continue
            }
            do {
                try await transport.uploadFile(sha256: mine.sha256, data: data)
            } catch {
                // Said as `push` says it: this photo can't be shown elsewhere until it is up.
                let problem = error as? SyncTransportError ?? .offline
                report.problem = report.problem ?? problem
                if case .quotaExceeded = problem { continue }
                if problem.concernsOneFile { report.photosNotUploaded += 1 }
                continue
            }
            device.collectedFiles.remove(mine.sha256)
            log.notice("sync: uploaded a missing file again")
        }
        device.repairCursor = (start + Self.repairBatch) % held.count
    }
}
