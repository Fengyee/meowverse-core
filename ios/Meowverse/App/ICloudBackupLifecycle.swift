import MeowverseCore
import SwiftUI

/// Starts iCloud backup work at launch and when the app goes to the background, and hosts the
/// restore sheet opened from the empty room. With the feature off it adds nothing at all: no
/// task, no scene-phase observer, no sheet.
struct ICloudBackupLifecycle: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        @Bindable var model = model
        if model.options.cloudBackupFeature {
            content
                .task(id: model.phase) {
                    if model.phase == .ready { await model.startCloudBackup() }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background: model.backUpToCloud(trigger: .automatic)
                    case .active: Task { await model.refreshCloudBackups() }
                    default: break
                    }
                }
                // Another Apple Account: backups wait for the user's answer (`AccountCheck`).
                // `.onReceive` delivers on the main thread, whichever queue the system posts on.
                .onReceive(NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)) { _ in
                    model.cloudAccountDidChange()
                }
                .sheet(isPresented: $model.cloud.restoreSheetShown) { ICloudRestoreSheet() }
        } else {
            content
        }
    }
}

/// Shown in the empty room when iCloud Drive holds a backup. It only offers; nothing is
/// restored until the user picks a backup, sees its preview and confirms.
struct ICloudRestoreOffer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.cloudRestoreOffered, let entry = model.offeredCloudBackup {
            VStack(spacing: 6) {
                Divider().padding(.vertical, 4)
                Text("iCloud 云盘里有喵空间的备份")
                    .font(.subheadline.weight(.semibold))
                Text(detail(entry))
                    .font(.subheadline)
                    .foregroundStyle(Color.subtle)
                    .multilineTextAlignment(.center)
                HStack(spacing: 20) {
                    Button("从 iCloud 云盘恢复…") { model.cloud.restoreSheetShown = true }
                        .accessibilityHint("先列出备份，选一份后显示里面有什么，确认后才放进房间。")
                        .accessibilityIdentifier("icloud-restore")
                    Button("不用了") { model.dismissCloudRestoreOffer() }
                        .accessibilityHint("以后可以在设置 › 备份到 iCloud 云盘里恢复。")
                        .accessibilityIdentifier("icloud-restore-dismiss")
                }
                .font(.subheadline.weight(.medium))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("icloud-restore-offer")
        }
    }

    private func detail(_ entry: CloudBackupEntry) -> String {
        let date = entry.name.createdAt.formatted(date: .abbreviated, time: .shortened)
        if let info = entry.info {
            return String(localized: "最新一份：\(date)，\(info.photoCount) 张照片、\(info.furnitureCount) 件家具。")
        }
        return String(localized: "最新一份：\(date)。")
    }
}

/// The backup list as its own sheet (from the empty room), with the restore preview on top.
struct ICloudRestoreSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ICloudRestoreList()
                .memoryPage(.home)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                            .disabled(model.backup.busy?.operation == .replacing)
                            .accessibilityIdentifier("close-icloud-restore")
                    }
                }
        }
        .interactiveDismissDisabled(model.backup.busy != nil || model.cloud.activity != nil)
        .sheet(isPresented: pendingBinding) {
            if let prepared = model.backup.pending {
                RestorePreviewView(preview: prepared.preview)
                    .memoryPage(.home)
            }
        }
        .onDisappear {
            // Closing the sheet drops an unconfirmed preview and stops a download.
            model.cancelPendingRestore()
            if case .downloading = model.cloud.activity { model.cancelCloudActivity() }
        }
    }

    private var pendingBinding: Binding<Bool> {
        Binding(get: { model.backup.pending != nil }, set: { if !$0 { model.cancelPendingRestore() } })
    }
}
