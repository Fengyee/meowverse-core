import MeowverseCore
import os
import SwiftUI

/// What the user agreed to, per library. `enabled` is false until they saw what is synced and agreed.
struct CloudSyncSettings: Codable, Equatable {
    var enabled = false
    /// The end of the last cycle that ran without a problem (or only with a full iCloud).
    var lastSuccess: Date?
}

/// iCloud sync between devices as the app sees it (docs/ICLOUD_SYNC.md). The merge, the
/// capture of this device's edits and the one-step write into the library are
/// `MeowverseCore/SyncSession.swift`; this only says when a cycle runs and reports honestly.
struct CloudSyncUIState {
    enum Problem: Equatable {
        case signedOut, quotaExceeded, accountChanged, cloudDataDeleted, offline, busy, failed

        /// Goes away by itself: the app tries again after a wait.
        var retries: Bool { self == .offline || self == .busy || self == .failed || self == .quotaExceeded }
        /// Only the user can decide what happens next; nothing is sent until then.
        var needsUser: Bool { self == .accountChanged || self == .cloudDataDeleted }
    }

    struct Notice: Equatable {
        var text: String
        var isFailure: Bool
    }

    var settings = CloudSyncSettings()
    /// False until the settings were read after launch; nothing runs before that.
    var loaded = false
    var running = false
    var problem: Problem?
    /// The server asked to wait this long (`retryLater`).
    var retryAfter: Int?
    /// Records with edits the cloud has not confirmed yet.
    var unsent = 0
    /// Photos whose copy could not be downloaded yet.
    var waitingForFiles = 0
    /// Photos whose file came and can't be used on this device.
    var unusableFiles = 0
    /// Links on pieces whose photo another device has not uploaded yet.
    var pendingLinks = 0
    /// The same, per piece: its detail says the photos are on their way, not "no photos yet".
    var pendingLinksByPiece: [String: Int] = [:]
    /// Records written by a newer version of the app, left as they are.
    var heldBack = 0
    /// Pieces whose model only a newer version has: their place is not changed here (COMPAT-2).
    var piecesFromNewerVersion: Set<String> = []
    /// Photos on those pieces: never called "on no furniture" (JOURNEY-FAMILY-6).
    var photosOnNewerPieces: Set<String> = []
    /// Records that could not be read or clash with others here, left as they are; updating
    /// the app would not help (`SyncReport.quarantined`).
    var quarantined = 0
    /// Records changed elsewhere that reached this device but could not be read yet.
    var notFetched = 0
    /// Photos whose copy could not be uploaded this round (iCloud being full is its own problem).
    var notUploaded = 0
    var notice: Notice?
    /// Failed rounds in a row, for the wait before the next try.
    var failures = 0
    var session: SyncSession?
    var cloud: (any SyncCloud)?
    /// Every call into the session runs here, one after another: a capture never runs inside a
    /// cycle (both rewrite sync's own file).
    var worker: Task<Void, Never>?
    /// The queue item running (or waiting to run) the latest cycle. A push or background time
    /// that runs out cancels this one: `worker` is only the queue's tail, and cancelling the tail
    /// does not stop the cycle in front of it.
    var cycleTask: Task<Void, Never>?
    var scheduled: Task<Void, Never>?
    /// Something changed while a cycle ran: one more cycle when it ends.
    var rerun = false
    /// The library revision sync last wrote itself: not an edit to capture.
    var appliedRevision: Int?
    var lastAttempt: Date?
    /// The library opened from its fallback copy (`state.backup.json`, or a picker import cut
    /// back), so sync's file may describe a later state than the one in use.
    var libraryFellBack = false
    /// The generation of the library this launch opened. Opening it is not a replacement:
    /// only a restore or a clear after it is (a start over at every launch refetched the whole
    /// home and merged it again as a first sync).
    var openedGeneration: UUID?
    /// Before the next cycle, sync forgets what it knew (`SyncSession.startOver`) and merges as
    /// on first sync: after a fallback, a restore or a clear, and when the user turned it on.
    var freshStartPending = false
    /// This install never synced this library, yet sync is on: a phone set up from another
    /// phone's device backup, which carries the library with sync's file in it and the settings,
    /// but not the `Sync` folder. Before the next cycle sync goes on from that file under a new
    /// device id (`SyncSession.startOnNewInstall`), so the edits the old phone never sent go
    /// out and deletions made elsewhere since stay deleted. `freshStartPending` wins over it.
    var newInstallPending = false
    /// The user chose to go on in the account signed in now.
    var freshStartAnyAccount = false
}

extension AppModel {
    enum SyncTrigger: Equatable {
        case launch, foreground, background, edit, remote, manual, retry, libraryReplaced
    }

    static let syncContainerIdentifier = "iCloud.io.github.fengyee.meowverse"
    private static let syncLog = Logger(subsystem: "app.meowverse", category: "cloudSync")
    /// Edits made close together go in one cycle.
    static let syncEditDelay: Duration = .seconds(4)

