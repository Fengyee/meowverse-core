import MeowverseCore
import SwiftUI
import UIKit

/// Where a photo detail is shown; decides how "open that furniture" navigates.
enum PhotoDetailContext: Equatable {
    case library
    case furniture(String)
}

/// One stored photo: the original, its capture day and where that day came from, the furniture
/// it belongs to, and the user's own favourite / note / date. Pushed inside a navigation stack.
struct PhotoDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let photoId: String
    let context: PhotoDetailContext

    @State private var exportAction: PhotoExportAction?
    @State private var saving = false
    @State private var failure: String?
    @State private var retry: (() -> Void)?
    @State private var noteShown = false
    @State private var dateShown = false
    @State private var deleteAsked = false
    @State private var deleteWords = ""
    @State private var furniturePickerShown = false

    var body: some View {
        Group {
            if let photo = model.photo(photoId) {
                content(photo)
            } else {
                ContentUnavailableView("这张照片已经不在照片库里", systemImage: "photo")
            }
        }
        .memoryPage(.album)
        .navigationTitle("照片")
        .sheet(item: $exportAction) { action in PhotoExportView(ids: [photoId], action: action) }
        .sheet(isPresented: $furniturePickerShown) {
            FurniturePickerView(title: String(localized: "放进家具"),
                                prompt: String(localized: "选一件家具。照片原来在别的家具里的，仍然在那里。"),
                                hidden: Set(model.furniture(containingPhoto: photoId).map(\.instanceId))) { item in
                link(to: item.instanceId)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .alert("没能保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            if let retry { Button("重试") { retry() } }
            Button(retry == nil ? "好" : "取消", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func content(_ photo: PhotoRecord) -> some View {
        let linked = model.furniture(containingPhoto: photoId)
        // Pieces in the storage box can take a photo too.
        let others = model.state.allFurniture.filter { item in !linked.contains { $0.instanceId == item.instanceId } }
        return List {
            Section {
                StoredOriginalView(photoId: photoId, label: String(localized: "照片，\(photo.captureLine)"))
                    .frame(height: 246)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "calendar").accessibilityHidden(true)
                    Text(photo.captureLine)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("photo-date-line")
                }
                .font(.system(.headline, design: .serif, weight: .semibold))
                .foregroundStyle(RoomPaper.ink)
                Button { dateShown = true } label: {
                    Label(photo.captureDate == nil ? "填写拍摄日期" : "修改拍摄日期", systemImage: "calendar.badge.clock")
                        .foregroundStyle(Color.primary)
                }
                .accessibilityIdentifier("edit-date")
                if photo.captureDateSource == .user {
                    Button(photo.exifCaptureDate == nil ? "清除我填写的日期" : "恢复为照片信息里的日期", systemImage: "arrow.uturn.backward") {
                        apply(PhotoEdit(captureDate: .clear))
                    }
                    .accessibilityIdentifier("clear-date")
                }
                explanation(dateFooter(photo))
            }
            .listRowBackground(RoomPaper.sheet)

            Section {
                Text(photo.reducedFrom == nil
                     ? String(localized: "已保存完整原件", table: "PhotoExport")
                     : String(localized: "已保存缩小副本，请保留系统相册里的原件。", table: "PhotoExport"))
                    .accessibilityIdentifier("photo-storage-status")
                Button(PhotoExportAction.share.title, systemImage: "square.and.arrow.up") { exportAction = .share }
                    .accessibilityIdentifier("share-photo")
                Button(PhotoExportAction.shareFile.title, systemImage: "doc") { exportAction = .shareFile }
                    .accessibilityIdentifier("share-photo-file")
                Button(PhotoExportAction.save.title, systemImage: "square.and.arrow.down") { exportAction = .save }
                    .accessibilityIdentifier("save-photo-to-photos")
                if model.photoLibrary.isOn, photo.assetIdentifier != nil || photo.cloudIdentifier != nil {
                    Button(PhotoExportAction.album.title, systemImage: "rectangle.stack.badge.plus") { exportAction = .album }
                }
            }
            .listRowBackground(RoomPaper.sheet)

            Section {
                header(String(localized: "收藏与便签"))
                Toggle(isOn: Binding(get: { photo.favorite }, set: { apply(PhotoEdit(favorite: $0)) })) {
                    Label("收藏", systemImage: photo.favorite ? "heart.fill" : "heart")
                }
                .accessibilityIdentifier("favorite-toggle")
                if !photo.note.isEmpty {
                    Text(photo.note)
                        .accessibilityLabel("便签：\(photo.note)")
                        .accessibilityIdentifier("photo-note")
                }
                Button(photo.note.isEmpty ? "写一张便签" : "编辑便签", systemImage: "square.and.pencil") { noteShown = true }
                    .accessibilityIdentifier("edit-note")
            }
            .listRowBackground(RoomPaper.sheet)

            Section {
                if linked.isEmpty {
                    Text("还没有放进任何家具。")
                        .foregroundStyle(Color.subtle)
                        .accessibilityIdentifier("photo-unlinked")
                }
                ForEach(linked) { item in
                    furnitureRow(item)
                }
                if !others.isEmpty {
                    Button("放进已有的家具", systemImage: "rectangle.badge.plus") { furniturePickerShown = true }
                        .accessibilityHint("选一件家具。照片原来在别的家具里的，仍然在那里。")
                        .accessibilityIdentifier("link-furniture")
                }
                Button("用它添一件新家具", systemImage: "sofa") { model.beginFurniture(fromPhoto: photoId) }
                    .accessibilityIdentifier("make-furniture")
                if case .furniture(let instanceId) = context, linked.contains(where: { $0.instanceId == instanceId }) {
                    Button("从这件家具移出", systemImage: "rectangle.badge.minus") { unlink(from: instanceId) }
                        .accessibilityHint("照片留在照片库里，家具也还在")
                        .accessibilityIdentifier("unlink-photo")
                }
            } header: {
                header(String(localized: "所在的家具"))
            }
            .listRowBackground(RoomPaper.sheet)

            Section {
                fact(String(localized: "导入时间"), photo.importedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: AppLanguage.locale)))
                if let source = photo.reducedFrom {
                    fact(String(localized: "保存的副本"), Wording.fileLine(photo))
                    explanation(String(localized: "这里保存的是缩小副本。导入时的原件尺寸为 \("\(source.width)×\(source.height)")。", table: "PhotoExport"))
                        .accessibilityIdentifier("reduced-copy-note")
                } else {
                    fact(String(localized: "原图"), Wording.fileLine(photo))
                    explanation(String(localized: "原图按导入时的样子原样保存，这里的修改不会动它。"))
                }
            } header: {
                header(String(localized: "关于这张照片"))
            }
            .listRowBackground(RoomPaper.sheet)

            Section {
                Button(role: .destructive) { askToDelete() } label: {
                    Label("删除这张照片", systemImage: "trash").foregroundStyle(.red)
                }
                    .accessibilityIdentifier("delete-photo")
            }
        }
        .disabled(saving)
        .sheet(isPresented: $noteShown) {
            NoteEditor(initial: photo.note) { text in
                await model.editPhoto(photoId, PhotoEdit(note: text)).failureMessage
            }
        }
        .sheet(isPresented: $dateShown) {
            CaptureDateEditor(photo: photo) { day in
                await model.editPhoto(photoId, PhotoEdit(captureDate: .set(day))).failureMessage
            }
        }
        .confirmationDialog("删除这张照片？", isPresented: $deleteAsked, titleVisibility: .visible) {
            Button("删除照片", role: .destructive) { delete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deleteWords)
        }
    }

    private func askToDelete() {
        Task {
            let loss = await model.photoLoss([photoId])
            deleteWords = Wording.deletionMessage(model.state.deletionImpact(photoId: photoId), loss: loss)
            deleteAsked = true
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(.headline, design: .serif, weight: .semibold))
            .textCase(nil)
            .foregroundStyle(Color.primary)
            .accessibilityAddTraits(.isHeader)
    }

    private func explanation(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color.subtle)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 12)
                Text(value).foregroundStyle(Color.subtle)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(value).foregroundStyle(Color.subtle)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func furnitureRow(_ item: PhotoFurniture) -> some View {
        if context == .furniture(item.instanceId) {
            Label("\(item.shownName)（正在看的这件）", systemImage: "sofa")
                .accessibilityIdentifier("photo-current-furniture")
        } else {
            Button {
                if case .furniture = context {
                    model.openedFurnitureID = item.instanceId
                } else {
                    model.showFurniture(item.instanceId)
                }
            } label: {
                HStack {
                    Label(title(item), systemImage: "sofa")
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.subtle)
                        .accessibilityHidden(true)
                }
            }
            .tint(.primary)
            .accessibilityHint("打开这件家具")
            .accessibilityIdentifier("photo-furniture")
        }
    }

    /// A piece that is put away says so, so nobody looks for it in the room.
    private func title(_ item: PhotoFurniture) -> String {
        model.furniture(item.instanceId) == nil ? String(localized: "\(item.shownName)（在收纳箱）") : item.shownName
    }

    private func dateFooter(_ photo: PhotoRecord) -> String {
        if let exif = Wording.dayTitle(photo.exifCaptureDate) {
            return photo.captureDateSource == .user
                ? String(localized: "照片信息里记录的是 \(exif)。它一直保留着，随时可以恢复。")
                : String(localized: "这个日期来自照片信息。你可以改成自己记得的日期，照片信息里的日期仍会保留。")
        }
        return photo.captureDateSource == .user
            ? String(localized: "这张照片没有记录拍摄日期，现在显示的是你填写的。")
            : String(localized: "这张照片没有记录拍摄日期。喵空间不会替你猜。")
    }

    // MARK: Changes

    /// One change at a time, each an absolute value; the list is disabled while one is in flight,
    /// and what is shown afterwards is always the store's own state.
    private func apply(_ edit: PhotoEdit) {
        guard !saving else { return }
        saving = true
        Task {
            let result = await model.editPhoto(photoId, edit)
            saving = false
            if let message = result.failureMessage {
                retry = { apply(edit) }
                failure = message
            }
        }
    }

    private func link(to instanceId: String) {
        guard !saving else { return }
        saving = true
        Task {
            let result = await model.linkPhoto(photoId, to: instanceId)
            saving = false
            if case .failure(let failed) = result {
                retry = (failed.error.map(Self.isRetryable) ?? true) ? { link(to: instanceId) } : nil
                failure = failed.message
            }
        }
    }

    /// Takes the photo off the piece being viewed, then goes back to that piece. Only the link
    /// goes: the photo stays in the library and the piece stays, with or without other photos.
    private func unlink(from instanceId: String) {
        guard !saving else { return }
        saving = true
        Task {
            let failed = await model.unlinkPhoto(photoId, from: instanceId)
            saving = false
            if let failed {
                retry = (failed.error.map(Self.isRetryable) ?? true) ? { unlink(from: instanceId) } : nil
                failure = failed.message
            } else {
                dismiss()
            }
        }
    }

    private func delete() {
        guard !saving else { return }
        saving = true
        Task {
            let failed = await model.deletePhoto(photoId)
            saving = false
            if let failed {
                retry = (failed.error.map(Self.isRetryable) ?? true) ? { delete() } : nil
                failure = failed.message
            } else {
                dismiss()
            }
        }
    }

    private static func isRetryable(_ error: StoreError) -> Bool {
        if case .io = error { return true }
        return false
    }
}

