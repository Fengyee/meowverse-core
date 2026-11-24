import SwiftUI

/// The outline of a tour bubble: `sheet` paper with corner 18 and, on one edge, a 16 × 9 tail whose
/// tip is rounded by 2 pt. One path, so the fill and the edge line have no seam at the tail.
///
/// The shape's rect includes the tail: the paper is the rect less 9 pt on the tail's edge.
nonisolated struct TourNoteBubbleShape: Shape {
    struct Tail: Equatable, Sendable {
        /// The edge of the bubble the tail sticks out of: `.top` when the control is above the
        /// bubble. `.leading` is the left edge; the app has no right-to-left language.
        var edge: Edge
        /// Where the tip is along that edge, from the left (or top) end of the shape's rect. Give
        /// the centre of the cutout; the tip is kept 28 pt clear of the bubble's corners.
        var offset: CGFloat
    }

    var tail: Tail?
    /// `RoomPaper.cardCorner` for a bubble.
    var cornerRadius: CGFloat

    var animatableData: CGFloat {
        get { tail?.offset ?? 0 }
        set { tail?.offset = newValue }
    }

    /// The paper inside `rect`, without the tail.
    static func paper(in rect: CGRect, tail: Tail?) -> CGRect {
        let h = TourNoteMetrics.tailHeight
        return switch tail?.edge {
        case .top: CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h)
        case .bottom: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - h)
        case .leading: CGRect(x: rect.minX + h, y: rect.minY, width: rect.width - h, height: rect.height)
        case .trailing: CGRect(x: rect.minX, y: rect.minY, width: rect.width - h, height: rect.height)
        case nil: rect
        }
    }

    /// The tip of the tail in `rect`, for a host that wants to check where it points.
    static func tip(in rect: CGRect, tail: Tail) -> CGPoint {
        let paper = paper(in: rect, tail: tail)
        let clear = TourNoteMetrics.tailCornerClearance
        func along(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            low <= high ? min(max(value, low), high) : (low + high) / 2
        }
        switch tail.edge {
        case .top, .bottom:
            let x = along(rect.minX + tail.offset, paper.minX + clear, paper.maxX - clear)
            return CGPoint(x: x, y: tail.edge == .top ? rect.minY : rect.maxY)
        case .leading, .trailing:
            let y = along(rect.minY + tail.offset, paper.minY + clear, paper.maxY - clear)
            return CGPoint(x: tail.edge == .leading ? rect.minX : rect.maxX, y: y)
        }
    }

    func path(in rect: CGRect) -> Path {
        let paper = Self.paper(in: rect, tail: tail)
        let corner = min(cornerRadius, min(paper.width, paper.height) / 2)
        let sheet = Path(roundedRect: paper, cornerRadius: corner, style: .continuous)
        guard let tail else { return sheet }

        let tip = Self.tip(in: rect, tail: tail)
        let h = TourNoteMetrics.tailHeight
        // The triangle starts 1 pt inside the paper so the union has no hairline, and is widened
        // there so it is still 16 pt wide where it leaves the paper.
        let overlap: CGFloat = 1
        let half = TourNoteMetrics.tailWidth / 2 * (h + overlap) / h
        let out: CGVector = switch tail.edge {
        case .top: CGVector(dx: 0, dy: -1)
        case .bottom: CGVector(dx: 0, dy: 1)
        case .leading: CGVector(dx: -1, dy: 0)
        case .trailing: CGVector(dx: 1, dy: 0)
        }
        let side = CGVector(dx: -out.dy, dy: out.dx)
        let root = CGPoint(x: tip.x - out.dx * (h + overlap), y: tip.y - out.dy * (h + overlap))
        let first = CGPoint(x: root.x - side.dx * half, y: root.y - side.dy * half)
        let second = CGPoint(x: root.x + side.dx * half, y: root.y + side.dy * half)
        var flag = Path()
        flag.move(to: first)
        flag.addArc(tangent1End: tip, tangent2End: second, radius: TourNoteMetrics.tailTipRadius)
        flag.addLine(to: second)
        flag.closeSubpath()
        return sheet.union(flag)
    }
}

