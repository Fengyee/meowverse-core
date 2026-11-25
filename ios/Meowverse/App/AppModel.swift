import MeowverseCore
import os
import PhotosUI
import SwiftUI

/// One-shot switch for the save-failure drill: the first state write after launch fails, later ones succeed.
final class FaultSwitch: Sendable {
    private let armed: OSAllocatedUnfairLock<Bool>
    /// `-MeowverseDiskFullAfter <n>`: after n photos were written there is no space.
    private let room: OSAllocatedUnfairLock<Int?>
    init(armed: Bool) {
        self.armed = OSAllocatedUnfairLock(initialState: armed)
        var left: Int?
        #if DEBUG || DRILLS
        let args = ProcessInfo.processInfo.arguments
        if let at = args.firstIndex(of: "-MeowverseDiskFullAfter"), at + 1 < args.count { left = Int(args[at + 1]) }
        #endif
        room = OSAllocatedUnfairLock(initialState: left)
    }

    nonisolated func trip(_ step: StoreStep) throws {
        if step == .writeOriginal {
            let full = room.withLock { left -> Bool in
                guard let now = left else { return false }
                left = max(now - 1, 0)
                return now == 0
            }
            // As the store reports a real failed write (injected faults aren't wrapped).
            if full { throw StoreError.io("addPhoto:\(NSCocoaErrorDomain):\(CocoaError.Code.fileWriteOutOfSpace.rawValue)") }
        }
        // The state write of an ordinary save, or the switch of a restore / clear all.
        guard step == .writeState || step == .swapLibrary else { return }
        let fire = armed.withLock { value -> Bool in
            defer { value = false }
            return value
        }
        if fire { throw CocoaError(.fileWriteUnknown) }
    }
}

@Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed
        case corruptLibrary
        /// Saved by a newer app version; nothing is touched and retrying cannot help.
        case needsUpdate
    }

    private(set) var phase: Phase = .loading
    private(set) var state: AppState = .empty
    /// Both directions of the photo–furniture link for the current state.
    private(set) var libraryIndex = LibraryIndex(state: .empty)
    private(set) var art: ArtLibrary?
    private(set) var isPreparingImport = false
    var libraryGeneration = UUID()
    /// Set at launch when the last run left a capture unconfirmed (`findPendingCapture`).
    var pendingCaptureOffer: PendingCapture?
    var importSession: ImportSession? {
        didSet {
            if oldValue !== importSession {
                similarity.reviewTask?.cancel()
                recognitionTask?.cancel()
            }
        }
    }
    var openedFurnitureID: String?
    var movingFurnitureID: String?
    /// A stored piece being put back into the room.
    var restoringFurnitureID: String?
    /// The catalog flow that places a piece without a photo.
    var addFurnitureShown = false
    var importFailure: String?
    /// Photo library navigation and progress (see AppModel+Photos.swift).
    var photos = PhotoUIState() {
        didSet {
            if photos.adding != oldValue.adding {
                importBackground.update(.adding, photos.adding.map { .init(shown: $0.shown, total: $0.total) })
            }
        }
    }
    /// Furniture library filters, order and the "locate in the room" highlight (see AppModel+Furniture.swift).
    var pieces = FurnitureUIState()
    /// Settings: export, restore, clear all (see AppModel+Backup.swift).
    var backup = BackupUIState()
    /// iCloud Drive backup (see AppModel+ICloudBackup.swift). Untouched while the feature is off.
    var cloud = CloudBackupUIState()
    /// iCloud sync between devices (see Sync/AppModel+ICloudSync.swift). Untouched while the feature is off.
    var sync = CloudSyncUIState()
    /// Background import of several photos and the sorting queue (see AppModel+Batch.swift).
    var batch = BatchImportState() {
        didSet {
            if batch.progress != oldValue.progress {
                importBackground.update(.batch, batch.progress.map { .init(shown: $0.shown, total: $0.total) })
            }
        }
    }
    /// Keeps imports running while the app is in the background (see ImportBackgroundTime.swift).
    let importBackground = ImportBackgroundTime()
    let photoLibrary = PhotoLibraryLink()
    @ObservationIgnored private var recognitionTask: Task<Void, Never>?
    /// Feature prints of the photos in furniture (see AppModel+Similarity.swift).
    @ObservationIgnored var similarity = SimilarityState()
    /// Corrections read from originals whose saving failed; see `photo(_:)`. Never written to disk from here.
    private(set) var unsavedPhotoRepairs: [String: PhotoMetadataRepair] = [:]
    /// Set once when the last save had not finished and the previous room was restored.
    var restoredNotice = false
    var recoveryNotice: String?
    /// What Bella is doing in the room right now; written by the room scene, shown as a caption.
    var bellaStatus = BellaStatus.atEntrance
    /// The room the user last chose to look at (see AppModel+Rooms.swift). Read `currentRoomId`.
    var chosenRoomId = AppState.primaryRoomId
    /// The rooms and cats pages (see AppModel+Rooms.swift).
    var home = HomeUIState()
    /// Which cat the room shows (built-in and imported cat packs).
    let catPacks: CatPackLibrary
    /// 设置 › 画质: what the room draws with.
    let quality: RenderQualityModel
    /// 未下载 / 下载中 / 已就绪 / 失败 of the built-in cats' 低/高 meshes (`CatTierSupport.swift`).
    let catTiers: CatTierDownloads

    let options: LaunchOptions
    private(set) var store: LibraryStore?
    private var prepareTask: Task<Void, Never>?
    private var prepareGeneration = 0
    let recognizer: any FurnitureRecognizing = VisionFurnitureRecognizer()
    /// How prints are made now. DINOv2 is replaced by Vision, with a new print cache, when its
    /// model fails to load (`similarityModelLoaded`).
    @ObservationIgnored var embedder: any PhotoEmbedding
    /// Which model makes the prints, as far as is known now (for the bug report).
    var recognitionEngine: RecognitionDiagnostics.Engine
    private let log = Logger(subsystem: "app.meowverse", category: "app")
    private let signposter = Perf.signposter

    init(options: LaunchOptions) {
        self.options = options
        catPacks = CatPackLibrary(options: options)
        quality = RenderQualityModel(options: options)
        catTiers = CatTierDownloads(transport: Self.makeCatTierTransport(options))
        let (outcomes, report) = AsyncStream<DinoPhotoEmbedder.LoadOutcome>.makeStream()
        embedder = Self.makeEmbedder(options, onLoad: { report.yield($0) })
        recognitionEngine = Self.initialEngine(of: embedder)
        Task { [weak self] in
            for await outcome in outcomes { self?.similarityModelLoaded(outcome) }
        }
        #if DEBUG || DRILLS
        importBackground.drillExpiryAfter = options.importExpiryDrill
        #endif
        importBackground.stopImports = { [weak self] in self?.stopImportsForTheSystem() }
    }

    var catalog: FurnitureCatalog? { art?.catalog }

    /// Every piece the library holds, in the room and in the storage box.
    var furnitureCount: Int { state.allFurniture.count }

    /// The name the user chose for their cat.
    var catName: String { state.primaryCat.name }

    /// Shows what the store holds now. Used after a change that went around `perform`.
    func republish() async {
        guard let store else { return }
        (state, libraryIndex) = await store.indexedSnapshot()
    }

    /// A piece placed in a room, whichever room. A piece that was put away is found by `anyFurniture`.
    func furniture(_ id: String?) -> PhotoFurniture? {
        guard let id else { return nil }
        return state.placedFurniture.first { $0.instanceId == id }
    }

    /// A piece wherever it is: in the room or in the storage box.
    func anyFurniture(_ id: String?) -> PhotoFurniture? {
        guard let id else { return nil }
        return state.anyItem(id: id)
    }

    /// Where a new or returning piece is first shown in the placement editor: the first free
    /// spot, or a corner the editor then reports as not allowed when the room has no room left.
    func suggestedPlacement(for piece: CatalogModel) -> Placement {
        if let catalog, let free = GridRules.firstFreePlacement(for: piece, in: roomFurniture, catalog: catalog) { return free }
        return Placement(modelId: piece.id, x: 0, z: 0, width: piece.defaultWidth, depth: piece.defaultDepth,
                         wall: piece.mount == .wall ? .back : nil)
    }

    /// The record shown with the photo's pixels. A full HEIF imported by an older version can
    /// show its designated primary before the corrected size and EXIF day could be saved; until
    /// a retry saves them, the record shown here carries them instead of item zero's.
    func photo(_ id: String) -> PhotoRecord? {
        guard let stored = libraryIndex.photo(id: id) else { return nil }
        return unsavedPhotoRepairs[id]?.applied(to: stored) ?? stored
    }

    /// The library with the same unsaved repairs as `photo(_:)`, for month groups, counts,
    /// cells, filters and reminders (fifth review, R5-05). `state` itself when nothing waits,
    /// which is almost always; never saved or backed up.
    var shownState: AppState { state.applying(unsavedPhotoRepairs) }

    /// True while `photo(_:)` shows a corrected size and day that is not saved yet.
    func hasUnsavedRepair(_ id: String) -> Bool {
        guard let stored = libraryIndex.photo(id: id), let repair = unsavedPhotoRepairs[id] else { return false }
        return repair.applied(to: stored) != stored
    }

    // MARK: Launch

    func bootstrap() async {
        guard phase != .ready else { return }
        phase = .loading
        let interval = signposter.beginInterval("LoadLibrary")
        defer { signposter.endInterval("LoadLibrary", interval) }
        do {
            let art = try self.art ?? ArtLibrary()
            self.art = art
            let root = try storeRoot()
            let fault = FaultSwitch(armed: options.failNextSave)
            let store = LibraryStore(root: root, catalog: art.catalog) { step in try fault.trip(step) }
            do {
                try await store.load()
                (state, libraryIndex) = await store.indexedSnapshot()
            } catch StoreError.corruptState {
                self.store = store
                phase = .corruptLibrary
                return
            }
            self.store = store
            libraryGeneration = await store.generation
            if sync.openedGeneration == nil { sync.openedGeneration = libraryGeneration }
            loadChosenRoom()
            loadPendingQueue()
            removeLeftoverExports()
            restoredNotice = await store.recoveredFromBackup
            // Read now: the store forgets it at the next write. Sync must not diff against
            // its file from before the state it fell back to (see AppModel+ICloudSync).
            sync.libraryFellBack = restoredNotice
            if await store.deletionPending { recoveryNotice = Self.photoMessage(for: StoreError.deletionCleanupPending) }
            phase = .ready
            openFeaturePrintCache()
            refreshFeaturePrints()
            Perf.mark("LibraryReady")
            log.info("library ready: \(self.state.placedFurniture.count) items, \(self.state.photos.count) photos, revision \(self.state.revision)")
        } catch StoreError.newerSchema {
            log.error("library was written by a newer schema")
            phase = .needsUpdate
        } catch {
            log.error("library failed to open: \(String(describing: type(of: error)), privacy: .public)")
            phase = .failed
        }
    }

    func finishCorruptLibraryRecovery(notice: String) {
        loadChosenRoom()
        openFeaturePrintCache()
        refreshFeaturePrints()
        recoveryNotice = notice
        phase = .ready
    }

    private func storeRoot() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = base.appending(path: "Meowverse").appending(path: options.storeFolder)
        if options.resetStore, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        return root
    }

    // MARK: Import

    func beginImport(from item: PhotosPickerItem) {
        beginImport(filename: nil, assetIdentifier: item.itemIdentifier) {
            try await PhotoLibraryLink.load(item)
        }
    }

    /// `assetIdentifier` is the photo library's identifier for a photo that came from the picker.
    /// `fullSizeCopy` is `.onlyHere` for bytes read back from the app's own library, which must
    /// come out exactly as stored so they match their record.
    func beginImport(filename: String?, sorting: SortingPosition? = nil, assetIdentifier: String? = nil,
                     fullSizeCopy: FullSizeCopy = .inPhotoLibrary, load: @escaping @Sendable () async throws -> Data) {
        startImport(filename: filename, sorting: sorting, source: fullSizeCopy == .onlyHere ? .stored : .picked) {
            LoadedPhoto(data: try await load(), assetIdentifier: assetIdentifier, fullSizeCopy: fullSizeCopy)
        }
    }

    /// A photo just taken with the in-app camera, already encoded with its EXIF (see
    /// `InAppCamera.encode`). It goes to the same review as a picked photo.
    ///
    /// With `saveToPhotos`, the bytes are first added to the photo library and the new asset's
    /// identifier is kept like a picked photo's. That save is not part of the import: it still
    /// finishes if the review is cancelled, as with the system camera. If it fails, the photo
    /// is imported all the same and the review says it is not in Photos.
    ///
    /// Unless Photos confirmed the save, these bytes are the only full-size file, so the app
    /// keeps them whole instead of the reduced copy it keeps of a picked photo.
    func beginCapturedImport(saveToPhotos: (@Sendable (Data) async -> InAppCamera.LibrarySave)?,
                             encode: @escaping @Sendable () throws -> Data) {
        startImport(filename: nil, sorting: nil, source: .captured) {
            let data = try await Self.offMain { try encode() }
            try Task.checkCancellation()
            let save: CameraCapture.LibrarySave
            if let saveToPhotos {
                save = await Task.detached(priority: .userInitiated, operation: { await saveToPhotos(data) }).value
            } else {
                save = .notWanted
            }
            return LoadedPhoto(data: data, assetIdentifier: save.assetIdentifier, fullSizeCopy: save.fullSizeCopy,
                               capturedOutsidePhotos: save.fullSizeCopy == .onlyHere, photosSave: save)
        }
    }

    /// The capture the last run left unconfirmed, offered once the library is open. Nothing of
    /// it is in the library; 继续 reopens its review, 不要了 deletes it.
    func findPendingCapture() async {
        guard phase == .ready, pendingCaptureOffer == nil, importSession == nil, !isPreparingImport, !switchingLibraries,
              let store else { return }
        #if DEBUG || DRILLS
        // UI tests look at the library while the capture is still held (`-MeowverseNoCaptureOffer`).
        if ProcessInfo.processInfo.arguments.contains("-MeowverseNoCaptureOffer") { return }
        #endif
        // Bound to the library it was asked about (audit V24-01): an answer arriving after a
        // restore or clear-all switched libraries is not offered in the new one.
        let library = libraryGeneration
        guard let capture = await store.pendingCapture(generation: library), phase == .ready, importSession == nil,
              !isPreparingImport, !switchingLibraries, library == libraryGeneration else { return }
        pendingCaptureOffer = capture
    }

    /// 继续: the same review as before the app stopped, saying again what Photos did.
    func resumePendingCapture() {
        guard let capture = pendingCaptureOffer else { return }
        pendingCaptureOffer = nil
        startImport(filename: nil, sorting: nil, source: .resumedCapture) {
            LoadedPhoto(data: capture.data, assetIdentifier: nil, fullSizeCopy: .onlyHere,
                        capturedOutsidePhotos: true, photosSave: capture.save.librarySave)
        }
    }

    /// 不要了.
    func discardPendingCapture() {
        guard let capture = pendingCaptureOffer else { return }
        pendingCaptureOffer = nil
        forgetPendingCapture(capture.sha256, library: libraryGeneration)
    }

    /// `library`: the generation the capture belongs to; a later library's file is left alone.
    func forgetPendingCapture(_ sha256: String, library: UUID) {
        guard let store else { return }
        Task { await store.removePendingCapture(sha256: sha256, generation: library) }
    }

    /// What an import read, and where the photo also lives.
    nonisolated struct LoadedPhoto: Sendable {
        var data: Data
        var assetIdentifier: String?
        /// Whether the photo library also has the full-size file; if not, it is not reduced.
        var fullSizeCopy = FullSizeCopy.inPhotoLibrary
        /// Taken in the app and kept nowhere else.
        var capturedOutsidePhotos = false
        /// What Photos did with a photo taken in the app; nil for any other photo.
        var photosSave: CameraCapture.LibrarySave?
    }

    /// Where an import's photo came from: what can be promised when it can't be read.
    /// `resumedCapture`: a capture held from an earlier run (`PendingCapture`).
    private enum ImportSource { case picked, stored, captured, resumedCapture }

    private static func readFailure(_ source: ImportSource, savedToPhotos: Bool) -> String {
        switch source {
        case .picked: String(localized: "没能读取这张照片。相册里的原照片没有变化，可以再试一次。")
        case .stored: String(localized: "没能读取这张存在喵空间里的照片，可以再试一次。")
        case .captured: savedToPhotos
            ? String(localized: "没能读取刚拍的照片。它已经存进“照片”，可以从相册里再选一次。")
            : String(localized: "没能处理刚拍的照片，它没有存下来。请再拍一张。")
        // Its file stays (see `startImport`), so the next launch asks again.
        case .resumedCapture: String(localized: "没能打开上次拍的照片。它还暂存在这台设备上，下次打开喵空间时会再问你。")
        }
    }

    private func startImport(filename: String?, sorting: SortingPosition?, source: ImportSource,
                             load: @escaping @Sendable () async throws -> LoadedPhoto) {
        guard !switchingLibraries else { return }
        prepareTask?.cancel()
        isPreparingImport = true
        prepareGeneration += 1
        let generation = prepareGeneration, library = libraryGeneration
        let linked = photoLibrary.isOn
        prepareTask = Task {
            let interval = signposter.beginInterval("PrepareImport")
            defer {
                signposter.endInterval("PrepareImport", interval)
                // An older, cancelled attempt must not hide the progress of a newer one.
                if generation == prepareGeneration { isPreparingImport = false }
            }
            var savedToPhotos = false
            // A capture held for after a relaunch: dropped again if its review never opens.
            // One from an earlier run stays until the user answers in its review or 不要了.
            var held: String?
            let keepsHeld = source == .resumedCapture
            do {
                let loaded = try await load()
                savedToPhotos = loaded.photosSave?.fullSizeCopy == .inPhotoLibrary
                try Task.checkCancellation()
                #if DEBUG || DRILLS
                // UI tests (`-MeowverseFailImportRead`): what was loaded can't be prepared.
                if ProcessInfo.processInfo.arguments.contains("-MeowverseFailImportRead") { throw CocoaError(.fileReadUnknown) }
                #endif
                let draft = try await PhotoLibraryLink.makeDraft(data: loaded.data, filename: filename, assetIdentifier: loaded.assetIdentifier,
                                                                fullSizeCopy: loaded.fullSizeCopy, linked: linked, store: store)
                try Task.checkCancellation()
                // Only in memory so far (JOURNEY-NEW-4): kept in the library folder until the
                // user confirms or discards it, so quitting here does not lose it.
                if loaded.capturedOutsidePhotos, let save = loaded.photosSave.flatMap(PendingCapture.Save.init), let store {
                    let capture = PendingCapture(data: loaded.data, save: save)
                    // Once more after a failure: a capture not held is lost if the app stops
                    // before the review saves it, and the review then says so.
                    for attempt in 1...2 where held == nil {
                        do {
                            try await store.keepPendingCapture(capture)
                            held = capture.sha256
                        } catch {
                            log.error("capture not held for a relaunch (attempt \(attempt))")
                        }
                    }
                    try Task.checkCancellation()
                }
                let preview = try await Self.offMain { PhotoIngest.downsampledImage(data: draft.thumbnailJPEG, maxPixel: 512) }
                try Task.checkCancellation()
                let existing = await store?.existingPhoto(matching: draft)
                let linked = existing == nil ? [] : (await store?.furniture(containingPhoto: existing!.photoId) ?? [])
                // Last suspension point passed: a cancel that arrived meanwhile still wins.
                try Task.checkCancellation()
                guard generation == prepareGeneration else {
                    if let held, !keepsHeld { forgetPendingCapture(held, library: library) }
                    return
                }
                let session = ImportSession(draft: draft, generation: library, preview: preview.map { UIImage(cgImage: $0) },
                                            alreadyIn: linked, existingPhoto: existing)
                session.sorting = sorting
                session.capturedOutsidePhotos = loaded.capturedOutsidePhotos
                session.photosSave = loaded.photosSave
                session.pendingCaptureSHA = held
                session.resumedCapture = keepsHeld
                importSession = session
                if existing == nil { retryFailedPrints() }
                Perf.mark("ReviewShown")
                // With furniture photos to compare with, suggestions come from those alone
                // (owner, 2026-11-13: Vision's category guess was right 36% of the time).
                if !comparesWithRoom(excluding: existing?.photoId) { startRecognition(for: session) }
                startSimilarity(for: session)
            } catch {
                if let held, !keepsHeld { forgetPendingCapture(held, library: library) }
                guard generation == prepareGeneration else { return }
                if Task.isCancelled || error is CancellationError {
                    log.info("import cancelled before review")
                    if sorting != nil { stopSorting() }
                    return
                }
                if let sorting { sortingFailed(sorting) }
                if let error = error as? IngestError {
                    importFailure = Self.message(for: error)
                    return
                }
                log.error("import failed: \(String(describing: type(of: error)), privacy: .public)")
                importFailure = Self.readFailure(source, savedToPhotos: savedToPhotos)
            }
        }
    }

    func cancelPreparingImport() {
        prepareTask?.cancel()
        prepareTask = nil
        guard isPreparingImport else { return }
        prepareGeneration += 1
        isPreparingImport = false
        if batch.sortingTotal != nil { stopSorting() }
    }

    private func startRecognition(for session: ImportSession) {
        let token = session.review.beginAnalysis()
        let data = session.draft.data
        let recognizer = self.recognizer
        recognitionTask = Task {
            let interval = signposter.beginInterval("Recognize")
            let result = try? await recognizer.recognize(imageData: data)
            signposter.endInterval("Recognize", interval)
            guard !Task.isCancelled, importSession === session else { return }
            Perf.mark("RecognitionDone")
            // A session the user already left, or a choice they already made, is never overwritten.
            session.review.receive(result, token: token)
        }
    }

    private static func message(for error: IngestError) -> String {
        switch error {
        case .empty, .notAnImage: String(localized: "这个文件不是可以读取的照片。")
        case .tooLarge: String(localized: "这张照片超过 100 MB，暂时无法导入。")
        }
    }

    // MARK: Mutations

    enum SaveOutcome { case saved(PhotoFurniture), failed(String) }

    /// The name to save for what the name field holds. The field shows a built-in style name in
    /// the interface language; left as it is, the catalog's own (Chinese) label is saved, so the
    /// name keeps following the language. Anything else is the user's own name, saved as typed.
    private func nameToStore(_ typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog?.models.first { $0.title == trimmed }?.label ?? typed
    }

    func confirm(_ session: ImportSession, placement: Placement, displayName: String) async -> SaveOutcome {
        let displayName = nameToStore(displayName), roomId = currentRoomId
        return await mutate { store in
            try await store.commitNewFurniture(
                draft: session.draft, placement: placement, displayName: displayName, decision: session.review.sourceDecision,
                roomId: roomId, generation: session.generation)
        }
    }

    func move(instanceId: String, to placement: Placement, displayName: String) async -> SaveOutcome {
        if let refusal = placeEditRefusal([instanceId]) { return .failed(refusal) }
        let displayName = nameToStore(displayName)
        return await mutate { store in
            try await store.updatePlacement(instanceId: instanceId, placement: placement, displayName: displayName)
        }
    }

    /// A piece placed straight from the catalog: it has no source photos yet.
    func addFurniture(placement: Placement, displayName: String) async -> SaveOutcome {
        let displayName = nameToStore(displayName)
        let roomId = currentRoomId
        return await mutate { try await $0.addFurniture(placement: placement, displayName: displayName, roomId: roomId) }
    }

    /// Takes a piece out of the room into storage; its photos stay attached. Returns a message on failure.
    func stow(instanceId: String) async -> String? {
        if let refusal = placeEditRefusal([instanceId]) { return refusal }
        let result = await perform { try await $0.stowFurniture(instanceId: instanceId) }
        if case .failure(let failure) = result { return failure.message }
        return nil
    }

    /// Brings a stored piece back into the room at `placement`, under the name shown in the editor.
    func restore(instanceId: String, placement: Placement, displayName: String) async -> SaveOutcome {
        if let refusal = placeEditRefusal([instanceId]) { return .failed(refusal) }
        let displayName = nameToStore(displayName), roomId = currentRoomId
        return await mutate { store in
            try await store.restoreFurniture(instanceId: instanceId, placement: placement, roomId: roomId, displayName: displayName)
        }
    }

    /// Takes one photo off a piece (in the room or stored). The photo and the piece both stay.
    func unlinkPhoto(_ photoId: String, from instanceId: String) async -> PhotoSaveFailure? {
        let result = await perform { try await $0.unlinkPhoto(photoId: photoId, fromInstance: instanceId) }
        if case .failure(let failure) = result { return failure }
        return nil
    }

    func remove(instanceId: String) async -> String? {
        guard let store else { return String(localized: "房间还没有打开，请稍后再试。") }
        do {
            try await store.removeFurniture(instanceId: instanceId)
            (state, libraryIndex) = await store.indexedSnapshot()
            librarySaved()
            return nil
        } catch {
            (state, libraryIndex) = await store.indexedSnapshot()
            return Self.message(for: error)
        }
    }

    /// Runs one store change and then republishes the store's own state, whatever the outcome:
    /// the room and library always show what is on disk, never a stale or half-applied copy.
    /// The change is for the library shown when it was asked (or, for an undo, the library its
    /// receipt came from: `library`); once that library was replaced, the store refuses it.
    func perform<T: Sendable>(in library: UUID? = nil, _ body: (LibraryStore) async throws -> T) async -> Result<T, PhotoSaveFailure> {
        guard let store else { return .failure(PhotoSaveFailure(message: String(localized: "房间还没有打开，请稍后再试。"), error: nil)) }
        do {
            let value = try await LibraryStore.$expectedGeneration.withValue(library ?? libraryGeneration) { try await body(store) }
            (state, libraryIndex) = await store.indexedSnapshot()
            librarySaved()
            return .success(value)
        } catch {
            (state, libraryIndex) = await store.indexedSnapshot()
            librarySaved()
            log.error("photo save failed: \(String(describing: type(of: error)), privacy: .public)")
            return .failure(PhotoSaveFailure(message: Self.photoMessage(for: error), error: error as? StoreError))
        }
    }

    private func mutate(_ body: (LibraryStore) async throws -> PhotoFurniture) async -> SaveOutcome {
        guard let store else { return .failed(String(localized: "房间还没有打开，请稍后再试。")) }
        let interval = signposter.beginInterval("Save")
        defer { signposter.endInterval("Save", interval) }
        do {
            let item = try await LibraryStore.$expectedGeneration.withValue(libraryGeneration) { try await body(store) }
            (state, libraryIndex) = await store.indexedSnapshot()
            librarySaved()
            Perf.mark("Saved")
            return .saved(item)
        } catch {
            (state, libraryIndex) = await store.indexedSnapshot()
            log.error("save failed: \(String(describing: type(of: error)), privacy: .public)")
            return .failed(Self.message(for: error))
        }
    }

    private static func message(for error: any Error) -> String {
        if case StoreError.placement = error {
            return String(localized: "这个位置现在放不下，请换个位置再确认。")
        }
        if case StoreError.locked = error {
            return String(localized: "这件家具已锁定。先解锁，再移动、收纳或删除。")
        }
        if (error as? StoreError)?.isOutOfSpace == true { return outOfSpaceMessage }
        return String(localized: "没能保存。房间和已有照片都保持原样，可以重试。")
    }

    // MARK: Reading originals

    func originalURL(photoId: String) async -> URL? {
        await displayFiles(photoId: photoId)?.original
    }

    func thumbnailURL(photoId: String) async -> URL? {
        await displayFiles(photoId: photoId)?.thumbnail
    }

    private func displayFiles(photoId: String) async -> (original: URL, thumbnail: URL)? {
        guard let files = await store?.displayFiles(photoId: photoId) else { return nil }
        if let repair = files.unsavedRepair {
            unsavedPhotoRepairs[photoId] = repair
        } else if files.metadataChanged {
            unsavedPhotoRepairs[photoId] = nil
            await republish()
        }
        return (files.original, files.thumbnail)
    }

    func verifyOriginal(photoId: String) async -> Bool? {
        guard let store else { return nil }
        return try? await store.verifyOriginal(photoId: photoId)
    }

    struct IntegritySummary: Equatable {
        var furniture: Int
        var photos: Int
        var verifiedOriginals: Int
        var problems: Int
    }

    func checkIntegrity() async -> IntegritySummary? {
        guard let store else { return nil }
        let report = await store.integrityReport()
        var verified = 0
        for photo in state.photos where (try? await store.verifyOriginal(photoId: photo.photoId)) == true {
            verified += 1
        }
        let problems = (report.isClean ? 0 : 1) + (state.photos.count - verified)
        return IntegritySummary(furniture: furnitureCount, photos: state.photos.count, verifiedOriginals: verified, problems: problems)
    }
}

