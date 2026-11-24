import MeowverseCore
import SwiftUI

/// The furniture library: every piece the user has, in the room and in the storage box (which
/// keep their photos). It can be searched, narrowed and sorted, shown as rows or as covers, and
/// several pieces can be locked, put away or deleted at once. Also where a piece is added
/// straight from the catalog.
struct FurnitureListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var working = false
    @State private var failure: String?
    /// The pieces a delete was asked for, until it is confirmed or dropped.
    @State private var deleting: [PhotoFurniture]?
    /// What the last batch change did, shown above the batch bar for a few seconds.
    @State private var notice: String?

    private let gridColumns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        @Bindable var model = model
        let query = model.pieces.query
        let shown = model.shownFurniture
        let chosen = shown.filter { selected.contains($0.instanceId) }
        NavigationStack {
            ScrollView {
                // Not lazy: a lazy stack kept drawing a piece that had just been put away the way
                // it looked while ticked in the room. A home has tens of pieces, not thousands.
                VStack(alignment: .leading, spacing: 10) {
                    if !selecting { addButton }
                    placeBar
                    controls
                    if query.isNarrowed { narrowedLine(shown.count) }
                    if shown.isEmpty {
                        empty
                    } else if query.place == .all, query.sort == .added, query.ascending {
                        // The plain view keeps the two places apart, as the room does.
                        let room = shown.filter { model.furniture($0.instanceId) != nil }
                        let stored = shown.filter { model.furniture($0.instanceId) == nil }
                        header(roomTitle)
                        if room.isEmpty { roomEmpty }
                        pieces(room, showsPlace: false)
                        if !stored.isEmpty {
                            header(String(localized: "收纳箱"))
                            pieces(stored, showsPlace: false)
                            storedNote
                        }
                    } else {
                        header(query.place == .room ? roomTitle
                               : query.place == .stored ? String(localized: "收纳箱") : String(localized: "\(shown.count) 件家具"))
                        pieces(shown, showsPlace: query.place == .all)
                        if query.place == .stored { storedNote }
                    }
                }
                .padding()
            }
            // Chapter 10 begins while this page is on top (`TourPages`).
            .tourAnchor(TourPages.anchor(.furnitureLibrary), padding: 0)
            .searchable(text: $model.pieces.query.search, prompt: Text("搜索家具名字"))
            .memoryPage(.home)
            .navigationTitle(selecting ? String(localized: "已选 \(chosen.count) 件") : String(localized: "家具"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selecting {
                        Button(chosen.count == shown.count ? "全不选" : "全选") {
                            selected = chosen.count == shown.count ? [] : Set(shown.map(\.instanceId))
                        }
                        .disabled(shown.isEmpty)
                        .accessibilityIdentifier("select-all-furniture")
                    } else {
                        Button("选择") { selecting = true }
                            .buttonStyle(MemoryCommandStyle(tint: RoomPaper.moss))
                            .disabled(shown.isEmpty)
                            .accessibilityHint("选中几件家具，一起锁定、收纳或删除")
                            .accessibilityIdentifier("select-furniture")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if selecting {
                        Button("取消") { stopSelecting() }.accessibilityIdentifier("cancel-select-furniture")
                    } else {
                        Button("完成") { dismiss() }.accessibilityIdentifier("close-furniture-list")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if let notice { noticeBar(notice) }
                    if selecting { batchBar(chosen) }
                }
            }
        }
        .alert(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { pieces in
            Button(pieces.count == 1 ? String(localized: "删除") : String(localized: "删除 \(pieces.count) 件"), role: .destructive) { delete(pieces) }
            Button("取消", role: .cancel) {}
        } message: { pieces in
            Text(deleteMessage(pieces))
        }
        .alert("没能保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好") {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var roomTitle: String {
        // Each room has its own limit, so with several rooms one "n / 20" would mislead.
        model.hasSeveralRooms
            ? String(localized: "各个房间里共 \(model.state.placedFurniture.count) 件")
            : String(localized: "房间里 \(model.roomFurniture.count) / \(GridRules.maxItems)")
    }

    // MARK: Top of the page

    private var addButton: some View {
        Button {
            // The catalog opens once this sheet has gone: never two sheets at once.
            dismiss()
            model.addFurnitureShown = true
        } label: {
            Label("添加家具", systemImage: "plus")
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .card()
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityHint("从款式里选一件摆进房间，先不带照片")
        .accessibilityIdentifier("add-furniture")
        .tourAnchor("add-furniture", form: .plate(corner: 12))
    }

    /// Everything, the room, or the storage box.
    private var placeBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { placeChips }
            VStack(alignment: .leading, spacing: 8) { placeChips }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("按位置筛选")
    }

    @ViewBuilder
    private var placeChips: some View {
        ForEach(FurnitureQuery.Place.allCases, id: \.self) { place in
            let active = model.pieces.query.place == place
            let count = switch place {
            case .all: model.state.allFurniture.count
            case .room: model.state.placedFurniture.count
            case .stored: model.state.storedFurniture.count
            }
            Button {
                model.pieces.query.place = place
            } label: {
                Text(verbatim: "\(Wording.placeTitle(place)) \(count)")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .foregroundStyle(active ? RoomPaper.paper : RoomPaper.ink)
                    .background(active ? RoomPaper.ink : RoomPaper.paper, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(Wording.placeTitle(place))，\(count) 件")
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityIdentifier("place-\(place.rawValue)")
        }
    }

    /// Filter, order, and rows or covers.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { filterMenu; sortMenu; Spacer(minLength: 0); layoutToggle }
            VStack(alignment: .leading, spacing: 8) { filterMenu; sortMenu; layoutToggle }
        }
    }

    private var filterMenu: some View {
        let query = model.pieces.query
        let categories = FurnitureLibrary.categories(in: model.state, catalog: model.catalog)
        return Menu {
            if model.hasSeveralRooms {
                Section("房间") {
                    Picker("房间", selection: Binding(get: { model.pieces.query.roomId }, set: { model.pieces.query.roomId = $0 })) {
                        Text("所有房间").tag(String?.none)
                        ForEach(model.state.allRooms) { room in
                            Text(model.roomName(room)).tag(String?.some(room.roomId))
                        }
                    }
                }
            }
            Section("照片") {
                Picker("照片", selection: Binding(get: { model.pieces.query.photos }, set: { model.pieces.query.photos = $0 })) {
                    Text("有没有照片都看").tag(FurnitureQuery.Photos.any)
                    Text("有照片的").tag(FurnitureQuery.Photos.with)
                    Text("还没有照片的").tag(FurnitureQuery.Photos.without)
                }
            }
            Section {
                Toggle("只看锁定的", systemImage: "lock", isOn: Binding(get: { model.pieces.query.lockedOnly }, set: { model.pieces.query.lockedOnly = $0 }))
            }
            if categories.count > 1 {
                Section("分类") {
                    ForEach(categories, id: \.self) { category in
                        Toggle(category.title, systemImage: category.symbol, isOn: Binding(
                            get: { model.pieces.query.categories.contains(category) },
                            set: { on in
                                if on { model.pieces.query.categories.insert(category) } else { model.pieces.query.categories.remove(category) }
                            }))
                    }
                }
            }
        } label: {
            controlLabel(String(localized: "筛选"), "line.3.horizontal.decrease", active: query.isNarrowed)
        }
        .menuActionDismissBehavior(.disabled)
        .accessibilityValue(query.isNarrowed ? String(localized: "已筛选") : "")
        .accessibilityIdentifier("furniture-filter")
    }

    private var sortMenu: some View {
        let query = model.pieces.query
        return Menu {
            Picker("排序", selection: Binding(get: { model.pieces.query.sort }, set: { sort in
                model.pieces.query.sort = sort
                model.pieces.query.ascending = FurnitureQuery.defaultAscending(for: sort)
            })) {
                ForEach(FurnitureQuery.Sort.allCases, id: \.self) { Text(Wording.sortTitle($0)).tag($0) }
            }
            Picker("方向", selection: Binding(get: { model.pieces.query.ascending }, set: { model.pieces.query.ascending = $0 })) {
                Text(Wording.directionTitle(query.sort, ascending: true)).tag(true)
                Text(Wording.directionTitle(query.sort, ascending: false)).tag(false)
            }
        } label: {
            controlLabel(Wording.sortTitle(query.sort), "arrow.up.arrow.down", active: query.sort != .added || !query.ascending)
        }
        .accessibilityLabel("排序")
        .accessibilityValue(Wording.phrases([Wording.sortTitle(query.sort), Wording.directionTitle(query.sort, ascending: query.ascending)]))
        .accessibilityIdentifier("furniture-sort")
    }

    private var layoutToggle: some View {
        Button {
            model.pieces.grid.toggle()
        } label: {
            controlLabel(model.pieces.grid ? String(localized: "列表") : String(localized: "封面"),
                         model.pieces.grid ? "list.bullet" : "square.grid.2x2", active: false)
        }
        .buttonStyle(.plain)
        .accessibilityHint(model.pieces.grid ? "改成一行一件" : "改成封面网格")
        .accessibilityIdentifier("furniture-layout")
    }

    private func controlLabel(_ title: String, _ symbol: String, active: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .foregroundStyle(active ? RoomPaper.paper : RoomPaper.ink)
            .background(active ? RoomPaper.ink : RoomPaper.paper, in: .rect(cornerRadius: 10))
            .contentShape(.rect)
    }

    /// Says a filter is on (the menu hides it) and takes it off in one tap.
    private func narrowedLine(_ count: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) { narrowedText(count); Spacer(minLength: 12); clearFilters }
            VStack(alignment: .leading, spacing: 4) { narrowedText(count); clearFilters }
        }
    }

    private func narrowedText(_ count: Int) -> some View {
        Text("筛选后 \(count) 件")
            .font(.subheadline)
            .foregroundStyle(Color.subtle)
            .accessibilityIdentifier("furniture-narrowed")
    }

    private var clearFilters: some View {
        Button("清除筛选") {
            model.pieces.query.categories = []
            model.pieces.query.photos = .any
            model.pieces.query.lockedOnly = false
            model.pieces.query.roomId = nil
        }
        .font(.subheadline.weight(.semibold))
        .frame(minHeight: 44)
        .accessibilityIdentifier("clear-furniture-filters")
    }

    // MARK: Pieces

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.subtle)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private var roomEmpty: some View {
        VStack(spacing: 9) {
            MemoryEmblem(.workshop).frame(width: 90, height: 70)
            Text("房间里还没有家具。")
                .font(.system(.headline, design: .serif))
                .foregroundStyle(RoomPaper.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("list-room-empty")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var storedNote: some View {
        Text("收纳箱里的家具和照片都还在，随时可以放回房间。")
            .font(.footnote)
            .foregroundStyle(Color.subtle)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var empty: some View {
        let query = model.pieces.query
        let searching = !query.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if model.state.allFurniture.isEmpty {
            roomEmpty
        } else {
            Text(searching ? "没有找到这个名字的家具。" : query.isNarrowed ? "没有符合筛选的家具。"
                 : query.place == .stored ? "收纳箱是空的。" : "房间里还没有家具。")
                .foregroundStyle(Color.subtle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .accessibilityIdentifier("furniture-none-shown")
        }
    }

    @ViewBuilder
    private func pieces(_ items: [PhotoFurniture], showsPlace: Bool) -> some View {
        if model.pieces.grid {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 10) {
                ForEach(items) { cell($0) }
            }
        } else {
            ForEach(items) { row($0, showsPlace: showsPlace) }
        }
    }

    private func identifier(_ item: PhotoFurniture) -> String {
        model.furniture(item.instanceId) == nil ? "list-stored-item" : "list-room-item"
    }

    private func tap(_ item: PhotoFurniture) {
        if selecting {
            if selected.contains(item.instanceId) { selected.remove(item.instanceId) } else { selected.insert(item.instanceId) }
        } else {
            dismiss()
            model.openedFurnitureID = item.instanceId
        }
    }

    private func row(_ item: PhotoFurniture, showsPlace: Bool) -> some View {
        let isSelected = selected.contains(item.instanceId)
        return HStack(spacing: 4) {
            Button {
                tap(item)
            } label: {
                HStack(spacing: 10) {
                    if selecting { tick(isSelected) }
                    FurnitureRowLabel(item: item, showsPlace: showsPlace)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selecting && isSelected ? .isSelected : [])
            .accessibilityHint(selecting ? (isSelected ? "取消选中" : "选中") : item.sources.isEmpty ? "打开这件家具" : "查看照片")
            .accessibilityIdentifier(identifier(item))
            if !selecting { pieceMenu(item) }
        }
        .card()
    }

    private func cell(_ item: PhotoFurniture) -> some View {
        let isSelected = selected.contains(item.instanceId)
        let stored = model.furniture(item.instanceId) == nil
        let category = model.catalog?.model(id: item.modelId)?.category
        return Button {
            tap(item)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { ThumbnailView(photoId: item.cover) }
                    .overlay {
                        if item.sources.isEmpty, let category {
                            Image(systemName: category.symbol).font(.largeTitle).foregroundStyle(Color.subtle)
                        }
                    }
                    .clipped()
                    .memoryPhotoMount()
                    .overlay(alignment: .topLeading) { if selecting { tick(isSelected).padding(6) } }
                    .overlay(alignment: .topTrailing) {
                        HStack(spacing: 4) {
                            if item.isLocked { badge("lock.fill") }
                            if stored { badge("archivebox.fill") }
                        }
                        .padding(6)
                    }
                    .accessibilityHidden(true)
                Text(item.shownName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(Wording.photoCountLine(item, syncing: model.sync.pendingLinksByPiece[item.instanceId] ?? 0))
                    .font(.footnote)
                    .foregroundStyle(Color.subtle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { if !selecting { pieceActions(item) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.shownName)
        .accessibilityValue(FurnitureRowLabel.info(item, model: model, showsPlace: true))
        .accessibilityAddTraits(selecting && isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(selecting ? (isSelected ? "取消选中" : "选中") : item.sources.isEmpty ? "打开这件家具" : "查看照片")
        .accessibilityIdentifier(identifier(item))
    }

    private func tick(_ on: Bool) -> some View {
        MemorySelectionMark(isSelected: on).frame(width: 22, height: 22)
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.55), in: .circle)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func pieceMenu(_ item: PhotoFurniture) -> some View {
        Menu {
            pieceActions(item)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("「\(item.shownName)」的更多操作")
        .accessibilityIdentifier("piece-menu")
        // 10.2's window: one piece's 「⋯」, the one the tour chose (`TourFacts.pieceMenuPiece`).
        .tourAnchor(TourLaunch.isEnabled && item.instanceId == TourFacts.pieceMenuPiece(model)?.instanceId ? "piece-menu" : "",
                    form: .circle)
    }

    @ViewBuilder
    private func pieceActions(_ item: PhotoFurniture) -> some View {
        let inRoom = model.furniture(item.instanceId) != nil
        if inRoom {
            Button("在房间里定位", systemImage: "scope") {
                dismiss()
                model.locate(item.instanceId)
            }
        }
        Button(item.isLocked ? "解锁" : "锁定", systemImage: item.isLocked ? "lock.open" : "lock") {
            run { failure = await model.setLocked([item.instanceId], !item.isLocked)?.message }
        }
        if inRoom {
            Button("收进收纳箱", systemImage: "archivebox") {
                run { failure = await model.stow([item.instanceId])?.message }
            }
            .disabled(item.isLocked)
        } else {
            Button("放回房间", systemImage: "arrow.uturn.backward") {
                // The placement editor opens once this sheet has gone: never two sheets at once.
                dismiss()
                model.restoringFurnitureID = item.instanceId
            }
            .disabled(item.isLocked)
        }
        Button("删除家具", systemImage: "trash", role: .destructive) { deleting = [item] }
            .disabled(item.isLocked)
    }

    // MARK: Several pieces at once

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

    private func batchBar(_ chosen: [PhotoFurniture]) -> some View {
        let allLocked = !chosen.isEmpty && chosen.allSatisfy(\.isLocked)
        let free = chosen.filter { !$0.isLocked }
        let stowable = free.filter { model.furniture($0.instanceId) != nil }
        return HStack {
            batchButton(allLocked ? String(localized: "解锁") : String(localized: "锁定"), allLocked ? "lock.open" : "lock", id: "batch-lock") {
                lock(chosen, !allLocked)
            }
            .disabled(chosen.isEmpty)
            batchButton(String(localized: "收进收纳箱"), "archivebox", id: "batch-stow") { stow(stowable, of: chosen.count) }
                .disabled(stowable.isEmpty)
            batchButton(String(localized: "删除"), "trash", id: "batch-remove", role: .destructive) { deleting = free }
                .disabled(free.isEmpty)
        }
        .disabled(working)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(RoomPaper.paper)
        .overlay(alignment: .top) { Divider().overlay(RoomPaper.edge) }
        .accessibilityElement(children: .contain)
        .buttonStyle(MemoryCommandStyle(tint: RoomPaper.moss))
        .accessibilityIdentifier("furniture-batch-bar")
    }

    private func batchButton(_ title: String, _ symbol: String, id: String, role: ButtonRole? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.body.weight(.medium))
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.rect)
        }
        .accessibilityIdentifier(id)
    }

    private func noticeBar(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(RoomPaper.paper)
            .overlay(alignment: .top) { Divider().overlay(RoomPaper.edge) }
            .accessibilityIdentifier("furniture-notice")
    }

    private func show(_ text: String) {
        notice = text
        AccessibilityNotification.Announcement(text).post()
        Task {
            try? await Task.sleep(for: .seconds(6))
            if notice == text { notice = nil }
        }
    }

    private func lock(_ chosen: [PhotoFurniture], _ locked: Bool) {
        let changing = chosen.filter { $0.isLocked != locked }
        run {
            if let failed = await model.setLocked(chosen.map(\.instanceId), locked) { failure = failed.message; return }
            show(locked ? String(localized: "已锁定 \(changing.count) 件。锁定的家具不能移动、收纳或删除。")
                 : String(localized: "已解锁 \(changing.count) 件。"))
            stopSelecting()
        }
    }

    private func stow(_ pieces: [PhotoFurniture], of total: Int) {
        run {
            if let failed = await model.stow(pieces.map(\.instanceId)) { failure = failed.message; return }
            let skipped = total - pieces.count
            show(String(localized: "已收纳 \(pieces.count) 件，照片都还在。")
                 + (skipped > 0 ? String(localized: "另外 \(skipped) 件已锁定或已经在收纳箱，没有动。") : ""))
            stopSelecting()
        }
    }

    private var deleteTitle: String {
        guard let deleting else { return "" }
        return deleting.count == 1 ? String(localized: "删除「\(deleting[0].shownName)」？") : String(localized: "删除这 \(deleting.count) 件家具？")
    }

    private func deleteMessage(_ pieces: [PhotoFurniture]) -> String {
        let photos = Set(pieces.flatMap { $0.sources.map(\.photoId) }).count
        let skipped = selecting ? selected.count - pieces.count : 0
        var text = photos > 0 ? String(localized: "家具会被删除，上面的 \(photos) 张照片仍留在照片库里。只是暂时不想摆的话，可以收进收纳箱。")
            : String(localized: "家具会被删除。只是暂时不想摆的话，可以收进收纳箱。")
        if skipped > 0 { text += String(localized: "另外 \(skipped) 件已锁定，不会删除。") }
        return text
    }

    private func delete(_ pieces: [PhotoFurniture]) {
        run {
            if let failed = await model.remove(pieces.map(\.instanceId)) { failure = failed.message; return }
            if selecting {
                show(String(localized: "已删除 \(pieces.count) 件家具，照片都还在照片库里。"))
                stopSelecting()
            }
        }
    }
}

private extension View {
    /// The row background shared with the import steps.
    func card() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .memoryCard(.home)
            .contentShape(.rect)
    }
}

/// The chest in the scene always opens its own contents, including when the library is filtered.
struct StorageChestList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    let onSelect: (String) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.state.storedFurniture.isEmpty {
                        ContentUnavailableView {
                            MemoryEmblem(.home).frame(width: 102, height: 78)
                            Text("收纳箱还是空的")
                        } description: {
                            Text("从家具详情里选择“收进收纳箱”，就能在这里找到它。")
                        }
                        .accessibilityIdentifier("storage-empty")
                    } else {
                        ForEach(model.state.storedFurniture) { item in
                            Button {
                                onSelect(item.instanceId)
                                dismiss()
                            } label: {
                                FurnitureRowLabel(item: item).card()
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(item.sources.isEmpty ? "打开这件家具" : "查看照片")
                            .accessibilityIdentifier("list-stored-item")
                        }
                        Text("收纳箱里的家具和照片都还在，随时可以放回房间。")
                            .font(.footnote)
                            .foregroundStyle(Color.subtle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding()
            }
            .memoryPage(.home)
            .navigationTitle("收纳箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("close-furniture-list")
                }
            }
        }
        .modifier(HalfHeightSheet(enabled: !typeSize.isAccessibilitySize))
    }
}

/// Lets the sheet rest at half height. Not applied at the accessibility text sizes: half height
/// shows barely two rows there, and merely declaring detents (even only `.large`) makes the
/// system accessibility audit report the sheet's text as possibly clipped.
private struct HalfHeightSheet: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.presentationDetents([.medium, .large])
        } else {
            content
        }
    }
}
