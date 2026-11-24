#if DEBUG
import SwiftUI

/// A DEBUG-only page that shows the tour's bubble, mask and chapter card before the tour is wired,
/// in the manner of `OverlayGallery`. Launch with `-MeowverseTourNoteGallery <page>`:
///
/// - `bubble` (default), `plate`, `top`: a stand-in room with the mask open over 添加照片, the room's
///   title plate or 设置, and the bubble beside it. 【下一步】 moves to the next of the three,
///   【跳过这一段】 plays the exit and comes back. `-MeowverseTourNoteAutoplay` steps by itself.
/// - `folio`: a panel with the mask open over one card. The mask follows the colour scheme here.
/// - `sides`: tails on the left and right. `states`: no tail, digits for a long chapter, a note,
///   a finished chapter.
/// - `mask`: the four window forms. Dark mode shows them on the dim base.
/// - `card`, `card-first`: the chapter card of an on-demand chapter and of chapter 1. `card-dim`: the
///   on-demand card over a panel with the dim mask, as on a dark-mode panel (shoot it in dark mode).
/// - `heads`, `bodies`: Bella's six heads in the bubble's name row and her eight whole-body pictures
///   in the card's slot, at their real sizes on the bubble's paper.
///
/// Each step and card shows the Bella picture it would use. `-MeowverseTourNoteHead <name>` and
/// `-MeowverseTourNoteBody <name>` (`BellaHead`, `BellaBody` raw values) put one picture everywhere.
/// `-MeowverseTourNoteShort` swaps the longest lines for short ones. `-MeowverseTourNotePortraitFile <path>`
/// and `-MeowverseTourNoteIllustrationFile <path>` read a picture from the Mac's disk (the simulator can)
/// instead, so new art can be tried before it is exported into the app; a head must be framed like
/// the `bella-head-*` pictures (see `TourNotePortrait`). The room here is a flat stand-in in
/// the daytime room's colour, which stays bright in dark mode; the placement of the bubble is the
/// gallery's own and is not the tour's layout. Nothing here ships.
struct TourNoteGallery: View {
    enum Page: String {
        case bubble, plate, top, folio, sides, states, mask, card, heads, bodies
        case cardFirst = "card-first"
        case cardDim = "card-dim"
    }

    static var page: Page? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-MeowverseTourNoteGallery") else { return nil }
        return args.indices.contains(index + 1) ? Page(rawValue: args[index + 1]) ?? .bubble : .bubble
    }

    let page: Page

    var body: some View {
        switch page {
        case .bubble: Stage(steps: Sample.roomSteps, first: 0, base: .bright) { StandInRoom() }
        case .plate: Stage(steps: Sample.roomSteps, first: 1, base: .bright) { StandInRoom() }
        case .top: Stage(steps: Sample.roomSteps, first: 2, base: .bright) { StandInRoom() }
        case .folio: FolioStage()
        case .sides, .states: Loose(page: page)
        case .mask: WindowForms()
        case .card, .cardFirst, .cardDim: Card(first: page == .cardFirst, dim: page == .cardDim)
        case .heads: Heads()
        case .bodies: Bodies()
        }
    }
}

/// The gallery's own copy: sample lines from docs/onboarding/PRODUCT_PLAN.md, not the shipped script.
private func copy(_ zh: String, _ en: String) -> String {
    Locale.current.language.languageCode?.identifier == "zh" ? zh : en
}

private let short = ProcessInfo.processInfo.arguments.contains("-MeowverseTourNoteShort")

private func argument(_ flag: String) -> String? {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
    return args[index + 1]
}

private func artFile(_ flag: String) -> Image? {
    argument(flag).flatMap(UIImage.init(contentsOfFile:)).map(Image.init(uiImage:))
}
private let roomColour = Color(red: 0.961, green: 0.929, blue: 0.871) // #F5EDDE, the daytime room page

private enum Target: Hashable { case addPhoto, title, settings, card }

