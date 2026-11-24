import MeowverseCore
import SwiftUI
import UIKit

// The tour's own window (docs/onboarding/TECH_DESIGN.md §3, route A): above the main window's
// sheets, popovers and full-screen pages, below alerts and the transient notice. It never
// becomes the key window and hands touches to the main window by geometry. Every frame it
// measures where the step's control is and whether it may be shown (§3.5).

/// What the overlay shows, as the coordinator asks for it.
enum TourOverlayScene: Equatable {
    struct Key: Equatable {
        var run: TourRunID
        var card: Bool
        var step: String
    }

    case nothing
    /// `firstChapter`: chapter 1's card, whose quiet button is 「全部跳过」.
    /// `startTitle`: 「开始」, or 「知道了」 on a card with nothing after it.
    case card(key: Key, title: String, line: String, art: TourArt, firstChapter: Bool, startTitle: String, placeholder: Bool)
    case step(key: Key, step: TourStep, number: Int, count: Int, nextTitle: String)

    var key: Key? {
        switch self {
        case .nothing: nil
        case .card(let key, _, _, _, _, _, _), .step(let key, _, _, _, _): key
        }
    }

    var target: TourTarget {
        if case .step(_, let step, _, _, _) = self { return step.target }
        return .none
    }

    var step: TourStep? {
        if case .step(_, let step, _, _, _) = self { return step }
        return nil
    }
}

final class TourOverlayWindow: UIWindow {
    let controller: TourOverlayController
    private var lastTouch: TimeInterval = -1

    init(windowScene: UIWindowScene, coordinator: TourCoordinator, main: UIWindow) {
        controller = TourOverlayController(coordinator: coordinator, main: main)
        super.init(windowScene: windowScene)
        windowLevel = .normal + 1
        backgroundColor = .clear
        rootViewController = controller
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var canBecomeKey: Bool { false }

    override var isHidden: Bool {
        didSet { controller.setRunning(!isHidden) }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard controller.isShowing else { return nil }
        if controller.paperFrame.contains(point) { return super.hitTest(point, with: event) ?? controller.view }
        // UIKit asks more than once per touch; count each touch once.
        let fresh = event.map { $0.timestamp != lastTouch } ?? true
        lastTouch = event?.timestamp ?? -1
        if controller.letsThrough(point) {
            if fresh { controller.passed += 1 }
            return nil
        }
        if fresh { controller.swallowed += 1 }
        return controller.view
    }
}

/// Where the bubble sits: against the top or the bottom of the screen, `inset` from that edge.
struct TourBubblePlacement: Equatable {
    var fromTop = true
    var inset: CGFloat = 0
    var x: CGFloat = TourNoteMetrics.bubbleMargin
    var width: CGFloat = 340
    var tail: TourNoteBubbleShape.Tail?
    /// The bubble is above its control (Bella may look down at it).
    var above = false
    /// The room the bubble has on its side of the window: 70 % of the screen at most, and never
    /// past the window or the screen's edge (QA_T2 F3). Longer words scroll inside it.
    var maxHeight: CGFloat = 0
}

@MainActor @Observable
final class TourOverlayModel {
    var scene: TourOverlayScene = .nothing
    var shown = false
    var cutout: TourNoteCutout?
    var base: TourNoteMask.Base = .bright
    var placement = TourBubblePlacement()
    /// The window closes on leaving instead of opening outwards: its control opened something over it.
    var closesWindow = false
    /// 7.2: the mask and the window have faded for the pinch; the bubble stays (VISUAL §17.6).
    var maskFaded = false
    /// The window is shut, the mask and the bubble stay: the list scrolls to the next row (§18.2 item 5).
    var windowShut = false
    /// It shut while the mask was faded (`maskFaded`): there was nothing of it to fade.
    var windowUnseen = false
    /// Bumped with a cutout given while the window is shut or unseen (`TourNoteMask.windowGeneration`).
    var windowGeneration = 0
    /// The mask stays and the paper is away: between a chapter card and a first step that waits for
    /// its list (§18.2 item 3).
    var paperHidden = false
    /// A new value is a new bubble, made with its words already in (no word change inside it).
    /// Bumped only while the paper is faded out (`paperOpacity`).
    var bubbleGeneration = 0
    /// The paper fades out where it is and in at its next place: after a list scrolled to the next
    /// step's row (11.1 to 11.2) the bubble changes the edge it hangs from, which SwiftUI does not
    /// animate: it jumped some 64 pt in one frame, over a window already open (VISUAL §18.4).
    var paperOpacity = 1.0
    @ObservationIgnored var paperFrame = CGRect.null
    @ObservationIgnored var next: () -> Void = {}
    @ObservationIgnored var skip: () -> Void = {}
    @ObservationIgnored var skipAll: () -> Void = {}
}

struct TourOverlayContent: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: TourOverlayModel

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                TourNoteMask(base: model.base, cutout: model.cutout, strength: isCard ? .card : .full, isShown: model.shown,
                             closesOnLeave: model.closesWindow, windowShut: model.windowShut, windowUnseen: model.windowUnseen,
                             windowGeneration: model.windowGeneration)
                    .opacity(model.maskFaded ? 0 : 1)
                    .animation(.easeOut(duration: 0.2), value: model.maskFaded)
                if model.shown, !model.paperHidden { paper(height: proxy.size.height).opacity(model.paperOpacity) }
            }
        }
        .ignoresSafeArea()
    }

    private var isCard: Bool {
        if case .card = model.scene { return true }
        return false
    }

    @ViewBuilder
    private func paper(height: CGFloat) -> some View {
        switch model.scene {
        case .nothing:
            EmptyView()
        case .card(_, let title, let line, let art, let first, let startTitle, let placeholder):
            let skipAll = TourChapterCard.Exit(title: TourText.skipAll, action: model.skipAll)
            TourChapterCard(speaker: TourText.speaker, illustration: art.body, title: title, line: line,
                            maxHeight: height * TourNoteMetrics.tallestShare,
                            later: placeholder ? nil : first ? skipAll : TourChapterCard.Exit(title: TourText.skip, action: model.skip),
                            start: TourChapterCard.Exit(title: startTitle, action: model.next),
                            skipAll: first || placeholder ? nil : skipAll)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { model.paperFrame = $0 }
                .padding(.horizontal, TourNoteMetrics.bubbleMargin)
                // A little below the middle (VISUAL §4).
                .offset(y: height * 0.06)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id("card")
                .transition(.tourNote(tail: nil, reduceMotion: reduceMotion))
        case .step(_, let step, let number, let count, let nextTitle):
            let place = model.placement
            TourNoteBubble(speaker: TourText.speaker, portrait: step.art.head(bubbleAbove: place.above), line: step.line,
                           progress: .init(step: number, count: count), tail: place.tail,
                           maxHeight: place.maxHeight > 0 ? place.maxHeight : height * TourNoteMetrics.tallestShare,
                           skipTitle: TourText.skip, nextTitle: nextTitle, skip: model.skip, next: model.next)
                .frame(width: place.width)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { model.paperFrame = $0 }
                .padding(.leading, place.x)
                .padding(place.fromTop ? .top : .bottom, place.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: place.fromTop ? .topLeading : .bottomLeading)
                // A new one only while the paper is faded out: under Reduce Motion, when its place
                // changes (it never travels); in the same place it is the one paper (§19.3 item 5).
                .id("bubble-\(model.bubbleGeneration)")
                .transition(.tourNote(tail: place.tail?.edge, reduceMotion: reduceMotion))
        }
    }
}

