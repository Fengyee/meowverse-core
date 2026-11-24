import MeowverseCore
import SwiftUI

/// Chapter 12's pages after its steps (12.5 to 12.7; VISUAL §17.2): a sheet over whatever is on
/// top, paged sideways, on page mode's paper. Each page: the picture (`TourCompanyDiagram`),
/// Bella's line on a note signed with her 44 pt head, the steps. The bar: 【跳过这一段】 and
/// 【下一步】, on the last page 「知道了」, which ends the chapter. Also page mode's last step.
struct TourCompanyPagesView: View {
    let pages: [TourCompanyPage]
    let conditions: TourCompanyConditions
    let liveActivitiesOn: Bool
    let isPad: Bool
    let skip: () -> Void
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var index = 0
    @AccessibilityFocusState private var reads: Bool

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $index) {
                ForEach(Array(pages.enumerated()), id: \.offset) { offset, page in
                    pageView(page).tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .tourPageFoot { bar }
        }
        .memoryPage(.home)
        .presentationDetents([.large])
        .accessibilityAction(.escape, skip)
        .onChange(of: index) { reads = true }
        .onAppear { reads = true }
    }

    private var isLast: Bool { index >= pages.count - 1 }

    private var bar: some View {
        VStack(spacing: 8) {
            TourNoteDots(step: index + 1, count: pages.count)
                .accessibilityHidden(true)
            TourNoteButtonRow(quietTitle: TourText.skip, solidTitle: isLast ? TourText.gotIt : TourText.next,
                              quietID: "tour-company-skip", solidID: isLast ? "tour-company-done" : "tour-company-next",
                              quiet: skip,
                              solid: {
                                  guard !isLast else { return done() }
                                  withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .default) { index += 1 }
                              })
        }
    }

    private func pageView(_ page: TourCompanyPage) -> some View {
        let words = TourScript.companyPage(page, conditions: conditions, liveActivitiesOn: liveActivitiesOn, isPad: isPad)
        return TourPageScroll(flash: "company-\(page.rawValue)") {
            VStack(spacing: 0) {
                Text(verbatim: words.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .tourPageLines(.title2.weight(.semibold), sample: words.title)
                    .padding(.bottom, 16)
                // Left out at accessibility text sizes, with its space (VISUAL 17.4).
                if TourCompanyDiagram.isShown(at: typeSize) {
                    TourCompanyDiagram(page: page, conditions: conditions)
                        .padding(.bottom, 20)
                }
                note(words)
                    .padding(.bottom, 16)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(words.steps.enumerated()), id: \.offset) { part, group in
                        VStack(alignment: .leading, spacing: 6) {
                            if words.titles.indices.contains(part) {
                                // 12.5: the same words as the captions in the picture (VISUAL 17.2).
                                Text(verbatim: words.titles[part])
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(RoomPaper.note)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(Array(group.enumerated()), id: \.offset) { number, step in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    if group.count > 1 {
                                        Text(verbatim: "\(number + 1)")
                                            .font(.callout.monospacedDigit().weight(.semibold))
                                            .foregroundStyle(RoomPaper.moss)
                                    }
                                    Text(verbatim: step).font(.callout).foregroundStyle(RoomPaper.ink)
                                }
                                .tourPageLines(.callout, sample: step)
                            }
                        }
                    }
                    if page == .iconShortcuts { shortcuts }
                    ForEach(words.notes, id: \.self) { line in
                        Text(verbatim: line).font(.callout).foregroundStyle(RoomPaper.ink)
                            .tourPageLines(.callout, sample: line)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
    }

    /// Bella's line on a note pinned to the paper: no tail, no shadow, no buttons (§17.2).
    private func note(_ words: TourScript.CompanyPage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if !typeSize.isAccessibilitySize {
                    TourNotePortrait(image: words.art.head(bubbleAbove: false), name: TourText.speaker)
                }
                Text(verbatim: TourText.speaker)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(RoomPaper.ink)
            }
            Text(verbatim: words.line)
                .font(.body)
                .foregroundStyle(RoomPaper.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tourPageLines(.body, sample: words.line)
        }
        .padding(16)
        .background(RoomPaper.sheet, in: .rect(cornerRadius: RoomPaper.cardCorner))
        .overlay { RoundedRectangle(cornerRadius: RoomPaper.cardCorner).strokeBorder(RoomPaper.edge, lineWidth: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [TourText.speaker, words.line].joined(separator: "\n")))
        .accessibilityFocused($reads)
        .accessibilityIdentifier("tour-company-line")
    }

    /// 12.7: the Home Screen items as this device lists them, closest to the icon first.
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(conditions.shortcuts, id: \.self) { kind in
                Label { Text(verbatim: kind.title) } icon: { kind.image.foregroundStyle(RoomPaper.moss) }
                    .labelStyle(TourShortcutLabelStyle())
                    .font(.callout)
                    .foregroundStyle(RoomPaper.ink)
                    .accessibilityIdentifier("tour-company-shortcut-\(kind.rawValue)")
            }
        }
    }
}

/// 12.7's list: each symbol centred in a column 28 pt wide, so the words start on one line
/// whatever the symbol's own width (the paw is narrower than `camera`; VISUAL §17.10.2 item 4).
private struct TourShortcutLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
                .frame(width: 28)
            configuration.title
        }
    }
}
