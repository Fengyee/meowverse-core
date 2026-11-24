import Foundation
import Testing
@testable import MeowverseCore

/// QA round 12, task B, third iteration: adversarial cases against 6a42635, aimed at what it
/// added. A deletion of a shared photo names the records it tombed together
/// (`SyncTombstone.together`) and a deleted record rejoins the live record its list names; the
/// field is added without a format bump; the safety net tries every combination of four kinds;
/// counters out of range in `sync-state.json` are clamped to `SyncStamp.maxCounter`.
@Suite struct QARound12Iter3Tests {
    let clock = SyncTestClock()
    static let s = SyncStamp(wall: 1_800_000_000_000, counter: 0, device: "x")

    static func file(_ c: Character, from source: Character? = nil) -> SyncFileInfo {
        SyncFileInfo(sha256: String(repeating: c, count: 64), mimeType: "image/jpeg", ext: "jpg", byteSize: 10, width: 4, height: 2,
                     reducedFrom: source.map { ReducedFrom(sha256: String(repeating: $0, count: 64), byteSize: 99, width: 8, height: 4) })
    }

    static func hex(_ i: Int) -> String {
        let h = String(i, radix: 16)
        return String(repeating: "0", count: 64 - h.count) + h
    }

    static func name(_ r: PhotoSyncRecord) -> String { SyncRecord.photoName(r.sourceHash) }

    static func photoRecord(_ device: SyncDevice, _ name: String) async throws -> PhotoSyncRecord? {
        guard case .photo(let r)? = try await device.session.deviceState()?.replica[name] else { return nil }
        return r
    }

    // MARK: Lists that name what was not deleted with the record

