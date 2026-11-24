import Foundation
import Testing
@testable import MeowverseCore

/// QA review, round 2 (2026-11-18): the version vectors (`SyncVersion`) and reading what earlier
/// builds wrote. The fix round tested old furniture records only; photos, rooms, cats and
/// observations carry the same fields, and sync's own file holds every record kind.
@Suite struct SyncQA2FormatTests {
    static func stamp(_ wall: Int64, _ device: String, _ counter: Int = 0) -> SyncStamp {
        SyncStamp(wall: wall, counter: counter, device: device)
    }

    /// Strips `edits` and writes `tomb.seen` as one stamp, as records were before versions.
    static func oldShape<R: Encodable>(_ record: R, seen: SyncStamp?) throws -> Data {
        var json = try #require(try JSONSerialization.jsonObject(with: SyncCoding.encoder().encode(record)) as? [String: Any])
        json["edits"] = nil
        if let seen, var tomb = json["tomb"] as? [String: Any] {
            tomb["seen"] = ["w": seen.wall, "c": seen.counter, "d": seen.device]
            json["tomb"] = tomb
        }
        return try JSONSerialization.data(withJSONObject: json)
    }

    /// Every record kind with edits or a tombstone reads in its old shape, through the envelope
    /// (the path both a fetch and sync's own file take).
    @Test func everyRecordKindFromBeforeVersionsStillReads() throws {
        let s = Self.stamp(10, "a"), at = Self.stamp(30, "a")
        var photo = SyncMergeTests.photo(ids: ["p1"], file: SyncMergeTests.file("f1", 512), at: s)
        photo.tomb = SyncTombstone(seen: s, at: at)
        var room = RoomSyncRecord(roomId: "r1", name: SyncRegister("Study", s), createdAt: nil, tomb: nil)
        room.tomb = SyncTombstone(seen: s, at: at)
        let cat = CatSyncRecord(catId: "c1", name: SyncRegister("Mimi", s), roomId: SyncRegister(nil, s), tomb: nil)
        let observation = PhotoObservation(observationId: "o1", photoId: "p1", origin: .user, mode: .manual,
                                           analyzer: "qa", analyzerRevision: 1, objects: [], createdAt: Date(timeIntervalSince1970: 5))
        var obs = ObservationSyncRecord(observation: observation, created: s, tomb: nil)
        obs.tomb = SyncTombstone(seen: s, at: at)
        let cases: [(SyncRecord, Data, String)] = [
            (.photo(photo), try Self.oldShape(photo, seen: s), "MVPhoto"),
            (.room(room), try Self.oldShape(room, seen: s), "MVRoom"),
            (.cat(cat), try Self.oldShape(cat, seen: nil), "MVCat"),
            (.observation(obs), try Self.oldShape(obs, seen: s), "MVObservation"),
        ]
        for (record, payload, type) in cases {
            let envelope = SyncEnvelope(type: type, name: record.name, format: 1, payload: payload)
            let read = try #require(envelope.decoded(), "\(type) in its old shape does not read")
            #expect(read == record, "\(type)")
            #expect(read.isLive == record.isLive, "\(type)")
        }
    }

