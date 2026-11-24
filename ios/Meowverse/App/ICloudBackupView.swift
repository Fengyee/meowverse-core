import MeowverseCore
import SwiftUI

/// Settings › 备份到 iCloud 云盘 (Back Up to iCloud Drive): the switch (with consent), the honest status, "back up now", and the
/// way into restoring. Only reachable while the feature is on (`LaunchOptions.cloudBackupFeature`).
struct ICloudBackupView: View {
    @Environment(AppModel.self) private var model
    @State private var consentShown = false
    @State private var disableAsked = false
    @State private var deleteAsked = false

    var body: some View {
        List {
            Section {
                Toggle("备份到 iCloud 云盘", isOn: enabledBinding)
                    .disabled(!model.cloud.loaded || model.cloud.activity != nil)
                    .accessibilityHint("把全部照片和房间记录自动存到你自己的 iCloud 云盘。打开前会先说明存什么。")
                    .accessibilityIdentifier("icloud-backup-toggle")
                ICloudBackupStatusView()
                if case .backingUp(let fraction) = model.cloud.activity {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: fraction) {
                            if model.cloud.cancelling {
                                Text("正在停止…")
                            } else {
                                Text("正在核对照片、打包并检查备份…")
                            }
                        }
                        .accessibilityIdentifier("icloud-backup-progress")
                        Button("取消", role: .cancel) { model.cancelCloudActivity() }
                            .buttonStyle(.bordered)
                            .disabled(model.cloud.cancelling)
                            .accessibilityIdentifier("icloud-backup-cancel")
                    }
                    .padding(.vertical, 4)
                } else if model.cloud.activity == .deleting {
                    ProgressView("正在删除备份…")
                }
                if let notice = model.cloud.notice {
                    NoticeLabel(text: notice.text, isFailure: notice.isFailure)
                        .accessibilityIdentifier("icloud-backup-notice")
                }
                Button("立即备份", systemImage: "icloud.and.arrow.up") { model.backUpToCloud(trigger: .manual) }
                    .buttonStyle(.listCommand)
                    .disabled(!canBackUpNow)
                    .accessibilityHint("现在就生成一份新的备份。房间没有改动时不会重复备份。")
                    .accessibilityIdentifier("icloud-backup-now")
            } footer: {
                // With iCloud sync on the app itself talks to CloudKit: say how, not "never".
                if model.cloudSyncOn {
                    Text("备份存在你自己的 iCloud 云盘里（“文件”App › iCloud 云盘 › Meowverse），由系统上传。你还打开了 iCloud 同步，喵空间会通过 Apple 的 iCloud 和你自己的设备同步，开发者拿不到这些数据。房间有改动时，打开或离开 App 时会自动备份，最多每天一次。")
                } else {
                    Text("备份存在你自己的 iCloud 云盘里（“文件”App › iCloud 云盘 › Meowverse），由系统上传。备份这一步喵空间自己不联网。房间有改动时，打开或离开 App 时会自动备份，最多每天一次。")
                }
            }
            if model.cloud.waitsForAccountAnswer {
                accountDecisionSection
            }
            Section {
                NavigationLink {
                    ICloudRestoreList()
                } label: {
                    Label("从 iCloud 云盘恢复…", systemImage: "icloud.and.arrow.down")
                }
                .disabled(model.backup.busy != nil || model.cloud.activity == .deleting)
                .accessibilityIdentifier("icloud-restore")
            } footer: {
                Text("会先显示备份内容，确认后才替换现在的房间。")
            }
        }
        .navigationTitle("备份到 iCloud 云盘")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.refreshStorageUsage()
            await model.refreshCloudBackups()
        }
        .refreshable { await model.refreshCloudBackups() }
        .sheet(isPresented: $consentShown) {
            ICloudConsentView { model.enableCloudBackup() }
        }
        .confirmationDialog("停止备份到 iCloud 云盘？", isPresented: $disableAsked, titleVisibility: .visible) {
            Button("关闭，保留已有备份") { model.disableCloudBackup() }
                .accessibilityIdentifier("icloud-disable-keep")
            if !ownBackups.isEmpty {
                Button("关闭并删除这些备份…", role: .destructive) { deleteAsked = true }
                    .accessibilityIdentifier("icloud-disable-delete")
            }
            Button("取消", role: .cancel) {}
        } message: {
            if ownBackups.isEmpty {
                Text("以后不会再自动备份。")
            } else {
                Text("以后不会再自动备份。这台设备已经存在 iCloud 云盘里的 \(ownBackups.count) 份备份要留着吗？")
            }
        }
        .alert(deleteTitle, isPresented: $deleteAsked) {
            // The list is fixed now: exactly these files are deleted, nothing that appears later.
            let doomed = ownBackups
            Button(deleteButtonTitle(doomed.count), role: .destructive) { model.disableCloudBackup(deleting: doomed) }
                .accessibilityIdentifier("icloud-delete-confirm")
            Button("取消", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    private var enabledBinding: Binding<Bool> {
        // The switch only asks; the consent sheet or the dialog decides.
        Binding(get: { model.cloud.settings.enabled }, set: { wanted in
            if wanted { consentShown = true } else { disableAsked = true }
        })
    }

    private var canBackUpNow: Bool {
        model.cloud.settings.enabled && model.cloud.availability == .available && model.cloud.activity == nil && model.backup.busy == nil
            && !model.cloud.waitsForAccountAnswer
    }

    /// Another Apple Account, or one never compared: nothing goes into it until the user chooses here.
    private var accountDecisionSection: some View {
        let another = model.cloud.account == .differs
        return Section {
            Button(another ? "继续备份到现在的账户" : "备份到现在登录的账户") { model.keepCloudBackupOnCurrentAccount() }
                .buttonStyle(.listCommand)
                .disabled(model.cloud.activity != nil)
                .accessibilityHint("以后把这台设备上的全部照片和房间记录备份到现在登录的 Apple 账户的 iCloud 云盘。")
                .accessibilityIdentifier("icloud-backup-account-keep")
            Button("停止备份到 iCloud 云盘", role: .destructive) { model.disableCloudBackup() }
                .buttonStyle(.listCommand)
                .disabled(model.cloud.activity != nil)
                .accessibilityIdentifier("icloud-backup-account-off")
        } header: {
            Text("需要你决定")
        } footer: {
            if another {
                Text("选好之前，不会往现在的账户里存任何东西。原来账户里的备份留在原来的账户里。")
            } else {
                Text("确认之前，不会往 iCloud 云盘里存任何东西。")
            }
        }
    }

    private var ownBackups: [CloudBackupEntry] { model.cloudBackupsOfThisDevice }

    private var deleteTitle: String {
        String(localized: "删除 \(ownBackups.count) 份备份？")
    }

    private func deleteButtonTitle(_ count: Int) -> String {
        String(localized: "删除 \(count) 份备份")
    }

    private var deleteMessage: String {
        let bytes = ownBackups.compactMap(\.byteSize).reduce(0, +)
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let newest = ownBackups.first.map { $0.name.createdAt.formatted(date: .abbreviated, time: .shortened) } ?? ""
        return String(localized: "会从 iCloud 云盘删除这台设备存的 \(ownBackups.count) 份备份（共 \(size)），包括最新的一份（\(newest)）。删除后不能再用它们恢复。房间里的内容和其他设备存的备份都不受影响。")
    }
}

/// The row in Settings. Says when backups are paused for the user's answer about the account,
/// so it is seen without opening the page.
struct ICloudBackupSettingsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("备份到 iCloud 云盘")
                if model.cloud.waitsForAccountAnswer {
                    Text("已暂停，需要你确认账户")
                        .font(.subheadline)
                        .foregroundStyle(Color.caution)
                }
            }
        } icon: {
            Image(systemName: model.cloud.waitsForAccountAnswer ? "exclamationmark.icloud" : "icloud")
        }
    }
}