final class TourOverlayController: UIViewController {
    private weak var coordinator: TourCoordinator?
    private weak var main: UIWindow?
    let model = TourOverlayModel()
    private var host: UIHostingController<TourOverlayContent>?
    private var link: CADisplayLink?

    private(set) var isShowing = false
    var paperFrame: CGRect { model.paperFrame }
    var passed = 0
    var swallowed = 0

    private var key: TourOverlayScene.Key?
    private var showableSince: CFTimeInterval?
    private var hiddenSince: CFTimeInterval?
    private var stepChangedAt: CFTimeInterval = 0
    /// Since when the next step's window could not be measured while this one stays up.
    private var nextUnmeasuredSince: CFTimeInterval?
    /// A step's window on its way from the old control to the new one.
    private struct Flight {
        var from: TourNoteCutout
        var start: CFTimeInterval
    }
    /// Flown here frame by frame, towards where the control is at that frame, rather than given
    /// to SwiftUI as one animation: a control that moves meanwhile (the cat walks) made SwiftUI
    /// merge a new spring into the delayed one each frame, and the window stalled part-way and then
    /// jumped (VISUAL §12.3). The hole, its line and its shadow read the one value.
    private var flight: Flight?
    private var lastMove: CFTimeInterval = 0
    /// The window the bubble was last placed against.
    private var placedFor = CGRect.null
    /// A docked bubble keeps its place for the whole step; only its tail follows the window.
    private var docked: TourBubblePlacement?
    /// Chapter 7: where this step's bubble was put, kept for the whole step (VISUAL §17.10.2).
    private var gestureKept: (place: TourBubblePlacement, stageTop: CGFloat?)?
    /// The cat's round window is measured once per step; then only its centre follows her.
    private var catDiameter: CGFloat?
    /// 7.2: the stage window's top, lowered for a bubble under the top bar (VISUAL §17.6, step 3).
    private var stageTop: CGFloat?
    /// DEBUG: the last measured whole height of a chapter 7 bubble, for the probe.
    private var measuredWhole: CGFloat = 0
    private var measuredLeast: CGFloat = 0
    /// The floor's back corner for the stage window, from the last reading.
    private var floorTop: CGFloat?
    private let sizer = TourBubbleSizer()
    private var why = "start"
    #if DEBUG
    private var lastTick: CFTimeInterval?
    #endif
    // A "do" step.
    private var passedAtStep = 0
    private var nextSeenDuringStep = false
    private var nextFrames = 0
    #if DEBUG
    private let status = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
    private var lastStatus = ""
    private var frames = 0
    #endif

    init(coordinator: TourCoordinator, main: UIWindow) {
        self.coordinator = coordinator
        self.main = main
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        model.next = { [weak self] in self?.coordinator?.next() }
        model.skip = { [weak self] in self?.coordinator?.skip() }
        model.skipAll = { [weak self] in self?.coordinator?.skipAll() }
        let host = UIHostingController(rootView: TourOverlayContent(model: model))
        host.view.backgroundColor = .clear
        // Window coordinates throughout: the placement already allows for the safe area.
        host.safeAreaRegions = []
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        self.host = host
        #if DEBUG
        status.isAccessibilityElement = true
        status.accessibilityIdentifier = "tour-status"
        status.accessibilityLabel = "tour-status"
        view.addSubview(status)
        #endif
    }

    func setRunning(_ running: Bool) {
        if running, link == nil {
            loadViewIfNeeded()
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !running {
            link?.invalidate()
            link = nil
        }
    }

    func letsThrough(_ point: CGPoint) -> Bool {
        // Only the window of the step that is up, open and arrived: from 【下一步】 until then the
        // old one, shut or on its way, lets nothing through (QA S-1: the cat was sent by such a tap).
        guard let coordinator, coordinator.overlayScene.key == model.scene.key,
              !model.windowShut, flight == nil,
              let step = model.scene.step, let cutout = model.cutout else { return false }
        let inWindow = UIBezierPath(roundedRect: cutout.rect, cornerRadius: cutout.cornerRadius).contains(point)
        if step.does { return inWindow }
        // A look step may still let one control in its window take a tap (9.1: 「未放进家具」).
        guard inWindow, let id = step.passes, let main, let probe = TourAnchorRegistry.shared.probe(id, in: main),
              let rect = TourGeometry.rect(of: probe) else { return false }
        return rect.shown.contains(point)
    }

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }
    private var isPad: Bool { traitCollection.userInterfaceIdiom == .pad }

    // MARK: Every frame

