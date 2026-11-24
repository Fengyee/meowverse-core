import MeowverseCore
import SwiftUI
import UIKit

extension View {
    /// The app's root: where the tour finds the main window, and where its sheets (the naming
    /// page, page mode) are presented. Without the tour the view is left as it is.
    @ViewBuilder
    func tourHost(_ coordinator: TourCoordinator) -> some View {
        if TourLaunch.isEnabled {
            modifier(TourHost(coordinator: coordinator))
        } else {
            self
        }
    }
}

private struct TourHost: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(ReminderScheduler.self) private var reminders
    @Bindable var coordinator: TourCoordinator

    func body(content: Content) -> some View {
        content
            .background(HostProbe { window in coordinator.attach(window: window, model: model, reminders: reminders) })
            .background {
                Color.clear.sheet(isPresented: $coordinator.namingShown, onDismiss: { coordinator.named(nil) }) {
                    TourNamingPage(catName: model.leadCatName, use: { coordinator.named($0) }, later: { coordinator.named(nil) })
                        .presentationDetents([.large])
                }
            }
            .background {
                Color.clear.sheet(isPresented: $coordinator.pageShown, onDismiss: { coordinator.pageClosed() }) {
                    TourPageView(coordinator: coordinator, catName: model.leadCatName)
                }
            }
            .background {
                Color.clear.fullScreenCover(isPresented: $coordinator.noticeShown, onDismiss: { coordinator.noticeClosed() }) {
                    TourTestBuildPage(answered: coordinator.noticeAnswered, close: { coordinator.noticeShown = false })
                        .environment(model)
                }
            }
            .alert("没能保存", isPresented: Binding(get: { coordinator.renameFailure != nil },
                                                set: { if !$0 { coordinator.renameFailure = nil } })) {
                Button("好") { coordinator.renameFailure = nil }
            } message: {
                Text(coordinator.renameFailure ?? "")
            }
    }

    private struct HostProbe: UIViewRepresentable {
        let found: (UIWindow) -> Void
        func makeUIView(context: Context) -> HostView { HostView() }
        // The latest closure wins: SwiftUI may build this view more than once.
        func updateUIView(_ view: HostView, context: Context) { view.found = found }
    }

    final class HostView: UIView {
        var found: ((UIWindow) -> Void)? {
            didSet { report() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        private func report() {
            guard let window, let found else { return }
            DispatchQueue.main.async { found(window) }
        }
    }
}

// MARK: - The naming page

/// 「它叫什么名字？」 (PRODUCT_PLAN §3.3, chapter 1): a plain page in the main window, where the
/// keyboard can come up. The field starts empty with the cat's present name as its placeholder;
/// empty, 「先不起名」 or a swipe down leave the name as it is.
struct TourNamingPage: View {
    let catName: String
    let use: (String) -> Void
    let later: () -> Void
    var embedded = false
    /// A sheet's rise, about 0.5 s.
    static let keyboardAfter: Duration = .milliseconds(550)
    @State private var typed = ""
    @FocusState private var typing: Bool

    var body: some View {
        let page = ScrollView {
            VStack(spacing: 16) {
                TourChapterIllustration(image: TourArt.b2.body)
                    .accessibilityHidden(true)
                Text(verbatim: TourText.namingTitle)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: TourText.namingLine)
                    .font(.body)
                    .foregroundStyle(Color.subtle)
                    .multilineTextAlignment(.center)
                TextField(text: $typed, prompt: Text(verbatim: catName)) { Text(verbatim: TourText.namingField) }
                    .font(.title3)
                    // On the page's own paper with a 1 pt edge, not the system's white or black box
                    // (VISUAL §11.1).
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoomPaper.sheet, in: .rect(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(RoomPaper.edge, lineWidth: 1) }
                    .multilineTextAlignment(.center)
                    .submitLabel(.done)
                    .focused($typing)
                    .onSubmit { use(typed) }
                    .onChange(of: typed) { _, value in
                        if value.count > AppState.maxCatNameLength { typed = String(value.prefix(AppState.maxCatNameLength)) }
                    }
                    .accessibilityIdentifier("tour-naming-field")
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .tourPageFoot {
            TourNoteButtonRow(quietTitle: TourText.namingLater, solidTitle: TourText.namingUse,
                              quietID: "tour-naming-later", solidID: "tour-naming-use",
                              quiet: later, solid: { use(typed) })
            }
        // The keyboard comes once the page is in place: asked for as the sheet began to rise, it held
        // the main thread for 0.37 s while the mask was fading (VISUAL §14.1 item 1). In page mode the
        // page is already up.
        .task {
            if !embedded {
                do { try await Task.sleep(for: Self.keyboardAfter) } catch { return }
            }
            typing = true
        }
        if embedded {
            page
        } else {
            page.memoryPage(.home)
        }
    }
}

// MARK: - The test build page

/// 「测试版说明」 (`TourTestBuild`): Bella says this is a test build and where problems go. A page
/// card of page mode, full screen, with no mask and no window. 「去反馈」 opens the same 「反馈问题」
/// as Settings, on this page's own navigation; its 【完成】 closes both.
struct TourTestBuildPage: View {
    let answered: () -> Void
    let close: () -> Void
    @State private var reporting = false
    @AccessibilityFocusState private var reads: Bool

    var body: some View {
        NavigationStack {
            // The words and Bella in the middle of the page, the words flush left (VISUAL §15).
            TourPageScroll(flash: "test-build", centered: true) {
                VStack(spacing: 16) {
                    // Ears out, mouth closed: calm, something not ready yet (BellaHead.notYet).
                    TourNotePortrait(image: BellaHead.notYet.image, name: TourText.speaker, size: 88)
                        .padding(.top, 12)
                        .accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text(verbatim: TourTestBuild.title)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .tourPageLines(.title2.weight(.semibold), sample: TourTestBuild.line)
                        Text(verbatim: TourTestBuild.line)
                            .font(.body)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .tourPageLines(.body, sample: TourTestBuild.line)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: [TourText.speaker, TourTestBuild.title, TourTestBuild.line].joined(separator: "\n")))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($reads)
                    .accessibilityIdentifier("tour-test-build-words")
                }
                .padding(24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .tourPageFoot {
                TourNoteButtonRow(quietTitle: TourTestBuild.gotIt, solidTitle: TourTestBuild.report,
                                  quietID: "tour-test-build-ok", solidID: "tour-test-build-report",
                                  quiet: {
                                      answered()
                                      close()
                                  },
                                  solid: {
                                      answered()
                                      reporting = true
                                  })
            }
            .memoryPage(.home)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $reporting) {
                // Answered already: the way out is 【关闭】, not back to the page.
                FeedbackView()
                    .navigationBarBackButtonHidden()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(TourTestBuild.close, action: close)
                                .accessibilityIdentifier("tour-test-build-close")
                        }
                    }
            }
        }
        .onAppear { reads = true }
    }
}

