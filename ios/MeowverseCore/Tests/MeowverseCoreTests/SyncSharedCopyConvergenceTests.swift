import Foundation
import Testing
@testable import MeowverseCore

/// Random edits on three devices where photos also travel as the app's own stored copies
/// (「分享原文件」 hands one out byte for byte and another device imports it): every device
/// ends with the same home, each stored file shown once, and a device that joins later agrees.
/// The other convergence suites import distinct bytes only, so they never make two records of
/// one stored file (round-12 audit CLOUDKIT-1).
@Suite struct SyncSharedCopyConvergenceTests {
    /// Seeds kept after a sweep (see `sharedSweep`).
    @Test(arguments: [UInt64(1), 2, 3, 4, 5, 7])
    func randomEditsWithSharedCopiesConverge(seed: UInt64) async throws {
        let shared = try await Self.run(seed: seed, steps: 160)
        #expect(shared > 0, "the run made two records of one stored file")
    }

    /// `SYNC_SHARED_SWEEP=<n> swift test --filter sharedSweep` runs seeds 1...n; off by default.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SYNC_SHARED_SWEEP"] != nil))
    func sharedSweep() async throws {
        let count = UInt64(ProcessInfo.processInfo.environment["SYNC_SHARED_SWEEP"].flatMap(Int.init) ?? 0)
        let start = UInt64(ProcessInfo.processInfo.environment["SYNC_SHARED_SWEEP_START"].flatMap(Int.init) ?? 1)
        for seed in start..<(start + count) {
            try await Self.run(seed: seed, steps: 160, label: "seed \(seed)")
        }
    }

    /// What devices agree on: photos without their stored copy's own facts (`reducedFrom`, the
    /// Photos asset), which stay each device's.
    static func view(_ s: AppState) -> [String] {
        let photos = s.photos.map { p in
            "\(p.photoId) fav=\(p.favorite) note='\(p.note)' day=\(p.captureDate ?? "-")/\(p.captureDateSource.rawValue) "
                + "exif=\(p.exifCaptureDate ?? "-") file=\(p.filename ?? "-") imported=\(p.importedAt.timeIntervalSince1970)"
        }.sorted()
        let shared = SyncCheck.view(s)
        return photos + ["--"] + shared.items + ["--"] + shared.storage + ["--"] + shared.observations
    }

    /// Returns how many photos the records hold under more than one record, live at the end.
    @discardableResult
    static func run(seed: UInt64, steps: Int, label: String = "") async throws -> Int {
        var rng = SeededRandom(seed: seed)
        let clock = SyncTestClock()
        let cloud = SyncMemoryCloud(seed: seed)
        await cloud.setMessyDelivery(true)
        var devices: [SyncDevice] = []
        for (name, skew) in [("A", 0.0), ("B", 5.0), ("C", -7.0)] {
            devices.append(try await SyncDevice(name, cloud: cloud, clock: clock, skew: skew))
        }
        var drafts: [Int: ImportDraft] = [:]
        func wide(_ n: Int) throws -> ImportDraft {
            if let made = drafts[n] { return made }
            let made = try SyncCheck.wideDraft(seed: 40 + n, maxPixel: 2048)
            drafts[n] = made
            return made
        }
        for _ in 0..<steps {
            clock.advance(Double(Int.random(in: 0...3, using: &rng)))
            let device = devices.randomElement(using: &rng)!
            let state = await device.state()
            let photo = state.photos.randomElement(using: &rng)
            let piece = state.allFurniture.randomElement(using: &rng)
            switch Int.random(in: 0..<14, using: &rng) {
            case 0, 1:
                _ = try? await device.store.importPhoto(draft: try wide(Int.random(in: 0..<6, using: &rng)))
            case 2, 3:
                // Another device's stored copy, imported here as a file of its own.
                let other = devices.filter { $0.name != device.name }.randomElement(using: &rng)!
                if let theirs = await other.state().photos.randomElement(using: &rng),
                   let url = await other.store.originalURL(photoId: theirs.photoId), let data = try? Data(contentsOf: url),
                   let shared = try? PhotoIngest.makeDraft(data: data, filename: "shared.jpg", reduce: true, maxPixel: 2048) {
                    _ = try? await device.store.importPhoto(draft: shared)
                }
            case 4:
                if let photo { _ = try? await device.store.editPhoto(photoId: photo.photoId, PhotoEdit(note: "n\(Int.random(in: 0..<50, using: &rng))")) }
            case 5:
                if let photo { _ = try? await device.store.setFavorite(photoIds: [photo.photoId], Bool.random(using: &rng)) }
            case 6:
                if let photo {
                    let change: PhotoEdit.DateChange = Bool.random(using: &rng) ? .set("2020-0\(Int.random(in: 1...9, using: &rng))-11") : .clear
                    _ = try? await device.store.editPhoto(photoId: photo.photoId, PhotoEdit(captureDate: change))
                }
            case 7:
                if let photo, Int.random(in: 0..<3, using: &rng) == 0 { try? await device.store.deletePhoto(photoId: photo.photoId) }
            case 8:
                _ = try? await device.store.addFurniture(placement: SyncCheck.spot(Int.random(in: 0..<12, using: &rng)),
                                                         displayName: "P\(Int.random(in: 0..<99, using: &rng))")
            case 9:
                if let photo, let piece {
                    if piece.sources.contains(where: { $0.photoId == photo.photoId }) {
                        _ = try? await device.store.unlinkPhoto(photoId: photo.photoId, fromInstance: piece.instanceId)
                    } else {
                        _ = try? await device.store.linkPhoto(photoId: photo.photoId, toInstance: piece.instanceId)
                    }
                }
            case 10:
                _ = try? await device.session.captureLocalEdits()
            default:
                _ = try await device.sync()
            }
        }

        try await settle(devices, label: label)
        try await expectConverged(devices, label: label)
        let joining = try await SyncDevice("Z", cloud: cloud, clock: clock, skew: 3)
        try await settle([joining] + devices, label: label)
        try await expectConverged([joining] + devices, label: label)
        let replica = try #require(try await joining.session.deviceState()?.replica)
        return SyncPhotoGroups(replica).groups.filter { $0.members.count > 1 }.count
    }

    static func settle(_ devices: [SyncDevice], label: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 1...12 {
            var changed = false
            for device in devices {
                let report = try await device.sync()
                if report.applied || report.sent > 0 || report.received > 0 || report.unsent > 0 || report.problem != nil
                    || report.waitingForFiles > 0 { changed = true }
            }
            if !changed { return }
        }
        Issue.record("\(label) did not settle in 12 rounds", sourceLocation: sourceLocation)
    }

    static func expectConverged(_ devices: [SyncDevice], label: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var views: [[String]] = []
        for device in devices {
            let state = await device.state()
            #expect(LibraryStore.isConsistent(state), "\(label) \(device.name) is consistent", sourceLocation: sourceLocation)
            let report = try await device.sync()
            #expect(report.heldBack.isEmpty && !report.applied && report.unsent == 0,
                    "\(label) \(device.name) still changing or holding back \(report.heldBack)", sourceLocation: sourceLocation)
            views.append(view(state))
        }
        for (index, other) in views.enumerated().dropFirst() where other != views[0] {
            Issue.record("\(label) \(devices[index].name) differs from \(devices[0].name):\n\(views[0].joined(separator: "\n"))\n---\n\(other.joined(separator: "\n"))",
                         sourceLocation: sourceLocation)
        }
    }
}
