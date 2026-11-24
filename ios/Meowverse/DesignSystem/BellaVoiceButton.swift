import SwiftUI

/// What Talk to Bella is doing, as the 2D head shows it (docs/TALK_TO_BELLA.md).
enum BellaVoiceState: Equatable {
    /// Waiting to be tapped.
    case idle
    /// Microphone open. `level` 0...1 is the input loudness, for a gentle ear or halo pulse.
    case listening(level: Double)
    /// Heard a sentence; deciding what it means.
    case thinking
    /// Understood and sent to the cat: a small nod, then back to idle.
    case understood
    /// Not understood, or the room cannot do it: a head tilt, then back to idle.
    case puzzled
    /// Speech recognition or the microphone is not available on this device or is off.
    case unavailable
}

/// The floating 2D cat head in the room's corner. Appearance only: the caller supplies the
/// state, the VoiceOver label and value, and the tap.
///
/// The head is the pocket cat's 20 px face (`PocketCatPortrait`) at 40 pt, which is a whole
/// number of screen pixels per art pixel on 2× and 3× alike (one art pixel = 2 pt), in the
/// companion page's dark green window, on the room's paper with its edge and shadow, so it sits
/// with 互动 and 添加照片 below it. 54 pt square; the rings and seals reach about 6 pt past it.
/// Review: art/ui/reviews/r12-talk-to-bella.md (A1–A4).
///
/// | State | Face | Shown by |
/// | --- | --- | --- |
/// | idle | watching | nothing else |
/// | listening | watching | a solid moss ring hugging the paper edge, 2 + 4·level pt; at rest it eases 2–2.5 pt |
/// | thinking | thinking | a stitched moss ring 3.5 pt off the edge whose stitches walk round |
/// | understood | watching | one nod (4, 0, 2, 0 pt), and a moss seal with a tick |
/// | puzzled | watching | an 8° tilt held 0.5 s then upright, and a clay seal with a question mark |
/// | unavailable | sleeping, in colour | a flyleaf seal with `mic.slash`; paper as idle, still a button |
///
/// Reduce Motion: no loop, no nod, no tilt; the ring is a fixed 3 pt and the seals and rings
/// switch without animating. Reduce Transparency: nothing here is see-through. Press:
/// `RoomTokenButtonStyle`, as the top band. The pixels never rest rotated (art-craft).
struct BellaVoiceButton: View {
    let state: BellaVoiceState
    let accessibilityLabel: Text
    let accessibilityValue: Text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BellaVoiceHead(state: state)
        }
        .buttonStyle(.roomToken)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("talk-to-bella")
        .accessibilityShowsLargeContentViewer {
            Label { accessibilityLabel } icon: { Image(PocketCatArt.face.imageName(.watching)) }
        }
    }
}

/// The short line beside the head when Bella cannot do what was asked ("房间里还没有沙发"). A paper
/// slip with a small tail on its trailing side, pointing at the head. Two lines at most, type up
/// to accessibility2, at most 240 pt wide. The caller places it to the leading side of the head,
/// clear of it, and owns the words.
struct BellaVoiceHint: View {
    let text: Text

    var body: some View {
        text
            .font(.system(.footnote, design: .rounded, weight: .semibold))
            .foregroundStyle(RoomPaper.ink)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .padding(.trailing, BellaHintSlip.tail)
            .background {
                let slip = BellaHintSlip()
                slip.fill(RoomPaper.paper)
                    .overlay { slip.stroke(RoomPaper.edge, lineWidth: 1) }
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 2)
                    .flipsForRightToLeftLayoutDirection(true)
            }
            .frame(maxWidth: 240, alignment: .trailing)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

#if DEBUG
extension EnvironmentValues {
    /// DEBUG gallery only: draws the head as under Reduce Motion without changing the system setting.
    @Entry var bellaPreviewsReduceMotion = false
}
#endif

// MARK: - Drawing

private enum BellaVoiceMetrics {
    /// 20 art pixels at 2 pt each: 4 px/pixel on 2×, 6 px/pixel on 3×.
    static let face: CGFloat = 40
    /// Dark green window round the face, as on the companion page (art-craft: pixel cats on
    /// light paper always sit in it).
    static let windowInset: CGFloat = 4
    static let windowCorner: CGFloat = 11
    static let paperInset: CGFloat = 3
    static let paperCorner = RoomPaper.bookplateCorner
    static let window = Color(red: 0x29 / 255, green: 0x3B / 255, blue: 0x30 / 255)
    static var plate: CGFloat { face + 2 * (windowInset + paperInset) }
}

private struct BellaVoiceHead: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    #if DEBUG
    @Environment(\.bellaPreviewsReduceMotion) private var previewReduceMotion
    #else
    private let previewReduceMotion = false
    #endif
    @Environment(\.roomPaperPressed) private var pressed
    let state: BellaVoiceState
    @State private var nods = 0
    @State private var tilts = 0

    private enum Kind: Equatable { case idle, listening, thinking, understood, puzzled, unavailable }

