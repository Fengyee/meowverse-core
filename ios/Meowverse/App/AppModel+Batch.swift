import os
import MeowverseCore
import PhotosUI
import SwiftUI

/// Photos picked together go straight into the photo library in the background. Deciding which
/// furniture each one belongs to happens afterwards, one photo at a time, at the user's pace.
struct BatchImportState {
    struct Progress: Equatable {
        /// Photos dealt with for good: stored (or found already in furniture) or unreadable.
        /// The rest, if the import ends early, are the ones the end notice offers to pick again.
        var done: Int
        var total: Int
        /// What the bar counts.
        var shown: Int { min(done, total) }
    }

    /// Non-nil while picked photos are being stored.
    var progress: Progress?
    /// What went wrong with the last batch, ready to show once.
    var notice: String?
    /// photoIds still to be sorted into furniture, in the order they were picked.
    var pending: [String] = []
    /// Only photos created by this import can be withdrawn during review.
    var insertedRevisions: [String: Int] = [:]
    /// Non-nil while the user goes through `pending`: how many photos this round started with.
    var sortingTotal: Int?
    var sortingDone = 0
    /// Counts photos stored by batches; drives the "done" haptic.
    var importedCount = 0
    /// Prints, suggestions and review order of the last batch (see AppModel+Suggestions.swift).
    var suggestions = SuggestionState()

    fileprivate var task: Task<Void, Never>?
    fileprivate var runID: UUID?
    fileprivate var checkpoint: AsyncStream<Void>?
}

/// One picked photo after reading and decoding.
nonisolated enum PreparedPhoto: Sendable {
    case ready(ImportDraft)
    /// It could not be read or decoded.
    case unreadable
    /// The photo library did not hand it over in time, also when asked again (`LoadTimedOut`).
    /// Not unreadable: picking it again later can work.
    case notLoaded
}

/// Where a photo under review sits in the sorting queue.
struct SortingPosition: Equatable {
    let photoId: String
    let index: Int
    let total: Int
}

/// How the review of one photo ended.
enum ImportEnding: Equatable {
    case placed
    case attached(instanceId: String)
    case keptInLibrary
    case skipped
    case viewExisting(instanceId: String)
    case cancelled

    var isAttachment: Bool {
        if case .attached = self { return true }
        return false
    }
}

extension AppModel {
    private var pendingKey: String { "import.pending.\(options.storeFolder)" }

    /// Queued photos that are still in the library and still in no furniture.
    var pendingPhotoIds: [String] {
        batch.pending.filter { libraryIndex.photo(id: $0) != nil && !isOnFurniture($0) }
    }

    func loadPendingQueue() {
        let defaults = UserDefaults.standard
        if let saved = defaults.dictionary(forKey: pendingKey),
           let ids = saved["ids"] as? [String] {
            batch.pending = ids
            batch.insertedRevisions = saved["insertedRevisions"] as? [String: Int] ?? [:]
        } else {
            // Older queues carry no evidence that their photos were new. Skipping keeps them.
            batch.pending = defaults.stringArray(forKey: pendingKey) ?? []
            batch.insertedRevisions = [:]
        }
        loadDeclined()
    }

    private func setPending(_ ids: [String], insertedRevisions: [String: Int]? = nil) {
        batch.pending = ids
        let remaining = Set(ids)
        batch.insertedRevisions = (insertedRevisions ?? batch.insertedRevisions).filter { remaining.contains($0.key) }
        UserDefaults.standard.set(["ids": ids, "insertedRevisions": batch.insertedRevisions], forKey: pendingKey)
    }

    func clearBatchQueue() {
        cancelPreparingImport()
        stopSorting()
        batch.notice = nil
        photos.storageReceipt = nil
        setPending([])
        resetSuggestions()
    }

    var switchingLibraries: Bool {
        backup.busy?.operation == .replacing || backup.busy?.operation == .clearing
    }

    /// In-flight writes finish on the store actor or fail their generation check. A loader that
    /// has not returned cannot hold a restore hostage or publish into its replacement.
    func stopPhotoImports() async {
        cancelPreparingImport()
        batch.task?.cancel()
        photos.addTask?.cancel()
        // A chunk already on disk must finish publishing its queue, even if the switch fails.
        if let checkpoint = batch.checkpoint { for await _ in checkpoint {} }
        batch.runID = nil
        batch.task = nil
        batch.progress = nil
        photos.addTask = nil
        photos.adding = nil
        photos.addRun = nil
    }

