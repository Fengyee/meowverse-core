import MeowverseCore
import PhotosUI
import SwiftUI

/// Navigation and progress of the photo library. Kept in one value so AppModel gains one property.
struct PhotoUIState {
    var storageReceipt: PhotoStorageReceipt?
    var libraryShown = false
    var filter: PhotoFilter = .all
    /// Only photos on these pieces are shown; empty means every piece.
    var furnitureFilter: Set<String> = []
    /// Non-nil while picked photos are being added to a piece of furniture.
    var adding: AddingProgress?
    var addTask: Task<AddPhotosSummary, Never>?

    struct AddingProgress: Equatable {
        /// Photos dealt with for good: added (or found already there) or unreadable.
        var done: Int
        var total: Int
        /// What the bar counts.
        var shown: Int { min(done, total) }
    }
}

/// A store change that did not happen. `message` is ready to show; nothing was half-applied.
struct PhotoSaveFailure: Error {
    let message: String
    let error: StoreError?
}

/// What happened to a batch of photos added to one piece of furniture.
struct AddPhotosSummary: Equatable {
    var added: [String] = []
    var alreadyThere = 0
    var unreadable = 0
    /// Photos not handed over in time, or not reached because the add stopped or a save failed:
    /// the ones the bar left uncounted. Picking them again can work.
    var notImported = 0
    /// Of those, photos the photo library did not hand over in time, also when asked again.
    var timedOut = 0
    var saveFailure: String?

    var message: String? {
        var lines: [String] = []
        if alreadyThere > 0 { lines.append(String(localized: "\(alreadyThere) 张已经在这件家具里，没有重复添加。")) }
        if unreadable > 0 { lines.append(String(localized: "\(unreadable) 张读不出来，没有添加。")) }
        if let saveFailure { lines.append(saveFailure) }
        if notImported > 0 {
            lines.append(String(localized: "还有 \(notImported) 张没有处理，可以再选一次。"))
            if timedOut > 0 { lines.append(AppModel.timedOutLine(timedOut)) }
        }
        guard !lines.isEmpty else { return nil }
        if !added.isEmpty { lines.insert(String(localized: "已添加 \(added.count) 张。"), at: 0) }
        return lines.joined(separator: "\n")
    }
}

/// What a delete or clear question may say (DATA-1).
struct PhotoLoss {
    /// Photos whose original Photos could not confirm: each may be the only copy.
    var unconfirmed: Int
    var syncing: Bool
    var backingUp: Bool
    /// Photos on pieces from a newer version, which this device can't show.
    var onNewerPieces = 0
}

extension AppModel {
    typealias PhotoLoader = @Sendable () async throws -> Data

    static var outOfSpaceMessage: String { String(localized: "这台设备的储存空间不够，没能保存。腾出一些空间后再试。") }

    static func photoMessage(for error: any Error) -> String {
        if (error as? StoreError)?.isOutOfSpace == true { return outOfSpaceMessage }
        return switch error as? StoreError {
        case .deletionCleanupPending: String(localized: "删除已记录。清理本机文件还未完成，重新打开 App 后会重试。")
        case .unknownPhoto: String(localized: "这张照片已经不在照片库里了。")
        case .unknownInstance: String(localized: "这件家具已经不在了。")
        case .duplicateSource: String(localized: "这张照片已经在这件家具里了。")
        case .invalidDate: String(localized: "这个日期无效，请重新选择。")
        case .noteTooLong: String(localized: "便签最多 \(String(LibraryStore.maxNoteLength)) 个字。")
        case .placement: String(localized: "这个位置现在放不下，请换个位置再确认。")
        case .locked: String(localized: "这件家具已锁定。先解锁，再移动、收纳或删除。")
        case .unknownRoom: String(localized: "这个房间已经不在了。")
        case .unknownCat: String(localized: "这只猫咪已经不在了。")
        case .firstRoom: String(localized: "第一个房间不能删除。")
        case .firstCat: String(localized: "第一只猫咪不能移除。")
        case .invalidName: String(localized: "名字需要 1 到 \(AppState.maxCatNameLength) 个字。")
        default: String(localized: "没能保存。照片和家具都保持原样，可以重试。")
        }
    }