/// Bella's portrait in a bubble (VISUAL §8.3): a 44 pt circle on the icon's sage (`RoomPaper.sage`)
/// with a 1 pt `edge` line, and her head cut out and set on it. The head is about as wide as the
/// circle, the circle's lower edge cuts her chest, and her ears stand about 6 pt above the circle.
/// The view's own frame is the circle: the ears overflow it upwards by 6 pt and, for a tilted or
/// spread ear, sideways by up to 3 pt, so leave that clear.
///
/// `image` is one of the `bella-head-*` pictures (`BellaHead.image`), or any picture framed like them:
/// 50 × 50 pt for a 44 pt circle, the circle's top 6 pt below the picture's, already cut to what shows.
/// nil shows `BellaHead.default`. The portrait does not change with the colour scheme. A new expression
/// replaces the old one in place with no cross-fade; do not give the portrait a transition or switch
/// off its animations, or it stops travelling with the bubble.
struct TourNotePortrait: View {
    var image: Image?
    /// Not drawn: the portrait has no lettering since the real pictures came in. Kept for callers.
    let name: String
    var size = TourNoteMetrics.portraitSize

    var body: some View {
        let unit = size / TourNoteMetrics.portraitSize
        let ears = TourNoteMetrics.portraitEarRoom * unit
        let sides = TourNoteMetrics.portraitSideRoom * unit
        ZStack {
            Circle().fill(TourNoteInk.portraitBase)
            Circle().strokeBorder(RoomPaper.edge, lineWidth: 1)
            (image ?? BellaHead.default.image)
                .resizable().interpolation(.high)
                .frame(width: size + 2 * sides, height: size + ears)
                .offset(y: -ears / 2)
            // The circle's line again over her chest; behind her head it stays hidden.
            Circle().strokeBorder(RoomPaper.edge, lineWidth: 1)
                .mask(alignment: .bottom) { Rectangle().frame(height: size * 0.42) }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The words of a bubble or a card. They show plainly when they fit the height the paper is allowed,
/// and otherwise scroll (VISUAL §9.1, §10.1). Scrolling, the window onto them is a whole number of
/// lines and a half, so the cut always falls through the middle of a line and it is plain there is
/// more; that half line fades out (the fade is half a line high, at whichever edge is cut). The
/// scroll indicator flashes when the scrolling words appear.
///
/// The line is measured, not assumed: give `font` and a `sample` of the words (a few characters of
/// the line; Chinese falls back to a taller face than Latin), and `lead`, how far the first of those
/// lines sits below the top of `content` (a card's title above its sentence). Without a sample the
/// window is not snapped and the fade is `TourNoteMetrics.scrollFade`.
struct TourNoteWords<Content: View>: View {
    private struct Cuts: Equatable {
        var top = false
        var bottom = false
    }

    /// The indicator flashes when the words start to need scrolling and when they change.
    private struct Flash: Equatable {
        var words: String?
        var scrolls: Bool
    }

    @State private var cuts = Cuts()
    @State private var oneLine: CGFloat = 0
    @State private var twoLines: CGFloat = 0
    private let font: Font
    private let sample: String?
    private let lead: CGFloat
    private let content: Content

    init(font: Font = .system(.body, design: .rounded), sample: String? = nil, lead: CGFloat = 0,
         @ViewBuilder content: () -> Content) {
        self.font = font
        self.sample = sample
        self.lead = lead
        self.content = content()
    }

    private var line: CGFloat { twoLines - oneLine }

    var body: some View {
        let fade = line > 0 ? line / 2 : TourNoteMetrics.scrollFade
        ViewThatFits(in: .vertical) {
            content
            TourNoteLineWindow(line: line, lead: lead) {
                ScrollView { content }
                    .scrollBounceBehavior(.basedOnSize)
                    // Not `onAppear`: inside `ViewThatFits` the scroll view appears before it has
                    // anything to scroll, and no flash showed (recorded on the simulator at AX3).
                    .scrollIndicatorsFlash(trigger: Flash(words: sample, scrolls: cuts.top || cuts.bottom))
                    .onScrollGeometryChange(for: Cuts.self) { geometry in
                        let shown = geometry.visibleRect
                        return Cuts(top: shown.minY > 0.5, bottom: shown.maxY < geometry.contentSize.height - 0.5)
                    } action: { _, new in
                        cuts = new
                    }
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: cuts.top ? fade : 0)
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: cuts.bottom ? fade : 0)
                        }
                    }
            }
        }
        .background { probes }
    }

    /// One and two lines of the sample in the words' font, unseen: their difference is the line step.
    @ViewBuilder private var probes: some View {
        if let sample = sample.map({ String($0.prefix(8)) }) {
            ZStack {
                Text(verbatim: sample)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { oneLine = $0 }
                Text(verbatim: sample + "\n" + sample)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { twoLines = $0 }
            }
            .font(font)
            .lineLimit(2)
            .fixedSize()
            .hidden()
            .accessibilityHidden(true)
        }
    }
}

