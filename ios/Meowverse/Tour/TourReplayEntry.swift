import MeowverseCore
import os
import SwiftUI

/// The chapters the user asked to see again, from Settings → 使用导览 or the empty room's
/// 「看看怎么玩」 (PRODUCT_PLAN §4.1, §4.2). Held here until the room is free; `TourCoordinator`
/// takes them one at a time and sends each as `.replay`, which changes no ending already recorded.
@MainActor
enum TourReplayEntry {
    /// Still to show, in order (`TourReplayQueue`).
    private(set) static var queue = TourReplayQueue()
    private static let log = Logger(subsystem: "app.meowverse", category: "tour")

    /// The chapters this build tells, in catalog order.
    static var catalog: TourCatalog { .thisBuild }

    /// The chapters asked for are the opening, 「从头看一遍」: told as the opening is, chapter 1's card
    /// only and 【下一步】 at the end of chapters 2 and 3.
    private(set) static var replaysOpening = false

    /// Replaces whatever was asked before.
    static func ask(_ chapters: [TourChapterID]) {
        queue.ask(chapters)
        replaysOpening = false
        log.notice("[tour] replay queued: \(chapters.map(\.rawValue).joined(separator: ","), privacy: .public)")
    }

    /// 「从头看一遍」: the opening, from chapter 1's card.
    static func askOpening() {
        ask(TourMenu(catalog: catalog, stored: .missing, snapshot: TourSnapshot()).fromTheStart)
        replaysOpening = true
    }

    /// For the coordinator, when `TourReplayQueue.step` says so.
    static func take() -> TourChapterID? { queue.take() }

    /// For the coordinator, when a replayed chapter ends: 「全部跳过」 also drops the rest asked for.
    static func ended(_ exit: TourExit) { queue.ended(exit) }

    // MARK: Read again, for the list only

    /// The chapters read again to their end by hand on this library, for Settings only (the
    /// lead's ruling, T3 r8). Looking again changes no ending in the tour's record (PRODUCT_PLAN
    /// §3.1.1 #10); this only turns 还没看 into 看过 in the list, and leaves 看过 and 跳过了 as they
    /// are. Beside the record in UserDefaults; not in a backup.
    static func readAgainKey(library: String) -> String { "tour.readAgain.\(library)" }

    static func readAgain(library: String, defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: readAgainKey(library: library)) ?? [])
    }

    static func markReadAgain(_ chapter: TourChapterID, library: String, defaults: UserDefaults = .standard) {
        var read = readAgain(library: library, defaults: defaults)
        guard read.insert(chapter.rawValue).inserted else { return }
        defaults.set(read.sorted(), forKey: readAgainKey(library: library))
    }

    static func forgetReadAgain(library: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: readAgainKey(library: library))
    }

    /// The status the list shows for a row.
    static func shown(_ row: TourMenu.Row, readAgain: Set<String>) -> TourMenu.Status {
        row.status == .notYet && readAgain.contains(row.id.rawValue) ? .seen : row.status
    }

    /// What this home and device have, for the replay list and, with where the user is and the
    /// reminders added, for the coordinator (LINES.md T5.10).
    static func listSnapshot(_ model: AppModel) -> TourSnapshot {
        var snapshot = TourSnapshot()
        snapshot.roomIsEmpty = model.roomFurniture.isEmpty
        snapshot.roomHasCat = model.leadCat != nil
        snapshot.furnitureCount = model.state.items.count
        snapshot.photoCount = model.state.photos.count
        // What the Play panel shows: also the simulator's stand-in row (`-MeowverseShowAREntry`).
        let ar = RoomAREntry.current
        snapshot.supportsAR = ar != .hidden
        snapshot.cameraDenied = ar == .cameraOff
        snapshot.hasFurnitureWithPhotos = model.roomFurniture.contains { !$0.sources.isEmpty }
        snapshot.hasMovableFurniture = model.roomFurniture.contains { !$0.isLocked }
        snapshot.hasPerchableFurniture = TourFacts.catPieces(model).contains { TourFacts.reachable($0, model) }
        // The queue on the bar of photos to sort, not the library's 「未放进家具」.
        snapshot.unsortedPhotoCount = model.pendingPhotoIds.count
        snapshot.importRunning = importRunning(model)
        snapshot.cloudBackupOn = model.cloudBackupOn
        return snapshot
    }

    /// Anything that keeps the bar from offering 「整理」 (`ImportQueueBar`). Wider than the room's
    /// own "busy": photos are compared in a free room (`TourImportWait`).
    static func importRunning(_ model: AppModel) -> Bool {
        model.batch.progress != nil || model.photos.adding != nil || model.importSession != nil
            || model.isPreparingImport || model.batch.suggestions.recognition?.phase == .recognising
    }
}
