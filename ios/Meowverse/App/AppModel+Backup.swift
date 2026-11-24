import ActivityKit
import MeowverseCore
import os
import SwiftUI

/// Progress and results of the settings screen's export / restore / clear. One value, so
/// AppModel gains one property.
struct BackupUIState {
    enum Operation: Equatable {
        case exporting, reading, replacing, clearing
    }

    struct Busy: Equatable {
        var operation: Operation
        /// 0...1 while it can be measured.
        var fraction: Double
    }

    /// A finished export, still inside the app's temporary folder until the user saves or shares it.
    struct Exported: Equatable {
        var url: URL
        var summary: BackupSummary
    }

    struct Notice: Equatable {
        var text: String
        var isFailure: Bool
    }

    var busy: Busy?
    var exported: Exported?
    /// A verified backup waiting for the user's confirmation. Nothing has been replaced yet.
    var pending: PreparedLibrary?
    var notice: Notice?
    var usage: StorageUsage?
    /// Why the last `openBackup` did not produce a preview; nil when it did or was cancelled.
    var lastReadError: BackupError?
    /// Bumped for every operation and every cancel: a result that arrives for an older
    /// number is dropped instead of overriding what the user did since.
    var generation = 0
    var task: Task<Void, Never>?
}

/// Carries progress from a background executor to the main actor, at most once per percent.
final class ProgressRelay: Sendable {
    private let last = OSAllocatedUnfairLock(initialState: -1.0)
    private let deliver: @MainActor @Sendable (Double) -> Void

    init(deliver: @escaping @MainActor @Sendable (Double) -> Void) {
        self.deliver = deliver
    }

    nonisolated func send(_ fraction: Double) {
        let due = last.withLock { value -> Bool in
            guard fraction >= 1 || fraction - value >= 0.01 else { return false }
            value = fraction
            return true
        }
        guard due else { return }
        let deliver = self.deliver
        Task { @MainActor in deliver(fraction) }
    }
}

extension AppModel {
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    static let exportFolderPrefix = "MeowverseExport-"

    /// Heavy synchronous work off the main actor; cancelling the caller cancels the work.
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Storage

    // The cats' names are changed in 猫咪管理 (`renameCat`; the first cat's name is `catName`).

    func refreshStorageUsage() async {
        guard let store else { return }
        backup.usage = await store.storageUsage()
    }

    // MARK: Export