/// Its own height, never more than `limit`: unlike `.frame(maxHeight:)` with `.fixedSize`, which sizes
/// from the content's ideal height and centres it, this asks the content again at the capped height
/// and keeps its answer, so scrolling words snapped to whole lines and a half pull the paper in.
private nonisolated struct TourNoteHeightCap: Layout {
    let limit: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        return view.sizeThatFits(asked(view, width: proposal.width))
    }

    // Placed with the very proposal it was measured with. Placing it at its own measured height
    // instead let rounding inside the stack hand the words a hair less than they need, and words
    // that fit scrolled (seen at standard sizes on iPhone 17 Pro).
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        view.place(at: bounds.origin, proposal: asked(view, width: bounds.width))
    }

    /// Its ideal height when that is within the limit (as `.fixedSize` asked), else the limit.
    private func asked(_ view: LayoutSubview, width: CGFloat?) -> ProposedViewSize {
        let ideal = ProposedViewSize(width: width, height: nil)
        guard let limit, view.sizeThatFits(ideal).height > limit else { return ideal }
        return ProposedViewSize(width: width, height: limit)
    }
}

extension View {
    /// The height the bubble or card needs, up to `limit` (nil: no limit), at the width it is offered.
    func tourNoteHeight(atMost limit: CGFloat?) -> some View {
        TourNoteHeightCap(limit: limit) { self }
    }
}

