import SwiftUI

/// A command row in a settings list, such as 立即备份, 导出备份 or 写邮件: the list's own look, except
/// that an unavailable command reads as unavailable.
///
/// The default list button on iOS 27 draws a disabled `Button(_:systemImage:)` with its title in the
/// primary colour and its icon still in the accent tint, so 立即备份 without iCloud looked live (its
/// enabled title is the accent colour, which is nearly as dark), and a disabled 清除全部数据 turned
/// black instead of red. A text-only disabled button fades to about 1.8 : 1, too faint to read.
/// Here title and icon change together: the accent colour (red for a destructive command) when
/// available, `Color.listDisabledInk` when not, the grey the system gives a disabled navigation row
/// such as 从 iCloud 恢复…, so every unavailable row on a page looks the same. A richer label that
/// sets its own colours uses `.listRow(_:)` for them; a warning line that says why the row is
/// unavailable (已损坏) keeps its colour. Only colours change; the row, label, spacing and the
/// disabled trait VoiceOver reads are the list's.
struct ListCommandStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let ink = configuration.role == .destructive ? Color.red : Color.accentColor
        configuration.label
            .foregroundStyle(.listRow(ink))
            // The whole width of the row stays the tap target, as with the list's own style.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

extension ButtonStyle where Self == ListCommandStyle {
    static var listCommand: ListCommandStyle { ListCommandStyle() }
}

/// Ink for text inside a list row's label that follows the row: `base` while the row can be used,
/// `Color.listDisabledInk` while it is disabled. For labels that set their own colours (a title in
/// `.primary`, details in `Color.subtle`), which would otherwise stay dark on a disabled row.
struct ListRowInk: ShapeStyle {
    let base: Color

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.isEnabled ? base : .listDisabledInk
    }
}

extension ShapeStyle where Self == ListRowInk {
    static func listRow(_ base: Color) -> ListRowInk { ListRowInk(base: base) }
}

extension Color {
    /// A disabled row's title and icon in a settings list. Matches the grey the system draws a
    /// disabled navigation row in (light #7F7F7F, 4.0 : 1 on the white row; dark #969697, 4.7 : 1 on
    /// #2C2C2E), so it stays readable and every unavailable row on a page agrees. Lighter and colder
    /// than the moss accent in both schemes; darker again under Increase Contrast. Kept here rather
    /// than in `art/ui/tokens.json`: it belongs to the system list, not the paper palette, and the
    /// token table has no Increase Contrast variant.
    nonisolated static let listDisabledInk = Color(UIColor { traits in
        let high = traits.accessibilityContrast == .high
        return traits.userInterfaceStyle == .dark
            ? UIColor(white: high ? 0.72 : 0.59, alpha: 1)
            : UIColor(white: high ? 0.40 : 0.50, alpha: 1)
    })
}