/// Everything about one photo the user is deciding on. Nothing here is persisted until they confirm.
@Observable
final class ImportSession: Identifiable {
    let id = UUID()
    let draft: ImportDraft
    let generation: UUID
    let preview: UIImage?
    let alreadyIn: [PhotoFurniture]
    /// The stored record when these exact bytes are already in the library.
    let existingPhoto: PhotoRecord?
    var review = CandidateReview()
    var chosenModelID: String?
    var placement: Placement?
    var displayName = ""
    var saving = false
    /// Set when this photo came up from the sorting queue.
    var sorting: SortingPosition?
    /// Pieces already in the room that this photo looks like, closest first.
    var similar: [FurnitureMatch] = []
    /// The analyzer of the print `similar` was worked out with (nil until then), so the header
    /// names the model that really made the answer.
    var similarAnalyzer: String?
    /// While the photos it is compared with still need prints: how many are ready of how many.
    var preparing: (done: Int, total: Int)?
    /// True while the photo is being compared with the photos in furniture.
    var matchingSimilar = false
    /// Taken with the in-app camera and not in the photo library: discarding it loses it.
    var capturedOutsidePhotos = false
    /// What Photos did with a photo taken in the app; nil for any other photo. Unless Photos
    /// took it, the review says before any discard that it isn't saved.
    var photosSave: CameraCapture.LibrarySave?
    /// The capture held in the library folder for after a relaunch (`PendingCapture`), deleted
    /// when this review ends.
    var pendingCaptureSHA: String?
    /// Taken in an earlier run and reopened after a relaunch: no longer "just taken".
    var resumedCapture = false
    /// The only copy of a photo just taken is in memory: holding it for a relaunch failed, so
    /// quitting before it is saved loses it, and the review says so (audit E24-03).
    var captureOnlyInMemory: Bool { capturedOutsidePhotos && pendingCaptureSHA == nil && !resumedCapture }

    init(draft: ImportDraft, generation: UUID, preview: UIImage?, alreadyIn: [PhotoFurniture], existingPhoto: PhotoRecord? = nil) {
        self.draft = draft
        self.generation = generation
        self.preview = preview
        self.alreadyIn = alreadyIn
        self.existingPhoto = existingPhoto
    }
}