/// What turning iCloud backup on means, shown before anything is written.
struct ICloudConsentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let agree: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("全部照片和房间记录：\(model.state.photos.count) 张照片、\(model.furnitureCount) 件家具，以及便签、日期和猫咪的名字。", systemImage: "photo.on.rectangle.angled")
                        .accessibilityIdentifier("icloud-consent-contents")
                    Label(sizeLine, systemImage: "internaldrive")
                        .accessibilityIdentifier("icloud-consent-size")
                    if model.cloudSyncOn {
                        Label("存到你自己的 iCloud 云盘：“文件”App › iCloud 云盘 › Meowverse。上传由系统完成。你打开的 iCloud 同步另由喵空间通过 Apple 的 iCloud 和你自己的设备同步，开发者拿不到这些数据。", systemImage: "icloud")
                    } else {
                        Label("存到你自己的 iCloud 云盘：“文件”App › iCloud 云盘 › Meowverse。上传由系统完成，这一步喵空间自己不联网。", systemImage: "icloud")
                    }
                    if let availability = model.cloud.availability, availability != .available {
                        // No account to remember yet: the first backup waits for the user to confirm it.
                        Label("现在用不了 iCloud 云盘。登录 iCloud 后，会先问你要不要备份到那个 Apple 账户。", systemImage: "person.crop.circle.badge.questionmark")
                            .accessibilityIdentifier("icloud-consent-signed-out")
                    }
                    Label("房间有改动时，打开或离开 App 时自动备份，最多每天一次。也可以随时点“立即备份”。", systemImage: "clock")
                    Label("随时可以关闭。关闭时会问你要不要删除已经存在 iCloud 里的备份。", systemImage: "switch.2")
                } header: {
                    Text("会存什么、存到哪里")
                }
                Section {
                    Button("开始备份到 iCloud 云盘") {
                        agree()
                        dismiss()
                    }
                    .accessibilityIdentifier("icloud-consent-confirm")
                    Button("不打开", role: .cancel) { dismiss() }
                        .accessibilityIdentifier("icloud-consent-cancel")
                } footer: {
                    Text("打开后不会马上上传；下次离开 App 时，或你点“立即备份”时，才会生成第一份备份。")
                }
            }
            .navigationTitle("备份到 iCloud 云盘？")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await model.refreshStorageUsage() }
    }

    private var sizeLine: String {
        guard let bytes = model.backup.usage?.bytes else { return String(localized: "大小正在计算…") }
        let one = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        // Says "one" in words: `CloudBackupPolicy.keepCount` is 1.
        return String(localized: "一份备份约 \(one)。iCloud 里只保留这台设备最新的一份；新的一份核对无误后，才会删掉上一份。")
    }
}