    /// Only a hostile or broken writer names a record the deleted one never shared a copy with;
    /// no build does. The rule rejoins by name alone (9e0f732 still asked for a shared copy), so
    /// one deleted record whose list names every photo glues itself to the first live one it
    /// names: that photo takes the planted note and favourite, the planted id (smallest of the
    /// group) and the planted record's copy, none of which belong to it.
    @Test func aDeletionListNamingAnUnrelatedPhotoLendsItNothing() throws {
        let mine = SyncMergeTests.photo(ids: ["p-mine"], file: Self.file("a"), at: Self.s, note: "mine")
        let later = SyncStamp(wall: Self.s.wall + 100, counter: 0, device: "zz")
        var planted = SyncMergeTests.photo(ids: ["a-planted"], file: Self.file("b"), at: later, note: "planted", favorite: true)
        planted.tomb = SyncTombstone(seen: planted.version, at: later,
                                     together: [Self.name(planted), Self.name(mine), "photo.never-existed"].sorted())
        var replica = SyncReplica()
        replica.merge(.photo(mine))
        replica.merge(.photo(planted))
        let groups = SyncPhotoGroups(replica)
        let group = try #require(groups.groups.first { $0.members.contains { $0.sourceHash == mine.sourceHash } })
        #expect(group.members.count == 1, "joined by name alone: \(group.members.map(Self.name))")
        let staged = SyncIncomingFile(info: Self.file("a"), stagedFile: "sync-incoming/a", stagedThumbnail: "sync-incoming/a.jpg")
        let shown = try #require(SyncProjection.project(replica, local: AppState.empty, downloaded: [Self.file("a").sha256: staged]).state.photos.first)
        #expect(shown.photoId == "p-mine" && shown.note == "mine" && !shown.favorite,
                "shows id \(shown.photoId), note '\(shown.note)', favourite \(shown.favorite)")
    }

    // MARK: The no-format-bump argument

    /// docs/ICLOUD_SYNC.md §9 argues an older build "drops the list only from a record it writes,
    /// which is then live again". An older build also deletes: one that brought B's record back
    /// with an edit of its own (here: a confirmed day, X) and later deletes the photo writes a
    /// dead record without the list. The cloud keeps that version; devices that had read the
    /// list keep it (a join), devices that read only the cloud's version never see it. When C,
    /// which had seen none of this, edits the photo and brings it back, A and B rejoin B's
    /// record (X's later day) and C and a new device D do not (A's earlier day): the devices
    /// disagree on the photo's confirmed day for good.
    @Test(arguments: [("A", "B"), ("B", "A")])
    func anOlderBuildsDeletionDoesNotSplitWhatDevicesShow(_ names: (String, String)) async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice(names.0, cloud: cloud, clock: clock)
        let b = try await SyncDevice(names.1, cloud: cloud, clock: clock)
        let c = try await SyncDevice("C", cloud: cloud, clock: clock)
        _ = try await a.store.importPhotos([try SyncCheck.wideDraft(seed: 1, maxPixel: 2048)])
        let shared = try await QARound12Iter2Tests.share(a)
        let origin = try #require(try await a.onlyPhoto().reducedFrom).sha256
        let nameO = SyncRecord.photoName(origin), nameR = SyncRecord.photoName(shared.sha256)
        try await a.sync()
        clock.advance()
        _ = try await b.store.importPhotos([shared])
        try await SyncCheck.settle([a, b, c])
        clock.advance()
        _ = try await a.store.editPhoto(photoId: try await a.onlyPhoto().photoId, PhotoEdit(favorite: true, captureDate: .set("2020-01-02")))
        try await SyncCheck.settle([a, b])
        let beforeDeletion = try #require(try await Self.photoRecord(c, nameR), "C holds B's record as it was")
        clock.advance()
        try await a.store.deletePhotos(photoIds: [try await a.onlyPhoto().photoId])
        try await SyncCheck.settle([a, b])
        let deleted = try #require(try await Self.photoRecord(b, nameR))
        try #require(deleted.tomb?.together == [nameO, nameR].sorted(), "the group deletion names both")

        // X, an older build that had not seen the deletion, confirms another day on B's record
        // and saves it over the cloud's version, read without the list (the key is dropped).
        clock.advance()
        let tX = SyncStamp(wall: SyncClock.millis(clock.now), counter: 0, device: "devX")
        var x = beforeDeletion
        x.date = SyncRegister(.user("2021-03-04"), tX)
        x.edits.add(tX)
        var server = deleted
        server.tomb?.together = nil
        x = x.joined(server)
        try #require(SyncRecord.photo(x).isLive)
        try await QARound12Iter2Tests.overwrite(cloud, try SyncEnvelope(.photo(x)))
        try await SyncCheck.settle([a, b])
        let back = try await a.onlyPhoto()
        try #require(back.captureDate == "2021-03-04", "the photo came back with X's day")

        // X deletes the photo: its own record only (it does not group), written without the list.
        clock.advance()
        let tX2 = SyncStamp(wall: SyncClock.millis(clock.now), counter: 0, device: "devX")
        var again = try #require(try await Self.photoRecord(b, nameR))
        again.tomb?.together = nil
        again = x.joined(again)
        again.tomb = SyncTombstone.join(again.tomb, SyncTombstone(seen: again.version, at: tX2))
        try await QARound12Iter2Tests.overwrite(cloud, try SyncEnvelope(.photo(again)))
        try await SyncCheck.settle([a, b])
        try #require(await a.state().photos.isEmpty)
        try #require(await b.state().photos.isEmpty)

        let d = try await SyncDevice("D", cloud: cloud, clock: clock)
        try await d.sync()
        // C had seen none of it, and edits the note: a write the deletions never saw (§4).
        clock.advance()
        _ = try await c.store.editPhoto(photoId: try await c.onlyPhoto().photoId, PhotoEdit(note: "from C"))
        try await c.session.captureLocalEdits()
        try #require(try await c.session.deviceState()?.dirty.contains(nameO) == true, "C writes A's record")
        try await SyncCheck.settle([a, b, c, d])
        var shown: [String: String] = [:]
        for device in [a, b, c, d] {
            let photos = await device.state().photos
            shown[device.name] = photos.map { "fav=\($0.favorite) day=\($0.captureDate ?? "-")/\($0.captureDateSource.rawValue)" }.joined()
        }
        #expect(Set(shown.values).count == 1, "devices disagree: \(shown.sorted { $0.key < $1.key })")
    }

    // MARK: A deletion that could not tomb every record

    /// B confirms a day and favourites the shared photo (its own record R); A's record O then
    /// arrives in a newer format, which B holds. B deletes the photo: only R can be written, and
    /// a list of one is no list. A newer build that reads both shows O, still live, and R, dead
    /// and naming nothing, so it does not rejoin: the photo stays on that device, but the day
    /// and favourite B gave it are gone. Naming the partner it could not write would keep the
    /// photo whole while it stays.
    @Test func aDeletionThatCannotTombThePartnerLeavesThePhotoWhole() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        let b = try await SyncDevice("B", cloud: cloud, clock: clock)
        _ = try await a.store.importPhotos([try SyncCheck.wideDraft(seed: 1, maxPixel: 2048)])
        let shared = try await QARound12Iter2Tests.share(a)
        let nameO = SyncRecord.photoName(try #require(try await a.onlyPhoto().reducedFrom).sha256)
        let nameR = SyncRecord.photoName(shared.sha256)
        try await a.sync()
        clock.advance()
        _ = try await b.store.importPhotos([shared])
        try await SyncCheck.settle([a, b])
        clock.advance()
        _ = try await b.store.editPhoto(photoId: try await b.onlyPhoto().photoId, PhotoEdit(favorite: true, captureDate: .set("2021-03-04")))
        try await SyncCheck.settle([a, b])
        try #require(try await a.onlyPhoto().favorite)
        let o = try #require(try await Self.photoRecord(a, nameO))
        let tag = try #require(try await a.session.deviceState()?.tags[nameO])
        _ = try await cloud.endpoint("N").save([SyncSave(envelope: SyncEnvelope(type: "MVPhoto", name: nameO, format: SyncEnvelope.currentFormat + 1,
                                                                                 payload: Data("{}".utf8)), baseTag: tag)])
        try await b.sync()
        clock.advance()
        try await b.store.deletePhotos(photoIds: [try await b.onlyPhoto().photoId])
        try await b.sync()
        let r = try #require(try await Self.photoRecord(b, nameR))
        try #require(!SyncRecord.photo(r).isLive)
        var newer = SyncReplica()
        newer.merge(.photo(o))
        newer.merge(.photo(r))
        let group = try #require(SyncPhotoGroups(newer).groups.first { $0.members.contains { $0.sourceHash == o.sourceHash } })
        #expect(group.merged.favorite.value && group.merged.date.value == .user("2021-03-04"),
                "the photo stays, without B's day and favourite: together \(r.tomb?.together ?? [])")
    }

    // MARK: Membership that changes after the deletion

    /// The shared photo, with a note, a favourite and a confirmed day, is deleted on A (both
    /// records, one list). Later C, which has synced and seen the deletion, imports the same
    /// bytes again (the share it kept, or the original). The record that comes back is a fresh
    /// import; the other rejoins it through the list, but none of the deleted photo's values come
    /// back, on any device. (A control: passes on 6a42635.)
    @Test(arguments: [true, false])
    func aCopyImportedAgainAfterTheGroupDeletionIsANewPhoto(theShare: Bool) async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        let b = try await SyncDevice("B", cloud: cloud, clock: clock)
        let c = try await SyncDevice("C", cloud: cloud, clock: clock)
        _ = try await a.store.importPhotos([try SyncCheck.wideDraft(seed: 1, maxPixel: 2048)])
        let shared = try await QARound12Iter2Tests.share(a)
        try await a.sync()
        clock.advance()
        _ = try await b.store.importPhotos([shared])
        try await SyncCheck.settle([a, b])
        clock.advance()
        _ = try await a.store.editPhoto(photoId: try await a.onlyPhoto().photoId,
                                        PhotoEdit(favorite: true, note: "deleted with it", captureDate: .set("2020-01-02")))
        try await SyncCheck.settle([a, b])
        clock.advance()
        try await a.store.deletePhotos(photoIds: [try await a.onlyPhoto().photoId])
        try await SyncCheck.settle([a, b, c])
        try #require(await c.state().photos.isEmpty)
        clock.advance()
        _ = try await c.store.importPhotos([theShare ? shared : try SyncCheck.wideDraft(seed: 1, maxPixel: 2048)])
        try await SyncCheck.settle([a, b, c])
        for device in [a, b, c] {
            let photos = await device.state().photos
            #expect(photos.count == 1, "\(device.name)")
            #expect(photos.allSatisfy { $0.note.isEmpty && !$0.favorite && $0.captureDateSource != .user },
                    "\(device.name) [share \(theShare)]: \(photos.map { "'\($0.note)' \($0.favorite) \($0.captureDate ?? "-")/\($0.captureDateSource)" })")
        }
        // The stored copy's own history (`src` in the view) stays each device's; the rest agrees.
        var views: [String] = []
        for device in [a, b, c] {
            views.append(SyncCheck.view(await device.state()).photos
                .map { $0.replacingOccurrences(of: #"src=\w+ "#, with: "", options: .regularExpression) }.joined())
        }
        #expect(Set(views).count == 1, "\(views)")
    }

    // MARK: Counters clamped when reading sync-state.json

    /// An earlier build without the range check adopted a planted stamp at the last wall time
    /// with a counter past `maxCounter`; every stamp it wrote afterwards is there too. Its own
    /// deletion of a photo and then its re-import (an edit after the deletion) differ only in
    /// counters past the limit. Clamped to `maxCounter`, both become the same stamp: the
    /// deletion now covers the re-import, and the photo the user imported again is deleted.
    @Test func clampingDoesNotMakeALaterEditLookSeenByAnEarlierDeletion() throws {
        let deletedAt = SyncStamp(wall: .max, counter: (1 << 61) + 1, device: "devA")
        let reimported = SyncStamp(wall: .max, counter: (1 << 61) + 2, device: "devA")
        var record = SyncMergeTests.photo(ids: ["p"], file: Self.file("a"), at: Self.s)
        record.tomb = SyncTombstone(seen: record.version.joined(SyncVersion([deletedAt])), at: deletedAt)
        record.edits.add(reimported)
        try #require(SyncRecord.photo(record).isLive, "the re-import was not seen by the deletion")
        let envelope = try SyncEnvelope(.photo(record))
        try #require(envelope.decoded() == nil)
        let clamped = try #require(envelope.decodedClampingCounters())
        #expect(clamped.isLive, "after clamping the deletion covers the later re-import")
    }

    /// The same earlier build renamed a piece after adopting that stamp (unsent). After the
    /// upgrade the rename is clamped to the largest readable stamp, `(max, maxCounter)`. The
    /// clock, stored at the same place, moves on from `SyncClock.ceiling`, 2^59 below it: the
    /// user's next rename on this device, and any other device's that has seen the clamped one,
    /// loses to it. The name can no longer be changed anywhere.
    @Test func aRenameAfterTheUpgradeWinsOverTheClampedOne() throws {
        let old = SyncStamp(wall: .max, counter: (1 << 61) + 1, device: "devA")
        var piece = SyncMergeTests.furniture(Self.s, name: "Before")
        piece.name = SyncRegister("Before", old)
        piece.edits.add(old)
        let clamped = try #require(try SyncEnvelope(.furniture(piece)).decodedClampingCounters())
        guard case .furniture(let read) = clamped else { Issue.record("not a piece"); return }
        let json = #"{"device":"devA","last":{"w":9223372036854775807,"c":\#((1 << 61) + 1),"d":"devA"}}"#
        var mine = try SyncCoding.decoder().decode(SyncClock.self, from: Data(json.utf8))
        let next = mine.tick(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(next > read.name.stamp, "this device's next rename \(next) loses to \(read.name.stamp)")
        var other = SyncClock(device: "devB")
        other.observe(read.name.stamp)
        let theirs = other.tick(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(theirs > read.name.stamp, "another device's rename after seeing it, \(theirs), loses to \(read.name.stamp)")
    }

    // MARK: Cost (QA_TIMING=1)

    /// The worst case of the safety net: a fault nothing clears, so the projection builds the
    /// library 1 + 15 times (clashing stays empty here). And grouping with a planted list of the
    /// largest size on every deleted record.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QA_TIMING"] == "1"), arguments: [500, 2000])
    func timing(photos count: Int) throws {
        var replica = SyncReplica()
        var downloaded: [String: SyncIncomingFile] = [:]
        for i in 0..<count {
            let info = SyncFileInfo(sha256: Self.hex(i), mimeType: "image/jpeg", ext: "jpg", byteSize: 10, width: 4, height: 2, reducedFrom: nil)
            replica.merge(.photo(SyncMergeTests.photo(ids: ["p\(i)"], file: info, at: Self.s, note: "n\(i)")))
            downloaded[info.sha256] = SyncIncomingFile(info: info, stagedFile: "sync-incoming/\(i)", stagedThumbnail: "sync-incoming/\(i).jpg")
        }
        replica.merge(.furniture(SyncMergeTests.furniture(Self.s)))
        replica.merge(.room(RoomSyncRecord(roomId: "room-2", name: SyncRegister("Upstairs", Self.s), createdAt: nil, tomb: nil)))
        let clock = ContinuousClock()
        var first: SyncProjectionResult!
        // Half the photos are here already; the other half are new (every kind is non-empty).
        let half = downloaded.filter { Int($0.key, radix: 16)! % 2 == 0 }
        let once = clock.measure { first = SyncProjection.project(replica, local: AppState.empty, downloaded: half) }
        let local = first.state
        try #require(local.photos.count == count / 2)
        var calls = 0
        var held: SyncProjectionResult!
        let worst = clock.measure {
            held = SyncProjection.project(replica, local: local, downloaded: downloaded,
                                          fault: { calls += 1; return LibraryStore.consistencyFault($0) ?? "injected" })
        }
        #expect(held.state == local)
        // Every deleted record names every record (the limit is 1000).
        var listed = replica
        let all = replica.photos.map(Self.name).sorted()
        for i in 0..<(count / 2) {
            guard case .photo(var r) = replica[SyncRecord.photoName(Self.hex(i))] else { continue }
            r.tomb = SyncTombstone(seen: r.version, at: Self.s, together: Array(all.prefix(SyncTombstone.maxTogether)))
            listed.merge(.photo(r))
        }
        var groups: SyncPhotoGroups!
        let grouping = clock.measure { groups = SyncPhotoGroups(listed) }
        print("QA_TIMING photos=\(count) project once=\(once) all tries=\(worst) fault calls=\(calls) groups with 1000-name lists=\(grouping) (\(groups.groups.count) groups)")
    }
}