/// Takes the height it is offered down to `lead` plus a whole number of lines and a half, and gives
/// that to the scroll view. With no line measured yet it takes all of it.
private nonisolated struct TourNoteLineWindow: Layout {
    let line: CGFloat
    let lead: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let size = view.sizeThatFits(proposal)
        guard line > 0, let offered = proposal.height, offered.isFinite else { return size }
        let lines = max(((offered - lead - line / 2) / line + 0.01).rounded(.down), 1)
        return CGSize(width: size.width, height: min(offered, lead + (lines + 0.5) * line))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Where the user is in this chapter: solid moss dots behind, a moss capsule for the current step
/// and `note`-coloured rings ahead, so it reads by shape as well as colour. More than five steps
/// show as digits. The dots change at once, with no fade. Hidden from VoiceOver; the bubble speaks
/// the step.
struct TourNoteDots: View {
    /// 1-based. A step beyond `count` draws every dot solid: the chapter is done.
    let step: Int
    let count: Int

    var body: some View {
        Group {
            if count > TourNoteMetrics.mostDots {
                Text(verbatim: "\(min(step, count))/\(count)")
                    .font(.system(.footnote, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(RoomPaper.note)
            } else {
                // Two shapes rather than a view per dot, so a step changes them without transitions.
                ZStack {
                    TourNoteDotsShape(step: step, count: count, rings: false).fill(RoomPaper.moss)
                    TourNoteDotsShape(step: step, count: count, rings: true)
                        .stroke(RoomPaper.note, lineWidth: TourNoteMetrics.dotRing)
                }
                .frame(width: TourNoteDotsShape.width(step: step, count: count), height: TourNoteMetrics.dotSize)
            }
        }
        .accessibilityHidden(true)
    }
}

private nonisolated struct TourNoteDotsShape: Shape {
    let step: Int
    let count: Int
    /// The rings of the steps ahead, or the solid dots and the capsule.
    let rings: Bool

    static func width(step: Int, count: Int) -> CGFloat {
        let dots = CGFloat(max(count, 1))
        let capsule = (1...max(count, 1)).contains(step) ? TourNoteMetrics.currentDotWidth - TourNoteMetrics.dotSize : 0
        return dots * TourNoteMetrics.dotSize + (dots - 1) * TourNoteMetrics.dotSpacing + capsule
    }

    func path(in rect: CGRect) -> Path {
        let size = TourNoteMetrics.dotSize
        var path = Path()
        var x = rect.minX
        for index in 1...max(count, 1) {
            let width = index == step ? TourNoteMetrics.currentDotWidth : size
            let dot = CGRect(x: x, y: rect.midY - size / 2, width: width, height: size)
            if index > step, rings {
                path.addEllipse(in: dot.insetBy(dx: TourNoteMetrics.dotRing / 2, dy: TourNoteMetrics.dotRing / 2))
            } else if index <= step, !rings {
                path.addRoundedRect(in: dot, cornerSize: CGSize(width: size / 2, height: size / 2))
            }
            x += width + TourNoteMetrics.dotSpacing
        }
        return path
    }
}

/// 【下一步】 and a card's 「开始」: solid moss with `sealInk` text, corner 15, at least 96 × 44. The
/// same look as the page-bottom action of the import flow. Held, it wears 9 % black.
struct TourNoteSolidButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var fillsWidth = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: TourNoteMetrics.nextCorner, style: .continuous)
        configuration.label
            .font(.system(.headline, design: .rounded))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(minWidth: TourNoteMetrics.nextMinWidth, maxWidth: fillsWidth ? .infinity : nil,
                   minHeight: TourNoteMetrics.hitSize)
            .foregroundStyle(RoomPaper.sealInk)
            .background {
                shape.fill(RoomPaper.moss)
                    .overlay {
                        // Under Reduce Motion the press is one view, so it cuts to the button's new
                        // place with it: removed, it faded out where the button had been, a pale
                        // plate above the taller bubble's button (2.1 to 2.2).
                        if reduceMotion {
                            shape.fill(.black.opacity(configuration.isPressed ? 0.09 : 0))
                        } else if configuration.isPressed {
                            shape.fill(.black.opacity(0.09))
                        }
                    }
            }
            .contentShape(shape)
    }
}

/// 【跳过这一段】 on a bubble or a card: words only, in full ink, with a 44 pt hit area. The
/// difference from 【下一步】 is having no paper under it, not being paler. Held, the ink drops to 60 %.
struct TourNoteQuietButtonStyle: ButtonStyle {
    var alignment: Alignment = .leading
    var fillsWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded, weight: .medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(RoomPaper.ink.opacity(configuration.isPressed ? 0.6 : 1))
            .frame(minWidth: TourNoteMetrics.hitSize, maxWidth: fillsWidth ? .infinity : nil,
                   minHeight: TourNoteMetrics.hitSize, alignment: alignment)
            .contentShape(.rect)
    }
}