extension Result where Failure == PhotoSaveFailure {
    var failureMessage: String? {
        if case .failure(let failure) = self { return failure.message }
        return nil
    }
}

/// The stored original, decoded off the main thread at screen resolution and zoomable.
struct StoredOriginalView: View {
    @Environment(AppModel.self) private var model
    let photoId: String
    let label: String
    var imageIdentifier = "detail-photo"
    @State private var image: UIImage?
    @State private var missing = false
    @State private var intact: Bool?
    @State private var libraryNote: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var reload = 0
    private struct LoadKey: Equatable {
        let photoId: String
        let active: Bool
        let linked: Bool
        let reload: Int
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let image {
                ZoomableImage(image: image, imageLabel: label, imageIdentifier: imageIdentifier)
                    .aspectRatio(image.size, contentMode: .fit)
                    .memoryPhotoMount()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if missing {
                ContentUnavailableView("读不到这张照片", systemImage: "photo.badge.exclamationmark",
                                       description: Text("记录还在。可以稍后再试。"))
            } else {
                ProgressView("正在打开照片…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if intact == false {
                Label("这张照片和导入时不一致，可能已损坏。", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Color.caution)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            } else if let libraryNote {
                VStack(spacing: 4) {
                    Text(libraryNote)
                        .accessibilityIdentifier("library-note")
                    Button { reload += 1 } label: {
                        Text("重试").frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                    }
                    .buttonStyle(MemoryCommandStyle(tint: RoomPaper.clay))
                    .accessibilityIdentifier("retry-library-original")
                }
                    .font(.footnote)
                    .foregroundStyle(Color.subtle)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
        .task(id: LoadKey(photoId: photoId, active: scenePhase == .active, linked: model.photoLibrary.isOn, reload: reload)) {
            if scenePhase == .active { await load() }
        }
    }

    private func load() async {
        let interval = Perf.signposter.beginInterval("OpenOriginal")
        defer { Perf.signposter.endInterval("OpenOriginal", interval) }
        guard !Task.isCancelled else { return }
        image = nil
        missing = false
        intact = nil
        libraryNote = nil
        let url = await model.originalURL(photoId: photoId)
        guard !Task.isCancelled else { return }
        guard let url else {
            missing = true
            return
        }
        let side = Int(max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale)
        let decoded = try? await AppModel.offMain { PhotoIngest.downsampledImage(at: url, maxPixel: min(side * 2, 4096)) }
        guard !Task.isCancelled else { return }
        if let decoded {
            image = UIImage(cgImage: decoded)
            Perf.mark("OriginalShown")
        } else {
            missing = true
        }
        let verified = await model.verifyOriginal(photoId: photoId)
        guard !Task.isCancelled else { return }
        intact = verified
        // The stored copy is on screen; the full-size picture from the photo library replaces it.
        guard let photo = model.photo(photoId) else { return }
        let full = await model.photoLibrary.fullImage(for: photo, maxPixel: min(side * 2, 4096))
        guard !Task.isCancelled else { return }
        if case .image(let picture) = full { image = picture }
        libraryNote = PhotoLibraryLink.note(for: full)
    }
}

/// Plain-text note, at most 2000 UTF-16 units. The text stays on screen if the save fails.
struct NoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    let save: (String) async -> String?
    private let initial: String
    @State private var text: String
    @State private var saving = false
    @State private var failure: String?
    @State private var discardAsked = false
    @FocusState private var focused: Bool

    init(initial: String, save: @escaping (String) async -> String?) {
        self.save = save
        self.initial = initial
        _text = State(initialValue: initial)
    }

    private var length: String { String(text.utf16.count) }
    private var limit: String { String(LibraryStore.maxNoteLength) }
    private var tooLong: Bool { text.utf16.count > LibraryStore.maxNoteLength }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $text)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .memoryCard(.album)
                    .accessibilityLabel("便签内容")
                    .accessibilityIdentifier("note-text")
                Text(tooLong ? "已经 \(length) 个字，最多 \(limit) 个字。" : "\(length) / \(limit)")
                    .font(.footnote)
                    .foregroundStyle(tooLong ? Color.caution : Color.subtle)
                    .accessibilityLabel(tooLong ? "超出字数：已经 \(length) 个字，最多 \(limit) 个字" : "已写 \(length) 个字，最多 \(limit) 个字")
                    .accessibilityIdentifier("note-count")
            }
            .padding()
            .memoryPage(.album)
            .navigationTitle("便签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { if text == initial { dismiss() } else { discardAsked = true } }
                        .disabled(saving)
                        .accessibilityIdentifier("cancel-note")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { commit() }
                        .disabled(tooLong || saving)
                        .accessibilityIdentifier("save-note")
                }
            }
            .alert("没能保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("重试") { commit() }
                Button("取消", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
            .alert("不保存这次对便签的修改？", isPresented: $discardAsked) {
                Button("不保存", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
            }
        }
        // A swipe doesn't throw typed text away; 取消 asks.
        .interactiveDismissDisabled(text != initial || saving)
        // A Home Screen quick action must not close the editor over text not yet saved.
        .unsentWork(text != initial || saving)
        .onAppear { focused = true }
    }

    private func commit() {
        guard !saving, !tooLong else { return }
        saving = true
        Task {
            let message = await save(text)
            saving = false
            if let message { failure = message } else { dismiss() }
        }
    }
}

