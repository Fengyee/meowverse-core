import Foundation
import Testing
@testable import MeowverseCore

/// QA round 12, task B, second iteration: adversarial cases against 9e0f732, aimed at the rules
/// it added. Deleted records rejoin a shared copy's group when their `tomb.at` equals a live
/// member's; a group with a record this build cannot read stays as this device has it; one
/// record out of range in `sync-state.json` is held back by itself; the safety net tries each
/// stage from all records; the clock adopts no stamp past `SyncClock.ceiling`; quarantined
/// records get their own wording, not "from a newer version".
@Suite struct QARound12Iter2Tests {
    let clock = SyncTestClock()

    /// A's stored copy, handed out byte for byte (「分享原文件」) and imported elsewhere whole.
    static func share(_ a: SyncDevice) async throws -> ImportDraft {
        let mine = try #require(await a.state().photos.first { $0.reducedFrom != nil })
        let url = try #require(await a.store.originalURL(photoId: mine.photoId))
        let shared = try PhotoIngest.makeDraft(data: try Data(contentsOf: url), filename: "shared.jpg", reduce: true, maxPixel: 2048)
        try #require(shared.sha256 == mine.sha256 && shared.reducedFrom == nil)
        return shared
    }

    /// Saves a version over whatever the cloud holds, as some other device would.
    static func overwrite(_ cloud: SyncMemoryCloud, _ envelope: SyncEnvelope) async throws {
        let endpoint = cloud.endpoint("N")
        let first = try await endpoint.save([SyncSave(envelope: envelope, baseTag: nil)])
        guard case .conflict(let server)? = first.first else { return }
        let again = try await endpoint.save([SyncSave(envelope: envelope, baseTag: server.tag)])
        guard case .saved? = again.first else { Issue.record("not saved: \(again)"); return }
    }

    // MARK: Rejoining by equal tomb.at