    func exportBackup() {
        guard backup.busy == nil, let store else { return }
        discardExport()
        backup.notice = nil
        let generation = beginBackupOperation(.exporting)
        let folder = FileManager.default.temporaryDirectory
            .appending(path: Self.exportFolderPrefix + UUID().uuidString, directoryHint: .isDirectory)
        let url = folder.appending(path: BackupArchive.defaultFilename(word: String(localized: "filename.backup", defaultValue: "备份", comment: "The word for backup inside the exported file name: Meowverse-备份-2026-11-11.zip")), directoryHint: .notDirectory)
        let version = Self.appVersion
        let relay = progressRelay(generation)
        backup.task = Task {
            let interval = Perf.signposter.beginInterval("ExportBackup")
            defer { Perf.signposter.endInterval("ExportBackup", interval) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let summary = try await store.exportBackup(to: url, appVersion: version) { relay.send($0.fraction) }
                // Cancelled (or superseded) while the last bytes were written: drop the file.
                guard generation == backup.generation, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: folder)
                    return
                }
                backup.exported = .init(url: url, summary: summary)
                finishBackupOperation(generation, notice: nil)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                finishBackupOperation(generation, notice: error is CancellationError ? nil
                                      : .init(text: Self.backupMessage(for: error, during: .exporting), isFailure: true))
            }
        }
    }

    /// Deletes an export the user has not saved (a new export, or leaving it behind).
    func discardExport() {
        if let exported = backup.exported {
            try? FileManager.default.removeItem(at: exported.url.deletingLastPathComponent())
        }
        backup.exported = nil
    }

    /// Exports that were never saved do not pile up in the temporary folder.
    func removeLeftoverExports() {
        let temp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [] where name.hasPrefix(Self.exportFolderPrefix) {
            try? FileManager.default.removeItem(at: temp.appending(path: name))
        }
    }

    // MARK: Restore / web import

    /// Reads and verifies a backup file and stages its content beside the library. Nothing is
    /// replaced: the result waits in `backup.pending` for the user's confirmation.
    func openBackup(at url: URL) {
        guard backup.busy == nil, let store, let catalog else { return }
        cancelPendingRestore()
        backup.notice = nil
        let generation = beginBackupOperation(.reading)
        let staging = store.makeStagingURL()
        let relay = progressRelay(generation)
        backup.task = Task {
            let interval = Perf.signposter.beginInterval("ReadBackup")
            defer { Perf.signposter.endInterval("ReadBackup", interval) }
            // A file picked in Files is only readable between these two calls.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let prepared = try await Self.offMain {
                    try BackupArchive.prepare(file: url, stagingURL: staging, catalog: catalog) { relay.send($0.fraction) }
                }
                guard generation == backup.generation, !Task.isCancelled else {
                    prepared.discard()
                    return
                }
                backup.pending = prepared
                finishBackupOperation(generation, notice: nil)
            } catch {
                if generation == backup.generation { backup.lastReadError = error as? BackupError }
                finishBackupOperation(generation, notice: error is CancellationError ? nil
                                      : .init(text: Self.backupMessage(for: error, during: .reading), isFailure: true))
            }
        }
    }

    /// The user looked at the preview and said no: the staged copy is deleted, the room is as it was.
    func cancelPendingRestore() {
        backup.pending?.discard()
        backup.pending = nil
    }

    /// The user confirmed the preview: the staged library replaces the current one in one step.
    func confirmRestore() {
        guard backup.busy == nil, let prepared = backup.pending, let store else { return }
        backup.pending = nil
        let recovering = phase == .corruptLibrary
        let generation = beginBackupOperation(.replacing)
        backup.task = Task {
            // Photos still arriving from a batch would land in the restored library.
            await stopPhotoImports()
            let undoSyncNote = noteLibraryReplacementForSync()
            do {
                let restored = try await store.replaceLibrary(with: prepared, recoveringCorruptLibrary: recovering)
                await libraryWasReplaced()
                // Stored pieces count too: the preview counted them.
                let (photos, pieces) = (restored.photos.count, restored.allFurniture.count)
                let message = prepared.preview.kind == .webBackup
                    ? String(localized: "网页版备份已导入：\(photos) 张照片、\(pieces) 件家具。")
                    : String(localized: "已从备份恢复：\(photos) 张照片、\(pieces) 件家具。")
                // With sync on, the restored library merges with iCloud like a first sync.
                let shown = sync.settings.enabled
                    ? Wording.sentences(message, String(localized: "iCloud 同步开着，它会和 iCloud 里的家合并。"))
                    : message
                finishBackupOperation(generation, notice: .init(text: shown, isFailure: false))
                if recovering { finishCorruptLibraryRecovery(notice: message) }
            } catch {
                undoSyncNote()
                prepared.discard()
                await republish()
                finishBackupOperation(generation, notice: .init(text: Self.backupMessage(for: error, during: .replacing), isFailure: true))
            }
        }
    }

    // MARK: Clear all

    /// What "清除全部数据" clears when iCloud sync is on (docs/ICLOUD_SYNC.md §7). With sync off
    /// there is only this device.
    enum ClearScope {
        /// This device only. Its sync is turned off first: left on, the cleared library would
        /// merge with iCloud like a first sync and get the home back. iCloud and the other
        /// devices are not touched.
        case thisDevice
        /// The home in iCloud too, as a deletion every syncing device takes; then this device.
        case everywhere
    }

    func clearAllData(_ scope: ClearScope = .thisDevice) {
        guard backup.busy == nil, let store else { return }
        cancelPendingRestore()
        let syncWasOn = sync.settings.enabled
        let everywhere = scope == .everywhere && syncWasOn
        // Before the clear: a cycle after it would merge the home back from iCloud.
        var syncOff: Task<Void, Never>?
        if syncWasOn, !everywhere {
            syncOff = disableCloudSync(notice: String(localized: "清除全部数据时关闭了这台设备的 iCloud 同步。iCloud 里的家和其他设备都没有动。"))
        }
        let generation = beginBackupOperation(.clearing)
        backup.task = Task {
            // Photos still arriving from a batch would land in the emptied library.
            await stopPhotoImports()
            // Not queued behind it: waited for. A cycle still out on the network when the empty
            // library came in retried on it and brought the whole home back (audit round 12,
            // SYNC-1). Once this returns that cycle has stopped and sync has forgotten the home.
            await syncOff?.value
            if everywhere {
                switch await deleteHomeInICloud() {
                case .done:
                    break
                case .unfinished(let problem):
                    finishBackupOperation(generation, notice: .init(text: Wording.sentences(
                        String(localized: "iCloud 里的家只删除了一部分，剩下的会在下次同步时接着删除，到时这台设备上的家也会跟着清空。"),
                        Self.syncProblemText(problem)), isFailure: true))
                    return
                case .failed(let problem):
                    finishBackupOperation(generation, notice: .init(text: Wording.sentences(
                        String(localized: "没能删除 iCloud 里的家，哪里都没有清除。"), Self.syncProblemText(problem)), isFailure: true))
                    return
                }
            }
            let undoSyncNote = noteLibraryReplacementForSync()
            #if DEBUG || DRILLS
            await ClearedNotificationsDrill.deliverOne()
            #endif
            do {
                try await store.clearAll()
                await libraryWasReplaced()
                await endWhatStillShowsTheClearedHome()
                let text = everywhere
                    ? String(localized: "已删除 iCloud 里的家，也清除了这台设备上的全部数据。其他设备同步后也会清空。")
                    : syncWasOn
                    ? String(localized: "已清除这台设备上的全部数据，这台设备的 iCloud 同步也已关闭。iCloud 里的家和其他设备都没有动。")
                    : String(localized: "已清除全部数据。房间现在是空的。")
                finishBackupOperation(generation, notice: .init(text: text, isFailure: false))
                #if DEBUG || DRILLS
                await ClearedNotificationsDrill.writeCount(store: options.storeFolder)
                #endif
            } catch StoreError.clearCleanupPending {
                await libraryWasReplaced()
                await endWhatStillShowsTheClearedHome()
                finishBackupOperation(generation, notice: .init(text: String(localized: "房间已清空，旧资料库的本地副本还未清理完。请再次选择清除全部数据。"), isFailure: true))
            } catch {
                undoSyncNote()
                await republish()
                // The home in iCloud is gone already: the next cycle empties this library from it.
                let text = everywhere
                    ? String(localized: "iCloud 里的家已删除，但这台设备上的数据没能清除。下次同步时会跟着清空，也可以再试一次。")
                    : syncWasOn
                    ? String(localized: "没能清除。照片和家具都还在，和之前一样。这台设备的 iCloud 同步已关闭。可以再试一次。")
                    : String(localized: "没能清除。照片和家具都还在，和之前一样。可以再试一次。")
                finishBackupOperation(generation, notice: .init(text: text, isFailure: true))
            }
        }
    }

    // MARK: Cancel

    /// Stops a running export or read. The switch itself (replace, clear) is a single step
    /// and is not cancellable.
    func cancelBackupOperation() {
        guard let busy = backup.busy, busy.operation == .exporting || busy.operation == .reading else { return }
        backup.task?.cancel()
        backup.generation += 1
        backup.busy = nil
        backup.notice = .init(text: busy.operation == .exporting ? String(localized: "已取消导出，没有生成文件。") : String(localized: "已取消，房间没有任何改动。"), isFailure: false)
    }

    // MARK: Internals

    private func beginBackupOperation(_ operation: BackupUIState.Operation) -> Int {
        backup.generation += 1
        backup.busy = .init(operation: operation, fraction: 0)
        return backup.generation
    }

    private func finishBackupOperation(_ generation: Int, notice: BackupUIState.Notice?) {
        guard generation == backup.generation else { return }
        backup.busy = nil
        if let notice {
            backup.notice = notice
            AccessibilityNotification.Announcement(notice.text).post()
        }
        Task { await refreshStorageUsage() }
    }

    private func progressRelay(_ generation: Int) -> ProgressRelay {
        ProgressRelay { [weak self] fraction in
            guard let self, generation == self.backup.generation, self.backup.busy != nil else { return }
            self.backup.busy?.fraction = fraction
        }
    }

    /// Everything on screen that pointed into the old library is closed.
    /// Company and delivered reminders carry the cat's and the furniture's names outside the app.
    private func endWhatStillShowsTheClearedHome() async {
        let company = PocketCatActivity.activities
        for activity in company { await activity.end(nil, dismissalPolicy: .immediate) }
        PocketCatCompanyMirror.endedAll(company.map(\.id))
        SystemNotificationCenter().removeDelivered()
    }

    private func libraryWasReplaced() async {
        openedFurnitureID = nil
        movingFurnitureID = nil
        restoringFurnitureID = nil
        addFurnitureShown = false
        importSession = nil
        // A held capture left with the old library folder (`PendingCapture`).
        pendingCaptureOffer = nil
        clearBatchQueue()
        photos = PhotoUIState()
        pieces = FurnitureUIState()
        home = HomeUIState()
        bellaStatus = .atEntrance
        await republish()
        if let store { libraryGeneration = await store.generation }
        await forgetFeaturePrints()
    }

    static func backupMessage(for error: any Error, during operation: BackupUIState.Operation) -> String {
        let untouched = String(localized: "现在的房间没有任何改动。")
        if let error = error as? BackupError {
            switch error {
            case .notABackup: return Wording.sentences(String(localized: "这个文件不是喵空间的备份，或者文件不完整。"), untouched)
            case .damaged: return Wording.sentences(String(localized: "这份备份不完整或者已经损坏，校验没有通过。"), untouched)
            case .tooLarge:
                return operation == .exporting
                    ? String(localized: "照片库超过了备份格式的文件数或大小上限。请保留当前资料库，暂缓迁移或清空，等待支持更大备份的版本。")
                    : Wording.sentences(String(localized: "这份备份超过了可以读取的大小。"), untouched)
            case .newerVersion: return Wording.sentences(String(localized: "这份备份来自更新版本的喵空间，请先更新 App 再恢复。"), untouched)
            case .unsupportedVersion: return Wording.sentences(String(localized: "这是旧版网页存档。请在网页版里打开一次、重新导出，再导入。"), untouched)
            case .unreadablePhotos(let count): return Wording.sentences(String(localized: "备份里有 \(count) 张照片这台设备读不出来。为了不丢照片，这次没有导入。"), untouched)
            case .libraryDamaged(let count): return String(localized: "有 \(count) 张照片找不到了，或者和导入时不一致，所以没有生成备份。可以用下面的“核对照片和家具记录”查看。照片库没有改动。")
            case .stale: return Wording.sentences(String(localized: "这份备份的预览已经失效，请重新选择文件。"), untouched)
            }
        }
        switch operation {
        case .exporting: return String(localized: "没能生成备份，可能是存储空间不够。照片库没有改动，可以再试一次。")
        case .reading: return Wording.sentences(String(localized: "没能读取这份备份，可能是存储空间不够。"), untouched)
        case .replacing: return String(localized: "没能替换。现在的房间和之前一样，可以再试一次。")
        case .clearing: return String(localized: "没能清除。照片和家具都还在，和之前一样。")
        }
    }
}

