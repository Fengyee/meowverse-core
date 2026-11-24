import MeowverseCore
import SwiftUI

/// One furniture row: cover, name, and what the user needs to manage it (kind, how many photos,
/// when a photo was last added, and whether it is put away).
struct FurnitureRowLabel: View {
    @Environment(AppModel.self) private var model
    let item: PhotoFurniture
    /// Say "in the storage box" in the row itself, for lists that do not group by place.
    var showsPlace = false

    var body: some View {
        let category = model.catalog?.model(id: item.modelId)?.category
        HStack(spacing: 12) {
            ThumbnailView(photoId: item.cover)
                .frame(width: 56, height: 56)
                .overlay {
                    if item.sources.isEmpty, let category {
                        Image(systemName: category.symbol)
                            .font(.title3)
                            .foregroundStyle(Color.subtle)
                            .accessibilityHidden(true)
                    }
                }
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.shownName).font(.body.weight(.medium))
                    if item.isLocked {
                        // The line below says "已锁定" in words; this is the mark the eye finds.
                        Image(systemName: "lock.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.subtle)
                            .accessibilityHidden(true)
                    }
                }
                Text(Self.info(item, model: model, showsPlace: showsPlace))
                    .font(.footnote)
                    .foregroundStyle(Color.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// The line under the name. Static, so a list can also read it out without building a row.
    static func info(_ item: PhotoFurniture, model: AppModel, showsPlace: Bool = false) -> String {
        Wording.furnitureLine(item, category: model.catalog?.model(id: item.modelId)?.category,
                              lastPhotoAdded: model.libraryIndex.lastPhotoAdded(toFurniture: item.instanceId),
                              stored: showsPlace && model.furniture(item.instanceId) == nil,
                              room: model.hasSeveralRooms ? model.roomName(ofFurniture: item.instanceId) : nil,
                              syncing: model.sync.pendingLinksByPiece[item.instanceId] ?? 0)
    }
}

/// "选家具": every piece the user has, in the room and put away, to pick one from. Shared by
/// the photo detail, the library's batch bar and a piece's own album.
struct FurniturePickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let title: String
    /// One line under the title saying what picking does.
    var prompt: String?
    /// Pieces not offered at all.
    var hidden: Set<String> = []
    /// Pieces shown with a check mark.
    var checked: Set<String> = []
    /// Close after one pick. When false the sheet stays open and offers "完成".
    var closesOnPick = true
    let onPick: (PhotoFurniture) -> Void

    @State private var search = ""

    var body: some View {
        let room = shown(model.state.placedFurniture), stored = shown(model.state.storedFurniture)
        NavigationStack {
            List {
                if let prompt {
                    Text(prompt)
                        .font(.footnote)
                        .foregroundStyle(Color.subtle)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                }
                if room.isEmpty && stored.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "没有可选的家具" : "没有找到家具", systemImage: "sofa",
                                           description: Text(search.isEmpty ? "先在房间里添一件家具。" : "换个名字再找找。"))
                        .accessibilityIdentifier("picker-no-furniture")
                }
                if !room.isEmpty {
                    Section("房间里") { ForEach(room) { row($0) } }
                }
                if !stored.isEmpty {
                    Section("收纳箱") { ForEach(stored) { row($0) } }
                }
            }
            .searchable(text: $search, prompt: Text("找家具"))
            .memoryPage(.album)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: closesOnPick ? .cancellationAction : .confirmationAction) {
                    Button(closesOnPick ? "取消" : "完成") { dismiss() }
                        .accessibilityIdentifier("close-furniture-picker")
                }
            }
        }
        .accessibilityIdentifier("furniture-picker")
    }

    /// Pieces changed most recently come first, so the one just used is at hand.
    private func shown(_ items: [PhotoFurniture]) -> [PhotoFurniture] {
        let term = search.trimmingCharacters(in: .whitespaces)
        return items
            .filter { !hidden.contains($0.instanceId) && (term.isEmpty || $0.shownName.localizedCaseInsensitiveContains(term)) }
            .enumerated()
            .sorted { a, b in
                let (x, y) = (a.element.updatedAt ?? a.element.createdAt, b.element.updatedAt ?? b.element.createdAt)
                if x != y { return (x ?? .distantPast) > (y ?? .distantPast) }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    private func row(_ item: PhotoFurniture) -> some View {
        let isChecked = checked.contains(item.instanceId)
        return Button {
            onPick(item)
            if closesOnPick { dismiss() }
        } label: {
            HStack {
                FurnitureRowLabel(item: item)
                if isChecked {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .tint(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.shownName)
        .accessibilityValue(FurnitureRowLabel.info(item, model: model))
        .accessibilityAddTraits(isChecked ? [.isButton, .isSelected] : .isButton)
    }
}

/// A library thumbnail that can be ticked.
struct SelectablePhotoCell: View {
    let photo: PhotoRecord
    let linkedTo: [PhotoFurniture]
    let selected: Bool

    var body: some View {
        PhotoCell(photo: photo, linkedTo: linkedTo)
            .opacity(selected ? 0.7 : 1)
            .overlay(alignment: .bottomTrailing) {
                MemorySelectionMark(isSelected: selected)
                    .padding(6)
            }
    }
}

/// "选照片": photos already in the library, to tick several and put them somewhere. Nothing is
/// imported or copied: the photos chosen are the stored ones.
struct LibraryPhotoPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let title: String
    /// Photos not offered (already where they would go).
    var hidden: Set<String> = []
    /// The confirm button's words for a number of chosen photos.
    let confirmTitle: (Int) -> String
    let onConfirm: ([String]) -> Void

    @State private var filter: PhotoFilter = .all
    @State private var selected: Set<String> = []

    var body: some View {
        let sections = PhotoLibrary.sections(in: model.shownState, filter: filter, linkedElsewhere: model.sync.photosOnNewerPieces)
            .map { PhotoSection(month: $0.month, photos: $0.photos.filter { !hidden.contains($0.photoId) }) }
            .filter { !$0.photos.isEmpty }
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Picker("筛选照片", selection: $filter) {
                        ForEach(PhotoFilter.allCases, id: \.self) { Text(Wording.filterTitle($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    if sections.isEmpty {
                        ContentUnavailableView("没有可选的照片", systemImage: "photo.on.rectangle.angled",
                                               description: Text("照片库里符合条件的照片都已经在这里了。"))
                            .accessibilityIdentifier("picker-no-photos")
                    }
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Wording.monthTitle(section.month))
                                .font(.headline)
                                .padding(.horizontal)
                                .accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 4)], spacing: 4) {
                                ForEach(section.photos) { photo in
                                    let linked = model.furniture(containingPhoto: photo.photoId)
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
                                    .accessibilityIdentifier("picker-photo")
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(.vertical)
            }
            .memoryPage(.album)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.accessibilityIdentifier("close-photo-picker")
                }
            }
            .safeAreaInset(edge: .bottom) {
                primaryButton(confirmTitle(selected.count), enabled: !selected.isEmpty) {
                    // Library order, so the photos arrive in the order they are shown.
                    let ordered = sections.flatMap(\.photos).map(\.photoId).filter(selected.contains)
                    dismiss()
                    onConfirm(ordered)
                }
                .accessibilityIdentifier("confirm-photo-picker")
            }
        }
    }
}

/// "调整照片顺序": a piece's photos as a list that can be dragged into a new order. Nothing is
/// saved until "完成"; "取消" leaves the album as it was.
struct AlbumOrderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: PhotoFurniture
    let onSave: ([String]) -> Void
    @State private var order: [String] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order, id: \.self) { photoId in
                        let position = (order.firstIndex(of: photoId) ?? 0) + 1
                        HStack(spacing: 12) {
                            ThumbnailView(photoId: photoId)
                                .frame(width: 56, height: 56)
                                .clipShape(.rect(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("第 \(position) 张").font(.body.weight(.medium))
                                if let photo = model.photo(photoId) {
                                    Text(photo.captureLine)
                                        .font(.footnote)
                                        .foregroundStyle(Color.subtle)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("order-row")
                        // Dragging needs a steady finger; these do the same one step at a time.
                        .accessibilityAction(named: "上移一位") { step(photoId, by: -1) }
                        .accessibilityAction(named: "下移一位") { step(photoId, by: 1) }
                        .accessibilityAction(named: "移到最前") { move(photoId, to: 0) }
                    }
                    .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("按住右边的把手拖动。没有另外选封面时，第一张就是封面。")
                }
            }
            .environment(\.editMode, .constant(.active))
            .memoryPage(.album)
            .navigationTitle("调整照片顺序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.accessibilityIdentifier("cancel-order")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if order != item.sources.map(\.photoId) { onSave(order) }
                        dismiss()
                    }
                    .accessibilityIdentifier("save-order")
                }
            }
        }
        .onAppear { order = item.sources.map(\.photoId) }
    }

    private func step(_ photoId: String, by offset: Int) {
        guard let index = order.firstIndex(of: photoId) else { return }
        move(photoId, to: index + offset)
    }

    private func move(_ photoId: String, to target: Int) {
        guard let index = order.firstIndex(of: photoId), order.indices.contains(target), target != index else { return }
        order.remove(at: index)
        order.insert(photoId, at: target)
    }
}
