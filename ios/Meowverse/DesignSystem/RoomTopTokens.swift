import SwiftUI

// The top band's building blocks (art/ui/OVERLAY_SPEC.md §2–3). They are label views plus one button
// style and one accessibility modifier, so the same token works in a Button, a NavigationLink or a
// Menu (`.menuStyle(.button)`). Layout, actions, identifiers and every string belong to the caller.
// In `RoomTopBar`: `RoomTopBarTitleFace` → `RoomTitlePlate(title:)`, `RoomTopBarButtonFace` →
// `RoomRoundToken(glyph:)` for 设置 and 分享, `RoomLabelledToken(title: tag, image:)` for the
// other four, `RoomTopBarDivider` → `RoomTopDot()`, and `.buttonStyle(.plain)` → `.buttonStyle(.roomToken)`.

extension EnvironmentValues {
    /// Set by `RoomTokenButtonStyle` while a token is held under Reduce Motion: the paper darkens
    /// to `flyleaf` instead of the token shrinking.
    @Entry var roomPaperPressed = false
}

/// Press feedback for every top-band token and paper chip: scale 0.94 with a 0.2 s spring, or under
/// Reduce Motion no scale and the paper turns `flyleaf`.
struct RoomTokenButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.roomPaperPressed, reduceMotion && configuration.isPressed)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.94 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.2), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == RoomTokenButtonStyle {
    static var roomToken: RoomTokenButtonStyle { RoomTokenButtonStyle() }
}

/// The paper of a token, a tag or the title plate. Disabled reads as grey paper with ink at 60 %,
/// and the label stays readable.
private struct TokenPaper: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.roomPaperPressed) private var pressed
    let shape: AnyShape
    var shadow: (opacity: Double, radius: CGFloat, y: CGFloat) = (0.16, 1, 1)

    func body(content: Content) -> some View {
        content
            .foregroundStyle(RoomPaper.ink.opacity(isEnabled ? 1 : 0.6))
            .background {
                shape.fill(pressed ? RoomPaper.flyleaf : RoomPaper.paper)
                    .overlay { shape.stroke(RoomPaper.edge, lineWidth: 1) }
                    .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
            }
    }
}

/// 设置 and 分享: a 44 pt paper circle with a 30 pt icon.
struct RoomRoundToken: View {
    enum Glyph {
        /// An SF Symbol drawn in ink, as 设置 uses `gearshape`.
        case symbol(String)
        /// An image set from the asset catalog, drawn in its own colours.
        case art(String)
    }

    @Environment(\.isEnabled) private var isEnabled
    let glyph: Glyph

    var body: some View {
        Group {
            switch glyph {
            case .symbol(let name):
                Image(systemName: name).font(.system(size: 22, weight: .regular))
            case .art(let name):
                Image(name).renderingMode(.original).resizable().scaledToFit()
            }
        }
        .frame(width: 30, height: 30)
        .frame(width: 44, height: 44)
        .modifier(TokenPaper(shape: AnyShape(Circle())))
        .saturation(isEnabled ? 1 : 0)
        .contentShape(.circle)
    }
}

/// 主题, 音乐音效, 房间管理, 猫咪管理: a 34 × 31 icon over a paper tag. At accessibility text sizes
/// the tag hides and the token becomes a 44 × 44 icon; `roomTokenAccessibility` gives it the Large
/// Content Viewer.
struct RoomLabelledToken: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.isEnabled) private var isEnabled
    /// The short on-screen word (主题, 音乐音效, 房间, 猫咪 / Theme, Sound, Rooms, Cats), already localised.
    let title: String
    let image: String

    var body: some View {
        let iconOnly = typeSize.isAccessibilitySize
        VStack(spacing: 0) {
            Image(image).renderingMode(.original).resizable().scaledToFit()
                .frame(width: iconOnly ? 30 : 34, height: iconOnly ? 28 : 31)
                .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
            if !iconOnly {
                Text(verbatim: title)
                    .font(.system(.caption2, design: .rounded, weight: .bold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 5).padding(.vertical, 2.5)
                    .modifier(TokenPaper(shape: AnyShape(RoundedRectangle(cornerRadius: 5, style: .continuous)),
                                         shadow: (0.12, 2, 2)))
            }
        }
        .padding(.horizontal, iconOnly ? 0 : 7)
        .frame(minWidth: iconOnly ? 44 : 52, minHeight: 44)
        .background {
            if iconOnly {
                Circle().fill(RoomPaper.paper).overlay { Circle().stroke(RoomPaper.edge, lineWidth: 1) }
                    .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
                    .frame(width: 44, height: 44)
            }
        }
        .saturation(isEnabled ? 1 : 0)
        .contentShape(.rect)
    }
}

extension View {
    /// Accessibility for a token used outside `RoomTopBar` (which sets its own): label, hint,
    /// identifier, Voice Control names and the Large Content Viewer. All text comes from the caller,
    /// already localised.
    func roomTokenAccessibility(label: Text, hint: Text? = nil, inputLabels: [Text] = [], id: String,
                                largeContent: Text, image: String? = nil, symbol: String? = nil) -> some View {
        accessibilityLabel(label)
            .accessibilityHint(hint ?? Text(verbatim: ""))
            .accessibilityInputLabels(inputLabels.isEmpty ? [label] : inputLabels)
            .accessibilityIdentifier(id)
            .accessibilityShowsLargeContentViewer {
                Label {
                    largeContent
                } icon: {
                    if let image { Image(image) } else if let symbol { Image(systemName: symbol) }
                }
            }
    }
}

/// The 3 pt `edge` dot between the room's look and sound and its home management, with 16 pt of
/// space around it (row B on iPhone). Decorative.
struct RoomTopDot: View {
    var body: some View {
        Circle().fill(RoomPaper.edge).frame(width: 3, height: 3)
            .frame(width: 16, height: 31)
            .accessibilityHidden(true)
    }
}

/// The 8 × 4 chevron of the title plate, a 2 pt ink stroke.
private nonisolated struct PlateChevron: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
    }
}

/// The room's name on a bookplate: 44 high, corner 14, a second edge line inset 3 pt, the title face,
/// and a chevron. Width is the text plus 46; cap it with `.frame(maxWidth:)`. A long name shrinks to
/// 80 % and then ends in an ellipsis. Use as the label of the room switcher's Menu and give the Menu
/// the full name as its accessibility label.
struct RoomTitlePlate: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    var showsChevron = true

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
                .font(RoomTitleFont.font(for: title, typeSize: typeSize))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)
            if showsChevron {
                PlateChevron()
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 8, height: 4)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 16) // the chevron's centre sits 20 pt from the right edge
        .frame(height: 44)
        .modifier(TokenPaper(shape: AnyShape(RoundedRectangle(cornerRadius: RoomPaper.bookplateCorner, style: .continuous))))
        .overlay {
            RoundedRectangle(cornerRadius: RoomPaper.bookplateCorner - 3, style: .continuous)
                .stroke(RoomPaper.edge, lineWidth: 1)
                .padding(3)
                .allowsHitTesting(false)
        }
        .saturation(isEnabled ? 1 : 0)
        .contentShape(.rect(cornerRadius: RoomPaper.bookplateCorner))
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityShowsLargeContentViewer { Text(verbatim: title) }
    }
}