private struct TargetFrames: PreferenceKey {
    static let defaultValue: [Target: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Target: Anchor<CGRect>], nextValue: () -> [Target: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func target(_ target: Target) -> some View {
        anchorPreference(key: TargetFrames.self, value: .bounds) { [target: $0] }
    }
}

private struct Step {
    let target: Target
    let form: TourNoteCutout.Form
    var padding = TourNoteMetrics.cutoutPadding
    /// Trims the measured bounds to the control's visible outline.
    var inset = CGSize.zero
    let line: String
    var next = Sample.next
    var head = BellaHead.default
}

private enum Sample {
    static let speaker = "Bella"
    private static let portraitFile = artFile("-MeowverseTourNotePortraitFile")
    private static let headOverride = argument("-MeowverseTourNoteHead").flatMap(BellaHead.init(rawValue:))
    private static let illustrationFile = artFile("-MeowverseTourNoteIllustrationFile")
    private static let bodyOverride = argument("-MeowverseTourNoteBody").flatMap(BellaBody.init(rawValue:))

    static func portrait(_ head: BellaHead) -> Image { portraitFile ?? (headOverride ?? head).image }
    static func illustration(_ body: BellaBody) -> Image { illustrationFile ?? (bodyOverride ?? body).image }
    static let skip = copy("跳过这一段", "Skip this part") // not-localized: debug gallery, sample tour copy
    static let next = copy("下一步", "Next") // not-localized: debug gallery, sample tour copy
    static let shortLine = copy("点这里，挑一张照片吧。", "Tap here and pick a photo.") // not-localized: debug gallery, sample tour copy

    /// 36 characters and 90 characters: the longest a line may be.
    static let longest = copy("照片里的家具会搬进这间房间。照片只留在这台 iPhone 上，不会上传。", // not-localized: debug gallery, sample tour copy
                              "The furniture in your photo moves in too. Photos stay on this iPhone; nothing is uploaded.")

    static let roomSteps = [
        // 添加照片 sits 1 pt from 互动, so its window takes the tight padding. The bubble is above it,
        // so she can look down at it (H2).
        Step(target: .addPhoto, form: .labelled, padding: TourNoteMetrics.cutoutTightPadding, line: short ? shortLine : longest,
             head: .lookDown),
        Step(target: .title, form: .plate(corner: RoomPaper.bookplateCorner),
             line: copy("Kitty，好名字。上面的门牌也换好了。", "Kitty. Lovely. The nameplate up top says so too."), // not-localized: debug gallery, sample tour copy
             head: .happy),
        Step(target: .settings, form: .circle,
             line: copy("先说到这儿，别的等你用到再讲。想重听，来设置里的“使用导览”。", // not-localized: debug gallery, sample tour copy
                        "That’s all for now. I’ll explain the rest when you get to it. Replay me in Settings."),
             next: copy("好", "OK")), // not-localized: debug gallery, sample tour copy
    ]
}

// MARK: - A page with a mask, a cutout and a bubble

private struct Stage<Backdrop: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.dynamicTypeSize) private var typeSize
    let steps: [Step]
    let first: Int
    let base: TourNoteMask.Base
    let backdrop: Backdrop
    @State private var index: Int
    @State private var shown = false
    private let autoplay = ProcessInfo.processInfo.arguments.contains("-MeowverseTourNoteAutoplay")

    init(steps: [Step], first: Int, base: TourNoteMask.Base, @ViewBuilder backdrop: () -> Backdrop) {
        self.steps = steps
        self.first = first
        self.base = base
        self.backdrop = backdrop()
        _index = State(initialValue: first)
    }

    var body: some View {
        GeometryReader { safe in
            let insets = safe.safeAreaInsets
            backdrop
                .overlayPreferenceValue(TargetFrames.self) { anchors in
                    GeometryReader { full in
                        if let anchor = anchors[steps[index].target] {
                            tour(over: full[anchor], screen: full.size, insets: insets)
                        }
                    }
                    .ignoresSafeArea()
                }
        }
        .task {
            withAnimation { shown = true }
            guard autoplay else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2.4)) } catch { return }
                if index == steps.count - 1 {
                    await leaveAndReturn()
                } else {
                    withAnimation(TourNoteMotion.stepMove) { index += 1 }
                }
            }
        }
    }

    private func leaveAndReturn() async {
        withAnimation { shown = false }
        do { try await Task.sleep(for: .seconds(1.2)) } catch { return }
        // Back to the page's first step while nothing shows, so the entrance plays on its own.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { index = first }
        do { try await Task.sleep(for: .seconds(0.1)) } catch { return }
        withAnimation { shown = true }
    }

    private func tour(over bounds: CGRect, screen: CGSize, insets: EdgeInsets) -> some View {
        let step = steps[index]
        let cutout = TourNoteCutout(around: bounds.insetBy(dx: step.inset.width, dy: step.inset.height),
                                form: step.form, padding: step.padding)
        let margin = TourNoteMetrics.bubbleMargin
        let width = min(screen.width - 2 * margin, TourNoteMetrics.bubbleMaxWidth(regular: widthClass == .regular))
        let x = TourNoteMetrics.bubbleX(width: width, screenWidth: screen.width, window: cutout.rect)
        // Above or below the window, whichever has more room.
        let above = cutout.rect.minY - insets.top > screen.height - insets.bottom - cutout.rect.maxY
        let gap = TourNoteMetrics.tailGap + TourNoteMetrics.cutoutLine / 2
        let tail = TourNoteBubbleShape.Tail(edge: above ? .bottom : .top, offset: cutout.rect.midX - x)
        // The tip of the tail stops 6 pt from the window's line.
        let inset = above ? screen.height - (cutout.rect.minY - gap) : cutout.rect.maxY + gap
        return ZStack {
            TourNoteMask(base: base, cutout: cutout, isShown: shown)
            if shown {
                TourNoteBubble(speaker: Sample.speaker, portrait: Sample.portrait(step.head), line: step.line,
                           progress: .init(step: index + 2, count: steps.count + 1), tail: tail,
                           maxHeight: typeSize.isAccessibilitySize ? screen.height * TourNoteMetrics.tallestShare : nil,
                           skipTitle: Sample.skip, nextTitle: step.next,
                           skip: { Task { await leaveAndReturn() } },
                           next: { withAnimation(TourNoteMotion.stepMove) { index = (index + 1) % steps.count } })
                    .frame(width: width)
                    .padding(.leading, x)
                    .padding(above ? .bottom : .top, inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: above ? .bottomLeading : .topLeading)
                    // Under Reduce Motion the bubble does not travel: the old one fades out, the new one in.
                    .id(reduceMotion ? index : 0)
                    .transition(.tourNote(tail: tail.edge, reduceMotion: reduceMotion))
            }
        }
        .animation(reduceMotion ? TourNoteMotion.reduced : TourNoteMotion.stepMove, value: index)
    }
}

