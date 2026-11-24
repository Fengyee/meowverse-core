import MeowverseCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum PhotoExportAction: String, Identifiable {
    case share, shareFile, save, album
    var id: Self { self }

    var title: String {
        switch self {
        case .share: String(localized: "分享照片", table: "PhotoExport")
        case .shareFile: String(localized: "分享原文件", table: "PhotoExport")
        case .save: String(localized: "保存到系统相册", table: "PhotoExport")
        case .album: String(localized: "将原件加入 Meowverse 相簿", table: "PhotoExport")
        }
    }
}

struct PhotoExportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ids: [String]
    let action: PhotoExportAction

    @State private var files: [PhotoExport] = []
    @State private var images: [UIImage] = []
    @State private var folder: URL?
    @State private var nextAttempt = 0
    @State private var preparing = true
    @State private var working = false
    @State private var sharing = false
    @State private var message: String?
    @State private var success = false
    @State private var addDenied = false
    @State private var generation: UUID?
    /// The zone the date note is written for and the copies are dated in.
    @State private var timeZone = TimeZone.current

    var body: some View {
        NavigationStack {
            List {
                if preparing {
                    HStack(spacing: 12) {
                        MemoryEmblem(.postcard).frame(width: 52, height: 43)
                        ProgressView(String(localized: "正在准备照片…", table: "PhotoExport"))
                    }
                } else if action == .album {
                    Text(String(localized: "系统相簿只归集仍在系统照片中的原件。删除原件也会将它移出相簿，相簿不能用作备份。", table: "PhotoExport"))
                } else if !files.isEmpty {
                    let copies = files.filter { $0.copyReason != nil }
                    HStack(alignment: .top, spacing: 12) {
                        MemoryEmblem(.postcard).frame(width: 54, height: 45)
                        if copies.isEmpty {
                            Text(action == .share
                                 ? String(localized: "将从完整原件准备图片：\(files.count) 张。", table: "PhotoExport")
                                 : String(localized: "将导出完整原件：\(files.count) 张。", table: "PhotoExport"))
                        } else {
                            Text(String(localized: "所选照片中有 \(copies.count) 张仅能导出本地缩小副本。", table: "PhotoExport"))
                                .accessibilityIdentifier("export-copy-warning")
                        }
                    }
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(RoomPaper.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                    .listRowBackground(RoomPaper.sheet)
                    ForEach(Array(Set(copies.compactMap(\.copyReason))).map(\.guidance).sorted(), id: \.self) { Text($0) }
                    if action == .save, !copies.isEmpty {
                        Text(Self.copyDateNote(PhotoExport.copyDateCounts(copies, in: timeZone)))
                            .font(.footnote)
                            .accessibilityIdentifier("export-copy-date-note")
                    }
                }
                if action == .share, !files.isEmpty {
                    Text(String(localized: "以兼容图片分享，保留所用照片的像素尺寸。要保留文件格式和原始数据，请选择“分享原文件”。", table: "PhotoExport"))
                        .font(.footnote)
                }
                if let message {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(success ? RoomPaper.moss : Color.caution)
                            .accessibilityHidden(true)
                        Text(message)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("export-result")
                    }
                    .listRowBackground(RoomPaper.sheet)
                }
                if addDenied, let settings = URL(string: UIApplication.openSettingsURLString) {
                    Link(String(localized: "打开系统设置"), destination: settings)
                }
                if !preparing && !success {
                    if message != nil {
                        Button(String(localized: "重试")) { nextAttempt += 1 }
                            .accessibilityIdentifier("retry-photo-export")
                    } else {
                        Button(action.title) { Task { await deliver() } }
                            .disabled(working)
                            .accessibilityIdentifier("confirm-photo-export")
                    }
                }
                if working { ProgressView() }
            }
            .memoryPage(.postcard)
            .navigationTitle(action.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(success ? "完成" : "取消") { dismiss() }.disabled(working)
                        .accessibilityIdentifier("close-photo-export")
                }
            }
        }
        .interactiveDismissDisabled(working)
        .task(id: nextAttempt) { await prepare() }
        .onChange(of: model.libraryGeneration) { dismiss() }
        .sheet(isPresented: $sharing) { PhotoActivities(files: files, images: images, shareImages: action == .share) }
        .onDisappear { if !sharing { clean() } }
    }

    private func prepare() async {
        preparing = true
        addDenied = false
        message = nil
        files = []
        images = []
        clean()
        generation = model.libraryGeneration
        defer { if !Task.isCancelled { preparing = false } }
        guard action != .album else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(AppModel.exportFolderPrefix + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let linked = model.photoLibrary.wanted
            var ready: [PhotoExport] = []
            var compatible: [UIImage] = []
            for id in ids {
                try Task.checkCancellation()
                guard let photo = model.photo(id), generation == model.libraryGeneration else { throw StoreError.unknownPhoto }
                let url = await model.originalURL(photoId: id)
                let file = try await PhotoExport.prepare(photo: photo, stored: url, in: directory) {
                    try await PhotoLibraryLink.originalData(for: photo, linked: linked)
                }
                if action == .share {
                    let jpeg = try await file.compatibleJPEG()
                    guard let image = UIImage(contentsOfFile: jpeg.path) else { throw CocoaError(.fileReadCorruptFile) }
                    compatible.append(image)
                }
                ready.append(file)
            }
            try Task.checkCancellation()
            guard !ready.isEmpty, generation == model.libraryGeneration else { throw StoreError.unknownPhoto }
            folder = directory
            files = ready
            images = compatible
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if !Task.isCancelled {
                message = String(localized: "无法准备所选照片。请检查本地副本或从备份恢复，再重试。", table: "PhotoExport")
            }
        }
    }

    private func deliver() async {
        guard !working, generation == model.libraryGeneration else { return }
        working = true
        defer { working = false }
        do {
            switch action {
            case .share, .shareFile:
                sharing = true
                return
            case .save:
                try await PhotoDelivery.save(files, timeZone: timeZone)
                message = String(localized: "已保存到系统相册：\(files.count) 张。", table: "PhotoExport")
            case .album:
                let count = try await PhotoDelivery.collect(ids.compactMap(model.photo), linked: model.photoLibrary.wanted)
                message = String(localized: "已在 Meowverse 相簿：\(count) / \(ids.count)。", table: "PhotoExport")
            }
            success = true
        } catch PhotoDeliveryError.addPermission {
            addDenied = true
            message = String(localized: "请在系统设置中允许喵空间添加照片，然后重试。", table: "PhotoExport")
        } catch PhotoDeliveryError.noOriginals {
            message = String(localized: "没有找到可归集的原件。请打开“从相册读取大图”，并检查系统照片中的原件。", table: "PhotoExport")
        } catch let issue as PhotoSourceIssue {
            message = issue.guidance
        } catch {
            message = String(localized: "系统照片未完成此操作，请检查剩余空间后重试。", table: "PhotoExport")
        }
    }

    private func clean() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    /// Only the cases these copies meet, from the same plan `PhotoDelivery.save` follows.
    static func copyDateNote(_ counts: PhotoExport.CopyDateCounts) -> String {
        var lines: [String] = []
        if counts.localNoon + counts.laterThatDay > 0 {
            lines.append(String(localized: "缩小副本沿用你在这里看到的拍摄日期。", table: "PhotoExport"))
        }
        if counts.localNoon > 0 {
            lines.append(String(localized: "只有日期时，系统相册用当地中午 12 点排列。", table: "PhotoExport"))
        }
        if counts.laterThatDay > 0 {
            lines.append(String(localized: "\(counts.laterThatDay) 张的拍摄日在当地没有中午 12 点，改用同一天稍后的时刻。", table: "PhotoExport"))
        }
        if counts.dayMissingHere > 0 {
            lines.append(String(localized: "\(counts.dayMissingHere) 张的拍摄日在当地时区里被整天跳过，不会带上日期，由系统相册安排；喵空间里的日期不变。", table: "PhotoExport"))
        }
        if counts.unknownDay > 0 {
            lines.append(String(localized: "\(counts.unknownDay) 张日期未知，由系统相册安排。", table: "PhotoExport"))
        }
        return lines.joined(separator: AppLanguage.locale.language.languageCode == .chinese ? "" : " ")
    }
}

private struct PhotoActivities: UIViewControllerRepresentable {
    let files: [PhotoExport]
    let images: [UIImage]
    let shareImages: Bool

    func makeUIViewController(context: Context) -> UIActivityViewController {
        if shareImages { return UIActivityViewController(activityItems: images, applicationActivities: nil) }
        let configuration = UIActivityItemsConfiguration(itemProviders: files.map(Self.provider))
        return UIActivityViewController(activityItemsConfiguration: configuration)
    }

    private nonisolated static func provider(for file: PhotoExport) -> NSItemProvider {
        let provider = NSItemProvider()
        let url = file.url
        let type = UTType(filenameExtension: url.pathExtension, conformingTo: .image) ?? .image
        provider.suggestedName = url.lastPathComponent
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { reply in
            reply(url, false, nil)
            return nil
        }
        return provider
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
