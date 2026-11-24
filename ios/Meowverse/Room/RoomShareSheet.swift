import CoreTransferable
import ImageIO
import MeowverseCore
import SwiftUI
import UniformTypeIdentifiers

enum RoomSnapshotError: Error { case unavailable }

@MainActor
final class RoomSnapshotSource {
    weak var controller: RoomSceneController?

    func capture() async throws -> CGImage {
        guard let controller else { throw RoomSnapshotError.unavailable }
        return try await controller.capturePostcard()
    }
}

nonisolated private struct PostcardOptions: Hashable, Sendable {
    let title: String
    let showsQR: Bool
    /// nil = no stats line on the card (turned off, or nothing to show).
    let stats: LibraryStats?
}

nonisolated private struct PostcardPNG: Transferable, Sendable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in item.data }
            .suggestedFileName(String(localized: "Meowverse-房间明信片.png"))
    }
}

nonisolated private struct PreparedPostcard: Sendable {
    let options: PostcardOptions
    let image: CGImage
    let png: PostcardPNG

    init(scene: CGImage, options: PostcardOptions) throws {
        self.options = options
        image = try RoomPostcard.render(scene: scene, title: options.title, showsQR: options.showsQR, stats: options.stats)
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RoomSnapshotError.unavailable
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw RoomSnapshotError.unavailable }
        png = PostcardPNG(data: data as Data)
    }
}