// MARK: - Backdrops

/// The room page drawn flat: the real top-band tokens and bookplates, and stand-ins for 互动 and
/// 添加照片 that copy the look of `RoomActionControls` so each can be measured on its own.
private struct StandInRoom: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ZStack {
            roomColour.ignoresSafeArea()
            VStack(spacing: 8) {
                ZStack {
                    HStack {
                        RoomRoundToken(glyph: .symbol("gearshape")).target(.settings)
                        Spacer()
                        RoomRoundToken(glyph: .art("TopShare"))
                    }
                    RoomTitlePlate(title: copy("Kitty 的房间", "Kitty’s room")).target(.title) // not-localized: debug gallery, sample room name
                }
                .padding(.horizontal, 12)
                HStack(alignment: .top, spacing: 4) {
                    RoomLabelledToken(title: copy("主题", "Theme"), image: "TopTheme") // not-localized: debug gallery, copy owned by the room screen
                    RoomLabelledToken(title: copy("音乐音效", "Sound"), image: "TopSound") // not-localized: debug gallery, copy owned by the room screen
                    RoomTopDot().padding(.horizontal, -4)
                    RoomLabelledToken(title: copy("房间", "Rooms"), image: "TopRooms") // not-localized: debug gallery, copy owned by the room screen
                    RoomLabelledToken(title: copy("猫咪", "Cats"), image: "TopCats") // not-localized: debug gallery, copy owned by the room screen
                }
                Spacer()
                HStack(alignment: .bottom) {
                    RoomLibraryControls(photos: {}, furniture: {})
                    Spacer(minLength: 8)
                    let layout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 5))
                        : AnyLayout(HStackLayout(alignment: .bottom, spacing: 6))
                    layout {
                        action(copy("互动", "Play"), image: "RoomPlayPaw") // not-localized: debug gallery, copy owned by the room screen
                        action(copy("添加照片", "Add photos"), image: "RoomAddCamera").target(.addPhoto) // not-localized: debug gallery, copy owned by the room screen
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .padding(.top, 4)
        }
    }

    private func action(_ title: String, image: String) -> some View {
        let large = typeSize.isAccessibilitySize
        let layout = large ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: -3))
        return layout {
            Image(image).renderingMode(.original).resizable().scaledToFit()
                .frame(width: large ? 31 : 47, height: large ? 31 : 44)
                .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
            Text(verbatim: title)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .roomPaper(corner: 5)
        }
        .frame(minWidth: 44, minHeight: 44)
    }
}

