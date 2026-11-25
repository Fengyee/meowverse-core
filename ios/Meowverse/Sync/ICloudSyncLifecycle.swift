import CloudKit
import SwiftUI

/// Runs iCloud sync at launch, on returning to the app, a moment after an edit, after a restore
/// or a clear, and when another device changed something. With the feature off it adds nothing
/// at all: no task, no observers.
struct ICloudSyncLifecycle: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        if model.options.cloudSyncFeature {
            content
                .task(id: model.phase) {
                    if model.phase == .ready { await model.startCloudSync() }
                }
                .onChange(of: scenePhase) { _, phase in model.cloudSyncScenePhaseChanged(phase) }
                .onChange(of: model.state.revision) { _, _ in model.libraryChangedForSync() }
                .onChange(of: model.libraryGeneration) { _, _ in model.libraryReplacedForSync() }
        } else {
            content
        }
    }
}

extension QuickActionAppDelegate {
    /// A silent push from CloudKit (another device changed something): one sync cycle.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return .noData }
        switch await SyncPushCenter.shared.receive() {
        case .newData?: return .newData
        case .failed?: return .failed
        case .noData?, nil: return .noData
        }
    }
}
