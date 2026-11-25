import MeowverseCore
import SwiftUI

/// Photo → furniture category → model → placement. Nothing is saved until the last step is confirmed.
struct ImportFlowView: View {
    @Environment(AppModel.self) private var model
    let session: ImportSession
    let onPlaced: () -> Void

    /// The flow is drawn over the room rather than presented modally: a modal presented while
    /// the system photo picker is still sliding away comes up without its own background.
    private func end(_ ending: ImportEnding) {
        model.endImport(session, ending)
    }

    /// `suggestions` carries the confirmation page's groups as they were when it opened.
    enum Step: Hashable { case model, placement, attach, suggestions([FilingSuggestionGroup]) }
    /// What "重试" repeats after a failed save.
    enum Pending: Equatable { case place, photoOnly, attach(String), skip }
    @State private var path: [Step] = []
    @State private var discardAsked = false
    @State private var saveFailure: String?
    @State private var pending = Pending.place
    @State private var filedNotice: FiledNotice?
    /// Once shown for this photo, the suggestion strip stays until the next photo (this view is
    /// made again for every photo), so the screen does not jump when the count reaches 0.
    @State private var stripShown = false

    var body: some View {
        NavigationStack(path: $path) {
            rootStep
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .model: modelStep
                    case .placement: placementStep
                    case .attach: attachStep
                    case .suggestions(let groups): suggestionsStep(groups)
                    }
                }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .sensoryFeedback(.selection, trigger: session.review.selectedCategory)
        .sensoryFeedback(.selection, trigger: session.chosenModelID)
        .sensoryFeedback(.error, trigger: saveFailure) { _, failure in failure != nil }
        .disabled(session.saving)
        .confirmationDialog("不添加这张照片？", isPresented: $discardAsked, titleVisibility: .visible) {
            Button("不添加", role: .destructive) { end(.cancelled) }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text(session.existingPhoto != nil ? "房间不会变化。这张照片仍然留在照片库里。"
                 : session.capturedOutsidePhotos
                    ? (session.resumedCapture ? "房间不会变化。上次拍的这张照片没有存进“照片”，不添加就不会留下。"
                       : "房间不会变化。这张刚拍的照片没有存进“照片”，不添加就不会留下。")
                 : "房间不会变化，这张照片也不会存进喵空间。相册里的原照片不受影响。")
        }
        .alert("没能保存", isPresented: failureBinding) {
            Button("重试") { retry() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(saveFailure ?? "")
        }
    }

    // MARK: The representative round around the review

    private var roundStage: RoundStage {
        session.sorting == nil ? .none : model.batch.suggestions.roundStage
    }

    @ViewBuilder
    private var rootStep: some View {
        switch roundStage {
        case .intro: roundIntro
        case .end where model.suggestedCount > 0: roundEnd
        default: reviewStep
        }
    }

    private var sortingTitle: String {
        guard let sorting = session.sorting else { return String(localized: "照片里的家具") }
        // The total follows photos filed from the confirmation page meanwhile.
        let total = max(model.batch.sortingTotal ?? sorting.total, sorting.index)
        return String(localized: "整理照片 \(sorting.index) / \(total)")
    }