    @objc private func tick() {
        guard let coordinator else { return }
        let now = CACurrentMediaTime()
        let scene = coordinator.overlayScene
        defer { writeStatus() }
        #if DEBUG
        // A frame the main thread missed: a stall in a move shows as a stop and then a jump.
        if let lastTick, now - lastTick > 0.1, isShowing {
            coordinator.log.notice("tour: hitch \(Int((now - lastTick) * 1000)) ms at \(self.key.map { String(describing: $0) } ?? "-", privacy: .public)")
        }
        lastTick = now
        #endif
        // The old window stays where it is until the new one has been measured (VISUAL §12.3).
        if scene.key != key, !change(to: scene, now: now) { return }
        if let swapAt, now >= swapAt {
            // The old bubble has faded: the new one is put at its place unseen and fades in there.
            self.swapAt = nil
            let reading = read(scene)
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                model.bubbleGeneration += 1
                model.scene = scene
                place(reading, scene: scene, now: now, animated: false)
            }
            withAnimation(.easeOut(duration: Self.bubbleFadesIn)) { model.paperOpacity = 1 }
        }
        if swapAt == nil, scene.key == key, scene != model.scene, case .step = scene, case .step = model.scene {
            // The same step with a different count or closing word: the chapter's steps changed
            // under it (9.1 after 「未放进家具」: 9.3 added, or 9.2 dropped when no photo is left;
            // QA_T5 must-fix 2). The bubble changes its dots and its button's word in place.
            model.scene = scene
        }
        if let reopensAt, now >= reopensAt {
            // The bubble has reached its new place: now the new window opens, beside it, never
            // under it (VISUAL §18.4). Under Reduce Motion the old window has faded out: the new
            // cutout is given while it is shut, and fades in.
            self.reopensAt = nil
            if reduceMotion {
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    model.cutout = read(scene).cutout
                    model.windowGeneration += 1
                }
            }
            model.windowShut = false
        }
        if let revealAt {
            // Under Reduce Motion, from a card: nothing new until the card has faded.
            guard now >= revealAt else { return }
            self.revealAt = nil
        }
        guard scene != .nothing else {
            if isShowing { setShown(false) }
            let since = hiddenSince ?? now
            hiddenSince = since
            if now - since > TourNoteMotion.maskOutDuration + 0.1 { coordinator.overlayIdle() }
            return
        }
        hiddenSince = nil
        let reading = read(scene)
        if model.paperHidden, isShowing {
            // After a card: the mask is held until the first step's row has come to rest.
            if reading.showable, fits(reading, scene: scene), reduceMotion {
                // The window and the bubble fade in together, the hole too (it was shut while the
                // card went; VISUAL §19.2 item 2).
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    place(reading, scene: scene, now: now)
                    model.windowGeneration += 1
                }
                model.windowShut = false
                withAnimation(TourNoteMotion.reduced) {
                    model.scene = scene
                    model.paperHidden = false
                }
            } else if reading.showable, fits(reading, scene: scene) {
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { place(reading, scene: scene, now: now) }
                withAnimation(TourNoteMotion.bubbleIn) { model.paperHidden = false }
            } else if !Self.waits(reading.why) || now - stepChangedAt > Self.scrollWait {
                model.paperHidden = false
                setShown(false)
            }
            why = reading.why
            return
        }
        let fades = coordinator.gestureFades
        if fades != model.maskFaded { model.maskFaded = fades }
        why = reading.why
        if reading.showable {
            if isShowing {
                track(reading, scene: scene, now: now)
            } else {
                // Entry waits until it has been showable for a quarter second (correction 5): the
                // mask once came back for 0.1 s between two transitions.
                let since = showableSince ?? now
                showableSince = since
                if now - since >= 0.25 {
                    guard place(reading, scene: scene, now: now) else { return squeeze(scene) }
                    setShown(true)
                }
            }
        } else {
            // Leaving is not delayed: the frame it may not show, it goes. When its control opened a
            // panel or a page over it (or anything else came over it), the window closes in 0.15 s
            // rather than opening outwards over what came (VISUAL §13.3 b).
            showableSince = nil
            if isShowing {
                model.closesWindow = ["transition", "covered", "covered-subview", "aside"].contains(reading.why)
                setShown(false)
            }
        }
        checkDoStep(scene, reading)
    }

    /// The scene's target as it is now, and whether the tour holds it back.
    private func read(_ scene: TourOverlayScene) -> Reading {
        var reading = evaluate(scene.target, anyLayer: showsOverAnyLayer(scene))
        if case .step(_, let step, let number, let count, let nextTitle) = scene, step.bubbleAbove, let id = step.alsoCovers,
           let hole = reading.cutout, !fitsAbove(step, number: number, count: count, nextTitle: nextTitle, hole: hole.rect),
           let main, let probe = TourAnchorRegistry.shared.probe(id, in: main), let footer = TourGeometry.rect(of: probe) {
            // No room above (SE, large text): the window takes in the footer too and the bubble goes
            // below, so it still does not sit on the footer (VISUAL §18.2 item 6).
            let padding = TourGeometry.rowPadding
            let grown = hole.rect.union(footer.shown.insetBy(dx: -padding, dy: -padding))
            reading.cutout = Self.onScreen(TourNoteCutout(rect: grown, cornerRadius: hole.cornerRadius),
                                           control: hole.rect, in: view.bounds)
        }
        guard let coordinator else { return reading }
        // 7.1: the piece is lifted; the window closes as it does when a panel comes over it.
        if coordinator.stepsAside {
            reading.showable = false
            reading.why = "aside"
        } else if coordinator.waitsForZoom {
            // The room is still easing back: the old window waits (`change`), then this one is
            // placed on the room as it settles.
            reading.showable = false
            reading.why = "zooming"
        } else if coordinator.waitsForScroll {
            // 11.2, 13.1, 14.2: the list is still bringing the row into view.
            reading.showable = false
            reading.why = "scrolling"
        }
        return reading
    }

    /// May this scene show over whatever is on top: a step that says so (12.3 关着, 12.4), and the
    /// card of a chapter that began on a page (chapter 12 on the company page, §3.2; chapters 9, 10,
    /// 11 and 13 on theirs). QA_T4 item 1: the card has no step, so it was read as `covered` there
    /// and never came.
    private func showsOverAnyLayer(_ scene: TourOverlayScene) -> Bool {
        if let step = scene.step { return step.anyLayer }
        if case .card = scene { return coordinator?.cardOverPage == true }
        return false
    }

    /// A new step or card. The new window and the new words come in the same update, never the
    /// old window with the new words (correction 4), and the layout is always redone.
    /// False while the old step's window stays up because the new one cannot be measured yet.
    @discardableResult
    private func change(to scene: TourOverlayScene, now: CFTimeInterval) -> Bool {
        // Measured before anything changes: the window moves once, to where it ends (§12.3).
        let oldDiameter = catDiameter
        catDiameter = nil
        if scene.step?.target != .scene(.stage) { stageTop = nil }
        let reading = scene == .nothing ? Reading() : read(scene)
        let fromCard: Bool = { if case .card = model.scene { return true } else { return false } }()
        if isShowing, fromCard, !reading.showable, Self.waits(reading.why), scene.step != nil {
            // From a card to a first step whose list is still scrolling (13 → 13.1): the card goes,
            // the mask stays, darker, with no window, until the row is at rest (§18.2 item 3).
            begin(scene, now: now)
            if reduceMotion { model.windowShut = true }
            withAnimation(reduceMotion ? TourNoteMotion.reduced : TourNoteMotion.bubbleOut) {
                model.paperHidden = true
                model.scene = scene
            }
            model.cutout = nil
            showableSince = nil
            return true
        }
        if reduceMotion, isShowing, model.scene.step != nil, scene.step != nil {
            let changed = fadeAcross(to: scene, reading, now: now)
            if !changed { catDiameter = oldDiameter }
            return changed
        }
        let scrolling = reading.why == "scrolling"
        if isShowing, !reading.showable || reading.estimated, model.scene.step != nil, scene.step != nil {
            // From one window to the next: wait on the old one rather than move to a guess (the
            // floor while the cat is not drawn yet), for up to `TourNoteMotion.measureWait`; then
            // leave, or go to the guess, as before.
            let since = nextUnmeasuredSince ?? now
            nextUnmeasuredSince = since
            // The probe says why the step has not changed yet (`zooming`: 7.3 waits for the room to
            // be set back), so a test can see it (QA_T4 r2 suggestion 2).
            why = reading.estimated ? "guess" : reading.why
            // While the list scrolls to the next row the old window shuts, so it does not frame
            // the rows sliding through it; the bubble keeps the old words (§18.2 item 5).
            if scrolling, !model.windowShut { model.windowShut = true }
            if now - since < (scrolling ? Self.scrollWait : TourNoteMotion.measureWait) {
                #if DEBUG
                if since == now {
                    coordinator?.log.notice("tour: waits on the old window, the next is \(reading.estimated ? "a guess" : reading.why, privacy: .public)")
                }
                #endif
                catDiameter = oldDiameter
                return false
            }
        }
        nextUnmeasuredSince = nil
        let reopens = model.windowShut
        begin(scene, now: now)
        if isShowing, reading.showable, fits(reading, scene: scene) {
            if fromCard, reduceMotion {
                // Under Reduce Motion the card goes first, 0.15 s, the mask staying and no window
                // in it; then the window and the bubble fade in together (`revealAt`, then the
                // paper-hidden reveal above). The window came at once and cut, lit, through the
                // card still fading (VISUAL §19.2 item 2).
                withAnimation(TourNoteMotion.bubbleOut) {
                    model.paperHidden = true
                    model.scene = scene
                }
                model.cutout = nil
                model.windowUnseen = false
                model.windowShut = true
                revealAt = now + TourNoteMotion.fadesOut
            } else if fromCard {
                // From a card: the bubble is placed where it ends before it comes, and comes in
                // there (8 pt and a fade), not from where the last bubble was (§18.2 item 4).
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { place(reading, scene: scene, now: now) }
                withAnimation(TourNoteMotion.stepMove) { model.scene = scene }
            } else if reopens {
                // After the scroll, with the window still shut: the old bubble fades out where it
                // is, the new one fades in at its own place (`swapAt`), and only then does the new
                // window open in place on its row (`reopensAt`). The bubble never travels over the
                // rows, never jumps, and the window never opens under it (§18.2 item 5, §18.4).
                // (Under Reduce Motion: `fadeAcross`.)
                withAnimation(TourNoteMotion.bubbleOut) { model.paperOpacity = 0 }
                swapAt = now + TourNoteMotion.fadesOut
                reopensAt = now + TourNoteMotion.fadesOut + Self.bubbleFadesIn
            } else {
                let from = reduceMotion ? nil : model.cutout
                withAnimation(reduceMotion ? TourNoteMotion.reduced : TourNoteMotion.stepMove) {
                    model.scene = scene
                    place(reading, scene: scene, now: now, animated: true, keepsCutout: from != nil)
                }
                if let from, reading.cutout != nil { flight = Flight(from: from, start: now) }
            }
        } else {
            if reopens { model.windowShut = false }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { model.scene = scene }
            if isShowing { setShown(false) }
            showableSince = nil
        }
        return true
    }

    /// Under Reduce Motion, from one step to the next (VISUAL §19.3 items 4 and 5, §19.4): what is
    /// old fades out where it is, 0.15 s, the mask staying; a list jumps or the zoom is set back;
    /// what is new fades in, 0.2 s, the window and the bubble together. Nothing travels. A bubble
    /// that has the same place keeps its paper, and only its words go out and in; a window that is
    /// the same for both steps stays lit throughout (2.1 to 2.2 to 2.3).
    /// False while the old step is still on its way out.
    private func fadeAcross(to scene: TourOverlayScene, _ reading: Reading, now: CFTimeInterval) -> Bool {
        // A jumped list is not always laid out when it reports: its row reads off screen for a
        // frame. Left on that, the mask went and came back over the panel (recorded at 10 ms).
        let toRow = scene.step?.scrolls == true && !reading.showable
        let waiting = Self.waits(reading.why) || toRow
        // Decided as the step changes: is it the window already lit?
        if fadedSince == nil { windowStays = !model.windowShut && !model.maskFaded && isSameWindow(reading) }
        if waiting { windowStays = false }
        let gone = fadedSince ?? now
        fadedSince = gone
        if !windowStays, !model.windowShut {
            model.windowUnseen = model.maskFaded
            model.windowShut = true
        }
        why = reading.why
        if waiting {
            let since = nextUnmeasuredSince ?? now
            nextUnmeasuredSince = since
            if now - since < Self.scrollWait {
                // The row will be elsewhere, so will the bubble: it goes with its window. For the
                // zoom (7.3) it waits where it is.
                if toRow { fadePaperOut(now) }
                return false
            }
        }
        let canShow = reading.showable && fits(reading, scene: scene, fresh: true)
        if canShow, paperOutSince == nil, case .step(_, let step, let number, let count, let nextTitle) = scene {
            if let new = freshPlacement(for: step, number: number, count: count, nextTitle: nextTitle, reading: reading),
               Self.samePlace(new, model.placement) {
                // The paper stays: the words change in it (`TourNoteBubble.change`).
                begin(scene, now: now)
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    // The words first: placing measures and so draws at once, and a new tail with
                    // the old words is taken for the same words following their control.
                    model.scene = scene
                    place(reading, scene: scene, now: now, keepsCutout: true)
                }
                // A window that could not be seen has nothing to fade: the new one comes as the
                // mask darkens again (7.3, §19.3 item 5).
                if model.windowShut {
                    reopensAt = gone + (model.windowUnseen ? 1.0 / 60 : TourNoteMotion.fadesOut)
                }
                return true
            }
        }
        guard canShow else {
            // Not to be shown here: it leaves as before.
            begin(scene, now: now)
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { model.scene = scene }
            setShown(false)
            showableSince = nil
            return true
        }
        fadePaperOut(now)
        guard now >= max(gone, paperOutSince ?? now) + TourNoteMotion.fadesOut else { return false }
        begin(scene, now: now)
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            model.bubbleGeneration += 1
            model.scene = scene
            place(reading, scene: scene, now: now)
            if model.windowShut { model.windowGeneration += 1 }
        }
        model.windowShut = false
        withAnimation(TourNoteMotion.reduced) { model.paperOpacity = 1 }
        return true
    }

    private func fadePaperOut(_ now: CFTimeInterval) {
        guard paperOutSince == nil else { return }
        paperOutSince = now
        withAnimation(TourNoteMotion.reducedOut) { model.paperOpacity = 0 }
    }

    /// Where `step`'s bubble would go, leaving what is kept for the step on screen as it is.
    private func freshPlacement(for step: TourStep, number: Int, count: Int, nextTitle: String,
                                reading: Reading) -> TourBubblePlacement? {
        if step.target == .none { return centred(step, number: number, count: count, nextTitle: nextTitle) }
        guard let hole = reading.cutout?.rect else { return nil }
        let kept = (docked, gestureKept, stageTop)
        defer { (docked, gestureKept, stageTop) = kept }
        docked = nil
        gestureKept = nil
        return placement(for: step, number: number, count: count, nextTitle: nextTitle, around: hole)
    }

    private func isSameWindow(_ reading: Reading) -> Bool {
        guard reading.showable, let new = reading.cutout, let old = model.cutout else { return false }
        return !Self.differs(new.rect, old.rect, by: 1) && abs(new.cornerRadius - old.cornerRadius) <= 1
    }

    private static func samePlace(_ a: TourBubblePlacement, _ b: TourBubblePlacement) -> Bool {
        a.fromTop == b.fromTop && abs(a.x - b.x) < 1 && abs(a.inset - b.inset) < 1 && abs(a.width - b.width) < 1
    }

    /// The step's own state starts over.
    private func begin(_ scene: TourOverlayScene, now: CFTimeInterval) {
        key = scene.key
        passedAtStep = passed
        nextSeenDuringStep = false
        nextFrames = 0
        docked = nil
        gestureKept = nil
        stepChangedAt = now
        flight = nil
        revealAt = nil
        fadedSince = nil
        paperOutSince = nil
        nextUnmeasuredSince = nil
        reopensAt = nil
    }

    /// Reasons a step waits on, the old window or the mask held for it, rather than leaving.
    private static func waits(_ why: String) -> Bool { why == "scrolling" || why == "zooming" }
    /// As long as `TourCoordinator.waitsForScroll` holds a step, and a little more.
    private static let scrollWait = 2.1
    /// The bubble's fade in at its new place, after a scroll.
    private static let bubbleFadesIn = 0.25
    /// When the faded bubble is put at its new place, and when the window shut for a scroll opens
    /// again (`windowShut`), once the bubble is there.
    private var swapAt: CFTimeInterval?
    private var reopensAt: CFTimeInterval?
    /// Under Reduce Motion, from a card to a first step: when the card has faded and the window
    /// and the bubble may come (`TourNoteMotion.bubbleOut`'s length).
    private var revealAt: CFTimeInterval?
    /// Under Reduce Motion (`fadeAcross`): since when the old window fades out, and the old paper.
    private var fadedSince: CFTimeInterval?
    private var paperOutSince: CFTimeInterval?
    /// `fadeAcross`: the next step's window is the one on screen, and stays lit.
    private var windowStays = false

    private func setShown(_ shown: Bool) {
        if shown {
            model.closesWindow = false
            model.paperOpacity = 1
            if reduceMotion, !isShowing { model.windowGeneration += 1 }
        }
        if !shown {
            model.paperHidden = false
            reopensAt = nil
            swapAt = nil
            revealAt = nil
            fadedSince = nil
            paperOutSince = nil
            // A paper already faded out does not come back to leave (Reduce Motion).
            if !reduceMotion { model.paperOpacity = 1 }
            if model.windowShut { model.windowShut = false }
        }
        isShowing = shown
        if !shown {
            model.paperFrame = .null
            flight = nil
        }
        withAnimation(reduceMotion ? TourNoteMotion.reduced : shown ? TourNoteMotion.bubbleIn : TourNoteMotion.bubbleOut) {
            model.shown = shown
        }
        coordinator?.log.notice("tour: overlay \(shown ? "shown" : "hidden", privacy: .public) \(self.why, privacy: .public)")
    }

    /// The window follows its control every frame with no animation; the bubble moves only once
    /// the window has stayed put for 0.15 s (correction 6).
    private func track(_ reading: Reading, scene: TourOverlayScene, now: CFTimeInterval) {
        if reading.base != model.base { model.base = reading.base }
        // The step's own move starts after the old words have faded (0.12 s).
        let flying = now - stepChangedAt - TourNoteMotion.wordsOut
        if let flight, let target = reading.cutout {
            var still = Transaction()
            still.disablesAnimations = true
            if flying >= TourNoteMotion.moveSettle {
                self.flight = nil
                withTransaction(still) { model.cutout = target }
            } else if flying > 0 {
                let progress = TourNoteMotion.moveSpring.value(target: 1.0, time: flying)
                var step = target.animated - flight.from.animated
                step.scale(by: progress)
                var cutout = flight.from
                cutout.animated = flight.from.animated + step
                withTransaction(still) { model.cutout = cutout }
            }
            lastMove = now
        }
        guard flight == nil, flying > 0 else { return }
        // Under Reduce Motion the old window is still fading out where it was.
        if reduceMotion, reopensAt != nil { return }
        if let cutout = reading.cutout, let shown = model.cutout, Self.differs(cutout.rect, shown.rect, by: 0.5) {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { model.cutout = cutout }
            lastMove = now
        } else if (reading.cutout == nil) != (model.cutout == nil) {
            model.cutout = reading.cutout
            lastMove = now
        }
        if let docked, let rect = model.cutout?.rect, var tail = model.placement.tail {
            // The bubble stays put (VISUAL §11.1): only the tip of its tail follows the window.
            let offset = rect.midX - docked.x
            if abs(tail.offset - offset) > 0.5 {
                tail.offset = offset
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { model.placement.tail = tail }
            }
            return
        }
        if now - lastMove >= 0.15, let rect = model.cutout?.rect, Self.differs(rect, placedFor, by: 1) {
            withAnimation(reduceMotion ? nil : TourNoteMotion.move) { place(reading, scene: scene, now: now, keepsCutout: true) }
        }
    }

    /// The bubble cannot have its least height beside this step's window: the step is read as a
    /// page instead (QA_T2 F3, F4; TECH_DESIGN §6.1).
    private func squeeze(_ scene: TourOverlayScene) {
        showableSince = nil
        if isShowing { setShown(false) }
        if let key = scene.key { coordinator?.squeeze(key) }
    }

    /// Whether `place` would find room for the bubble, without placing it.
    /// `fresh`: the step has not begun, so nothing kept for the one on screen counts.
    private func fits(_ reading: Reading, scene: TourOverlayScene, fresh: Bool = false) -> Bool {
        guard case .step(_, let step, let number, let count, let nextTitle) = scene, let hole = reading.cutout?.rect else { return true }
        if fresh { return freshPlacement(for: step, number: number, count: count, nextTitle: nextTitle, reading: reading) != nil }
        return placement(for: step, number: number, count: count, nextTitle: nextTitle, around: hole) != nil
    }

    /// False when the bubble has no room beside the window (the caller reads the step as a page).
    @discardableResult
    private func place(_ reading: Reading, scene: TourOverlayScene, now: CFTimeInterval, animated: Bool = false,
                       keepsCutout: Bool = false) -> Bool {
        if !keepsCutout {
            if model.cutout == nil || !animated {
                // From no window to a window: it opens in place rather than flying in from a corner.
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { model.cutout = reading.cutout }
            } else {
                model.cutout = reading.cutout
            }
        }
        model.base = reading.base
        floorTop = reading.floorTop
        if case .step(_, let step, let number, let count, let nextTitle) = scene, step.target == .none {
            // No window: the bubble in the middle of the screen, no tail.
            placedFor = .null
            model.placement = centred(step, number: number, count: count, nextTitle: nextTitle)
            return true
        }
        guard let hole = reading.cutout?.rect ?? model.cutout?.rect,
              case .step(_, let step, let number, let count, let nextTitle) = scene else {
            placedFor = .null
            return true
        }
        guard let placement = placement(for: step, number: number, count: count, nextTitle: nextTitle, around: hole) else {
            return false
        }
        placedFor = hole
        model.placement = placement
        if step.target == .scene(.stage), stageTop != nil, let lowered = evaluate(step.target).cutout {
            // Step 3 of the ladder: the window gives up the top of the walls at once.
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { model.cutout = lowered }
            placedFor = lowered.rect
        }
        return true
    }

    /// A step with no window (12.3 关着, 12.4): the bubble centred on the screen, with no tail.
    private func centred(_ step: TourStep, number: Int, count: Int, nextTitle: String) -> TourBubblePlacement {
        let screen = view.bounds.size
        let regular = traitCollection.horizontalSizeClass == .regular
        var place = TourBubblePlacement()
        place.width = min(screen.width - 2 * TourNoteMetrics.bubbleMargin, TourNoteMetrics.bubbleMaxWidth(regular: regular))
        let size = sizer.heights(step: step, number: number, count: count, nextTitle: nextTitle, width: place.width, traits: traitCollection)
        let room = screen.height * TourNoteMetrics.tallestShare
        place.x = (screen.width - place.width) / 2
        place.fromTop = true
        place.inset = max(view.safeAreaInsets.top + 8, (screen.height - min(size.ideal, room)) / 2)
        place.maxHeight = room
        place.tail = nil
        return place
    }

    /// Chapter 7's bubble (VISUAL §17.6): the same place for its three steps, tried in order:
    /// on the bottom bar, on the top bar, and for 7.2 on the top bar with the stage window giving up
    /// the top of the walls. nil: page mode. 7.2 has no tail.
    private func gesturePlacement(for step: TourStep, number: Int, count: Int, nextTitle: String,
                                  around hole: CGRect) -> TourBubblePlacement? {
        let screen = view.bounds.size
        let safe = view.safeAreaInsets
        let regular = traitCollection.horizontalSizeClass == .regular
        let stage = step.target == .scene(.stage)
        // 7.2 keeps off the whole stage, the floor its fingers land on; 7.1 and 7.3 only keep the
        // tail's tip 6 pt clear of their window and may cover the floor's front (VISUAL §17.10.2).
        let clear: CGFloat = stage ? 8 : 6
        var place = TourBubblePlacement()
        place.width = min(screen.width - 2 * TourNoteMetrics.bubbleMargin, TourNoteMetrics.bubbleMaxWidth(regular: regular))
        place.x = (screen.width - place.width) / 2
        if !stage, isPad {
            // iPad: towards the window, so the tail reaches it, 16 pt from the sides at least; for
            // the whole step (§19.3 item 7).
            let side = TourNoteMetrics.bubbleMargin
            place.x = max(side, min(hole.midX - place.width / 2, screen.width - side - place.width))
        }
        // The sizer measures with a tail: 7.2 has none.
        let measured = sizer.heights(step: step, number: number, count: count, nextTitle: nextTitle,
                                     width: place.width, traits: traitCollection)
        let untailed: CGFloat = stage ? TourNoteMetrics.tailHeight : 0
        let whole = measured.ideal - untailed
        measuredWhole = whole
        measuredLeast = measured.least - untailed
        let tallest = screen.height * TourNoteMetrics.tallestShare
        func tail(_ edge: Edge) -> TourNoteBubbleShape.Tail? {
            stage ? nil : .init(edge: edge, offset: hole.midX - place.x)
        }
        let bottom = screen.height - safe.bottom - 8
        let top = safe.top + 8
        let belowRoom = bottom - (hole.maxY + clear), aboveRoom = hole.minY - clear - top
        // A level is used only when the words fit whole there (no scrolling); the bubble may then
        // take all of that room, so a measure a hair short never squeezes it (§17.10.2 item 1).
        func onBottom(room: CGFloat) -> TourBubblePlacement {
            var place = place
            place.fromTop = false
            place.inset = screen.height - bottom
            place.maxHeight = min(room, tallest)
            place.tail = tail(.top)
            place.above = false
            return place
        }
        func onTop(room: CGFloat) -> TourBubblePlacement {
            var place = place
            place.fromTop = true
            place.inset = top
            place.maxHeight = min(room, tallest)
            place.tail = tail(.bottom)
            place.above = true
            return place
        }
        stageTop = nil
        if whole <= belowRoom { return onBottom(room: belowRoom) }
        if whole <= aboveRoom { return onTop(room: aboveRoom) }
        // 7.2 only: the window's top comes down to under the bubble, never below the floor's back.
        if stage, let floorTop, top + whole + clear <= floorTop {
            stageTop = top + whole + clear
            return onTop(room: floorTop - clear - top)
        }
        // At accessibility sizes, where no level holds the whole words, they scroll in the bubble
        // on the bottom bar (§10.1); otherwise the step is read as a page.
        let least = measured.least - untailed
        guard traitCollection.preferredContentSizeCategory.isAccessibilityCategory else { return nil }
        if least <= belowRoom { return onBottom(room: belowRoom) }
        if least <= aboveRoom { return onTop(room: aboveRoom) }
        return nil
    }

    /// Where the bubble goes beside `hole`, or nil when even its least height (the signature, a line
    /// and a half of words, the buttons) has no room on either side.
    private func placement(for step: TourStep, number: Int, count: Int, nextTitle: String,
                           around hole: CGRect) -> TourBubblePlacement? {
        let screen = view.bounds.size
        let safe = view.safeAreaInsets
        let margin = TourNoteMetrics.bubbleMargin
        let regular = traitCollection.horizontalSizeClass == .regular
        let gap = TourNoteMetrics.tailGap + TourNoteMetrics.cutoutLine / 2
        let tail = TourNoteMetrics.tailHeight
        let tallest = screen.height * TourNoteMetrics.tallestShare
        var place = TourBubblePlacement()
        place.width = min(screen.width - 2 * margin, TourNoteMetrics.bubbleMaxWidth(regular: regular))

        if step.id.hasPrefix("7.") {
            // Placed once per step, on the room as the step began: the bubble stays put while the
            // user pinches and the stage window grows past the screen (VISUAL §17.6, §17.10.2).
            if var kept = gestureKept {
                if kept.place.tail != nil { kept.place.tail?.offset = hole.midX - kept.place.x }
                stageTop = kept.stageTop
                return kept.place
            }
            guard let fresh = gesturePlacement(for: step, number: number, count: count, nextTitle: nextTitle, around: hole) else {
                return nil
            }
            gestureKept = (fresh, stageTop)
            return fresh
        }

        if step.docked {
            if var kept = docked {
                kept.tail?.offset = hole.midX - kept.x
                return kept
            }
            let size = sizer.heights(step: step, number: number, count: count, nextTitle: nextTitle,
                                     width: place.width, traits: traitCollection)
            // Under the top bar, the paper where 1.3a's paper is; or, when the window is too close
            // to that, above the bottom bar, the same way up (VISUAL §11.1). Centred, and still for
            // the whole step: only the tail's tip follows the cat.
            let clearance: CGFloat = 12
            let paperTop = (edgeOfBar(["room-switcher"], top: true) ?? safe.top + 8) + gap + tail
            let paperBottom = (edgeOfBar(["choose-interaction", "add-photo"], top: false)
                ?? screen.height - safe.bottom - 100) - gap - tail
            let topRoom = min(tallest, hole.minY - clearance - paperTop)
            let bottomRoom = min(tallest, paperBottom - (hole.maxY + clearance))
            let top: Bool
            if size.ideal <= topRoom {
                top = true
            } else if size.ideal <= bottomRoom {
                top = false
            } else if size.least <= topRoom {
                top = true
            } else if size.least <= bottomRoom {
                top = false
            } else {
                return nil
            }
            place.x = (screen.width - place.width) / 2
            place.fromTop = top
            place.inset = top ? paperTop : screen.height - paperBottom
            place.maxHeight = top ? topRoom : bottomRoom
            place.tail = .init(edge: top ? .bottom : .top, offset: hole.midX - place.x)
            place.above = top
            docked = place
            return place
        }

        let size = sizer.heights(step: step, number: number, count: count, nextTitle: nextTitle,
                                 width: place.width, traits: traitCollection)
        // 1.3a on iPad is in the middle like 1.1 and 1.4, though the title plate is a little off it:
        // the tail reaches the plate by itself (§19.3 item 3).
        place.x = isPad && step.id == "1.3a" ? (screen.width - place.width) / 2
            : TourNoteMetrics.bubbleX(width: place.width, screenWidth: screen.width, window: hole)
        let edge = TourNoteMetrics.bubbleLeastMargin
        let aboveRoom = min(tallest, hole.minY - gap - (safe.top + edge))
        let belowRoom = min(tallest, screen.height - safe.bottom - edge - (hole.maxY + gap))
        // The side with more room, unless only the other one holds the bubble's least height. A step
        // that keeps something under its row clear (13.1) goes above whenever it fits there.
        let need = Self.needed(size, for: step)
        var above = step.bubbleAbove && need <= aboveRoom ? true : aboveRoom > belowRoom
        if need > (above ? aboveRoom : belowRoom) { above.toggle() }
        let room = above ? aboveRoom : belowRoom
        guard need <= room else { return nil }
        place.fromTop = !above
        place.inset = above ? screen.height - (hole.minY - gap) : hole.maxY + gap
        place.maxHeight = room
        place.tail = .init(edge: above ? .bottom : .top, offset: hole.midX - place.x)
        place.above = above
        return place
    }

    /// Whether the bubble's least height fits above `hole` (13.1, `TourStep.bubbleAbove`).
    private func fitsAbove(_ step: TourStep, number: Int, count: Int, nextTitle: String, hole: CGRect) -> Bool {
        let screen = view.bounds.size
        let width = min(screen.width - 2 * TourNoteMetrics.bubbleMargin,
                        TourNoteMetrics.bubbleMaxWidth(regular: traitCollection.horizontalSizeClass == .regular))
        let size = sizer.heights(step: step, number: number, count: count, nextTitle: nextTitle, width: width, traits: traitCollection)
        let gap = TourNoteMetrics.tailGap + TourNoteMetrics.cutoutLine / 2
        let room = min(screen.height * TourNoteMetrics.tallestShare,
                       hole.minY - gap - (view.safeAreaInsets.top + TourNoteMetrics.bubbleLeastMargin))
        return Self.needed(size, for: step) <= room
    }

    /// The height a bubble must have room for. On a list scrolled to its row (11.2, 13.1, 14.2) all
    /// of its words, or the step is read as a page over the list: a bubble that shows a line and a
    /// half and fades the rest was cut short (iPhone SE, Accessibility XL, 11.2; VISUAL §17.10.2
    /// "放不下就换下一级、不截断"). Elsewhere its least height, the words scrolling inside it.
    static func needed(_ size: TourBubbleSizer.Heights, for step: TourStep) -> CGFloat {
        step.scrolls ? size.ideal : size.least
    }

    /// The window kept inside the screen (VISUAL §18.2 item 2): its edges at least 4 pt from the
    /// screen's, the padding giving way on that side, down to none (the control's own edge).
    static func onScreen(_ cutout: TourNoteCutout, control: CGRect, in screen: CGRect) -> TourNoteCutout {
        let edge: CGFloat = 4
        let rect = cutout.rect
        let minX = rect.minX < screen.minX + edge ? min(screen.minX + edge, max(control.minX, rect.minX)) : rect.minX
        let minY = rect.minY < screen.minY + edge ? min(screen.minY + edge, max(control.minY, rect.minY)) : rect.minY
        let maxX = rect.maxX > screen.maxX - edge ? max(screen.maxX - edge, min(control.maxX, rect.maxX)) : rect.maxX
        let maxY = rect.maxY > screen.maxY - edge ? max(screen.maxY - edge, min(control.maxY, rect.maxY)) : rect.maxY
        let kept = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard kept != rect else { return cutout }
        return TourNoteCutout(rect: kept, cornerRadius: min(cutout.cornerRadius, min(kept.width, kept.height) / 2))
    }

    /// The lower edge of the top bar's windows (`top`), or the upper edge of the bottom bar's: what
    /// a docked bubble lines up with. nil when none of the controls is on screen.
    private func edgeOfBar(_ ids: [String], top: Bool) -> CGFloat? {
        guard let main else { return nil }
        let edges = ids.compactMap { id -> CGFloat? in
            guard let probe = TourAnchorRegistry.shared.probe(id, in: main), let rect = TourGeometry.rect(of: probe) else { return nil }
            let window = TourNoteCutout(around: rect.model, form: probe.form, padding: probe.padding).rect
            return top ? window.maxY : window.minY
        }
        return top ? edges.max() : edges.min()
    }

    private static func differs(_ a: CGRect, _ b: CGRect, by limit: CGFloat) -> Bool {
        a.isNull != b.isNull || abs(a.minX - b.minX) > limit || abs(a.minY - b.minY) > limit
            || abs(a.width - b.width) > limit || abs(a.height - b.height) > limit
    }

    /// A "do" step is done when the user touched the control in the window and the next step's
    /// target then turned up and settled: the panel the control opens. Both halves matter (a
    /// target already there, or one shown because some other page closed, is not "done").
    private func checkDoStep(_ scene: TourOverlayScene, _ reading: Reading) {
        guard let step = scene.step, step.does, let key = scene.key else { return }
        if step.handsOff {
            // Leaving the app voids the touch: what is open on the way back (a quick action's
            // camera) was not opened by it.
            if reading.why == "inactive" { passedAtStep = passed }
            coordinator?.handOff(key, touched: passed != passedAtStep,
                                 covered: ["transition", "covered", "covered-subview"].contains(reading.why))
            return
        }
        guard let done = step.doneWhen else { return }
        let next = evaluate(done)
        if passed == passedAtStep {
            if reading.showable, next.showable { nextSeenDuringStep = true }
        } else if !nextSeenDuringStep {
            nextFrames = next.showable && next.drift < 0.5 ? nextFrames + 1 : 0
            if nextFrames >= 6 { coordinator?.didStep(key) }
        }
    }

    // MARK: May it show

    private struct Reading {
        var showable = false
        var why = "nothing"
        var cutout: TourNoteCutout?
        var base: TourNoteMask.Base = .bright
        /// How far the model layer is from what is on screen: non-zero while UIKit animates.
        var drift: CGFloat = 0
        /// The cat was asked for and is not drawn: the window is on the floor she will be on.
        var estimated = false
        /// The stage window: where the floor's back corner is, as high as its top may be lowered.
        var floorTop: CGFloat?
    }

    private func evaluate(_ target: TourTarget, anyLayer: Bool = false) -> Reading {
        var reading = Reading()
        guard let main, let root = main.rootViewController else { reading.why = "no-window"; return reading }
        guard UIApplication.shared.applicationState == .active, main.windowScene?.activationState == .foregroundActive else {
            reading.why = "inactive"
            return reading
        }
        var top = root
        while let next = top.presentedViewController { top = next }
        if top.isBeingPresented || top.isBeingDismissed || top.transitionCoordinator != nil || root.transitionCoordinator != nil {
            reading.why = "transition"
            return reading
        }
        let onRoom = top === root
        // The room page follows the room's light; the other layers follow the system.
        reading.base = onRoom ? (TourSceneAnchorView.current?.night == true ? .dim : .bright)
            : top.traitCollection.userInterfaceStyle == .dark ? .dim : .bright

        let anchor: UIView
        var local: CGRect?
        var form = TourNoteCutout.Form.labelled
        var padding = TourNoteMetrics.cutoutPadding
        var largest: CGFloat = 0.6
        var round = false
        var stage = false
        var cellRect: (shown: CGRect, model: CGRect)?
        switch target {
        case .none:
            // 12.3 关着 and 12.4 are said over the company page (`anyLayer`).
            reading.why = onRoom || anyLayer ? "card" : "covered"
            reading.showable = onRoom || anyLayer
            return reading
        case .control(let id):
            if let probe = TourAnchorRegistry.shared.probe(id, in: main) {
                anchor = probe
                form = probe.form
                padding = probe.padding
                if let cell = TourGeometry.cell(of: probe) {
                    // A list row: the window is the row's card, or its whole group (§18.2 item 1).
                    // Still the probe that must be in the top layer.
                    cellRect = TourGeometry.rect(of: cell.view, local: cell.local)
                    form = .plate(corner: cell.corner)
                    padding = TourGeometry.rowPadding
                }
            } else if let item = TourBarItems.view(id, in: main) {
                // A navigation bar button: SwiftUI hosts it where a probe is not drawn.
                anchor = item
                form = .circle
                padding = 3
            } else {
                reading.why = "no-target"
                return reading
            }
        case .scene(let wanted):
            guard let scene = TourSceneAnchorView.current, scene.window === main else { reading.why = "no-target"; return reading }
            // Until the cat is drawn, the window opens on the floor she will be on.
            let cat = wanted == .cat ? scene.rect(for: .cat) : nil
            reading.estimated = wanted == .cat && cat == nil
            let found = wanted == .cat || wanted == .floor ? cat ?? scene.rect(for: .floor) : scene.rect(for: wanted)
            guard var rect = found, !rect.isNull else {
                reading.why = "no-target"
                return reading
            }
            anchor = scene
            largest = 0.75
            if wanted == .stage {
                // The stage window (VISUAL §17.6): the room's box, 8 out, at least 4 from the
                // screen's sides; its top may be lowered to the floor's back corner for the bubble.
                largest = 1.01
                stage = true
                if let floor = scene.rect(for: .floor) { reading.floorTop = scene.convert(floor, to: nil).minY }
                rect = rect.insetBy(dx: -8, dy: -8)
                let left = scene.convert(CGPoint(x: 4, y: 0), from: nil).x
                let right = scene.convert(CGPoint(x: view.bounds.width - 4, y: 0), from: nil).x
                rect = CGRect(x: max(rect.minX, left), y: rect.minY, width: min(rect.maxX, right) - max(rect.minX, left), height: rect.height)
                if let stageTop {
                    let top = scene.convert(CGPoint(x: 0, y: stageTop), from: nil).y
                    if top > rect.minY { rect = CGRect(x: rect.minX, y: top, width: rect.width, height: rect.maxY - top) }
                }
            }
            local = rect
            // The cat's window is a circle (VISUAL §11.1): her box's longer side and 40, at least
            // 72, measured when the step begins; after that only its centre follows her.
            if cat != nil {
                let diameter = catDiameter ?? max(max(rect.width, rect.height) + 40, 72)
                catDiameter = diameter
                local = CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)
                round = true
            }
        }

        // The target has to be in the topmost layer: the top presented controller, and the last
        // of the main window's subviews (a menu or an edit menu is a subview, not a controller).
        guard anchor.isDescendant(of: top.view) else { reading.why = "covered"; return reading }
        // A push inside a navigation stack is a transition of a controller further down.
        var responder: UIResponder? = anchor
        while let current = responder {
            if let controller = current as? UIViewController, controller.transitionCoordinator != nil {
                reading.why = "transition"
                return reading
            }
            responder = current.next
        }
        guard let last = main.subviews.last, anchor.isDescendant(of: last) else { reading.why = "covered-subview"; return reading }
        guard let rect = TourGeometry.rect(of: anchor, local: local) else { reading.why = "no-window"; return reading }
        reading.drift = max(abs(rect.shown.minX - rect.model.minX), abs(rect.shown.minY - rect.model.minY))
        let screen = view.bounds
        guard rect.shown.width >= 1, rect.shown.height >= 1, screen.insetBy(dx: -1, dy: -1).contains(rect.shown) else {
            reading.why = "off-screen"
            return reading
        }
        guard rect.shown.width * rect.shown.height < screen.width * screen.height * largest else {
            reading.why = "too-large"
            return reading
        }
        // Cut off by a scroll view, under a title bar (correction 3).
        guard Self.visiblePart(of: anchor, rect: rect.model).insetBy(dx: -1, dy: -1).contains(rect.model) else {
            reading.why = "clipped"
            return reading
        }
        let shown = cellRect?.shown ?? rect.shown
        reading.cutout = round ? TourNoteCutout(rect: rect.shown, cornerRadius: rect.shown.width / 2)
            : stage ? TourNoteCutout(rect: rect.shown, cornerRadius: 24)
            : Self.onScreen(TourNoteCutout(around: shown, form: form, padding: padding), control: shown, in: screen)
        reading.showable = true
        reading.why = "ok"
        return reading
    }

    /// What scroll views and clipping ancestors leave of `rect` (window coordinates).
    private static func visiblePart(of view: UIView, rect: CGRect) -> CGRect {
        var visible = rect
        var ancestor = view.superview
        while let current = ancestor, !(current is UIWindow) {
            if let scroll = current as? UIScrollView {
                visible = visible.intersection(scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: nil))
            } else if current.clipsToBounds {
                visible = visible.intersection(current.convert(current.bounds, to: nil))
            }
            ancestor = current.superview
        }
        return visible
    }

    // MARK: Probe

    private func writeStatus() {
        #if DEBUG
        frames += 1
        func number(_ value: CGFloat) -> String { String(format: "%.1f", value) }
        func rect(_ rect: CGRect?) -> String {
            guard let rect, !rect.isNull else { return "none" }
            return [rect.minX, rect.minY, rect.width, rect.height].map(number).joined(separator: ",")
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let keyName = keyWindow == nil ? "none" : keyWindow === main ? "main" : keyWindow is TourOverlayWindow ? "overlay" : "other"
        let value = "tour=\(coordinator?.probe ?? "none") show=\(isShowing ? 1 : 0) why=\(why)"
            + " hole=\(rect(isShowing ? model.cutout?.rect : nil)) bubble=\(rect(model.paperFrame))"
            + " cap=\(number(model.placement.maxHeight)) whole=\(number(measuredWhole)) least=\(number(measuredLeast)) dim=\(model.base == .dim ? 1 : 0) key=\(keyName) passed=\(passed) swallowed=\(swallowed)"
        guard value != lastStatus || frames % 30 == 0 else { return }
        lastStatus = value
        status.accessibilityValue = value
        #endif
    }
}

