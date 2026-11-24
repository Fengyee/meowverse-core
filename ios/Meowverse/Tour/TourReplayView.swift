import MeowverseCore
import SwiftUI

/// Settings → 使用导览 (PRODUCT_PLAN §4.1, words in docs/onboarding/LINES.md §6). 「从头看一遍」 and
/// one row per chapter this build tells, with how it ended. A choice closes Settings
/// (`closeSettings`); the tour shows it in the room once the room is free (`TourReplayEntry`).
///
/// Only chapters with a script are listed. The 「用到时再讲的」 group appears once this build tells
/// a feature chapter.
struct TourReplayView: View {
    @Environment(AppModel.self) private var model
    let closeSettings: () -> Void

    /// The row in Settings.
    static var rowTitle: String {
        String(localized: "tour.settings.row", defaultValue: "使用导览", comment: "Settings row that opens the tour's chapter list.")
    }

    var body: some View {
        let snapshot = TourReplayEntry.listSnapshot(model)
        let menu = TourMenu(catalog: TourReplayEntry.catalog,
                            stored: UserDefaultsTourRecordStore().load(library: model.options.storeFolder),
                            snapshot: snapshot)
        let readAgain = TourReplayEntry.readAgain(library: model.options.storeFolder)
        List {
            Section {
                Button {
                    // Told as the opening is: chapter 1's card only.
                    TourReplayEntry.askOpening()
                    closeSettings()
                } label: {
                    Label(String(localized: "tour.settings.replayAll", defaultValue: "从头看一遍",
                                 comment: "Tour page: closes Settings and runs the opening again from chapter 1's card."),
                          systemImage: "play.circle")
                }
                .accessibilityIdentifier("tour-replay-all")
            }
            group(menu.opening, readAgain: readAgain, snapshot: snapshot, title: String(localized: "tour.settings.group.opening", defaultValue: "开场",
                                              comment: "Tour page: the group of chapters told at the first launch."))
            group(menu.onDemand, readAgain: readAgain, snapshot: snapshot, title: String(localized: "tour.settings.group.onDemand", defaultValue: "用到时再讲的",
                                               comment: "Tour page: the group of chapters told when the user first gets to a feature."))
        }
        .navigationTitle(String(localized: "tour.settings.title", defaultValue: "使用导览", comment: "Tour page title."))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func group(_ rows: [TourMenu.Row], readAgain: Set<String>, snapshot: TourSnapshot, title: String) -> some View {
        // A chapter without a card has no script in this build yet.
        let shown = rows.compactMap { row in TourScript.card(row.id, catName: model.leadCatName).map { (row, $0) } }
        if !shown.isEmpty {
            Section {
                ForEach(shown, id: \.0.id) { row, card in
                    let state = Self.status(TourReplayEntry.shown(row, readAgain: readAgain), row.id, snapshot,
                                            roomHasFurniture: !model.roomFurniture.isEmpty)
                    Button { replay([row.id]) } label: { label(state, card) }
                        .accessibilityIdentifier("tour-replay-\(row.id.rawValue)")
                }
            } header: {
                Text(title)
            }
        }
    }

    private func label(_ status: String, _ card: (title: String, line: String, art: TourArt)) -> some View {
        HStack(spacing: 12) {
            (card.art.body ?? Image(systemName: "pawprint"))
                .resizable()
                .scaledToFit()
                .frame(width: 54, height: 36)
                .accessibilityHidden(true)
            Text(card.title)
                .foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            Text(status)
                .font(.subheadline)
                .foregroundStyle(Color.subtle)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    static func status(_ status: TourMenu.Status) -> String {
        switch status {
        case .seen: String(localized: "tour.status.seen", defaultValue: "看过", comment: "Tour page: the chapter was read to its end.")
        case .skipped: String(localized: "tour.status.skipped", defaultValue: "跳过了", comment: "Tour page: the chapter was skipped.")
        case .notYet: String(localized: "tour.status.notYet", defaultValue: "还没看", comment: "Tour page: the chapter was not seen on this device.")
        }
    }

    /// Not seen yet, and nothing in this room to show it with: when it can be seen (LINES.md T4.4).
    static func status(_ status: TourMenu.Status, _ chapter: TourChapterID, _ snapshot: TourSnapshot,
                       roomHasFurniture: Bool) -> String {
        guard status == .notYet else { return self.status(status) }
        switch chapter {
        case .memories where !snapshot.hasFurnitureWithPhotos: return TourText.statusNeedsPhotos
        case .moveAndLook where !snapshot.hasMovableFurniture:
            // Pieces in the room, all of them locked: say what is missing (QA_T4 suggestion 2).
            return roomHasFurniture ? TourText.statusNeedsUnlocked : TourText.statusNeedsFurniture
        default: return TourScript.t5Status(chapter, snapshot) ?? self.status(status)
        }
    }

    private func replay(_ chapters: [TourChapterID]) {
        TourReplayEntry.ask(chapters)
        closeSettings()
    }
}
