import Foundation
import MeowverseCore
import os

/// Which piece already in the room a new photo looks like. Most photos after the first few are
/// of a piece that is already there, often a close-up the category classifier cannot name, so
/// the photo is compared with the photos each piece already holds (DINOv2 feature prints, or
/// Vision's when the model cannot load, on this device). The prints are a cache in Caches/: never backed up, dropped with the photo.
struct SimilarityState {
    var cache: FeaturePrintCache?
    var reviewTask: Task<Void, Never>?
    /// The background backfill (or a step queued behind it); see `refreshFeaturePrints`.
    var warmTask: Task<Void, Never>?
    /// The backfill itself, the one a newer backfill replaces.
    var backfillTask: Task<Void, Never>?
    /// Which backfill is current: a replaced run reports nothing more.
    var backfillRun = 0
    /// The current backfill's prints made of prints to make; nil while it only checks, or when none runs.
    var backfill: (done: Int, total: Int)?
    /// Photos the current backfill found with a usable print (subtracted from its progress).
    var backfillChecked = 0
    /// Since launch, for the bug report: prints made, and photos whose print was only checked.
    var printsMade = 0
    var printsChecked = 0
    /// The print the review made of the photo it shows, until that photo is saved or left.
    var reviewPrint: ReviewPrint?
    /// What the review's comparison came to. Not observed: set before `matchingSimilar` drops.
    var reviewOutcome: (session: UUID, outcome: SimilarityOutcome)?
    /// A real trigger came (an import, a rerun the user asked for): the next refresh attempts
    /// the prints given up this session again.
    var retriesFailedPrints = false
    /// Prints of the photos batch suggestions last looked at, for the review order.
    var batchPrints: [String: FeaturePrint] = [:]
    /// What the last run of the batch rule came to, for the bug report.
    var lastBatch: RecognitionDiagnostics.BatchSummary?

    struct ReviewPrint {
        let session: UUID
        let print: FeaturePrint
        /// The thumbnail bytes the print was made from; the cache checks them against the stored file.
        let thumbnail: Data
    }
}

extension AppModel {
    /// The backfill writes the cache after this many new prints, so closing the app loses little.
    static let backfillSaveEvery = 10
    /// Prints the backfill makes at once (the model itself runs one prediction at a time).
    static let backfillConcurrency = 2

    private static let similarityLog = Logger(subsystem: "app.meowverse", category: "similarity")

    /// The one place the app chooses how prints are made: the colour grid for UI tests that ask
    /// for it, otherwise DINOv2 (Vision when the model is missing or failed to load in this build).
    static func makeEmbedder(_ options: LaunchOptions,
                             onLoad: @escaping @Sendable (DinoPhotoEmbedder.LoadOutcome) -> Void) -> any PhotoEmbedding {
        assert(DinoPhotoEmbedder.analyzerName == KnownAnalyzer.dinoV2, "Core's name for the DINOv2 prints")
        let embedder: any PhotoEmbedding = options.colorGridSimilarity ? ColorGridEmbedder() : PhotoEmbedderFactory.make(onLoad: onLoad)
        #if DEBUG || DRILLS
        let args = ProcessInfo.processInfo.arguments
        if options.colorGridSimilarity, args.contains("-MeowverseFailPrints") { return FailingEmbedder(base: embedder, store: options.storeFolder) }
        if options.colorGridSimilarity, args.contains("-MeowverseUnlikePrints") { return UnlikeEmbedder() }
        #endif
        return options.slowPrints > 0 ? SlowEmbedder(base: embedder, seconds: options.slowPrints) : embedder
    }

    /// UI tests (`-MeowverseSlowPrints <s>`, DEBUG and drill builds only): every print takes
    /// this long, so a test can see the preparation phase. Same prints, same analyzer.
    nonisolated struct SlowEmbedder: PhotoEmbedding {
        let base: any PhotoEmbedding
        let seconds: Double
        var analyzer: String { base.analyzer }
        var revision: Int { base.revision }
        func featurePrint(imageData: Data) async throws -> FeaturePrint {
            try await Task.sleep(for: .seconds(seconds))
            return try await base.featurePrint(imageData: imageData)
        }
    }

