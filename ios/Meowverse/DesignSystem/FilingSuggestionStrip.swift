import SwiftUI

// The entry to suggested filing (round 8), pinned at the top of the one-photo review screen with
// `.safeAreaInset(edge: .top)`. One component, two states:
//
// * `.suggestions` — "按建议放进家具 · 12 张": opens the confirmation page.
// * `.round` — during the representative round: the quiet counter "代表照片 3 / 10" and, beside
//   it, "已可建议 12 张", which grows as the user files photos and also opens the page.
//
// Nothing under the finger moves when the count changes: the title is fixed text, the count sits
// in a badge with a minimum width and tabular digits, and the note reserves the height of its
// longest wording. Values in, closures out; nothing here reads the app model.

struct FilingSuggestionStrip: View {
    enum Mode: Equatable {
        case suggestions
        /// `index` is the representative photo on screen, 1-based, of `total`.
        case round(index: Int, total: Int)
    }

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: Mode
    /// Photos that have a suggested piece right now.
    let count: Int
    /// The device is still comparing photos, so `count` may grow.
    var comparing: Bool = false
    /// Nothing is offered and the comparison didn't finish: the note says so and there is no "暂无".
    var unfinished: Bool = false
    /// The screen already says, in a footnote, that the comparison may be wrong; the note then
    /// leaves out its own "可能有错". Keep it false wherever no such footnote is shown.
    var cautionShownNearby: Bool = false
    /// Opens the confirmation page. Not called while `count` is 0.
    let open: () -> Void

    private var canOpen: Bool { count > 0 }
    private var saysUnfinished: Bool { mode == .suggestions && unfinished && !comparing && count == 0 }

    var body: some View {
        Button(action: open) {
            content
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        }
        .buttonStyle(PaperSlipStyle(accent: canOpen ? RoomPaper.moss.opacity(0.45) : RoomPaper.edge))
        .disabled(!canOpen)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 6)
        // Pinned above the photo: it grows with text up to a point, as the room caption does.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(canOpen ? Text("打开建议，逐张确认后再放进家具") : Text(""))
        .accessibilityIdentifier(mode == .suggestions ? "filing-suggestions-entry" : "representative-round-strip")
    }

    @ViewBuilder
    private var content: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))
        layout {
            if !typeSize.isAccessibilitySize { StackOfPrints().frame(width: 34, height: 34) }
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(RoomPaper.ink)
                // Every wording of the mode is laid out and only one is shown, so the strip keeps
                // one height when comparing finishes.
                // At accessibility sizes the note goes (VoiceOver still reads it in the label), so
                // the strip does not take a third of the screen above the photo; unless it is all
                // the strip has to say (a comparison that didn't finish, where the badge is blank).
                if !typeSize.isAccessibilitySize || saysUnfinished {
                    ZStack(alignment: .topLeading) {
                        switch mode {
                        case .suggestions:
                            Text("本机比对，可能有错，由你确认").hidden(ifNot: !comparing && !saysUnfinished && !cautionShownNearby)
                            Text("本机比对，由你确认").hidden(ifNot: !comparing && !saysUnfinished && cautionShownNearby)
                            Text("还在比对，可能会再多几张").hidden(ifNot: comparing)
                            Text("这次没能完成比对").hidden(ifNot: saysUnfinished)
                        case .round:
                            Text("放好的照片会带来建议")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(RoomPaper.note)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            badge.hidden(ifNot: !saysUnfinished)
        }
    }

    private var title: Text {
        switch mode {
        case .suggestions: Text("按建议放进家具")
        case .round(let index, let total): Text("代表照片 \(index) / \(total)")
        }
    }

    /// The count in a pill. Its width is that of three digits and the chevron, so 0 → 1 → 10 → 100
    /// moves nothing. While it cannot be opened ("暂无", "已可建议 0 张") there is no pill, only
    /// the text, in the same width.
    private var badge: some View {
        ZStack {
            badgeLabel(count: 888, chevron: true).hidden().accessibilityHidden(true)
            badgeLabel(count: count, chevron: canOpen)
                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(count)))
                .animation(reduceMotion ? nil : .snappy, value: count)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .foregroundStyle(canOpen ? RoomPaper.sealInk : RoomPaper.ink.opacity(0.75))
        .background {
            if canOpen { Capsule().fill(RoomPaper.moss) }
        }
        .fixedSize()
    }

    private func badgeLabel(count: Int, chevron: Bool) -> some View {
        HStack(spacing: 4) {
            Group {
                switch mode {
                case .suggestions where count == 0: Text("暂无")
                case .suggestions: Text("\(count) 张")
                case .round: Text("已可建议 \(count) 张")
                }
            }
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            if chevron {
                Image(systemName: "chevron.forward").font(.caption.weight(.bold))
            }
        }
    }

    private var accessibilityLabel: Text {
        switch mode {
        case .suggestions where saysUnfinished:
            return Text("按建议放进家具，这次没能完成比对。")
        case .suggestions:
            // Reads what is shown: "暂无" rather than "0 张", and the note on screen.
            let note = comparing ? Text("还在比对，可能会再多几张")
                : cautionShownNearby ? Text("本机比对，由你确认") : Text("本机比对，可能有错，由你确认")
            let entry = count == 0 ? Text("按建议放进家具，暂无。") : Text("按建议放进家具，\(count) 张。")
            return entry + note
        case .round(let index, let total):
            return Text("代表照片，第 \(index) 张，共 \(total) 张。已可建议 \(count) 张。") + Text("放好的照片会带来建议")
        }
    }
}

/// A wide paper slip that can be tapped: `sheet` paper, corner 14, a 1 pt stroke in `accent`.
/// Pressed, the paper turns `flyleaf` (no scale: a full-width row shrinking reads as a jump).
struct PaperSlipStyle: ButtonStyle {
    var accent: Color = RoomPaper.edge

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: RoomPaper.bookplateCorner, style: .continuous)
        configuration.label
            .background {
                shape.fill(configuration.isPressed ? RoomPaper.flyleaf : RoomPaper.sheet)
                    .overlay { shape.strokeBorder(accent, lineWidth: 1) }
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            }
            .contentShape(shape)
    }
}

private extension View {
    /// Keeps the view's size in layout but draws nothing when `shown` is false.
    func hidden(ifNot shown: Bool) -> some View {
        opacity(shown ? 1 : 0).accessibilityHidden(!shown)
    }
}

/// Two prints on a third, in the photo-mat paper with a mount corner: the "photos with a place to
/// go" glyph of the strip. Drawn, decorative, no text.
struct StackOfPrints: View {
    var body: some View {
        ZStack {
            print.rotationEffect(.degrees(-10)).offset(x: -3, y: 1)
            print.rotationEffect(.degrees(7)).offset(x: 3, y: -1)
            print
                .overlay(alignment: .topLeading) {
                    Path { p in
                        p.move(to: .zero)
                        p.addLine(to: CGPoint(x: 7, y: 0))
                        p.addLine(to: CGPoint(x: 0, y: 7))
                        p.closeSubpath()
                    }
                    .fill(RoomPaper.mount)
                    .frame(width: 7, height: 7)
                    .padding(2)
                }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var print: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(RoomPaper.photoMat)
            .overlay {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(RoomPaper.moss.opacity(0.35))
                    .padding(4)
                    .padding(.bottom, 3)
            }
            .overlay { RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(RoomPaper.edge, lineWidth: 1) }
            .frame(width: 22, height: 26)
            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
    }
}