/// The two buttons of a bubble or a card. The quiet one is always on the left and the solid one on
/// the right. They stack, solid one on top and full width, at accessibility text sizes or when one
/// row cannot hold both without breaking a word. With no quiet title only the solid one is drawn,
/// on the right (the placeholder card's 「知道了」).
struct TourNoteButtonRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let quietTitle: String?
    let solidTitle: String
    var quietID = "tour-skip"
    var solidID = "tour-next"
    let quiet: () -> Void
    let solid: () -> Void
    /// The solid button's word fades in with the bubble's new words (QA_T5 suggestion 1).
    var solidTitleOpacity = 1.0

    var body: some View {
        if typeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    if let quietTitle { quietButton(quietTitle, wraps: false) }
                    Spacer(minLength: 8)
                    solidButton(wraps: false)
                }
                stacked
            }
        }
    }

    private var stacked: some View {
        VStack(spacing: 4) {
            solidButton(wraps: true)
            if let quietTitle { quietButton(quietTitle, wraps: true) }
        }
    }

    private func title(_ words: String, wraps: Bool) -> some View {
        Text(verbatim: words)
            // A new title (「下一步」 to 「好」) replaces the old one at once, even inside the bubble's move.
            .contentTransition(.identity)
            .lineLimit(wraps ? nil : 1)
            .fixedSize(horizontal: !wraps, vertical: true)
    }

    private func solidButton(wraps: Bool) -> some View {
        Button(action: solid) { title(solidTitle, wraps: wraps).opacity(solidTitleOpacity) }
            .buttonStyle(TourNoteSolidButtonStyle(fillsWidth: wraps))
            .accessibilityIdentifier(solidID)
            .accessibilitySortPriority(2)
    }

    private func quietButton(_ words: String, wraps: Bool) -> some View {
        Button(action: quiet) { title(words, wraps: wraps) }
            .buttonStyle(TourNoteQuietButtonStyle(alignment: wraps ? .center : .leading, fillsWidth: wraps))
            .accessibilityIdentifier(quietID)
            .accessibilitySortPriority(1)
    }
}

/// The note Bella leaves beside a control (VISUAL §2.3–2.5, §8.3): portrait, name and progress dots,
/// her line, then 【跳过这一段】 on the left and 【下一步】 on the right, on `sheet` paper with a tail
/// pointing at the cutout.
///
/// Every string comes from the caller, already localised. The bubble is as wide as it is offered,
/// up to 340 (360 on iPad): give it 16 pt of margin on iPhone. Place it across the screen with
/// `TourNoteMetrics.bubbleX(width:screenWidth:window:)`, which moves it towards a control near the
/// edge when the tail could not otherwise reach the middle half of the cutout, and so that the tip of
/// the tail is 6 pt from the cutout's line; `TourNoteBubbleShape.tip(in:tail:)` says where the tip is.
///
/// At accessibility text sizes the portrait hides and the buttons stack. Pass `maxHeight` (70 % of
/// the screen, `TourNoteMetrics.tallestShare`): words that still do not fit scroll inside the bubble,
/// fading at the edge where they are cut.
///
/// Motion: insert and remove it with `.transition(.tourNote(tail:reduceMotion:))`. For the next step,
/// give it the new line, tail and button word and move it with `TourNoteMotion.stepMove`, all in one
/// update: the old words fade out (0.12 s) with the tail still on the old control, then the bubble
/// travels and takes its new height and tail (0.35 s); 0.15 s into the move the new words fade in
/// (0.18 s) and the button takes its new word in the same frame. The buttons never fade and take taps throughout. Under Reduce Motion the
/// words change at once, and the host cross-fades the old and new bubbles instead of moving one.
struct TourNoteBubble: View {
    struct Progress: Equatable, Sendable {
        /// 1-based.
        var step: Int
        var count: Int
    }

    private struct Words: Equatable {
        var line: String
        var note: String?
    }

