import Foundation
import Testing
@testable import MeowverseCore

/// External audit 2026-11-24, work package M10: merges that converge and retries that are fair.
/// Small fixtures of mixed versions, no random sweep (docs/ICLOUD_SYNC.md §3, §4, §7, §9, §11).
@Suite struct SyncCRDTFairnessTests {
    let clock = SyncTestClock()

    // MARK: D24-04 — refetching unreadable records takes turns

    /// 51 records the engine delivered unreadable, the first 50 of them unreadable for good:
    /// the 51st still gets its turn on the next refetch, and every one does in time.
    @Test func recordsThatStayUnreadableDoNotStarveTheOnesAfterThem() {
        var mirror = CloudSyncMirror()
        let names = (0..<51).map { String(format: "photo.%03d", $0) }
        for name in names { mirror.noteUnfetched(name, tag: "t") }
        let first = mirror.unfetchedToRefetch(limit: 50)
        #expect(first == Array(names.prefix(50)))
        mirror.noteRefetched(first)   // all still unreadable: none leaves the list
        let second = mirror.unfetchedToRefetch(limit: 50)
        #expect(second.first == "photo.050", "the one after the first batch comes first")
        #expect(second.count == 50 && Set(second).count == 50)
        // Over two turns every name was asked for.
        #expect(Set(first).union(second) == Set(names))
        // The turn survives a relaunch (the mirror on disk), and a mirror from before reads.
        mirror.noteRefetched(second)
        let reread = CloudSyncMirror.decode(try! mirror.encoded())
        #expect(reread?.unfetchedToRefetch(limit: 50) == mirror.unfetchedToRefetch(limit: 50))
        var old = try! JSONSerialization.jsonObject(with: try! mirror.encoded()) as! [String: Any]
        old["refetchAfter"] = nil
        let older = CloudSyncMirror.decode(try! JSONSerialization.data(withJSONObject: old))
        #expect(older?.unfetchedToRefetch(limit: 50) == first)
        // Few enough for one call: all of them, in order; a reset starts from the first again.
        #expect(mirror.unfetchedToRefetch(limit: 60) == names)
        mirror.reset()
        #expect(mirror.refetchAfter == nil)
    }

    // MARK: C24-02 — an unnamed room is not a room that was not there

    /// The library's room has no name; another device named it and the name is in the records,
    /// but not yet in the library (the write was refused because the user was editing). The
    /// next capture must not take "still unnamed here" for this device renaming it back.
    @Test func anUnnamedRoomIsNotRenamedBackByARetry() throws {
        let theirs = SyncStamp(wall: 1_800_000_000_000, counter: 0, device: "devB")
        var replica = SyncReplica()
        replica.merge(.room(RoomSyncRecord(roomId: AppState.primaryRoomId, name: SyncRegister("Den", theirs), createdAt: nil, tomb: nil)))
        let unnamed = AppState(revision: 3, photos: [], observations: [], items: [], rooms: [Room(roomId: AppState.primaryRoomId)])
        var named = unnamed
        named.rooms = [Room(roomId: AppState.primaryRoomId, name: "Den")]
        var clock = SyncClock(device: "devA")
        let changed = SyncCapture.capture(base: unnamed, current: unnamed, projected: named, catalog: nil,
                                          into: &replica, clock: &clock, now: Date(timeIntervalSince1970: 1_800_000_100))
        #expect(!changed.contains("room.\(AppState.primaryRoomId)"))
        guard case .room(let room) = replica["room.\(AppState.primaryRoomId)"] else { Issue.record("no room record"); return }
        #expect(room.name.value == "Den")
        // A real clear of the name still goes: named before, unnamed now, named in the records.
        let cleared = SyncCapture.capture(base: named, current: unnamed, projected: named, catalog: nil,
                                          into: &replica, clock: &clock, now: Date(timeIntervalSince1970: 1_800_000_200))
        #expect(cleared.contains("room.\(AppState.primaryRoomId)"))
        guard case .room(let after) = replica["room.\(AppState.primaryRoomId)"] else { return }
        #expect(after.name.value == nil)
    }

    // MARK: C24-03 — a new piece that reuses a photo uses it