    // MARK: Storing a batch

    func importBatch(_ items: [PhotosPickerItem]) {
        importBatch(loaders: items.map { item in { try await PhotoLibraryLink.load(item) } },
                    assetIdentifiers: items.map(\.itemIdentifier))
    }

    func importBatch(loaders: [PhotoLoader], assetIdentifiers: [String?] = []) {
        guard !loaders.isEmpty, !switchingLibraries, batch.progress == nil, batch.sortingTotal == nil else { return }
        batch.progress = .init(done: 0, total: loaders.count)
        batch.notice = nil
        let prior = pendingPhotoIds, generation = libraryGeneration, runID = UUID()
        batch.runID = runID
        batch.task = Task {
            var insertedPhotos: [PhotoRecord] = []
            var pickerIndex: [String: Int] = [:]
            var revisions = batch.insertedRevisions
            var unreadable = 0, alreadyPlaced = 0, timedOut = 0
            var saveFailure: PhotoSaveFailure?

            // Each photo is saved as soon as it is ready, so a slow or silent request never
            // holds back photos that already arrived. The bar and the persistent sorting queue
            // move only after the photo is durable.
            await prepareEach(loaders, assetIdentifiers: assetIdentifiers) { index, photo in
                guard batch.runID == runID, !switchingLibraries, generation == libraryGeneration else { return false }
                switch photo {
                case .unreadable:
                    unreadable += 1
                    batch.progress?.done += 1
                    return true
                case .notLoaded:
                    timedOut += 1
                    return true
                case .ready(let draft):
                    let (checkpoint, signal) = AsyncStream<Void>.makeStream()
                    batch.checkpoint = checkpoint
                    defer { batch.checkpoint = nil; signal.finish() }
                    // Its own task: a photo that arrived is saved even while the import stops.
                    let result = await Task { await perform { try await $0.importPickerPhotos([draft], generation: generation) } }.value
                    guard batch.runID == runID else { return false }
                    guard case .success(let imported) = result, let stored = imported.first else {
                        if case .failure(let failure) = result { saveFailure = failure }
                        return false
                    }
                    if stored.inserted { insertedPhotos.append(stored.photo) }
                    let id = stored.photo.photoId
                    if isOnFurniture(id) {
                        alreadyPlaced += 1
                    } else {
                        if stored.inserted { revisions[id] = stored.photo.revision }
                        pickerIndex[id] = min(index, pickerIndex[id] ?? index)
                        let ids = pickerIndex.sorted { $0.value < $1.value }.map(\.key)
                        setPending(prior.filter { pickerIndex[$0] == nil } + ids, insertedRevisions: revisions)
                    }
                    batch.progress?.done += 1
                    return true
                }
            }

            await store?.finishPickerImport()
            guard !switchingLibraries, batch.runID == runID else { return }
            batch.runID = nil
            let handled = batch.progress?.done ?? 0
            batch.progress = nil
            batch.task = nil
            var lines: [String] = []
            if alreadyPlaced > 0 { lines.append(String(localized: "\(alreadyPlaced) 张已经在家具里，没有重复导入。")) }
            if unreadable > 0 { lines.append(String(localized: "\(unreadable) 张读不出来，没有导入。")) }
            if let saveFailure {
                // Once some are in, "everything stays as it was" is no longer true.
                lines.append(pickerIndex.isEmpty || saveFailure.error?.isOutOfSpace == true
                             ? saveFailure.message : String(localized: "后面的照片没能保存。"))
            }
            // Not handed over in time, not reached before a stop or a failed save: the same
            // number the bar left uncounted.
            if handled < loaders.count {
                lines.append(String(localized: "还有 \(loaders.count - handled) 张没有导入，可以再选一次。"))
                if timedOut > 0 { lines.append(Self.timedOutLine(timedOut)) }
            }
            if !lines.isEmpty {
                if !pickerIndex.isEmpty { lines.insert(String(localized: "已导入 \(pickerIndex.count) 张。"), at: 0) }
                batch.notice = lines.joined(separator: "\n")
            }
            photos.storageReceipt = PhotoStorageReceipt(photos: insertedPhotos)
            batch.importedCount += pickerIndex.count
            // Prints for every stored photo, then suggestions; the review can start meanwhile.
            if !pickerIndex.isEmpty { batchStored(pickerIndex.sorted { $0.value < $1.value }.map(\.key)) }
        }
    }