/// The status line: what is really true, never "backed up" for something that failed.
struct ICloudBackupStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lines = statusLines
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.text)
                    .font(line.isPrimary ? .body : .subheadline)
                    .foregroundStyle(line.isProblem ? Color.caution : (line.isPrimary ? Color.primary : Color.subtle))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("icloud-backup-status")
    }

    private struct Line {
        var text: String
        var isPrimary = false
        var isProblem = false
    }

    private var statusLines: [Line] {
        let cloud = model.cloud
        guard cloud.loaded, let availability = cloud.availability else {
            return [Line(text: String(localized: "正在查看 iCloud 云盘…"), isPrimary: true)]
        }
        var lines: [Line] = []
        switch availability {
        case .signedOut:
            lines.append(Line(text: String(localized: "这台设备没有登录 iCloud，或者没有打开 iCloud 云盘，所以不能备份。可以在系统“设置”里打开。"),
                              isPrimary: true, isProblem: true))
        case .containerUnavailable:
            lines.append(Line(text: String(localized: "喵空间现在用不了 iCloud 云盘，所以不能备份。可以在系统“设置” › iCloud 里查看是否允许喵空间使用 iCloud 云盘。"),
                              isPrimary: true, isProblem: true))
        case .available:
            break
        }
        if !cloud.settings.enabled {
            lines.append(Line(text: String(localized: "已关闭，不会自动备份。"), isPrimary: lines.isEmpty))
            return lines
        }
        if availability == .available {
            switch cloud.account {
            case .differs:
                // The last backup is in the other account: what it says about uploads is not about this one.
                lines.append(Line(text: String(localized: "这台设备现在登录的是另一个 Apple 账户。备份到 iCloud 云盘已暂停，没有往这个账户存任何东西。"),
                                  isPrimary: true, isProblem: true))
                return lines
            case .unconfirmed:
                // Turned on while signed out, or by an older build: nothing says whose account this is.
                lines.append(Line(text: String(localized: "还没确认要备份到现在登录的 Apple 账户。确认之前，不会往 iCloud 云盘存任何东西。"),
                                  isPrimary: true, isProblem: true))
                return lines
            case .unknown:
                lines.append(Line(text: String(localized: "没能确认现在登录的是哪个 Apple 账户，所以暂时不备份。"),
                                  isPrimary: true, isProblem: true))
            case .matches, .adopt, nil:
                break
            }
        }
        if let last = cloud.settings.lastSuccess {
            let date = last.date.formatted(date: .abbreviated, time: .shortened)
            let size = ByteCountFormatter.string(fromByteCount: Int64(last.byteSize), countStyle: .file)
            lines.append(Line(text: String(localized: "上次备份：\(date)，\(last.photoCount) 张照片、\(last.furnitureCount) 件家具，\(size)。"),
                              isPrimary: lines.isEmpty))
            if let upload = uploadLine(for: last) { lines.append(upload) }
        } else if cloud.settings.lastFailure == nil {
            lines.append(Line(text: String(localized: "已打开，还没有备份。下次离开 App 时会自动备份，也可以点“立即备份”。"), isPrimary: lines.isEmpty))
        }
        if let failure = cloud.settings.lastFailure {
            let date = failure.date.formatted(date: .abbreviated, time: .shortened)
            lines.append(Line(text: String(localized: "最近一次（\(date)）没有备份成功：\(AppModel.cloudFailureText(code: failure.code))"),
                              isPrimary: lines.isEmpty, isProblem: true))
        }
        return lines
    }

    private func uploadLine(for last: CloudBackupRecord) -> Line? {
        guard model.cloud.availability == .available, !model.cloud.listFailed else { return nil }
        guard let entry = model.cloud.entries.first(where: { $0.name.archiveName == last.archiveName }) else {
            return Line(text: String(localized: "这份备份已经不在 iCloud 云盘里了，下次会重新备份。"), isProblem: true)
        }
        switch entry.upload {
        case .notApplicable: return Line(text: String(localized: "已写入备份文件夹。"))
        case .pending, .uploading: return Line(text: String(localized: "已存入 iCloud 云盘，正在等系统上传。上传完成前，它只在这台设备上。"))
        case .uploaded: return Line(text: String(localized: "已上传到 iCloud。"))
        case .failed(let quotaExceeded):
            return Line(text: quotaExceeded
                        ? String(localized: "iCloud 储存空间已满，这份备份还没有上传，只在这台设备上。")
                        : String(localized: "这份备份还没能上传，只在这台设备上。系统会再试。"),
                        isProblem: true)
        }
    }
}

