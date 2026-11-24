import Foundation
import MeowverseCore

/// "建议归位" for photos imported together: their prints are made up front (in the foreground,
/// a few at a time, reusing the cache), then the strict rule (`BatchSuggestionSettings`) offers
/// the photos that clearly belong to a piece already holding photos. Offers wait for the user
/// on a confirmation page; nothing is filed silently. The review meanwhile asks about the most
/// representative photos first. Free for everyone (owner, 2026-11-17).
///
/// The interface binds to: `batchProgress`, `suggestionGroups`, `suggestedCount`,
/// `acceptSuggestions(_:declining:)`, `declineSuggestions(_:)`, `undoLastAcceptance()`,
/// `suggestForPending()`, `suggestForPhotoBoards()`, `sortingQueue`, `representativeRound`,
/// `batch.suggestions.representativeOrderOn`.
struct SuggestionState {
    /// The prints of a batch (or of a re-run's photos) being made; `done` once they all are.
    var recognition: BatchProgress?
    /// The photos of the last import, in the order they were picked.
    var batchIds: [String] = []
    /// Which photos the current offers are about; nil = no suggestions running.
    var scope: SuggestionScope?
    /// The offers as last computed. Read `currentOffers`: it drops anything the user has
    /// filed, moved or declined since.
    var offers: [BatchSuggestion] = []
    /// Photos the user unticked or declined: never offered again. Kept with the sorting queue.
    var declined: Set<String> = []
    /// The last confirmed page, so it can be taken back in one step.
    var lastAcceptance: LibraryStore.SuggestionReceipt?
    /// Ask about the most representative photos first (default on). Applies only to batches of
    /// at least `BatchSuggestionSettings.representativeMinimumBatch` photos once their prints are ready.
    var representativeOrderOn = true
    /// Photos of this batch already decided one by one while the representative order applied.
    var representativesAsked = 0
    /// The sorting queue with representatives first (see `sortingQueue`).
    var reviewOrder: [String] = []
    /// The last run lacked a print of a photo it was to compare, so no offer doesn't mean none.
    var unfinished = false
    /// True while offers are being computed.
    var computing = false
    /// The library revision the last run started from.
    var seenRevision: Int?

    var printTask: Task<Void, Never>?
    var suggestTask: Task<Void, Never>?
    var runID: UUID?
    var token: UUID?
    /// True while the user sorts photos they chose themselves (library selection): their order wins.
    var sortingInChosenOrder = false
    /// Where the representative round of the last batch is (see `RoundStage`).
    var roundStage = RoundStage.none
    /// Representatives in this round, fixed when it is introduced: at most `representativeRound`,
    /// fewer when fewer photos can be chosen.
    var roundTotal = 0
    /// The representatives still to ask about, in order, as `refreshReviewOrder` last chose them.
    var roundPicks: [String] = []
}

/// The representative round of a big batch: introduced (RepresentativeRoundIntro), running in
/// the review (the strip counts it), ending (RepresentativeRoundEnd, or a passing line when
/// nothing can be suggested), then over for this batch.
enum RoundStage: Equatable {
    case none, intro, running, end, finished
}

/// How far a batch is: storing the picked photos, then making their prints.
struct BatchProgress: Equatable {
    enum Phase: Equatable { case importing, recognising, done }
    var phase: Phase
    var completed: Int
    var total: Int

    /// A batch's photos are being checked for prints: sorting waits, but no bar is shown yet.
    /// The bar appears only if prints have to be made, counting those (`backfillPlanned`).
    static let checking = BatchProgress(phase: .recognising, completed: 0, total: 0)

    /// Whether a bar shows it: only while prints are being made.
    var shown: Bool { phase != .recognising || total > 0 }
}

extension AppModel {
    /// At most this many prints are made at once for a batch (the warmup may run beside it).
    static let batchPrintConcurrency = 3

    // MARK: Progress

    /// nil when no batch is being imported or recognised.
    var batchProgress: BatchProgress? {
        if let stored = batch.progress { return BatchProgress(phase: .importing, completed: stored.shown, total: stored.total) }
        return batch.suggestions.recognition
    }

    /// Stops making the batch's prints. Prints already made are kept; suggestions use them.
    func cancelBatchRecognition() {
        batch.suggestions.printTask?.cancel()
        batch.suggestions.printTask = nil
        batch.suggestions.runID = nil
        batch.suggestions.recognition = nil
        recomputeSuggestions()
    }

    /// Hides a finished progress value.
    func dismissBatchProgress() {
        if batch.suggestions.recognition?.phase == .done { batch.suggestions.recognition = nil }
    }