/// How tall a bubble would be, measured off screen with the view the overlay shows: its height with
/// all its words, and its least height, when the words scroll and show a line and a half.
@MainActor
final class TourBubbleSizer {
    struct Heights {
        var ideal: CGFloat
        var least: CGFloat
    }

    private struct Key: Hashable {
        var line: String
        var width: CGFloat
        var size: String
        var regular: Bool
        var nextTitle: String
        var count: Int
    }

    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    private var known: [Key: Heights] = [:]

    func heights(step: TourStep, number: Int, count: Int, nextTitle: String, width: CGFloat,
                 traits: UITraitCollection) -> Heights {
        let key = Key(line: step.line, width: width, size: traits.preferredContentSizeCategory.rawValue,
                      regular: traits.horizontalSizeClass == .regular, nextTitle: nextTitle, count: count)
        if let heights = known[key] { return heights }
        func height(_ line: String) -> CGFloat {
            let bubble = TourNoteBubble(speaker: TourText.speaker, portrait: step.art.head(bubbleAbove: false), line: line,
                                        progress: .init(step: number, count: count), tail: .init(edge: .top, offset: width / 2),
                                        skipTitle: TourText.skip, nextTitle: nextTitle, skip: {}, next: {})
                .frame(width: width)
                .environment(\.dynamicTypeSize, DynamicTypeSize(traits.preferredContentSizeCategory) ?? .large)
                .environment(\.horizontalSizeClass, traits.horizontalSizeClass == .regular ? .regular : .compact)
                // A new identity for every measure: the bubble keeps its words and its button's word
                // in `@State`, set once when it is made, so a reused host measured the first line it
                // ever saw, whatever it was asked (169.5 pt for 191.5 on iPhone SE; VISUAL §17.10.2
                // item 1).
                .id("\(line)|\(nextTitle)")
            host.rootView = AnyView(bubble)
            return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        // One and two lines in the step's own script: Chinese is set taller than Latin.
        let sample = String(step.line.prefix(1))
        let one = height(sample), two = height(sample + "\n" + sample)
        let heights = Heights(ideal: height(step.line), least: one + max(two - one, 0) / 2)
        known[key] = heights
        return heights
    }
}

/// Counts the fingers on the main window for 7.2, which goes on only once they have all left. It
/// never recognises: it stays possible, takes nothing from the room's own gestures, and resets
/// when the last finger lifts.
final class TourTouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private(set) static var down = 0
    static func forget() { down = 0 }

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        Self.down += touches.count
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        Self.down = max(0, Self.down - touches.count)
        if Self.down == 0 { state = .failed }
    }

    override func reset() {
        super.reset()
        Self.down = 0
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
