#if DEBUG
import MeowverseCore
import SwiftUI

/// DEBUG-only pages for the round-8 suggested-filing components, reached through
/// `-MeowverseOverlayGallery <page>` with an optional `-MeowverseGalleryState <state>`:
///
/// | page | states |
/// | --- | --- |
/// | `filing-screen` | `count` (default), `comparing`, `done` — the review screen with the strip and the progress bar |
/// | `filing-round` | `count` (default), `zero` — the review screen during the representative round |
/// | `filing-confirm` | `four` (default, 4 pieces, 40 photos), `one` (1 piece, 3 photos), `none` (all unticked) |
/// | `filing-cover` | — the full-screen progress |
/// | `filing-round-intro`, `filing-round-end`, `filing-mark` | — |
///
/// Every photo here is drawn: blocks of colour standing for a corner of a room. The screens around
/// the components are a reference arrangement, not the shipped import flow.
struct FilingGallery: View {
    let page: OverlayGallery.Page
    private let state: String = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-MeowverseGalleryState"), args.indices.contains(index + 1) else { return "" }
        return args[index + 1]
    }()

    var body: some View {
        switch page {
        case .filingScreen:
            ReviewScreenSample(mode: .suggestions,
                               count: state == "comparing" || state == "done" ? 0 : 12,
                               comparing: true, done: state == "done")
        case .filingRound:
            ReviewScreenSample(mode: .round(index: 3, total: 10), count: state == "zero" ? 0 : 12,
                               comparing: false, done: false)
        case .filingConfirm:
            ConfirmSample(state: state)
        case .filingCover:
            BatchProgressCover(phase: .importing, done: 3, total: 200,
                               note: Text(verbatim: copy("第一张准备好就可以开始整理，其余的在后台继续。", "You can start sorting as soon as the first photo is ready; the rest carry on in the background.")), // not-localized: debug gallery sample note
                               cancel: {})
        case .filingRoundIntro:
            NavigationStack {
                RepresentativeRoundIntro(picks: 10, total: 200, previews: (0..<5).map { "g\($0)-0" },
                                         start: {}, skip: {}) { SyntheticPrint(id: $0) }
                    .navigationTitle(Text(verbatim: copy("整理照片", "Sort photos"))) // not-localized: debug gallery
                    .navigationBarTitleDisplayMode(.inline)
            }
        case .filingRoundEnd:
            NavigationStack {
                RepresentativeRoundEnd(suggestable: 34, remaining: 190, review: {}, carryOn: {})
                    .navigationTitle(Text(verbatim: copy("整理照片", "Sort photos"))) // not-localized: debug gallery
                    .navigationBarTitleDisplayMode(.inline)
            }
        case .filingMark:
            MarkSample()
        default:
            EmptyView()
        }
    }
}

private func copy(_ zh: String, _ en: String) -> String {
    Locale.current.language.languageCode?.identifier == "zh" ? zh : en
}

/// Sample pieces: name in Chinese and English, and the palette their photos are drawn in.
private let samplePieces: [(zh: String, en: String)] = [
    ("布艺沙发", "Fabric sofa"), // not-localized: debug gallery sample name
    ("窗边猫爬架", "Window cat tree"), // not-localized: debug gallery sample name
    ("橡木书架", "Oak bookshelf"), // not-localized: debug gallery sample name
    ("照片墙", "Photo wall"), // not-localized: debug gallery sample name
    ("藤编猫窝", "Rattan cat bed"), // not-localized: debug gallery sample name
]

// MARK: - A drawn photo

/// A drawn "photo" of a room corner: wall, floor, a piece of furniture and a window, in a palette
/// chosen by the group (`g<group>-<n>`) so photos of one group look alike and vary a little by `n`.
struct SyntheticPrint: View {
    let id: String

    private var numbers: (group: Int, index: Int) {
        let parts = id.dropFirst().split(separator: "-").compactMap { Int($0) }
        return (parts.first ?? 0, parts.count > 1 ? parts[1] : 0)
    }

    private static let palettes: [(wall: UInt32, floor: UInt32, piece: UInt32, accent: UInt32)] = [
        (0xE9D8C4, 0xA77B55, 0x6F8F7A, 0xF4E6B8),
        (0xCFE0E3, 0x8E6F52, 0xC98B5E, 0xFFF3C9),
        (0xEFE3D0, 0x7B5A40, 0x8A5A3C, 0xE7C9A0),
        (0xF2DCDC, 0xB89474, 0xD7B98A, 0x9CB7C9),
        (0xDCE6CF, 0x9A7A5C, 0xC9A26B, 0xF6E7C6),
    ]

