import Foundation
import Testing
@testable import MeowverseCore

/// The record merge on its own: every join is commutative, associative and idempotent, and the
/// deletion rule keeps edits the deleting device never saw.
@Suite struct SyncMergeTests {
    static func stamp(_ wall: Int64, _ counter: Int = 0, _ device: String = "a") -> SyncStamp {
        SyncStamp(wall: wall, counter: counter, device: device)
    }

    static func file(_ sha: String, _ side: Int, source: String = "src") -> SyncFileInfo {
        SyncFileInfo(sha256: sha, mimeType: "image/jpeg", ext: "jpeg", byteSize: side * 10, width: side, height: side,
                     reducedFrom: ReducedFrom(sha256: source, byteSize: 99_999, width: 4000, height: 4000))
    }

    static func photo(ids: [String], file: SyncFileInfo, at s: SyncStamp, note: String = "", favorite: Bool = false,
                      importedAt: Date = Date(timeIntervalSince1970: 1000)) -> PhotoSyncRecord {
        PhotoSyncRecord(sourceHash: file.sourceHash, photoIds: ids.sorted(), importedAt: importedAt, copies: [file],
                        filename: SyncRegister(nil, s), exifDay: SyncRegister("2024-01-02", s),
                        date: SyncRegister(.followFile, s), favorite: SyncRegister(favorite, s),
                        note: SyncRegister(note, s), cloudIdentifier: SyncRegister(nil, s), tomb: nil)
    }

    static func furniture(_ s: SyncStamp, name: String = "Sofa", x: Int = 1) -> FurnitureSyncRecord {
        let piece = PhotoFurniture(instanceId: "f1", modelId: "sofa", x: x, z: 2, width: 2, depth: 1, turn: 0,
                                   finish: .original, displayName: name, sources: [], tags: [], revision: 1)
        return FurnitureSyncRecord(instanceId: "f1", place: SyncRegister(SyncPlace(piece, stored: false), s),
                                   name: SyncRegister(name, s), tags: SyncRegister([], s), locked: SyncRegister(nil, s),
                                   cover: SyncRegister(nil, s), order: SyncRegister([], s), links: [:],
                                   createdAt: nil, updatedAt: nil, tomb: nil)
    }

    @Test func clockPassesEverythingItHasSeenEvenWhenItsWallClockIsBehind() {
        var clock = SyncClock(device: "b")
        let early = Date(timeIntervalSince1970: 100)
        let first = clock.tick(now: early)
        clock.observe(Self.stamp(999_999_000, 5, "z"))
        let next = clock.tick(now: early)
        #expect(next > Self.stamp(999_999_000, 5, "z"))
        #expect(next > first)
        #expect(clock.tick(now: early) > next)
    }

    @Test func registerKeepsTheLaterWriteWhateverOrderItArrivesIn() {
        let a = SyncRegister("old", Self.stamp(1)), b = SyncRegister("new", Self.stamp(2, 0, "b"))
        #expect(a.joined(b) == b)
        #expect(b.joined(a) == b)
        #expect(b.joined(b) == b)
        // Equal stamps with different values (a damaged copy): still one answer for everyone.
        let c = SyncRegister("x", Self.stamp(3)), d = SyncRegister("y", Self.stamp(3))
        #expect(c.joined(d) == d.joined(c))
    }

    @Test func aDeletionHidesWhatItSawAndKeepsWhatItDidNot() throws {
        let created = Self.furniture(Self.stamp(10))
        var deleted = created
        deleted.tomb = SyncTombstone(seen: Self.stamp(10), at: Self.stamp(20))
        #expect(SyncRecord.furniture(deleted).isLive == false)
        // Another device renamed it at 15, before the deletion at 20, but the deleter never
        // saw that rename: the piece comes back with the rename.
        var renamed = created
        renamed.name = SyncRegister("Blue sofa", Self.stamp(15, 0, "b"))
        let merged = try #require(SyncRecord.furniture(deleted).joined(.furniture(renamed)))
        #expect(merged.isLive)
        #expect(merged == SyncRecord.furniture(renamed).joined(.furniture(deleted)))
        guard case .furniture(let piece) = merged else { Issue.record("type"); return }
        #expect(piece.name.value == "Blue sofa")
        // Deleted again after seeing the rename: gone, in either order.
        var again = piece
        again.tomb = SyncTombstone(seen: Self.stamp(15, 0, "b"), at: Self.stamp(30))
        #expect(SyncRecord.furniture(again).joined(merged)?.isLive == false)
        #expect(merged.joined(.furniture(again))?.isLive == false)
    }