/// The backups in iCloud Drive, newest first. Picking one downloads it if needed and hands it
/// to the ordinary restore (full verification, preview, confirm).
struct ICloudRestoreList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.cloud.activity != nil || model.backup.busy != nil || model.cloud.notice != nil || model.backup.notice != nil {
                Section { progressAndNotices }
            }
            Section {
                Group {
                    if model.cloud.availability == .available, model.cloud.entries.isEmpty {
                        if model.cloud.listFailed {
                            Text("没能读取 iCloud 云盘里的文件，可以下拉再试一次。")
                        } else {
                            Text("iCloud 云盘里还没有喵空间的备份。")
                        }
                    } else if model.cloud.availability == .signedOut {
                        Text("这台设备没有登录 iCloud，或者没有打开 iCloud 云盘，所以看不到备份。")
                    } else if model.cloud.availability == .containerUnavailable {
                        Text("喵空间现在用不了 iCloud 云盘，所以看不到备份。")
                    }
                }
                .foregroundStyle(Color.subtle)
                .accessibilityIdentifier("icloud-restore-empty")
                ForEach(model.cloud.entries) { entry in
                    ICloudBackupRow(entry: entry, isRecommended: entry.id == model.recommendedCloudBackup?.id)
                }
            } footer: {
                Text("选一份备份后，会先下载（如果还不在这台设备上）并完整核对，再显示里面有什么。确认后才替换现在的房间。")
            }
        }
        .navigationTitle("从 iCloud 云盘恢复")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refreshCloudBackups() }
        .refreshable { await model.refreshCloudBackups() }
    }

    @ViewBuilder private var progressAndNotices: some View {
        if case .downloading(_, let fraction) = model.cloud.activity {
            VStack(alignment: .leading, spacing: 8) {
                if let fraction {
                    ProgressView(value: fraction) { Text("正在从 iCloud 下载备份…") }
                } else {
                    ProgressView { Text("正在从 iCloud 下载备份…") }
                }
                Button("取消", role: .cancel) { model.cancelCloudActivity() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("icloud-download-cancel")
            }
            .accessibilityIdentifier("icloud-download-progress")
            .padding(.vertical, 4)
        }
        if let busy = model.backup.busy {
            VStack(alignment: .leading, spacing: 8) {
                switch busy.operation {
                case .reading:
                    ProgressView(value: busy.fraction) { Text("正在读取并核对备份…") }
                    Button("取消", role: .cancel) { model.cancelBackupOperation() }
                        .buttonStyle(.bordered)
                case .replacing:
                    ProgressView("正在替换房间…")
                case .exporting, .clearing:
                    ProgressView()
                }
            }
            .padding(.vertical, 4)
        }
        if let notice = model.cloud.notice {
            NoticeLabel(text: notice.text, isFailure: notice.isFailure)
                .accessibilityIdentifier("icloud-restore-notice")
        }
        if let notice = model.backup.notice {
            NoticeLabel(text: notice.text, isFailure: notice.isFailure)
                .accessibilityIdentifier("backup-notice")
        }
    }
}