    /// A deletes a photo; B, not having heard, makes a new piece from the same photo (the store
    /// reuses the photo it has). The piece is a use of the photo the deletion never saw: the
    /// photo stays, with the link, on both devices, as for a link added to an existing piece.
    @Test func aNewPieceMadeFromAPhotoDeletedElsewhereKeepsThePhoto() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice("A", cloud: cloud, clock: clock)
        let b = try await QADevice("B", cloud: cloud, clock: clock)
        let draft = try TestSupport.draft(seed: 87)
        let photo = try await a.store.importPhoto(draft: draft).photo
        try await QACheck.settle([a, b])
        #expect(await b.state().photos.map(\.photoId) == [photo.photoId])
        try await a.store.deletePhoto(photoId: photo.photoId)
        try await a.session.captureLocalEdits()
        clock.advance()
        let piece = try await b.store.commitNewFurniture(draft: draft, placement: SyncCheck.chair, displayName: "Chair", decision: .manual)
        #expect(piece.sources.map(\.photoId) == [photo.photoId], "the store reused the photo")
        try await b.session.captureLocalEdits()
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(state.photos.map(\.photoId) == [photo.photoId], "\(device.name): the photo the new piece uses was deleted")
            #expect(state.allFurniture.first { $0.instanceId == piece.instanceId }?.sources.map(\.photoId) == [photo.photoId], "\(device.name)")
        }
        #expect(await a.filesAreWhole() == [])
        await QACheck.expectConverged([a, b])
    }

    // MARK: C24-08 — a version vector names each write under the device that made it

    /// A record whose `edits` (or a deletion's `seen`) lists a stamp under another device's key,
    /// or the zero stamp, is no vector any build writes: joining it is not idempotent or
    /// commutative. It is read as out of range (held back as it came, like CLOUDKIT-4).
    @Test func aVectorWithAStampUnderAnotherDevicesKeyIsNotRead() throws {
        let s = SyncStamp(wall: 10, counter: 0, device: "devA")
        let good = RoomSyncRecord(roomId: "room-2", name: SyncRegister("Den", s), createdAt: nil, tomb: nil)
        let envelope = try SyncEnvelope(.room(good))
        #expect(envelope.decoded() != nil)
        func tampered(_ change: (inout [String: Any]) -> Void) throws -> SyncEnvelope {
            var json = try #require(try JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any])
            change(&json)
            return SyncEnvelope(type: envelope.type, name: envelope.name, format: envelope.format,
                                payload: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
        }
        let stamp: [String: Any] = ["w": 20, "c": 0, "d": "devB"]
        let misKeyed = try tampered { $0["edits"] = ["devA": stamp] }
        #expect(misKeyed.decoded() == nil, "devB's stamp under devA's key")
        let zero = try tampered { $0["edits"] = ["": ["w": 0, "c": 0, "d": ""]] }
        #expect(zero.decoded() == nil, "the zero stamp in a vector")
        let seen = try tampered { $0["tomb"] = ["seen": ["devA": stamp], "at": ["w": 30, "c": 0, "d": "devA"]] }
        #expect(seen.decoded() == nil, "a deletion's seen with devB's stamp under devA's key")
        // A well-formed vector still reads, and a deletion's single old `seen` stamp too.
        let fine = try tampered { $0["edits"] = ["devB": stamp] }
        #expect(fine.decoded() != nil)
        let single = try tampered { $0["tomb"] = ["seen": stamp, "at": ["w": 30, "c": 0, "d": "devA"]] }
        #expect(single.decoded() != nil)
        // Held back as it came, never merged.
        var replica = SyncReplica()
        replica.merge(misKeyed)
        #expect(replica.unreadable[misKeyed.name] == misKeyed)
        #expect(replica[misKeyed.name] == nil)
    }

    /// The vector joins as a join must on what decodes: idempotent, commutative, associative.
    @Test func vectorsThatReadJoinAsAJoin() throws {
        func vector(_ json: String) throws -> SyncVersion {
            try JSONDecoder().decode(SyncVersion.self, from: Data(json.utf8))
        }
        let a = try vector(#"{"devA":{"w":10,"c":0,"d":"devA"}}"#)
        let b = try vector(#"{"devB":{"w":12,"c":1,"d":"devB"}}"#)
        let c = try vector(#"{"devA":{"w":11,"c":0,"d":"devA"},"devC":{"w":5,"c":0,"d":"devC"}}"#)
        #expect(a.isInRange && b.isInRange && c.isInRange)
        #expect(a.joined(a) == a)
        #expect(a.joined(b) == b.joined(a))
        #expect(a.joined(b).joined(c) == a.joined(b.joined(c)))
        let odd = try vector(#"{"devA":{"w":20,"c":0,"d":"devB"}}"#)
        #expect(!odd.isInRange)
        #expect(odd.joined(odd) != odd, "why it is not read: joined with itself it changes")
    }

    // MARK: C24-04 — two first syncs at once, with different notes

    /// Two devices turn sync on at the same moment, each with the same photo and its own note.
    /// One after the other, both notes are kept ("theirs\n\nmine", docs/ICLOUD_SYNC.md §7). At
    /// once, the second's save meets the first's record as a conflict: there too both notes are
    /// kept (owner's choice 1 for C24-04), once each, and both devices show the same text.
    @Test func twoFirstSyncsAtOnceKeepBothNotes() async throws {
        let cloud = SyncMemoryCloud()
        let gate = QAGate()
        let a = try await QADevice("A", cloud: cloud, clock: clock)
        let b = try await SaveGatedDevice("B", cloud: cloud, clock: clock, gate: gate)
        let draft = try TestSupport.draft(seed: 303)
        for (store, note) in [(a.store, "from A"), (b.store, "from B")] {
            let photo = try await store.importPhoto(draft: draft).photo
            _ = try await store.editPhoto(photoId: photo.photoId, PhotoEdit(note: note))
        }
        await gate.arm()
        let held = Task { try await b.session.sync() }
        await gate.waitUntilHeld()   // B fetched an empty cloud and seeded its note
        try await a.sync()           // A's first sync lands first
        await gate.release()
        _ = try await held.value
        try await QACheck.settle([a])
        _ = try await b.session.sync()
        try await QACheck.settle([a])
        let notes = [await a.state().photos.first?.note, await b.store.snapshot().photos.first?.note]
        #expect(notes.allSatisfy { $0?.contains("from A") == true && $0?.contains("from B") == true }, "\(notes)")
        #expect(notes[0] == notes[1], "both devices agree")
        // More rounds change nothing: the merge is not made again.
        try await QACheck.settle([a])
        _ = try await b.session.sync()
        try await QACheck.settle([a])
        let again = [await a.state().photos.first?.note, await b.store.snapshot().photos.first?.note]
        #expect(again == notes)
        #expect(again.allSatisfy { $0?.components(separatedBy: "from B").count == 2 && $0?.components(separatedBy: "from A").count == 2 }, "\(again)")
    }

    /// The merge at a conflict gives one text whichever device makes it, and is not made again
    /// when met again (a retried save, a second conflict). A note a user wrote with sync on, an
    /// empty note, or one that would pass the limit is left to the register.
    @Test func aConflictBetweenTwoOfferedNotesMergesTheSameWayEitherWay() {
        let a = SyncRegister("from A", SyncClock.seed(rank: 4)), b = SyncRegister("from B", SyncClock.seed(rank: 4))
        let both = SyncCapture.concurrentFirstSyncNote(a, b)
        #expect(both != nil && both == SyncCapture.concurrentFirstSyncNote(b, a))
        #expect(both?.value.components(separatedBy: "\n\n").sorted() == ["from A", "from B"])
        #expect(both.map { SyncClock.isSeed($0.stamp) } == true, "still an offer: an edit made meanwhile wins over it")
        #expect(both.map { $0.joined(a) == $0 && $0.joined(b) == $0 } == true)
        if let both {
            #expect(SyncCapture.concurrentFirstSyncNote(both, a) == nil)
            #expect(SyncCapture.concurrentFirstSyncNote(b, both) == nil)
        }
        // A higher rank: its note comes first, from either side.
        let newer = SyncRegister("from C", SyncClock.seed(rank: 9))
        #expect(SyncCapture.concurrentFirstSyncNote(a, newer)?.value == "from C\n\nfrom A")
        #expect(SyncCapture.concurrentFirstSyncNote(newer, a)?.value == "from C\n\nfrom A")
        // One holds the other: the longer one, even when the register would keep the shorter.
        let longer = SyncRegister("from A, and more", SyncClock.seed(rank: 2))
        #expect(SyncCapture.concurrentFirstSyncNote(a, longer)?.value == "from A, and more")
        // Not for an edit, an empty note, the same note, or past the limit.
        let edit = SyncRegister("edited", SyncStamp(wall: 1_800_000_000_000, counter: 0, device: "devA"))
        #expect(SyncCapture.concurrentFirstSyncNote(edit, b) == nil)
        #expect(SyncCapture.concurrentFirstSyncNote(b, edit) == nil)
        #expect(SyncCapture.concurrentFirstSyncNote(SyncRegister("", SyncClock.seed(rank: 4)), b) == nil)
        #expect(SyncCapture.concurrentFirstSyncNote(a, a) == nil)
        let half = String(repeating: "x", count: LibraryStore.maxNoteLength / 2 + 1)
        #expect(SyncCapture.concurrentFirstSyncNote(SyncRegister(half + "a", a.stamp), SyncRegister(half + "b", a.stamp)) == nil)
    }

    /// As above, but A's user changed the note after A's first sync, before B's save met it: the
    /// user's note stays as written on both devices (no offered note is put next to it here).
    @Test func twoFirstSyncsAtOnceKeepANoteEditedMeanwhile() async throws {
        let cloud = SyncMemoryCloud()
        let gate = QAGate()
        let a = try await QADevice("A", cloud: cloud, clock: clock)
        let b = try await SaveGatedDevice("B", cloud: cloud, clock: clock, gate: gate)
        let draft = try TestSupport.draft(seed: 304)
        for (store, note) in [(a.store, "from A"), (b.store, "from B")] {
            let photo = try await store.importPhoto(draft: draft).photo
            _ = try await store.editPhoto(photoId: photo.photoId, PhotoEdit(note: note))
        }
        await gate.arm()
        let held = Task { try await b.session.sync() }
        await gate.waitUntilHeld()
        try await a.sync()
        let photoId = try #require(await a.state().photos.first?.photoId)
        clock.advance(60)
        _ = try await a.store.editPhoto(photoId: photoId, PhotoEdit(note: "written on A"))
        try await a.sync()
        await gate.release()
        _ = try await held.value
        try await QACheck.settle([a])
        _ = try await b.session.sync()
        try await QACheck.settle([a])
        let notes = [await a.state().photos.first?.note, await b.store.snapshot().photos.first?.note]
        #expect(notes == ["written on A", "written on A"], "\(notes)")
    }
}

/// A device whose next armed `save` waits for the test (`QAGate`): the cycle has fetched and
/// captured, and holds before anything reaches the cloud.
struct SaveGatedDevice {
    let store: LibraryStore
    let session: SyncSession

    struct Transport: SyncTransport {
        let inner: SyncMemoryEndpoint
        let gate: QAGate
        func accountKey() async throws -> String { try await inner.accountKey() }
        func fetchChanges(since token: SyncToken?) async throws -> SyncFetchResult { try await inner.fetchChanges(since: token) }
        func save(_ records: [SyncSave]) async throws -> [SyncSaveResult] {
            await gate.pass()
            return try await inner.save(records)
        }
        func hasFile(sha256: String) async throws -> Bool { try await inner.hasFile(sha256: sha256) }
        func uploadFile(sha256: String, data: Data) async throws { try await inner.uploadFile(sha256: sha256, data: data) }
        func downloadFile(sha256: String) async throws -> Data { try await inner.downloadFile(sha256: sha256) }
        func deleteFile(sha256: String) async throws { try await inner.deleteFile(sha256: sha256) }
    }

    init(_ name: String, cloud: SyncMemoryCloud, clock: SyncTestClock, gate: QAGate) async throws {
        let root = TestSupport.tempDir().appendingPathComponent("Library-\(name)", isDirectory: true)
        let catalog = try TestSupport.catalog()
        store = LibraryStore(root: root, catalog: catalog)
        try await store.load()
        session = SyncSession(store: store, transport: Transport(inner: cloud.endpoint(name), gate: gate),
                              catalog: catalog, deviceID: "dev\(name)", now: clock.reader())
    }
}
