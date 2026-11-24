import SwiftUI

/// The window the mask opens over one control (VISUAL §2.2): the control's frame plus padding, at
/// least 44 × 44, with a corner taken from the control's own shape.
nonisolated struct TourNoteCutout: Equatable, Sendable {
    /// What the control looks like.
    enum Form: Equatable, Sendable {
        /// A round paper token (设置, 分享): a circle.
        case circle
        /// A control on its own paper with this corner: a bookplate or the title plate (14), a
        /// card or a row's card (18). The window's corner is this plus the padding.
        case plate(corner: CGFloat)
        /// An icon over a label with no plate of its own (主题, 互动, 添加照片): corner 12.
        case labelled
    }

    /// The window, in the mask's coordinate space.
    var rect: CGRect
    var cornerRadius: CGFloat

    init(rect: CGRect, cornerRadius: CGFloat) {
        self.rect = rect
        self.cornerRadius = cornerRadius
    }

    /// - Parameters:
    ///   - target: the control's visible outline, in the mask's coordinate space.
    ///   - padding: 6, or `TourNoteMetrics.cutoutTightPadding` when another control is within 12 pt.
    init(around target: CGRect, form: Form, padding: CGFloat = TourNoteMetrics.cutoutPadding) {
        let least = TourNoteMetrics.cutoutMinSize
        switch form {
        case .circle:
            let side = max(max(target.width, target.height) + 2 * padding, least)
            rect = CGRect(x: target.midX - side / 2, y: target.midY - side / 2, width: side, height: side)
            cornerRadius = side / 2
        case .plate, .labelled:
            let width = max(target.width + 2 * padding, least)
            let height = max(target.height + 2 * padding, least)
            rect = CGRect(x: target.midX - width / 2, y: target.midY - height / 2, width: width, height: height)
            if case .plate(let corner) = form {
                cornerRadius = corner + padding
            } else {
                cornerRadius = TourNoteMetrics.cutoutLabelledCorner
            }
        }
    }

    /// The window's outline. `scale` grows or shrinks it about its centre, for opening and closing.
    /// Also for a host that draws the hole itself (`path.cgPath` into a `CAShapeLayer`).
    func path(scale: CGFloat = 1) -> Path {
        let width = rect.width * scale, height = rect.height * scale
        let window = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        let limit = min(width, height) / 2
        let corner = min(cornerRadius * scale, limit)
        // A circle or a capsule is drawn with true arcs; other corners match the app's paper.
        return Path(roundedRect: window, cornerRadius: corner, style: corner >= limit - 0.01 ? .circular : .continuous)
    }

    typealias Animated = AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>>

    var animated: Animated {
        get { Animated(.init(rect.minX, rect.minY), .init(.init(rect.width, rect.height), cornerRadius)) }
        set {
            rect = CGRect(x: newValue.first.first, y: newValue.first.second,
                          width: newValue.second.first.first, height: newValue.second.first.second)
            cornerRadius = newValue.second.second
        }
    }
}