/// A panel with one card, for the mask on a page that follows the colour scheme.
private struct FolioStage: View {
    @Environment(\.colorScheme) private var scheme
    @State private var music = false
    @State private var effects = true

    var body: some View {
        let step = Step(target: .card, form: .plate(corner: RoomPaper.cardCorner),
                        inset: CGSize(width: 16, height: 0), // the card's own side padding
                        line: copy("玩具和小零食的声音，在这里开关。", "The sounds of toys and treats switch on and off here.")) // not-localized: debug gallery, sample tour copy
        Stage(steps: [step], first: 0, base: scheme == .dark ? .dim : .bright) {
            RoomFolio(title: copy("音乐音效", "Music & sound"), image: "TopSound") { // not-localized: debug gallery, copy owned by the room screen
                RoomFolioCard {
                    RoomFolioToggleRow(title: Text("背景轻音乐"), isOn: $music)
                    RoomFolioToggleRow(title: Text("猫咪动作音效"), isOn: $effects)
                }
                .target(.card)
            }
        }
    }
}

// MARK: - Bubbles on their own

private struct Loose: View {
    let page: TourNoteGallery.Page

    var body: some View {
        ZStack {
            StandInRoom()
            TourNoteMask(base: .bright).ignoresSafeArea()
            VStack(spacing: 24) {
                if page == .sides {
                    bubble(tail: .init(edge: .leading, offset: 60), step: 1, count: 4)
                    bubble(tail: .init(edge: .trailing, offset: 110), step: 3, count: 4)
                } else {
                    TourNoteBubble(speaker: Sample.speaker, portrait: Sample.portrait(.waiting), line: Sample.shortLine,
                               note: copy("只有你选中的照片会被读取。", "Only the photos you pick are read."), // not-localized: debug gallery, sample tour copy
                               progress: .init(step: 3, count: 7), skipTitle: Sample.skip, nextTitle: Sample.next, skip: {}, next: {})
                    TourNoteBubble(speaker: Sample.speaker, portrait: Sample.portrait(.happy),
                               line: copy("设置里的“备份与恢复”能导出一份，换手机也带得走。", // not-localized: debug gallery, sample tour copy
                                          "In Settings, Backup & restore exports a copy you can take to a new phone."),
                               progress: .init(step: 5, count: 4), tail: .init(edge: .top, offset: 34),
                               skipTitle: Sample.skip, nextTitle: copy("知道了", "OK"), skip: {}, next: {}) // not-localized: debug gallery, sample tour copy
                }
            }
            .padding(TourNoteMetrics.bubbleMargin)
        }
    }

    private func bubble(tail: TourNoteBubbleShape.Tail, step: Int, count: Int) -> some View {
        TourNoteBubble(speaker: Sample.speaker, portrait: Sample.portrait(.default), line: Sample.shortLine,
                   progress: .init(step: step, count: count), tail: tail,
                   skipTitle: Sample.skip, nextTitle: Sample.next, skip: {}, next: {})
            .frame(maxWidth: 290)
    }
}

// MARK: - The window forms

private struct WindowForms: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tile(.circle) { RoomRoundToken(glyph: .symbol("gearshape")) }
                tile(.plate(corner: RoomPaper.bookplateCorner)) {
                    RoomTitlePlate(title: copy("Kitty 的房间", "Kitty’s room"), showsChevron: false) // not-localized: debug gallery, sample room name
                }
            }
            HStack(spacing: 0) {
                tile(.plate(corner: RoomPaper.cardCorner)) {
                    Text(verbatim: copy("背景轻音乐", "Background music")) // not-localized: debug gallery, copy owned by the room screen
                        .font(.system(.body, design: .rounded))
                        .padding(16)
                        .roomPaper(corner: RoomPaper.cardCorner)
                }
                tile(.labelled, padding: TourNoteMetrics.cutoutTightPadding) {
                    RoomLabelledToken(title: copy("主题", "Theme"), image: "TopTheme") // not-localized: debug gallery, copy owned by the room screen
                }
            }
        }
        .ignoresSafeArea()
    }

    private func tile(_ form: TourNoteCutout.Form, padding: CGFloat = TourNoteMetrics.cutoutPadding,
                      @ViewBuilder control: () -> some View) -> some View {
        ZStack {
            scheme == .dark ? RoomPaper.leaf : roomColour
            control().target(.card)
        }
        .overlayPreferenceValue(TargetFrames.self) { anchors in
            GeometryReader { proxy in
                if let anchor = anchors[.card] {
                    TourNoteMask(base: scheme == .dark ? .dim : .bright,
                             cutout: TourNoteCutout(around: proxy[anchor], form: form, padding: padding))
                }
            }
        }
        .clipped()
    }
}

