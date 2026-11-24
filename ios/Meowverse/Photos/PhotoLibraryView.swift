import MeowverseCore
import SwiftUI

/// Every photo Meowverse keeps, by capture month. Photos without a capture day get their own
/// group; nothing here guesses a date from a filename or from when the photo was imported.
struct PhotoLibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 4)]

    /// "选择" mode: taps tick photos instead of opening them.
    @State private var export: ExportRequest?
    @State private var selecting = false
    @State private var selected: Set<String> = []
    /// The piece picker, for the ticked photos or for the one photo whose menu asked.
    @State private var linking: LinkRequest?
    @State private var furnitureFilterShown = false
    @State private var deleteAsked = false
    /// The photo whose long-press menu asked to delete it, waiting for the confirmation.
    @State private var deleteOne: String?
    /// The open delete question's message, made when it was asked.
    @State private var deleteWords = ""
    @State private var working = false
    @State private var failure: String?
    /// What the last batch change did, with the way to take it back.
    @State private var notice: BatchNotice?
    /// What the last confirmed page of suggestions filed, with 撤销.
    @State private var filedNotice: FiledNotice?

    /// The furniture filter, without pieces that no longer exist.
    private var furnitureFilter: Set<String> {
        model.photos.furnitureFilter.intersection(model.state.allFurniture.map(\.instanceId))
    }

    var body: some View {
        let sections = PhotoLibrary.sections(in: model.shownState, filter: model.photos.filter, onFurniture: furnitureFilter,
                                             linkedElsewhere: model.sync.photosOnNewerPieces)
        let shownIds = sections.flatMap(\.photos).map(\.photoId)
        // Photos that left the view (deleted, or filtered out) are no longer chosen.
        let chosen = shownIds.filter(selected.contains)
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    filterBar
                    if sections.isEmpty {
                        emptyState
                    } else {
                        if model.photos.filter == .unlinked, !selecting {
                            sortAllButton(shownIds)
                            SuggestionRerunEntry(scope: .unfiled(shownIds), notice: $filedNotice)
                                .padding(.horizontal)
                        }
                        ForEach(sections) { section in
                            sectionView(section, first: shownIds.first)
                        }
                    }
                }
                .padding(.vertical)
            }
            // Chapter 9 begins while this page is on top (`TourPages`).
            .tourAnchor(TourPages.anchor(.photoLibrary), padding: 0)
            .memoryPage(.album)
            .navigationTitle(selecting ? String(localized: "已选 \(chosen.count) 张") : String(localized: "照片库"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { photoId in
                PhotoDetailView(photoId: photoId, context: .library)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selecting {
                        Button(chosen.count == shownIds.count ? "全不选" : "全选") {
                            selected = chosen.count == shownIds.count ? [] : Set(shownIds)
                        }
                        .disabled(shownIds.isEmpty)
                        .accessibilityIdentifier("select-all-photos")
                    } else {
                        Button("选择") { selecting = true }
                            .buttonStyle(MemoryCommandStyle(tint: RoomPaper.clay))
                            .disabled(shownIds.isEmpty)
                            .accessibilityHint("选中几张照片，一起放进家具、收藏或删除")
                            .accessibilityIdentifier("select-photos")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if selecting {
                        Button("取消") { stopSelecting() }.accessibilityIdentifier("cancel-select-photos")
                    } else {
                        Button("完成") { dismiss() }.accessibilityIdentifier("close-library")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    PhotoStorageBanner()
                    SuggestedFilingNotice(notice: $filedNotice)
                    if let notice { noticeBar(notice) }
                    if selecting { batchBar(chosen) }
                }
            }
        }
        .sheet(item: $export) { request in PhotoExportView(ids: request.ids, action: request.action) }
        .sheet(item: $linking) { request in
            FurniturePickerView(title: String(localized: "放进家具"),
                                prompt: request.ids.count == 1 && !selecting
                                    ? String(localized: "选一件家具。照片原来在别的家具里的，仍然在那里。")
                                    : String(localized: "选中的 \(request.ids.count) 张照片会放进你选的家具。原来在别的家具里的，仍然在那里。"),
                                hidden: request.hidden) { item in
                link(request.ids, to: item)
            }
        }
        .sheet(isPresented: $furnitureFilterShown) {
            FurniturePickerView(title: String(localized: "按家具筛选"),
                                prompt: String(localized: "只看选中家具里的照片。可以选几件。"),
                                checked: furnitureFilter, closesOnPick: false) { item in
                if furnitureFilter.contains(item.instanceId) {
                    model.photos.furnitureFilter.remove(item.instanceId)
                } else {
                    model.photos.furnitureFilter = furnitureFilter.union([item.instanceId])
                }
            }
        }
        .alert("没能保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好") {}
        } message: {
            Text(failure ?? "")
        }
    }

    // MARK: Several photos at once

    private struct BatchNotice: Equatable {
        let id = UUID()
        let message: String
        let undo: Undo

        enum Undo: Equatable {
            case unlink(photoIds: [String], instanceId: String)
            case favorite(photoIds: [String], Bool)
            /// Puts the links back exactly as they were (origin, place in the album).
            case relink(LibraryStore.UnlinkReceipt)
            /// The cover the piece had before; nil = its first photo.
            case cover(instanceId: String, previous: String?)
        }
    }

    private struct ExportRequest: Identifiable {
        let id = UUID()
        let ids: [String]
        let action: PhotoExportAction
    }

    private struct LinkRequest: Identifiable {
        let id = UUID()
        let ids: [String]
        /// Pieces every one of these photos is already on.
        var hidden: Set<String> = []
    }

    private func stopSelecting() {
        selecting = false
        selected = []
    }

    /// The pieces any of `ids` is on, in the order of the furniture library.
    private func pieces(holding ids: [String]) -> [PhotoFurniture] {
        let held = Set(ids.flatMap { model.furniture(containingPhoto: $0).map(\.instanceId) })
        return model.state.allFurniture.filter { held.contains($0.instanceId) }
    }

    private func batchBar(_ chosen: [String]) -> some View {
        let allFavorite = !chosen.isEmpty && chosen.allSatisfy { model.photo($0)?.favorite == true }
        let holding = pieces(holding: chosen)
        return HStack {
            batchButton(String(localized: "放进家具"), "rectangle.badge.plus", id: "batch-link") { linking = LinkRequest(ids: chosen) }
                .disabled(model.state.allFurniture.isEmpty)
            batchButton(allFavorite ? String(localized: "取消收藏") : String(localized: "action.favorite", defaultValue: "收藏", comment: "Action on photos: mark them as favorite"),
                        allFavorite ? "heart.slash" : "heart", id: "batch-favorite") { favorite(chosen, !allFavorite) }
            batchUnlink(chosen, holding: holding)
            Menu {
                exportButtons(chosen)
            } label: {
                batchLabel(String(localized: "分享或导出"), "square.and.arrow.up")
            }
            // A menu opened from the bottom of the screen lists its items bottom-up unless told
            // otherwise; fixed keeps them in the long-press menu's order.
            .menuOrder(.fixed)
            .accessibilityIdentifier("batch-export")
            batchButton(String(localized: "删除"), "trash", id: "batch-delete", role: .destructive) { askToDelete(chosen) }
                // On the button, not the page: mounted on the page it put text the audit could
                // not place at the largest text size, and the sheet should point at what opened it.
                .confirmationDialog("删除这 \(chosen.count) 张照片？", isPresented: $deleteAsked, titleVisibility: .visible) {
                    Button("删除 \(chosen.count) 张照片", role: .destructive) { delete(chosen) }
                        .accessibilityIdentifier("confirm-delete-photos")
                    Button("取消", role: .cancel) {}
                } message: {
                    Text(deleteWords)
                }
        }
        .disabled(chosen.isEmpty || working)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(RoomPaper.paper)
        .overlay(alignment: .top) { Divider().overlay(RoomPaper.edge) }
        .accessibilityElement(children: .contain)
        .buttonStyle(MemoryCommandStyle(tint: RoomPaper.clay))
        .accessibilityIdentifier("batch-bar")
    }

    private func batchButton(_ title: String, _ symbol: String, id: String, role: ButtonRole? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) { batchLabel(title, symbol) }
            .accessibilityIdentifier(id)
    }

    private func batchLabel(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.body.weight(.medium))
            Text(title).font(.caption)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(.rect)
    }

    /// 从家具移出 for the ticked photos. On one piece it takes them off at once; on several it
    /// first asks which piece, or all of them.
    @ViewBuilder
    private func batchUnlink(_ chosen: [String], holding: [PhotoFurniture]) -> some View {
        let title = String(localized: "从家具移出")
        if holding.count > 1 {
            Menu {
                unlinkChoices(heading: String(localized: "选中的照片在 \(holding.count) 件家具里"), holding) { unlink(chosen, from: $0) }
            } label: {
                batchLabel(title, "rectangle.badge.minus")
            }
            .menuOrder(.fixed)
            .accessibilityHint("照片留在照片库里，家具也还在")
            .accessibilityIdentifier("batch-unlink")
        } else {
            batchButton(title, "rectangle.badge.minus", id: "batch-unlink") { unlink(chosen, from: holding) }
                .disabled(holding.isEmpty)
                .accessibilityHint(holding.isEmpty ? String(localized: "选中的照片都不在家具里") : String(localized: "照片留在照片库里，家具也还在"))
        }
    }

    /// The pieces to take photos off, under a heading, then all of them: the same list in the
    /// long-press menu and the batch bar. `take(nil)` means every piece.
    @ViewBuilder
    private func unlinkChoices(heading: String, _ pieces: [PhotoFurniture], take: @escaping ([PhotoFurniture]?) -> Void) -> some View {
        Section(heading) {
            ForEach(pieces) { piece in
                Button(pieceName(piece)) { take([piece]) }
            }
        }
        Button(String(localized: "从全部 \(pieces.count) 件家具移出")) { take(nil) }
    }

    @ViewBuilder
    private func exportButtons(_ ids: [String]) -> some View {
        ForEach(exportActions(ids), id: \.self) { action in
            Button(action.title, systemImage: action.symbol) { export = ExportRequest(ids: ids, action: action) }
        }
    }

    /// What 分享或导出 offers for `ids`: the menus and VoiceOver's actions list the same.
    private func exportActions(_ ids: [String]) -> [PhotoExportAction] {
        // As on the photo's own page: only photos the system library knows can join its album.
        let album = model.photoLibrary.isOn
            && (ids.count > 1 || ids.contains { model.photo($0)?.assetIdentifier != nil || model.photo($0)?.cloudIdentifier != nil })
        return [.share, .shareFile, .save] + (album ? [.album] : [])
    }

    /// A piece's name, saying so when it is in the storage box rather than in a room.
    private func pieceName(_ piece: PhotoFurniture) -> String {
        model.furniture(piece.instanceId) == nil ? String(localized: "\(piece.shownName)（在收纳箱）") : piece.shownName
    }

    private func noticeBar(_ notice: BatchNotice) -> some View {
        HStack(spacing: 12) {
            Text(notice.message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("撤销") { undo(notice) }
                .font(.subheadline.weight(.semibold))
                .disabled(working)
                .accessibilityIdentifier("undo-batch")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(RoomPaper.paper)
        .overlay(alignment: .top) { Divider().overlay(RoomPaper.edge) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("batch-notice")
        .task(id: notice.id) {
            // Long enough to read and reach; the change itself stays either way.
            try? await Task.sleep(for: .seconds(8))
            if self.notice?.id == notice.id { self.notice = nil }
        }
    }

    private func link(_ ids: [String], to item: PhotoFurniture) {
        run {
            switch await model.linkPhotos(ids, to: item.instanceId) {
            case .success(let fresh):
                stopSelecting()
                guard !fresh.isEmpty else {
                    failure = String(localized: "这些照片已经在「\(item.shownName)」里了。")
                    return
                }
                let skipped = ids.count - fresh.count
                notice = BatchNotice(
                    message: skipped == 0
                        ? String(localized: "已把 \(fresh.count) 张照片放进「\(item.shownName)」")
                        : String(localized: "已把 \(fresh.count) 张照片放进「\(item.shownName)」，另外 \(skipped) 张本来就在"),
                    undo: .unlink(photoIds: fresh, instanceId: item.instanceId))
            case .failure(let failed):
                failure = failed.message
            }
        }
    }

    private func favorite(_ ids: [String], _ value: Bool) {
        run {
            switch await model.setFavorite(ids, value) {
            case .success(let changed):
                stopSelecting()
                guard !changed.isEmpty else { return }
                notice = BatchNotice(message: value ? String(localized: "已收藏 \(changed.count) 张照片") : String(localized: "已取消收藏 \(changed.count) 张照片"),
                                     undo: .favorite(photoIds: changed, !value))
            case .failure(let failed):
                failure = failed.message
            }
        }
    }

    /// Takes photos off `pieces` (nil = every piece they are on). The photos stay in the
    /// library; one that is on no piece any more shows under 未归位 again.
    private func unlink(_ ids: [String], from pieces: [PhotoFurniture]?) {
        run {
            switch await model.unlinkPhotos(ids, fromPieces: pieces?.map(\.instanceId)) {
            case .success(let receipt):
                stopSelecting()
                guard !receipt.removed.isEmpty else { return }
                let photos = Set(receipt.removed.map(\.link.photoId)).count
                let touched = Set(receipt.removed.map(\.instanceId))
                let message: String
                if touched.count == 1, let only = touched.first, let piece = model.anyFurniture(only) {
                    message = String(localized: "已把 \(photos) 张照片从「\(piece.shownName)」移出")
                } else {
                    message = String(localized: "已把 \(photos) 张照片从 \(touched.count) 件家具移出")
                }
                notice = BatchNotice(message: message, undo: .relink(receipt))
            case .failure(let failed):
                failure = failed.message
            }
        }
    }

    /// Makes the photo stand for `piece` in lists, with 撤销 back to the cover it had.
    private func setCover(_ photoId: String, of piece: PhotoFurniture) {
        let previous = piece.cover
        run {
            if let failed = await model.setCover(photoId, of: piece.instanceId) {
                failure = failed.message
            } else {
                notice = BatchNotice(message: String(localized: "已设为「\(piece.shownName)」的封面"),
                                     undo: .cover(instanceId: piece.instanceId, previous: previous))
            }
        }
    }

    private func delete(_ ids: [String]) {
        run {
            if let failed = await model.deletePhotos(ids) {
                failure = failed.message
            } else {
                notice = nil
                stopSelecting()
            }
        }
    }

    private func undo(_ notice: BatchNotice) {
        run {
            let failed: PhotoSaveFailure?
            switch notice.undo {
            case .unlink(let ids, let instanceId):
                failed = await model.unlinkPhotos(ids, from: instanceId)
            case .favorite(let ids, let value):
                if case .failure(let failure) = await model.setFavorite(ids, value) { failed = failure } else { failed = nil }
            case .relink(let receipt):
                failed = await model.undoUnlink(receipt)
            case .cover(let instanceId, let previous):
                // The old cover may have left the piece since: then the first photo stands for it.
                let stillThere = previous.flatMap { id in model.anyFurniture(instanceId)?.sources.contains { $0.photoId == id } == true ? id : nil }
                failed = await model.setCover(stillThere, of: instanceId)
            }
            if let failed { failure = failed.message } else { self.notice = nil }
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        guard !working else { return }
        working = true
        Task {
            await work()
            working = false
        }
    }

    // MARK: Filters

    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { filterChips; furnitureChipIfAny }
            // The three kinds of photo on one line, the furniture filter under them.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { filterChips }
                furnitureChipIfAny
            }
            VStack(alignment: .leading, spacing: 8) { filterChips; furnitureChipIfAny }
        }
        // 9.1's window: the chips together, 6 out, not the bar's margins (VISUAL §18.2 item 2).
        .tourAnchor("photo-filters", form: .plate(corner: 22))
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("筛选照片")
    }

    @ViewBuilder
    private var filterChips: some View {
        ForEach(PhotoFilter.allCases, id: \.self) { filter in
            let selected = model.photos.filter == filter
            let count = PhotoLibrary.count(in: model.shownState, filter: filter, onFurniture: furnitureFilter,
                                           linkedElsewhere: model.sync.photosOnNewerPieces)
            Button {
                model.photos.filter = filter
            } label: {
                Text("\(Wording.filterTitle(filter)) \(count)")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .foregroundStyle(selected ? RoomPaper.paper : RoomPaper.ink)
                    .background(selected ? RoomPaper.ink : RoomPaper.paper, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(Wording.filterTitle(filter))，\(count) 张")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("filter-\(filter.rawValue)")
            // 9.1 lets a tap on 「未放进家具」 through (LINES.md T5.14).
            .tourAnchor(filter == .unlinked ? "filter-unlinked" : "", form: .plate(corner: 22))
        }
    }

    @ViewBuilder
    private var furnitureChipIfAny: some View {
        if !model.state.allFurniture.isEmpty { furnitureChip }
    }

    /// Narrows the library to the photos on chosen pieces; combines with the chips before it.
    private var furnitureChip: some View {
        let active = furnitureFilter
        let names = model.state.allFurniture.filter { active.contains($0.instanceId) }
        let title = active.isEmpty ? String(localized: "家具")
            : names.count == 1 ? names[0].shownName : String(localized: "\(names.count) 件家具")
        return HStack(spacing: 0) {
            Button {
                furnitureFilterShown = true
            } label: {
                Label(title, systemImage: "sofa")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .padding(.leading, 14)
                    .padding(.trailing, active.isEmpty ? 14 : 6)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(active.isEmpty ? String(localized: "按家具筛选") : String(localized: "按家具筛选：\(Wording.quotedNames(names))"))
            .accessibilityAddTraits(active.isEmpty ? [] : .isSelected)
            .accessibilityIdentifier("filter-furniture")
            if !active.isEmpty {
                Button {
                    model.photos.furnitureFilter = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .padding(.trailing, 10)
                        .frame(minWidth: 34, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除家具筛选")
                .accessibilityIdentifier("clear-furniture-filter")
            }
        }
        .foregroundStyle(active.isEmpty ? Color.primary : Color(.systemBackground))
        .background(active.isEmpty ? Color(.secondarySystemBackground) : Color.primary, in: .capsule)
    }

    /// Every photo that is in no furniture, reviewed one at a time.
    private func sortAllButton(_ ids: [String]) -> some View {
        Button {
            dismiss()
            // The review opens over the room once this sheet has gone.
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                model.startSorting(ids)
            }
        } label: {
            Label("逐张整理这 \(ids.count) 张", systemImage: "tray.full")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal)
        .accessibilityHint("逐张决定照片放进哪件家具。可以随时停下。")
        .accessibilityIdentifier("sort-unlinked")
    }

    // MARK: Content

    /// `first`: the first photo on the page, 9.2's window.
    private func sectionView(_ section: PhotoSection, first: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    sectionTitle(section)
                    Spacer(minLength: 12)
                    sectionCount(section)
                }
                VStack(alignment: .leading, spacing: 2) {
                    sectionTitle(section)
                    sectionCount(section)
                }
            }
            .padding(.horizontal)

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(section.photos) { photo in
                    let linked = model.furniture(containingPhoto: photo.photoId)
                    if selecting {
                        let isSelected = selected.contains(photo.photoId)
                        Button {
                            if isSelected { selected.remove(photo.photoId) } else { selected.insert(photo.photoId) }
                        } label: {
                            SelectablePhotoCell(photo: photo, linkedTo: linked, selected: isSelected)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("照片")
                        .accessibilityValue(PhotoCell.summary(photo, linkedTo: linked,
                                                                              onNewerPiece: model.sync.photosOnNewerPieces.contains(photo.photoId)))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityHint(isSelected ? "取消选中" : "选中")
                        .accessibilityIdentifier("library-photo")
                    } else {
                        NavigationLink(value: photo.photoId) {
                            PhotoCell(photo: photo, linkedTo: linked)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            photoMenu(photo, linked: linked)
                        } preview: {
                            PhotoMenuPreview(photo: photo).environment(model)
                        }
                        .confirmationDialog("删除这张照片？", isPresented: deleteOneBinding(photo.photoId), titleVisibility: .visible) {
                            Button("删除照片", role: .destructive) { delete([photo.photoId]) }
                                .accessibilityIdentifier("confirm-delete-photo")
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text(deleteWords)
                        }
                        .accessibilityLabel("照片")
                        .accessibilityValue(PhotoCell.summary(photo, linkedTo: linked,
                                                                              onNewerPiece: model.sync.photosOnNewerPieces.contains(photo.photoId)))
                        // VoiceOver says actions are available; they are the long-press menu's.
                        .accessibilityHint("查看照片和便签")
                        .accessibilityActions { photoActions(photo, linked: linked) }
                        .accessibilityIdentifier("library-photo")
                        .tourAnchor(photo.photoId == first ? "library-photo" : "", form: .plate(corner: 12))
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: One photo's long-press menu

    private func askToDelete(_ chosen: [String]) {
        let asked = selected
        Task {
            let loss = await model.photoLoss(chosen)
            // Confirming deletes what is selected then: never ask about another selection.
            guard selected == asked else { return }
            let onFurniture = chosen.filter { model.libraryIndex.isLinked($0) }
            let pieces = Set(onFurniture.flatMap { model.furniture(containingPhoto: $0).map(\.instanceId) })
            deleteWords = Wording.deletionMessage(loss: loss, onFurniture: onFurniture.count, furniture: pieces.count)
            deleteAsked = true
        }
    }

    private func askToDeleteOne(_ id: String) {
        Task {
            let loss = await model.photoLoss([id])
            deleteWords = Wording.deletionMessage(model.state.deletionImpact(photoId: id), loss: loss)
            deleteOne = id
        }
    }

    private func deleteOneBinding(_ photoId: String) -> Binding<Bool> {
        Binding(get: { deleteOne == photoId }, set: { if !$0, deleteOne == photoId { deleteOne = nil } })
    }

    /// What can be done with one photo without opening it. 设为封面 and 从家具移出 appear only
    /// for a photo on furniture; on several pieces they list the pieces.
    @ViewBuilder
    private func photoMenu(_ photo: PhotoRecord, linked: [PhotoFurniture]) -> some View {
        let id = photo.photoId
        Section {
            Button(photo.favorite ? String(localized: "取消收藏") : String(localized: "action.favorite", defaultValue: "收藏", comment: "Action on photos: mark them as favorite"),
                   systemImage: photo.favorite ? "heart.slash" : "heart") { favorite([id], !photo.favorite) }
            if let piece = linked.first, linked.count == 1 {
                coverButton(id, of: piece, title: piece.cover == id ? String(localized: "已是「\(piece.shownName)」的封面") : String(localized: "设为「\(piece.shownName)」的封面"),
                            icon: "star.square")
            } else if linked.count > 1 {
                Menu(String(localized: "设为封面"), systemImage: "star.square") {
                    ForEach(linked) { piece in
                        coverButton(id, of: piece, title: piece.cover == id ? String(localized: "\(pieceName(piece))（已是封面）") : pieceName(piece))
                    }
                }
            }
            // Putting on comes before taking off, here and in the batch bar.
            if model.state.allFurniture.count > linked.count {
                Button(String(localized: "放进家具…"), systemImage: "rectangle.badge.plus") {
                    linking = LinkRequest(ids: [id], hidden: Set(linked.map(\.instanceId)))
                }
            }
            if let piece = linked.first, linked.count == 1 {
                Button(String(localized: "从「\(pieceName(piece))」移出"), systemImage: "rectangle.badge.minus") { unlink([id], from: [piece]) }
            } else if linked.count > 1 {
                Menu(String(localized: "从家具移出"), systemImage: "rectangle.badge.minus") {
                    unlinkChoices(heading: String(localized: "这张照片在 \(linked.count) 件家具里"), linked) { unlink([id], from: $0) }
                }
            }
        }
        Section {
            Menu(String(localized: "分享或导出"), systemImage: "square.and.arrow.up") { exportButtons([id]) }
        }
        Section {
            Button(String(localized: "删除"), systemImage: "trash", role: .destructive) { askToDeleteOne(id) }
        }
    }

    /// 设为封面 for one piece; marked and disabled when the photo already stands for it. In the
    /// submenu the pieces carry no icon, only the current cover its checkmark.
    @ViewBuilder
    private func coverButton(_ photoId: String, of piece: PhotoFurniture, title: String, icon: String? = nil) -> some View {
        if piece.cover == photoId {
            Button(title, systemImage: "checkmark") {}.disabled(true)
        } else if let icon {
            Button(title, systemImage: icon) { setCover(photoId, of: piece) }
        } else {
            Button(title) { setCover(photoId, of: piece) }
        }
    }

    /// The same as the long-press menu, flat, for VoiceOver's actions rotor.
    @ViewBuilder
    private func photoActions(_ photo: PhotoRecord, linked: [PhotoFurniture]) -> some View {
        let id = photo.photoId
        Button(photo.favorite ? String(localized: "取消收藏") : String(localized: "action.favorite", defaultValue: "收藏", comment: "Action on photos: mark them as favorite")) {
            favorite([id], !photo.favorite)
        }
        ForEach(linked.filter { $0.cover != id }) { piece in
            Button(String(localized: "设为「\(piece.shownName)」的封面")) { setCover(id, of: piece) }
        }
        if model.state.allFurniture.count > linked.count {
            Button(String(localized: "放进家具…")) { linking = LinkRequest(ids: [id], hidden: Set(linked.map(\.instanceId))) }
        }
        ForEach(linked) { piece in
            Button(String(localized: "从「\(pieceName(piece))」移出")) { unlink([id], from: [piece]) }
        }
        if linked.count > 1 {
            Button(String(localized: "从全部 \(linked.count) 件家具移出")) { unlink([id], from: nil) }
        }
        ForEach(exportActions([id]), id: \.self) { action in
            Button(action.title) { export = ExportRequest(ids: [id], action: action) }
        }
        Button(String(localized: "删除")) { askToDeleteOne(id) }
    }

    private func sectionTitle(_ section: PhotoSection) -> some View {
        Text(Wording.monthTitle(section.month))
            .font(.system(.title3, design: .serif, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(section.month == nil ? "section-unknown" : "section-\(section.month ?? "")")
    }

    private func sectionCount(_ section: PhotoSection) -> some View {
        Text("\(section.photos.count) 张")
            .font(.subheadline)
            .foregroundStyle(Color.subtle)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !furnitureFilter.isEmpty {
            emptyPage("选中的家具里没有这样的照片", detail: "换一件家具，或者清除家具筛选。")
        } else {
            switch model.photos.filter {
            case .all:
                emptyPage("还没有照片", detail: "回到房间，点“添加照片”开始。")
            case .favorites:
                emptyPage("还没有收藏的照片", detail: "打开一张照片，就能收藏它。")
            case .unlinked:
                emptyPage("每张照片都在家具里", detail: "还没放进家具的照片会出现在这里。")
            }
        }
    }

    private func emptyPage(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(spacing: 10) {
            MemoryEmblem(.album).frame(width: 100, height: 72)
            Text(title)
                .font(.system(.title3, design: .serif, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(detail).font(.body)
        }
        .foregroundStyle(RoomPaper.ink)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(maxWidth: 480)
        .memoryCard(.album)
        .padding(.horizontal)
        .frame(maxWidth: .infinity)
    }
}

/// The long-press preview: the whole thumbnail at the photo's own shape (the grid crops it to a
/// square), with its capture day. The stored thumbnail, never the original, so it opens at once.
private struct PhotoMenuPreview: View {
    let photo: PhotoRecord

    var body: some View {
        let ratio = CGFloat(max(photo.width, 1)) / CGFloat(max(photo.height, 1))
        VStack(alignment: .leading, spacing: 0) {
            ThumbnailView(photoId: photo.photoId)
                .aspectRatio(min(max(ratio, 0.6), 1.8), contentMode: .fit)
                .clipped()
            Text(photo.captureLine)
                .font(.system(.subheadline, design: .serif, weight: .semibold))
                .foregroundStyle(RoomPaper.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(width: 300)
        .background(RoomPaper.sheet)
    }
}

/// A square thumbnail (never the original) with what the user needs to tell photos apart.
struct PhotoCell: View {
    let photo: PhotoRecord
    let linkedTo: [PhotoFurniture]

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { ThumbnailView(photoId: photo.photoId) }
            .clipped()
            .memoryPhotoMount()
            .overlay(alignment: .topTrailing) {
                if photo.favorite { badge("heart.fill") }
            }
            .overlay(alignment: .bottomLeading) {
                if linkedTo.isEmpty {
                    badge("tray.full")
                } else if linkedTo.count > 1 {
                    // On more than one piece: say how many, so the many-to-many link is visible.
                    Label(String(linkedTo.count), systemImage: "sofa.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: .capsule)
                        .padding(5)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
            .accessibilityHidden(true)
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.55), in: .circle)
            .padding(5)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityHidden(true)
    }

    /// Spoken after "照片": capture day, favourite, which furniture, whether it has a note.
    static func summary(_ photo: PhotoRecord, linkedTo: [PhotoFurniture], onNewerPiece: Bool = false) -> String {
        var parts = [photo.captureLine]
        if photo.favorite { parts.append(String(localized: "已收藏")) }
        if linkedTo.isEmpty {
            parts.append(onNewerPiece ? String(localized: "在更新版本的家具上") : String(localized: "还没放进家具"))
        } else {
            parts.append(String(localized: "在\(Wording.quotedNames(linkedTo))里"))
        }
        if !photo.note.isEmpty { parts.append(String(localized: "有便签")) }
        return Wording.phrases(parts)
    }
}

private extension PhotoExportAction {
    /// The icon in the long-press menu and the batch bar's 分享或导出.
    var symbol: String {
        switch self {
        case .share: "square.and.arrow.up"
        case .shareFile: "doc"
        case .save: "square.and.arrow.down"
        case .album: "rectangle.stack.badge.plus"
        }
    }
}
