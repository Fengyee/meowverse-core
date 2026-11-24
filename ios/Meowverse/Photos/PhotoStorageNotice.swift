import MeowverseCore
import SwiftUI

extension PhotoSourceIssue {
    var guidance: String {
        switch self {
        case .unlinked: String(localized: "没有可读取的相册原件。若原件仍在，请打开“从相册读取大图”，再选择原来的照片导入。", table: "PhotoExport")
        case .missing: String(localized: "当前相册找不到原件。如果误删了，请到系统照片的“最近删除”恢复，再重试。", table: "PhotoExport")
        case .permission: String(localized: "相册读取权限不足。请在系统设置中允许喵空间完整访问照片，再重试。", table: "PhotoExport")
        case .iCloud: String(localized: "暂时无法下载 iCloud 原件。请联网，在系统照片中打开原图后重试。", table: "PhotoExport")
        case .unavailable: String(localized: "系统照片暂时无法读取原件，请稍后重试。", table: "PhotoExport")
        case .changed: String(localized: "相册中的文件与导入时不同。请在备份中查找当时的原件。", table: "PhotoExport")
        }
    }
}

struct PhotoStorageReceipt: Identifiable {
    let id = UUID()
    let message: String

    init?(photos: [PhotoRecord]) {
        guard !photos.isEmpty else { return nil }
        let reduced = photos.filter { $0.reducedFrom != nil }.count
        var parts = [String(localized: "已加入回忆。", table: "PhotoExport")]
        if reduced < photos.count {
            parts.append(String(localized: "已保存完整原件：\(photos.count - reduced) 张。", table: "PhotoExport"))
        }
        if reduced > 0 {
            parts.append(String(localized: "已保存缩小副本：\(reduced) 张。请保留系统相册里的原件。", table: "PhotoExport"))
        }
        message = parts.joined(separator: " ")
    }
}

struct PhotoStorageBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if let receipt = model.photos.storageReceipt {
            HStack(spacing: 10) {
                if !typeSize.isAccessibilitySize {
                    MemoryEmblem(.album).frame(width: 30, height: 26)
                }
                Text(receipt.message)
                    .font(.footnote)
                    .foregroundStyle(RoomPaper.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("photo-storage-receipt")
                Button {
                    model.photos.storageReceipt = nil
                } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel(String(localized: "关闭", table: "PhotoExport"))
            }
            .padding(.horizontal)
            .background(RoomPaper.paper)
            .overlay(alignment: .top) { Divider().overlay(RoomPaper.edge) }
            .task(id: receipt.id) {
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                if model.photos.storageReceipt?.id == receipt.id { model.photos.storageReceipt = nil }
            }
        }
    }
}