struct RoomShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @FocusState private var editingTitle: Bool
    @State private var title: String
    /// Off unless the user asks for it each time (owner, 2026-11-20): the code leads to the
    /// frozen web demo, not the App Store. The choice was never stored, so no earlier one is lost.
    @State private var showsQR = false
    @State private var showsStats = true
    @State private var scene: CGImage?
    @State private var prepared: PreparedPostcard?
    @State private var captureAttempt = 0
    @State private var renderAttempt = 0
    @State private var captureFailed = false
    @State private var failedOptions: PostcardOptions?
    let source: RoomSnapshotSource
    private let startTitle: String

    init(defaultTitle: String, source: RoomSnapshotSource) {
        startTitle = String(defaultTitle.prefix(RoomPostcard.maximumTitleLength))
        _title = State(initialValue: startTitle)
        self.source = source
    }

    /// Read from the current state, so the card never shows numbers older than the library.
    private var libraryStats: LibraryStats? {
        let stats = LibraryStats(state: model.state)
        return RoomPostcard.statsParts(stats).isEmpty ? nil : stats
    }
    private var options: PostcardOptions {
        .init(title: title.trimmingCharacters(in: .whitespacesAndNewlines), showsQR: showsQR,
              stats: showsStats ? libraryStats : nil)
    }
    private struct RenderRequest: Hashable {
        let options: PostcardOptions
        let hasScene: Bool
        let attempt: Int
    }
    private var request: RenderRequest { .init(options: options, hasScene: scene != nil, attempt: renderAttempt) }

    var body: some View {
        RoomFolio(title: String(localized: "分享房间"), image: "TopShare", scrolls: false, detents: [.large],
                  close: RoomFolioClose(label: Text("关闭"), id: "close-room-share") { dismiss() }) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        preview
                            // The preview is printed on light photo stock in either appearance.
                            .environment(\.colorScheme, .light)
                            .memoryPhotoMount()
                            .frame(maxWidth: max(200, geometry.size.height * 0.52))
                            .frame(maxWidth: .infinity)
                        // The options, in one card of the folio.
                        RoomFolioCard {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("明信片标题").font(.headline)
                                Spacer()
                                Text("\(title.count)/60").font(.caption.monospacedDigit()).foregroundStyle(RoomPaper.note)
                                    .accessibilityLabel("已输入 \(title.count) 个字，最多 60 个字")
                            }
                            TextField("明信片标题", text: Binding(get: { title }, set: { title = String($0.prefix(RoomPostcard.maximumTitleLength)) }))
                                .textFieldStyle(.roundedBorder)
                                .focused($editingTitle)
                                .submitLabel(.done)
                                .onSubmit { editingTitle = false }
                                .accessibilityIdentifier("room-share-title")
                        }
                        .padding(16)
                        postcardToggle("附上喵空间二维码", isOn: $showsQR)
                            .accessibilityIdentifier("room-share-qr")
                            .padding(.horizontal, 16)
                        if let stats = libraryStats { statsControls(stats).padding(.horizontal, 16).padding(.vertical, 8) }
                        }
                        .padding(.horizontal, -16)
                        Text("只会分享这张明信片，不含你的照片。")
                            .font(.footnote)
                            .foregroundStyle(RoomPaper.note)
                    }
                    .padding()
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { shareButton }
        }
        // A title the user typed: a Home Screen quick action must not close the folio over it.
        .unsentWork(title != startTitle)
        .task(id: captureAttempt) { await capture() }
        .task(id: request) { await compose(request) }
    }

    @ViewBuilder private var preview: some View {
        if options.title.isEmpty {
            ContentUnavailableView("填写明信片标题", systemImage: "pencil",
                                   description: Text("请填写 1–60 个字的标题。").foregroundStyle(RoomPaper.note))
        } else if captureFailed || failedOptions == options {
            ContentUnavailableView {
                Label(captureFailed ? "房间画面暂不可用" : "明信片生成失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(captureFailed ? "请稍后重试。" : "请重新生成明信片。").foregroundStyle(RoomPaper.note)
            } actions: {
                Button("重试") {
                    if captureFailed { captureAttempt += 1 } else { renderAttempt += 1 }
                }.buttonStyle(.bordered)
            }
        } else {
            ZStack {
                RoomPaper.sheet
                if let prepared {
                    Image(decorative: prepared.image, scale: 1)
                        .resizable().scaledToFit()
                }
                if prepared?.options != options {
                    ProgressView(scene == nil ? "正在拍摄房间…" : "正在生成明信片…")
                        .padding().background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(previewLabel)
            .accessibilityValue(showsQR ? "包含喵空间二维码" : "二维码已关闭")
            .accessibilityIdentifier(prepared?.options == options ? "room-postcard-ready" : "room-postcard-loading")
        }
    }

    private var previewLabel: String {
        guard prepared?.options == options else { return String(localized: "正在生成房间预览") }
        guard let stats = options.stats else { return String(localized: "房间明信片预览，\(title)") }
        return String(localized: "房间明信片预览，\(title)，\(Self.spokenStats(stats))")
    }

    private static func spokenStats(_ stats: LibraryStats) -> String {
        RoomPostcard.statsParts(stats).formatted(.list(type: .and).locale(AppLanguage.locale))
    }

    private func postcardToggle(_ label: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(.rect)
        }
    }

    @ViewBuilder private func statsControls(_ stats: LibraryStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            postcardToggle("显示回忆统计", isOn: $showsStats)
                .accessibilityIdentifier("room-share-stats")
            Text(showsStats ? "明信片右上角会写：\(RoomPostcard.statsParts(stats).joined(separator: " · "))"
                            : "统计已关闭，明信片上不写数字。")
                .font(.footnote)
                .foregroundStyle(RoomPaper.note)
                .accessibilityLabel(showsStats ? "明信片上会写：\(Self.spokenStats(stats))" : "统计已关闭，明信片上不写数字。")
                .accessibilityIdentifier("room-share-stats-summary")
        }
    }

    @ViewBuilder private var shareButton: some View {
        Group {
            if let prepared, prepared.options == options, !captureFailed, failedOptions != options {
                let thumbnail = Image(decorative: prepared.image, scale: 1)
                ShareLink(item: prepared.png, preview: SharePreview(title.isEmpty ? String(localized: "喵空间房间明信片") : title, image: thumbnail)) {
                    // The folio's brown ink would sit on the moss button at about 1.5:1.
                    shareLabel.foregroundStyle(RoomPaper.sealInk)
                }
                .accessibilityIdentifier("share-room-png")
            } else {
                Button {} label: { shareLabel }.disabled(true)
            }
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var shareLabel: some View {
        Label("分享明信片", systemImage: "square.and.arrow.up")
            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 5)
    }

    private func capture() async {
        captureFailed = false
        do {
            let image = try await source.capture()
            try Task.checkCancellation()
            scene = image
        } catch {
            if !Task.isCancelled { captureFailed = true }
        }
    }

    private func compose(_ request: RenderRequest) async {
        guard let scene, request.hasScene, !request.options.title.isEmpty else { return }
        failedOptions = nil
        do {
            try await Task.sleep(for: .milliseconds(110))
            let render = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try PreparedPostcard(scene: scene, options: request.options)
            }
            let next = try await withTaskCancellationHandler {
                try await render.value
            } onCancel: {
                render.cancel()
            }
            try Task.checkCancellation()
            guard options == next.options else { return }
            prepared = next
        } catch {
            if !Task.isCancelled, options == request.options { failedOptions = request.options }
        }
    }
}