    // MARK: Entry points

    /// Batch suggestions and the representative order run only on prints their numbers were
    /// measured on (DINOv2). With the Vision fallback both are off; the review's own
    /// look-alike rows still work.
    var batchSuggestionsAvailable: Bool { BatchSuggestionSettings.applies(to: embedder.analyzer) }

    /// Called when a batch has been stored: its prints (and any filed photo's still missing) are
    /// made while the batch bar shows "识别中", then suggestions run over it. Sorting is offered
    /// only after that (owner, round 8), with Vision prints too, which have no suggestions.
    func batchStored(_ ids: [String]) {
        retryFailedPrints()
        guard batchSuggestionsAvailable else {
            guard similarity.cache != nil, !ids.isEmpty else { return }
            batch.suggestions.recognition = .checking
            refreshFeaturePrints(first: ids)
            return
        }
        batch.suggestions.batchIds = ids
        batch.suggestions.representativesAsked = 0
        batch.suggestions.roundStage = .none
        batch.suggestions.roundTotal = 0
        batch.suggestions.lastAcceptance = nil
        recognise(ids, for: .unfiled(ids))
    }

    /// Offers for every photo waiting in 待整理.
    func suggestForPending() {
        suggestForUnfiled(pendingPhotoIds)
    }

    /// Offers for these photos, those of them in no furniture (the library's 未放进家具 list).
    func suggestForUnfiled(_ ids: [String]) {
        guard batchSuggestionsAvailable else { return }
        recognise(ids, for: .unfiled(ids))
    }

    /// True while prints are being made or offers worked out: the count may still change.
    var suggestionsComparing: Bool {
        batch.suggestions.recognition?.phase == .recognising || batch.suggestions.printTask != nil || batch.suggestions.computing
    }

    /// Returns once the prints and the offers of the running entry point are done (or stopped).
    func suggestionsSettled() async {
        while true {
            if batch.suggestions.recognition?.phase == .recognising, similarity.warmTask != nil {
                await featurePrintsSettled()
                // The backfill's end clears the phase and starts the offers; a cancelled one may not.
                if batch.suggestions.recognition?.phase == .recognising { return }
                continue
            }
            if let prints = batch.suggestions.printTask {
                await prints.value
                if batch.suggestions.printTask == prints { return }   // cancelled and not cleared
                continue
            }
            guard batch.suggestions.computing, let offers = batch.suggestions.suggestTask else { return }
            await offers.value
            // A run whose result was dropped (newer run, other library) leaves `computing` as it was.
            if batch.suggestions.suggestTask == offers { return }
        }
    }

    /// Offers for photos on a photo board (and in no other piece).
    func suggestForPhotoBoards() {
        guard batchSuggestionsAvailable, let catalog else { return }
        let ids = BatchSuggestions.candidates(.photoBoards, in: state, catalog: catalog).map(\.photoId)
        recognise(ids, for: .photoBoards)
    }

    /// Makes the prints of `ids` first in the backfill, which also makes every filed photo's
    /// print still missing; the bar counts all of them. When the backfill is done it computes
    /// the offers for `scope` (`backfillFinished`).
    private func recognise(_ ids: [String], for scope: SuggestionScope) {
        batch.suggestions.printTask?.cancel()
        batch.suggestions.printTask = nil
        batch.suggestions.scope = scope
        batch.suggestions.offers = []
        batch.suggestions.unfinished = false
        guard similarity.cache != nil, !ids.isEmpty else {
            batch.suggestions.recognition = nil
            recomputeSuggestions()
            return
        }
        batch.suggestions.runID = UUID()
        batch.suggestions.recognition = .checking
        refreshFeaturePrints(first: ids)
    }

    // MARK: Offers

    /// The offers still true of the home: not filed, moved or declined since, and not the photo
    /// the review is showing.
    var currentOffers: [BatchSuggestion] {
        guard let catalog else { return [] }
        let reviewing = importSession?.sorting?.photoId ?? importSession?.existingPhoto?.photoId
        return batch.suggestions.offers.filter {
            !batch.suggestions.declined.contains($0.photoId) && $0.photoId != reviewing
                && BatchSuggestions.isCurrent($0, in: state, catalog: catalog)
        }
    }

    /// The confirmation page: offers by piece, the piece with the most first.
    var suggestionGroups: [SuggestionGroup] { BatchSuggestions.byPiece(currentOffers) }

    var suggestedCount: Int { currentOffers.count }

