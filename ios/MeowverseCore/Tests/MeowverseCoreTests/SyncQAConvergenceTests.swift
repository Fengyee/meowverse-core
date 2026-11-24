import Foundation
import Testing
@testable import MeowverseCore

/// QA review of the sync core (2026-11-18): random edits on five devices with skewed clocks,
/// a cloud that repeats, reorders and drops, failing saves and downloads, a full iCloud, long
/// offline stretches, and devices whose sync file is lost or reset. Once everything is online:
/// every device holds the same home, every shown photo has its copy on disk, nothing nobody
/// deleted is missing, another round changes nothing, and a new device gets the same home.
@Suite struct SyncQAConvergenceTests {
    /// Seeds kept after a sweep (see `wideSweep`).
    @Test(arguments: [UInt64(1), 2, 3, 5, 8, 13, 21, 2026])
    func randomEditsOnFiveDevicesWithFaultsConverge(seed: UInt64) async throws {
        try await Self.run(seed: seed, steps: 220)
    }

    /// `SYNC_QA_SWEEP=<n> swift test --filter wideSweep` runs seeds 1...n; off by default.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SYNC_QA_SWEEP"] != nil))
    func wideSweep() async throws {
        let count = UInt64(ProcessInfo.processInfo.environment["SYNC_QA_SWEEP"].flatMap(Int.init) ?? 0)
        let start = UInt64(ProcessInfo.processInfo.environment["SYNC_QA_SWEEP_START"].flatMap(Int.init) ?? 1)
        for seed in start..<(start + count) {
            try await Self.run(seed: seed, steps: 220, label: "seed \(seed)")
        }
    }

    static func run(seed: UInt64, steps: Int, label: String = "") async throws {
        var rng = SeededRandom(seed: seed)
        let clock = SyncTestClock()
        let cloud = SyncMemoryCloud(seed: seed)
        await cloud.setMessyDelivery(true)
        var devices: [QADevice] = []
        for (name, skew) in [("A", 0.0), ("B", 5.0), ("C", -7.0), ("D", 40.0), ("E", -90.0)] {
            devices.append(try await QADevice(name, cloud: cloud, clock: clock, skew: skew))
        }
        var drafts: [Int: ImportDraft] = [:]
        func draft(_ n: Int) throws -> ImportDraft {
            if let made = drafts[n] { return made }
            let made = try TestSupport.draft(seed: 300 + n)
            drafts[n] = made
            return made
        }
        var importedSources = Set<String>(), deletedSources = Set<String>()
        var madePieces = Set<String>(), removedPieces = Set<String>()
        var offline = Set<String>()

        for _ in 0..<steps {
            clock.advance(Double(Int.random(in: 0...3, using: &rng)))
            let device = devices.randomElement(using: &rng)!
            let state = await device.state()
            let photo = state.photos.randomElement(using: &rng)
            let piece = state.allFurniture.randomElement(using: &rng)
            switch Int.random(in: 0..<26, using: &rng) {
            case 0, 1:
                let d = try draft(Int.random(in: 0..<10, using: &rng))
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
                _ = try? await device.session.captureLocalEdits()
            case 17:
                await cloud.failSaves(device.name, count: 1)
                _ = try? await device.sync()
            case 18:
                device.faults.failDownloads.toggle()
            case 19:
                // iCloud full for a while.
                let full = Bool.random(using: &rng)
                let used = await cloud.fileBytes
                await cloud.setQuota(full ? used : nil)
            case 20:
                // A long time passes (a device was away for more than a day).
                if Int.random(in: 0..<4, using: &rng) == 0 { clock.advance(SyncSession.fileGrace + 120) }
            case 21:
                // Sync's own file is lost (or reset after the user agreed): the next sync merges as a first.
                if Int.random(in: 0..<4, using: &rng) == 0 {
                    if Bool.random(using: &rng) { try? FileManager.default.removeItem(at: device.syncStateURL) }
                    else { try? await device.session.startOver() }
                }
            default:
                _ = try? await device.sync()
            }
        }

        for device in devices {
            await cloud.setOffline(device.name, false)
            device.faults.failDownloads = false
        }
        await cloud.setQuota(nil)
        try await QACheck.settle(devices, rounds: 16)
        await QACheck.expectConverged(devices)

        let final = await devices[0].state()
        let sources = Set(final.photos.map { $0.reducedFrom?.sha256 ?? $0.sha256 })
        #expect(importedSources.subtracting(deletedSources).isSubset(of: sources), "\(label) a photo nobody deleted is missing")
        #expect(madePieces.subtracting(removedPieces).isSubset(of: Set(final.allFurniture.map(\.instanceId))),
                "\(label) a piece nobody removed is missing")
        #expect(!final.photos.isEmpty && !final.allFurniture.isEmpty, "\(label) the run did something")
        for device in devices {
            #expect(await device.filesAreWhole() == [], "\(label)")
            let report = try await device.sync()
            #expect(!report.applied && report.sent == 0 && report.unsent == 0 && report.waitingForFiles == 0,
                    "\(label) \(device.name) still changing after settling")
            #expect(try await device.store.load() == device.state(), "\(label) \(device.name) on disk matches memory")
        }
        // A device that joins now gets the same home, files included.
        let joining = try await QADevice("Z", cloud: cloud, clock: clock, skew: 3)
        try await QACheck.settle([joining] + devices, rounds: 16)
        await QACheck.expectConverged([joining] + devices)
        #expect(await joining.filesAreWhole() == [], "\(label)")
        #expect(await joining.state().photos.count == final.photos.count, "\(label) a new device cannot get every photo")
    }
}