    /// What the host asks for; the bubble shows it once the old words have faded.
    private struct Asked: Equatable {
        var words: Words
        var tail: TourNoteBubbleShape.Tail?
        var next: String
    }

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let speaker: String
    private let portrait: Image?
    private let words: Words
    private let progress: Progress?
    private let tail: TourNoteBubbleShape.Tail?
    private let maxHeight: CGFloat?
    private let skipTitle: String
    private let nextTitle: String
    private let skip: () -> Void
    private let next: () -> Void

    @State private var shown: Words
    /// The tail on screen. It follows `tail` at once unless the words change too: then it keeps
    /// pointing at the old control until the bubble leaves it.
    @State private var shownTail: TourNoteBubbleShape.Tail?
    @State private var wordsOpacity = 1.0
    /// The solid button's word on screen: it changes with the words, once the old ones have gone.
    @State private var shownNext: String
    @State private var nextOpacity = 1.0

    /// - Parameters:
    ///   - speaker: the name beside the portrait: 「Bella」.
    ///   - portrait: Bella's head for this step (`BellaHead.waiting.image`); nil shows `BellaHead.default`.
    ///   - line: at most 36 Chinese characters or 90 English ones.
    ///   - note: an optional smaller sentence under the line, in `note` ink.
    ///   - progress: this chapter's step; nil hides the dots.
    ///   - tail: nil for a step with no cutout.
    ///   - nextTitle: 「下一步」, or the chapter's closing word on its last step.
    init(speaker: String, portrait: Image? = nil, line: String, note: String? = nil, progress: Progress? = nil,
         tail: TourNoteBubbleShape.Tail? = nil, maxHeight: CGFloat? = nil, skipTitle: String, nextTitle: String,
         skip: @escaping () -> Void, next: @escaping () -> Void) {
        self.speaker = speaker
        self.portrait = portrait
        words = Words(line: line, note: note)
        self.progress = progress
        self.tail = tail
        self.maxHeight = maxHeight
        self.skipTitle = skipTitle
        self.nextTitle = nextTitle
        self.skip = skip
        self.next = next
        _shown = State(initialValue: Words(line: line, note: note))
        _shownTail = State(initialValue: tail)
        _shownNext = State(initialValue: nextTitle)
    }

    var body: some View {
        let shape = TourNoteBubbleShape(tail: shownTail, cornerRadius: RoomPaper.cardCorner)
        let shadow = TourNoteMetrics.bubbleShadow
        VStack(alignment: .leading, spacing: 10) {
            signature
            lines
            TourNoteButtonRow(quietTitle: skipTitle, solidTitle: shownNext, quiet: skip, solid: next,
                              solidTitleOpacity: nextOpacity)
        }
        .padding(TourNoteMetrics.bubblePadding)
        .padding(shownTail.map { Edge.Set($0.edge) } ?? [], TourNoteMetrics.tailHeight)
        .frame(maxWidth: TourNoteMetrics.bubbleMaxWidth(regular: widthClass == .regular))
        .tourNoteHeight(atMost: maxHeight)
        .background {
            shape.fill(RoomPaper.sheet)
                .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
        }
        .overlay { shape.stroke(RoomPaper.edge, lineWidth: 1) }
        // One piece for the host's move: without this the paper, the words and the buttons each
        // follow whichever animation last touched them and drift apart on the way.
        .geometryGroup()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tour-bubble")
        .task(id: Asked(words: words, tail: tail, next: nextTitle)) { await change(to: words, tail: tail) }
    }

