import MeowverseCore
import SwiftUI

// Suggested filing (round 8) bound to the app model: the confirmation page, the notice with
// 撤销 that follows it, and the quiet entry that runs suggestions again from the photo library's
// 未放进家具 list and from a photo board. The look is the UI artist's components in
// DesignSystem/ (FilingSuggestionReview, FilingNoticeBar); nothing here restyles them.

/// What the notice bar says after a confirmed page.
struct FiledNotice: Equatable, Identifiable {
    let id = UUID()
    let message: String
}

extension AppModel {
    /// The offers as the confirmation page shows them: by piece, each photo with its capture line.
    func filingGroups() -> [FilingSuggestionGroup] {
        suggestionGroups.compactMap { group in
            guard let item = anyFurniture(group.instanceId) else { return nil }
            let detail: String? = if let room = roomName(ofFurniture: item.instanceId) {
                hasSeveralRooms ? room : nil
            } else {
                String(localized: "在收纳箱")
            }
            return FilingSuggestionGroup(
                id: item.instanceId, name: item.shownName, detail: detail, cover: item.cover,
                photos: group.offers.map { offer in
                    FilingSuggestionPhoto(id: offer.photoId,
                                          label: photo(offer.photoId)?.captureLine ?? String(localized: "拍摄日期未知"))
                })
        }
    }
}

/// The confirmation page with the app behind it. Every photo starts ticked; "放进所选的 N 张"
/// files the ticked ones and never offers the unticked ones again; "先不用" leaves everything
/// as it was (the offers stay). `groups` is taken when the page opens, so nothing moves under
/// the finger while it is open; offers that stopped holding meanwhile are skipped on confirm.
struct SuggestionReviewPage: View {
    @Environment(AppModel.self) private var model
    let groups: [FilingSuggestionGroup]
    /// Called once: with the notice to show after a confirmed page, or nil for "先不用".
    let finish: (FiledNotice?) -> Void
    @State private var selection: Set<String>
    @State private var busy = false
    @State private var failure: String?

    init(groups: [FilingSuggestionGroup], finish: @escaping (FiledNotice?) -> Void) {
        self.groups = groups
        self.finish = finish
        _selection = State(initialValue: Set(groups.flatMap { $0.photos.map(\.id) }))
    }

    var body: some View {
        FilingSuggestionReview(groups: groups, selection: $selection, busy: busy, confirm: confirm, notNow: { finish(nil) }) {
            ThumbnailView(photoId: $0)
        }
        .interactiveDismissDisabled(busy)
        .alert("没能保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好") {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func confirm() {
        guard !busy else { return }
        busy = true
        let shown = Set(groups.flatMap { $0.photos.map(\.id) })
        let chosen = selection.intersection(shown)
        // Each ticked photo with the piece it was shown under: only that filing is confirmed.
        let choices = Set(groups.flatMap { group in
            group.photos.filter { chosen.contains($0.id) }.map { SuggestionChoice(photoId: $0.id, instanceId: group.id) }
        })
        Task {
            let failed = await model.acceptSuggestions(choices, declining: shown.subtracting(chosen))
            busy = false
            if let failed {
                failure = failed.message
            } else {
                finish(model.lastAcceptanceMessage().map { FiledNotice(message: $0) })
            }
        }
    }
}

/// The notice after a confirmed page, with 撤销, for about 8 s (as the photo library's batch
/// notice). Put it in the page's bottom inset.
struct SuggestedFilingNotice: View {
    @Environment(AppModel.self) private var model
    @Binding var notice: FiledNotice?
    @State private var undoing = false

    var body: some View {
        if let notice {
            FilingNoticeBar(message: notice.message, undoing: undoing,
                            undo: model.canUndoLastAcceptance ? { undo(notice) } : nil)
                .task(id: notice.id) {
                    // Long enough to read and reach; the filing itself stays either way. A task
                    // cancelled because the bar left the screen for a moment (the page it came
                    // from sliding away) must not take the notice with it.
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    if self.notice?.id == notice.id, !undoing { self.notice = nil }
                }
        }
    }

    private func undo(_ shown: FiledNotice) {
        guard !undoing else { return }
        undoing = true
        Task {
            let failed = await model.undoLastAcceptance()
            undoing = false
            if let failed {
                TransientNotice.show(failed.message)
            } else if notice?.id == shown.id {
                notice = nil
            }
        }
    }
}

/// A quiet way to ask for suggestions again: on the photo library's 未放进家具 list and on a
/// photo board. It works the offers out, then opens the confirmation page; with nothing to
/// suggest it says so in a passing line and stays hidden until the home changes.
struct SuggestionRerunEntry: View {
    enum Scope: Equatable {
        /// These photos, those of them in no furniture.
        case unfiled([String])
        /// Photos on a photo board and in no other piece.
        case photoBoards
    }

    @Environment(AppModel.self) private var model
    let scope: Scope
    @Binding var notice: FiledNotice?
    @State private var running = false
    @State private var page: Page?
    /// The library revision at which the last run found nothing.
    @State private var emptyAt: Int?

    var body: some View {
        if model.batchSuggestionsAvailable, emptyAt != model.state.revision {
            // The quiet command look of 「收藏、便签和日期」: icon and accent text, no fill, so it
            // stays below "逐张整理这 N 张" on the library list.
            Button(action: run) {
                Label {
                    Text("按建议放进家具")
                } icon: {
                    if running { ProgressView() } else { Image(systemName: SuggestedFilingMark.symbol) }
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
                .contentShape(.rect)
                // 9.3's window (LINES.md T5.2): the words, not the row's whole width.
                .tourAnchor("rerun-suggestions")
            }
            .buttonStyle(.borderless)
            .disabled(running)
            .frame(maxWidth: .infinity)
            .accessibilityHint(Text("在这台设备上找和家具里的照片相像的照片，逐张确认后再放进去"))
            .accessibilityIdentifier("rerun-suggestions")
            .sheet(item: $page) { shown in
                NavigationStack {
                    SuggestionReviewPage(groups: shown.groups) { filed in
                        page = nil
                        notice = filed
                    }
                }
            }
        }
    }

    private struct Page: Identifiable {
        let id = UUID()
        let groups: [FilingSuggestionGroup]
    }

    private func run() {
        guard !running else { return }
        running = true
        model.retryFailedPrints()
        switch scope {
        case .unfiled(let ids): model.suggestForUnfiled(ids)
        case .photoBoards: model.suggestForPhotoBoards()
        }
        Task {
            await model.suggestionsSettled()
            running = false
            let groups = model.filingGroups()
            if groups.isEmpty, model.suggestionsUnfinished {
                // Still there to be asked again.
                TransientNotice.show(String(localized: "这次没能完成比对，不能确定有没有可以按建议放进家具的照片。可以再试一次。"))
            } else if groups.isEmpty {
                emptyAt = model.state.revision
                TransientNotice.show(String(localized: "没有找到可以按建议放进家具的照片。"))
            } else {
                page = Page(groups: groups)
            }
        }
    }
}