    /// No offers, and the comparison didn't finish: "none" must not be said.
    var suggestionsUnfinished: Bool {
        batch.suggestions.unfinished && !suggestionsComparing && suggestedCount == 0
    }

    /// Runs the rule again over the current scope: after the prints are made, after every filing
    /// by hand, and after every confirmed or undone page. A result that arrives after a newer run
    /// started, or after the library was switched, is dropped.
    func recomputeSuggestions() {
        batch.suggestions.suggestTask?.cancel()
        guard batchSuggestionsAvailable, let scope = batch.suggestions.scope, let cache = similarity.cache, let catalog,
              batch.suggestions.recognition?.phase != .recognising else {
            batch.suggestions.computing = false
            refreshReviewOrder()
            return
        }
        let token = UUID(), generation = libraryGeneration, state = self.state
        batch.suggestions.token = token
        batch.suggestions.seenRevision = state.revision
        batch.suggestions.computing = true
        let candidates = BatchSuggestions.candidates(scope, in: state, catalog: catalog)
        let (links, boards) = BatchSuggestions.links(in: state, catalog: catalog)
        refreshFeaturePrints()
        batch.suggestions.suggestTask = Task {
            // Every filed photo's print must be there: a missing one could let the margin pass.
            await featurePrintsSettled()
            guard !Task.isCancelled else { return }
            var references: [FurniturePhotoPrint] = []
            for link in links {
                if let print = await cache.print(for: link.photoId) {
                    references.append(FurniturePhotoPrint(instanceId: link.instanceId, photoId: link.photoId, print: print))
                }
            }
            var prints: [String: FeaturePrint] = [:]
            for candidate in candidates {
                if let print = await cache.print(for: candidate.photoId) { prints[candidate.photoId] = print }
            }
            let declined = batch.suggestions.declined, candidatePrints = prints, filed = references
            let rule = suggestionRule
            // With nothing to compare, or nothing to compare with, none is simply true.
            let asked = candidates.filter { !declined.contains($0.photoId) }
            let allPrinted = references.count == links.count && asked.allSatisfy { prints[$0.photoId] != nil }
            let unfinished = !asked.isEmpty && !links.isEmpty && !allPrinted
            let result = try? await Self.offMain {
                (BatchSuggestions.offers(for: candidates, prints: candidatePrints, references: filed, boards: boards,
                                         declined: declined, rule: rule),
                 RecognitionDiagnostics.nearestDistances(of: candidatePrints, to: filed))
            }
            let (found, nearest) = result ?? ([], [])
            guard !Task.isCancelled, batch.suggestions.token == token, generation == libraryGeneration else { return }
            similarity.lastBatch = .init(compared: candidatePrints.count, offers: found.count, nearest: nearest)
            batch.suggestions.offers = found
            batch.suggestions.unfinished = unfinished || result == nil
            similarity.batchPrints = prints
            batch.suggestions.computing = false
            batch.suggestions.suggestTask = nil
            refreshReviewOrder()
        }
    }

    /// Files the selected offers in one step and never offers `unticked` again. Offers that no
    /// longer hold (the photo was filed or moved by hand meanwhile, or the rule now names
    /// another piece than the page showed) are left alone.
    func acceptSuggestions(_ selected: Set<SuggestionChoice>, declining unticked: Set<String> = []) async -> PhotoSaveFailure? {
        if !unticked.isEmpty { declineSuggestions(unticked) }
        // Confirm against offers worked out from the home as it is now.
        await batch.suggestions.suggestTask?.value
        let chosen = BatchSuggestions.confirmed(selected, among: currentOffers)
        guard !chosen.isEmpty else { return nil }
        let analyzer = embedder.analyzer, generation = libraryGeneration
        let result = await perform { try await $0.fileSuggestions(chosen, printsBy: analyzer, generation: generation) }
        switch result {
        case .success(let receipt):
            if !receipt.filed.isEmpty { batch.suggestions.lastAcceptance = receipt }
            suggestionsChangedQueue()
            return nil
        case .failure(let failure):
            return failure
        }
    }

    /// Never offers these photos again (they stay to be sorted by hand).
    func declineSuggestions(_ photoIds: Set<String>) {
        guard !photoIds.isEmpty else { return }
        batch.suggestions.declined.formUnion(photoIds)
        batch.suggestions.offers.removeAll { photoIds.contains($0.photoId) }
        saveDeclined()
        refreshReviewOrder()
    }