    /// On a piece here, or on one from a newer version that this device can't show.
    func isOnFurniture(_ photoId: String) -> Bool {
        libraryIndex.isLinked(photoId) || sync.photosOnNewerPieces.contains(photoId)
    }

    func furniture(containingPhoto photoId: String) -> [PhotoFurniture] {
        libraryIndex.furniture(ofPhoto: photoId)
    }

    // MARK: Import without new furniture

    /// "只存照片，不添家具": the photo goes into the library, linked to nothing.
    func storePhotoOnly(_ session: ImportSession) async -> Result<PhotoRecord, PhotoSaveFailure> {
        let draft = session.draft, generation = session.generation
        return await perform { try await $0.addPhoto(draft: draft, generation: generation) }
    }

    /// Attaches the photo under review to an existing piece instead of creating a new one.
    func attach(_ session: ImportSession, to instanceId: String) async -> Result<PhotoFurniture, PhotoSaveFailure> {
        let draft = session.draft, decision = session.review.sourceDecision, generation = session.generation
        return await perform { try await $0.addSource(draft: draft, toInstance: instanceId, decision: decision, generation: generation) }
    }

    // MARK: More photos for one piece of furniture

    func addPhotos(_ items: [PhotosPickerItem], to instanceId: String) async -> AddPhotosSummary {
        await addPhotos(to: instanceId, loaders: items.map { item in { try await PhotoLibraryLink.load(item) } },
                        assetIdentifiers: items.map(\.itemIdentifier))
    }

    /// Each photo commits before it is counted, so later failures keep already added photos.
    /// The user picked the furniture by hand, so every link is a manual (user) source.
    func addPhotos(to instanceId: String, loaders: [PhotoLoader], assetIdentifiers: [String?] = []) async -> AddPhotosSummary {
        guard !loaders.isEmpty, !switchingLibraries, photos.addTask == nil else { return .init() }
        let generation = libraryGeneration
        photos.adding = .init(done: 0, total: loaders.count)
        let task = Task {
            await appendPhotos(to: instanceId, loaders: loaders, assetIdentifiers: assetIdentifiers, generation: generation)
        }
        photos.addTask = task
        let result = await task.value
        // A library switch stops the add and clears it itself (`stopPhotoImports`); nothing to
        // report then. Stopped for want of background time, the add reports what it got through.
        guard photos.addTask == task, generation == libraryGeneration, !switchingLibraries else { return .init() }
        photos.addTask = nil
        photos.adding = nil
        return result
    }

    private func appendPhotos(to instanceId: String, loaders: [PhotoLoader], assetIdentifiers: [String?],
                              generation: UUID) async -> AddPhotosSummary {
        var summary = AddPhotosSummary()
        // Each photo is saved as soon as it is ready: a silent request never holds back the
        // others, and a photo that arrived is kept even if the add is stopped.
        await prepareEach(loaders, assetIdentifiers: assetIdentifiers) { _, photo in
            guard !switchingLibraries, generation == libraryGeneration else { return false }
            switch photo {
            case .unreadable:
                summary.unreadable += 1
                photos.adding?.done += 1
                return true
            case .notLoaded:
                summary.timedOut += 1
                return true
            case .ready(let draft):
                let result = await Task { await perform { try await $0.importPickerPhotos([draft], to: instanceId, generation: generation) } }.value
                switch result {
                case .success(let imported):
                    summary.added += imported.filter(\.linked).map(\.photo.photoId)
                    summary.alreadyThere += imported.filter { !$0.linked }.count
                    photos.adding?.done += 1
                    return true
                case .failure(let failure):
                    summary.saveFailure = failure.message
                    return false
                }
            }
        }
        summary.notImported = max(0, loaders.count - summary.added.count - summary.alreadyThere - summary.unreadable)
        await store?.finishPickerImport()
        return summary
    }

    // MARK: One stored photo

    func editPhoto(_ photoId: String, _ edit: PhotoEdit) async -> Result<PhotoRecord, PhotoSaveFailure> {
        await perform { try await $0.editPhoto(photoId: photoId, edit) }
    }

    func linkPhoto(_ photoId: String, to instanceId: String) async -> Result<PhotoFurniture, PhotoSaveFailure> {
        await perform { try await $0.linkPhoto(photoId: photoId, toInstance: instanceId) }
    }

