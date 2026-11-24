import Combine
import MeowverseCore
import RealityKit
import SwiftUI
import UIKit

enum RoomLightingMode: String, CaseIterable {
    case constant, localTime

    static let defaultsKey = "room.lightingMode"

    var title: String {
        switch self {
        case .constant: String(localized: "恒定柔光", table: "RoomLighting")
        case .localTime: String(localized: "跟随当地时间", table: "RoomLighting")
        }
    }
}

struct RoomLightingPicker: View {
    @Binding var selection: RoomLightingMode

    var body: some View {
        LabeledContent {
            Picker(selection: $selection) {
                ForEach(RoomLightingMode.allCases, id: \.self) { mode in
                    Text(verbatim: mode.title).tag(mode)
                }
            } label: {
                Text("光线", tableName: "RoomLighting")
            }
            .labelsHidden()
            .accessibilityValue(selection.title)
            .accessibilityIdentifier("room-lighting-mode")
        } label: {
            Text("光线", tableName: "RoomLighting")
        }
    }
}

extension EnvironmentValues {
    @Entry var roomLightPhase: RoomLightPhase = .daylight
}

extension View {
    func roomLighting(mode: RoomLightingMode) -> some View {
        modifier(RoomLightingClock(mode: mode))
    }
}

private struct RoomLightingClock: ViewModifier {
    let mode: RoomLightingMode
    @Environment(\.scenePhase) private var scenePhase
    @State private var sample = Date.now
    @State private var clockRevision = 0

    private struct ClockKey: Equatable {
        let active: Bool
        let revision: Int
    }

    func body(content: Content) -> some View {
        let active = mode == .localTime && scenePhase == .active
        content
            .environment(\.roomLightPhase, mode == .constant ? .daylight : .local(at: sample))
            .task(id: ClockKey(active: active, revision: clockRevision)) {
                guard active else { return }
                while !Task.isCancelled {
                    sample = .now
                    guard let next = RoomLightPhase.nextChange(after: sample) else { return }
                    do { try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow))) }
                    catch { return }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
                .merge(with: NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange))) { _ in
                    if active { clockRevision += 1 }
                }
    }
}

extension RoomLightPhase {
    func apply(to sun: DirectionalLight, fill: DirectionalLight) {
        switch self {
        case .daylight:
            sun.light.color = UIColor(red: 1, green: 0.98, blue: 0.94, alpha: 1)
            sun.light.intensity = 2600
            fill.light.color = .white
            fill.light.intensity = 1100
        case .dawn:
            sun.light.color = UIColor(hex: 0xffe2bb)
            sun.light.intensity = 2350
            fill.light.color = UIColor(hex: 0xfff6ed)
            fill.light.intensity = 1100
        case .dusk:
            sun.light.color = UIColor(hex: 0xffc080)
            sun.light.intensity = 2100
            fill.light.color = UIColor(hex: 0xefdfec)
            fill.light.intensity = 1050
        case .night:
            sun.light.color = UIColor(hex: 0xffdcaa)
            sun.light.intensity = 1350
            fill.light.color = UIColor(hex: 0xcad9f5)
            fill.light.intensity = 850
        }
    }

    /// The colour the backdrop is blended toward in this phase, and how far.
    var backdropTint: (r: CGFloat, g: CGFloat, b: CGFloat, weight: CGFloat)? {
        switch self {
        case .dawn: (1.0, 0.84, 0.71, 0.25)
        case .dusk: (0.89, 0.62, 0.53, 0.38)
        case .night: (0.33, 0.40, 0.55, 0.66)
        case .daylight: nil
        }
    }

    func backdrop(color: UIColor) -> UIColor {
        guard let tint = backdropTint else { return color }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return color }
        let base = 1 - tint.weight
        return UIColor(red: r * base + tint.r * tint.weight,
                       green: g * base + tint.g * tint.weight,
                       blue: b * base + tint.b * tint.weight, alpha: a)
    }
}
