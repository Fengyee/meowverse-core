import SwiftUI

// The representative round of a big first import (round 8). The app picks about ten photos that
// stand for the most others; the user files those first in the ordinary one-photo review screen
// (where `FilingSuggestionStrip(mode: .round…)` counts them), and photos that look like them get
// suggestions. These are the two pages around that round. Wording stays with "建议": nothing is
// filed without the user, and nothing is promised to be right.
//
// Both are page contents for the import flow's NavigationStack, in the `.album` page look; they
// set no title (the caller's step title stays). Values in, closures out. A no-break space
// (\u{00A0}) joins every count to its 张, so "3 张" never wraps apart.

/// Before the round: what it is, and a way to keep the ordinary order.
struct RepresentativeRoundIntro<Thumbnail: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Photos in the round, about 10.
    let picks: Int
    /// Photos in the whole batch.
    let total: Int
    /// A few of the picked photos for the fanned prints, at most 5 are drawn; may be empty.
    var previews: [String] = []
    let start: () -> Void
    let skip: () -> Void
    @ViewBuilder let thumbnail: (_ photoId: String) -> Thumbnail

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if previews.isEmpty || typeSize.isAccessibilitySize {
                    MemoryEmblem(.album).frame(width: 132, height: 100)
                } else {
                    FannedPrints(ids: Array(previews.prefix(5)), thumbnail: thumbnail)
                        .frame(height: 128)
                }
                Text("先整理 \(picks)\u{00A0}张代表照片")
                    .font(RoomTitleFont.font(for: String(localized: "先整理 \(picks)\u{00A0}张代表照片"), size: 24,
                                             relativeTo: .title2, maximum: 30, typeSize: typeSize))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("这次有 \(total)\u{00A0}张照片。先把最能代表其余照片的 \(picks)\u{00A0}张放进家具；之后，和它们相像的照片会给出建议，由你确认再放。")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("建议是按照片的相像程度在这台设备上给出的，可能有错。")
                    .font(.footnote)
                    .foregroundStyle(RoomPaper.note)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: skip) { Text("不用，按原来的顺序整理") }
                    .buttonStyle(PaperOutlineStyle())
                    .accessibilityHint(Text("从第一张开始一张一张整理，不先挑代表照片。"))
                    .accessibilityIdentifier("skip-representative-round")
                    .padding(.top, 4)
            }
            .foregroundStyle(RoomPaper.ink)
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            primaryButton(String(localized: "开始整理这 \(picks)\u{00A0}张"), enabled: true, action: start)
                .accessibilityIdentifier("start-representative-round")
        }
        .memoryPage(.album)
    }
}

/// After the round. With suggestions it hands off to the confirmation page; with none the caller
/// goes straight on to the remaining photos and shows `nothingToSuggest` as a passing line
/// (`TransientNotice.show`) instead of this page.
struct RepresentativeRoundEnd: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Photos with a suggested piece now. Show this page only when it is at least 1.
    let suggestable: Int
    /// Photos still to sort, suggested ones included.
    let remaining: Int
    let review: () -> Void
    let carryOn: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                MemoryEmblem(.workshop).frame(width: 132, height: 100)
                Text("代表照片整理好了")
                    .font(RoomTitleFont.font(for: String(localized: "代表照片整理好了"), size: 24,
                                             relativeTo: .title2, maximum: 30, typeSize: typeSize))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("有 \(suggestable)\u{00A0}张照片可以按建议放进家具。建议是按相像程度给的，可能有错，先看一看再放。")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: carryOn) { Text("先一张一张整理剩下的 \(remaining)\u{00A0}张") }
                    .buttonStyle(PaperOutlineStyle())
                    .accessibilityHint(Text("建议会留在整理页顶上，随时可以打开。"))
                    .accessibilityIdentifier("skip-suggestion-review")
                    .padding(.top, 4)
            }
            .foregroundStyle(RoomPaper.ink)
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            primaryButton(String(localized: "查看建议的 \(suggestable)\u{00A0}张"), enabled: true, action: review)
                .accessibilityIdentifier("open-suggestion-review")
        }
        .memoryPage(.album)
    }

    /// The passing line when the round leaves nothing to suggest.
    static func nothingToSuggest(remaining: Int) -> String {
        String(localized: "这一轮没有找到可以建议的照片，接着整理剩下的 \(remaining)\u{00A0}张。")
    }

    /// The same passing line when the comparison didn't finish: it doesn't know that there are none.
    static func couldNotCompare(remaining: Int) -> String {
        String(localized: "这一轮没能完成比对，接着整理剩下的 \(remaining)\u{00A0}张。")
    }
}

/// A secondary page action that can wrap at large text: `paper`, 1 pt `edge`, corner 15 (the
/// primary button's corner), ink text. `RoomFolioButtonStyle` keeps one line; this one does not.
struct PaperOutlineStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        configuration.label
            .font(.system(.body, design: .rounded, weight: .semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(RoomPaper.ink.opacity(isEnabled ? 1 : 0.6))
            .background {
                shape.fill(configuration.isPressed ? RoomPaper.flyleaf : RoomPaper.paper)
                    .overlay { shape.strokeBorder(RoomPaper.edge, lineWidth: 1) }
            }
            .contentShape(shape)
    }
}

/// Up to five prints fanned on the table, each in its photo mat. Decorative.
private struct FannedPrints<Thumbnail: View>: View {
    let ids: [String]
    @ViewBuilder let thumbnail: (_ photoId: String) -> Thumbnail

    var body: some View {
        let count = ids.count
        ZStack {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                let spread = Double(index) - Double(count - 1) / 2
                thumbnail(id)
                    .frame(width: 70, height: 84)
                    .clipped()
                    .padding(4)
                    .background(RoomPaper.photoMat)
                    .overlay { Rectangle().strokeBorder(RoomPaper.edge.opacity(0.7)) }
                    .shadow(color: .black.opacity(0.14), radius: 2, y: 2)
                    .rotationEffect(.degrees(spread * 8), anchor: .bottom)
                    .offset(x: spread * 38, y: abs(spread) * 6)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