    private var syncSettingsKey: String { "cloudSync.settings." + options.storeFolder }
    /// Set when a restore or a clear switched in a new library while this build was not syncing
    /// it: a build without sync, or sync off. Kept in every build, so a sync build that finds its
    /// settings still on asks again instead of merging that library (audit round 12, SYNC-2).
    private var replacedWithoutSyncKey: String { "cloudSync.replacedWithoutSync." + options.storeFolder }
    /// Set when sync went from on to off without the home in iCloud being deleted: what it
    /// stored is still in the user's iCloud. Its own key, not a field of `CloudSyncSettings`,
    /// whose synthesized decoding would fail on older saved settings and turn sync off.
    private var syncLeftInICloudKey: String { "cloudSync.leftInICloud." + options.storeFolder }

    /// Sync is off, and the last thing this device knows is that what sync stored is still in
    /// iCloud (turned off by hand, by clearing this device only, or after a replace). Not
    /// checked against iCloud: deleted elsewhere since (another device, the Settings app), this
    /// is out of date. A test library only counts it while it runs with the sync test folder.
    var syncDataLeftInICloud: Bool {
        guard options.cloudSyncFeature || options.storeFolder == "Library" else { return false }
        if let recorded = UserDefaults.standard.object(forKey: syncLeftInICloudKey) as? Bool { return recorded }
        // Turned off by a build from before the record: this install synced this library once
        // (the marker is kept out of device backups, so it is this install's own).
        return FileManager.default.fileExists(atPath: syncInstallMarker.path)
    }

    /// Sync is turned off now; unless iCloud's copy is known to be gone, it was left there.
    private func noteSyncDataLeft() {
        let gone = sync.problem == .cloudDataDeleted
        UserDefaults.standard.set(!gone, forKey: syncLeftInICloudKey)
    }

    /// The user turned iCloud sync on: the app itself then talks to CloudKit, and the privacy
    /// wording says how (the About page adds its sync line, the backup page its own footer).
    var cloudSyncOn: Bool { options.cloudSyncFeature && sync.settings.enabled }

    /// This install's own sync files for this library: the engine state, the fetch mirror and the
    /// marker that this install has synced it. Kept out of device backups, so none of it moves
    /// to another phone (see `prepareSyncFolder`).
    private var syncLocalFolder: URL {
        SyncFiles.applicationSupport.appending(path: "Meowverse", directoryHint: .isDirectory)
            .appending(path: "Sync", directoryHint: .isDirectory)
            .appending(path: options.storeFolder, directoryHint: .isDirectory)
    }

    private var syncInstallMarker: URL { syncLocalFolder.appending(path: "this-install") }

    /// Creates the folder and keeps the whole `Sync` folder out of device backups.
    private func prepareSyncFolder() {
        let fm = FileManager.default
        try? fm.createDirectory(at: syncLocalFolder, withIntermediateDirectories: true)
        var parent = syncLocalFolder.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do { try parent.setResourceValues(values) } catch { Self.syncLog.error("sync folder not excluded from backup") }
    }

    /// CloudKit, or the test switch's plain folder. Only made once the user turned sync on.
    private func makeSyncCloud() -> any SyncCloud {
        #if DEBUG || DRILLS
        if let name = options.syncFolder {
            let base = SyncFiles.applicationSupport.appending(path: "Meowverse", directoryHint: .isDirectory)
            return FolderSyncCloud(folder: base.appending(path: "TestSync-" + name, directoryHint: .isDirectory),
                                   account: options.syncAccount, fault: options.syncFault.flatMap(FolderSyncCloud.Fault.init(rawValue:)))
        }
        #endif
        precondition(FeatureFlags.iCloudSync, "iCloud sync is switched off")
        // The home keeps its zones; a test library gets its own and never merges into the home.
        return CloudKitSyncTransport(containerIdentifier: Self.syncContainerIdentifier, folder: syncLocalFolder,
                                     zones: .forLibrary(options.storeFolder))
    }

    // MARK: Launch

    /// Once the library is open: read the settings and, if the user turned sync on, sync.
    func startCloudSync() async {
        guard options.cloudSyncFeature, phase == .ready else { return }
        // Read before the settings, so nothing waits between reading them and acting on them.
        var syncFileThere = true
        if !sync.loaded, let store { syncFileThere = await SyncSession.hasSyncFile(store) }
        if !sync.loaded {
            let defaults = UserDefaults.standard
            // A reset test library starts with sync off, like a fresh install.
            if options.resetStore {
                defaults.removeObject(forKey: syncSettingsKey)
                defaults.set(false, forKey: syncLeftInICloudKey)
            }
            if let saved = savedSyncSettings { sync.settings = saved }
            sync.loaded = true
            if sync.settings.enabled, defaults.bool(forKey: replacedWithoutSyncKey) || replacedWithoutRecord(syncFileThere) {
                turnSyncOffAfterReplacementElsewhere()
            }
            // Sync off: nothing to protect, and turning it on is the user's own choice to merge.
            if !sync.settings.enabled { defaults.removeObject(forKey: replacedWithoutSyncKey) }
        }
        guard sync.settings.enabled else { return }
        openSyncSession()
        requestSync(.launch)
    }