    private var signature: some View {
        HStack(spacing: 10) {
            if !typeSize.isAccessibilitySize {
                TourNotePortrait(image: portrait, name: speaker)
            }
            Text(verbatim: speaker)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(RoomPaper.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            if let progress {
                TourNoteDots(step: progress.step, count: progress.count)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: speaker))
        .accessibilityValue(progress.map { Text("第 \(min($0.step, $0.count)) 步，共 \($0.count) 步") } ?? Text(verbatim: ""))
        .accessibilitySortPriority(4)
    }

    private var lines: some View {
        let text = VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: shown.line)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(RoomPaper.ink)
                .accessibilityIdentifier("tour-words")
            if let note = shown.note {
                Text(verbatim: note)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(RoomPaper.note)
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        return TourNoteWords(sample: shown.line) { text }
            .opacity(wordsOpacity)
            .accessibilitySortPriority(3)
    }

    private func change(to new: Words, tail: TourNoteBubbleShape.Tail?) async {
        guard new != shown else {
            shown = new
            shownTail = tail
            shownNext = nextTitle
            wordsOpacity = 1
            nextOpacity = 1
            return
        }
        if reduceMotion {
            // The paper stays, opaque: the old words out, then the new in, never two at once
            // (VISUAL §19.3 item 5). Nothing moves with them.
            withAnimation(TourNoteMotion.reducedOut) { wordsOpacity = 0; nextOpacity = 0 }
            do { try await Task.sleep(for: .seconds(TourNoteMotion.fadesOut)) } catch { return }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                shown = new
                shownTail = tail
                shownNext = nextTitle
            }
            withAnimation(TourNoteMotion.reduced) { wordsOpacity = 1; nextOpacity = 1 }
            return
        }
        // Eased both ways: eased out, the old words were mostly gone by the first frame and read as
        // vanishing (VISUAL §17.11.2).
        withAnimation(.easeInOut(duration: TourNoteMotion.wordsOut)) { wordsOpacity = 0 }
        do { try await Task.sleep(for: .seconds(TourNoteMotion.wordsOut)) } catch { return }
        withAnimation(TourNoteMotion.move) {
            shown = new
            shownTail = tail
        }
        do { try await Task.sleep(for: .seconds(TourNoteMotion.wordsInAfterMove)) } catch { return }
        // The button's word changes with the new words, not with the step (VISUAL §17.11.3 ①),
        // and comes in as they do: set at once it showed a frame before the words could be seen
        // (QA_T5 suggestion 1).
        if shownNext != nextTitle {
            nextOpacity = 0
            shownNext = nextTitle
        }
        withAnimation(.easeOut(duration: TourNoteMotion.wordsIn)) {
            wordsOpacity = 1
            nextOpacity = 1
        }
    }
}

#if DEBUG
#Preview("Bubble, tail below") {
    TourNoteBubble(speaker: "Bella", line: "The furniture in your photo moves in too. Photos stay on this iPhone; nothing is uploaded.",
               progress: .init(step: 2, count: 4), tail: .init(edge: .bottom, offset: 280),
               skipTitle: "Skip this part", nextTitle: "Next", skip: {}, next: {})
        .padding(TourNoteMetrics.bubbleMargin)
        .frame(maxHeight: .infinity)
        .background(RoomPaper.leaf)
}

#Preview("Bubble, four tails") {
    ScrollView {
        VStack(spacing: 20) {
            ForEach([Edge.top, .bottom, .leading, .trailing], id: \.self) { edge in
                TourNoteBubble(speaker: "Bella", line: "Tap here and pick a photo.", note: "Only the photos you pick are read.",
                           progress: .init(step: 3, count: 7), tail: .init(edge: edge, offset: 60),
                           skipTitle: "Skip this part", nextTitle: "Next", skip: {}, next: {})
            }
        }
        .padding(TourNoteMetrics.bubbleMargin)
    }
    .background(RoomPaper.leaf)
}

#Preview("Bubble, AX3, 70 %") {
    GeometryReader { proxy in
        TourNoteBubble(speaker: "Bella", line: "The furniture in your photo moves in too. Photos stay on this iPhone; nothing is uploaded.",
                   progress: .init(step: 1, count: 3), tail: .init(edge: .top, offset: 40),
                   maxHeight: proxy.size.height * TourNoteMetrics.tallestShare,
                   skipTitle: "Skip this part", nextTitle: "Next", skip: {}, next: {})
            .padding(TourNoteMetrics.bubbleMargin)
    }
    .background(RoomPaper.leaf)
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
