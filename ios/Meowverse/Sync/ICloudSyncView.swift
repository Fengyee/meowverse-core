import MeowverseCore
import SwiftUI

/// Settings › iCloud 同步: the switch (with consent), the honest status, what needs the user,
/// and "sync now". Only reachable while the feature is on (`LaunchOptions.cloudSyncFeature`).
struct ICloudSyncView: View {
    @Environment(AppModel.self) private var model
    @State private var consentShown = false
    @State private var disableAsked = false

    var body: some View {
        List {
            Section {
                Toggle("iCloud 同步", isOn: enabledBinding)
                    .disabled(!model.sync.loaded)
                    .accessibilityHint("让登录同一个 Apple 账户的 iPhone 和 iPad 看到同一个家。打开前会先说明同步什么。")
                    .accessibilityIdentifier("icloud-sync-toggle")
                ICloudSyncStatusView()
                if model.sync.running {
                    ProgressView("正在同步…")
                        .accessibilityIdentifier("icloud-sync-progress")
                }
                if let notice = model.sync.notice {
                    NoticeLabel(text: notice.text, isFailure: notice.isFailure)
                        .accessibilityIdentifier("icloud-sync-notice")
                }
                Button("立即同步", systemImage: "arrow.triangle.2.circlepath") { model.syncNow() }
                    .buttonStyle(.listCommand)
                    .disabled(!canSyncNow)
                    .accessibilityHint("现在就和 iCloud 交换改动。")
                    .accessibilityIdentifier("icloud-sync-now")
            } footer: {
                Text("同步的内容存在你自己的 iCloud 里，喵空间的开发者看不到。打开或回到 App、做了改动、其他设备有改动时，会自动同步。")
            }
            if model.sync.settings.enabled, let problem = model.sync.problem, problem.needsUser {
                decisionSection(problem)
            }
        }
        .navigationTitle("iCloud 同步")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refreshStorageUsage() }
        .sheet(isPresented: $consentShown) {
            ICloudSyncConsentView { model.enableCloudSync() }
        }
        .confirmationDialog("关闭 iCloud 同步？", isPresented: $disableAsked, titleVisibility: .visible) {
            Button("关闭同步") { model.disableCloudSync() }
                .accessibilityIdentifier("icloud-sync-disable-confirm")
            Button("取消", role: .cancel) {}
        } message: {
            Text("这台设备上的家保持现在的样子，iCloud 里的数据也不会删除，其他设备照常同步。以后再打开时，会把两边合并在一起。")
        }
    }

    /// Another account, or the iCloud data deleted: nothing is sent until the user chooses.
    private func decisionSection(_ problem: CloudSyncUIState.Problem) -> some View {
        Section {
            Button(problem == .accountChanged ? "把这台设备的家并入现在的账户" : "重新上传这台设备的家") {
                model.startSyncOver()
            }
            .buttonStyle(.listCommand)
            .accessibilityHint(problem == .accountChanged
                               ? "这台设备上的家会和现在这个账户的 iCloud 里已有的内容合并，不删除任何东西。"
                               : "把这台设备上的家重新存进 iCloud，再和其他设备同步。")
            .accessibilityIdentifier("icloud-sync-start-over")
            Button("关闭同步", role: .destructive) { model.disableCloudSync() }
                .buttonStyle(.listCommand)
                .accessibilityIdentifier("icloud-sync-turn-off")
        } header: {
            Text("需要你决定")
        } footer: {
            Text(problem == .accountChanged
                 ? "原来账户里的数据留在原来的账户里，不会搬进现在的账户。"
                 : "其他设备上的家不受影响。")
        }
    }

    private var enabledBinding: Binding<Bool> {
        // The switch only asks; the consent sheet or the dialog decides.
        Binding(get: { model.sync.settings.enabled }, set: { wanted in
            if wanted { consentShown = true } else { disableAsked = true }
        })
    }

    private var canSyncNow: Bool {
        model.sync.settings.enabled && !model.sync.running && model.sync.problem?.needsUser != true
    }
}