    /// A build without sync (or with it off) cleared or restored this library while the saved
    /// settings still said sync is on. The new library has no sync file, so the next cycle would
    /// merge it as a first sync without a word: a cleared home would come back from iCloud, and a
    /// restored one would bring back, on every device, everything deleted since that backup.
    /// Sync is turned off instead, with nothing deleted anywhere; turning it on again asks first.
    private func turnSyncOffAfterReplacementElsewhere() {
        noteSyncDataLeft()
        sync.settings.enabled = false
        sync.settings.lastSuccess = nil
        saveSyncSettings()
        // What the transport fetched for the old library is forgotten, as on turning sync off.
        let cloud = makeSyncCloud()
        enqueueSync { await cloud.reset() }
        Self.syncLog.notice("sync turned off: the library was replaced while sync was not running")
        setSyncNotice(String(localized: "这台设备上的资料库在没有同步的时候被清除或恢复过，为了不把它和 iCloud 里的家合并，iCloud 同步已关闭。iCloud 里的家和其他设备都没有动。要接着同步，可以再打开。", table: "ICloudSync"), isFailure: false)
    }

    private var savedSyncSettings: CloudSyncSettings? {
        UserDefaults.standard.data(forKey: syncSettingsKey).flatMap { try? JSONDecoder().decode(CloudSyncSettings.self, from: $0) }
    }

    /// Sync is on for this library in this build. Before the settings are read at launch
    /// (restoring a damaged library happens before the library is ready), the saved ones say.
    var syncOnForThisLibrary: Bool {
        guard options.cloudSyncFeature else { return false }
        return sync.loaded ? sync.settings.enabled : savedSyncSettings?.enabled == true
    }

    /// A replacement that left no record: builds shipped before the record existed cleared or
    /// restored the library without writing one. This install synced it (its marker is there)
    /// and the library has no sync file at all, nor any start over of this launch to explain it.
    /// A phone set up from a device backup has no marker, and takes the new-install path.
    private func replacedWithoutRecord(_ syncFileThere: Bool) -> Bool {
        !syncFileThere && !sync.freshStartPending && !sync.libraryFellBack
            && FileManager.default.fileExists(atPath: syncInstallMarker.path)
    }

    /// Called right before a restore or a clear switches the library. While this build is not
    /// syncing it, the switch is recorded for a later sync build (`turnSyncOffAfterReplacementElsewhere`).
    /// Returns what undoes the record when the switch fails.
    func noteLibraryReplacementForSync() -> () -> Void {
        if syncOnForThisLibrary {
            // Merged like any restore with sync on (docs/ICLOUD_SYNC.md §12, decision 6). Before
            // the settings are read nothing else marks the new library, so the fresh start (and
            // its account check) is set here.
            guard !sync.loaded, !sync.freshStartPending else { return {} }
            sync.freshStartPending = true
            return { [weak self] in self?.sync.freshStartPending = false }
        }
        let defaults = UserDefaults.standard, key = replacedWithoutSyncKey
        let had = defaults.bool(forKey: key)
        defaults.set(true, forKey: key)
        return { if !had { defaults.removeObject(forKey: key) } }
    }

    private func saveSyncSettings() {
        if let data = try? JSONEncoder().encode(sync.settings) { UserDefaults.standard.set(data, forKey: syncSettingsKey) }
    }