    /// Takes the last confirmed page back: the photos return to where they were, unless the
    /// user has moved them by hand since.
    func undoLastAcceptance() async -> PhotoSaveFailure? {
        guard let receipt = batch.suggestions.lastAcceptance else { return nil }
        let result = await perform { try await $0.undoSuggestions(receipt) }
        switch result {
        case .success:
            batch.suggestions.lastAcceptance = nil
            suggestionsChangedQueue()
            return nil
        case .failure(let failure):
            return failure
        }
    }

    var canUndoLastAcceptance: Bool { batch.suggestions.lastAcceptance != nil }

    /// Photos left the queue (or came back) other than one by one: the sorting count follows.
    /// The save itself already started a new run of the rule.
    private func suggestionsChangedQueue() {
        if batch.sortingTotal != nil {
            // The photo under review is still pending, so it is counted.
            batch.sortingTotal = batch.sortingDone + pendingPhotoIds.count
        }
        refreshReviewOrder()
    }

    /// A photo was decided one by one in the review. The next photo is chosen again at once;
    /// the save itself already started a new run of the rule (`librarySaved`).
    func photoSortedByHand(_ photoId: String) {
        if batch.suggestions.roundStage == .running, batch.suggestions.batchIds.contains(photoId) {
            batch.suggestions.representativesAsked += 1
        }
        refreshReviewOrder()
    }

    /// Called after every save: any change of links can change what the rule says (an unlinked
    /// photo no longer votes; a new one may block the margin), so offers are worked out again.
    func librarySaved() {
        guard batch.suggestions.scope != nil, batch.progress == nil,
              state.revision != batch.suggestions.seenRevision else { return }
        batch.suggestions.seenRevision = state.revision
        recomputeSuggestions()
    }

    // MARK: Review order

    /// How many photos of the last batch are asked about in representative order: 10, or 0
    /// (the order they were picked in) for a batch under 12.
    var representativeRound: Int {
        let size = BatchSuggestionSettings.representativeRound(forBatchOf: batch.suggestions.batchIds.count)
        return size > 0 ? (options.representativeRound ?? size) : 0
    }

    /// The rule as it runs: `BatchSuggestionSettings.rule`, with the distance cut a DEBUG UI test
    /// may set for the colour grid's scale.
    var suggestionRule: AutoFileRule {
        var rule = BatchSuggestionSettings.rule
        if let cut = options.suggestionDistances?.cut { rule.maximumDistance = cut }
        return rule
    }

    var neighbourhoodRadius: Float {
        options.suggestionDistances?.radius ?? BatchSuggestionSettings.neighbourhoodRadius
    }

    /// True while the review asks about representatives: switched on, a large enough batch,
    /// its prints ready, and the round not used up.
    var representativeOrderApplies: Bool {
        let s = batch.suggestions
        return batchSuggestionsAvailable && s.representativeOrderOn && representativeRound > 0 && s.roundStage != .finished && s.recognition?.phase != .recognising
            && s.printTask == nil && !similarity.batchPrints.isEmpty && s.representativesAsked < representativeRound
            && !s.sortingInChosenOrder
    }

    /// The photos still to sort, in the order the review takes them.
    var sortingQueue: [String] {
        let pending = pendingPhotoIds
        let set = Set(pending)
        let ordered = batch.suggestions.reviewOrder.filter { set.contains($0) }
        let placed = Set(ordered)
        return ordered + pending.filter { !placed.contains($0) }
    }

    /// The photo the review opens next: the first in the queue that is not waiting on the
    /// confirmation page, so the count offered there does not change because of which photo
    /// happens to be open. When every photo left is offered, the first of them.
    var nextToSort: String? {
        let queue = sortingQueue
        // An order the user chose in the library is kept as it is.
        if batch.suggestions.sortingInChosenOrder { return queue.first }
        let shown = importSession?.sorting?.photoId
        let offered = Set(batch.suggestions.offers.map(\.photoId)).subtracting(batch.suggestions.declined)
        return queue.first { $0 == shown || !offered.contains($0) } ?? queue.first
    }

    /// Recomputes `reviewOrder`. Representatives are chosen among the batch's photos that have
    /// a print; photos on the confirmation page or declined are not asked about first.
    func refreshReviewOrder() {
        let pending = pendingPhotoIds
        guard representativeOrderApplies else {
            batch.suggestions.reviewOrder = pending
            batch.suggestions.roundPicks = []
            return
        }
        let batchIds = Set(batch.suggestions.batchIds)
        let prints = similarity.batchPrints.filter { batchIds.contains($0.key) }
        var days: [String: String] = [:]
        for id in pending { if let day = photo(id)?.captureDate { days[id] = day } }
        let excluded = batch.suggestions.declined.union(currentOffers.map(\.photoId))
        let s = batch.suggestions
        let left = (s.roundStage == .none ? representativeRound : s.roundTotal) - s.representativesAsked
        let picks = RepresentativeOrder.picks(pending, prints: prints, days: days, excluded: excluded, count: left,
                                              radius: neighbourhoodRadius)
        let taken = Set(picks)
        batch.suggestions.roundPicks = picks
        batch.suggestions.reviewOrder = picks + pending.filter { !taken.contains($0) }
    }

