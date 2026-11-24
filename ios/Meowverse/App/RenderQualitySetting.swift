import MeowverseCore
import SwiftUI

/// 设置 › 画质 (owner, 2026-11-20): the user's choice, kept on this device, and what the room
/// draws with now. The rules and the table of values are in Core (`RenderQuality.swift`); the
/// room view applies them (`RoomSceneController.applyQuality`).
@Observable
final class RenderQualityModel {
    static let defaultsKey = "room.renderQuality"

    private(set) var state: RenderQualityState
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    /// DEBUG and drill builds: a pretend thermal state (`-MeowverseQualityThermal`), live from
    /// launch or only once `simulateThermal()` has run (`-MeowverseQualityThermalAfter`).
    @ObservationIgnored private let pretendThermal: ProcessInfo.ThermalState?
    @ObservationIgnored private var pretendLive: Bool

    init(options: LaunchOptions, defaults: UserDefaults = .standard) {
        // Test stores (`-MeowverseStore`) keep their own choice, reset with the store.
        let isTest = options.storeFolder != "Library"
        key = isTest ? "\(Self.defaultsKey).\(options.storeFolder)" : Self.defaultsKey
        if isTest, options.resetStore { defaults.removeObject(forKey: key) }
        if let forced = options.qualityChoice { defaults.set(forced.rawValue, forKey: key) }
        let memory = options.qualityMemoryGiB.map { UInt64($0 * Double(1 << 30)) } ?? ProcessInfo.processInfo.physicalMemory
        state = RenderQualityState(choice: RenderQualityChoice(stored: defaults.string(forKey: key)),
                                   deviceTier: RenderQuality.deviceTier(physicalMemory: memory))
        pretendThermal = options.qualityThermal
        pretendLive = options.qualityThermalAfter == nil
        self.defaults = defaults
    }

    var choice: RenderQualityChoice { state.choice }
    var tier: RenderQualityTier { state.tier }

    private var thermal: ProcessInfo.ThermalState {
        if let pretendThermal, pretendLive { return pretendThermal }
        return ProcessInfo.processInfo.thermalState
    }

    func choose(_ choice: RenderQualityChoice) {
        defaults.set(choice.rawValue, forKey: key)
        if state.choose(choice, thermal: thermal) { announceDrop() }
    }

    /// At launch and on every `thermalStateDidChangeNotification`.
    func checkThermal() {
        if state.observe(thermal) { announceDrop() }
    }

    /// `-MeowverseQualityThermalAfter`: the pretend state arrives now, as a system change would.
    func simulateThermal() {
        pretendLive = true
        checkThermal()
    }

    /// One short line that goes away by itself and takes no taps (`TransientNotice`).
    private func announceDrop() {
        TransientNotice.show(String(localized: "设备有点热，画质先降到「\(tier.title)」，下次打开 App 时恢复。", table: "RenderQuality"))
    }
}

/// Reads the thermal state once the library is ready and whenever the system says it changed.
/// `.onReceive` delivers on the main thread, whichever queue the system posts on (tech-craft).
struct RenderQualityLifecycle: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .task(id: model.phase == .ready) {
                guard model.phase == .ready else { return }
                model.quality.checkThermal()
                guard let delay = model.options.qualityThermalAfter, model.options.qualityThermal != nil else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                model.quality.simulateThermal()
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                model.quality.checkThermal()
            }
    }
}

extension RenderQualityTier {
    var title: String {
        switch self {
        case .high: String(localized: "高", table: "RenderQuality")
        case .medium: String(localized: "中", table: "RenderQuality")
        case .low: String(localized: "低", table: "RenderQuality")
        }
    }
}

extension RenderQualityChoice {
    var title: String {
        switch self {
        case .auto: String(localized: "自动", table: "RenderQuality")
        case .high: RenderQualityTier.high.title
        case .medium: RenderQualityTier.medium.title
        case .low: RenderQualityTier.low.title
        }
    }
}

/// The row in 设置, with a footer that says what 自动 picks on this device.
struct RenderQualitySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let quality = model.quality
        Section {
            NavigationLink { RenderQualityPage() } label: {
                LabeledContent {
                    Text(quality.choice.title)
                } label: {
                    Label { Text("画质", tableName: "RenderQuality") } icon: { Image(systemName: "sparkles") }
                }
            }
            .accessibilityIdentifier("open-render-quality")
        } header: {
            Text("画面", tableName: "RenderQuality")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                RenderQualityAutoNote(state: quality.state)
                    .accessibilityIdentifier("render-quality-footer")
                CatTierNoteText()
            }
        }
    }
}

/// What 自动 gives this device, and the drop for heat while it lasts.
private struct RenderQualityAutoNote: View {
    let state: RenderQualityState

    var body: some View {
        if state.steppedDown {
            Text("自动：设备刚才发热，这次先用「\(state.autoTier.title)」，下次打开 App 时恢复「\(state.deviceTier.title)」。", tableName: "RenderQuality")
        } else {
            Text("自动：按这台设备的内存用「\(state.deviceTier.title)」。", tableName: "RenderQuality")
        }
    }
}

/// 设置 › 画质: four choices, one checked.
struct RenderQualityPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let quality = model.quality
        List {
            Section {
                ForEach(RenderQualityChoice.allCases, id: \.self) { choice in
                    Button { quality.choose(choice) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.title)
                                    .foregroundStyle(Color.primary)
                                Text(detail(choice, state: quality.state))
                                    .font(.subheadline)
                                    .foregroundStyle(Color.subtle)
                            }
                            Spacer(minLength: 8)
                            if quality.choice == choice {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(quality.choice == choice ? .isSelected : [])
                    .accessibilityIdentifier("render-quality-\(choice.rawValue)")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    CatTierNoteText()
                    Text("画质影响房间的清晰度、阴影和部分家具的材质细节。首次使用「低」档时，简化的猫咪模型需要下载。", tableName: "RenderQuality")
                }
            }
        }
        .navigationTitle(Text("画质", tableName: "RenderQuality"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ choice: RenderQualityChoice, state: RenderQualityState) -> String {
        switch choice {
        case .auto:
            if state.steppedDown {
                return String(localized: "这台设备用「\(state.autoTier.title)」：刚才发热，下次打开 App 时恢复「\(state.deviceTier.title)」", table: "RenderQuality")
            }
            return String(localized: "按这台设备的内存用「\(state.deviceTier.title)」，设备发热时先降一档", table: "RenderQuality")
        case .high: return String(localized: "高清画面、柔和接地影和更丰富的材质细节", table: "RenderQuality")
        case .medium: return String(localized: "保留太阳投影，使用较小的家具贴图", table: "RenderQuality")
        case .low: return String(localized: "较低分辨率，保留家具接缝的层次", table: "RenderQuality")
        }
    }
}