    @Test func twoImportsOfOnePhotoBecomeOneRecordWithTheSmallestIdAndTheBestCopy() throws {
        let small = Self.photo(ids: ["B-photo"], file: Self.file("s1024", 1024), at: Self.stamp(5, 0, "b"),
                               importedAt: Date(timeIntervalSince1970: 2000))
        let large = Self.photo(ids: ["A-photo"], file: Self.file("s2048", 2048), at: Self.stamp(4),
                               importedAt: Date(timeIntervalSince1970: 1500))
        let ab = try #require(SyncRecord.photo(small).joined(.photo(large)))
        let ba = try #require(SyncRecord.photo(large).joined(.photo(small)))
        #expect(ab == ba)
        guard case .photo(let merged) = ab else { Issue.record("type"); return }
        #expect(merged.photoIds == ["A-photo", "B-photo"])
        #expect(merged.canonicalId == "A-photo")
        #expect(merged.file.sha256 == "s2048")
        #expect(merged.importedAt == Date(timeIntervalSince1970: 1500))
    }

    @Test func envelopesRoundTripAndANewerFormatIsKeptUntouched() throws {
        let record = SyncRecord.furniture(Self.furniture(Self.stamp(1)))
        let envelope = try SyncEnvelope(record)
        #expect(envelope.decoded() == record)
        var replica = SyncReplica()
        let first = replica.merge(envelope), again = replica.merge(envelope)
        #expect(first && !again)

        var newer = envelope
        newer.format = SyncEnvelope.currentFormat + 1
        newer.payload = Data("{\"future\":true}".utf8)
        #expect(newer.decoded() == nil)
        let keptNewer = replica.merge(newer)
        #expect(keptNewer)
        #expect(replica.unreadable[envelope.name] == newer)
        #expect(replica[envelope.name] == record)
        let data = try JSONEncoder().encode(replica)
        #expect(try JSONDecoder().decode(SyncReplica.self, from: data) == replica)
    }

    @Test func aPayloadThatNamesAnotherRecordIsRefused() throws {
        var envelope = try SyncEnvelope(.furniture(Self.furniture(Self.stamp(1))))
        envelope.name = "furniture.other"
        #expect(envelope.decoded() == nil)
    }

    /// Random versions of one record joined in random groupings and orders give one answer.
    @Test func joinsAreOrderIndependentOverRandomVersions() throws {
        var rng = SeededRandom(seed: 7)
        for _ in 0..<40 {
            var versions: [SyncRecord] = []
            for _ in 0..<5 {
                var piece = Self.furniture(Self.stamp(Int64.random(in: 1...6, using: &rng), 0, ["a", "b", "c"].randomElement(using: &rng)!),
                                           name: ["A", "B", "C"].randomElement(using: &rng)!, x: Int.random(in: 0...3, using: &rng))
                if Bool.random(using: &rng) {
                    piece.links["p\(Int.random(in: 0...2, using: &rng))"] = SyncRegister(
                        Bool.random(using: &rng) ? .manual(photoId: "p") : nil, Self.stamp(Int64.random(in: 1...6, using: &rng), 0, "b"))
                }
                if Int.random(in: 0...3, using: &rng) == 0 {
                    piece.tomb = SyncTombstone(seen: Self.stamp(Int64.random(in: 1...6, using: &rng)), at: Self.stamp(7))
                }
                versions.append(.furniture(piece))
            }
            let forward = try versions.dropFirst().reduce(versions[0]) { try #require($0.joined($1)) }
            let shuffled = versions.shuffled(using: &rng)
            let other = try shuffled.dropFirst().reduce(shuffled[0]) { try #require($0.joined($1)) }
            #expect(forward == other)
            #expect(forward.joined(forward) == forward)
            // Associativity: (a ∨ b) ∨ (c ∨ d ∨ e) = forward.
            let left = try #require(versions[0].joined(versions[1]))
            let right = try versions[3...].reduce(versions[2]) { try #require($0.joined($1)) }
            #expect(left.joined(right) == forward)
        }
    }
}