    #if DEBUG || DRILLS
    /// UI tests (`-MeowverseFailPrints`, with the colour grid): no print can be made. Those an
    /// earlier launch cached are still read. How often one was asked for since launch is kept in
    /// Caches/Meowverse/print-attempts-Test-<store>, where the test can read it.
    nonisolated struct FailingEmbedder: PhotoEmbedding {
        let base: any PhotoEmbedding
        private let attempts: OSAllocatedUnfairLock<Int>
        private let file: URL?

        init(base: any PhotoEmbedding, store: String) {
            self.base = base
            attempts = OSAllocatedUnfairLock(initialState: 0)
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appending(path: "Meowverse")
            file = folder?.appending(path: "print-attempts-" + store)
            if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            if let file { try? Data("0".utf8).write(to: file, options: .atomic) }
        }

        var analyzer: String { base.analyzer }
        var revision: Int { base.revision }
        func featurePrint(imageData: Data) async throws -> FeaturePrint {
            let file = file
            attempts.withLock { count in
                count += 1
                if let file { try? Data("\(count)".utf8).write(to: file, options: .atomic) }
            }
            throw RecognitionError.undecodableImage
        }
    }

    /// UI tests (`-MeowverseUnlikePrints`, with the colour grid): no two different photos look alike.
    nonisolated struct UnlikeEmbedder: PhotoEmbedding {
        var analyzer: String { ColorGridEmbedder.analyzerName }
        var revision: Int { 2 }
        func featurePrint(imageData: Data) async throws -> FeaturePrint {
            let vector = PhotoIngest.sha256Hex(imageData).map { Float($0.hexDigitValue ?? 0) - 7.5 }
            let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return FeaturePrint(analyzer: analyzer, revision: revision, vector: vector.map { $0 / length })
        }
    }
    #endif

    static func initialEngine(of embedder: any PhotoEmbedding) -> RecognitionDiagnostics.Engine {
        switch embedder.analyzer {
        case KnownAnalyzer.dinoV2: return .dinoLoading
        case ColorGridEmbedder.analyzerName: return .testStandIn
        default:
            let bundled = Bundle.main.url(forResource: DinoPhotoEmbedder.resourceName, withExtension: "mlmodelc") != nil
            return bundled ? .visionAfterDinoFailed : .vision
        }
    }

    /// The DINOv2 model finished loading, or failed. On failure the app switches to Vision as a
    /// whole within this launch: embedder, a print cache opened for Vision's prints, and every
    /// comparison started again, so nothing made by Vision is dropped as "not DINOv2" or shown
    /// as DINOv2. Batch suggestions are off with Vision (`BatchSuggestionSettings.measuredOn`).
    func similarityModelLoaded(_ outcome: DinoPhotoEmbedder.LoadOutcome) {
        guard embedder.analyzer == KnownAnalyzer.dinoV2 else { return }
        switch outcome {
        case .loaded(let load):
            recognitionEngine = .dino(load)
        case .failed:
            Self.similarityLog.notice("switching feature prints to Vision for this launch")
            embedder = VisionPhotoEmbedder()
            recognitionEngine = .visionAfterDinoFailed
            similarity.reviewTask?.cancel()
            similarity.reviewPrint = nil
            similarity.batchPrints = [:]
            batch.suggestions.offers = []
            let old = similarity.warmTask
            similarity.backfillTask?.cancel()
            old?.cancel()
            // The reopened cache's first run starts once the old one has stopped and saved.
            similarity.warmTask = Task { await old?.value }
            guard similarity.cache != nil else { return }
            similarity.cache = nil
            openFeaturePrintCache()
            refreshFeaturePrints()
            if let session = importSession, comparesWithRoom(excluding: session.existingPhoto?.photoId) {
                startSimilarity(for: session)
            }
        }
    }

