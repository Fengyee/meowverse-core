import Foundation
import Testing
@testable import MeowverseCore

/// Random edits on three devices with skewed clocks, going offline, a cloud that repeats,
/// reorders and drops: once everyone is online and synced, every device holds the same home,
/// nothing that was never deleted is missing, and further syncs change nothing.
@Suite struct SyncConvergenceTests {
    /// Seed 6 once lost a photo's file: a cycle whose save dropped still cleaned up files.
    @Test(arguments: [UInt64(20261118), 6, 7, 99])
    func randomEditsOnThreeDevicesConverge(seed: UInt64) async throws {
        var rng = SeededRandom(seed: seed)
        let clock = SyncTestClock()
        let cloud = SyncMemoryCloud(seed: seed)
        await cloud.setMessyDelivery(true)
        let devices = [
            try await SyncDevice("A", cloud: cloud, clock: clock),
            try await SyncDevice("B", cloud: cloud, clock: clock, skew: 5),
            try await SyncDevice("C", cloud: cloud, clock: clock, skew: -7),
        ]
        var drafts: [Int: ImportDraft] = [:]
        func draft(_ n: Int) throws -> ImportDraft {
            if let made = drafts[n] { return made }
            let made = try TestSupport.draft(seed: 100 + n)
            drafts[n] = made
            return made
        }
        var importedSources = Set<String>(), deletedSources = Set<String>()
        var madePieces = Set<String>(), removedPieces = Set<String>()
        var offline = Set<String>()

        for _ in 0..<160 {
            clock.advance(Double(Int.random(in: 0...3, using: &rng)))
            let device = devices.randomElement(using: &rng)!
            let state = await device.state()
            let photo = state.photos.randomElement(using: &rng)
            let piece = state.allFurniture.randomElement(using: &rng)
            switch Int.random(in: 0..<18, using: &rng) {
            case 0, 1:
                let d = try draft(Int.random(in: 0..<8, using: &rng))
                if let piece, Bool.random(using: &rng) {
                    if (try? await device.store.addSource(draft: d, toInstance: piece.instanceId, decision: .manual)) != nil { importedSources.insert(d.sha256) }
                } else if (try? await device.store.importPhoto(draft: d)) != nil {
                    importedSources.insert(d.sha256)
                }
            case 2:
                if let photo { _ = try? await device.store.editPhoto(photoId: photo.photoId, PhotoEdit(note: "n\(Int.random(in: 0..<50, using: &rng))")) }
            case 3:
                if let photo { _ = try? await device.store.setFavorite(photoIds: [photo.photoId], Bool.random(using: &rng)) }
            case 4:
                if let photo {
                    let change: PhotoEdit.DateChange = Bool.random(using: &rng) ? .set("2020-0\(Int.random(in: 1...9, using: &rng))-11") : .clear
                    _ = try? await device.store.editPhoto(photoId: photo.photoId, PhotoEdit(captureDate: change))
                }
            case 5:
                if let made = try? await device.store.addFurniture(placement: SyncCheck.spot(Int.random(in: 0..<12, using: &rng)),
                                                                     displayName: "P\(Int.random(in: 0..<99, using: &rng))",
                                                                     roomId: state.allRooms.randomElement(using: &rng)!.roomId) {
                    madePieces.insert(made.instanceId)
                }
            case 6:
                if let piece { _ = try? await device.store.rename(instanceId: piece.instanceId, displayName: "R\(Int.random(in: 0..<99, using: &rng))") }
            case 7:
                if let piece, state.item(id: piece.instanceId) != nil {
                    _ = try? await device.store.updatePlacement(instanceId: piece.instanceId, placement: SyncCheck.spot(Int.random(in: 0..<12, using: &rng)))
                }
            case 8:
                if let photo, let piece {
                    if piece.sources.contains(where: { $0.photoId == photo.photoId }) {
                        _ = try? await device.store.unlinkPhoto(photoId: photo.photoId, fromInstance: piece.instanceId)
                    } else {
                        _ = try? await device.store.linkPhoto(photoId: photo.photoId, toInstance: piece.instanceId)
                    }
                }
            case 9:
                if let photo, Int.random(in: 0..<3, using: &rng) == 0, (try? await device.store.deletePhoto(photoId: photo.photoId)) != nil {
                    deletedSources.insert(photo.reducedFrom?.sha256 ?? photo.sha256)
                }
            case 10:
                if let piece, Int.random(in: 0..<3, using: &rng) == 0, (try? await device.store.removeFurniture(instanceId: piece.instanceId)) != nil {
                    removedPieces.insert(piece.instanceId)
                }
            case 11:
                if let piece {
                    if state.item(id: piece.instanceId) != nil {
                        _ = try? await device.store.stowFurniture(instanceId: piece.instanceId)
                    } else {
                        _ = try? await device.store.restoreFurniture(instanceId: piece.instanceId, placement: SyncCheck.spot(Int.random(in: 0..<12, using: &rng)))
                    }
                }
            case 12:
                if state.allRooms.count < 4, Bool.random(using: &rng) {
                    _ = try? await device.store.addRoom(name: "Room\(Int.random(in: 0..<9, using: &rng))")
                } else if let room = state.allRooms.dropFirst().randomElement(using: &rng) {
                    if Bool.random(using: &rng) { _ = try? await device.store.renameRoom(roomId: room.roomId, name: "Q\(Int.random(in: 0..<9, using: &rng))") }
                    else { try? await device.store.removeRoom(roomId: room.roomId) }
                }
            case 13:
                if let cat = state.allCats.randomElement(using: &rng), Bool.random(using: &rng) {
                    _ = try? await device.store.renameCat(catId: cat.catId, name: "Cat\(Int.random(in: 0..<9, using: &rng))")
                } else {
                    _ = try? await device.store.addCat(name: "Kit\(Int.random(in: 0..<9, using: &rng))")
                }
            case 14:
                let isOff = offline.contains(device.name)
                if isOff { offline.remove(device.name) } else { offline.insert(device.name) }
                await cloud.setOffline(device.name, !isOff)
            case 15:
                await cloud.dropAfterSaving(device.name, count: Int.random(in: 0...2, using: &rng))
                _ = try? await device.sync()
            case 16:
                try await device.session.captureLocalEdits()
            default:
                _ = try await device.sync()
            }
        }

        for device in devices { await cloud.setOffline(device.name, false) }
        try await SyncCheck.settle(devices)
        await SyncCheck.expectConverged(devices)

        let final = await devices[0].state()
        let sources = Set(final.photos.map { $0.reducedFrom?.sha256 ?? $0.sha256 })
        #expect(importedSources.subtracting(deletedSources).isSubset(of: sources), "a photo nobody deleted is missing")
        #expect(madePieces.subtracting(removedPieces).isSubset(of: Set(final.allFurniture.map(\.instanceId))),
                "a piece nobody removed is missing")
        #expect(!final.photos.isEmpty && !final.allFurniture.isEmpty, "the run did something")
        for device in devices {
            let report = try await device.sync()
            #expect(!report.applied && report.sent == 0, "\(device.name) still changing after settling")
            #expect(try await device.reopened() == device.state(), "\(device.name) on disk matches memory")
        }
    }
}
