import SwiftUI

// The "paper folio" every panel except 设置 wears (art/ui/OVERLAY_SPEC.md §5): a leaf-coloured
// sheet, a header with the panel's own token icon and its title in the title face, a stitched
// rule, cards of `sheet` paper, and system controls tinted moss. Content and actions come from the
// caller; nothing here reads the app model.

extension RoomPaper {
    /// Notes, footers, counts and hints in a folio: ink at 75 % (OVERLAY_SPEC §5, Content). Set it
    /// on the text itself. `.secondary` inside a folio is derived from the folio's ink, about 50 %,
    /// which is 2.6:1 on `leaf`; this is 4.8:1 on `leaf` and 5.0:1 on `sheet` in light, 6.8:1 and up
    /// in dark.
    static let note = ink.opacity(0.75)
}

/// A 1 pt dashed rule in `edge`, dash 3 gap 3: under the folio header and between rows of a card.
struct RoomStitchedRule: View {
    var body: some View {
        Line()
            .stroke(RoomPaper.edge, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private nonisolated struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.midY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

/// What closes a folio: the caller's localised label (关闭), identifier and action.
struct RoomFolioClose {
    let label: Text
    let id: String
    let action: () -> Void
}

/// The folio's close button: a 44 pt paper circle with a 12 pt ink cross.
struct RoomFolioCloseButton: View {
    let close: RoomFolioClose

    var body: some View {
        Button(action: close.action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 44, height: 44)
                .foregroundStyle(RoomPaper.ink)
                .background {
                    Circle().fill(RoomPaper.paper).overlay { Circle().stroke(RoomPaper.edge, lineWidth: 1) }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.roomToken)
        .accessibilityLabel(close.label)
        .accessibilityIdentifier(close.id)
    }
}

/// A panel shell. On iPhone present it in a sheet; it sets the leaf background, the drag indicator
/// and a detent that fits its content (plus `detents`, for content that can grow). On iPad present it
/// in a popover and give it `.frame(width: 360)`. The 主题 tray uses `compact: true`: a smaller header
/// with no close button, placed by the caller at the bottom of the room.
///
///     RoomFolio(title: String(localized: "音乐音效"), image: "TopSound", illustration: "MemoryCompanion",
///               close: RoomFolioClose(label: Text("关闭"), id: "close-room-sound") { dismiss() }) {
///         RoomFolioCard { RoomFolioToggleRow(title: Text("背景轻音乐"), note: Text(…), isOn: $music) }
///     }
struct RoomFolio<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    private let title: String
    private let image: String
    private let compact: Bool
    private let illustration: String?
    private let scrolls: Bool
    private let detents: Set<PresentationDetent>
    private let close: RoomFolioClose?
    private let content: Content

    @State private var headerHeight: CGFloat = 0
    @State private var bodyHeight: CGFloat = 0
    @State private var windowHeight: CGFloat = 0

    /// - Parameters:
    ///   - illustration: at most one decorative drawing, below the content. It is hidden from
    ///     VoiceOver and dropped at accessibility text sizes or when it would make the panel scroll.
    ///   - scrolls: `false` when `content` brings its own scrolling container, such as a `List`;
    ///     the panel then takes `detents` (default medium and large) instead of fitting its content.
    ///   - title: already localised; drawn in the title face.
    ///   - detents: extra detents beside the fitted one.
    init(title: String, image: String, compact: Bool = false, illustration: String? = nil,
         scrolls: Bool = true, detents: Set<PresentationDetent> = [], close: RoomFolioClose? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.image = image
        self.compact = compact
        self.illustration = illustration
        self.scrolls = scrolls
        self.detents = scrolls ? detents : (detents.isEmpty ? [.medium, .large] : detents)
        self.close = close
        self.content = content()
    }

    private static var illustrationHeight: CGFloat { 60 + 14 }

    /// The illustration stays while the whole panel fits in the tallest sheet the window allows
    /// (about 85 % of its height); otherwise it goes, before content has to scroll.
    private var showsIllustration: Bool {
        guard illustration != nil, scrolls, !compact, !typeSize.isAccessibilitySize else { return false }
        guard windowHeight > 0 else { return true }
        return headerHeight + bodyHeight + Self.illustrationHeight <= windowHeight * 0.85
    }

    private var fittedHeight: CGFloat {
        headerHeight + bodyHeight + (showsIllustration ? Self.illustrationHeight : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            if compact {
                // The 主题 tray sits at the bottom of the room at its natural height.
                VStack(spacing: 14) { content }.padding(.top, 10).padding(.bottom, 16)
            } else if scrolls {
                ScrollView {
                    VStack(spacing: 0) {
                        VStack(spacing: 14) { content }
                            .padding(.top, 16)
                            .padding(.bottom, 16)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
                        if showsIllustration, let illustration {
                            Image(decorative: illustration).renderingMode(.original).resizable().scaledToFit()
                                .frame(width: 80, height: 60)
                                .padding(.bottom, 14)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                content
            }
        }
        .foregroundStyle(RoomPaper.ink)
        .fontDesign(.rounded)
        .tint(RoomPaper.moss)
        .background(RoomPaper.leaf)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { windowHeight = $0 }
        .presentationBackground(RoomPaper.leaf)
        .presentationDragIndicator(.visible)
        .presentationDetents(presentationDetents)
    }

    private var presentationDetents: Set<PresentationDetent> {
        guard scrolls, !compact else { return detents }
        return fittedHeight > 0 ? detents.union([.height(fittedHeight)]) : detents.union([.medium])
    }

    private var header: some View {
        let titleText = title
        return VStack(spacing: 0) {
            HStack(spacing: compact ? 8 : 10) {
                Image(decorative: image).renderingMode(.original).resizable().scaledToFit()
                    .frame(width: compact ? 36 : 52, height: compact ? 33 : 48)
                    .accessibilityHidden(true)
                Text(verbatim: titleText)
                    .font(RoomTitleFont.font(for: titleText, size: compact ? 20 : 24, relativeTo: .title2,
                                             maximum: compact ? 26 : 30, typeSize: typeSize))
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let close, !compact {
                    RoomFolioCloseButton(close: close)
                }
            }
            .padding(.horizontal, 20)
            .frame(minHeight: compact ? 50 : 70)
            .padding(.top, compact ? 4 : 14)
            RoomStitchedRule().padding(.horizontal, 20)
        }
    }
}

/// A card of `sheet` paper, corner 18, 1 pt `edge` stroke, inset 16 from the panel edges. A stitched
/// rule goes between the rows it is given. `footer` sits under the card in footnote ink, as a
/// List section footer would (the limits text of 房间管理 and 猫咪管理).
struct RoomFolioCard<Content: View>: View {
    private let footer: Text?
    private let content: Content

    init(footer: Text? = nil, @ViewBuilder content: () -> Content) {
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            RoomStitchedRule().padding(.horizontal, 16)
                        }
                        row
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let card = RoundedRectangle(cornerRadius: RoomPaper.cardCorner, style: .continuous)
                card.fill(RoomPaper.sheet).overlay { card.strokeBorder(RoomPaper.edge, lineWidth: 1) }
            }
            if let footer {
                footer
                    .font(.footnote)
                    .foregroundStyle(RoomPaper.note)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.horizontal, 16)
    }
}

/// A row's title (`.body`) and optional note (`.footnote`, ink at 75 %).
struct RoomFolioRowText: View {
    let title: Text
    var note: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            title.font(.body)
            if let note {
                note.font(.footnote).foregroundStyle(RoomPaper.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.leading)
    }
}

/// A card row: text on the leading side, any accessory on the trailing side, at least 44 pt tall,
/// padding 16.
struct RoomFolioRow<Accessory: View>: View {
    private let title: Text
    private let note: Text?
    private let accessory: Accessory

    /// `Text("…")` for fixed copy, `Text(verbatim: room.name)` for a name the user typed.
    init(title: Text, note: Text? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.note = note
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            RoomFolioRowText(title: title, note: note)
            Spacer(minLength: 0)
            accessory
        }
        .padding(16)
        .frame(minHeight: 44)
    }
}

/// A system toggle in a card row, tinted moss. The note is part of the toggle's label, so VoiceOver
/// reads it with the title.
struct RoomFolioToggleRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: Text
    var note: Text?
    @Binding var isOn: Bool
    var id: String?

    var body: some View {
        Toggle(isOn: $isOn) { RoomFolioRowText(title: title, note: note) }
            // At accessibility sizes the switch goes under the text, so the text keeps the row's width.
            .toggleStyle(StackedToggleStyle(stacked: typeSize.isAccessibilitySize))
            .tint(RoomPaper.moss)
            .padding(16)
            .frame(minHeight: 44)
            .modifier(OptionalIdentifier(id: id))
    }
}

private struct StackedToggleStyle: ToggleStyle {
    let stacked: Bool