// MARK: - Page mode

/// The tour as a plain sheet of pages, for VoiceOver, Switch Control and very large text
/// (TECH_DESIGN §6.1): the same lines, no overlay window and no mask. The sheet's modality is
/// UIKit's own. Read first: the step and its words, as one element; then 【下一步】, 【上一步】,
/// 【跳过这一段】.
struct TourPageView: View {
    let coordinator: TourCoordinator
    let catName: String
    @AccessibilityFocusState private var reads: Bool

    var body: some View {
        // No navigation bar: the paper and its spine run to the top, as on the naming page
        // (VISUAL §11.1).
        Group {
            if let showing = coordinator.showing {
                if showing.onCard, let card = TourScript.card(showing.run.chapter, catName: catName) {
                    cardPage((card.title, showing.placeholderLine ?? showing.cardLine ?? card.line, card.art),
                             first: showing.run.chapter == .welcome && showing.run.mode == .auto, startTitle: showing.startTitle,
                             placeholder: showing.placeholderLine != nil)
                } else if let step = showing.step {
                    if step.kind == .companyPages {
                        coordinator.companyPagesView()
                    } else if step.kind == .naming {
                        TourNamingPage(catName: catName, use: { coordinator.named($0) }, later: { coordinator.named(nil) },
                                       embedded: true)
                    } else {
                        stepPage(step, showing)
                    }
                }
            }
        }
        .memoryPage(.home)
        // Full height only. On iOS 27.2 a sheet at its medium detent draws its content at 0.96
        // of its size, so a 44 pt button there measures 42.2 pt on screen.
        .presentationDetents([.large])
        // VoiceOver's two-finger scrub leaves the chapter, the same as 跳过这一段.
        .accessibilityAction(.escape) { coordinator.skip() }
        .onChange(of: coordinator.showing?.index) { reads = true }
        .onChange(of: coordinator.showing?.onCard) { reads = true }
        .onAppear { reads = true }
    }