    /// Control for the next test: one photo, one record, the same three devices and the same two
    /// deletions. The unseen edit brings the record back with everything it held.
    @Test func controlOneRecordTwoDeletionsComesBackWhole() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        let b = try await SyncDevice("B", cloud: cloud, clock: clock)
        let c = try await SyncDevice("C", cloud: cloud, clock: clock)
        _ = try await a.store.importPhotos([try SyncCheck.wideDraft(seed: 1, maxPixel: 2048)])
        try await SyncCheck.settle([a, b, c])
        clock.advance()
        _ = try await a.store.editPhoto(photoId: try await a.onlyPhoto().photoId, PhotoEdit(favorite: true, captureDate: .set("2020-01-02")))
        try await SyncCheck.settle([a, b])
        clock.advance()
        try await a.store.deletePhotos(photoIds: [try await a.onlyPhoto().photoId])
        try await a.session.captureLocalEdits()
        try await a.sync()
        clock.advance()
        try await c.store.deletePhotos(photoIds: [try await c.onlyPhoto().photoId])
        try await c.session.captureLocalEdits()
        try await c.sync()
        clock.advance()
        _ = try await b.store.editPhoto(photoId: try await b.onlyPhoto().photoId, PhotoEdit(note: "unseen"))
        try await SyncCheck.settle([a, b, c])
        for device in [a, b, c] {
            let p = try await device.onlyPhoto()
            #expect(p.note == "unseen" && p.favorite && p.captureDate == "2020-01-02" && p.captureDateSource == .user, "\(device.name)")
        }
    }

    /// The rejoin rule assumes one deletion tombs every record of the group with one `tomb.at`.
    /// Two deletions do not: A deletes the shared photo (both records, at T_A); C, which synced
    /// before B's import and so only knows A's record, deletes its photo a little later (A's
    /// record only, at T_C; the join keeps the later `at`). Now A's record says T_C, B's T_A. B
    /// had seen neither and edits the note, which revives B's own record; A's record (holding
    /// the confirmed day and the favourite) does not rejoin, because its `at` differs. The photo
    /// comes back, as in the control, but with the day falling back to the file's.
    @Test(arguments: [("A", "B"), ("B", "A")])
    func twoDeletionsThenAnUnseenEditBringTheSharedPhotoBackWhole(_ names: (String, String)) async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice(names.0, cloud: cloud, clock: clock)
        let b = try await SyncDevice(names.1, cloud: cloud, clock: clock)
        let c = try await SyncDevice("C", cloud: cloud, clock: clock)
        _ = try await a.store.importPhotos([try SyncCheck.wideDraft(seed: 1, maxPixel: 2048)])
        let shared = try await Self.share(a)
        try await a.sync()
        try await c.sync()
        try #require(await c.state().photos.count == 1, "C has A's photo, before B's record exists")
        clock.advance()
        _ = try await b.store.importPhotos([shared])
        try await SyncCheck.settle([a, b])
        clock.advance()
        _ = try await a.store.editPhoto(photoId: try await a.onlyPhoto().photoId, PhotoEdit(favorite: true, captureDate: .set("2020-01-02")))
        try await SyncCheck.settle([a, b])
        let before = try await b.onlyPhoto()
        try #require(before.favorite && before.captureDate == "2020-01-02")
        clock.advance()
        try await a.store.deletePhotos(photoIds: [try await a.onlyPhoto().photoId])
        try await a.session.captureLocalEdits()
        try await a.sync()
        clock.advance()
        try await c.store.deletePhotos(photoIds: [try await c.onlyPhoto().photoId])
        try await c.session.captureLocalEdits()
        try await c.sync()
        clock.advance()
        _ = try await b.store.editPhoto(photoId: before.photoId, PhotoEdit(note: "unseen"))
        try await SyncCheck.settle([a, b, c])
        for device in [a, b, c] {
            let p = try await device.onlyPhoto()
            #expect(p.note == "unseen", "\(device.name)")
            #expect(p.favorite, "\(device.name) [\(names.0)/\(names.1)]: favourite lost")
            #expect(p.captureDate == "2020-01-02" && p.captureDateSource == .user,
                    "\(device.name) [\(names.0)/\(names.1)]: confirmed day lost, shows \(p.captureDate ?? "-")/\(p.captureDateSource)")
        }
    }

    /// Four devices. C imports O with the photo-library link (a 1024 copy S); B imports A's
    /// 2048 copy R as a source of its own and writes a note on it; D sees two photos (S and R
    /// are different files) and deletes both in one go: one capture, one stamp, so both
    /// records get the same `tomb.at`. A had imported O (copy R) before any of that reached it
    /// and syncs only now: its version of O's record, adding R, was never seen by D's deletion
    /// and brings O back (§4). B's record, deleted as its own photo, should stay deleted, as in
    /// `aPhotoDeletedOnItsOwnDoesNotLendItsNoteToALaterImportOfItsCopy`; with equal `tomb.at`
    /// it rejoins and lends its note to the photo that came back, on A too, which never had it.
    /// `separately: true` deletes the two photos in two captures (two stamps): the control.
    @Test(arguments: [true, false])
    func aBatchDeletionDoesNotLendADeletedPhotosNoteToOneThatComesBack(separately: Bool) async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        let b = try await SyncDevice("B", cloud: cloud, clock: clock)
        let c = try await SyncDevice("C", cloud: cloud, clock: clock)
        let d = try await SyncDevice("D", cloud: cloud, clock: clock)
        try await a.sync()
        _ = try await c.store.importPhotos([try SyncCheck.wideDraft(seed: 1, maxPixel: 1024)])
        try await c.sync()
        clock.advance()
        _ = try await a.store.importPhotos([try SyncCheck.wideDraft(seed: 1, maxPixel: 2048)])
        try await a.session.captureLocalEdits()
        let shared = try await Self.share(a)
        _ = try await b.store.importPhotos([shared])
        try await b.sync()
        clock.advance()
        let onB = try #require(await b.state().photos.first { $0.sha256 == shared.sha256 })
        _ = try await b.store.editPhoto(photoId: onB.photoId, PhotoEdit(note: "B's note"))
        try await b.sync()
        try await d.sync()
        let onD = await d.state().photos
        try #require(onD.count == 2, "D shows S and R as two photos")
        clock.advance()
        if separately {
            for photo in onD {
                try await d.store.deletePhotos(photoIds: [photo.photoId])
                try await d.session.captureLocalEdits()
                clock.advance()
            }
        } else {
            try await d.store.deletePhotos(photoIds: onD.map(\.photoId))
            try await d.session.captureLocalEdits()
        }
        clock.advance()
        try await SyncCheck.settle([a, b, c, d])
        for device in [a, b, c, d] {
            let photos = await device.state().photos
            #expect(photos.count == 1, "\(device.name): O comes back")
            #expect(photos.allSatisfy { $0.note.isEmpty }, "\(device.name) [separately \(separately)]: shows '\(photos.map(\.note))'")
        }
    }

    // MARK: Wording: what "from a newer version" counts

    /// The shared copy settled, then A's record rewritten in this build's format with one stamp
    /// out of range. That record is quarantined ("couldn't be read"); B's own record is held
    /// with it as a group, but only in `heldBack`. The app counts `heldBack` minus
    /// `quarantined` as "N items come from a newer version of Meowverse; update the app to sync
    /// them" (`AppModel+ICloudSync`), which no update would fix here.
    @Test func aRecordHeldWithAnOutOfRangePartnerIsNotSaidToBeFromANewerVersion() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        let b = try await SyncDevice("B", cloud: cloud, clock: clock)
        _ = try await a.store.importPhotos([try SyncCheck.wideDraft(seed: 1, maxPixel: 2048)])
        let shared = try await Self.share(a)
        try await a.sync()
        clock.advance()
        _ = try await b.store.importPhotos([shared])
        try await SyncCheck.settle([a, b])
        let mine = try await a.onlyPhoto()
        let name = SyncRecord.photoName(try #require(mine.reducedFrom).sha256)
        guard case .photo(var hostile)? = try await a.session.deviceState()?.replica[name] else {
            Issue.record("no record \(name)"); return
        }
        hostile.note = SyncRegister("hostile", SyncStamp(wall: SyncClock.millis(clock.now), counter: 1 << 61, device: "zz"))
        try await Self.overwrite(cloud, try SyncEnvelope(.photo(hostile)))
        clock.advance()
        let report = try await b.sync()
        #expect(report.quarantined.contains(name))
        let saidNewer = Set(report.heldBack).subtracting(report.quarantined)
        #expect(saidNewer.isEmpty, "the app would say \(saidNewer.count) item(s) come from a newer version: \(saidNewer.sorted())")
    }

    /// docs/ICLOUD_SYNC.md §9: "新版本写的更高 format 或未知类型，旧版本原样保存". A record type this
    /// build does not know is from a newer version even at format 1 (a new type starts at 1),
    /// so the app should say "update the app", not "couldn't be read or doesn't match".
    @Test func anUnknownRecordTypeIsFromANewerVersion() throws {
        var replica = SyncReplica()
        replica.merge(SyncEnvelope(type: "MVSticker", name: "sticker.s1", format: SyncEnvelope.currentFormat, payload: Data("{}".utf8)))
        let result = SyncProjection.project(replica, local: AppState.empty)
        #expect(result.heldBack == ["sticker.s1"])
        #expect(result.quarantined.isEmpty, "said as unreadable here: \(result.quarantined)")
    }

    // MARK: The safety net

    /// A fault that comes with a remote edit to a photo this device already has (its record
    /// only; the stand-in fault fires on that note). No stage holds records of photos already
    /// here unless they clash, so every stage fails and the last resort holds everything: the
    /// new photo and the piece from elsewhere, which have nothing to do with it, never arrive.
    @Test func aFaultInAPhotoAlreadyHereDoesNotHoldBackEverythingElse() async throws {
        let (local, replica, downloaded, mine, fresh) = try await SyncQuarantineTests().setUp()
        let result = SyncProjection.project(replica, local: local, downloaded: downloaded,
                                            fault: { $0.photos.contains { $0.note == "from elsewhere" } ? "note" : nil })
        #expect(result.quarantined == [mine], "held: \(result.quarantined)")
        #expect(!result.quarantined.contains(fresh))
        #expect(SyncQuarantineTests.has(result.state, photo: "elsewhere"), "the unrelated photo comes in")
        #expect(SyncQuarantineTests.hasPiece(result.state), "the unrelated piece comes in")
    }

    /// A stage only helps if the fault goes away; check the narrowest stage that suffices is the
    /// one used, and that the user's own photo keeps its local note when its record is held.
    @Test func aClashIsHeldAloneAndThePhotoKeepsWhatThisDeviceHas() async throws {
        let (local, replica, downloaded, _, fresh) = try await SyncQuarantineTests().setUp()
        let result = SyncProjection.project(replica, local: local, downloaded: downloaded,
                                            fault: { $0.photos.contains { $0.photoId == "elsewhere" } ? "fresh" : nil })
        #expect(result.quarantined == [fresh])
        #expect(result.state.photos.first?.note == "from elsewhere", "the photo here still takes its record's note")
        #expect(SyncQuarantineTests.hasPiece(result.state))
    }

    // MARK: The clock

    /// Normal clocks are untouched by the ceiling: a tick passes every honest stamp seen, a
    /// clock ahead by years included, and a stamp just under the ceiling.
    @Test func honestStampsAreStillPassed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for seen in [SyncStamp(wall: SyncClock.millis(now) + 5_000, counter: 3, device: "zz"),
                     SyncStamp(wall: SyncClock.millis(now) + 10 * 365 * 86_400_000, counter: 0, device: "zz"),
                     SyncStamp(wall: .max - 1, counter: SyncStamp.maxCounter, device: "zz"),
                     SyncStamp(wall: .max, counter: SyncStamp.maxCounter / 2 - 1, device: "zz")] {
            var clock = SyncClock(device: "a")
            _ = clock.tick(now: now)
            clock.observe(seen)
            let next = clock.tick(now: now)
            #expect(next > seen, "\(next) after \(seen)")
            let after = clock.tick(now: now)
            #expect(after > next)
        }
    }

    /// Past the ceiling, ticks still move, each after the one before.
    @Test func ticksKeepMovingPastTheCeiling() {
        var clock = SyncClock(device: "a")
        clock.observe(SyncStamp(wall: .max, counter: SyncStamp.maxCounter, device: "zz"))
        var last = clock.tick(now: Date(timeIntervalSince1970: 1_800_000_000))
        for _ in 0..<5 {
            let next = clock.tick(now: Date(timeIntervalSince1970: 1_800_000_000))
            #expect(next > last)
            last = next
        }
    }

    /// The ceiling applies when a stamp is observed. A clock stored in `sync-state.json` by 66c1994
    /// (which adopted any readable stamp, the top one included) still has `last` at the top
    /// after the upgrade, and every tick returns that same stamp.
    @Test func aClockStoredAtTheTopStillMovesAfterTheUpgrade() throws {
        let json = #"{"device":"a","last":{"w":9223372036854775807,"c":1152921504606846976,"d":"a"}}"#
        var clock = try SyncCoding.decoder().decode(SyncClock.self, from: Data(json.utf8))
        let first = clock.tick(now: Date(timeIntervalSince1970: 1_800_000_000))
        let second = clock.tick(now: Date(timeIntervalSince1970: 1_800_000_001))
        #expect(second > first, "\(first) then \(second)")
    }

    // MARK: One record out of range in sync-state.json

    /// An earlier build (no range check) merged a version with one stamp out of range into a
    /// piece that held this device's unsent rename. After the upgrade the file reads and that
    /// record alone is held back, as 9e0f732 intends; but the record as a whole, the rename
    /// in it included, is now only an unreadable envelope. The send step drops the name from
    /// `dirty` without sending it, and when another device's later readable version arrives it
    /// replaces the held one: the rename, the newest edit of the name anywhere, is gone on
    /// every device, unsaid.
    /// `merged: false` is the control: the same versions, but A never merged the odd one.
    @Test(arguments: [true, false])
    func anUnsentRenameInARecordHeldFromTheSyncFileIsNotLost(merged: Bool) async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        let b = try await SyncDevice("B", cloud: cloud, clock: clock)
        let chair = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: 9), placement: SyncCheck.chair,
                                                         displayName: "Chair", decision: .manual)
        try await SyncCheck.settle([a, b])
        let name = "furniture.\(chair.instanceId)"
        guard case .furniture(let synced)? = try await b.session.deviceState()?.replica[name] else {
            Issue.record("no record"); return
        }
        // Another device writes a version with a stamp out of range; A, on the earlier build,
        // merges it into its record, which already holds A's rename, not yet sent.
        var hostile = synced
        let w = SyncClock.millis(clock.now)
        hostile.tags = SyncRegister(["odd"], SyncStamp(wall: w, counter: 1 << 61, device: "zz"))
        clock.advance()
        _ = try await a.store.rename(instanceId: chair.instanceId, displayName: "Mine")
        try await a.session.captureLocalEdits()
        let (_, generation) = try await a.store.syncSnapshot()
        var device = try #require(try await a.session.deviceState())
        try #require(device.dirty.contains(name))
        if merged {
            device.replica.merge(.furniture(hostile))
            try await a.store.writeSyncState(try device.encoded(), generation: generation)
        }
        // That device later edits the tags again (a later wall time beats the odd stamp), so
        // its next version is readable. It never saw A's rename.
        clock.advance()
        var later = hostile
        later.tags = SyncRegister(["fixed"], SyncStamp(wall: SyncClock.millis(clock.now), counter: 0, device: "zz"))
        try await Self.overwrite(cloud, try SyncEnvelope(.furniture(later)))
        clock.advance()
        try await SyncCheck.settle([a, b])
        for device in [a, b] {
            let piece = try #require(await device.state().items.first { $0.instanceId == chair.instanceId })
            #expect(piece.displayName == "Mine", "\(device.name) [merged \(merged)] shows '\(piece.displayName)'")
        }
    }
}