/// One backup: when, what (from its info file), how big, from which device, and its condition.
struct ICloudBackupRow: View {
    @Environment(AppModel.self) private var model
    let entry: CloudBackupEntry
    let isRecommended: Bool

    var body: some View {
        Button {
            model.restoreFromCloud(entry)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.name.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.listRow(entry.condition == .damaged ? .subtle : .primary))
                    if isRecommended {
                        Text("最新的完好备份")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.listRow(.accentColor))
                    }
                }
                Text(contentsLine)
                    .font(.subheadline)
                    .foregroundStyle(.listRow(.subtle))
                Text(deviceLine)
                    .font(.subheadline)
                    .foregroundStyle(.listRow(.subtle))
                if let condition = conditionLine {
                    Text(condition.text)
                        .font(.subheadline)
                        .foregroundStyle(condition.isProblem ? AnyShapeStyle(Color.caution) : AnyShapeStyle(ListRowInk(base: .subtle)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.listCommand)
        .disabled(entry.condition == .damaged || model.cloud.activity != nil || model.backup.busy != nil)
        .accessibilityElement(children: .combine)
        .accessibilityHint(entry.condition == .damaged ? "" : "下载并核对这份备份，先显示里面有什么。")
        .accessibilityIdentifier("icloud-backup-row")
    }

    private var contentsLine: String {
        let size = entry.byteSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        switch (entry.info, size) {
        case (let info?, let size?):
            return String(localized: "\(info.photoCount) 张照片、\(info.furnitureCount) 件家具，\(size)")
        case (let info?, nil):
            return String(localized: "\(info.photoCount) 张照片、\(info.furnitureCount) 件家具")
        case (nil, let size?):
            return String(localized: "\(size)，里面有多少照片要打开后才知道")
        case (nil, nil):
            return String(localized: "大小和内容要下载后才知道")
        }
    }

    private var deviceLine: String {
        if entry.isFromThisDevice { return String(localized: "来自这台设备") }
        if let kind = entry.info?.deviceKind, !kind.isEmpty { return String(localized: "来自另一台 \(kind)") }
        return String(localized: "来自另一台设备")
    }

    private var conditionLine: (text: String, isProblem: Bool)? {
        switch entry.condition {
        case .damaged: return (String(localized: "已损坏，不能用来恢复。"), true)
        case .unverified: return (String(localized: "缺少核对信息，可能没有写完。恢复时会完整核对。"), true)
        case .pending: return (String(localized: "核对信息还在从 iCloud 下载。恢复时会完整核对。"), false)
        case .verified:
            return entry.isDownloaded ? nil : (String(localized: "在 iCloud 里，恢复前要先下载。"), false)
        }
    }
}

/// A one-line result with an icon, as the rest of Settings shows them.
struct NoticeLabel: View {
    let text: String
    let isFailure: Bool

    var body: some View {
        Label(text, systemImage: isFailure ? "exclamationmark.triangle" : "checkmark.circle")
            .font(.subheadline)
            .foregroundStyle(isFailure ? Color.caution : Color.primary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: text))
    }
}