extension BackupNote {
    /// Things in a web backup that the iPhone app has no place for.
    var isNotCarriedOver: Bool {
        switch self {
        case .classicFurniture, .customModels, .customCat, .analysisRecords, .photoAnnotations, .reviewMarks, .roomTheme, .unknownModels: true
        case .sourcesMadeManual, .datesFromFile, .catNameShortened, .thumbnailsRebuilt: false
        }
    }

    var line: String {
        switch self {
        case .classicFurniture(let count): String(localized: "经典模式里的 \(count) 件家具（App 里只有网格房间）")
        case .customModels(let count): String(localized: "\(count) 个自己导入的 3D 家具模型")
        case .customCat: String(localized: "自己导入的猫咪 3D 模型（这里用内置的猫咪）")
        case .analysisRecords(let runs, let consents, let observations):
            String(localized: "云端分析的记录：\(runs) 次分析、\(consents) 条同意记录、\(observations) 条没有用在家具上的识别结果")
        case .photoAnnotations(let count): String(localized: "\(count) 张照片的类别修正和自定义标签")
        case .reviewMarks(let count): String(localized: "\(count) 张照片的“已校对”标记")
        case .roomTheme: String(localized: "房间的配色主题")
        case .unknownModels(let names):
            String(localized: "这个版本没有的家具款式：\(names.map(Wording.quoted).joined(separator: String(localized: "、")))。它们的照片会留在照片库里")
        case .sourcesMadeManual(let count): String(localized: "\(count) 张照片的识别记录对不上，改为“由你手动选择”；照片仍在原来的家具里")
        case .datesFromFile(let count): String(localized: "\(count) 张照片标着“来自照片信息”的日期和文件里读到的不一样，以文件为准")
        case .catNameShortened: String(localized: "猫咪的名字超过 \(AppState.maxCatNameLength) 个字，只保留前面的部分")
        case .thumbnailsRebuilt: String(localized: "缩略图会重新生成，照片不变")
        }
    }
}
