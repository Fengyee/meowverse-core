import MeowverseCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings: storage, backup / restore / web import, the integrity check, clear all, and About.
/// The cats' names and the cat model live in 猫咪管理 in the room's top band; a row here opens it.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var integrity: AppModel.IntegritySummary?
    @State private var checking = false
    @State private var importerShown = false
    @State private var clearAsked = false
    @State private var clearWords = ""
    @State private var clearConfirmAsked = false
    @State private var clearScopeAsked = false
    @State private var clearEverywhereAsked = false
    @State private var clearScope = AppModel.ClearScope.thisDevice
    @AppStorage(InAppCamera.savesToPhotosKey) private var cameraSavesToPhotos = true

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                LabourOfLoveSection()
                catsSection
                AppIconSettings()
                storageSection
                backupSection
                clearSection
                Section {
                    // First in the last group, above 提醒 (PRODUCT_PLAN §4.1). A test library
                    // without `-MeowverseTour` has no tour, so no row.
                    if TourLaunch.isEnabled {
                        NavigationLink { TourReplayView { dismiss() } } label: {
                            Label(TourReplayView.rowTitle, systemImage: "map")
                        }
                        .accessibilityIdentifier("open-tour")
                    }
                    NavigationLink { ReminderSettingsView() } label: {
                        Label("提醒", systemImage: "bell")
                    }
                    .accessibilityIdentifier("open-reminders")
                    // 14.2's window; Settings scrolls to it while chapter 14 is on (Q-05).
                    .tourAnchor("open-reminders", cover: .row)
                    .id("open-reminders")
                    NavigationLink { FeedbackView() } label: {
                        Label("反馈问题", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                    }
                    .accessibilityIdentifier("open-feedback")
                    NavigationLink { WishView() } label: {
                        Label("我想要这个", systemImage: "lightbulb")
                    }
                    .accessibilityIdentifier("open-wish")
                    NavigationLink { AboutView() } label: {
                        Label("关于与隐私", systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("open-about")
                }
                // Last, so no row other tests reach by scrolling moves.
                RenderQualitySection()
            }
            .tourScrolls(proxy, to: ["open-reminders"])
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("close-settings")
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .interactiveDismissDisabled(model.backup.busy != nil)
        .onDisappear {
            // Leaving settings: an unconfirmed preview is dropped, and an export that was not
            // saved does not stay behind as a second copy of every photo.
            model.cancelPendingRestore()
            if model.backup.busy == nil { model.discardExport() }
        }
        .task { await model.refreshStorageUsage() }
        .onChange(of: model.libraryGeneration) { _, _ in integrity = nil }
        .onChange(of: model.state.revision) { _, _ in integrity = nil }
        // iPhone backups and web backups both come in as a ZIP.
        .fileImporter(isPresented: $importerShown, allowedContentTypes: [.zip]) { result in
            guard case .success(let url) = result else { return }
            model.openBackup(at: url)
        }
        .sheet(isPresented: pendingBinding) {
            if let prepared = model.backup.pending {
                RestorePreviewView(preview: prepared.preview)
            }
        }
        .confirmationDialog("清除全部数据？", isPresented: $clearAsked, titleVisibility: .visible) {
            Button("先导出备份") { model.exportBackup() }
                .accessibilityIdentifier("clear-all-export-first")
            Button("继续清除", role: .destructive) {
                // With sync on, one more question: this device only, or the home in iCloud too.
                if model.sync.settings.enabled { clearScopeAsked = true } else { clearScope = .thisDevice; clearConfirmAsked = true }
            }
                .accessibilityIdentifier("clear-all-continue")
            Button("取消", role: .cancel) {}
        } message: {
            Text(clearWords)
        }
        .confirmationDialog("iCloud 里的家也要删除吗？", isPresented: $clearScopeAsked, titleVisibility: .visible) {
            Button("只清除这台设备上的家") { clearScope = .thisDevice; clearConfirmAsked = true }
                .accessibilityIdentifier("clear-all-this-device")
            Button("也删除 iCloud 里的家", role: .destructive) { clearScope = .everywhere; clearEverywhereAsked = true }
                .accessibilityIdentifier("clear-all-everywhere")
            Button("取消", role: .cancel) {}
                .accessibilityIdentifier("clear-all-scope-cancel")
        } message: {
            Text("iCloud 同步开着。只清除这台设备上的家：iCloud 里的家和其他设备都不动，这台设备的 iCloud 同步会关闭，否则 iCloud 里的家会同步回来。也删除 iCloud 里的家：所有打开了同步的设备上的家都会被清空。")
        }
        .alert("最后确认", isPresented: $clearConfirmAsked) {
            Button("全部清除", role: .destructive) { model.clearAllData(clearScope) }
                .accessibilityIdentifier("clear-all-confirm")
            Button("取消", role: .cancel) {}
        } message: {
            if model.sync.settings.enabled {
                Text(Wording.sentences(String(localized: "清除后无法撤销。"), model.clearAllRestoreNote,
                                       String(localized: "这台设备的 iCloud 同步会关闭，iCloud 里的家和其他设备不受影响。")))
            } else {
                Text(Wording.sentences(String(localized: "清除后无法撤销。"), model.clearAllRestoreNote))
            }
        }
        .alert("删除所有设备上的家？", isPresented: $clearEverywhereAsked) {
            Button("全部删除", role: .destructive) { model.clearAllData(.everywhere) }
                .accessibilityIdentifier("clear-all-everywhere-confirm")
            Button("取消", role: .cancel) {}
        } message: {
            Text(Wording.sentences(
                String(localized: "iCloud 里的家会被删除。所有登录同一个 Apple 账户、打开了 iCloud 同步的 iPhone 和 iPad 上，照片、家具、房间和猫咪也会一起被清空。无法撤销。"),
                model.clearAllRestoreNote, unsavedPhotosWarning))
        }
    }

    // MARK: Cats

    /// The cats' names and the cat model moved to 猫咪管理 (round 10). This row leads there: it
    /// closes 设置 and the room opens 猫咪管理. Closing 设置 any other way opens nothing.
    private var catsSection: some View {
        Section {
            // Looks like the navigation rows below it, but 猫咪管理 is the room's own page:
            // 设置 closes and the room opens it (`HomeUIState.catsAfterSettings`).
            Button {
                model.home.catsAfterSettings = true
                dismiss()
            } label: {
                HStack {
                    Label("猫咪的名字和模型", systemImage: "pawprint")
                        .foregroundStyle(Color.primary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .accessibilityHint("关闭设置，打开猫咪管理。")
            .accessibilityIdentifier("open-cats-from-settings")
        } header: {
            Text("猫咪")
        }
    }

    // MARK: Storage and integrity

    private var storageSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(model.state.photos.count) 张照片、\(model.furnitureCount) 件家具")
                if let usage = model.backup.usage {
                    Text("占用 \(ByteCountFormatter.string(fromByteCount: Int64(usage.bytes), countStyle: .file))")
                        .font(.subheadline)
                        .foregroundStyle(Color.subtle)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("storage-usage")
            PhotoLibraryLinkRow()
            if InAppCamera.isAvailable {
                Toggle(isOn: $cameraSavesToPhotos) {
                    Text("拍的照片也存进“照片”")
                    Text("在喵空间里拍的照片会另存一份到系统相册，删除 App 后仍然保留。没有存进相册的照片，喵空间会保存完整原图，占用的空间更多。")
                }
                .accessibilityIdentifier("camera-saves-to-photos")
            }
            Button {
                checking = true
                Task {
                    let generation = model.libraryGeneration, revision = model.state.revision
                    let result = await model.checkIntegrity()
                    if model.libraryGeneration == generation, model.state.revision == revision { integrity = result }
                    checking = false
                }
            } label: {
                HStack {
                    Text("核对照片和家具记录")
                    if checking { Spacer(); ProgressView() }
                }
            }
            .buttonStyle(.listCommand)
            .disabled(checking || model.backup.busy != nil)
            .accessibilityIdentifier("check-integrity")
            if let integrity {
                Text(integrity.problems == 0
                     ? "\(integrity.furniture) 件家具、\(integrity.photos) 张照片，全部和导入时一致。"
                     : "\(integrity.furniture) 件家具、\(integrity.photos) 张照片，其中 \(integrity.verifiedOriginals) 张和导入时一致，另有 \(integrity.problems) 处对不上。")
                    .font(.subheadline)
                    .foregroundStyle(integrity.problems == 0 ? Color.subtle : Color.caution)
                    .accessibilityIdentifier("integrity-result")
            }
        } header: {
            Text("存储")
        }
    }

    // MARK: Backup

    private var backupSection: some View {
        Section {
            if let busy = model.backup.busy {
                busyRow(busy)
            }
            if let notice = model.backup.notice {
                NoticeLabel(text: notice.text, isFailure: notice.isFailure)
                    .accessibilityIdentifier("backup-notice")
            }
            Button("导出备份", systemImage: "arrow.up.doc") { model.exportBackup() }
                .buttonStyle(.listCommand)
                .disabled(model.backup.busy != nil)
                .accessibilityHint("把全部照片和房间记录打包成一个文件，由你决定存到哪里。")
                .accessibilityIdentifier("export-backup")
            if let exported = model.backup.exported {
                VStack(alignment: .leading, spacing: 8) {
                    Text("备份已生成：\(exported.summary.photoCount) 张照片、\(exported.summary.furnitureCount) 件家具，\(ByteCountFormatter.string(fromByteCount: Int64(exported.summary.byteSize), countStyle: .file))。把它存到别处，备份才算完成。")
                        .font(.subheadline)
                        .accessibilityIdentifier("export-result")
                    ShareLink(item: exported.url) {
                        Label("保存或分享备份文件", systemImage: "square.and.arrow.up")
                            .prominentInk()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("share-backup")
                }
                .padding(.vertical, 4)
            }
            Button("从备份恢复…", systemImage: "clock.arrow.circlepath") { importerShown = true }
                .buttonStyle(.listCommand)
                .disabled(model.backup.busy != nil)
                .accessibilityHint("选择一份 App 导出的备份。会先显示备份内容，确认后才替换。")
                .accessibilityIdentifier("restore-backup")
            Button("导入网页版备份…", systemImage: "globe") { importerShown = true }
                .buttonStyle(.listCommand)
                .disabled(model.backup.busy != nil)
                .accessibilityHint("选择网页版导出的 ZIP 备份。会先显示哪些内容能带过来。")
                .accessibilityIdentifier("import-web-backup")
            if model.options.cloudBackupFeature {
                NavigationLink { ICloudBackupView() } label: { ICloudBackupSettingsRow() }
                    .accessibilityIdentifier("open-icloud-backup")
            }
            if model.options.cloudSyncFeature {
                NavigationLink { ICloudSyncView() } label: { Label("iCloud 同步", systemImage: "arrow.triangle.2.circlepath.icloud") }
                    .accessibilityIdentifier("open-icloud-sync")
            }
            #if DEBUG || DRILLS
            drillButtons
            #endif
        } header: {
            Text("备份与恢复")
        } footer: {
            // Only the exported file is never uploaded: Back Up to iCloud Drive, in this section, is.
            Text("导出的备份文件包含全部照片和房间记录，存到哪里由你决定，喵空间不会上传它。恢复前会先显示备份内容，确认后才替换现在的房间。")
                .accessibilityIdentifier("backup-footer")
        }
    }

    private func busyRow(_ busy: BackupUIState.Busy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch busy.operation {
            case .exporting, .reading:
                ProgressView(value: busy.fraction) {
                    Text(busy.operation == .exporting ? "正在核对照片并打包…" : "正在读取并核对备份…")
                }
                .accessibilityIdentifier("backup-progress")
                Button("取消", role: .cancel) { model.cancelBackupOperation() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("cancel-backup-operation")
            case .replacing, .clearing:
                ProgressView(busy.operation == .replacing ? "正在替换房间…" : "正在清除…")
            }
        }
        .padding(.vertical, 4)
    }

    #if DEBUG || DRILLS
    @ViewBuilder private var drillButtons: some View {
        if model.options.backupDrill, let exported = model.backup.exported {
            Button("演练：恢复刚导出的备份") { model.openBackup(at: exported.url) }
                .buttonStyle(.listCommand)
                .disabled(model.backup.busy != nil)
                .accessibilityIdentifier("drill-restore-last-export")
        }
        if let path = model.options.backupFile {
            Button("演练：打开指定的备份文件") { model.openBackup(at: URL(fileURLWithPath: path)) }
                .buttonStyle(.listCommand)
                .disabled(model.backup.busy != nil)
                .accessibilityIdentifier("drill-open-backup-file")
        }
    }
    #endif

    private var pendingBinding: Binding<Bool> {
        Binding(get: { model.backup.pending != nil }, set: { if !$0 { model.cancelPendingRestore() } })
    }

    // MARK: Clear

    private var clearSection: some View {
        Section {
            Button("清除全部数据", systemImage: "trash", role: .destructive) { askToClear() }
                .buttonStyle(.listCommand)
                .disabled(model.backup.busy != nil)
                .accessibilityIdentifier("clear-all")
        } footer: {
            Text(Wording.sentences(String(localized: "删除喵空间里的全部照片、家具、便签和猫咪的名字。"), unsavedPhotosWarning))
        }
    }

    /// Where nothing can be confirmed: before asking, and for the other devices' photos.
    private var unsavedPhotosWarning: String {
        String(localized: "没有存进系统相册的照片，喵空间里的可能是唯一一份。")
    }

    private func askToClear() {
        Task {
            let photos = model.state.photos.map(\.photoId)
            let loss = await model.photoLoss(photos)
            let what = String(localized: "会删除喵空间里的 \(photos.count) 张照片、\(model.furnitureCount) 件家具、全部便签和猫咪的名字，无法撤销。")
            let advice = String(localized: "建议先导出一份备份并存好。")
            // Sync's reach is the next question, which asks where to clear.
            clearWords = photos.isEmpty ? Wording.sentences(what, advice) : Wording.sentences(what, Wording.originalsLine(loss), advice)
            clearAsked = true
        }
    }
}

/// What a picked backup contains, before anything is replaced.
struct RestorePreviewView: View {
    @Environment(AppModel.self) private var model
    let preview: BackupPreview

    var body: some View {
        NavigationStack {
            List {
                Section("这份备份") {
                    summaryRow(preview.kind == .webBackup ? "网页版备份" : "App 备份",
                          systemImage: preview.kind == .webBackup ? "globe" : "iphone")
                        .accessibilityIdentifier("preview-kind")
                    Label("创建于 \(preview.createdAt.formatted(Date.FormatStyle(date: .long, time: .shortened, locale: AppLanguage.locale)))",
                          systemImage: "calendar")
                    Label(versionLine, systemImage: "info.circle")
                    summaryRow("\(preview.photoCount) 张照片，共 \(ByteCountFormatter.string(fromByteCount: Int64(preview.originalBytes), countStyle: .file))",
                          systemImage: "photo.on.rectangle.angled")
                        .accessibilityIdentifier("preview-photos")
                    summaryRow("\(preview.furnitureCount) 件家具", systemImage: "sofa")
                        .accessibilityIdentifier("preview-furniture")
                    // Merged, the name in use may well stay: it is the backup's name that is shown.
                    Label(merges ? "备份里猫咪叫「\(preview.catName)」" : "猫咪叫「\(preview.catName)」", systemImage: "pawprint")
                        .accessibilityIdentifier("preview-cat")
                    Label("每张照片都核对过，和备份时一致。", systemImage: "checkmark.seal")
                }
                let dropped = preview.notes.filter(\.isNotCarriedOver), adjusted = preview.notes.filter { !$0.isNotCarriedOver }
                if !dropped.isEmpty {
                    Section {
                        ForEach(Array(dropped.enumerated()), id: \.offset) { _, note in
                            Label(note.line, systemImage: "minus.circle")
                        }
                    } header: {
                        Text("不会带过来")
                    } footer: {
                        Text("App 暂不支持这些内容。它们仍保存在备份文件里。")
                    }
                    .accessibilityIdentifier("preview-dropped")
                }
                if !adjusted.isEmpty {
                    Section("带过来时有调整") {
                        ForEach(Array(adjusted.enumerated()), id: \.offset) { _, note in
                            Label(note.line, systemImage: "pencil.circle")
                        }
                    }
                }
                Section {
                    Text(replaceWarning)
                        .foregroundStyle(currentIsEmpty ? Color.primary : Color.caution)
                        .accessibilityIdentifier("preview-warning")
                    Button(merges ? "恢复并合并" : currentIsEmpty ? "把备份放进房间" : "替换现有内容",
                           role: currentIsEmpty ? nil : .destructive) { model.confirmRestore() }
                        .accessibilityIdentifier("confirm-restore")
                    Button("不恢复", role: .cancel) { model.cancelPendingRestore() }
                        .accessibilityIdentifier("cancel-restore")
                }
            }
            .navigationTitle(preview.kind == .webBackup ? "导入网页版备份" : "从备份恢复")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func summaryRow(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
    }

    private var currentIsEmpty: Bool { model.phase != .corruptLibrary && model.state.isEmptyForBackup }
    /// With sync on, the restored library merges with the home in iCloud.
    private var merges: Bool { model.phase != .corruptLibrary && model.cloudSyncOn }

    private var versionLine: String {
        if preview.kind == .webBackup { return String(localized: "网页版数据格式第 \(preview.schemaVersion) 版") }
        if let app = preview.appVersion, !app.isEmpty { return String(localized: "由喵空间 \(app) 导出") }
        return String(localized: "数据格式第 \(preview.schemaVersion) 版")
    }

    private var replaceWarning: String {
        if model.phase == .corruptLibrary { return String(localized: "确认后会使用这份备份打开房间。损坏的资料库会单独保存在本机。") }
        if merges {
            return String(localized: "iCloud 同步开着：确认后，这台设备先换成这份备份，再和 iCloud 里的家合并。备份之后删掉的内容会回到所有同步的设备上；备份之后改过并已同步的内容大多保持现在的样子。这台设备上还没同步的改动会被替换，无法撤销。要让这台设备整份回到备份那时，请先取消并关闭同步。")
        }
        return currentIsEmpty
            ? String(localized: "现在的房间是空的。确认后，备份里的内容会放进来。")
            : String(localized: "确认后，这份备份会替换你已有的所有房间和猫咪，以及 \(model.state.photos.count) 张照片和 \(model.furnitureCount) 件家具。此操作无法撤销。如需保留，请先取消并导出备份。")
    }
}