/// The mask as one path: the whole rect with the cutout cut out of it, so it fills the same under
/// either fill rule (a SwiftUI shadow ignores even-odd). The cutout's position, size and corner
/// animate together.
nonisolated struct TourNoteMaskShape: Shape {
    /// nil for a step with no control: no hole.
    var cutout: TourNoteCutout?
    var scale: CGFloat = 1

    var animatableData: AnimatablePair<TourNoteCutout.Animated, CGFloat> {
        get { .init(cutout?.animated ?? .zero, scale) }
        set {
            cutout?.animated = newValue.first
            scale = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard let cutout else { return Path(rect) }
        return Path(rect).subtracting(cutout.path(scale: scale))
    }
}

/// The cutout alone: the line around it, the glow and the shadow inside it.
nonisolated struct TourNoteCutoutShape: Shape {
    var cutout: TourNoteCutout
    var scale: CGFloat = 1

    var animatableData: AnimatablePair<TourNoteCutout.Animated, CGFloat> {
        get { .init(cutout.animated, scale) }
        set {
            cutout.animated = newValue.first
            scale = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path { cutout.path(scale: scale) }
}

/// The tour's mask (VISUAL §2.1–2.2, owner's choice A): a sheet of dark walnut card laid over the
/// page, with a hard-edged window over one control. The window has a 1.5 pt cream line on its edge
/// and the card's shadow falling into it. No blur, no material, no words on the mask.
///
/// Lay it over the whole screen, status bar and home indicator included (`.ignoresSafeArea()`), and
/// give the cutout in the mask's own coordinates. It is hidden from accessibility. Hit-testing is the
/// host's: nothing here passes or swallows touches on purpose.
///
/// With Increase Contrast the bright mask is 70 % and the line 2.5 pt.
///
/// Motion: on appearing it fades in over 0.25 s while the window opens from 0.92 to full size
/// (0.35 s spring, bounce 0.1) and the line thickens to twice its width and settles, once, in 0.8 s.
/// A window that comes where there was none (after the chapter card) opens the same way, in place.
/// A new `cutout` moves only as the caller's transaction says: change it inside
/// `withAnimation(TourNoteMotion.stepMove)` for a step's move, and with animations disabled to
/// follow a control frame by frame. The hole, its line and its shadow are one shape at every frame.
/// Turn
/// `isShown` off to leave: the window opens outwards while the mask fades over 0.3 s, or, with
/// `closesOnLeave` (its control opened a panel or a page over it), closes in 0.15 s: it shrinks to
/// 0.92 while the mask fills it in; its line, shadow and light go at once, so nothing of them is
/// left on the panel. Remove the
/// view after `TourNoteMotion.maskOutDuration`. Under Reduce Motion each of these is a 0.2 s fade: the
/// window never scales or travels, and the line does not change. A new window there: `windowShut`
/// fades the old one out (0.15 s) with the mask staying whole, the host gives the new cutout, and it
/// fades in (VISUAL §19.4).
struct TourNoteMask: View {
    /// What is under the mask, which is not always the system colour scheme: the room page follows
    /// the room's light, so a daytime room is bright in dark mode too.
    enum Base {
        /// A daytime room, and light-mode panels and pages: #29231F at 56 %.
        case bright
        /// A night room, and dark-mode panels and pages: #120E0B at 62 %, and the window is lit
        /// with 8 % cream so a dark control still stands out.
        case dim
    }

    enum Strength {
        case full
        /// Behind a chapter card, lighter than `full` so the room and the cat stay readable: 30 % on a
        /// bright page, 45 % on a dim one.
        case card
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    let base: Base
    var cutout: TourNoteCutout?
    var strength: Strength = .full
    var isShown = true
    var closesOnLeave = false
    /// The window is shut while the mask stays (VISUAL §18.2 item 5): the list under it scrolls to
    /// the next step's row. It shuts as on `closesOnLeave`, and opens again in place, on the new
    /// cutout, when this turns off.
    var windowShut = false
    /// The window could not be seen as it shut (7.2's, the mask faded for the pinch): under Reduce
    /// Motion it shuts at once, or it would come back with the mask only to fade.
    var windowUnseen = false
    /// Under Reduce Motion, one more for each window swapped in while shut: its line and shadow are
    /// new views, or the ones fading out would come back and travel to the new cutout.
    var windowGeneration = 0

    @State private var lit = false
    @State private var windowScale: CGFloat = 0.92
    @State private var pulse = 0
    @State private var opening = 0
    /// 1 while the window is open; 0 once it has been filled in on leaving.
    @State private var windowOpen: Double = 1
    /// The window's line, shadow and light. On a close they go in the frame of the tap, not with
    /// the fade: the panel rises faster than 0.15 s, and a fading line was left on its rows for four
    /// frames (VISUAL §14.1 item 2).
    @State private var decorated = true

    private var opacity: Double {
        switch (base, strength) {
        case (.bright, .full): contrast == .increased ? 0.70 : 0.56
        case (.bright, .card): 0.30
        case (.dim, .full): 0.62
        // Dark card on a dark page: at 31 % the page behind still looked live (VISUAL §10.1).
        case (.dim, .card): 0.45
        }
    }

    private var lineWidth: CGFloat {
        contrast == .increased ? TourNoteMetrics.cutoutLineIncreasedContrast : TourNoteMetrics.cutoutLine
    }

    var body: some View {
        layers
            // Under Reduce Motion one view throughout: a new one would begin with its window open,
            // and fade the whole mask in again.
            .id(reduceMotion || cutout == nil ? "mask" : "window")
            .transition(.opacity)
            // No implicit animation on `cutout`: it used to animate a new window out of the zero rect
            // a missing one stands for (the hole flew in from the top left while its line was
            // already in place), and it put a delayed spring on every frame of following the cat,
            // so a follow that began mid-move stalled the window short of her (VISUAL §12.3).
            .opacity(lit ? 1 : 0)
            .accessibilityHidden(true)
            .onAppear { if isShown { show(true) } }
            .onChange(of: isShown) { _, shown in show(shown) }
            .onChange(of: cutout == nil) { hadNone, hasNone in
                // A window where there was none, with the mask already up: it opens in place.
                if hadNone, !hasNone, lit, isShown { open() }
            }
            .onChange(of: windowShut) { _, shut in shutWindow(shut) }
            .task(id: opening) {
                guard opening > 0 else { return }
                // The 0.92 has been drawn; now open from it.
                withAnimation(TourNoteMotion.move) { windowScale = 1 }
                pulse += 1
            }
    }

    private func shutWindow(_ shut: Bool) {
        var still = Transaction()
        still.disablesAnimations = true
        if reduceMotion {
            // Out, with the old bubble, before the list jumps; in, with the new one (VISUAL §19.4).
            // On leaving it stays shut: it would come back while the mask fades.
            guard shut || isShown else { return }
            withAnimation(!shut ? TourNoteMotion.reduced : windowUnseen ? nil : TourNoteMotion.reducedOut) {
                decorated = !shut
                windowOpen = shut ? 0 : 1
            }
        } else if shut {
            withTransaction(still) { decorated = false }
            withAnimation(TourNoteMotion.windowClose) {
                windowScale = 0.92
                windowOpen = 0
            }
        } else {
            withTransaction(still) {
                windowOpen = 1
                decorated = true
            }
            if lit, isShown { open() } else { windowScale = 1 }
        }
    }

    private func open() {
        guard !reduceMotion else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { windowScale = 0.92 }
        opening += 1
    }

    private var layers: some View {
        ZStack {
            let ink = base == .bright ? TourNoteInk.maskOnBright : TourNoteInk.maskOnDim
            TourNoteMaskShape(cutout: cutout, scale: windowScale)
                .fill(ink.opacity(opacity))
            if let cutout {
                let window = TourNoteCutoutShape(cutout: cutout, scale: windowScale)
                // Fills the window in as it closes on leaving.
                window.fill(ink.opacity(opacity))
                    .opacity(1 - windowOpen)
                if reduceMotion {
                    // Only their opacity animates. Not keyed on the rect: the window follows its control.
                    ZStack {
                        decorations(cutout, window: window)
                            .id(windowGeneration)
                            .transition(.identity)
                    }
                    .opacity(decorated ? 1 : 0)
                } else if decorated {
                    decorations(cutout, window: window)
                }
            }
        }
    }

    @ViewBuilder
    private func decorations(_ cutout: TourNoteCutout, window: TourNoteCutoutShape) -> some View {
        ZStack {
                if base == .dim {
                    window.fill(TourNoteInk.cutoutLine.opacity(0.08))
                }
                // The card's shadow, kept only where it falls into the window.
                let shadow = TourNoteMetrics.cutoutShadow
                TourNoteMaskShape(cutout: cutout, scale: windowScale)
                    .fill(.black)
                    .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
                    .mask { window.fill(.black) }
                let line = TourNoteInk.cutoutLine
                let rest = lineWidth
                let timing = TourNoteMotion.linePulse
                Color.clear
                    .keyframeAnimator(initialValue: rest, trigger: pulse) { _, width in
                        window.stroke(line, lineWidth: width)
                    } keyframes: { _ in
                        KeyframeTrack {
                            CubicKeyframe(rest * 2, duration: timing.rise)
                            CubicKeyframe(rest, duration: timing.settle)
                        }
                    }
        }
    }

    private func show(_ shown: Bool) {
        if reduceMotion {
            windowScale = 1
            if shown {
                windowOpen = windowShut ? 0 : 1
                decorated = !windowShut
            }
            withAnimation(TourNoteMotion.reduced) { lit = shown }
        } else if shown {
            windowOpen = 1
            decorated = true
            withAnimation(TourNoteMotion.maskIn) { lit = true }
            withAnimation(TourNoteMotion.move) { windowScale = 1 }
            pulse += 1
        } else if closesOnLeave {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { decorated = false }
            withAnimation(TourNoteMotion.windowClose) {
                windowScale = 0.92
                windowOpen = 0
            }
            withAnimation(TourNoteMotion.maskOut) { lit = false } completion: {
                if !isShown {
                    windowOpen = 1
                    decorated = true
                }
            }
        } else {
            withAnimation(TourNoteMotion.maskOut) {
                lit = false
                windowScale = 1.12
            } completion: {
                // Ready to open from small again if the same mask is shown once more.
                if !isShown { windowScale = 0.92 }
            }
        }
    }
}

#if DEBUG
#Preview("Mask, bright and dim") {
    VStack(spacing: 0) {
        ForEach([TourNoteMask.Base.bright, .dim], id: \.self) { base in
            ZStack {
                (base == .bright ? Color(red: 0.96, green: 0.93, blue: 0.87) : RoomPaper.leaf)
                RoomRoundToken(glyph: .symbol("gearshape"))
                GeometryReader { proxy in
                    let middle = CGRect(x: proxy.size.width / 2 - 22, y: proxy.size.height / 2 - 22, width: 44, height: 44)
                    TourNoteMask(base: base, cutout: TourNoteCutout(around: middle, form: .circle))
                }
            }
            .environment(\.colorScheme, base == .bright ? .light : .dark)
        }
    }
    .ignoresSafeArea()
}

#Preview("Mask, window forms") {
    ZStack {
        Color(red: 0.96, green: 0.93, blue: 0.87)
        TourNoteMask(base: .bright, cutout: TourNoteCutout(around: CGRect(x: 60, y: 300, width: 154, height: 44),
                                                   form: .plate(corner: RoomPaper.bookplateCorner)))
    }
    .ignoresSafeArea()
}
#endif