    func openFeaturePrintCache() {
        guard similarity.cache == nil,
              let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return }
        let folder = caches.appending(path: "Meowverse")
        // Builds before the binary file kept a JSON file; it is migrated once and removed.
        similarity.cache = FeaturePrintCache(fileURL: folder.appending(path: "featureprints-\(options.storeFolder).bin"),
                                             analyzer: embedder.analyzer, revision: embedder.revision,
                                             legacyFileURL: folder.appending(path: "featureprints-\(options.storeFolder).json"))
        // A reset test library also starts timing afresh, so a UI test can count the prints it caused.
        if options.resetStore { FeaturePrintTimingLog.shared.reset() }
    }

    /// A photo linked to both a board and a piece can still vote for the piece.
    func similarityReferences() -> [(instanceId: String, photoId: String)] {
        guard let catalog else { return [] }
        return state.allFurniture.filter { catalog.model(id: $0.modelId)?.category != .photoBoard }
            .flatMap { item in item.sources.map { (instanceId: item.instanceId, photoId: $0.photoId) } }
    }

    /// Every photo in furniture, boards included: batch suggestions count a board's photos as
    /// another label, so their prints are kept and warmed too.
    func filedPhotoIds() -> [String] {
        Array(Set(state.allFurniture.flatMap { $0.sources.map(\.photoId) })).sorted()
    }

    /// If the only examples are on a board, offer the board fallback without running Vision.
    func comparesWithRoom(excluding photoId: String?) -> Bool {
        similarity.cache != nil && state.allFurniture.contains { piece in
            piece.sources.contains { $0.photoId != photoId }
        }
    }

    /// The background backfill: every photo in furniture and boards and every photo waiting to
    /// be sorted gets a current print, `first` before the rest. It replaces a backfill already
    /// running (that one stops after its print in hand; what it made is kept), runs at low
    /// priority, saves every `backfillSaveEvery` prints so it resumes after the app is closed,
    /// and drops prints of photos no longer in the library. Asking for a thumbnail also repairs
    /// an old multi-image HEIF that was never opened, so its print is made from the repaired picture.
    ///
    /// While photos wait to be sorted and prints are being made, the batch bar shows the
    /// preparation (`batch.suggestions.recognition`) and sorting is not offered. When it is done
    /// and it made prints, the suggestions for the photos still waiting are worked out again,
    /// which refreshes again: so a print that failed is not planned again by itself
    /// (`FeaturePrintCache.refresh`), only on a real trigger (`retryFailedPrints`).
    func refreshFeaturePrints(first: [String] = []) {
        guard let cache = similarity.cache else { return }
        var seen = Set<String>()
        // The photos being compared too: kept in the library they are in none of the others,
        // and the refresh before the comparison would drop the prints just made for it.
        var compared: [String] = []
        if case .unfiled(let photoIds) = batch.suggestions.scope { compared = photoIds }
        let ids = (first + filedPhotoIds() + batch.suggestions.batchIds + pendingPhotoIds + compared)
            .filter { seen.insert($0).inserted }
        // Prints of photos still to be sorted are kept: suggestions and the review order use them.
        let kept = Set(ids).union(batch.pending)
        // Only the backfill is replaced; a step queued behind it (`keepReviewPrint`) still runs.
        let previous = similarity.warmTask
        similarity.backfillTask?.cancel()
        similarity.backfillRun += 1
        similarity.backfill = nil
        let run = similarity.backfillRun
        similarity.warmTask = Task(priority: .utility) {
            await previous?.value
            guard !Task.isCancelled else { return }
            await cache.retain(only: kept)
            await retryIfAsked(cache)
            let made = await refreshPrints(ids, in: cache, concurrency: Self.backfillConcurrency, saveEvery: Self.backfillSaveEvery,
                                           planned: { count in await self.backfillPlanned(count, of: ids.count, run: run) },
                                           progress: { done, total in await self.backfillProgressed(done, total, run: run) })
            // A replaced run leaves the rest to the one that replaced it.
            guard !Task.isCancelled, run == similarity.backfillRun else { return }
            backfillFinished(made: made)
        }
        similarity.backfillTask = similarity.warmTask
    }

    /// For a real trigger only, never for a refresh that follows a refresh: prints that failed
    /// this session are attempted once more.
    func retryFailedPrints() {
        similarity.retriesFailedPrints = true
    }

    private func retryIfAsked(_ cache: FeaturePrintCache) async {
        guard similarity.retriesFailedPrints else { return }
        similarity.retriesFailedPrints = false
        await cache.retryFailed()
    }

    /// Returns once no backfill or queued step is running: every print asked for is made or given up.
    func featurePrintsSettled() async {
        while let task = similarity.warmTask {
            await task.value
            if similarity.warmTask == task { return }
        }
    }

    /// The check is over: `count` of `total` photos need a print. Checking is silent; the bar
    /// appears only now, only when there is something to make, and counts only those prints.
    private func backfillPlanned(_ count: Int, of total: Int, run: Int) {
        guard run == similarity.backfillRun, count > 0 else { return }
        similarity.backfillChecked = total - count
        similarity.backfill = (0, count)
        // Photos waiting to be sorted are compared only once the prints are made: say so.
        if batch.suggestions.recognition?.phase == .recognising || !pendingPhotoIds.isEmpty {
            batch.suggestions.recognition = BatchProgress(phase: .recognising, completed: 0, total: count)
        }
    }

    /// `done` of `total` photos settled, checks included; shown as prints made of prints to make.
    private func backfillProgressed(_ done: Int, _ total: Int, run: Int) {
        guard run == similarity.backfillRun, let toMake = similarity.backfill?.total else { return }
        let made = min(max(0, done - similarity.backfillChecked), toMake)
        similarity.backfill = (made, toMake)
        if batch.suggestions.recognition?.phase == .recognising {
            batch.suggestions.recognition = BatchProgress(phase: .recognising, completed: made, total: toMake)
        }
    }

    private func backfillFinished(made: Int) {
        similarity.backfill = nil
        let wasPreparing = batch.suggestions.recognition?.phase == .recognising
        batch.suggestions.recognition = nil
        guard batchSuggestionsAvailable, wasPreparing || made > 0 else {
            refreshReviewOrder()
            return
        }
        // Photos still waiting from an earlier launch or batch get their offers too.
        if batch.suggestions.scope == nil, !pendingPhotoIds.isEmpty {
            batch.suggestions.scope = .unfiled(pendingPhotoIds)
        }
        recomputeSuggestions()
    }

    /// After a clear or a restore no old print may survive, even one that a reused photoId would match.
    func forgetFeaturePrints() async {
        similarity.reviewPrint = nil
        similarity.backfillTask?.cancel()
        similarity.warmTask?.cancel()
        await similarity.warmTask?.value
        similarity.warmTask = nil
        similarity.backfill = nil
        if let cache = similarity.cache {
            await cache.retain(only: [])
            try? await cache.save()
        }
        refreshFeaturePrints()
    }

    @discardableResult
    func refreshPrints(_ photoIds: [String], in cache: FeaturePrintCache, concurrency: Int = 1, saveEvery: Int = 0,
                       planned: (@Sendable (Int) async -> Void)? = nil,
                       progress: (@Sendable (Int, Int) async -> Void)? = nil) async -> Int {
        let embedder = self.embedder
        let made = await cache.refresh(photoIds, input: { [weak self] photoId in await self?.thumbnailURL(photoId: photoId) },
                                       embed: { data in try await Self.offMainAsync { try await FeaturePrintTimingLog.shared.timed(embedder, imageData: data) } },
                                       concurrency: concurrency, saveEvery: saveEvery, planned: planned, progress: progress)
        similarity.printsMade += made
        similarity.printsChecked += max(0, photoIds.count - made)
        return made
    }

    /// Fills `session.similar` with up to three pieces (`SimilarFurniture.suggest`). The review
    /// shows them only once they are all known, so rows do not jump under the user's finger.
    ///
    /// The photo's own print comes first, then the prints of the pieces' photos, made here ahead
    /// of the background backfill. "No look-alike" is only said once every one of them has been
    /// compared (`SimilarityOutcome`); until then the review says recognition is preparing, with a count.
    func startSimilarity(for session: ImportSession) {
        let references = similarityReferences().filter { $0.photoId != session.existingPhoto?.photoId }
        guard !references.isEmpty, let cache = similarity.cache else {
            similarity.reviewOutcome = (session.id, references.isEmpty ? .nothingToCompare : .failed)
            return
        }
        similarity.reviewOutcome = nil
        session.matchingSimilar = true
        session.preparing = nil
        let embedder = self.embedder, thumbnail = session.draft.thumbnailJPEG
        // A stored photo (one being sorted) uses its own cached print, the one the batch made
        // or is making, so it is never printed twice.
        let stored = session.existingPhoto?.photoId
        let referenceIds = Array(Set(references.map(\.photoId))).sorted()
        similarity.reviewTask?.cancel()
        similarity.reviewTask = Task {
            await retryIfAsked(cache)
            let made = await reviewQueryPrint(stored: stored, thumbnail: thumbnail, embedder: embedder, cache: cache)
            guard !Task.isCancelled else { return }
            await refreshPrints(referenceIds, in: cache, planned: { count in
                await MainActor.run { if count > 0 { session.preparing = (referenceIds.count - count, referenceIds.count) } }
            }, progress: { done, total in
                await MainActor.run { if session.preparing != nil { session.preparing = (done, total) } }
            })
            var prints: [FurniturePhotoPrint] = []
            for reference in references {
                if let print = await cache.print(for: reference.photoId) {
                    prints.append(FurniturePhotoPrint(instanceId: reference.instanceId, photoId: reference.photoId, print: print))
                }
            }
            guard !Task.isCancelled, importSession === session else { return }
            if let made, stored == nil { similarity.reviewPrint = .init(session: session.id, print: made, thumbnail: thumbnail) }
            session.similar = made.map { SimilarFurniture.suggest($0, against: prints) } ?? []
            session.similarAnalyzer = made?.analyzer
            session.preparing = nil
            similarity.reviewOutcome = (session.id, SimilarityOutcome(query: made, against: prints, expected: Set(referenceIds)))
            session.matchingSimilar = false
        }
    }

    /// Without a recorded outcome nothing was established, which reads as a failure.
    func similarityOutcome(of session: ImportSession) -> SimilarityOutcome {
        guard let last = similarity.reviewOutcome, last.session == session.id else { return .failed }
        return last.outcome
    }

    private func reviewQueryPrint(stored: String?, thumbnail: Data, embedder: any PhotoEmbedding,
                                  cache: FeaturePrintCache) async -> FeaturePrint? {
        guard let stored else { return try? await FeaturePrintTimingLog.shared.timed(embedder, imageData: thumbnail) }
        await refreshPrints([stored], in: cache)
        return await cache.print(for: stored)
    }

    /// Called once the reviewed photo is saved into a piece: its review print becomes the photo's
    /// cache entry, so the next backfill checks it instead of making it again. Queued behind the
    /// running warmup, whose pruning would otherwise drop it; a clear or restore cancels it.
    func keepReviewPrint(of session: ImportSession) {
        guard let kept = similarity.reviewPrint, kept.session == session.id, let cache = similarity.cache else { return }
        similarity.reviewPrint = nil
        let photoId = session.existingPhoto?.photoId ?? state.photos.first { $0.isSamePhoto(as: session.draft) }?.photoId
        // Only photos that vote: a photo on a board alone would be pruned again at once.
        guard let photoId, similarityReferences().contains(where: { $0.photoId == photoId }) else { return }
        let previous = similarity.warmTask
        similarity.warmTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await cache.adopt(kept.print, madeFrom: kept.thumbnail, for: photoId)
        }
    }

    /// The bug report's recognition lines: counts and distances only.
    func recognitionDiagnostics() async -> RecognitionDiagnostics {
        let filed = Array(Set(similarityReferences().map(\.photoId)))
        let ready = await similarity.cache?.readyCount(of: filed) ?? 0
        return RecognitionDiagnostics(engine: recognitionEngine, filedReady: ready, filedTotal: filed.count,
                                      backfill: similarity.backfill, lastBatch: similarity.lastBatch,
                                      printsMade: similarity.printsMade, printsChecked: similarity.printsChecked)
    }
}
