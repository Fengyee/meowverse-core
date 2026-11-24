import Foundation
import Synchronization
import Testing
@testable import MeowverseCore

/// A wall clock tests move by hand. Each device reads it with its own skew.
final class SyncTestClock: Sendable {
    private let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    var now: Date { time.withLock { $0 } }

    func advance(_ seconds: TimeInterval = 1) { time.withLock { $0 += seconds } }

    func reader(skew: TimeInterval = 0) -> @Sendable () -> Date {
        { [self] in now.addingTimeInterval(skew) }
    }
}

/// One phone or iPad: its own library folder and its own sync session on the shared fake cloud.
struct SyncDevice {
    let name: String
    let root: URL
    let store: LibraryStore
    let session: SyncSession
    let cloud: SyncMemoryCloud

    /// `catalog` other than the full one: a device on another version of the app.
    init(_ name: String, cloud: SyncMemoryCloud, clock: SyncTestClock, skew: TimeInterval = 0,
         catalog older: FurnitureCatalog? = nil, fault: (@Sendable (StoreStep) throws -> Void)? = nil) async throws {
        self.name = name
        self.cloud = cloud
        root = TestSupport.tempDir().appendingPathComponent("Library-\(name)", isDirectory: true)
        let catalog = try older ?? TestSupport.catalog()
        store = LibraryStore(root: root, catalog: catalog, fault: fault)
        try await store.load()
        session = SyncSession(store: store, transport: cloud.endpoint(name), catalog: catalog,
                              deviceID: "dev\(name)", now: clock.reader(skew: skew))
    }

    @discardableResult
    func sync() async throws -> SyncReport { try await session.sync() }

    func state() async -> AppState { await store.snapshot() }

    /// Reopens the library from disk, as after a restart.
    func reopened() async throws -> AppState { try await store.load() }

    func onlyPhoto() async throws -> PhotoRecord {
        let photos = await state().photos
        try #require(photos.count == 1)
        return photos[0]
    }
}

enum SyncCheck {
    /// Syncs every device, in turn, until a full round changes nothing anywhere and nothing is
    /// left to send (at most 8 rounds). A cycle that hit a problem is not quiet.
    @discardableResult
    static func settle(_ devices: [SyncDevice], sourceLocation: SourceLocation = #_sourceLocation) async throws -> Int {
        for round in 1...8 {
            var changed = false
            for device in devices {
                let report = try await device.sync()
                if report.applied || report.sent > 0 || report.received > 0 || report.unsent > 0 || report.problem != nil
                    || report.waitingForFiles > 0 { changed = true }
            }
            if !changed { return round }
        }
        Issue.record("did not settle in 8 rounds", sourceLocation: sourceLocation)
        return 8
    }

    /// What every device must agree on: everything but device-local fields (the stored copy and
    /// its paths, `assetIdentifier`, revisions) and the positions of photos and pieces in their
    /// lists. Rooms, cats and each piece's photos are compared in order.
    struct View: Equatable, CustomStringConvertible {
        var photos: [String]
        var observations: [String]
        var items: [String]
        var storage: [String]
        var rooms: [String]
        var cats: [String]
        var catName: String

        var description: String {
            (["photos:"] + photos + ["observations:"] + observations + ["items:"] + items + ["storage:"] + storage
             + ["rooms:"] + rooms + ["cats:"] + cats + ["catName: \(catName)"]).joined(separator: "\n")
        }
    }

    static func view(_ s: AppState) -> View {
        func piece(_ p: PhotoFurniture) -> String {
            let sources = p.sources.map { "\($0.photoId)/\($0.observationId ?? "-")/\($0.origin.rawValue)/\($0.addedAt.map { "\($0.timeIntervalSince1970)" } ?? "-")" }
            return "\(p.instanceId) \(p.modelId) \(p.x),\(p.z) \(p.width)x\(p.depth) t\(p.turn) \(p.wall?.rawValue ?? "floor") \(p.finish.rawValue) "
                + "'\(p.displayName)' \(p.tags) lock=\(p.locked.map(String.init) ?? "-") cover=\(p.coverPhotoId ?? "-") room=\(p.roomId ?? "-") "
                + "created=\(p.createdAt?.timeIntervalSince1970 ?? -1) updated=\(p.updatedAt?.timeIntervalSince1970 ?? -1) [\(sources.joined(separator: ","))]"
        }
        return View(
            photos: s.photos.map { p in
                "\(p.photoId) src=\(p.reducedFrom?.sha256 ?? p.sha256) fav=\(p.favorite) note='\(p.note)' day=\(p.captureDate ?? "-")/\(p.captureDateSource.rawValue) "
                    + "exif=\(p.exifCaptureDate ?? "-") cloud=\(p.cloudIdentifier ?? "-") file=\(p.filename ?? "-") imported=\(p.importedAt.timeIntervalSince1970)"
            }.sorted(),
            observations: s.observations.map { "\($0.observationId) \($0.photoId) \($0.origin.rawValue) \($0.mode.rawValue) \($0.analyzer)" }.sorted(),
            // Pieces keep the order they reached each device in; which pieces and how is shared.
            items: s.items.map(piece).sorted(),
            storage: s.storage.map(piece).sorted(),
            rooms: s.allRooms.map { "\($0.roomId) \($0.name ?? "-")" },
            cats: s.allCats.map { "\($0.catId) \($0.name) \($0.roomId ?? "-")" },
            catName: s.catName)
    }

    static func expectConverged(_ devices: [SyncDevice], sourceLocation: SourceLocation = #_sourceLocation) async {
        var views: [View] = []
        for device in devices {
            let state = await device.state()
            #expect(LibraryStore.isConsistent(state), "\(device.name) is consistent", sourceLocation: sourceLocation)
            views.append(view(state))
        }
        for (index, other) in views.enumerated().dropFirst() where other != views[0] {
            Issue.record("device \(devices[index].name) differs from \(devices[0].name):\n\(views[0])\n---\n\(other)",
                         sourceLocation: sourceLocation)
        }
    }

    /// The same picked file stored as a copy at most `maxPixel` long: 2048 without the photo
    /// library link, 1024 with it. Same source hash, different stored bytes.
    static func wideDraft(seed: Int, maxPixel: Int, asset: String? = nil, cloud: String? = nil) throws -> ImportDraft {
        let data = TestSupport.imageData(width: 2600, height: 40, seed: seed, dateTimeOriginal: "2025:06:0\(seed % 9 + 1) 10:00:00")
        var draft = try PhotoIngest.makeDraft(data: data, filename: "wide-\(seed).jpg", reduce: true, maxPixel: maxPixel)
        draft.assetIdentifier = asset
        draft.cloudIdentifier = cloud
        return draft
    }

    static let chair = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2)
    /// Spots apart from each other and from `chair`.
    static func spot(_ i: Int) -> Placement {
        let spots = [(0, 0), (8, 0), (12, 0), (0, 8), (3, 8), (9, 8), (12, 8), (0, 11), (3, 11), (9, 11), (12, 11), (12, 4)]
        let (x, z) = spots[i % spots.count]
        return Placement(modelId: "kenney-chair", x: x, z: z, width: 2, depth: 2)
    }
}
