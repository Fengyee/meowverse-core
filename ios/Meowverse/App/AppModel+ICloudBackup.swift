import MeowverseCore
import os
import SwiftUI

/// iCloud Drive backup as the screen sees it. Policy, naming, pruning and the write itself
/// are in `MeowverseCore/CloudBackup.swift`; this file only starts them and reports honestly.
struct CloudBackupUIState {
    enum Activity: Equatable {
        /// Building, verifying and moving a new archive; 0...1.
        case backingUp(Double)
        /// Making a backup local before it is read; nil while the amount is unknown.
        case downloading(archiveName: String, fraction: Double?)
        case deleting
    }

    struct Notice: Equatable {
        var text: String
        var isFailure: Bool
    }

    /// Persisted per library. `enabled` is false until the user has seen what is stored and agreed.
    var settings = CloudBackupSettings()
    var deviceID = ""
    /// False until the settings were read after launch; nothing runs before that.
    var loaded = false
    /// nil until checked.
    var availability: CloudAvailability?
    /// Newest first; what the last successful listing found.
    var entries: [CloudBackupEntry] = []
    /// The last listing failed; `entries` may be out of date.
    var listFailed = false
    var activity: Activity?
    var cancelling = false
    var notice: Notice?
    /// The "restore from iCloud" sheet opened from the empty room.
    var restoreSheetShown = false
    /// A listing or download result for an older number is dropped.
    var generation = 0
    var listGeneration = 0
    var task: Task<Void, Never>?
    /// The signed-in account against the one backups belong to, from the last listing.
    var account: CloudBackupPolicy.AccountCheck?
    /// The account `entries` were listed under (the same before and after the listing); nil when
    /// there is no such listing. A delete the user confirms from that list happens only in this
    /// account, and stops if another one is signed in (audit A24-01).
    var listedAccount: String?

    /// Signed in to another account than the one the user agreed for, or to one never compared
    /// (turned on while signed out, or by an older build): nothing is backed up until the user
    /// chooses (back up to this account, or turn it off).
    var waitsForAccountAnswer: Bool { settings.enabled && (account == .differs || account == .unconfirmed) }
}

extension AppModel {
    private static let cloudWorkPrefix = "MeowverseCloudBackup-"
    private static let cloudDeviceKey = "cloudBackup.deviceID"
    private static let cloudVendorKey = "cloudBackup.deviceVendorID"
    private static let cloudLog = Logger(subsystem: "app.meowverse", category: "cloudBackup")

    private var cloudSettingsKey: String { "cloudBackup.settings." + options.storeFolder }

