import SwiftUI

/// What the room's top band opens (art/ui/OVERLAY_SPEC.md §1, §3).
enum RoomTopAction: String, CaseIterable, Identifiable {
    case settings, theme, sound, rooms, cats, news, share

    var id: String { rawValue }

    /// The full name VoiceOver reads.
    var name: String {
        switch self {
        case .settings: String(localized: "设置")
        case .theme: String(localized: "主题")
        case .sound: String(localized: "音乐音效")
        case .rooms: String(localized: "房间管理")
        case .cats: String(localized: "猫咪管理")
        case .news: String(localized: "公告", table: "News")
        case .share: String(localized: "分享房间")
        }
    }

    /// The short tag under a labelled token; the round tokens have none.
    var tag: String? {
        switch self {
        case .settings, .share: nil
        case .theme: String(localized: "top.theme", defaultValue: "主题")
        case .sound: String(localized: "top.sound", defaultValue: "音乐音效")
        case .rooms: String(localized: "top.rooms", defaultValue: "房间")
        case .cats: String(localized: "top.cats", defaultValue: "猫咪")
        case .news: String(localized: "top.news", defaultValue: "公告", table: "News")
        }
    }

    /// Names what the page does.
    var hint: String? {
        switch self {
        case .settings, .share: nil
        case .theme: String(localized: "换墙纸、地板和灯光")
        case .sound: String(localized: "背景轻音乐和猫咪动作音效")
        case .news: News.hint
        case .rooms: String(localized: "改名、删除房间")
        case .cats: String(localized: "改名、换猫咪模型、移除猫咪")
        }
    }

    /// Placeholder art until the drawn icons arrive.
    var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .theme: "paintpalette"
        case .sound: "music.note"
        case .rooms: "house"
        case .cats: "pawprint"
        case .news: "megaphone"
        case .share: "square.and.arrow.up"
        }
    }

    var identifier: String {
        switch self {
        case .settings: "open-settings"
        case .theme: "open-room-appearance"
        case .sound: "open-room-sound"
        case .rooms: "open-room-manager"
        case .cats: "open-cat-manager"
        case .news: "open-room-news"
        case .share: "open-room-share"
        }
    }

    /// iPad popover height (OVERLAY_SPEC §5): enough for the panel's content.
    var popoverHeight: CGFloat {
        switch self {
        case .sound: 400
        case .share: 680
        case .news: 640
        case .rooms: 520
        // Room for two rows of cat models above the fold.
        case .cats: 720
        case .settings, .theme: 0
        }
    }

    /// 360 pt (OVERLAY_SPEC §5), except 猫咪管理: its cat models are a grid with as many columns as
    /// the width allows (owner, 2026-11-20), and at 540 pt the iPad shows three.
    var popoverWidth: CGFloat { self == .cats ? 540 : 360 }

    /// Changing the room or who lives in it would pull the game out from under the user. 猫咪管理
    /// still opens: the cat model and the names (in 设置 until round 10, which never waited) can
    /// change mid-play; adding, removing or moving a cat waits inside the page.
    var waitsForPlay: Bool { self == .theme || self == .rooms }
}

