import SwiftUI

/// The card that opens a chapter (VISUAL §4, §8.4, §9.1): the same paper as a bubble with no tail and
/// no cutout. From the top: Bella's whole-body picture in a 180 × 120 slot, the title in the title
/// face, one sentence, and two buttons with the quiet one on the left. An optional third exit
/// (「全部跳过」 on an on-demand chapter) is a small underlined line of words centred under them, its
/// hit area the words only (at least 44 × 44), so a thumb that misses 「开始」 does not skip fifteen
/// chapters.
///
/// The card has no portrait and no name row: the picture is already Bella. VoiceOver still meets
/// `speaker` first, as an element of its own over the top of the card.
///
/// Every string comes from the caller, already localised. Put it over `TourNoteMask(strength: .card)`,
/// centred a little below the middle of the screen, with 16 pt of margin on iPhone. Insert and remove
/// it with `.transition(.tourNote(tail: nil, reduceMotion:))`: a fade, with no movement.
///
/// At accessibility text sizes the picture hides and the buttons stack. Pass `maxHeight` (70 % of the
/// screen, `TourNoteMetrics.tallestShare`): a title and sentence that still do not fit scroll inside
/// the card, fading at the edge where they are cut.
struct TourChapterCard: View {
    struct Exit {
        let title: String
        let action: () -> Void
    }

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var widthClass
    /// Where the sentence starts in the words, for snapping their scroll window to its lines.
    @State private var titleHeight: CGFloat = 0

    /// Not shown; read first by VoiceOver.
    let speaker: String
    /// Not drawn: cards carry no portrait since VISUAL §9.1. Kept so callers need not change.
    var portrait: Image?
    /// The chapter's picture (`BellaBody.greeting.image`), shown whole in the 3:2 slot. nil draws the
    /// slot as a placeholder.
    var illustration: Image?
    let title: String
    let line: String
    var maxHeight: CGFloat?
    /// 「跳过这一段」, or 「全部跳过」 on the first chapter; nil on a placeholder card.
    let later: Exit?
    /// 「开始」.
    let start: Exit
    var skipAll: Exit?

    var body: some View {
        let paper = RoundedRectangle(cornerRadius: RoomPaper.cardCorner, style: .continuous)
        let shadow = TourNoteMetrics.bubbleShadow
        VStack(alignment: .leading, spacing: 10) {
            if !typeSize.isAccessibilitySize {
                TourChapterIllustration(image: illustration)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 2)
            }
            words
            VStack(spacing: 0) {
                TourNoteButtonRow(quietTitle: later?.title, solidTitle: start.title, quietID: "tour-card-later",
                              solidID: "tour-card-start", quiet: later?.action ?? {}, solid: start.action)
                if let skipAll {
                    Button(action: skipAll.action) {
                        Text(verbatim: skipAll.title)
                            .font(.system(.footnote, design: .rounded, weight: .medium))
                            .foregroundStyle(RoomPaper.note)
                            .underline()
                            .multilineTextAlignment(.center)
                            .frame(minWidth: TourNoteMetrics.hitSize, minHeight: TourNoteMetrics.hitSize)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tour-card-skip-all")
                    // Centred in the row, but only the words (at least 44 × 44) take the tap.
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .overlay(alignment: .topLeading) { speakerForVoiceOver }
        .padding(TourNoteMetrics.bubblePadding)
        .padding(.bottom, skipAll == nil ? 0 : -8)
        .frame(maxWidth: TourNoteMetrics.bubbleMaxWidth(regular: widthClass == .regular))
        .tourNoteHeight(atMost: maxHeight)
        .background {
            paper.fill(RoomPaper.sheet)
                .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
        }
        .overlay { paper.stroke(RoomPaper.edge, lineWidth: 1) }
        .geometryGroup()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tour-card")
    }

    /// "Bella", for VoiceOver only: drawn in clear ink over the top of the card, where the picture
    /// (or at accessibility sizes the title) is, and first in the card's reading order.
    private var speakerForVoiceOver: some View {
        Text(verbatim: speaker)
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(.clear)
            .allowsHitTesting(false)
            .accessibilityIdentifier("tour-card-speaker")
            .accessibilitySortPriority(4)
    }

    private var words: some View {
        let text = VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(RoomTitleFont.font(for: title, size: 24, relativeTo: .title2, maximum: 30, typeSize: typeSize))
                // The system spaces a full-width comma in the title face half a character too wide
                // (34.1 pt for the font's 22.1 at 24 pt). Any kern set on the text turns that off
                // (VISUAL §9.1), but SwiftUI drops `.kerning(0)` as if unset (measured: the gap after
                // 「，」 stays 28.0 pt with 0, falls to 16.0 pt with 0.001), so the kern is a hair over 0.
                .kerning(0.001)
                .foregroundStyle(RoomPaper.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("tour-card-title")
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titleHeight = $0 }
            Text(verbatim: line)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(RoomPaper.ink)
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        return TourNoteWords(sample: line, lead: titleHeight + 6) { text }
            .accessibilitySortPriority(3)
    }
}

/// The chapter illustration's place: 180 × 120, 3:2. The drawing is fitted whole, on the card's own
/// paper. With no drawing yet it shows the slot itself: `flyleaf` paper inside a stitched `edge` line.
struct TourChapterIllustration: View {
    var image: Image?

    var body: some View {
        let size = TourNoteMetrics.illustrationSize
        Group {
            if let image {
                image.renderingMode(.original).resizable().scaledToFit()
            } else {
                let frame = RoundedRectangle(cornerRadius: 8, style: .continuous)
                frame.fill(RoomPaper.flyleaf)
                    .overlay { frame.strokeBorder(RoomPaper.edge, style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
                    .overlay {
                        Text(verbatim: "3 : 2")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(RoomPaper.note)
                    }
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Chapter card") {
    ZStack {
        Color(red: 0.96, green: 0.93, blue: 0.87).ignoresSafeArea()
        TourNoteMask(base: .bright, strength: .card).ignoresSafeArea()
        TourChapterCard(speaker: "Bella", illustration: BellaBody.company.image, title: "Keep Kitty with you",
                        line: "Even with the app closed, Kitty can keep you company on the Lock Screen.",
                        later: .init(title: "Skip this part") {}, start: .init(title: "Start") {},
                        skipAll: .init(title: "Skip all") {})
            .padding(TourNoteMetrics.bubbleMargin)
    }
}

#Preview("Chapter card, AX3") {
    GeometryReader { proxy in
        TourChapterCard(speaker: "Bella", title: "Hi, I’m Bella",
                        line: "I’m the guide around here. Let me show you around this little room.",
                        maxHeight: proxy.size.height * TourNoteMetrics.tallestShare,
                        later: .init(title: "Skip all") {}, start: .init(title: "Start") {})
            .padding(TourNoteMetrics.bubbleMargin)
            .frame(maxHeight: .infinity)
    }
    .background(RoomPaper.leaf)
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