/// Sets the capture day by hand. The day stored in the photo file is shown and never replaced.
struct CaptureDateEditor: View {
    @Environment(\.dismiss) private var dismiss
    let photo: PhotoRecord
    let save: (String) async -> String?
    private let initial: Date
    @State private var date: Date
    @State private var saving = false
    @State private var failure: String?

    init(photo: PhotoRecord, save: @escaping (String) async -> String?) {
        self.photo = photo
        self.save = save
        initial = PhotoLibrary.pickerDate(for: photo.captureDate, in: .current)
        _date = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Wording.dayTitle(photo.exifCaptureDate).map { "照片信息里记录的是 \($0)。保存后会显示你选的日期，原来的记录仍然保留。" }
                         ?? "这张照片没有记录拍摄日期。选一个你记得的日子。")
                        .font(.subheadline)
                        .foregroundStyle(Color.subtle)
                        .fixedSize(horizontal: false, vertical: true)
                    DatePicker("拍摄日期", selection: $date, in: ...DayCodec.latest, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .environment(\.calendar, DayCodec.calendar)
                        .environment(\.timeZone, DayCodec.timeZone)
                        .environment(\.locale, AppLanguage.locale)
                        .accessibilityIdentifier("date-picker")
                }
                .padding()
            }
            .memoryPage(.album)
            .navigationTitle("拍摄日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.accessibilityIdentifier("cancel-date")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { commit() }
                        .disabled(saving)
                        .accessibilityIdentifier("save-date")
                }
            }
            .alert("没能保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("重试") { commit() }
                Button("取消", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        }
        .interactiveDismissDisabled(saving)
        // A Home Screen quick action must not close the editor over a day not yet saved.
        .unsentWork(DayCodec.day(from: date) != DayCodec.day(from: initial) || saving)
    }

    private func commit() {
        guard !saving else { return }
        saving = true
        Task {
            let message = await save(DayCodec.day(from: date))
            saving = false
            if let message { failure = message } else { dismiss() }
        }
    }
}
