import MeowverseCore
import PhotosUI
import SwiftUI
import UIKit

/// The moment the app exists for: tap the sofa, see the photo that put it there. Also shows a
/// piece that has no photos yet, and a piece in the storage box (with the way back into the room).
struct FurnitureDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let instanceId: String
    @Binding var busyDetailID: String?
    @State private var navigation: [String] = []
    let onClose: () -> Void
    @State private var page: String?
    /// With several photos the album comes first; this is the photo opened from it.
    @State private var pagerShown = false
    @State private var unlinking = false
    @State private var removeAsked = false
    @State private var failure: String?
    @State private var pickerShown = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var pickerRequested = false
    @State private var addNotice: String?
    /// False once the page is closed; an add still running then reports to the room.
    @State private var onScreen = true
    /// What the last confirmed page of suggestions filed, with 撤销 (photo boards only).
    @State private var filedNotice: FiledNotice?
    /// "选择" mode in the album: taps tick photos instead of opening them.
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var libraryPickerShown = false
    /// The piece picker, open to move the chosen photos or to put them on another piece as well.
    @State private var target: Target?
    @State private var working = false
    @State private var orderShown = false

    private enum Target: String, Identifiable {
        case move, also
        var id: String { rawValue }
    }

    /// In the storage box rather than in the room.
    private var stored: Bool { model.furniture(instanceId) == nil }

    private var isPhotoBoard: Bool {
        guard let item = model.anyFurniture(instanceId) else { return false }
        return model.catalog?.model(id: item.modelId)?.category == .photoBoard
    }

    private var hasOngoingAction: Bool {
        !navigation.isEmpty || selecting || unlinking || removeAsked || working || orderShown
            || pickerRequested || pickerShown || libraryPickerShown || target != nil
            || failure != nil || addNotice != nil || model.photos.adding != nil
    }

    var body: some View {
        NavigationStack(path: $navigation) {
            Group {
                if let item = model.anyFurniture(instanceId) {
                    content(item)
                } else {
                    ContentUnavailableView("这件家具已经不在了", systemImage: "sofa")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { photoId in
                PhotoDetailView(photoId: photoId, context: .furniture(instanceId))
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onClose() }.accessibilityIdentifier("close-detail")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu("更多", systemImage: "ellipsis.circle") {
                        let locked = model.anyFurniture(instanceId)?.isLocked == true
                        if !stored {
                            Button("编辑家具", systemImage: "slider.horizontal.3") {
                                onClose()
                                model.showRoom(ofFurniture: instanceId)
                                model.movingFurnitureID = instanceId
                            }
                            .disabled(locked)
                            Button("在房间里定位", systemImage: "scope") {
                                onClose()
                                model.locate(instanceId)
                            }
                            .accessibilityIdentifier("locate-furniture")
                            if model.hasSeveralRooms {
                                Menu("搬到另一个房间", systemImage: "arrow.right.square") {
                                    ForEach(model.state.allRooms.filter { $0.roomId != model.state.roomId(ofFurniture: instanceId) }) { room in
                                        Button(model.roomName(room)) { move(to: room.roomId) }
                                    }
                                }
                                .disabled(locked)
                            }
                        }
                        Button(locked ? "解锁" : "锁定", systemImage: locked ? "lock.open" : "lock") { setLocked(!locked) }
                            .accessibilityIdentifier("toggle-lock")
                        #if DEBUG || DRILLS
                        if model.options.offerSyntheticPhoto {
                            Button("再添一张合成照片", systemImage: "photo.badge.plus") {
                                let variant = (model.anyFurniture(instanceId)?.sources.count ?? 0)
                                let delay = model.options.syntheticLoadDelay, hangs = model.options.syntheticLoadHangs > 0
                                add {
                                    await model.addPhotos(to: instanceId, loaders: [{
                                        if hangs { await SyntheticPhoto.neverArrives() }
                                        try await SyntheticPhoto.slowly(delay)
                                        return SyntheticPhoto.jpeg(variant: variant)
                                    }])
                                }
                            }
                        }
                        #endif
                        if model.state.photos.count > (model.anyFurniture(instanceId)?.sources.count ?? 0) {
                            Button("从照片库选照片", systemImage: "photo.on.rectangle") { libraryPickerShown = true }
                                .accessibilityIdentifier("add-from-library")
                        }
                        if (model.anyFurniture(instanceId)?.sources.count ?? 0) > 1 {
                            Button("调整照片顺序", systemImage: "arrow.up.arrow.down") { orderShown = true }
                                .accessibilityIdentifier("reorder-photos")
                        }
                        if !stored {
                            Button("收进收纳箱", systemImage: "archivebox") { stow() }
                                .disabled(locked)
                                .accessibilityIdentifier("stow-furniture")
                        }
                        Button("删除家具", systemImage: "trash", role: .destructive) { removeAsked = true }
                            .disabled(locked)
                    }
                    .accessibilityIdentifier("furniture-more")
                    .tourAnchor("furniture-more", form: .circle, padding: 3)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(model.anyFurniture(instanceId)?.sources.isEmpty == true ? "添加照片" : "再添一张照片", systemImage: "photo.badge.plus") { pickerRequested = true }
                        .disabled(model.photos.adding != nil)
                        .accessibilityHint("从相册给这件家具选几张照片。只有你选中的会被读取。")
                        .accessibilityIdentifier("add-source-photo")
                        .tourAnchor("add-source-photo", form: .circle, padding: 3)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    PhotoStorageBanner()
                    SuggestedFilingNotice(notice: $filedNotice)
                    if isPhotoBoard, !selecting, model.anyFurniture(instanceId)?.sources.isEmpty == false {
                        // Photos put on a board for want of a piece may belong to one by now.
                        SuggestionRerunEntry(scope: .photoBoards, notice: $filedNotice)
                            // The inset is outside the page's tint: the album accent, as 「收藏、便签和日期」.
                            .tint(MemoryChapter.album.accent)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(RoomPaper.paper)
                            .overlay(alignment: .top) { Divider().overlay(RoomPaper.edge) }
                    }
                    // Adding runs in the background: the photos already here stay browsable meanwhile.
                    if let progress = model.photos.adding {
                        BatchProgressBar(phase: .importing, done: progress.shown, total: progress.total,
                                         note: Text("iCloud 里的原图要先下载，需要网络，可能要等一会儿。可以先点「完成」去做别的，照片会接着添加。"))
                            .accessibilityIdentifier("adding-progress")
                    }
                    if selecting {
                        selectionBar
                    } else if stored, let item = model.anyFurniture(instanceId) {
                        storedBar(for: item)
                    }
                }
            }
        }
        .sheet(isPresented: $libraryPickerShown) {
            let name = model.anyFurniture(instanceId)?.shownName ?? ""
            LibraryPhotoPickerView(title: String(localized: "从照片库选"),
                                   hidden: Set(model.anyFurniture(instanceId)?.sources.map(\.photoId) ?? []),
                                   confirmTitle: { $0 == 0 ? String(localized: "放进「\(name)」") : String(localized: "把 \($0) 张放进「\(name)」") }) { ids in
                run {
                    if case .failure(let failed) = await model.linkPhotos(ids, to: instanceId) { failure = failed.message }
                    pagerShown = false
                }
            }
        }
        .sheet(isPresented: $orderShown) {
            if let item = model.anyFurniture(instanceId) {
                AlbumOrderView(item: item) { order in
                    run {
                        if let failed = await model.reorderPhotos(order, of: instanceId) { failure = failed.message }
                    }
                }
            }
        }
        .sheet(item: $target) { target in
            let chosen = chosenPhotos
            FurniturePickerView(title: target == .move ? String(localized: "移到另一件家具") : String(localized: "也放进另一件家具"),
                                prompt: target == .move
                                    ? String(localized: "选中的 \(chosen.count) 张照片会离开这件家具，放进你选的那件。")
                                    : String(localized: "选中的 \(chosen.count) 张照片会同时在这件家具和你选的那件里。"),
                                hidden: [instanceId]) { item in
                run {
                    let failed: PhotoSaveFailure?
                    if target == .move {
                        failed = await model.movePhotos(chosen, from: instanceId, to: item.instanceId)
                    } else if case .failure(let failure) = await model.linkPhotos(chosen, to: item.instanceId) {
                        failed = failure
                    } else {
                        failed = nil
                    }
                    if let failed { failure = failed.message } else { stopSelecting() }
                }
            }
        }
        .onChange(of: hasOngoingAction, initial: true) { _, busy in
            if busy { busyDetailID = instanceId } else if busyDetailID == instanceId { busyDetailID = nil }
        }
        .onDisappear { if busyDetailID == instanceId { busyDetailID = nil } }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onChange(of: model.anyFurniture(instanceId)?.sources.count ?? 0) { _, count in
            // The album (and so "选择") only exists from two photos on.
            if count < 2 { stopSelecting() }
        }
        .modifier(PhotoPickerGate(request: $pickerRequested, pickerShown: $pickerShown))
        .photosPicker(isPresented: $pickerShown, selection: $picked, maxSelectionCount: 20, matching: .images, preferredItemEncoding: .current,
                      photoLibrary: .shared())
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            add { await model.addPhotos(items, to: instanceId) }
        }
        .confirmationDialog("删除这件家具？", isPresented: $removeAsked, titleVisibility: .visible) {
            if !stored {
                Button("改为收进收纳箱") { stow() }.accessibilityIdentifier("stow-instead")
            }
            Button("删除", role: .destructive) { remove() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(stored
                 ? "家具会被删除，不能再放回房间。它的照片仍留在照片库里。"
                 : "家具会被删除，它的照片仍留在照片库里。只是暂时不想摆的话，可以收进收纳箱，随时能放回房间。")
        }
        .alert("添加照片", isPresented: Binding(get: { addNotice != nil }, set: { if !$0 { addNotice = nil } })) {
            Button("好") {}
        } message: {
            Text(addNotice ?? "")
        }
        .alert("没能保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好") {}
        } message: {
            Text(failure ?? "")
        }
    }

    @ViewBuilder
    private func content(_ item: PhotoFurniture) -> some View {
        let category = model.catalog?.model(id: item.modelId)?.category
        VStack(spacing: 0) {
            if item.isLocked { lockedBanner }
            if item.sources.isEmpty {
                noPhotos()
            } else if item.sources.count > 1, !pagerShown {
                album(item)
            } else if let selected = item.sources.first(where: { $0.photoId == page }) ?? item.sources.first {
                if item.sources.count > 1 {
                    Button { pagerShown = false } label: {
                        Label("全部 \(item.sources.count) 张照片", systemImage: "square.grid.2x2")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    }
                    .padding(.horizontal)
                    .accessibilityIdentifier("show-album")
                }
                if typeSize.isAccessibilitySize {
                    ScrollView {
                        albumPage(item, selected: selected, category: category)
                            .padding(.vertical, 8)
                    }
                } else {
                    Spacer(minLength: 8)
                    albumPage(item, selected: selected, category: category)
                    Spacer(minLength: 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: item.sources) { old, new in
            guard let page, let oldIndex = old.firstIndex(where: { $0.photoId == page }),
                  !new.contains(where: { $0.photoId == page }) else { return }
            self.page = new.isEmpty ? nil : new[min(oldIndex, new.count - 1)].photoId
        }
        .memoryPage(.album)
        .navigationTitle(item.shownName)
    }

    private func albumPage(_ item: PhotoFurniture, selected: PhotoCarrierSource, category: FurnitureCategory?) -> some View {
        let photo = model.photo(selected.photoId)
        let printRatio = photo.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 4 / 3
        return VStack(alignment: .leading, spacing: 0) {
            photoPager(item, selected: selected)
                .aspectRatio(max(0.85, min(printRatio, 2.4)), contentMode: .fit)
                .padding(.horizontal, 16)
            photoCaption(selected, category: category)
            if let photo { photoActions(photo) }
        }
        .frame(maxWidth: 740)
    }

    private func photoPager(_ item: PhotoFurniture, selected: PhotoCarrierSource) -> some View {
        TabView(selection: Binding(get: { selected.photoId }, set: { page = $0 })) {
            ForEach(item.sources, id: \.photoId) { source in
                let day = model.photo(source.photoId)?.captureLine ?? String(localized: "拍摄日期未知")
                StoredOriginalView(photoId: source.photoId, label: String(localized: "「\(item.shownName)」的照片，\(day)"),
                                   imageIdentifier: "original-photo")
                    .tag(source.photoId)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: item.sources.count > 1 ? .automatic : .never))
        .disabled(unlinking)
    }

    /// A piece placed straight from the catalog, or one whose photos were all taken off: it says
    /// so plainly instead of implying a source.
    private func noPhotos() -> some View {
        // Scrolls, so nothing is cut when the text is large and the storage bar takes room below.
        ScrollView {
            VStack(spacing: 12) {
                Image(decorative: "EmptyPhotoFrame")
                    .resizable().scaledToFit().frame(width: 116, height: 84)
                // Its photos are on another device and not here yet: never "no photos yet".
                let syncing = model.sync.pendingLinksByPiece[instanceId] ?? 0
                Text(syncing > 0 ? "照片还在同步" : "还没有照片")
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("no-photos-title")
                Text(syncing > 0 ? "这件家具在别的设备上有 \(syncing) 张照片，传过来以后就能在这里看到。" : "给它添上照片，以后点它就能看到。")
                    .foregroundStyle(Color.subtle)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("添加照片") { pickerRequested = true }
                    .foregroundStyle(RoomPaper.sealInk)
                    .tint(RoomPaper.clay)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.photos.adding != nil)
                    .padding(.top, 4)
                    .accessibilityHint("从相册给这件家具选几张照片。只有你选中的会被读取。")
                    .accessibilityIdentifier("add-first-photo")
                if !model.state.photos.isEmpty {
                    Button("从照片库选") { libraryPickerShown = true }
                        .buttonStyle(.bordered)
                        .accessibilityHint("选已经在照片库里的照片，不用再从相册导入")
                        .accessibilityIdentifier("add-first-from-library")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.vertical, 32)
        }
        // Contained, so the button inside keeps its own identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("furniture-no-photos")
    }

    /// Shown for a piece in the storage box: where it is, and the way back.
    private func storedBar(for item: PhotoFurniture) -> some View {
        let status = item.sources.isEmpty ? String(localized: "收纳箱") : String(localized: "在收纳箱里，照片都还在")
        return VStack(spacing: 4) {
            Label(status, systemImage: "archivebox")
                .font(.footnote)
                .foregroundStyle(Color.subtle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
                .padding(.top, 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(status)
                .accessibilityIdentifier("stored-banner")
            primaryButton(String(localized: "放回房间"), enabled: !item.isLocked) {
                // The placement editor opens once this sheet has gone: never two sheets at once.
                onClose()
                model.restoringFurnitureID = instanceId
            }
            .accessibilityIdentifier("restore-furniture")
        }
        .background(RoomPaper.paper)
        .overlay(alignment: .top) { Divider().overlay(RoomPaper.edge) }
    }

    /// Says the piece is locked and what that means, with the way out.
    private var lockedBanner: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) { lockedText; Spacer(minLength: 0); unlockButton }
            VStack(alignment: .leading, spacing: 4) { lockedText; unlockButton }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("locked-banner")
    }

    private var lockedText: some View {
        Label("已锁定：不能移动、换款式、收纳或删除", systemImage: "lock.fill")
            .font(.footnote)
            .foregroundStyle(Color.subtle)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var unlockButton: some View {
        Button("解锁") { setLocked(false) }
            .font(.footnote.weight(.semibold))
            .frame(minHeight: 44)
            .accessibilityIdentifier("unlock-furniture")
    }

    /// Moves the piece to another room; the room then shows it there.
    private func move(to roomId: String) {
        run {
            if let failed = await model.moveFurniture(instanceId, toRoom: roomId) { failure = failed.message } else { onClose() }
        }
    }

    private func setLocked(_ locked: Bool) {
        run {
            if let failed = await model.setLocked([instanceId], locked) { failure = failed.message }
        }
    }

    /// The ticked photos that are still on this piece, in album order.
    private var chosenPhotos: [String] {
        (model.anyFurniture(instanceId)?.sources.map(\.photoId) ?? []).filter(selected.contains)
    }

    private func stopSelecting() {
        selecting = false
        selected = []
    }

    private func run(_ work: @escaping () async -> Void) {
        guard !working else { return }
        working = true
        Task {
            await work()
            working = false
        }
    }

    /// What can be done with the ticked photos. None of it deletes a photo.
    private var selectionBar: some View {
        let chosen = chosenPhotos
        let others = model.state.allFurniture.count > 1
        return HStack {
            barButton(String(localized: "移出"), "rectangle.badge.minus", id: "album-unlink") {
                run {
                    if let failed = await model.unlinkPhotos(chosen, from: instanceId) { failure = failed.message } else { stopSelecting() }
                }
            }
            .accessibilityHint("照片留在照片库里，家具也还在")
            barButton(String(localized: "移到…"), "arrow.right.square", id: "album-move") { target = .move }
                .disabled(!others)
            barButton(String(localized: "也放进…"), "plus.square.on.square", id: "album-also") { target = .also }
                .disabled(!others)
            barButton(String(localized: "设为封面"), "star.square", id: "album-cover") {
                run {
                    if let failed = await model.setCover(chosen.first, of: instanceId) { failure = failed.message } else { stopSelecting() }
                }
            }
            // One photo stands for the piece, and the one that already does needs no change.
            .disabled(chosen.count != 1 || chosen.first == model.anyFurniture(instanceId)?.cover)
            .accessibilityHint("选中一张时可用。家具列表里用它代表这件家具")
        }
        .buttonStyle(MemoryCommandStyle(tint: RoomPaper.clay))
        .disabled(chosen.isEmpty || working)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(RoomPaper.paper)
        .overlay(alignment: .top) { Divider().overlay(RoomPaper.edge) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("album-selection-bar")
    }

    private func barButton(_ title: String, _ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.body.weight(.medium))
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.rect)
        }
        .accessibilityIdentifier(id)
    }

    /// Every photo of this piece at once; tapping one opens it full size.
    private func album(_ item: PhotoFurniture) -> some View {
        let photos = item.sources.compactMap { model.photo($0.photoId) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(selecting ? String(localized: "已选 \(chosenPhotos.count) 张") : Wording.albumLine(photos))
                        .font(.subheadline)
                        .foregroundStyle(Color.subtle)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("album-summary")
                    Spacer(minLength: 12)
                    Button(selecting ? "取消" : "选择") {
                        if selecting { stopSelecting() } else { selecting = true }
                    }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityHint(selecting ? "" : "选中几张照片，移出或放进另一件家具")
                    .accessibilityIdentifier("album-select")
                }
                .padding(.horizontal)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 4)], spacing: 4) {
                    ForEach(photos) { photo in
                        let linked = model.furniture(containingPhoto: photo.photoId)
                        let isSelected = selected.contains(photo.photoId)
                        Button {
                            if selecting {
                                if isSelected { selected.remove(photo.photoId) } else { selected.insert(photo.photoId) }
                            } else {
                                page = photo.photoId
                                pagerShown = true
                            }
                        } label: {
                            if selecting {
                                SelectablePhotoCell(photo: photo, linkedTo: linked, selected: isSelected)
                            } else {
                                PhotoCell(photo: photo, linkedTo: linked)
                            }
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottomTrailing) {
                            if photo.photoId == item.cover {
                                Text("封面")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.55), in: .capsule)
                                    .padding(5)
                                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel("照片")
                        .accessibilityValue(Wording.phrases((photo.photoId == item.cover ? [String(localized: "封面")] : []) + [photo.captureLine] + (photo.favorite ? [String(localized: "已收藏")] : [])
                                                            + (linked.count > 1 ? [String(localized: "也在另外 \(linked.count - 1) 件家具里")] : [])))
                        .accessibilityAddTraits(selecting && isSelected ? .isSelected : [])
                        .accessibilityHint(selecting ? (isSelected ? "取消选中" : "选中") : "打开这张照片")
                        .accessibilityIdentifier("album-photo")
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(.vertical)
        }
        .accessibilityIdentifier("furniture-album")
    }

    /// Adds photos, then turns to the newest one. Anything not added is reported once, in words.
    private func add(_ work: @escaping () async -> AddPhotosSummary) {
        let generation = model.libraryGeneration
        Task {
            guard model.libraryGeneration == generation else { return }
            let summary = await work()
            guard model.libraryGeneration == generation, !model.switchingLibraries else { return }
            // One photo stays on screen full size; from two on, the album shows everything.
            model.photos.storageReceipt = PhotoStorageReceipt(photos: summary.added.compactMap(model.photo))
            guard onScreen else {
                // The page was closed meanwhile: the room reports how it went.
                if let message = summary.message {
                    model.batch.notice = message
                } else if !summary.added.isEmpty {
                    TransientNotice.show(String(localized: "已添加 \(summary.added.count) 张。"))
                }
                return
            }
            if let newest = summary.added.last { page = newest }
            if !summary.added.isEmpty { pagerShown = false }
            addNotice = summary.message
        }
    }

    private func remove() {
        Task {
            if let message = await model.remove(instanceId: instanceId) {
                failure = message
            } else {
                onClose()
            }
        }
    }

    /// Into the storage box: out of the room, photos still attached.
    private func stow() {
        Task {
            if let message = await model.stow(instanceId: instanceId) {
                failure = message
            } else {
                onClose()
            }
        }
    }

    private func photoCaption(_ source: PhotoCarrierSource, category: FurnitureCategory?) -> some View {
        let photo = model.photo(source.photoId)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                MemoryEmblem(.album).frame(width: 44, height: 34)
                Text(photo?.captureLine ?? String(localized: "拍摄日期未知"))
                    .font(.system(.headline, design: .serif, weight: .semibold))
                    .foregroundStyle(RoomPaper.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let provenance = model.state.provenance(of: source)
            if let line = Wording.sourceLine(provenance, category: category) {
                Label(line, systemImage: Wording.sourceSymbol(provenance))
                    .font(.subheadline)
                    .foregroundStyle(Color.subtle)
            } else {
                SuggestedFilingMark()
            }
            if let photo {
                Text("导入于 \(photo.importedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: AppLanguage.locale)))")
                    .font(.footnote)
                    .foregroundStyle(Color.subtle)
            }
            if let photo, !photo.note.isEmpty {
                Text(photo.note)
                    .font(.subheadline)
                    .lineLimit(3)
                    .accessibilityLabel("便签：\(photo.note)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
        .padding(12)
        .memoryCard(.album)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("photo-caption")
    }

    private func photoActions(_ photo: PhotoRecord) -> some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) { actionButtons(photo) }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { actionButtons(photo) }
                    VStack(alignment: .leading, spacing: 0) { actionButtons(photo) }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .disabled(unlinking)
    }

    @ViewBuilder
    private func actionButtons(_ photo: PhotoRecord) -> some View {
        NavigationLink(value: photo.photoId) {
            Label(photo.favorite ? "收藏、便签和日期（已收藏）" : "收藏、便签和日期", systemImage: "square.and.pencil")
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .accessibilityHint("编辑这张照片")
        .accessibilityIdentifier("photo-details")

        Button {
            guard !unlinking else { return }
            unlinking = true
            Task {
                failure = await model.unlinkPhoto(photo.photoId, from: instanceId)?.message
                unlinking = false
            }
        } label: {
            Label("从这件家具移出", systemImage: "rectangle.badge.minus")
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .accessibilityHint("照片留在照片库里，家具也还在")
        .accessibilityIdentifier("quick-unlink-photo")
    }
}

/// Pinch and double-tap zoom with the system scroll view, so it feels like Photos.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    /// When set, the scroll view itself is exposed to VoiceOver as one image with this label.
    var imageLabel: String?
    var imageIdentifier: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.bouncesZoom = true
        let imageView = context.coordinator.imageView
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
        if let imageLabel {
            scroll.isAccessibilityElement = true
            scroll.accessibilityTraits = .image
            scroll.accessibilityLabel = imageLabel
            scroll.accessibilityIdentifier = imageIdentifier
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard let scroll = recognizer.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