    private func cardPage(_ card: (title: String, line: String, art: TourArt), first: Bool, startTitle: String,
                          placeholder: Bool) -> some View {
        TourPageScroll(flash: card.line) {
            VStack(spacing: 16) {
                TourChapterIllustration(image: card.art.body).accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(verbatim: card.title).font(.title2.weight(.semibold))
                        .tourPageLines(.title2.weight(.semibold), sample: card.line)
                    Text(verbatim: card.line).font(.body).multilineTextAlignment(.center)
                        .tourPageLines(.body, sample: card.line)
                }
                // 「Bella」 is not printed (the title says who she is) but is still read first.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: [TourText.speaker, card.title, card.line].joined(separator: "\n")))
                .accessibilityFocused($reads)
                .accessibilityIdentifier("tour-page-words")
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .tourPageFoot {
            VStack(spacing: 4) {
                TourNoteButtonRow(quietTitle: placeholder ? nil : first ? TourText.skipAll : TourText.skip, solidTitle: startTitle,
                                  quietID: first ? "tour-page-skip-all" : "tour-page-skip", solidID: "tour-page-start",
                                  quiet: first ? coordinator.skipAll : coordinator.skip, solid: coordinator.next)
                if !first, !placeholder {
                    Button(TourText.skipAll, action: coordinator.skipAll)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("tour-page-skip-all")
                }
            }
        }
    }

    private func stepPage(_ step: TourStep, _ showing: TourCoordinator.Showing) -> some View {
        TourPageScroll(flash: step.id) {
            VStack(spacing: 16) {
                TourNotePortrait(image: step.art.head(bubbleAbove: false), name: TourText.speaker, size: 88)
                    .padding(.top, 12)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("第 \(showing.bubbleNumber) 步，共 \(showing.bubbleCount) 步")
                        .font(.footnote)
                        .foregroundStyle(Color.subtle)
                        .tourPageLines(.footnote, sample: step.line)
                    Text(verbatim: step.pageLine ?? step.line)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .tourPageLines(.body, sample: step.pageLine ?? step.line)
                    if step.pageLine == nil, let place = step.place {
                        Text(verbatim: place)
                            .font(.callout)
                            .foregroundStyle(Color.subtle)
                            .multilineTextAlignment(.center)
                            .tourPageLines(.callout, sample: place)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityFocused($reads)
                .accessibilityIdentifier("tour-page-words")
                .accessibilitySortPriority(3)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .tourPageFoot {
            VStack(spacing: 4) {
                Button(action: coordinator.next) {
                    Text(verbatim: showing.nextTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(TourNoteSolidButtonStyle(fillsWidth: true))
                .accessibilityIdentifier("tour-page-next")
                .accessibilitySortPriority(2)
                // 【上一步】 and 【跳过这一段】 share a line, their words no larger than AX1, so the bar
                // leaves the screen to the words (VISUAL §14.1: 172 pt, 26 % of an iPhone SE, before).
                // Two lines only when one cannot hold them unbroken.
                let back = showing.bubbleNumber > 1 || TourScript.hasCard(showing.run.chapter) || showing.run.mode == .replay
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { quietButtons(back: back, wraps: false, spaced: true) }
                    VStack(spacing: 4) { quietButtons(back: back, wraps: true, spaced: false) }
                }
                .frame(maxWidth: .infinity)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
        }
    }

    @ViewBuilder
    private func quietButtons(back: Bool, wraps: Bool, spaced: Bool) -> some View {
        // On one line 【上一步】 is at the left and 【跳过这一段】 at the right, each as wide as its
        // words; stacked, both are the bar's width.
        if back {
            Button(action: coordinator.back) { quietTitle(TourText.back, wraps: wraps) }
                .buttonStyle(TourNoteQuietButtonStyle(alignment: .center, fillsWidth: !spaced))
                .accessibilityIdentifier("tour-page-back")
                .accessibilitySortPriority(1.5)
            if spaced { Spacer(minLength: 16) }
        }
        Button(action: coordinator.skip) { quietTitle(TourText.skip, wraps: wraps) }
            .buttonStyle(TourNoteQuietButtonStyle(alignment: .center, fillsWidth: !spaced))
            .accessibilityIdentifier("tour-page-skip")
            .accessibilitySortPriority(1)
    }

    private func quietTitle(_ words: String, wraps: Bool) -> some View {
        Text(verbatim: words)
            .lineLimit(wraps ? nil : 1)
            .fixedSize(horizontal: !wraps, vertical: true)
    }
}

extension View {
    /// The buttons at the foot of a tour page, below the page's scrolling words rather than over
    /// them: at the largest text sizes the words run longer than the screen, and a bar laid over
    /// them left 【跳过这一段】 under the words for touch and VoiceOver alike (QA_T2 F3). On paper
    /// of their own with an edge above, as the bar of FurnitureDetailView.
    func tourPageFoot<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        VStack(spacing: 0) {
            self
            bar().tourPageBar()
        }
    }

    func tourPageBar() -> some View {
        // The buttons stop growing at AX3 and leave the screen to the words (VISUAL §12.2 a): at
        // AX5 in English the bar took 251 pt, 29 % of an iPhone 17 Pro. Still at least 44 pt.
        dynamicTypeSize(...DynamicTypeSize.accessibility3)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background { RoomPaper.paper.ignoresSafeArea(edges: .bottom) }
            .overlay(alignment: .top) { Divider().overlay(RoomPaper.edge) }
    }
}

/// The scrolling words of a tour page. When they run longer than the room above the buttons, the
/// part shown is whole lines and a half (VISUAL §10.1, §13.4 item 3): the cut falls in the middle of
/// a line, so the next line shows half and is faded, and the room left over goes above the buttons.
/// Below the top once scrolled, half a line fades too; the scroll indicator flashes as the page
/// appears, as in the bubble.
struct TourPageScroll<Content: View>: View {
    private struct Cuts: Equatable {
        var top = false
        var bottom = false
    }

    private struct Flash: Equatable {
        var page: String
        var scrolls: Bool
    }

    private struct Fit: Equatable {
        var content: CGFloat = 0
        var insets: CGFloat = 0
    }

    /// Changes with the page, so the indicator flashes on each one that scrolls.
    let flash: String
    /// Words that fit stand in the middle of the room, not at its top.
    var centered = false
    @ViewBuilder let content: Content
    @State private var cuts = Cuts()
    @State private var room: CGFloat = 0
    @State private var fit = Fit()
    @State private var lines: [TourPageLines] = []
    /// A line of the page's body text, until the lines have been measured.
    @ScaledMetric(relativeTo: .body) private var line: CGFloat = 22

    var body: some View {
        let cut = self.cut
        Color.clear
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { room = $0 }
            .overlay(alignment: .top) {
                ScrollView {
                    content
                        .coordinateSpace(.named(TourPageLines.space))
                        .onPreferenceChange(TourPageLinesKey.self) { lines = $0 }
                        .frame(minHeight: centered ? max(room - fit.insets, 0) : 0)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicatorsFlash(trigger: Flash(page: flash, scrolls: cuts.top || cuts.bottom))
                .onScrollGeometryChange(for: Cuts.self) { geometry in
                    let shown = geometry.visibleRect
                    return Cuts(top: shown.minY > 0.5, bottom: shown.maxY < geometry.contentSize.height - 0.5)
                } action: { _, new in
                    cuts = new
                }
                .onScrollGeometryChange(for: Fit.self) { geometry in
                    Fit(content: geometry.contentSize.height, insets: geometry.contentInsets.top + geometry.contentInsets.bottom)
                } action: { _, new in
                    fit = new
                }
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: cuts.top ? cut.fade : 0)
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: cuts.bottom ? cut.fade : 0)
                    }
                }
                .frame(height: room > 0 ? cut.height : nil)
            }
    }

    /// How tall the scrolling part is, and how much of it fades: half of the line the cut falls in.
    private var cut: (height: CGFloat, fade: CGFloat) {
        let shown = room - fit.insets
        guard room > 0, fit.content > shown + 0.5, !lines.isEmpty else { return (room, line / 2) }
        let blocks = lines.sorted { $0.top < $1.top }
        // Half of the last line of the block before: the cut never falls in a gap, where nothing
        // would show that more follows.
        func lastHalf(before index: Int) -> (CGFloat, CGFloat)? {
            guard index > 0 else { return nil }
            let before = blocks[index - 1]
            return (before.bottom - before.pitch / 2, before.pitch)
        }
        var found: (CGFloat, CGFloat)?
        for (index, block) in blocks.enumerated() {
            if shown < block.top {
                found = lastHalf(before: index)
                break
            }
            if shown <= block.bottom {
                let whole = ((shown - block.top) / block.pitch - 0.5).rounded(.down)
                found = whole >= 0 ? (block.top + (whole + 0.5) * block.pitch, block.pitch) : lastHalf(before: index)
                break
            }
        }
        // Never less than half the room: a very tall first block keeps the old cut.
        guard let (edge, pitch) = found, edge >= shown / 2 else { return (room, line / 2) }
        return (edge + fit.insets, pitch / 2)
    }
}

/// Where a block of words is on its page, and the distance from one of its lines to the next.
struct TourPageLines: Equatable {
    static let space = "tour-page-words"
    var top: CGFloat
    var bottom: CGFloat
    var pitch: CGFloat
}

private struct TourPageLinesKey: PreferenceKey {
    static let defaultValue: [TourPageLines] = []
    static func reduce(value: inout [TourPageLines], nextValue: () -> [TourPageLines]) { value += nextValue() }
}

private struct TourPageLinesReader: ViewModifier {
    let font: Font
    /// A character from the words, so the measured line is the one the words are set in: Chinese
    /// falls back to another font with taller lines than the Latin one.
    let sample: String
    @State private var one: CGFloat = 0
    @State private var two: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Text(verbatim: sample).font(font).fixedSize()
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { one = $0 }
                    Text(verbatim: sample + "\n" + sample).font(font).fixedSize()
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { two = $0 }
                }
                .hidden()
                .accessibilityHidden(true)
            }
            .background {
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .named(TourPageLines.space))
                    Color.clear.preference(key: TourPageLinesKey.self,
                                           value: two > one ? [TourPageLines(top: frame.minY, bottom: frame.maxY, pitch: two - one)] : [])
                }
            }
    }
}

extension View {
    /// Reports this block's lines to the page around it, so the page can cut in the middle of one.
    func tourPageLines(_ font: Font, sample: String) -> some View {
        modifier(TourPageLinesReader(font: font, sample: String(sample.trimmingCharacters(in: .whitespaces).first ?? "A")))
    }
}