    private func openSyncSession() {
        guard sync.session == nil, let store else { return }
        prepareSyncFolder()
        if sync.libraryFellBack {
            sync.freshStartPending = true
        } else if !FileManager.default.fileExists(atPath: syncInstallMarker.path) {
            // Sync on, but not from this install: the settings came with a device backup.
            sync.newInstallPending = true
        }
        sync.libraryFellBack = false
        let cloud = makeSyncCloud()
        sync.cloud = cloud
        var known = catalog
        #if DEBUG
        // UI tests (`-MeowverseSyncOlderCatalog`): sync as a version from before the sofas.
        if ProcessInfo.processInfo.arguments.contains("-MeowverseSyncOlderCatalog"), let models = catalog?.models,
           let kept = try? JSONEncoder().encode(["models": models.filter { $0.category != .sofa }]),
           let older = try? FurnitureCatalog(data: kept) {
            known = older
        }
        #endif
        let session = SyncSession(store: store, transport: cloud, catalog: known)
        sync.session = session
        // Known before the first cycle ends, and without a network.
        enqueueSync { [weak self] in
            guard let standing = await session.standing(), let self, self.sync.session === session else { return }
            self.sync.pendingLinksByPiece = standing.pendingLinks
            self.sync.piecesFromNewerVersion = standing.piecesFromNewerVersion
            self.sync.photosOnNewerPieces = standing.photosOnNewerPieces
        }
        SyncPushCenter.shared.handler = { [weak self] in await self?.syncForPush() ?? .noData }
        let remoteChanged: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.requestSync(.remote) }
        }
        // In the queue: after the reset of a session turned off a moment ago, never beside it.
        enqueueSync {
            await cloud.setRemoteChangeHandler(remoteChanged)
            await cloud.start()
        }
        // Silent pushes for changes made elsewhere: no permission prompt, no visible notification.
        if cloud is CloudKitSyncTransport { UIApplication.shared.registerForRemoteNotifications() }
    }

    private func closeSyncSession() {
        sync.scheduled?.cancel()
        sync.scheduled = nil
        sync.session = nil
        sync.cloud = nil
        SyncPushCenter.shared.handler = nil
    }

    // MARK: Consent

    /// Called only after the user read what is synced and where, and agreed. The first cycle
    /// merges this device's home with what is in iCloud and deletes nothing.
    func enableCloudSync() {
        guard options.cloudSyncFeature, sync.loaded, !sync.settings.enabled else { return }
        sync.settings.enabled = true
        sync.settings.lastSuccess = nil
        saveSyncSettings()
        // The user's choice to merge this library, whatever replaced it before.
        UserDefaults.standard.removeObject(forKey: replacedWithoutSyncKey)
        sync.problem = nil
        sync.notice = nil
        openSyncSession()
        // Turning it on is the user's choice of the account signed in now; it starts as a first
        // sync whatever an earlier session left (turning off already started over).
        sync.freshStartPending = true
        sync.freshStartAnyAccount = true
        requestSync(.manual)
    }

    /// Stops syncing at once. The library stays as it is, and so does everything in iCloud;
    /// other devices go on syncing. Turning it on again merges the two sides as the first time did.
    /// `notice` replaces the usual one (clearing all data says the home here is gone).
    ///
    /// The returned task ends once nothing of the old session runs any more: the cycle that was
    /// running has stopped, sync's file is forgotten and the transport reset. Whoever switches
    /// the library next (clearing all data) waits for it: a cycle still out on the network
    /// carried on into the cleared library and brought the whole home back (audit round 12,
    /// SYNC-1). Only queueing the forgetting behind that cycle was not enough.
    @discardableResult
    func disableCloudSync(notice: String? = nil) -> Task<Void, Never>? {
        guard options.cloudSyncFeature, sync.settings.enabled else { return nil }
        // Before `problem` is cleared below: it tells whether iCloud's copy is already gone.
        noteSyncDataLeft()
        sync.settings.enabled = false
        sync.settings.lastSuccess = nil
        saveSyncSettings()
        let session = sync.session, cloud = sync.cloud
        // The running cycle stops at its next step, and its calls into CloudKit end with it.
        sync.cycleTask?.cancel()
        closeSyncSession()
        sync.problem = nil
        sync.retryAfter = nil
        sync.unsent = 0
        sync.waitingForFiles = 0
        sync.unusableFiles = 0
        sync.pendingLinks = 0
        sync.pendingLinksByPiece = [:]
        sync.piecesFromNewerVersion = []
        sync.photosOnNewerPieces = []
        sync.heldBack = 0
        sync.quarantined = 0
        sync.notFetched = 0
        sync.notUploaded = 0
        sync.failures = 0
        sync.freshStartPending = false
        sync.newInstallPending = false
        sync.freshStartAnyAccount = false
        // The cycle still out on the network belongs to the session closed here: it no longer
        // keeps a session opened later from running, and nothing it reports reaches that one
        // (audit CC24-02, `finishSync`).
        sync.running = false
        sync.rerun = false
        // Closed now, not when the queue gets to it: whatever the queue still holds for this
        // session does nothing. Closing waits for the cycle out on the network to stop, then
        // forgets what sync knew; nothing is deleted.
        let closing = Task {
            do { try await session?.close(forgetting: true) } catch {
                Self.syncLog.error("sync: what it knew was not forgotten on turning off: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        // The transport after everything queued for it, never beside a call still using it.
        let done = enqueueSync {
            await closing.value
            await cloud?.reset()
        }
        setSyncNotice(notice ?? String(localized: "iCloud 同步已关闭。这台设备上的家和 iCloud 里的数据都还在。"), isFailure: false)
        return done
    }

    /// After another account was signed in, or the iCloud data was deleted, and the user chose to
    /// go on: this device's home is merged into what the cloud has now (nothing is deleted).
    func startSyncOver() {
        guard sync.settings.enabled, let session = sync.session, let cloud = sync.cloud, sync.problem?.needsUser == true else { return }
        sync.problem = nil
        sync.notice = nil
        sync.settings.lastSuccess = nil
        saveSyncSettings()
        // The user's answer: merge into the account signed in now. The fresh start runs right
        // before the next cycle, after the transport forgot the old account's records.
        sync.freshStartPending = true
        sync.freshStartAnyAccount = true
        enqueueSync { await cloud.reset() }
        requestSync(.manual)
    }

    /// How deleting the home in iCloud went (clearing all data, docs/ICLOUD_SYNC.md §7).
    enum CloudHomeDeletion: Equatable {
        /// Every deletion reached iCloud: the library can be cleared.
        case done
        /// Every deletion this device could make reached iCloud, but records it can't read (a
        /// newer version wrote them) or hasn't fetched yet stay there as they are: the library
        /// can be cleared, and the result must not say the home is all gone (audit D24-01).
        case doneExceptUnread
        /// Recorded, not all sent: the next cycles send the rest and empty this library too.
        case unfinished(CloudSyncUIState.Problem)
        /// Nothing was deleted anywhere.
        case failed(CloudSyncUIState.Problem)
    }

    /// The user chose to delete the home in iCloud as well as on this device. In the queue like
    /// every call into the session, after any cycle that runs; the library is not touched here.
    func deleteHomeInICloud() async -> CloudHomeDeletion {
        guard options.cloudSyncFeature, sync.settings.enabled, let session = sync.session else { return .failed(.failed) }
        let cloud = sync.cloud
        sync.scheduled?.cancel()
        sync.scheduled = nil
        return await withCheckedContinuation { continuation in
            enqueueSync { [weak self] in
                guard let self else { return continuation.resume(returning: .failed(.failed)) }
                do {
                    try await self.freshStartIfPending(session, cloud)
                    let report = try await session.deleteHomeInCloud()
                    self.sync.unsent = report.unsent
                    if report.localStateUnsaved {
                        // The cloud has what the report says; the next cycle resends from the file.
                        Self.syncLog.error("sync: home deletion sent, sync's own file not saved")
                    }
                    let unread = report.heldBack.count + (await cloud?.recordsNotFetched() ?? 0)
                    if report.problem == nil, report.unsent == 0, unread > 0 {
                        Self.syncLog.notice("sync: home deleted in iCloud except \(unread, privacy: .public) records not read")
                        continuation.resume(returning: .doneExceptUnread)
                    } else if report.problem == nil, report.unsent == 0 {
                        Self.syncLog.notice("sync: home deleted in iCloud")
                        continuation.resume(returning: .done)
                    } else {
                        // The rest goes with the next cycles, as any unsent edit does.
                        let problem = Self.syncProblem(report.problem) ?? .failed
                        self.sync.problem = problem
                        Self.syncLog.notice("sync: home deletion unfinished: \(report.problem.map(Self.syncCode) ?? "unsent", privacy: .public)")
                        continuation.resume(returning: .unfinished(problem))
                        if problem.retries { self.requestSync(.retry, after: self.syncRetryDelay(problem)) }
                    }
                } catch let error as SyncTransportError {
                    Self.syncLog.notice("sync: home not deleted: \(Self.syncCode(error), privacy: .public)")
                    continuation.resume(returning: .failed(Self.syncProblem(error) ?? .failed))
                } catch {
                    Self.syncLog.error("sync: home not deleted: \(String(describing: type(of: error)), privacy: .public)")
                    continuation.resume(returning: .failed(.failed))
                }
            }
        }
    }

    // MARK: When a cycle runs

    /// "立即同步".
    func syncNow() {
        sync.notice = nil
        requestSync(.manual)
    }

    /// The library changed: record the edit now (it is ordered by when it was made, not by when
    /// the device was next online) and sync a moment later.
    func libraryChangedForSync() {
        guard sync.settings.enabled, let session = sync.session else { return }
        // Sync's own write of remote changes is not an edit.
        if state.revision == sync.appliedRevision { return }
        if !sync.running {
            enqueueSync { [weak self] in
                // A capture against a file a fresh start is about to drop would be worthless.
                do { try await self?.freshStartIfPending(session, self?.sync.cloud) } catch { return }
                try? await session.captureLocalEdits()
            }
        }
        requestSync(.edit, after: Self.syncEditDelay)
    }

    /// A restore or a clear switched in a whole new library: it has no sync state, so the next
    /// cycle merges it with the cloud as on first sync and never deletes anything elsewhere.
    func libraryReplacedForSync() {
        guard libraryGeneration != sync.openedGeneration else { return }
        sync.openedGeneration = libraryGeneration
        guard sync.settings.enabled else { return }
        sync.appliedRevision = nil
        sync.freshStartPending = true
        requestSync(.libraryReplaced, after: .seconds(1))
    }

    func cloudSyncScenePhaseChanged(_ phase: ScenePhase) {
        guard sync.settings.enabled, sync.session != nil else { return }
        switch phase {
        case .active:
            // Not again right after one ran (a quick trip to another app).
            if let last = sync.lastAttempt, Date().timeIntervalSince(last) < 20 { return }
            requestSync(.foreground)
        case .background:
            if sync.unsent > 0 || sync.scheduled != nil { requestSync(.background) }
        default:
            break
        }
    }

    /// A push from CloudKit: a cycle of its own, waited for, so the system's background time
    /// covers it. A cycle already running was not started for this push: the push waits for it
    /// without ever cancelling it, then runs its own. When the push's time runs out
    /// (`SyncPushCenter`) only that own cycle is cancelled (it leaves the library and sync's file
    /// as they were), never one a later request queued meanwhile (audit CC24-03). The result
    /// says what the cycle did: new data only when it wrote remote changes into the library.
    func syncForPush() async -> SyncPushOutcome {
        guard sync.settings.enabled, let session = sync.session else { return .noData }
        // The push's own cycle covers whatever was waiting to run.
        sync.scheduled?.cancel()
        sync.scheduled = nil
        if sync.running, let front = sync.cycleTask {
            guard await SyncDeadline.value(of: front) != nil else { return .failed }
            guard sync.settings.enabled, sync.session === session else { return .noData }
            // A retry that cycle asked for is covered too.
            sync.scheduled?.cancel()
            sync.scheduled = nil
        }
        let result = SyncCycleResult()
        guard let mine = runSync(.remote, result: result) else { return .noData }
        await withTaskCancellationHandler {
            await mine.value
        } onCancel: {
            mine.cancel()
        }
        switch result.outcome {
        case .success(let report)?:
            if report.problem != nil { return .failed }
            return report.applied ? .newData : .noData
        case .failure?, nil:
            return .failed
        }
    }

    func requestSync(_ trigger: SyncTrigger, after delay: Duration = .zero) {
        guard options.cloudSyncFeature, sync.settings.enabled, sync.session != nil else { return }
        sync.scheduled?.cancel()
        sync.scheduled = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            // Cancelled while it waited its turn (a push's own cycle covers it): nothing runs.
            guard !Task.isCancelled, let self else { return }
            self.sync.scheduled = nil
            self.runSync(trigger)
        }
    }

    /// Starts a cycle in the queue and returns its task; nil when none was started (one is
    /// running, the user must answer first, or it was put off). `result` gets what it did.
    @discardableResult
    private func runSync(_ trigger: SyncTrigger, result: SyncCycleResult? = nil) -> Task<Void, Never>? {
        guard sync.settings.enabled, let session = sync.session else { return nil }
        let cloud = sync.cloud
        // Not while a library is being switched in or photos are still arriving: each of their
        // writes would send the cycle back to the start. It runs once they are done.
        if switchingLibraries || batch.progress != nil || photos.adding != nil {
            requestSync(trigger, after: .seconds(5))
            return nil
        }
        if sync.running {
            sync.rerun = true
            return nil
        }
        // Waits for the user's answer; "立即同步" is not that answer.
        if sync.problem?.needsUser == true { return nil }
        sync.running = true
        sync.lastAttempt = Date()
        Self.syncLog.notice("sync cycle starts: \(String(describing: trigger), privacy: .public)")
        // A little more time when the app has just gone to the background; if it runs out the
        // cycle is cancelled, which leaves the library and sync's file as they were.
        // The expiry handler must end the task itself, or the system ends the app.
        let background = SyncBackgroundTask()
        if trigger == .background || UIApplication.shared.applicationState == .background {
            // This cycle's, not whichever is the latest when the time runs out (CC24-03).
            background.id = UIApplication.shared.beginBackgroundTask(withName: "CloudSync") {
                background.cycle?.cancel()
                background.end()
            }
        }
        let task = enqueueSync { [weak self] in
            let outcome: Result<SyncReport, any Error>
            do {
                // Cancelled while it waited behind the queue: it does not start.
                try Task.checkCancellation()
                try await self?.freshStartIfPending(session, cloud)
                outcome = .success(try await session.sync())
            } catch {
                outcome = .failure(error)
            }
            result?.outcome = outcome
            await self?.finishSync(outcome, trigger: trigger, session: session, cloud: cloud)
            background.end()
        }
        sync.cycleTask = task
        background.cycle = task
        return task
    }

    /// In the queue, right before a cycle: never a cycle on the old file once a fresh start is due.
    /// If it fails the cycle does not run, and the next one tries again.
    /// Starting over forgets which account the home synced with, so first the account is
    /// checked against the one this install last synced with (the marker holds its hashed key):
    /// another account waits for the user's answer, as `accountChanged` always does.
    ///
    /// On an install that never synced this library (`newInstallPending`) sync goes on from the
    /// file the library carried instead, under a new device id; the file's own account is
    /// checked by the cycle, as on any other launch.
    ///
    /// The marker then holds the account the home is bound to: the one sync's file names after
    /// the start (the carried file's account, not the one signed in now, which the next cycle
    /// refuses; audit CC24-01), or the one checked here. A marker that is there but cannot be
    /// read stops the start (ERRORS-5): it is not taken for "no account known".
    private func freshStartIfPending(_ session: SyncSession, _ cloud: (any SyncCloud)?) async throws {
        guard sync.freshStartPending || sync.newInstallPending, let cloud else { return }
        let account = try await cloud.accountKey()
        if sync.freshStartPending {
            // Checked only against a marker that names an account, or by the user's answer.
            // Otherwise (a new install whose library fell back to its fallback copy) `account`
            // is just whoever is signed in: an unreadable sync file then stops the start, and
            // `finishSync` turns sync off (QA round 20, G1, the fallback path).
            var checked = sync.freshStartAnyAccount
            if !sync.freshStartAnyAccount, FileManager.default.fileExists(atPath: syncInstallMarker.path) {
                let known = try String(contentsOf: syncInstallMarker, encoding: .utf8)
                if !known.isEmpty, known != account { throw SyncTransportError.accountChanged }
                checked = !known.isEmpty
            }
            // Bound to the account just checked: a switch before the cycle asks again stops it.
            try await session.startOver(acceptingCurrentAccount: sync.freshStartAnyAccount, account: account,
                                        accountChecked: checked)
            Self.syncLog.notice("sync started over: merges as on first sync")
        } else {
            switch try await session.startOnNewInstall() {
            case .kept: Self.syncLog.notice("sync on a new install: goes on from the library's sync file")
            case .startedOver: Self.syncLog.notice("sync on a new install: nothing to go on from, merges as on first sync")
            }
        }
        // Turned off (and maybe on again) meanwhile: the flags are the new session's (CC24-02).
        guard sync.session === session else { throw CancellationError() }
        sync.freshStartPending = false
        sync.newInstallPending = false
        sync.freshStartAnyAccount = false
        let bound = (try? await session.deviceState())?.account ?? account
        do {
            try SyncFiles.writeDurably(Data(bound.utf8), to: syncInstallMarker)
        } catch {
            Self.syncLog.error("sync install marker not written")
        }
    }

    @discardableResult
    private func enqueueSync(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = sync.worker
        let task = Task {
            await previous?.value
            await work()
        }
        sync.worker = task
        return task
    }

    /// `session` and `cloud` are the ones the cycle ran on. Sync turned off while it ran, and
    /// maybe on again with a new session: what the cycle wrote into the library is shown (that is
    /// the library's, whichever session), but nothing it reports, no problem, success, retry or
    /// fresh start, reaches the session open now. Checked again after every await (CC24-02).
    private func finishSync(_ outcome: Result<SyncReport, any Error>, trigger: SyncTrigger,
                            session: SyncSession, cloud: (any SyncCloud)?) async {
        func owned() -> Bool { sync.settings.enabled && sync.session === session }
        if owned() { sync.running = false }
        switch outcome {
        case .success(let report):
            if report.applied {
                // Remote changes are in the library: show them, and work out prints for new photos.
                await republish()
                sync.appliedRevision = state.revision
                refreshFeaturePrints()
                remoteChangesApplied()
            }
            // Turned off while it ran: what it wrote is shown, nothing more is reported.
            guard owned() else { return }
            // From the transport this cycle ran on, never a newer session's.
            let notFetched = await cloud?.recordsNotFetched() ?? 0
            guard owned() else { return }
            sync.unsent = report.unsent
            sync.waitingForFiles = report.waitingForFiles
            sync.unusableFiles = report.unusableFiles
            sync.pendingLinks = report.pendingLinks.values.reduce(0, +)
            sync.pendingLinksByPiece = report.pendingLinks
            sync.piecesFromNewerVersion = report.piecesFromNewerVersion
            sync.photosOnNewerPieces = report.photosOnNewerPieces
            sync.quarantined = report.quarantined.count
            sync.heldBack = Set(report.heldBack).subtracting(report.quarantined).count
            sync.notFetched = notFetched
            sync.notUploaded = report.photosNotUploaded
            sync.problem = Self.syncProblem(report.problem)
            if case .retryLater(let seconds) = report.problem { sync.retryAfter = seconds } else { sync.retryAfter = nil }
            // A full iCloud refuses records as well as files: not a success either.
            if report.problem == nil {
                sync.settings.lastSuccess = Date()
                saveSyncSettings()
            }
            if let problem = report.problem {
                Self.syncLog.notice("sync cycle stopped: \(Self.syncCode(problem), privacy: .public)")
            }
            sync.failures = sync.problem?.retries == true ? sync.failures + 1 : 0
            if trigger == .manual {
                if let problem = sync.problem {
                    setSyncNotice(Self.syncProblemText(problem), isFailure: true)
                } else if report.localCleanupPending {
                    // A deletion is in the library, its files not all removed yet (audit DD24-03).
                    setSyncNotice(Wording.sentences(String(localized: "同步完成。"),
                                                    Self.photoMessage(for: StoreError.deletionCleanupPending)), isFailure: false)
                } else {
                    setSyncNotice(String(localized: "同步完成。"), isFailure: false)
                }
            }
        case .failure(let error):
            // A store error after the library was committed (sync's own file not written,
            // T24-04): the library on disk is newer than the one shown. Shown, like any write.
            if !(error is SyncApplyError), !(error is CancellationError) { await republishIfSyncWrote() }
            guard owned() else { return }
            switch error {
            case SyncStateError.unreadable:
                // Sync's file and its backup are there and unreadable: not a first sync. The
                // fresh start checks the account this install knows first (audit AA24-01).
                // Without a marker (a new install) there is no account to check against, and
                // starting over would take whichever one is signed in: sync is turned off, with
                // nothing sent, and turning it on again asks first (QA round 20, G1). The same
                // when the marker names no account: the fresh start refuses then too, and asking
                // it again would only refuse again.
                let marker = FileManager.default.fileExists(atPath: syncInstallMarker.path)
                guard marker, (try? String(contentsOf: syncInstallMarker, encoding: .utf8))?.isEmpty != true else {
                    Self.syncLog.error("sync state unreadable and no account known: sync turned off")
                    disableCloudSync()
                    return
                }
                Self.syncLog.error("sync state unreadable: fresh start with the account check")
                sync.freshStartPending = true
                sync.rerun = true
            case SyncStateError.newerVersion:
                // A newer version's file: left alone, nothing synced by this version.
                Self.syncLog.error("sync state from a newer version: not synced")
                sync.problem = .failed
                sync.failures += 1
                if trigger == .manual { setSyncNotice(Self.syncProblemText(.failed), isFailure: true) }
            case SyncApplyError.libraryReplaced:
                // A restore or a clear switched in a library while the cycle ran. Without a sync
                // file there, the session left it to the app: the fresh start (with its account
                // check) runs before the next cycle, which never merges into it unchecked.
                let file = try? await session.deviceState()
                guard owned() else { return }
                if file == nil { sync.freshStartPending = true }
                sync.rerun = true
            case SyncApplyError.localChanged:
                // Edits kept coming: once more, shortly.
                sync.rerun = true
            case is CancellationError:
                break
            case let problem as SyncTransportError:
                // The fresh start's account check failed (no account, another account, offline):
                // said as it is, like the same problem inside a cycle.
                Self.syncLog.notice("sync fresh start stopped: \(Self.syncCode(problem), privacy: .public)")
                sync.problem = Self.syncProblem(problem)
                if case .retryLater(let seconds) = problem { sync.retryAfter = seconds } else { sync.retryAfter = nil }
                sync.failures = sync.problem?.retries == true ? sync.failures + 1 : 0
                if trigger == .manual, let shown = sync.problem { setSyncNotice(Self.syncProblemText(shown), isFailure: true) }
            default:
                Self.syncLog.error("sync cycle failed: \(String(describing: type(of: error)), privacy: .public)")
                sync.problem = .failed
                sync.failures += 1
                if trigger == .manual { setSyncNotice(Self.syncProblemText(.failed), isFailure: true) }
            }
        }
        if sync.rerun {
            sync.rerun = false
            requestSync(.retry, after: .seconds(1))
        } else if let problem = sync.problem, problem.retries {
            requestSync(.retry, after: syncRetryDelay(problem))
        }
    }

    /// The library on disk is not the one shown (a cycle committed it, then failed): show it.
    private func republishIfSyncWrote() async {
        guard let store, await store.snapshot().revision != state.revision else { return }
        await republish()
        sync.appliedRevision = state.revision
        refreshFeaturePrints()
    }

    /// 30 s, doubling to 15 min while it keeps failing; what the server asked for when it did.
    private func syncRetryDelay(_ problem: CloudSyncUIState.Problem) -> Duration {
        if problem == .busy, let seconds = sync.retryAfter { return .seconds(max(5, seconds)) }
        if problem == .quotaExceeded { return .seconds(15 * 60) }
        let exponent = min(max(sync.failures - 1, 0), 5)
        return .seconds(min(30 * (1 << exponent), 15 * 60))
    }

    // MARK: Wording

    private func setSyncNotice(_ text: String, isFailure: Bool) {
        sync.notice = .init(text: text, isFailure: isFailure)
        AccessibilityNotification.Announcement(text).post()
    }

    static func syncProblem(_ error: SyncTransportError?) -> CloudSyncUIState.Problem? {
        switch error {
        case nil: nil
        case .offline: .offline
        case .quotaExceeded: .quotaExceeded
        case .signedOut: .signedOut
        case .accountChanged: .accountChanged
        case .cloudDataDeleted: .cloudDataDeleted
        case .retryLater: .busy
        case .missingFile, .rejected: .failed
        }
    }

    /// A short code that is safe to log: never a record, a name or a path.
    static func syncCode(_ error: SyncTransportError) -> String {
        switch error {
        case .offline: "offline"
        case .quotaExceeded: "quota"
        case .signedOut: "signedOut"
        case .accountChanged: "accountChanged"
        case .cloudDataDeleted: "cloudDataDeleted"
        case .retryLater: "retryLater"
        case .missingFile: "missingFile"
        case .rejected(let code): "rejected-" + code
        }
    }

    static func syncProblemText(_ problem: CloudSyncUIState.Problem) -> String {
        switch problem {
        case .signedOut:
            String(localized: "这台设备没有登录 iCloud，或者在系统“设置”里关掉了喵空间使用 iCloud，所以现在不同步。改动都留在这台设备上，登录后会接着同步。")
        case .quotaExceeded:
            String(localized: "iCloud 储存空间已满，这台设备上有改动或照片还没能上传。空间够了会接着同步。")
        case .accountChanged:
            String(localized: "这台设备现在登录的是另一个 Apple 账户，同步已暂停。这台设备上的家和原来账户里的数据都没有动。")
        case .cloudDataDeleted:
            String(localized: "iCloud 里喵空间的同步数据已被删除，可能是在系统“设置”里删的。这台设备上的家没有动，同步已暂停。")
        case .offline:
            String(localized: "现在没有网络。改动都留在这台设备上，联网后会自动同步。")
        case .busy:
            String(localized: "iCloud 现在很忙，稍后会自动再试。")
        case .failed:
            String(localized: "这次没能同步完，稍后会自动再试。这台设备上的家没有受影响。")
        }
    }
}

/// A background task that is ended exactly once, by the cycle or by the system's expiry.
@MainActor
final class SyncBackgroundTask {
    var id = UIBackgroundTaskIdentifier.invalid
    /// The cycle this background time was asked for: the only one its expiry cancels.
    var cycle: Task<Void, Never>?

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// What a push's cycle did, for the system's background fetch result.
enum SyncPushOutcome: Sendable {
    /// Remote changes were written into the library.
    case newData
    /// Nothing ran, or the cycle brought nothing new.
    case noData
    /// The cycle stopped on a problem, was cancelled, or ran out of time.
    case failed
}

/// What one cycle ended with, for whoever started it (a push).
@MainActor
final class SyncCycleResult {
    var outcome: Result<SyncReport, any Error>?
}

/// Where a CloudKit push reaches the model (the app delegate has no other way in).
@MainActor
final class SyncPushCenter {
    static let shared = SyncPushCenter()
    var handler: (@MainActor @Sendable () async -> SyncPushOutcome)?

    /// Runs the push's cycle, and returns within about 25 seconds whatever it is doing: the
    /// system gives a push 30. At the limit only the push's own cycle is cancelled, and this
    /// does not wait for a call inside it that does not return (audit CC24-03).
    func receive() async -> SyncPushOutcome? {
        guard let handler else { return nil }
        switch await SyncDeadline.run(limit: .seconds(25), { await handler() }) {
        case .finished(let outcome): return outcome
        case .timedOut, .cancelled: return .failed
        }
    }
}
