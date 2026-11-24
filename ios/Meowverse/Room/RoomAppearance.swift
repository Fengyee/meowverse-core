import MeowverseCore
import SwiftUI

struct RoomAppearance: Equatable {
    var theme: RoomTheme = .creamOak
    var plainWalls = false

    /// The backdrop as one colour (postcards, and the scenes that do not show the painting).
    func backdrop(in phase: RoomLightPhase) -> UIColor {
        theme.paper(in: phase)
    }
}

/// Fills the whole screen behind the room, under the status bar too: there is no navigation bar
/// any more to cover the top. The theme's painting (`RoomThemeBackdrop`); in Dark Mode the room
/// page keeps its light paper, with a shade behind the status bar.
struct RoomBackdrop: View {
    @Environment(\.roomAppearance) private var appearance
    @Environment(\.roomLightPhase) private var light
    @Environment(\.roomBackdropBands) private var bands
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    /// False for a backdrop that only shows at the screen edges, behind a clipped room column.
    var ornaments = true

    var body: some View {
        let color = appearance.backdrop(in: light)
        RoomThemeBackdrop(theme: appearance.theme, phase: light, bands: ornaments ? bands : nil)
            .overlay {
                // In Dark Mode the status bar draws white text, which a pale backdrop would swallow.
                if scheme == .dark, color.isPale {
                    StatusBarShade(opacity: contrast == .increased ? StatusBarShade.increasedOpacity : StatusBarShade.opacity)
                }
            }
    }
}

/// A shade behind the status bar, within its height: even from the top of the screen to below
/// the time and icons, then fading to nothing exactly at the bottom of the bar, so the room
/// below meets it without a step. 56 % black keeps white status text at 5.49:1 or more on every
/// theme's day paper (the seasons it replaced needed 55 % for 5.33:1); 70 % under Increase
/// Contrast (9.2:1 or more).
///
/// The status text sits in the upper part of the bar: on a 62 pt Dynamic Island bar it ends about
/// 38 pt down, on the SE's 20 pt bar about 15, on the iPad mini's 24 pt bar about 18. The even
/// part runs to 75 % of the bar or to 18 pt above its bottom, whichever is further down.
///
/// Nothing is drawn below the bar: on iPad, RoomScreen clips a second backdrop to the room
/// column at the safe area, and a fade reaching past it would be cut into a step.
struct StatusBarShade: View {
    static let opacity = 0.56
    static let increasedOpacity = 0.7
    let opacity: Double

    var body: some View {
        // This reader keeps the safe area (one that ignores it reports a zero inset), so it starts
        // at the bottom of the bar; the shade is moved up by the bar's height.
        GeometryReader { geometry in
            let top = geometry.safeAreaInsets.top
            if top > 0 {
                let even = max(top - 18, top * 0.75) / top
                LinearGradient(stops: [
                    .init(color: .black.opacity(opacity), location: 0),
                    .init(color: .black.opacity(opacity), location: even),
                    .init(color: .black.opacity(0), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .frame(width: geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing,
                       height: top)
                .offset(x: -geometry.safeAreaInsets.leading, y: -top)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension UIColor {
    /// Light enough that white text on it would be hard to read.
    var isPale: Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return true }
        return 0.299 * red + 0.587 * green + 0.114 * blue > 0.6
    }
}

extension EnvironmentValues {
    @Entry var roomAppearance = RoomAppearance()
}

/// 主题: a tray at the bottom of the room, not a sheet, so the room stays in view while it changes
/// (art/ui/OVERLAY_SPEC.md §5, the 主题 exception). A compact folio header; 取消 and 保存 are the exits.
struct RoomAppearanceEditor: View {
    @Binding var appearance: RoomAppearance
    @Binding var lighting: RoomLightingMode
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        RoomFolio(title: String(localized: "主题"), image: "TopTheme", compact: true) {
            ScrollViewReader { scroller in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(RoomTheme.allCases, id: \.self) { theme in
                            themeChip(theme).id(theme)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                // The chips run past the screen: start with the saved one in view.
                .onAppear { scroller.scrollTo(appearance.theme, anchor: .center) }
            }
            Toggle("素色墙面", isOn: $appearance.plainWalls)
                .padding(.horizontal, 20)
                .accessibilityIdentifier("plain-room-walls")
            RoomLightingPicker(selection: $lighting)
                .padding(.horizontal, 20)
            HStack(spacing: 12) {
                Button(action: cancel) { Text("取消").frame(maxWidth: .infinity) }
                    .buttonStyle(.roomFolio(.secondary))
                    .accessibilityIdentifier("cancel-room-appearance")
                Button(action: save) { Text("保存").frame(maxWidth: .infinity) }
                    .buttonStyle(.roomFolio(.primary))
                    .accessibilityIdentifier("save-room-appearance")
            }
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .background(RoomPaper.leaf)
        .overlay(alignment: .top) { RoomStitchedRule() }
    }

    private func themeChip(_ theme: RoomTheme) -> some View {
        RoomPaperChip(title: Text(verbatim: theme.title), selected: appearance.theme == theme,
                      swatch: [Color(uiColor: UIColor(hex: theme.art.wall)), Color(uiColor: UIColor(hex: theme.art.floor))]) {
            appearance.theme = theme
        }
        .accessibilityLabel(theme.title)
        .accessibilityIdentifier("room-theme-" + theme.rawValue)
    }
}