    /// Deletes the app's copy (never the Photos library original). See `AppState.deletionImpact`.
    func deletePhoto(_ photoId: String) async -> PhotoSaveFailure? {
        let result: Result<Bool, PhotoSaveFailure> = await perform {
            try await $0.deletePhoto(photoId: photoId)
            return true
        }
        if case .failure(let failure) = result { return failure }
        return nil
    }

    // MARK: Several stored photos

    /// Puts photos on a piece. Returns the ones that were not on it before, for undo.
    func linkPhotos(_ photoIds: [String], to instanceId: String) async -> Result<[String], PhotoSaveFailure> {
        let held = Set(anyFurniture(instanceId)?.sources.map(\.photoId) ?? [])
        let fresh = photoIds.filter { !held.contains($0) }
        return await perform { _ = try await $0.linkPhotos(photoIds: photoIds, toInstance: instanceId) }.map { fresh }
    }

    func unlinkPhotos(_ photoIds: [String], from instanceId: String) async -> PhotoSaveFailure? {
        let result = await perform { _ = try await $0.unlinkPhotos(photoIds: photoIds, fromInstance: instanceId) }
        if case .failure(let failure) = result { return failure }
        // A correction by hand: these photos are not offered a piece again.
        declineSuggestions(Set(photoIds))
        return nil
    }

    /// Takes photos off the pieces named, or with nil off every piece they are on, as one save.
    /// Returns what was taken off, so 撤销 can put each link back as it was (origin included).
    func unlinkPhotos(_ photoIds: [String], fromPieces instanceIds: [String]?) async -> Result<LibraryStore.UnlinkReceipt, PhotoSaveFailure> {
        let result = await perform { try await $0.unlinkPhotos(photoIds: photoIds, fromInstances: instanceIds) }
        // A correction by hand: these photos are not offered a piece again.
        if case .success(let receipt) = result { declineSuggestions(Set(receipt.removed.map(\.link.photoId))) }
        return result
    }

    /// Puts back what `unlinkPhotos(_:fromPieces:)` took off, unless the user changed it since.
    func undoUnlink(_ receipt: LibraryStore.UnlinkReceipt) async -> PhotoSaveFailure? {
        let result = await perform { try await $0.undoUnlink(receipt) }
        if case .failure(let failure) = result { return failure }
        return nil
    }

    func movePhotos(_ photoIds: [String], from source: String, to target: String) async -> PhotoSaveFailure? {
        let result = await perform { _ = try await $0.movePhotos(photoIds: photoIds, fromInstance: source, toInstance: target) }
        if case .failure(let failure) = result { return failure }
        // A correction by hand: these photos are not offered a piece again.
        declineSuggestions(Set(photoIds))
        return nil
    }

    /// Returns the photos whose mark changed, for undo.
    func setFavorite(_ photoIds: [String], _ favorite: Bool) async -> Result<[String], PhotoSaveFailure> {
        let changing = photoIds.filter { photo($0)?.favorite == !favorite }
        return await perform { _ = try await $0.setFavorite(photoIds: photoIds, favorite) }.map { changing }
    }

    /// Deletes the app's copies (never the Photos library originals).
    func deletePhotos(_ photoIds: [String]) async -> PhotoSaveFailure? {
        let result = await perform { try await $0.deletePhotos(photoIds: photoIds) }
        if case .failure(let failure) = result { return failure }
        return nil
    }

    /// What deleting `photoIds` loses, as far as this device can tell. Asked when the question
    /// opens, never while a view draws: it looks in Photos.
    func photoLoss(_ photoIds: [String]) async -> PhotoLoss {
        let wanted = Set(photoIds)
        let confirmed = await PhotoLibraryLink.originalsInPhotos(state.photos.filter { wanted.contains($0.photoId) })
        return PhotoLoss(unconfirmed: wanted.subtracting(confirmed).count, syncing: syncOnForThisLibrary, backingUp: cloudBackupOn,
                         onNewerPieces: wanted.intersection(sync.photosOnNewerPieces).count)
    }