/// The band drawn over the top of the room in place of the system navigation bar. This view
/// owns the layout and what each token does; how the title plate and the tokens look lives in
/// `RoomTopBarTitleFace` and `RoomTopBarButtonFace`, so the art pass restyles those only.
/// Only the tokens take touches; the room keeps every gesture in between.
struct RoomTopBar: View {
    let playing: Bool
    let perform: (RoomTopAction) -> Void
    /// iPad: the panels open as popovers anchored to their token. nil for a token whose page is
    /// not a popover (设置, 主题) and on iPhone, where they are sheets.
    var popover: (RoomTopAction) -> Binding<Bool>? = { _ in nil }
    var panel: (RoomTopAction) -> AnyView = { _ in AnyView(EmptyView()) }
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad: one row, or the phone's two rows when it does not fit.
                ViewThatFits(in: .horizontal) { oneRow; twoRows }
            } else {
                twoRows
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility5)
    }

    private var oneRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                token(.settings).padding(.trailing, 6)
                token(.theme)
                token(.sound)
            }
            Spacer(minLength: 12)
            title.frame(maxWidth: 360)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                token(.rooms)
                token(.cats)
                token(.news)
                token(.share).padding(.leading, 6)
            }
        }
        .modifier(TopRowWindow())
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    private var twoRows: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                token(.settings)
                Spacer(minLength: 0)
                title
                Spacer(minLength: 0)
                token(.share)
            }
            // Five tokens with their tags are wider than the SE from English xxL and Chinese xxxL:
            // there they drop the tags, as they do at the accessibility sizes.
            ViewThatFits(in: .horizontal) {
                labelledRow
                labelledRow.dynamicTypeSize(.accessibility1)
            }
        }
        .modifier(TopRowWindow())
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var labelledRow: some View {
        TokenRow {
            token(.theme)
            token(.sound)
            RoomTopBarDivider()
            token(.rooms)
            token(.cats)
            token(.news)
        }
    }

    private var title: some View {
        RoomSwitcher()
            .disabled(playing)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func token(_ action: RoomTopAction) -> some View {
        Button { perform(action) } label: {
            RoomTopBarButtonFace(action: action)
        }
        .buttonStyle(.roomToken)
        .disabled(playing && action.waitsForPlay)
        .accessibilityLabel(action.name)
        .accessibilityHint(action.hint ?? "")
        .accessibilityInputLabels([action.name] + (action.tag.map { [$0] } ?? []))
        .accessibilityShowsLargeContentViewer {
            Label(action.name, systemImage: action.symbol)
        }
        .accessibilityIdentifier(action.identifier)
        .tourAnchor(action.identifier, form: action.tag == nil ? .circle : .labelled,
                    padding: TourNoteMetrics.cutoutTightPadding)
        .modifier(TokenPopover(isPresented: popover(action), width: action.popoverWidth, height: action.popoverHeight) { panel(action) })
    }
}

/// Row B on iPhone. Tagged tokens carry their own side padding and sit 4 pt apart. Without tags each
/// is a solid 44 pt circle, which needs air: at 4 pt they read as one overlapping strip.
private struct TokenRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: typeSize.isAccessibilitySize ? 10 : 4) { content }
    }
}

/// A panel in a popover anchored to its token, 360 pt wide (OVERLAY_SPEC §5, Presentation; 猫咪管理 wider).
private struct TokenPopover<Panel: View>: ViewModifier {
    let isPresented: Binding<Bool>?
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let panel: () -> Panel

    func body(content: Content) -> some View {
        if let isPresented {
            content.popover(isPresented: isPresented, arrowEdge: .top) {
                // The panels scroll inside, so a popover cannot size itself to them: give each a
                // height that shows its content (音乐音效 fits in about 372).
                panel().frame(width: width, height: height)
            }
        } else {
            content
        }
    }
}

/// How the room's name looks on its plate in the band.
struct RoomTopBarTitleFace: View {
    let title: String

    var body: some View { RoomTitlePlate(title: title) }
}

/// How one token looks: the design system's paper tokens.
struct RoomTopBarButtonFace: View {
    let action: RoomTopAction

    var body: some View {
        switch action {
        case .settings: RoomRoundToken(glyph: .symbol("gearshape"))
        case .share: RoomRoundToken(glyph: .art("TopShare"))
        case .theme: RoomLabelledToken(title: action.tag ?? "", image: "TopTheme")
        case .sound: RoomLabelledToken(title: action.tag ?? "", image: "TopSound")
        case .rooms: RoomLabelledToken(title: action.tag ?? "", image: "TopRooms")
        case .cats: RoomLabelledToken(title: action.tag ?? "", image: "TopCats")
        case .news: RoomLabelledToken(title: action.tag ?? "", image: "TopNews")
        }
    }
}

/// The small mark between the room's look and sound and the home's rooms and cats.
struct RoomTopBarDivider: View {
    var body: some View { RoomTopDot() }
}

/// Chapter 5 opens its first window on the row of tokens: their bounds and 6 pt, inside the band's
/// own margins, so the window's line and corners stay on screen (it was the whole band, edge to
/// edge, its sides off screen; VISUAL §19.2 item 1).
private struct TopRowWindow: ViewModifier {
    func body(content: Content) -> some View {
        content.tourAnchor("room-top-bar", padding: 6)
    }
}