    func cancelBatchImport() {
        batch.task?.cancel()
    }

    /// The background time ran out, or the user stopped the import from the system's progress:
    /// every running import stops as 「停止导入」 stops a batch. Stored photos stay; what was not
    /// imported is reported when the user is back.
    func stopImportsForTheSystem() {
        cancelBatchImport()
        photos.addTask?.cancel()
    }

    /// Under 「还有 N 张没有导入」: what happened to the photos that timed out, in plain words.
    static func timedOutLine(_ count: Int) -> String {
        String(localized: "其中 \(count) 张等了很久也没有读到，可能是 iCloud 还没有下载好。")
    }

    /// Reads and decodes up to three photos at a time, off the main actor, and hands each one to
    /// `handle` on the main actor as it becomes ready. The next photo is only started once
    /// `handle` returns, so at most three originals are in memory however many were picked.
    /// `handle` returns false to stop early. Every photo arrives at most once, ready or not.
    /// `assetIdentifiers` runs parallel to `loaders` (the photo library's identifier for each
    /// picked photo); it may be shorter or empty.
    ///
    /// Each request has a time limit and one longer retry (`LoadWatch.photos`): a request that
    /// never answers arrives as `.notLoaded` and the import moves on. Once one has timed out,
    /// the rest are fetched one at a time, in case several iCloud downloads at once are part of
    /// the trouble. When the calling task is cancelled, photos whose bytes already arrived are
    /// still decoded and handed over (so they can be saved); nothing else is.
    func prepareEach(_ loaders: [PhotoLoader], assetIdentifiers: [String?] = [],
                     handle: (Int, PreparedPhoto) async -> Bool) async {
        let linked = photoLibrary.isOn, store = self.store
        let watch = LoadWatch(limits: options.loadWatch.limits, suspensions: { Suspensions.current })
        await withTaskGroup(of: (Int, PreparedPhoto, Bool).self) { group in
            var next = 0, inFlight = 0, width = 3, stopping = false
            func startNext() {
                guard !Task.isCancelled, next < loaders.count, inFlight < width else { return }
                let index = next, load = loaders[index]
                let assetIdentifier = index < assetIdentifiers.count ? assetIdentifiers[index] : nil
                next += 1
                inFlight += 1
                group.addTask {
                    let timeOuts = OSAllocatedUnfairLock(initialState: false)
                    let data: Data
                    PhotoLoadLog.shared.record { $0.requested += 1 }
                    do {
                        try Task.checkCancellation()
                        data = try await LoadWatchdog.load(watch, timedOut: {
                            timeOuts.withLock { $0 = true }
                            PhotoLoadLog.shared.record { $0.timedOut += 1 }
                        }, load)
                    } catch is LoadTimedOut {
                        PhotoLoadLog.shared.record { $0.gaveUp += 1 }
                        return (index, .notLoaded, true)
                    } catch {
                        // A stop cancels requests; only a request that failed by itself counts.
                        if !Task.isCancelled { PhotoLoadLog.shared.record { $0.failed += 1 } }
                        return (index, .unreadable, timeOuts.withLock { $0 })
                    }
                    let timedOut = timeOuts.withLock { $0 }
                    // Its own task: bytes that arrived are decoded even while the import stops.
                    // Picked photos: the full size stays in the photo library.
                    let decoding = Task {
                        try await PhotoLibraryLink.makeDraft(data: data, filename: nil, assetIdentifier: assetIdentifier,
                                                             fullSizeCopy: .inPhotoLibrary, linked: linked, store: store)
                    }
                    guard let draft = try? await decoding.value else { return (index, .unreadable, timedOut) }
                    return (index, .ready(draft), timedOut)
                }
            }
            for _ in 0..<width { startNext() }
            for await (index, photo, timedOut) in group {
                inFlight -= 1
                if timedOut { width = 1 }
                if Task.isCancelled, !stopping {
                    stopping = true
                    group.cancelAll()
                }
                if stopping {
                    // Stopped: a photo that already arrived is still handed over; the rest end here.
                    if case .ready = photo, await !handle(index, photo) { break }
                    continue
                }
                guard await handle(index, photo) else {
                    group.cancelAll()
                    break
                }
                while inFlight < width, next < loaders.count, !Task.isCancelled { startNext() }
            }
        }
    }