/// What turning iCloud sync on means, shown before anything leaves the device.
struct ICloudSyncConsentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let agree: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(contentsLine, systemImage: "house")
                        .accessibilityIdentifier("icloud-sync-consent-contents")
                    Label("照片只同步喵空间自己存的那一份（长边最多 2048 像素，在 App 里拍的是整张）。相册里的原图不会上传。", systemImage: "photo.on.rectangle.angled")
                        .accessibilityIdentifier("icloud-sync-consent-photos")
                    Label(whereLine, systemImage: "icloud")
                        .accessibilityIdentifier("icloud-sync-consent-where")
                    Label("登录同一个 Apple 账户、也打开了同步的 iPhone 和 iPad 会看到同一个家，在哪台上改都会同步过去。", systemImage: "ipad.and.iphone")
                } header: {
                    Text("同步什么、存在哪里")
                }
                Section {
                    Label("这台设备上的家会和 iCloud 里已有的家合并，不删除任何东西。两边不一样的便签会合成一条。", systemImage: "arrow.triangle.merge")
                        .accessibilityIdentifier("icloud-sync-consent-merge")
                    Label("随时可以关闭。关闭后，这台设备上的家和 iCloud 里的数据都会保留，其他设备照常同步。", systemImage: "switch.2")
                        .accessibilityIdentifier("icloud-sync-consent-off")
                } header: {
                    Text("打开和关闭时")
                }
                Section {
                    Button("打开 iCloud 同步") {
                        agree()
                        dismiss()
                    }
                    .buttonStyle(.listCommand)
                    .accessibilityIdentifier("icloud-sync-consent-confirm")
                    Button("不打开", role: .cancel) { dismiss() }
                        .buttonStyle(.listCommand)
                        .accessibilityIdentifier("icloud-sync-consent-cancel")
                } footer: {
                    Text("和“备份到 iCloud 云盘”是两件事：备份是某一刻的完整副本，同步是让几台设备保持一样。", tableName: "ICloudSync")
                }
            }
            .navigationTitle("打开 iCloud 同步？")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await model.refreshStorageUsage() }
    }

    private var contentsLine: String {
        let state = model.state
        return String(localized: "\(state.allRooms.count) 个房间、\(model.furnitureCount) 件家具、\(state.allCats.count) 只猫咪和 \(state.photos.count) 张照片，以及便签、日期和名字。")
    }

    private var whereLine: String {
        guard let bytes = model.backup.usage?.bytes else {
            return String(localized: "存在你自己的 iCloud 私有数据库里，占用你的 iCloud 储存空间。喵空间的开发者看不到这些内容。")
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return String(localized: "存在你自己的 iCloud 私有数据库里，约占 \(size) 的 iCloud 储存空间。喵空间的开发者看不到这些内容。")
    }
}

/// The status: what is really true, never "synced" for something that is not.
struct ICloudSyncStatusView: View {
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
        .accessibilityIdentifier("icloud-sync-status")
    }

    private struct Line {
        var text: String
        var isPrimary = false
        var isProblem = false
    }

    private var statusLines: [Line] {
        let sync = model.sync
        guard sync.loaded else { return [Line(text: String(localized: "正在读取同步设置…"), isPrimary: true)] }
        guard sync.settings.enabled else {
            return [Line(text: String(localized: "已关闭，不和其他设备同步。"), isPrimary: true)]
        }
        var lines: [Line] = []
        if let problem = sync.problem {
            lines.append(Line(text: AppModel.syncProblemText(problem), isPrimary: true, isProblem: true))
        }
        if let last = sync.settings.lastSuccess {
            let date = last.formatted(date: .abbreviated, time: .shortened)
            lines.append(Line(text: String(localized: "上次同步：\(date)。"), isPrimary: lines.isEmpty))
        } else if sync.running {
            lines.append(Line(text: String(localized: "正在第一次同步：先看 iCloud 里已有什么，再把这台设备的家并进去。"), isPrimary: lines.isEmpty))
        } else if sync.problem == nil {
            lines.append(Line(text: String(localized: "已打开，还没有同步完成。"), isPrimary: true))
        }
        if sync.unsent > 0 {
            lines.append(Line(text: String(localized: "还有 \(sync.unsent) 项改动等待上传。")))
        }
        if sync.waitingForFiles > 0 {
            lines.append(Line(text: String(localized: "还有 \(sync.waitingForFiles) 张照片还没能从 iCloud 下载，下载好之前先不显示。")))
        }
        if sync.unusableFiles > 0 {
            lines.append(Line(text: String(localized: "有 \(sync.unusableFiles) 张照片的文件在这台设备上没法使用，所以没有显示。可能是文件损坏了，或者这台设备的系统读不了这种格式。下次打开 App 时会再试一次。"), isProblem: true))
        }
        if sync.pendingLinks > 0 {
            lines.append(Line(text: String(localized: "家具上有 \(sync.pendingLinks) 张照片还没同步到这台设备。")))
        }
        if sync.notUploaded > 0 {
            lines.append(Line(text: String(localized: "有 \(sync.notUploaded) 张照片没能上传到 iCloud，会自动再试。"), isProblem: true))
        }
        if sync.notFetched > 0 {
            lines.append(Line(text: String(localized: "别的设备改过的 \(sync.notFetched) 项内容还没能从 iCloud 取下来，会自动再试。")))
        }
        if sync.heldBack > 0 {
            lines.append(Line(text: String(localized: "有 \(sync.heldBack) 项内容来自更新版本的喵空间，更新 App 后才能同步。"), isProblem: true))
        }
        if sync.quarantined > 0 {
            lines.append(Line(text: String(localized: "iCloud 里有 \(sync.quarantined) 项内容读不出，或和这台设备上的内容对不上，没有合并进来。这台设备上已有的保持原样，还没有的先不显示；其中读不出的，在这台设备上对它们的修改也先不上传。每次同步都会再试。",
                                           table: "ICloudSync"), isProblem: true))
        }
        return lines
    }
}
