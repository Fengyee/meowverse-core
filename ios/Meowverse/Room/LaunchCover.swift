import SwiftUI

/// The opening page kept over the room once per launch while the furniture and the cat load,
/// so the room appears finished instead of piece by piece.
/// Lifted by `RoomSceneView.onSceneReady`, or after `longest` whatever happens.
struct LaunchCover: View {
    /// Once per process: switching rooms later shows the usual settle animation.
    /// UI test launches (`-MeowverseStore`, `-MeowverseSkipReminderSetup`) skip it so their first
    /// taps reach the room; `-MeowverseLaunchCover` brings it back for the test of the cover.
    @MainActor static var shouldShow: Bool = {
        #if DEBUG || DRILLS
        let args = ProcessInfo.processInfo.arguments
        let testLaunch = args.contains("-MeowverseStore") || args.contains("-MeowverseSkipReminderSetup")
        return !testLaunch || args.contains("-MeowverseLaunchCover")
        #else
        return true
        #endif
    }()
    static let longest: Duration = .seconds(4)
    /// The cover's own UI test reads what lifted it; nothing else shows the probe.
    @MainActor static let probes: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-MeowverseLaunchCover")
        #else
        false
        #endif
    }()

    var body: some View {
        RoomOpeningView()
            .contentShape(.rect)
            .accessibilityIdentifier("launch-cover")
    }
}

/// "正在打开房间…" with the house emblem inside a ring of paw prints (`PawRing`): the page while the library loads, and the launch
/// cover after it, so launch reads as one screen until the room is finished.
struct RoomOpeningView: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                PawRing()
                MemoryEmblem(.home).frame(width: 118, height: 84)
            }
            Text("正在打开房间…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .memoryPage(.home)
    }
}