    /// iCloud Drive, or the test switch's plain folder. Only reached when the feature is on.
    private var cloudDestination: any BackupDestination {
        #if DEBUG || DRILLS
        if let name = options.cloudFolder {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            // `-MeowverseCloudAccount <name>`: signed in to that account, which has a folder of
            // its own, as each account has its own iCloud Drive.
            let args = ProcessInfo.processInfo.arguments
            let account = args.firstIndex(of: "-MeowverseCloudAccount").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }?
                .filter { $0.isLetter || $0.isNumber }
            let folder = "TestCloud-" + name + (account.map { "-" + $0 } ?? "")
            return FolderBackupDestination(folder: base.appending(path: "Meowverse").appending(path: folder, directoryHint: .isDirectory),
                                           account: account.map { "test-" + $0 } ?? FolderBackupDestination.defaultAccount)
        }
        #endif
        assert(FeatureFlags.iCloudBackup, "iCloud backup is switched off")
        return UbiquityBackupDestination()
    }

    /// The backup a restore starts with: the newest verified one.
    var recommendedCloudBackup: CloudBackupEntry? { CloudBackupPolicy.recommended(cloud.entries) }

    /// The backup the empty room offers: the newest that is neither this device's own nor known
    /// to hold nothing (`CloudBackupPolicy.restoreOffer`, QA_T2 R3-1).
    var offeredCloudBackup: CloudBackupEntry? { CloudBackupPolicy.restoreOffer(cloud.entries) }

    var cloudBackupsOfThisDevice: [CloudBackupEntry] { cloud.entries.filter(\.isFromThisDevice) }

    /// An empty room and backups in iCloud: offered once, never restored on its own. A cat or room
    /// named at the first launch still counts as empty (`isEmptyForRestoreOffer`): a backup listed
    /// after the tour's naming page is offered all the same (QA_T2 F2). Not this device's own
    /// backup, nor one that holds nothing (`offeredCloudBackup`, QA_T2 R2-1, R3-1).
    var cloudRestoreOffered: Bool {
        options.cloudBackupFeature && phase == .ready && cloud.loaded && state.isEmptyForRestoreOffer
            && !cloud.settings.restoreOfferDismissed && cloud.activity == nil
            && offeredCloudBackup != nil
    }

    /// Heavy or blocking async work off the main actor; cancelling the caller cancels the work.
    nonisolated static func offMainAsync<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility) { try await work() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Launch and listing

    /// Once the library is open: read the settings, look at what iCloud holds, and back up if due.
    func startCloudBackup() async {
        guard options.cloudBackupFeature, phase == .ready else { return }
        if !cloud.loaded {
            let defaults = UserDefaults.standard
            // A reset test library starts like a fresh install: iCloud backup off, and a new device
            // id, so the backups made before the reset are another device's (QA_T2 R2-1).
            if options.resetStore {
                defaults.removeObject(forKey: cloudSettingsKey)
                defaults.removeObject(forKey: Self.cloudDeviceKey)
            }
            if let data = defaults.data(forKey: cloudSettingsKey), let saved = try? JSONDecoder().decode(CloudBackupSettings.self, from: data) {
                cloud.settings = saved
            }
            // The id names "this device" for pruning. It is remade when the app's data shows up
            // on another phone (moved by a device backup): two phones with one id could each
            // rotate out the other's backups.
            let vendor = UIDevice.current.identifierForVendor?.uuidString
            let storedVendor = defaults.string(forKey: Self.cloudVendorKey)
            if let id = defaults.string(forKey: Self.cloudDeviceKey), CloudBackupName(deviceID: id, createdAt: .now, revision: 0) != nil,
               vendor == nil || storedVendor == nil || vendor == storedVendor {
                cloud.deviceID = id
            } else {
                cloud.deviceID = CloudBackupName.newDeviceID()
                defaults.set(cloud.deviceID, forKey: Self.cloudDeviceKey)
            }
            if let vendor, storedVendor != vendor { defaults.set(vendor, forKey: Self.cloudVendorKey) }
            // Work folders of a backup that was interrupted (the app was closed half-way).
            let temp = FileManager.default.temporaryDirectory
            for name in (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [] where name.hasPrefix(Self.cloudWorkPrefix) {
                try? FileManager.default.removeItem(at: temp.appending(path: name))
            }
            cloud.loaded = true
        }
        await refreshCloudBackups()
        backUpToCloud(trigger: .automatic)
    }

    private func saveCloudSettings() {
        if let data = try? JSONEncoder().encode(cloud.settings) { UserDefaults.standard.set(data, forKey: cloudSettingsKey) }
    }

    /// Reads availability and the list of backups. Reads only; nothing is written or downloaded
    /// except the small info files the system has not fetched yet.
    func refreshCloudBackups(retryingAfterASwitch: Bool = true) async {
        guard options.cloudBackupFeature, cloud.loaded else { return }
        cloud.listGeneration += 1
        let generation = cloud.listGeneration
        let destination = cloudDestination, deviceID = cloud.deviceID, damaged = Set(cloud.settings.damagedNames)
        let result = await Task.detached(priority: .utility) { () -> (CloudAvailability, CloudBackupListing?, String?, Bool) in
            // The account before and after: a listing taken across a switch proves nothing.
            let listedUnder = destination.accountFingerprint()
            let availability = destination.availability()
            guard availability == .available else { return (availability, nil, nil, true) }
            let listing = try? CloudBackupCatalog.load(from: destination, deviceID: deviceID, knownDamaged: damaged)
            let account = destination.accountFingerprint()
            return (availability, listing, account, listedUnder == account)
        }.value
        // A newer refresh was started meanwhile: its answer is the one to show.
        guard generation == cloud.listGeneration else { return }
        guard result.3 else {
            // Switched while listing: look again (once; the identity notification also comes).
            Self.cloudLog.notice("iCloud account changed during the listing")
            if retryingAfterASwitch { await refreshCloudBackups(retryingAfterASwitch: false) } else { cloud.account = .unknown }
            return
        }
        cloud.availability = result.0
        // Against the settings as they are now, not as they were when the listing began.
        let check = CloudBackupPolicy.checkAccount(remembered: cloud.settings.account, current: result.2,
                                                   lastSuccess: cloud.settings.lastSuccess, listing: result.1)
        if case .adopt(let account) = check, cloud.settings.enabled {
            // Turned on by a build that did not remember the account; this device's last
            // backup is in this account's folder, so it is the one.
            cloud.settings.account = account
            saveCloudSettings()
            cloud.account = .matches
        } else {
            cloud.account = check
        }
        if let listing = result.1 {
            cloud.entries = listing.entries
            cloud.listedAccount = result.2
            cloud.listFailed = false
        } else {
            if result.0 != .available {
                cloud.entries = []
                cloud.listedAccount = nil
            }
            cloud.listFailed = result.0 == .available
        }
    }

    // MARK: Consent

    /// Called only after the user read what is stored where and agreed. Writes nothing by itself.
    /// Free for everyone.
    func enableCloudBackup() {
        guard options.cloudBackupFeature, cloud.loaded, cloud.activity == nil else { return }
        cloud.settings.enabled = true
        cloud.settings.lastFailure = nil
        // The consent is for the account signed in now (a fast read, no file access). Signed
        // out, none is remembered, and the user is asked once an account is there.
        let account = cloudDestination.accountFingerprint()
        cloud.settings.account = account
        cloud.account = account == nil ? .unknown : .matches
        cloud.notice = nil
        saveCloudSettings()
    }

    /// The user's answer after an account switch: back up to the account signed in now. The
    /// first account's backups stay in that account. Writes nothing by itself.
    func keepCloudBackupOnCurrentAccount() {
        guard options.cloudBackupFeature, cloud.loaded, cloud.activity == nil, cloud.settings.enabled else { return }
        // Read again: the account may have changed since the question was shown.
        guard let account = cloudDestination.accountFingerprint() else { return }
        let wasAnother = cloud.account == .differs
        // A last backup in the account remembered until now stays there, and that is
        // remembered for the privacy wording (audit B24-05).
        cloud.settings.moveBackups(to: account)
        cloud.account = .matches
        saveCloudSettings()
        setCloudNotice(wasAnother
                       ? String(localized: "以后会备份到现在登录的 Apple 账户。原来账户里的备份留在原来的账户里。")
                       : String(localized: "以后会备份到现在登录的 Apple 账户。"), isFailure: false)
    }

    /// iCloud signed in, out, or to another account (`NSUbiquityIdentityDidChange`). A backup
    /// being built checks the account again before it moves anything in.
    func cloudAccountDidChange() {
        guard options.cloudBackupFeature, cloud.loaded else { return }
        Self.cloudLog.notice("iCloud identity changed")
        Task { await refreshCloudBackups() }
    }

    /// Stops future backups at once. `deleting` (asked separately, naming what goes) are the
    /// backups the user confirmed: exactly those are removed from iCloud, and only ones this
    /// device wrote. Other devices' backups are never touched.
    func disableCloudBackup(deleting doomed: [CloudBackupEntry] = []) {
        guard options.cloudBackupFeature, cloud.loaded, cloud.activity == nil else { return }
        cloud.settings.enabled = false
        cloud.settings.lastFailure = nil
        cloud.notice = nil
        saveCloudSettings()
        guard !doomed.isEmpty else {
            setCloudNotice(String(localized: "已停止备份到 iCloud 云盘。已有的备份还在 iCloud 云盘里。"), isFailure: false)
            return
        }
        // Only in the account the confirmed list was read from (audit A24-01). Without one, nothing
        // is deleted: the list on screen cannot be tied to an account.
        guard let lease = cloud.listedAccount else {
            setCloudNotice(String(localized: "已停止备份到 iCloud 云盘，但没能删除全部备份。剩下的可以在“文件”App 的 iCloud 云盘 › Meowverse 里删除。"), isFailure: true)
            return
        }
        cloud.activity = .deleting
        let destination = cloudDestination, deviceID = cloud.deviceID, names = doomed.map(\.name)
        cloud.task = Task {
            do {
                let count = try await Self.offMainAsync {
                    try CloudBackupEngine.deleteBackups(names, deviceID: deviceID, account: lease, in: destination)
                }
                cloud.settings.lastSuccess = nil
                saveCloudSettings()
                setCloudNotice(String(localized: "已停止备份到 iCloud 云盘，并删除了这台设备存的 \(count) 份备份。"), isFailure: false)
            } catch {
                setCloudNotice(String(localized: "已停止备份到 iCloud 云盘，但没能删除全部备份。剩下的可以在“文件”App 的 iCloud 云盘 › Meowverse 里删除。"), isFailure: true)
            }
            cloud.activity = nil
            await refreshCloudBackups()
        }
    }

    // MARK: Backup

    /// Writes a new backup when one is due (see `CloudBackupPolicy`). Does nothing unless the
    /// user turned iCloud backup on. A failure leaves every earlier backup as it was.
    func backUpToCloud(trigger: CloudBackupPolicy.Trigger) {
        guard options.cloudBackupFeature, cloud.loaded, cloud.settings.enabled, cloud.activity == nil, backup.busy == nil,
              phase == .ready, let store, let catalog else { return }
        // Nothing to do for an empty room; say so only when the user asked.
        if state.isEmptyForBackup {
            if trigger == .manual { setCloudNotice(Self.cloudSkipText(.emptyLibrary), isFailure: false) }
            return
        }
        if trigger == .manual { cloud.notice = nil }
        // This backup's number: progress, the background expiry and the end of the task act only
        // while it is still the current cloud operation (audit A24-10).
        cloud.generation += 1
        let generation = cloud.generation
        cloud.activity = .backingUp(0)
        cloud.cancelling = false
        let destination = cloudDestination, settings = cloud.settings
        let context = CloudBackupEngine.Context(
            deviceID: cloud.deviceID, deviceKind: UIDevice.current.model, appVersion: Self.appVersion,
            workDirectory: FileManager.default.temporaryDirectory.appending(path: Self.cloudWorkPrefix + UUID().uuidString, directoryHint: .isDirectory),
            catalog: catalog)
        let relay = ProgressRelay { [weak self] fraction in
            guard let self, generation == self.cloud.generation, case .backingUp = self.cloud.activity else { return }
            self.cloud.activity = .backingUp(fraction)
        }
        // A little more time when the app has just gone to the background. If it runs out the
        // work is cancelled; whatever was half-built is in the temporary folder, not in iCloud.
        let background = SyncBackgroundTask()
        // The handler must end the task itself, or the system ends the app: the cancelled work
        // can only get back to the main actor once the handler has returned.
        let expired: @MainActor @Sendable () -> Void = { [weak self] in
            // This backup's task only: a later download or delete is not stopped by it.
            if let self, generation == self.cloud.generation { self.cloud.task?.cancel() }
            background.end()
        }
        background.id = UIApplication.shared.beginBackgroundTask(withName: "CloudBackup", expirationHandler: expired)
        cloud.task = Task {
            let interval = Perf.signposter.beginInterval("CloudBackup")
            defer {
                Perf.signposter.endInterval("CloudBackup", interval)
                background.end()
            }
            do {
                let outcome = try await Self.offMainAsync {
                    try await CloudBackupEngine.backUpIfNeeded(store: store, destination: destination, settings: settings,
                                                               trigger: trigger, context: context) { relay.send($0) }
                }
                switch outcome {
                case .completed(let record):
                    // What is in iCloud now is a fact, whatever the user did meanwhile.
                    cloud.settings.lastSuccess = record
                    cloud.settings.lastFailure = nil
                    saveCloudSettings()
                    if trigger == .manual { setCloudNotice(String(localized: "备份完成并通过核对，已放进 iCloud 云盘，由系统上传。"), isFailure: false) }
                case .skipped(let reason):
                    if trigger == .manual { setCloudNotice(Self.cloudSkipText(reason), isFailure: false) }
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    if trigger == .manual, generation == cloud.generation {
                        setCloudNotice(String(localized: "已取消，没有写入新的备份。之前的备份没有受影响。"), isFailure: false)
                    }
                } else {
                    let code = Self.cloudFailureCode(error)
                    Self.cloudLog.error("cloud backup failed: \(code, privacy: .public)")
                    cloud.settings.lastFailure = .init(date: Date(), code: code)
                    saveCloudSettings()
                    if trigger == .manual { setCloudNotice(Self.cloudFailureText(code: code), isFailure: true) }
                }
            }
            // Stopped for a clear or restore (`stopCloudTransfersBeforeLibrarySwitch`): that caller
            // owns the state now.
            guard generation == cloud.generation else { return }
            cloud.activity = nil
            cloud.cancelling = false
            await refreshCloudBackups()
        }
        #if DEBUG || DRILLS
        // `-MeowverseBackupExpiryDrill`: the background time runs out now.
        if ProcessInfo.processInfo.arguments.contains("-MeowverseBackupExpiryDrill") {
            expired()
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Meowverse")
            try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            let state = background.id == .invalid ? "ended" : "live"
            try? Data(state.utf8).write(to: caches.appending(path: "backup-expiry-" + options.storeFolder), options: .atomic)
        }
        #endif
    }

    // MARK: Restore

    /// Makes the backup local, then hands the file to the ordinary restore: full verification,
    /// preview, and only after the user confirms the all-or-nothing switch.
    func restoreFromCloud(_ entry: CloudBackupEntry) {
        guard options.cloudBackupFeature, cloud.loaded, cloud.activity == nil, backup.busy == nil, entry.condition != .damaged else { return }
        cancelPendingRestore()
        cloud.notice = nil
        backup.notice = nil
        // Room for the download (unless it is already here) and for the verified copy the
        // restore builds beside the library. Checked first, so nothing half-fills the phone.
        // Checked arithmetic: a listed size is never trusted to fit (audit B24-01).
        if let size = entry.byteSize, let free = CloudBackupEngine.freeSpace(at: FileManager.default.temporaryDirectory),
           free < CloudBackupPolicy.restoreSpaceNeeded(byteSize: size, isDownloaded: entry.isDownloaded) {
            setCloudNotice(Self.cloudDownloadFailureText(CloudBackupError.io("space")), isFailure: true)
            return
        }
        cloud.generation += 1
        let generation = cloud.generation
        let archiveName = entry.name.archiveName
        cloud.activity = .downloading(archiveName: archiveName, fraction: entry.isDownloaded ? 1 : nil)
        let destination = cloudDestination
        let relay = ProgressRelay { [weak self] fraction in
            guard let self, generation == self.cloud.generation, case .downloading = self.cloud.activity else { return }
            self.cloud.activity = .downloading(archiveName: archiveName, fraction: fraction)
        }
        cloud.task = Task {
            do {
                let url = try await Self.offMainAsync {
                    try await destination.download(archiveName) { fraction in if let fraction { relay.send(fraction) } }
                }
                // Cancelled while it downloaded: the file may stay local, but nothing is opened.
                guard generation == cloud.generation, !Task.isCancelled else { return }
                // The file must be the one its info file describes (audit A24-07): another archive
                // under that name is not opened as this backup. Without an info file there is
                // nothing to compare; the restore's full verification still runs.
                if let info = entry.info {
                    let matches = try await Self.offMainAsync { info.describes(fileAt: url) }
                    guard generation == cloud.generation, !Task.isCancelled else { return }
                    guard matches else {
                        cloud.activity = nil
                        cloud.settings.rememberDamaged(archiveName)
                        saveCloudSettings()
                        setCloudNotice(Self.backupMessage(for: BackupError.damaged("cloudInfo"), during: .reading), isFailure: true)
                        await refreshCloudBackups()
                        return
                    }
                }
                cloud.activity = nil
                backup.lastReadError = nil
                openBackup(at: url)
                await backup.task?.value
                guard generation == cloud.generation else { return }
                switch backup.lastReadError {
                case .damaged, .notABackup:
                    // Not offered first again; an earlier backup in the list is.
                    cloud.settings.rememberDamaged(archiveName)
                    saveCloudSettings()
                    await refreshCloudBackups()
                default:
                    break
                }
            } catch {
                guard generation == cloud.generation else { return }
                cloud.activity = nil
                if !(Task.isCancelled || error is CancellationError) {
                    setCloudNotice(Self.cloudDownloadFailureText(error), isFailure: true)
                }
            }
        }
    }

    /// Stops a download at once (a late result is dropped), or asks a running backup to stop.
    func cancelCloudActivity() {
        switch cloud.activity {
        case .downloading:
            cloud.task?.cancel()
            cloud.generation += 1
            cloud.activity = nil
            setCloudNotice(String(localized: "已取消，房间没有任何改动。"), isFailure: false)
        case .backingUp:
            cloud.cancelling = true
            cloud.task?.cancel()
        case .deleting, nil:
            break
        }
    }

    /// Before a clear or a restore switches the library: a backup still running is stopped and
    /// waited for, so it cannot publish the old library afterwards, and a download still running
    /// is stopped, so it cannot open a preview over the new one (audit A24-02). Silent: the
    /// clear or restore says what happened.
    func stopCloudTransfersBeforeLibrarySwitch() async {
        guard let task = cloud.task else { return }
        switch cloud.activity {
        case .backingUp, .downloading: break
        case .deleting, nil: return
        }
        cloud.generation += 1
        task.cancel()
        await task.value
        cloud.activity = nil
        cloud.cancelling = false
    }

    func dismissCloudRestoreOffer() {
        cloud.settings.restoreOfferDismissed = true
        saveCloudSettings()
    }

    // MARK: Wording

    /// Back Up to iCloud Drive is on for this library. Before the settings are read at launch,
    /// the saved ones say: an unread setting must not read as "off" in a privacy sentence.
    var cloudBackupOn: Bool { currentCloudSettings?.enabled == true }

    /// Backups this device made are still in iCloud Drive, as far as this device knows: the
    /// last listing of the account they go to, or without a usable one, a last backup the app
    /// has not deleted. Not a fresh look: deleted in the Files app since, this is out of date
    /// until the next listing.
    var cloudBackupsLeft: Bool {
        guard let settings = currentCloudSettings else { return false }
        let listed = cloud.loaded && cloud.availability == .available && !cloud.listFailed
            && (cloud.account == .matches || { if case .adopt = cloud.account { true } else { false } }())
        return PhotoReach.backupsLeft(listedOwnBackups: listed ? cloudBackupsOfThisDevice.count : nil,
                                      lastBackupKept: settings.lastSuccess != nil,
                                      leftInAnotherAccount: settings.backupsLeftInAnotherAccount)
    }

    /// The settings as they are, or before they are read at launch, as saved: an unread setting
    /// must not read as "off" in a privacy sentence. nil with the feature off.
    private var currentCloudSettings: CloudBackupSettings? {
        guard options.cloudBackupFeature else { return nil }
        if cloud.loaded { return cloud.settings }
        return UserDefaults.standard.data(forKey: cloudSettingsKey)
            .flatMap { try? JSONDecoder().decode(CloudBackupSettings.self, from: $0) } ?? CloudBackupSettings()
    }

    /// Where the photo copies can go, or are still, besides this device. Every sentence that
    /// says photos stay here, or are never uploaded, asks this rather than one of the switches.
    var photoReach: PhotoReach {
        PhotoReach(backupOn: cloudBackupOn, syncOn: syncOnForThisLibrary,
                   backupsLeft: cloudBackupsLeft, syncDataLeft: syncDataLeftInICloud)
    }

    /// For the clear-all dialogs: what can still restore the library afterwards. Clearing does
    /// not touch iCloud Drive, so this device's backups there stay (and, with backup on, the
    /// next one of a refilled room rotates them out).
    var clearAllRestoreNote: String {
        // Any backup in this account's folder that could restore it: this device's, another
        // device's, or this device's own from before its id was remade. The empty room offers it.
        // Without a current listing that is unknown, and unknown is not "none" (audit A24-03).
        let presence: CloudBackupPolicy.Presence = options.cloudBackupFeature
            ? CloudBackupPolicy.presence(listingIsCurrent: cloudListingIsCurrent, entries: cloud.entries)
            : .none
        let restorable = presence == .some
        let backingUp = options.cloudBackupFeature && cloud.loaded && cloud.settings.enabled
        if presence == .unknown {
            return backingUp
                ? String(localized: "现在没能确认 iCloud 云盘里有没有喵空间的备份。如果有，它们不会跟着删除。备份到 iCloud 云盘仍然开着：房间里再有内容时会备份新的一份，并删掉这台设备存的旧备份。")
                : String(localized: "现在没能确认 iCloud 云盘里有没有喵空间的备份。如果有，它们不会跟着删除，可以在“文件”App 的 iCloud 云盘 › Meowverse 里查看。")
        }
        switch (restorable, backingUp) {
        case (true, true):
            return String(localized: "iCloud 云盘里的喵空间备份不会跟着删除，还能用来恢复。备份到 iCloud 云盘仍然开着：房间里再有内容时会备份新的一份，并删掉这台设备存的旧备份。要现在删除，请到“备份到 iCloud 云盘”里停止备份并删除，或在“文件”App 的 iCloud 云盘 › Meowverse 里删除。")
        case (true, false):
            return String(localized: "iCloud 云盘里的喵空间备份不会跟着删除，还能用来恢复。不需要的话，可以在“文件”App 的 iCloud 云盘 › Meowverse 里删除。")
        case (false, true):
            return String(localized: "只有导出过的备份能恢复这些内容。备份到 iCloud 云盘仍然开着，房间里再有内容时会再备份。")
        case (false, false):
            return String(localized: "只有导出过的备份能恢复这些内容。")
        }
    }

    /// `cloud.entries` are a fact about the account signed in: listed after launch, iCloud Drive
    /// reachable, the listing did not fail, and taken under one known account.
    private var cloudListingIsCurrent: Bool {
        cloud.loaded && cloud.availability == .available && !cloud.listFailed && cloud.listedAccount != nil
            && cloud.account != nil && cloud.account != .unknown
    }

    private func setCloudNotice(_ text: String, isFailure: Bool) {
        cloud.notice = .init(text: text, isFailure: isFailure)
        AccessibilityNotification.Announcement(text).post()
    }

    static func cloudSkipText(_ reason: CloudBackupPolicy.Skip) -> String {
        switch reason {
        case .disabled: String(localized: "备份到 iCloud 云盘没有打开。")
        case .otherAccount: String(localized: "这台设备现在登录的是另一个 Apple 账户，所以没有备份。请先选择要不要备份到这个账户。")
        case .accountUnconfirmed: String(localized: "还没确认要备份到现在登录的 Apple 账户，所以没有备份。请先在下面确认。")
        case .accountUnknown: String(localized: "没能确认现在登录的是哪个 Apple 账户，所以这次没有备份。")
        case .emptyLibrary: String(localized: "房间是空的，没有可以备份的内容。")
        case .unchanged: String(localized: "上次备份之后没有改动，不需要再备份。")
        case .tooSoon: String(localized: "今天已经备份过了。")
        }
    }

    /// A short code that is safe to store and log: never a path or a name.
    static func cloudFailureCode(_ error: any Error) -> String {
        CloudBackupEngine.failureCode(error)
    }

    static func cloudFailureText(code: String) -> String {
        switch code {
        case "tooLarge": String(localized: "照片库超过了备份格式的文件数或大小上限。请保留当前资料库，暂缓迁移或清空，等待支持更大备份的版本。")
        case "libraryDamaged": String(localized: "有照片找不到了，或者和导入时不一致，所以这次没有备份。可以在设置里用“核对照片和家具记录”查看。之前的备份没有受影响。")
        case "signedOut": String(localized: "这台设备没有登录 iCloud，或者没有打开 iCloud 云盘，所以这次没有备份。")
        case "containerUnavailable": String(localized: "喵空间现在用不了 iCloud 云盘，所以这次没有备份。")
        case "verification": String(localized: "新生成的备份没有通过核对，已经丢弃。之前的备份没有受影响。")
        case "space": String(localized: "这台设备的存储空间不够，这次没有备份。之前的备份没有受影响。")
        // iCloud, not this device, is full (audit B24-10).
        case "quota": String(localized: "iCloud 储存空间已满，这次没有备份。之前的备份没有受影响。")
        default: String(localized: "这次没能备份，可能是这台设备的存储空间不够。之前的备份没有受影响。")
        }
    }

    static func cloudDownloadFailureText(_ error: any Error) -> String {
        switch error {
        case CloudBackupError.offline: String(localized: "现在没有网络，没能从 iCloud 下载这份备份。房间没有任何改动，联网后可以再试。")
        case CloudBackupError.notFound: String(localized: "这份备份已经不在 iCloud 云盘里了。房间没有任何改动。")
        case CloudBackupError.unavailable: String(localized: "现在用不了 iCloud 云盘，没能下载这份备份。房间没有任何改动。")
        case CloudBackupError.io("space"): String(localized: "这台设备的存储空间不够，没能下载这份备份。房间没有任何改动。")
        default: String(localized: "没能从 iCloud 下载这份备份。房间没有任何改动，可以再试一次。")
        }
    }
}