    func makeBody(configuration: Configuration) -> some View {
        if stacked {
            VStack(alignment: .leading, spacing: 10) {
                configuration.label
                Toggle(configuration).labelsHidden()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityRepresentation { Toggle(configuration) }
        } else {
            Toggle(configuration)
        }
    }
}

private struct OptionalIdentifier: ViewModifier {
    let id: String?

    func body(content: Content) -> some View {
        if let id { content.accessibilityIdentifier(id) } else { content }
    }
}

/// The label of the 新建房间 / 添加猫咪 row.
struct RoomFolioAddLabel: View {
    let title: Text

    var body: some View {
        Label {
            title.font(.body)
        } icon: {
            Image(systemName: "plus").foregroundStyle(RoomPaper.moss)
        }
        .foregroundStyle(RoomPaper.ink)
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
    }
}

/// A choice among a few items. Unselected: `paper` with an `edge` stroke. Selected: `moss` with a
/// checkmark and `sealInk` text, so shape and colour both say which one it is. `swatch` paints a
/// small sample (for a season: wall over floor).
struct RoomPaperChip: View {
    @Environment(\.isEnabled) private var isEnabled
    /// `Text("…")` for a key, `Text(verbatim:)` for an already-localised name such as `RoomTheme.title`.
    let title: Text
    let selected: Bool
    var swatch: [Color] = []
    let action: () -> Void