    /// Runs the normal photo → furniture flow on a photo that is already stored. Its bytes are
    /// matched by SHA-256, so confirming links the existing record instead of storing a copy.
    func beginFurniture(fromPhoto photoId: String, sorting: SortingPosition? = nil) {
        guard let record = photo(photoId) else { return }
        photos.libraryShown = false
        openedFurnitureID = nil
        let filename = record.filename
        // The stored bytes come back as they are, so they match their own record.
        beginImport(filename: filename, sorting: sorting, fullSizeCopy: .onlyHere) { [weak self] in
            guard let url = await self?.originalURL(photoId: photoId) else { throw IngestError.notAnImage }
            return try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        }
    }

    func showFurniture(_ instanceId: String) {
        photos.libraryShown = false
        openedFurnitureID = instanceId
    }
}

/// `yyyy-MM-dd` ↔ `Date` for the date picker and for showing a day. Days live in
/// `PhotoLibrary.dayCalendar` (Gregorian, UTC), where every day exists: a day whose noon or
/// whole date the device's zone skipped is still shown and edited as itself.
enum DayCodec {
    static var calendar: Calendar { PhotoLibrary.dayCalendar }
    static var timeZone: TimeZone { PhotoLibrary.dayCalendar.timeZone }

    static func date(from day: String?) -> Date? {
        PhotoLibrary.dayDate(day)
    }

    static func day(from date: Date) -> String {
        PhotoLibrary.day(of: date)
    }

    /// The last day the picker offers: today on this device, as a picker date.
    static var latest: Date {
        let today = PhotoLibrary.dayDate(PhotoLibrary.today(in: .current)) ?? Date()
        return calendar.dateInterval(of: .day, for: today)?.end.addingTimeInterval(-1) ?? today
    }
}

extension Wording {
    /// "2026年3月" for a `yyyy-MM` section, "日期未知" for the section without capture days.
    static func monthTitle(_ month: String?) -> String {
        guard let month, let date = DayCodec.date(from: month + "-01") else { return String(localized: "日期未知") }
        return date.formatted(Date.FormatStyle(locale: AppLanguage.locale, calendar: DayCodec.calendar, timeZone: DayCodec.timeZone).year().month(.wide))
    }

    static func dayTitle(_ day: String?) -> String? {
        guard let date = DayCodec.date(from: day) else { return nil }
        return date.formatted(Date.FormatStyle(locale: AppLanguage.locale, calendar: DayCodec.calendar, timeZone: DayCodec.timeZone).year().month().day())
    }

    static func filterTitle(_ filter: PhotoFilter) -> String {
        switch filter {
        case .all: String(localized: "全部")
        case .favorites: String(localized: "filter.favorites", defaultValue: "收藏", comment: "Photo library filter: the favorite photos")
        case .unlinked: String(localized: "未放进家具")
        }
    }

    static func deletionMessage(_ impact: PhotoDeletionImpact, loss: PhotoLoss) -> String {
        let original = loss.unconfirmed == 0
            ? String(localized: "系统相册里的原片不受影响。")
            : String(localized: "没能确认系统相册里还有原片：这可能是唯一一份。")
        var lines = [sentences(String(localized: "喵空间里的这张照片和它的便签会被删除，无法撤销。"), original)] + reachLines(loss)
        // Furniture is never deleted with a photo: a piece left without photos stays as it is.
        if !impact.furnitureToUpdate.isEmpty {
            lines.append(String(localized: "\(Wording.quotedNames(impact.furnitureToUpdate))不会被删除，只是不再包含这一张。"))
        }
        return lines.joined(separator: "\n")
    }

    /// "3 张照片 · 2024年3月1日 – 2026年5月2日". Photos without a capture day are counted, never dated.
    static func albumLine(_ photos: [PhotoRecord]) -> String {
        let days = photos.compactMap(\.captureDate).sorted()
        var line = String(localized: "\(photos.count) 张照片")
        if let first = days.first, let last = days.last, let from = dayTitle(first), let to = dayTitle(last) {
            line += first == last ? " · \(from)" : " · \(from) – \(to)"
        }
        let undated = photos.count - days.count
        if undated > 0, !days.isEmpty { line += " · " + String(localized: "\(undated) 张日期未知") }
        return line
    }

    static func fileLine(_ photo: PhotoRecord) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(photo.byteSize), countStyle: .file)
        return "\(photo.width)×\(photo.height) · \(size)"
    }
}