    var body: some View {
        let (group, index) = numbers
        let p = Self.palettes[group % Self.palettes.count]
        let shift = CGFloat((index * 37) % 9) / 9 - 0.5
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            ZStack(alignment: .topLeading) {
                Color(uiColor: UIColor(hex: p.wall))
                Rectangle().fill(Color(uiColor: UIColor(hex: p.accent)))
                    .frame(width: w * 0.26, height: h * 0.3)
                    .overlay { Rectangle().stroke(.white.opacity(0.8), lineWidth: max(1, w * 0.02)) }
                    .offset(x: w * (0.62 + shift * 0.15), y: h * 0.12)
                Rectangle().fill(Color(uiColor: UIColor(hex: p.floor)))
                    .frame(width: w, height: h * 0.32)
                    .offset(y: h * 0.68)
                RoundedRectangle(cornerRadius: w * 0.06)
                    .fill(Color(uiColor: UIColor(hex: p.piece)))
                    .frame(width: w * 0.5, height: h * 0.3)
                    .offset(x: w * (0.12 + shift * 0.2), y: h * 0.5)
                Ellipse().fill(.black.opacity(0.12))
                    .frame(width: w * 0.5, height: h * 0.06)
                    .offset(x: w * (0.12 + shift * 0.2), y: h * 0.79)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

// MARK: - The review screen around the strip

private struct ReviewScreenSample: View {
    let mode: FilingSuggestionStrip.Mode
    let count: Int
    let comparing: Bool
    let done: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SyntheticPrint(id: "g0-1")
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .frame(maxHeight: 250)
                        .memoryPhotoMount()
                        .frame(maxWidth: .infinity)
                    Label(copy("2024 年 5 月 3 日拍摄", "Taken 3 May 2024"), systemImage: "calendar") // not-localized: debug gallery sample date
                        .font(.system(.subheadline, design: .serif, weight: .semibold))
                        .foregroundStyle(RoomPaper.ink)
                    VStack(alignment: .leading, spacing: 10) {
                        Label(Wording.recognitionHeader(analyzer: KnownAnalyzer.dinoV2), systemImage: "iphone").font(.headline)
                        sampleRow
                    }
                    Label("手动选择", systemImage: "hand.tap").font(.headline)
                }
                .padding()
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                FilingSuggestionStrip(mode: mode, count: count, comparing: comparing, open: {})
                    .background(RoomPaper.leaf.opacity(0.94))
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if done {
                        FilingNoticeBar(message: FilingNoticeBar.filedMessage(photos: 11, pieces: ["", "", ""]), undo: {})
                    }
                    if comparing {
                        BatchProgressBar(phase: .recognizing, done: 37, total: 200, cancel: {})
                    }
                    primaryButton(String(localized: "下一步：选款式"), enabled: false) {}
                }
            }
            .memoryPage(.workshop)
            .navigationTitle(String(localized: "整理照片 \(1) / \(200)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("先到这里") {} }
                ToolbarItem(placement: .topBarTrailing) { Button(String(localized: "跳过", table: "BatchImport")) {} }
            }
        }
    }

    private var sampleRow: some View {
        HStack(spacing: 12) {
            SyntheticPrint(id: "g0-4").frame(width: 48, height: 48).clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: copy("放进「布艺沙发」", "Add to “Fabric sofa”")).font(.body.weight(.medium)) // not-localized: debug gallery sample row
                Text("很像它的一张照片").font(.footnote).foregroundStyle(Color.subtle)
            }
            Spacer()
            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(Color.subtle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 48)
        .memoryCard(.workshop)
    }
}

// MARK: - The confirmation page

private struct ConfirmSample: View {
    let groups: [FilingSuggestionGroup]
    @State private var selection: Set<String>

    init(state: String) {
        let sizes: [Int] = state == "one" ? [3] : [14, 11, 9, 6]
        let built = sizes.enumerated().map { group, size in
            let piece = samplePieces[group]
            return FilingSuggestionGroup(
                id: "piece-\(group)", name: copy(piece.zh, piece.en),
                detail: group == 2 ? copy("在收纳箱", "In storage") : nil, // not-localized: debug gallery sample detail
                cover: group == 3 ? nil : "g\(group)-0",
                photos: (1...size).map { FilingSuggestionPhoto(id: "g\(group)-\($0)", label: copy("拍摄于 2024 年 5 月 \($0) 日", "Taken \($0) May 2024")) }) // not-localized: debug gallery sample label
        }
        groups = built
        var ticked = Set(built.flatMap { $0.photos.map(\.id) })
        if state == "none" { ticked = [] } else if state != "one" { ticked.subtract(["g0-3", "g1-2", "g1-7"]) }
        _selection = State(initialValue: ticked)
    }

    var body: some View {
        NavigationStack {
            FilingSuggestionReview(groups: groups, selection: $selection, confirm: {}, notNow: {}) {
                SyntheticPrint(id: $0)
            }
        }
    }
}

// MARK: - The provenance mark in a photo caption

private struct MarkSample: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SyntheticPrint(id: "g1-2")
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .memoryPhotoMount()
                    .padding(.horizontal, 16)
                caption(suggested: true)
                caption(suggested: false)
            }
            .padding(.vertical, 16)
        }
        .memoryPage(.album)
    }

    /// The photo caption of FurnitureDetailView, drawn with sample values.
    private func caption(suggested: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                MemoryEmblem(.album).frame(width: 44, height: 34)
                Text(verbatim: copy("2024 年 5 月 2 日拍摄", "Taken 2 May 2024")) // not-localized: debug gallery sample date
                    .font(.system(.headline, design: .serif, weight: .semibold))
                    .foregroundStyle(RoomPaper.ink)
            }
            Label("由你手动选择", systemImage: "hand.tap")
                .font(.subheadline)
                .foregroundStyle(Color.subtle)
            if suggested { SuggestedFilingMark() }
            Text(verbatim: copy("导入于 2026 年 1 月 6 日 09:41", "Imported 6 Jan 2026 at 09:41")) // not-localized: debug gallery sample date
                .font(.footnote)
                .foregroundStyle(Color.subtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .memoryCard(.album)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}
#endif