    var body: some View {
        Button(action: action) { ChipFace(title: title, selected: selected, swatch: swatch) }
            .buttonStyle(.roomToken)
            .saturation(isEnabled ? 1 : 0)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private struct ChipFace: View {
        @Environment(\.roomPaperPressed) private var pressed
        let title: Text
        let selected: Bool
        let swatch: [Color]

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            HStack(spacing: 6) {
                if !swatch.isEmpty {
                    // A painted sample: the colours as diagonal bands, like a paint chip.
                    ZStack {
                        ForEach(swatch.indices.reversed(), id: \.self) { index in
                            Rectangle().fill(swatch[index])
                                .frame(width: 34, height: 34 * CGFloat(index + 1) / CGFloat(swatch.count))
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .rotationEffect(.degrees(-35))
                    .frame(width: 22, height: 22)
                    .clipShape(.rect(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).stroke(RoomPaper.edge, lineWidth: 1) }
                    .accessibilityHidden(true)
                }
                if selected {
                    Image(systemName: "checkmark").font(.system(.caption, weight: .bold)).accessibilityHidden(true)
                }
                title.font(.system(.subheadline, design: .rounded, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .foregroundStyle(selected ? RoomPaper.sealInk : RoomPaper.ink)
            .background {
                shape.fill(selected ? RoomPaper.moss : (pressed ? RoomPaper.flyleaf : RoomPaper.paper))
                    .overlay { if !selected { shape.strokeBorder(RoomPaper.edge, lineWidth: 1) } }
            }
            .contentShape(shape)
        }
    }
}

/// Lays chips out in rows, wrapping when the next one does not fit.
struct RoomChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = Self.size(of: subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = Self.size(of: subviews[index], width: width)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    /// A chip at its natural size, or, when that is wider than the row (English at the largest
    /// text sizes on a narrow phone: “Cautious but curious”), as wide as the row with its words
    /// wrapped, so nothing runs off the card.
    private static func size(of subview: LayoutSubview, width: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        guard natural.width > width, width.isFinite else { return natural }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
}

/// The folio's buttons. `.primary` (保存) is solid moss with `sealInk` text; `.secondary` (取消) is
/// outlined in `edge` with ink text.
struct RoomFolioButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(.body, design: .rounded, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 18)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(kind == .primary ? RoomPaper.sealInk : RoomPaper.ink.opacity(isEnabled ? 1 : 0.6))
            .background {
                switch kind {
                case .primary:
                    shape.fill(RoomPaper.moss.opacity(pressed ? 0.8 : 1))
                case .secondary:
                    shape.fill(pressed ? RoomPaper.flyleaf : RoomPaper.paper)
                        .overlay { shape.strokeBorder(RoomPaper.edge, lineWidth: 1) }
                }
            }
            .saturation(isEnabled ? 1 : 0)
            .scaleEffect(!reduceMotion && pressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.2), value: pressed)
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == RoomFolioButtonStyle {
    static func roomFolio(_ kind: RoomFolioButtonStyle.Kind) -> RoomFolioButtonStyle { RoomFolioButtonStyle(kind: kind) }
}
