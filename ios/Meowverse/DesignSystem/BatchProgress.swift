import SwiftUI

// Progress of a batch of photos (round 8): one compact bar that sits above the review screen's
// bottom action while the user keeps sorting, and a full page for the moment nothing else can be
// done yet. Values in, closures out; nothing here reads the app model.

/// What the batch is doing. The count is always "done of total" for that phase.
enum BatchPhase: Equatable {
    /// Copying the chosen photos into Meowverse.
    case importing
    /// Comparing the imported photos with the photos already in furniture, on this device.
    case recognizing

    /// "导入中 12 / 200" — the bar's one line.
    func line(done: Int, total: Int) -> Text {
        switch self {
        case .importing: Text("导入中 \(done) / \(total)")
        case .recognizing: Text("识别中 \(done) / \(total)")
        }
    }

    /// The phase alone, for VoiceOver's label (the count goes in the value).
    var name: Text {
        switch self {
        case .importing: Text("正在导入照片")
        case .recognizing: Text("正在识别照片")
        }
    }

    var stopTitle: Text {
        switch self {
        case .importing: Text("停止导入")
        case .recognizing: Text("停止识别")
        }
    }

    var stopHint: Text {
        switch self {
        case .importing: Text("停止导入。已经导入的照片会保留。")
        case .recognizing: Text("停止识别。照片和已经做好的整理都会保留。")
        }
    }
}

/// A paper groove with a moss fill: the bar's and the cover's progress. Decorative; the text
/// beside it carries the count for VoiceOver.
struct PaperProgressTrack: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let done: Int
    let total: Int
    var height: CGFloat = 8

    private var fraction: CGFloat {
        total > 0 ? min(max(CGFloat(done) / CGFloat(total), 0), 1) : 0
    }

    var body: some View {
        Capsule()
            .fill(RoomPaper.flyleaf)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(RoomPaper.moss)
                        // A started batch always shows a sliver, so "running" never reads as empty.
                        .frame(width: max(fraction * proxy.size.width, done > 0 ? height : 0))
                }
            }
            .overlay { Capsule().strokeBorder(RoomPaper.edge, lineWidth: 1) }
            .frame(height: height)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: fraction)
            .accessibilityHidden(true)
    }
}

/// The compact indicator: phase and count on one line, a thin track under it, and 停止. It goes
/// above the review screen's bottom action (where `ImportQueueBar` sits over the room), so the
/// photo being reviewed stays usable underneath. Its height does not change as the count grows.
///
///     BatchProgressBar(phase: .recognizing, done: 37, total: 200) { model.cancelRecognition() }
struct BatchProgressBar: View {
    let phase: BatchPhase
    let done: Int
    let total: Int
    /// Why the count is not moving, when there is a reason to give (e.g. photos coming from iCloud).
    var note: Text?
    /// `nil` hides 停止, e.g. for a phase that cannot be stopped.
    var cancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                phase.line(done: done, total: total)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(RoomPaper.ink)
                PaperProgressTrack(done: done, total: total, height: 6)
                if let note {
                    note.font(.footnote)
                        .foregroundStyle(RoomPaper.ink.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("batch-waiting")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(phase.name)
            .accessibilityValue(note.map { Text("\(done) / \(total)。") + $0 } ?? Text("\(done) / \(total)"))
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("batch-progress")
            if let cancel {
                // One short word beside the count; the full name is what VoiceOver reads.
                Button(action: cancel) { Text("停止") }
                    .buttonStyle(.roomFolio(.secondary))
                    .accessibilityLabel(phase.stopTitle)
                    .accessibilityHint(phase.stopHint)
                    .accessibilityIdentifier("batch-cancel")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(RoomPaper.paper)
        .overlay(alignment: .top) { Divider().overlay(RoomPaper.edge) }
        // It shares the bottom with the page's main button; past this size the two would cover
        // the photo being reviewed.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
    }
}

/// The full page, only while there is nothing else to do: before the first photo of a batch can be
/// reviewed. The album sways a little; with Reduce Motion it stands still. `note` says what happens
/// next ("第一张准备好就可以开始整理").
struct BatchProgressCover: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let phase: BatchPhase
    let done: Int
    let total: Int
    var note: Text?
    var cancel: (() -> Void)?
    @State private var sway = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                MemoryEmblem(.album)
                    .frame(width: 150, height: 112)
                    .rotationEffect(.degrees(reduceMotion ? 0 : (sway ? 2.5 : -2.5)), anchor: .bottom)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: sway)
                    .onAppear { sway = true }
                    .padding(.top, typeSize.isAccessibilitySize ? 8 : 40)
                VStack(spacing: 10) {
                    phase.name
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(done) / \(total)")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(RoomPaper.note)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .default, value: done)
                        .accessibilityHidden(true)
                    PaperProgressTrack(done: done, total: total, height: 10)
                        .frame(maxWidth: 280)
                        .padding(.top, 4)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(phase.name)
                .accessibilityValue(Text("\(done) / \(total)"))
                .accessibilityAddTraits([.updatesFrequently, .isHeader])
                .accessibilityIdentifier("batch-progress-cover")
                if let note {
                    note
                        .font(.subheadline)
                        .foregroundStyle(RoomPaper.note)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320)
                }
                if let cancel {
                    Button(action: cancel) { phase.stopTitle }
                        .buttonStyle(.roomFolio(.secondary))
                        .accessibilityHint(phase.stopHint)
                        .accessibilityIdentifier("batch-cancel")
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(RoomPaper.ink)
        .fontDesign(.rounded)
        .memoryPage(.album)
    }
}
