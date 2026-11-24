import MeowverseCore
import SwiftUI
import UniformTypeIdentifiers

/// 猫咪管理's second card: which cat model the room shows, and importing, inspecting and
/// deleting `.meowcat` models (docs/CAT_PACK.md). It used to be 设置 → 猫咪模型. The choice is
/// one for every cat and a setting of this device: it is not in the library, its backups or sync.
struct CatPackCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var importerShown = false
    @State private var packToDelete: CatPack?
    @State private var inspecting: CatPack?
    /// The built-in cat whose character card is open. Only its 就选它 chooses her.
    @State private var carded: CatPack?

    private static let contentTypes = [UTType(filenameExtension: "meowcat", conformingTo: .zip), .zip].compactMap { $0 }

    var body: some View {
        let packs = model.catPacks
        VStack(alignment: .leading, spacing: 8) {
            Text("猫咪模型")
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(RoomPaper.ink)
                // In line with the text in the card and its footer (the card's 16 plus a row's 16),
                // and a little apart from the cats card above.
                .padding(.horizontal, 32)
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            // As many columns as the width allows (owner, 2026-11-20): two on an iPhone held
            // upright, more on a wide sheet; one at accessibility text sizes.
            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(packs.builtIn) { packTile($0) }
                ForEach(packs.imported) { packTile($0) }
            }
            .padding(.horizontal, 16)
            RoomFolioCard(footer: Text("所有猫咪都用选中的模型。导入的模型和这里的选择只留在这台设备上，不会随备份导出。")) {
                if let active = packs.active, active.inspectURL != nil {
                    Button { inspecting = active } label: {
                        commandLabel(Text("查看 3D 模型"), symbol: "cube.transparent")
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("打开\(Wording.inline(active.displayTitle))的 3D 模型，可以转动和缩放。")
                    .accessibilityIdentifier("open-cat-inspect")
                }
                if packs.busy {
                    ProgressView("正在检查猫咪模型…")
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .accessibilityIdentifier("cat-pack-progress")
                }
                if let notice = packs.notice {
                    NoticeLabel(text: notice.text, isFailure: notice.isFailure)
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .accessibilityIdentifier("cat-pack-notice")
                }
                // Nobody outside the team has a .meowcat file, so a release build leaves the
                // command out (owner, 2026-11-20). Models imported before stay listed above.
                if model.options.debugEntries {
                    Button { importerShown = true } label: {
                        commandLabel(Text("导入猫咪模型…"), symbol: "square.and.arrow.down")
                    }
                    .buttonStyle(.plain)
                    .disabled(packs.busy)
                    .accessibilityHint("选择一个 .meowcat 文件。文件有问题时不会导入。")
                    .accessibilityIdentifier("import-cat-pack")
                }
                #if DEBUG || DRILLS
                if let path = model.options.catPackFile {
                    Button { packs.importPack(at: URL(fileURLWithPath: path)) } label: {
                        commandLabel(Text("演练：导入指定的猫咪模型"), symbol: "hammer")
                    }
                    .buttonStyle(.plain)
                    .disabled(packs.busy)
                    .accessibilityIdentifier("drill-import-cat-pack")
                }
                #endif
            }
        }
        .fileImporter(isPresented: $importerShown, allowedContentTypes: Self.contentTypes) { result in
            guard case .success(let url) = result else { return }
            model.catPacks.importPack(at: url)
        }
        .alert("替换已有的猫咪模型？", isPresented: replacementBinding) {
            Button("替换", role: .destructive) { model.catPacks.confirmReplacement() }
                .accessibilityIdentifier("confirm-replace-cat-pack")
            Button("取消", role: .cancel) { model.catPacks.cancelReplacement() }
                .accessibilityIdentifier("cancel-replace-cat-pack")
        } message: {
            Text(replacementMessage)
        }
        .confirmationDialog(packToDelete.map { "删除「\($0.manifest.name)」？" } ?? "", isPresented: deleteBinding, titleVisibility: .visible) {
            if let pack = packToDelete {
                Button("删除", role: .destructive) { model.catPacks.delete(id: pack.id) }
                    .accessibilityIdentifier("confirm-delete-cat-pack")
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let pack = packToDelete {
                Text(pack.id == model.catPacks.activeID
                     ? "房间里的猫咪会换回内置的\(Wording.object(model.catPacks.builtIn.first?.displayTitle ?? "Bella"))。删除后要重新导入文件才能再用它。"
                     : "删除后要重新导入文件才能再用它。")
            }
        }
        .sheet(item: $inspecting) { pack in
            NavigationStack {
                CatInspectView(pack: pack)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { inspecting = nil }
                                .accessibilityIdentifier("close-cat-inspect")
                        }
                    }
            }
        }
        .sheet(item: $carded) { pack in
            if let profile = pack.profile {
                CatProfileCardView(pack: pack, profile: profile, inUse: pack.id == model.catPacks.activeID,
                                   choose: {
                                       model.catPacks.select(pack.id)
                                       carded = nil
                                   },
                                   close: { carded = nil })
            }
        }
        // Leaving the page drops a replacement nobody confirmed, as leaving 设置 did.
        .onDisappear { model.catPacks.cancelReplacement() }
    }

    /// A command row of the card: icon and title in ink, at least 44 pt tall.
    private func commandLabel(_ title: Text, symbol: String) -> some View {
        Label {
            title.font(.body)
        } icon: {
            Image(systemName: symbol).foregroundStyle(RoomPaper.moss)
        }
        .foregroundStyle(RoomPaper.ink)
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
    }

    private var gridColumns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)]
    }

    /// A built-in cat opens her character card first; an imported model has no card (nothing is known
    /// about it beyond its file) and is chosen at once, as before.
    private func packTile(_ pack: CatPack) -> some View {
        let selected = pack.id == model.catPacks.activeID
        return CatPackTile(pack: pack, selected: selected) {
            if pack.profile != nil {
                carded = pack
            } else {
                model.catPacks.select(pack.id)
            }
        }
        .disabled(model.catPacks.busy)
        .accessibilityIdentifier("cat-pack-\(pack.id)")
        .overlay(alignment: .topTrailing) {
            if pack.origin != .builtIn {
                Menu {
                    Button("删除", systemImage: "trash", role: .destructive) { packToDelete = pack }
                        .accessibilityIdentifier("delete-cat-pack-\(pack.id)")
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(RoomPaper.moss)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .disabled(model.catPacks.busy)
                .accessibilityLabel("\(pack.displayTitle)的更多操作")
                .accessibilityIdentifier("cat-pack-menu-\(pack.id)")
            }
        }
    }


    private var replacementBinding: Binding<Bool> {
        // Only the alert's buttons decide; they say whether the staged copy is kept or discarded.
        Binding(get: { model.catPacks.pendingReplacement != nil }, set: { _ in })
    }

    private var replacementMessage: String {
        guard let staged = model.catPacks.pendingReplacement else { return "" }
        let old = model.catPacks.replacementTarget?.manifest.name ?? staged.manifest.id
        return String(localized: "已经有一个编号为 \(staged.manifest.id) 的模型「\(old)」。替换成「\(staged.manifest.name)」后，原来的文件会被删除。")
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { packToDelete != nil }, set: { if !$0 { packToDelete = nil } })
    }
}