// MARK: - The chapter card

private struct Card: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var scheme
    let first: Bool
    /// Over a panel that follows the colour scheme, rather than the daytime room.
    var dim = false
    @State private var shown = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if dim {
                    StandInPanel()
                    TourNoteMask(base: scheme == .dark ? .dim : .bright, strength: .card).ignoresSafeArea()
                } else {
                    StandInRoom()
                    TourNoteMask(base: .bright, strength: .card).ignoresSafeArea()
                }
                if shown {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        card(maxHeight: typeSize.isAccessibilitySize ? proxy.size.height * TourNoteMetrics.tallestShare : nil)
                        Spacer(minLength: 0).frame(maxHeight: proxy.size.height * 0.14)
                    }
                    .padding(TourNoteMetrics.bubbleMargin)
                    .transition(.tourNote(tail: nil, reduceMotion: reduceMotion))
                }
            }
        }
        .task { withAnimation { shown = true } }
    }

    private func card(maxHeight: CGFloat?) -> some View {
        let start = TourChapterCard.Exit(title: copy("开始", "Start")) {} // not-localized: debug gallery, sample tour copy
        let skipAll = TourChapterCard.Exit(title: copy("全部跳过", "Skip all")) {} // not-localized: debug gallery, sample tour copy
        return Group {
            if first {
                TourChapterCard(speaker: Sample.speaker, illustration: Sample.illustration(.greeting), title: copy("你好，我是 Bella", "Hi, I’m Bella"), // not-localized: debug gallery, sample tour copy
                                line: copy("我是这里的向导，带你认识一下这间小房间。", // not-localized: debug gallery, sample tour copy
                                           "I’m the guide around here. Let me show you around this little room."),
                                maxHeight: maxHeight, later: skipAll, start: start)
            } else {
                TourChapterCard(speaker: Sample.speaker, illustration: Sample.illustration(.album), title: copy("点家具，看回忆", "Tap a piece, see the memory"), // not-localized: debug gallery, sample tour copy
                                line: copy("第一件带照片的家具搬进来了。看看它记着什么？", // not-localized: debug gallery, sample tour copy
                                           "Your first piece with a photo is in. Want to see what it remembers?"),
                                maxHeight: maxHeight, later: .init(title: Sample.skip) {}, start: start, skipAll: skipAll)
            }
        }
    }
}

/// A panel with two cards behind the dim card: the 音乐音效 panel, which follows the colour scheme.
private struct StandInPanel: View {
    @State private var music = false
    @State private var effects = true

    var body: some View {
        RoomFolio(title: copy("音乐音效", "Music & sound"), image: "TopSound") { // not-localized: debug gallery, copy owned by the room screen
            RoomFolioCard {
                RoomFolioToggleRow(title: Text("背景轻音乐"), isOn: $music)
                RoomFolioToggleRow(title: Text("猫咪动作音效"), isOn: $effects)
            }
        }
    }
}

// MARK: - Bella's pictures at their real sizes

private struct Heads: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(BellaHead.allCases, id: \.self) { head in
                HStack(spacing: 10) {
                    TourNotePortrait(image: Sample.portrait(head), name: Sample.speaker)
                    Text(verbatim: Sample.speaker)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(RoomPaper.ink)
                    Spacer(minLength: 8)
                    Text(verbatim: head.rawValue)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(RoomPaper.note)
                }
                .padding(.top, TourNoteMetrics.portraitEarRoom)
            }
        }
        .padding(TourNoteMetrics.bubblePadding)
        .background(RoomPaper.sheet, in: .rect(cornerRadius: RoomPaper.cardCorner))
        .padding(TourNoteMetrics.bubbleMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoomPaper.leaf)
    }
}

private struct Bodies: View {
    var body: some View {
        let size = TourNoteMetrics.illustrationSize
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<4) { row in
                GridRow {
                    ForEach(0..<2) { column in
                        Sample.illustration(BellaBody.allCases[row * 2 + column])
                            .resizable().scaledToFit()
                            .frame(width: size.width, height: size.height)
                            .background(RoomPaper.sheet)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoomPaper.leaf)
    }
}
#endif