    /// Switches the representative order on or off for the review.
    func setRepresentativeOrder(_ on: Bool) {
        batch.suggestions.representativeOrderOn = on
        refreshReviewOrder()
    }

    // MARK: The representative round

    /// Before the next photo of the review opens: introduces the round when it applies, or ends
    /// it once its photos are asked (or none is left to choose). Returns true when the round has
    /// ended and the next photo is opened once the offers are worked out.
    func advanceRepresentativeRound(open: @escaping () -> Void) -> Bool {
        let s = batch.suggestions
        switch s.roundStage {
        case .none where representativeOrderApplies:
            if s.roundPicks.isEmpty {
                batch.suggestions.roundStage = .finished
                refreshReviewOrder()
            } else {
                batch.suggestions.roundTotal = min(representativeRound - s.representativesAsked, s.roundPicks.count)
                batch.suggestions.roundStage = .intro
            }
            return false
        case .running where s.representativesAsked >= s.roundTotal || s.roundPicks.isEmpty:
            batch.suggestions.roundStage = .end
            importSession = nil
            Task {
                await suggestionsSettled()
                guard batch.suggestions.roundStage == .end, batch.sortingTotal != nil, importSession == nil else { return }
                if suggestedCount == 0 {
                    batch.suggestions.roundStage = .finished
                    let left = pendingPhotoIds.count
                    TransientNotice.show(suggestionsUnfinished ? RepresentativeRoundEnd.couldNotCompare(remaining: left)
                                         : RepresentativeRoundEnd.nothingToSuggest(remaining: left))
                }
                refreshReviewOrder()
                open()
            }
            return true
        default:
            return false
        }
    }

    /// "开始整理这 N 张".
    func startRepresentativeRound() {
        guard batch.suggestions.roundStage == .intro else { return }
        batch.suggestions.roundStage = .running
    }

    /// "不用，按原来的顺序整理": the batch is reviewed in the order it was picked, from its first photo.
    func skipRepresentativeRound() {
        batch.suggestions.roundStage = .finished
        setRepresentativeOrder(false)
        reopenAtQueueHead()
    }

    /// The round's end page was answered (either way): the review goes on in the picked order.
    func finishRepresentativeRound() {
        guard batch.suggestions.roundStage == .end else { return }
        batch.suggestions.roundStage = .finished
        refreshReviewOrder()
    }

    // MARK: Persistence of declines

    private var declinedKey: String { "import.declined.\(options.storeFolder)" }

    func loadDeclined() {
        batch.suggestions.declined = Set(UserDefaults.standard.stringArray(forKey: declinedKey) ?? [])
    }

    private func saveDeclined() {
        // Only photos still in the library are worth remembering.
        let kept = batch.suggestions.declined.filter { libraryIndex.photo(id: $0) != nil }
        batch.suggestions.declined = kept
        UserDefaults.standard.set(kept.sorted(), forKey: declinedKey)
    }

    /// After a clear or a restore: nothing of the old library's suggestions survives.
    // MARK: Undo for the notice bar

    /// The line for the notice after a confirmed page, nil when nothing was filed.
    func lastAcceptanceMessage() -> String? {
        guard let receipt = batch.suggestions.lastAcceptance, !receipt.filed.isEmpty else { return nil }
        var names: [String] = []
        for id in receipt.filed.map(\.instanceId) where !names.contains(id) { names.append(id) }
        let pieces = names.map { anyFurniture($0)?.shownName ?? "" }
        // Every photo came off a board: say they moved, not just that they were put in.
        let fromBoards = receipt.filed.allSatisfy { !$0.boardLinks.isEmpty }
        return FilingNoticeBar.filedMessage(photos: receipt.filed.count, pieces: pieces, fromBoards: fromBoards)
    }

    func resetSuggestions() {
        batch.suggestions.printTask?.cancel()
        batch.suggestions.suggestTask?.cancel()
        batch.suggestions = SuggestionState()
        similarity.batchPrints = [:]
        UserDefaults.standard.removeObject(forKey: declinedKey)
    }
}