    // MARK: Sorting the queue

    /// Goes through `ids` (default: everything pending) one photo at a time.
    func startSorting(_ ids: [String]? = nil) {
        let queue = ids ?? pendingPhotoIds
        guard !queue.isEmpty, batch.progress == nil, batch.sortingTotal == nil, importSession == nil, !isPreparingImport else { return }
        if let ids {
            let selected = Set(ids)
            setPending(ids + pendingPhotoIds.filter { !selected.contains($0) })
        }
        batch.suggestions.sortingInChosenOrder = ids != nil
        refreshReviewOrder()
        batch.sortingTotal = queue.count
        batch.sortingDone = 0
        openNextPending()
    }

    func stopSorting() {
        if importSession?.sorting != nil { importSession = nil }
        batch.sortingTotal = nil
        batch.suggestions.sortingInChosenOrder = false
    }

    private func openNextPending() {
        guard batch.sortingTotal != nil, !sortingQueue.isEmpty else {
            stopSorting()
            return
        }
        if advanceRepresentativeRound(open: { [weak self] in self?.openNextPending() }) { return }
        guard let total = batch.sortingTotal, let photoId = nextToSort else { return }
        beginFurniture(fromPhoto: photoId, sorting: SortingPosition(photoId: photoId, index: batch.sortingDone + 1, total: max(total, batch.sortingDone + 1)))
    }

    /// The review's order changed under the photo on screen (the representative round was
    /// skipped): open the photo that is now first, unless it is already the one shown.
    func reopenAtQueueHead() {
        guard importSession?.sorting != nil, let head = nextToSort, importSession?.sorting?.photoId != head else { return }
        importSession = nil
        openNextPending()
    }

    /// The photo could not be opened for review: it goes to the back so the queue is not stuck on it.
    func sortingFailed(_ position: SortingPosition) {
        setPending(batch.pending.filter { $0 != position.photoId } + [position.photoId])
        stopSorting()
    }

    func skipSortingPhoto(_ session: ImportSession) async -> PhotoSaveFailure? {
        guard importSession === session, let position = session.sorting else { return nil }
        if let revision = batch.insertedRevisions[position.photoId] {
            let result = await perform { try await $0.discardBatchPhoto(photoId: position.photoId, ifUnchangedSince: revision, generation: session.generation) }
            if case .failure(let failure) = result { return failure }
        }
        endImport(session, .skipped)
        return nil
    }

    func endImport(_ session: ImportSession, _ ending: ImportEnding) {
        guard importSession === session else { return }
        // Confirmed (stored by now) or discarded: the held capture has done its job.
        if let held = session.pendingCaptureSHA { forgetPendingCapture(held, library: session.generation) }
        if ending == .placed || ending.isAttachment { keepReviewPrint(of: session) }
        if let position = session.sorting {
            switch ending {
            case .cancelled:
                stopSorting()
            case .viewExisting(let instanceId):
                stopSorting()
                openedFurnitureID = instanceId
            case .placed, .attached, .keptInLibrary, .skipped:
                setPending(batch.pending.filter { $0 != position.photoId })
                batch.sortingDone += 1
                photoSortedByHand(position.photoId)
                guard ending == .placed else {
                    openNextPending()
                    return
                }
                // After placing a new piece, show it in the room before the next photo.
                importSession = nil
                Task {
                    try? await Task.sleep(for: .milliseconds(1100))
                    guard batch.sortingTotal != nil, importSession == nil, !isPreparingImport else { return }
                    openNextPending()
                }
            }
            return
        }
        if session.existingPhoto == nil, [.placed, .keptInLibrary].contains(ending) || ending.isAttachment,
           let stored = state.photos.first(where: { $0.isSamePhoto(as: session.draft) }) {
            photos.storageReceipt = PhotoStorageReceipt(photos: [stored])
        }
        importSession = nil
        switch ending {
        case .attached(let instanceId), .viewExisting(let instanceId):
            openedFurnitureID = instanceId
        case .keptInLibrary where session.existingPhoto == nil:
            // Show where the photo went: the library, which lists it as not in any furniture.
            photos.filter = .all
            photos.libraryShown = true
        case .placed, .keptInLibrary, .skipped, .cancelled:
            break
        }
    }
}