    private var stopSortingItem: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("先到这里") { end(.cancelled) }
                .accessibilityHint("停止整理。没整理的照片留在照片库，之后可以接着整理。")
                .accessibilityIdentifier("stop-sorting")
        }
    }

    private var roundIntro: some View {
        let s = model.batch.suggestions
        return RepresentativeRoundIntro(picks: s.roundTotal, total: s.batchIds.count, previews: Array(s.roundPicks.prefix(5)),
                                        start: { model.startRepresentativeRound() },
                                        skip: { model.skipRepresentativeRound() }) {
            ThumbnailView(photoId: $0)
        }
        // No "1 / 12" here: the pages around the round are not a photo of the queue.
        .navigationTitle(Text("整理照片"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { stopSortingItem }
    }

    private var roundEnd: some View {
        RepresentativeRoundEnd(suggestable: model.suggestedCount, remaining: model.pendingPhotoIds.count,
                               review: {
                                   model.finishRepresentativeRound()
                                   openSuggestions()
                               },
                               carryOn: { model.finishRepresentativeRound() })
            .navigationTitle(Text("整理照片"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { stopSortingItem }
    }

    // MARK: Suggested filing

    /// The strip at the top of the review while sorting: shown from the moment comparing starts.
    private var stripWanted: Bool {
        session.sorting != nil && model.batchSuggestionsAvailable && model.batch.suggestions.scope != nil
            && (roundStage == .running || model.suggestionsComparing || model.suggestedCount > 0)
    }

    private var stripMode: FilingSuggestionStrip.Mode {
        let s = model.batch.suggestions
        guard roundStage == .running else { return .suggestions }
        return .round(index: min(s.representativesAsked + 1, s.roundTotal), total: s.roundTotal)
    }

    private func openSuggestions() {
        let groups = model.filingGroups()
        guard !groups.isEmpty else { return }
        path.append(.suggestions(groups))
    }

    private func suggestionsStep(_ groups: [FilingSuggestionGroup]) -> some View {
        SuggestionReviewPage(groups: groups) { filed in
            if case .suggestions = path.last { path.removeLast() }
            if let filed { filedNotice = filed }
        }
    }

    /// The progress of the prints, while a photo opened by hand waits for them. Preparing
    /// recognition cannot be skipped (owner, round 8), so there is no 停止.
    @ViewBuilder
    private var recognitionBar: some View {
        if session.sorting != nil, let progress = model.batchProgress, progress.phase == .recognising, progress.shown {
            BatchProgressBar(phase: .recognizing, done: progress.completed, total: progress.total)
        }
    }

    // MARK: Step 1 — what is in the photo

    /// For a photo taken in the app that is not in the library yet. Only a refusal is about
    /// permission. `resumed`: taken before the app last stopped, so not "just taken".
    private static func unsavedLine(_ save: CameraCapture.LibrarySave, resumed: Bool) -> LocalizedStringKey? {
        switch save {
        case .saved: nil
        case .notWanted where resumed: "上次拍的这张照片还没有存进喵空间，也不会存进“照片”。放进家具或选“只存照片，不添家具”后才会保存。"
        case .notWanted: "这张刚拍的照片还没有存进喵空间，也不会存进“照片”。放进家具或选“只存照片，不添家具”后才会保存。"
        case .refused: "这张照片没有存进“照片”，也还没有存进喵空间。放进家具或选“只存照片，不添家具”后才会保存。可以在系统设置里允许喵空间添加照片。"
        case .failed: "“照片”没能保存这张照片，可能是储存空间不够。它也还没有存进喵空间。放进家具或选“只存照片，不添家具”后才会保存。"
        }
    }

    private var reviewStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Shown before anything is stored: the photo is only in memory until the user
                // puts it in furniture or stores it, so the line must not call it saved.
                // Not for a photo the library already has: that one is saved.
                if session.existingPhoto == nil, let save = session.photosSave, let line = Self.unsavedLine(save, resumed: session.resumedCapture) {
                    Label(line, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(Color.subtle)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(save.saveFailed ? "capture-not-in-photos" : "capture-not-saved-yet")
                }
                // Holding it for a relaunch failed (audit E24-03): this review is its only copy.
                if session.existingPhoto == nil, session.captureOnlyInMemory {
                    Label("这张照片没能暂存在这台设备上，现在退出喵空间它就会丢失。放进家具或选“只存照片，不添家具”就会保存。",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Color.subtle)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("capture-not-held")
                }
                photoHeader
                if !session.alreadyIn.isEmpty {
                    duplicateNotice
                } else if session.existingPhoto != nil, session.sorting == nil {
                    storedNotice
                }
                if canReconnectOriginal {
                    Button(String(localized: "重新关联相册原图", table: "BatchImport")) { storePhotoOnly() }
                        .accessibilityIdentifier("relink-photo")
                }
                suggestionSection
                // Second, before the long category grid: most photos after the first few belong to a
                // piece that is already in the room (owner request, 2026-11-12).
                otherWaysSection
                manualSection
                if session.sorting != nil {
                    Button("留在照片库，看下一张") { end(.keptInLibrary) }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("keep-in-library")
                } else {
                    Button("不添加这张照片", role: .destructive) { discardAsked = true }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("reject-photo")
                }
            }
            .padding()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if stripShown {
                FilingSuggestionStrip(mode: stripMode, count: model.suggestedCount, comparing: model.suggestionsComparing,
                                      unfinished: model.suggestionsUnfinished,
                                      cautionShownNearby: recognitionFootnoteShown, open: openSuggestions)
                    .background(RoomPaper.leaf.opacity(0.94))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                SuggestedFilingNotice(notice: $filedNotice)
                recognitionBar
                primaryButton(String(localized: "下一步：选款式"), enabled: session.review.selectedCategory != nil) {
                    if session.chosenModelID == nil || chosenCategoryChanged {
                        session.chosenModelID = modelsInCategory.first?.id
                    }
                    path.append(.model)
                }
                .accessibilityIdentifier("next-model")
            }
        }
        .onChange(of: stripWanted, initial: true) { _, wanted in
            if wanted { stripShown = true }
        }
        .task {
            // After a relaunch the offers of the queue are worked out again (declines are kept).
            if session.sorting != nil, model.batch.suggestions.scope == nil { model.suggestForPending() }
        }
        .memoryPage(.workshop)
        .navigationTitle(sortingTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if session.sorting != nil {
                    Button("先到这里") { end(.cancelled) }
                        .accessibilityHint("停止整理。没整理的照片留在照片库，之后可以接着整理。")
                        .accessibilityIdentifier("stop-sorting")
                } else {
                    Button("取消") { discardAsked = true }.accessibilityIdentifier("cancel-import")
                }
            }
            if session.sorting != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "跳过", table: "BatchImport")) { skipPhoto() }
                        .accessibilityLabel(String(localized: "跳过这张照片", table: "BatchImport"))
                        .accessibilityHint(skipExplanation)
                        .accessibilityIdentifier("skip-batch-photo")
                }
            }
        }
    }

    /// The record as it is now for a stored photo; the file's day only for one not stored yet.
    private var captureLine: String {
        let stored = session.existingPhoto.map { model.photo($0.photoId) ?? $0 }
        let shown = session.draft.shownCaptureDay(stored: stored)
        return Wording.captureLine(day: shown.day, source: shown.source)
    }

    private var photoHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let preview = session.preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 250)
                    .memoryPhotoMount()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("你选的照片")
            }
            Label(captureLine, systemImage: "calendar")
                .font(.system(.subheadline, design: .serif, weight: .semibold))
                .foregroundStyle(RoomPaper.ink)
                .fixedSize(horizontal: false, vertical: true)
            if session.sorting != nil {
                Text(skipExplanation)
                    .font(.footnote)
                    .foregroundStyle(Color.subtle)
            }
        }
    }

    private var canReconnectOriginal: Bool {
        guard model.photoLibrary.isOn, session.draft.assetIdentifier != nil, let existing = session.existingPhoto else { return false }
        return session.draft.missingLibraryBinding != nil || (existing.assetIdentifier == nil && existing.cloudIdentifier == nil)
    }

    private var skipExplanation: String {
        if let photo = session.existingPhoto, model.batch.insertedRevisions[photo.photoId] == photo.revision {
            String(localized: "跳过后，这张照片不会留在 App 里。系统相册中的原图会保留。", table: "BatchImport")
        } else {
            String(localized: "这张照片已在照片库中，跳过会保留原有记录。", table: "BatchImport")
        }
    }

    private var duplicateNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("这张照片已经在「\(session.alreadyIn[0].shownName)」里", systemImage: "photo.on.rectangle.angled")
                .font(.subheadline.weight(.semibold))
            Text("可以去看那件家具，也可以用它再添一件。照片只保存一份。")
                .font(.subheadline)
                .foregroundStyle(Color.subtle)
            Button("查看那件家具") {
                end(.viewExisting(instanceId: session.alreadyIn[0].instanceId))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("view-existing-furniture")
            if !attachTargets.isEmpty {
                Button("放进另一件已有的家具") { path.append(.attach) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("attach-from-notice")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .memoryCard(.album)
    }

    /// The same bytes are in the library but not in any furniture yet.
    private var storedNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("这张照片已经在照片库里", systemImage: "photo.on.rectangle.angled")
                .font(.subheadline.weight(.semibold))
            Text(session.existingPhoto.map { model.sync.photosOnNewerPieces.contains($0.photoId) } ?? false
                 ? "它在一件来自更新版本的家具上，更新 App 后会显示那件家具。照片只保存一份。"
                 : "它还没放进家具。可以给它添一件新的，或放进已有的家具。照片只保存一份。")
                .font(.subheadline)
                .foregroundStyle(Color.subtle)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .memoryCard(.album)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stored-notice")
    }

    /// Furniture this photo is not part of yet: pieces in the room first, then those put away.
    private var attachTargets: [PhotoFurniture] {
        let linked = Set(session.alreadyIn.map(\.instanceId))
        let photoId = session.existingPhoto?.photoId
        return model.state.allFurniture.filter { item in
            !linked.contains(item.instanceId) && !item.sources.contains { $0.photoId == photoId }
        }
    }

    /// Keeping the photo does not have to mean a new piece of furniture.
    @ViewBuilder
    private var otherWaysSection: some View {
        let targets = attachTargets
        if !targets.isEmpty || session.existingPhoto == nil {
            VStack(alignment: .leading, spacing: 10) {
                Label("不添新家具", systemImage: "photo")
                    .font(.headline)
                if !targets.isEmpty {
                    actionRow(title: String(localized: "放进已有的家具"), detail: String(localized: "给那件家具多添一张照片"), symbol: "rectangle.badge.plus") {
                        path.append(.attach)
                    }
                    .accessibilityIdentifier("attach-existing")
                }
                if session.existingPhoto == nil {
                    actionRow(title: String(localized: "只存照片，不添家具"), detail: String(localized: "先存进照片库，以后再整理"), symbol: "tray.and.arrow.down", busy: session.saving && pending == .photoOnly) {
                        storePhotoOnly()
                    }
                    .accessibilityIdentifier("photo-only")
                }
            }
            .disabled(session.saving)
        }
    }

    private func actionRow(title: String, detail: String, symbol: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.footnote).foregroundStyle(Color.subtle)
                }
                Spacer()
                if busy {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.subtle)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .memoryCard(.workshop)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var suggestionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(recognitionHeader, systemImage: "iphone")
                .font(.headline)
                .accessibilityIdentifier("recognition-header")
            // One change from "working" to the answer: rows that attach on a tap must not
            // appear above, or push down, something the user is about to tap.
            if session.matchingSimilar {
                recognizingRow
            } else if case .idle = session.review.analysis {
                // Compared with the photos already in furniture (Vision's category guess was not
                // run): the likeliest pieces, then "未识别", which means the photo wall.
                let suggestions = similarTargets
                if let note = comparisonNote(anyShown: !suggestions.isEmpty) {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(Color.subtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(suggestions.enumerated()), id: \.element.item.instanceId) { index, target in
                    similarRow(target.item, match: target.match, index: index)
                }
                // Set apart from the look-alike rows so it is not tapped instead of one of them.
                unrecognisedRow(board: fallbackBoard)
                    .padding(.top, suggestions.isEmpty ? 0 : 8)
                if comparisonRanked {
                    Text("按和房间里已有照片的相像程度排列，在这台设备上完成，可能有误，以你的选择为准。")
                        .font(.footnote)
                        .foregroundStyle(Color.subtle)
                }
            } else {
                recognitionRows
            }
        }
    }

    /// What the comparison came to. A failure is never worded as "nothing looks like it", and
    /// look-alikes the photo is already in are not "nothing" either.
    private func comparisonNote(anyShown: Bool) -> LocalizedStringKey? {
        let outcome = model.similarityOutcome(of: session)
        switch outcome {
        case .nothingToCompare: return "还没有能用来比对的家具照片。"
        case .compared(complete: true): return session.similar.isEmpty ? "房间里没有和它相像的家具。" : nil
        case .compared, .failed:
            return anyShown ? "有些照片这次没能比对，可能还有更像的家具。"
                : "这次没能完成比对，不能确定有没有和它相像的家具。请在下面手动选择。"
        }
    }

    /// A ranking is claimed only for rows shown or a comparison that finished.
    private var comparisonRanked: Bool {
        !similarTargets.isEmpty || model.similarityOutcome(of: session) == .compared(complete: true)
    }

    /// 「本机识别」 with the model that produced what is shown: the look-alike rows name the
    /// analyzer of the prints they were compared with (DINOv2, or Apple Vision after a fallback);
    /// the category guess names its own. Plain while nothing has been produced yet.
    private var recognitionHeader: String {
        guard !session.matchingSimilar else { return String(localized: "本机识别") }
        switch session.review.analysis {
        case .idle: return Wording.recognitionHeader(analyzer: session.similarAnalyzer)
        case .finished(let result): return Wording.recognitionHeader(analyzer: result.analyzer)
        default: return String(localized: "本机识别")
        }
    }

    /// True while `suggestionSection` ends in its "可能有误，以你的选择为准" footnote.
    private var recognitionFootnoteShown: Bool {
        guard !session.matchingSimilar else { return false }
        switch session.review.analysis {
        case .idle: return comparisonRanked
        case .finished(let result): return !result.objects.isEmpty
        default: return false
        }
    }

    private func detailWithLocation(_ detail: String, for item: PhotoFurniture) -> String {
        guard let room = model.roomName(ofFurniture: item.instanceId) else { return String(localized: "\(detail) · 在收纳箱") }
        return model.hasSeveralRooms ? detail + " · " + room : detail
    }

    private var fallbackBoard: PhotoFurniture? {
        model.catalog.flatMap { FurnitureLibrary.photoBoard(for: attachTargets, inRoom: model.currentRoomId, state: model.state, catalog: $0) }
    }

    /// "未识别": a photo in which no furniture can be made out belongs on the photo wall. With no
    /// board yet, this starts placing one; it is added only once the user confirms it.
    private func unrecognisedRow(board: PhotoFurniture?) -> some View {
        return Button {
            if let board {
                attach(to: board.instanceId)
            } else {
                session.review.chooseManually(.photoBoard)
                session.chosenModelID = modelsInCategory.first?.id
                path.append(.model)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle")
                    .foregroundStyle(Color.subtle)
                    .frame(width: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("未识别").font(.body)
                    Text(board.map { detailWithLocation(String(localized: "放到「\($0.shownName)」"), for: $0) } ?? String(localized: "新挂一块照片板来放它"))
                        .font(.footnote)
                        .foregroundStyle(Color.subtle)
                }
                Spacer()
                if let board, session.saving, pending == .attach(board.instanceId) {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.subtle)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 48)
            // No filled card: a dashed outline in the folio's stitched-rule style, so it reads as
            // the way out rather than one more look-alike piece (owner, round 8).
            .background {
                RoundedRectangle(cornerRadius: RoomPaper.cardCorner, style: .continuous)
                    .strokeBorder(RoomPaper.edge, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(session.saving)
        .accessibilityIdentifier("similar-none")
    }

    /// While the pieces' photos still need prints, it says so with a count: "no look-alike" is
    /// only ever said once every photo it is compared with has one.
    private var recognizingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            if let preparing = session.preparing {
                Text("正在准备识别… 已准备 \(preparing.done) / \(preparing.total)。不想等的话，可以直接在下面手动选。")
                    .monospacedDigit()
                    .accessibilityIdentifier("recognition-preparing")
            } else {
                Text("正在识别…不想等的话，可以直接在下面手动选。")
            }
        }
        .font(.subheadline)
        .foregroundStyle(Color.subtle)
    }

    /// Pieces this photo looks like that it can still be put into, likeliest first, at most three.
    private var similarTargets: [(item: PhotoFurniture, match: FurnitureMatch)] {
        let targets = attachTargets
        return Array(session.similar.compactMap { match in
            targets.first { $0.instanceId == match.instanceId }.map { (item: $0, match: match) }
        }.prefix(SimilarFurniture.limit))
    }

    private func similarRow(_ item: PhotoFurniture, match: FurnitureMatch, index: Int) -> some View {
        let detail = String(localized: "很像它的一张照片")
        return Button {
            attach(to: item.instanceId)
        } label: {
            HStack(spacing: 12) {
                ThumbnailView(photoId: match.photoId)
                    .frame(width: 48, height: 48)
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("放进「\(item.shownName)」")
                        .font(.body.weight(.medium))
                    Text(detailWithLocation(detail, for: item))
                        .font(.footnote)
                        .foregroundStyle(Color.subtle)
                }
                Spacer()
                if session.saving, pending == .attach(item.instanceId) {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.subtle)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 48)
            .memoryCard(.workshop)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(session.saving)
        .accessibilityHint("把这张照片放进这件家具")
        .accessibilityIdentifier("similar-\(index)")
    }

    @ViewBuilder
    private var recognitionRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch session.review.analysis {
            case .idle, .running:
                recognizingRow
            case .unavailable:
                Text("这次没能在本机识别，请在下面手动选择。")
                    .font(.subheadline)
                    .foregroundStyle(Color.subtle)
                unrecognisedRow(board: fallbackBoard)
            case .finished(let result):
                if result.objects.isEmpty {
                    Text("本机没有认出家具，请在下面手动选择。")
                        .font(.subheadline)
                        .foregroundStyle(Color.subtle)
                    unrecognisedRow(board: fallbackBoard)
                } else {
                    ForEach(Array(result.objects.enumerated()), id: \.offset) { index, object in
                        ChoiceRow(
                            title: object.kind.title,
                            detail: String(localized: "本机建议 · \(Wording.likelihood(object.confidence))"),
                            symbol: object.kind.symbol,
                            selected: session.review.selectionOrigin == .suggested(objectIndex: index)
                        ) {
                            session.review.acceptSuggestion(objectIndex: index)
                        }
                        .accessibilityIdentifier("suggestion-\(object.kind.rawValue)")
                    }
                    Text("识别在这台设备上完成，可能有误，以你的选择为准。")
                        .font(.footnote)
                        .foregroundStyle(Color.subtle)
                }
            }
        }
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("手动选择", systemImage: "hand.tap")
                .font(.headline)
            CategoryPicker(
                selected: session.review.selectionOrigin == .user ? session.review.selectedCategory : nil,
                wallHint: photoBoardHint,
                photosOnly: true
            ) {
                session.review.chooseManually($0)
            }
        }
    }

    /// While sorting, a photo with no furniture in it has a natural home on a photo board. Once
    /// a board hangs in the room, "放进已有的家具" already offers it.
    private var photoBoardHint: String? {
        guard session.sorting != nil, let catalog = model.catalog else { return nil }
        let hasBoard = model.roomFurniture.contains { catalog.model(id: $0.modelId)?.category == .photoBoard }
        return hasBoard ? nil : String(localized: "看不出家具的照片，可以挂一块照片板来收。")
    }

    // MARK: Step 2 — which model

    private var modelsInCategory: [CatalogModel] {
        guard let category = session.review.selectedCategory, let catalog = model.catalog else { return [] }
        return catalog.models(in: category)
    }

    private var chosenModel: CatalogModel? {
        modelsInCategory.first { $0.id == session.chosenModelID }
    }

    private var chosenCategoryChanged: Bool {
        chosenModel == nil
    }

    private var modelStep: some View {
        ScrollView {
            ModelChooser(models: modelsInCategory, chosenID: Bindable(session).chosenModelID,
                         finish: session.placement?.finish ?? .original)
                .padding()
        }
        .safeAreaInset(edge: .bottom) {
            primaryButton(String(localized: "下一步：摆放"), enabled: chosenModel != nil) {
                guard let chosenModel else { return }
                if session.placement?.modelId != chosenModel.id {
                    session.placement = model.suggestedPlacement(for: chosenModel)
                    session.displayName = chosenModel.title
                }
                path.append(.placement)
            }
            .accessibilityIdentifier("next-placement")
        }
        .memoryPage(.workshop)
        .navigationTitle("选款式")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Instead of a new piece — an existing one

    private var attachStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("选一件家具，把这张照片放进去。房间的摆放不变。")
                    .font(.subheadline)
                    .foregroundStyle(Color.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(attachTargets.enumerated()), id: \.element.instanceId) { index, item in
                    Button {
                        attach(to: item.instanceId)
                    } label: {
                        HStack(spacing: 12) {
                            ThumbnailView(photoId: item.cover)
                                .frame(width: 56, height: 56)
                                .clipShape(.rect(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.shownName).font(.body.weight(.medium))
                                Text(detailWithLocation(Wording.photoCountLine(item, syncing: model.sync.pendingLinksByPiece[item.instanceId] ?? 0),
                                                        for: item))
                                    .font(.footnote)
                                    .foregroundStyle(Color.subtle)
                            }
                            Spacer()
                            if session.saving, pending == .attach(item.instanceId) { ProgressView() }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .memoryCard(.workshop)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("把这张照片放进这件家具")
                    .accessibilityIdentifier("attach-\(index)")
                }
            }
            .padding()
            .disabled(session.saving)
        }
        .memoryPage(.workshop)
        .navigationTitle("放进已有的家具")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(session.saving)
    }

    private func storePhotoOnly() {
        guard !session.saving else { return }
        session.saving = true
        pending = .photoOnly
        Task {
            let result = await model.storePhotoOnly(session)
            session.saving = false
            switch result {
            case .success:
                end(.keptInLibrary)
            case .failure(let failure):
                saveFailure = failure.message
            }
        }
    }

    private func attach(to instanceId: String) {
        guard !session.saving else { return }
        session.saving = true
        pending = .attach(instanceId)
        Task {
            let result = await model.attach(session, to: instanceId)
            session.saving = false
            switch result {
            case .success:
                onPlaced()
                end(.attached(instanceId: instanceId))
            case .failure(let failure):
                saveFailure = failure.message
            }
        }
    }

    private func retry() {
        switch pending {
        case .place: save()
        case .photoOnly: storePhotoOnly()
        case .attach(let instanceId): attach(to: instanceId)
        case .skip: skipPhoto()
        }
    }

    private func skipPhoto() {
        guard !session.saving else { return }
        session.saving = true
        pending = .skip
        Task {
            let failure = await model.skipSortingPhoto(session)
            session.saving = false
            saveFailure = failure?.message
        }
    }

    // MARK: Step 3 — where

    @ViewBuilder
    private var placementStep: some View {
        if let chosenModel, let binding = Binding(Bindable(session).placement) {
            PlacementEditor(
                placement: binding,
                displayName: Bindable(session).displayName,
                model: chosenModel,
                ignoring: nil,
                confirmTitle: String(localized: "确认摆放"),
                busy: session.saving,
                onConfirm: save
            )
            .memoryPage(.workshop)
            .navigationTitle("摆放")
            .navigationBarTitleDisplayMode(.inline)
            // Once a save is in flight the user cannot back out into "不添加" underneath it.
            .navigationBarBackButtonHidden(session.saving)
        }
    }

    private func save() {
        guard let placement = session.placement, !session.saving else { return }
        session.saving = true
        pending = .place
        let name = session.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let outcome = await model.confirm(session, placement: placement, displayName: name.isEmpty ? (chosenModel?.label ?? "家具") : name) // not-localized: stored; shown through shownName
            session.saving = false
            switch outcome {
            case .saved:
                onPlaced()
                end(.placed)
            case .failed(let message):
                saveFailure = message
            }
        }
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { saveFailure != nil }, set: { if !$0 { saveFailure = nil } })
    }
}

/// Full-width bottom action that stays reachable at the largest text sizes.
func primaryButton(_ title: String, enabled: Bool, busy: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 8) {
            if busy { ProgressView().tint(RoomPaper.ink) }
            Text(title).font(.headline).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
    .buttonStyle(PaperActionStyle())
    .disabled(!enabled || busy)
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(RoomPaper.paper)
    .overlay(alignment: .top) { Divider().overlay(RoomPaper.edge) }
}

private struct PaperActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        configuration.label
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .foregroundStyle(isEnabled ? RoomPaper.sealInk : RoomPaper.ink)
            .background {
                shape.fill(isEnabled ? RoomPaper.moss : RoomPaper.flyleaf)
                    .overlay { if configuration.isPressed { shape.fill(.black.opacity(0.09)) } }
                    .overlay { if !isEnabled { shape.strokeBorder(RoomPaper.edge) } }
            }
            .contentShape(shape)
    }
}