    private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }

    private var kind: Kind {
        switch state {
        case .idle: .idle
        case .listening: .listening
        case .thinking: .thinking
        case .understood: .understood
        case .puzzled: .puzzled
        case .unavailable: .unavailable
        }
    }

    private var level: Double {
        if case .listening(let level) = state { min(max(level, 0), 1) } else { 0 }
    }

    private var mood: PocketCatMood {
        switch kind {
        case .thinking: .thinking
        case .unavailable: .sleeping
        default: .watching
        }
    }

    /// Only listening and thinking move on their own, and not under Reduce Motion.
    private var loops: Bool { !reduceMotion && (kind == .listening || kind == .thinking) }

    var body: some View {
        TimelineView(.animation(paused: !loops)) { context in
            let time = loops ? context.date.timeIntervalSinceReferenceDate : 0
            plate
                .background { ring(time: time) }
        }
        // The tilt is a gesture, never a resting pose: rotated pixels stair-step (A4).
        .keyframeAnimator(initialValue: 0.0, trigger: tilts) { head, angle in
            head.rotationEffect(.degrees(angle), anchor: .bottom)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(-8, duration: 0.18, spring: .snappy)
                LinearKeyframe(-8, duration: 0.5)
                SpringKeyframe(0, duration: 0.3, spring: .bouncy)
            }
        }
        .overlay(alignment: .topTrailing) { seal.offset(x: 6, y: -6) }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.3), value: kind)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        .frame(width: BellaVoiceMetrics.plate, height: BellaVoiceMetrics.plate)
        .contentShape(.rect(cornerRadius: BellaVoiceMetrics.paperCorner))
        .onChange(of: kind) { _, now in
            guard !reduceMotion else { return }
            if now == .understood { nods += 1 }
            if now == .puzzled { tilts += 1 }
        }
    }

    private var plate: some View {
        let paper = RoundedRectangle(cornerRadius: BellaVoiceMetrics.paperCorner, style: .continuous)
        return PocketCatPortrait(mood: mood, size: BellaVoiceMetrics.face)
            .keyframeAnimator(initialValue: CGFloat(0), trigger: nods) { face, dip in
                face.offset(y: dip)
            } keyframes: { _ in
                // 2 pt = one art pixel at 40 pt.
                KeyframeTrack {
                    CubicKeyframe(4, duration: 0.14)
                    CubicKeyframe(0, duration: 0.16)
                    CubicKeyframe(2, duration: 0.12)
                    CubicKeyframe(0, duration: 0.18)
                }
            }
            .padding(BellaVoiceMetrics.windowInset)
            .background(BellaVoiceMetrics.window,
                        in: .rect(cornerRadius: BellaVoiceMetrics.windowCorner, style: .continuous))
            .padding(BellaVoiceMetrics.paperInset)
            .background {
                paper.fill(pressed ? RoomPaper.flyleaf : RoomPaper.paper)
                    .overlay { paper.strokeBorder(RoomPaper.edge, lineWidth: 1) }
                    .shadow(color: .black.opacity(0.16), radius: 1.5, y: 1.5)
            }
    }

    /// Drawn behind the plate in the same rounded shape.
    @ViewBuilder
    private func ring(time: TimeInterval) -> some View {
        switch kind {
        case .listening:
            // One quantity follows the voice: the width, 2–6 pt. Its inner edge sits on the
            // paper edge, so edge and ring read as one thick moss rim, not two lines (A2). With
            // the room quiet it eases between 2 and 2.5 pt over 1.6 s to show the mic is open.
            // The larger of the two, so noise hovering near silence does not make it jump.
            let width: CGFloat = reduceMotion ? 3 : max(2 + 0.25 * (1 - cos(time * 2 * .pi / 1.6)), 2 + 4 * level)
            outset(width / 2).stroke(RoomPaper.moss, lineWidth: width)
        case .thinking:
            // A stitched seam, like the 互动 paw, 3.5 pt off the edge, walking round at 10 pt a second.
            outset(3.5)
                .stroke(RoomPaper.moss, style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                           dash: [4, 4], dashPhase: -time * 10))
        default:
            EmptyView()
        }
    }

    private func outset(_ distance: CGFloat) -> some Shape {
        RoundedRectangle(cornerRadius: BellaVoiceMetrics.paperCorner + distance, style: .continuous)
            .inset(by: -distance)
    }

    @ViewBuilder
    private var seal: some View {
        switch kind {
        case .understood: BellaSeal(symbol: "checkmark", fill: RoomPaper.moss, ink: RoomPaper.sealInk, rim: RoomPaper.paper)
        case .puzzled: BellaSeal(symbol: "questionmark", fill: RoomPaper.clay, ink: RoomPaper.sealInk, rim: RoomPaper.paper)
        case .unavailable: BellaSeal(symbol: "mic.slash", fill: RoomPaper.flyleaf, ink: RoomPaper.ink, rim: RoomPaper.edge)
        default: EmptyView()
        }
    }
}

/// A 20 pt coin on the plate's corner: tick for understood, question mark for puzzled, a crossed
/// microphone for unavailable. Shape and colour both differ, so none relies on colour alone.
private struct BellaSeal: View {
    let symbol: String
    let fill: Color
    let ink: Color
    let rim: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .black, design: .rounded))
            .foregroundStyle(ink)
            .frame(width: 20, height: 20)
            .background(fill, in: .circle)
            .overlay { Circle().strokeBorder(rim, lineWidth: 1.5) }
            .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
            .dynamicTypeSize(.large)
            .accessibilityHidden(true)
    }
}

/// The hint's paper: a rounded slip with a 6 pt tail at the middle of its trailing edge.
private nonisolated struct BellaHintSlip: Shape {
    static let tail: CGFloat = 6
    /// `RoomPaper.bookplateCorner`, spelled out: a Shape draws off the main actor.
    static let corner: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width - Self.tail, height: rect.height)
        let corner = min(Self.corner, body.height / 2)
        var path = Path(roundedRect: body, cornerRadius: corner, style: .continuous)
        let mid = body.midY
        var tail = Path()
        tail.move(to: CGPoint(x: body.maxX - 1, y: mid - 6))
        tail.addLine(to: CGPoint(x: rect.maxX, y: mid))
        tail.addLine(to: CGPoint(x: body.maxX - 1, y: mid + 6))
        tail.closeSubpath()
        path = path.union(tail)
        return path
    }
}