    /// Sync's own file written by the build before versions: records in the old shape and no
    /// `collectedFiles` or `repairCursor`. It must read (an unreadable file starts over and
    /// re-seeds the unsent edits under seed stamps).
    @Test func syncsOwnFileWithOldShapeRecordsStillReads() throws {
        let s = Self.stamp(10, "devA"), at = Self.stamp(30, "devA")
        var room = RoomSyncRecord(roomId: "r1", name: SyncRegister("Study", s), createdAt: nil, tomb: nil)
        room.tomb = SyncTombstone(seen: s, at: at)
        let photo = SyncMergeTests.photo(ids: ["p1"], file: SyncMergeTests.file("f1", 512), at: s)
        var device = SyncDeviceState(device: "devA")
        device.dirty = ["photo.src"]
        var json = try #require(try JSONSerialization.jsonObject(with: device.encoded()) as? [String: Any])
        json["collectedFiles"] = nil
        json["repairCursor"] = nil
        json["uploadedFiles"] = ["f1"]
        let records: [[String: Any]] = try [(SyncRecord.room(room), try Self.oldShape(room, seen: s)),
                                            (.photo(photo), try Self.oldShape(photo, seen: nil))].map { record, payload in
            let envelope = SyncEnvelope(type: record.type, name: record.name, format: 1, payload: payload)
            return try #require(try JSONSerialization.jsonObject(with: SyncCoding.encoder().encode(envelope)) as? [String: Any])
        }
        json["replica"] = ["records": records, "unreadable": [String: Any]()]
        let read = try #require(SyncDeviceState.decode(try JSONSerialization.data(withJSONObject: json)),
                                "sync's own file from the build before versions does not read")
        #expect(read.dirty == ["photo.src"])
        #expect(read.replica[SyncRecord.room(room).name] == .room(room))
        #expect(read.replica[SyncRecord.photo(photo).name] == .photo(photo))
    }

    // MARK: The algebra, at random

    /// A random furniture record: some of three devices wrote some fields, some only added a
    /// link, some deleted what they had.
    static func randomPiece(_ rng: inout SeededRandom) -> FurnitureSyncRecord {
        let devices = ["a", "b", "c"]
        func s() -> SyncStamp { stamp(Int64.random(in: 1...6, using: &rng), devices.randomElement(using: &rng)!, Int.random(in: 0...1, using: &rng)) }
        var r = SyncMergeTests.furniture(s(), name: "n\(Int.random(in: 0...2, using: &rng))")
        r.place.stamp = s()
        r.tags = SyncRegister(["t\(Int.random(in: 0...1, using: &rng))"], s())
        if Bool.random(using: &rng) {
            r.links["p\(Int.random(in: 0...2, using: &rng))"] = SyncRegister(
                PhotoCarrierSource(photoId: "p", observationId: nil, objectIndex: nil, origin: .user, relationToCat: .unclear), s())
        }
        for _ in 0..<Int.random(in: 0...2, using: &rng) { r.edits.add(s()) }
        if Int.random(in: 0..<3, using: &rng) == 0 {
            r.tomb = SyncTombstone(seen: SyncRecord.furniture(r).version, at: s())
        }
        return r
    }

    /// Join is commutative, associative and idempotent on random records, liveness included;
    /// a deletion never hides a write it did not see; and a version it saw stays hidden.
    @Test func versionVectorsJoinLikeASemilatticeAndHideOnlyWhatWasSeen() throws {
        var rng = SeededRandom(seed: 77)
        for _ in 0..<3000 {
            let x = SyncRecord.furniture(Self.randomPiece(&rng))
            let y = SyncRecord.furniture(Self.randomPiece(&rng))
            let z = SyncRecord.furniture(Self.randomPiece(&rng))
            let xy = try #require(x.joined(y)), yx = try #require(y.joined(x))
            #expect(xy == yx)
            let yz = try #require(y.joined(z))
            let left = try #require(xy.joined(z)), right = try #require(x.joined(yz))
            #expect(left == right)
            #expect(try #require(x.joined(x)) == x)
            // Hiding: live exactly when some write is not covered by the joined deletion.
            if let tomb = xy.tomb {
                let unseen = xy.version.stamps.contains { device, stamp in tomb.seen[device].map { stamp > $0 } ?? true }
                #expect(xy.isLive == unseen)
            } else {
                #expect(xy.isLive)
            }
            // A deletion of x that saw everything x had, joined with y: if y wrote something x
            // had not seen, it stays live.
            guard case .furniture(var deleted) = x else { continue }
            deleted.tomb = SyncTombstone.join(deleted.tomb, SyncTombstone(seen: x.version, at: Self.stamp(9, "a")))
            let merged = try #require(SyncRecord.furniture(deleted).joined(y))
            let yHasUnseen = y.version.stamps.contains { device, stamp in x.version[device].map { stamp > $0 } ?? true }
            let yTombSeen = y.tomb?.seen ?? SyncVersion()
            if yHasUnseen, !yTombSeen.covers(y.version) || y.tomb == nil {
                let fullySeen = merged.tomb.map { $0.seen.covers(merged.version) } ?? false
                #expect(merged.isLive == !fullySeen)
            }
        }
    }

    /// Two installs that used one id: after one moves to a new id, writes under the old id stay
    /// in the records. A later deletion on the moved device must still be beaten by the other
    /// install's next write under the old id (it never saw it).
    @Test func aWriteUnderAnOldIdAfterTheMoveStillBeatsADeletionThatNeverSawIt() throws {
        var piece = SyncMergeTests.furniture(Self.stamp(10, "x"))
        piece.edits.add(Self.stamp(10, "x"))
        // The moved install (now "x-1") renames, then deletes what it has.
        var moved = piece
        moved.name = SyncRegister("moved", Self.stamp(20, "x-1"))
        moved.edits.add(Self.stamp(20, "x-1"))
        moved.tomb = SyncTombstone(seen: SyncRecord.furniture(moved).version, at: Self.stamp(21, "x-1"))
        // The other install, still "x", moves the piece later without having heard.
        var other = piece
        other.place.value.x = 7
        other.place.stamp = Self.stamp(15, "x", 3)
        other.edits.add(Self.stamp(15, "x", 3))
        let merged = try #require(SyncRecord.furniture(moved).joined(.furniture(other)))
        #expect(merged.isLive, "the other install's unseen move under the old id was hidden")
    }
}
