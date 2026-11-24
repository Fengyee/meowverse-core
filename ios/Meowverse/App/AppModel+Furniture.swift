import MeowverseCore
import SwiftUI

/// What the furniture library is showing. Kept in one value so AppModel gains one property, and
/// so the filters are still there when the library is opened again.
struct FurnitureUIState {
    var query = FurnitureQuery()
    /// Covers in a grid instead of rows.
    var grid = false
    /// The piece the room is pointing out after "在房间里定位", and the tick that restarts the
    /// highlight when the same piece is asked for twice.
    var located: String?
    var locateTick = 0
    /// A short line shown over the room (a locked piece was asked to move, a piece was pointed out).
    var roomNotice: String?
    var noticeTick = 0
}

extension AppModel {
    /// The pieces the furniture library shows for the current filters and order.
    var shownFurniture: [PhotoFurniture] {
        FurnitureLibrary.pieces(in: state, catalog: catalog, query: pieces.query, syncing: Set(sync.pendingLinksByPiece.keys))
    }

    /// Points a piece out in the room: every sheet closes and the room outlines it for a moment.
    func locate(_ instanceId: String) {
        guard furniture(instanceId) != nil else { return }
        showRoom(ofFurniture: instanceId)
        openedFurnitureID = nil
        photos.libraryShown = false
        pieces.located = instanceId
        pieces.locateTick += 1
        if let item = furniture(instanceId) { say(String(localized: "「\(item.shownName)」在这里")) }
    }

    /// Why a long press on a locked piece does nothing.
    func sayLocked(_ item: PhotoFurniture) {
        say(String(localized: "「\(item.shownName)」已锁定。在家具详情里解锁后才能移动。"))
    }

    private func say(_ text: String) {
        // The long press keeps reporting while the finger is down: one notice, not a stream.
        guard pieces.roomNotice != text else { return }
        pieces.roomNotice = text
        pieces.noticeTick += 1
        AccessibilityNotification.Announcement(text).post()
    }

    /// Locks or unlocks pieces. A locked piece cannot be moved, restyled, put away or deleted.
    func setLocked(_ instanceIds: [String], _ locked: Bool) async -> PhotoSaveFailure? {
        failure(of: await perform { _ = try await $0.setLocked(instanceIds: instanceIds, locked) })
    }

    /// Puts several pieces away as one save. The caller leaves locked pieces out.
    func stow(_ instanceIds: [String]) async -> PhotoSaveFailure? {
        if let refusal = placeEditRefusal(instanceIds) { return PhotoSaveFailure(message: refusal, error: nil) }
        return failure(of: await perform { _ = try await $0.stowFurniture(instanceIds: instanceIds) })
    }

    /// A piece restyled into a model this version doesn't have stands here as it was. Sync holds
    /// back its place (`SyncCapture`), so changing it here would only seem to work.
    func placeEditRefusal(_ instanceIds: [String]) -> String? {
        guard instanceIds.contains(where: sync.piecesFromNewerVersion.contains) else { return nil }
        return instanceIds.count == 1
            ? String(localized: "这件家具在更新版本里换了款式。更新 App 后才能在这里挪动、改款式或收纳。")
            : String(localized: "选中的家具里有在更新版本里换了款式的。更新 App 后才能一起收纳。")
    }

    /// Deletes several pieces as one save; their photos stay in the library.
    func remove(_ instanceIds: [String]) async -> PhotoSaveFailure? {
        failure(of: await perform { try await $0.removeFurniture(instanceIds: instanceIds) })
    }

    /// The photo that stands for a piece in lists; nil goes back to the first photo.
    func setCover(_ photoId: String?, of instanceId: String) async -> PhotoSaveFailure? {
        failure(of: await perform { _ = try await $0.setCover(instanceId: instanceId, photoId: photoId) })
    }

    func reorderPhotos(_ order: [String], of instanceId: String) async -> PhotoSaveFailure? {
        failure(of: await perform { _ = try await $0.reorderPhotos(instanceId: instanceId, order: order) })
    }

    private func failure<T>(of result: Result<T, PhotoSaveFailure>) -> PhotoSaveFailure? {
        if case .failure(let failure) = result { return failure }
        return nil
    }
}

extension Wording {
    static func sortTitle(_ sort: FurnitureQuery.Sort) -> String {
        switch sort {
        case .added: String(localized: "添加顺序")
        case .name: String(localized: "名字")
        case .photoCount: String(localized: "照片张数")
        case .lastPhotoAdded: String(localized: "上次添照片")
        case .created: String(localized: "创建时间")
        }
    }

    /// Which end a sort starts from, in words that fit the sort.
    static func directionTitle(_ sort: FurnitureQuery.Sort, ascending: Bool) -> String {
        switch sort {
        case .added: ascending ? String(localized: "先添的在前") : String(localized: "后添的在前")
        case .name: ascending ? String(localized: "A 到 Z") : String(localized: "Z 到 A")
        case .photoCount: ascending ? String(localized: "少的在前") : String(localized: "多的在前")
        case .lastPhotoAdded, .created: ascending ? String(localized: "最早的在前") : String(localized: "最近的在前")
        }
    }

    static func placeTitle(_ place: FurnitureQuery.Place) -> String {
        switch place {
        case .all: String(localized: "全部")
        case .room: String(localized: "房间里")
        case .stored: String(localized: "收纳箱")
        }
    }
}
