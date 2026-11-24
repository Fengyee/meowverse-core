import Foundation
import Testing
@testable import MeowverseCore

/// `SyncTombstone.together`: which records one deletion of a shared photo tombed together, so
/// the photo comes back whole when one of them does. A field added to a sync record without a
/// format bump (docs/audits/2026-11-20/wave3/compat.md, COMPAT-1): these pin what builds with and
/// without it read and write.
@Suite struct SyncTombTogetherTests {
    static let s = SyncStamp(wall: 1_800_000_000_000, counter: 0, device: "x")

    static func file(_ c: Character, from source: Character? = nil) -> SyncFileInfo {
        SyncFileInfo(sha256: String(repeating: c, count: 64), mimeType: "image/jpeg", ext: "jpg", byteSize: 10, width: 4, height: 2,
                     reducedFrom: source.map { ReducedFrom(sha256: String(repeating: $0, count: 64), byteSize: 99, width: 8, height: 4) })
    }

    /// The tombstone as builds before it wrote and read it (build 7 to 9e0f732).
    struct OldTombstone: Codable, Equatable {
        var seen: SyncVersion
        var at: SyncStamp
    }

    /// A deletion of one record alone writes no list: its bytes are the same as before.
    @Test func aDeletionOfOneRecordWritesTheSameBytesAsBefore() throws {
        let tomb = SyncTombstone(seen: Self.s, at: Self.s)
        let new = try SyncCoding.encoder().encode(tomb)
        let old = try SyncCoding.encoder().encode(OldTombstone(seen: tomb.seen, at: tomb.at))
        #expect(new == old)
    }

    /// An older build reads a tombstone with the list (the key is ignored), and this build reads
    /// one without it as deleted by itself.
    @Test func bothBuildsReadEachOthersTombstones() throws {
        let listed = SyncTombstone(seen: SyncVersion([Self.s]), at: Self.s, together: ["photo.a", "photo.b"])
        let bytes = try SyncCoding.encoder().encode(listed)
        let byOld = try SyncCoding.decoder().decode(OldTombstone.self, from: bytes)
        #expect(byOld == OldTombstone(seen: listed.seen, at: listed.at))
        let fromOld = try SyncCoding.decoder().decode(SyncTombstone.self, from: try SyncCoding.encoder().encode(byOld))
        #expect(fromOld.together == nil && fromOld.at == listed.at && fromOld.seen == listed.seen)
        // A whole record from an older build, tombstone without the key, still decodes.
        var record = SyncMergeTests.photo(ids: ["p"], file: Self.file("a"), at: Self.s)
        record.tomb = SyncTombstone(seen: record.version, at: Self.s)
        #expect(try SyncEnvelope(.photo(record)).decoded() != nil)
    }

    /// Two deletions of one record join their lists (and a list with none keeps the list).
    @Test func joinedDeletionsNameEveryRecordEitherDeletedTogether() {
        let a = SyncTombstone(seen: SyncVersion([Self.s]), at: Self.s, together: ["photo.o", "photo.r"])
        let b = SyncTombstone(seen: SyncVersion([Self.s]), at: SyncStamp(wall: Self.s.wall + 1, counter: 0, device: "y"))
        #expect(SyncTombstone.join(a, b)?.together == ["photo.o", "photo.r"])
        #expect(SyncTombstone.join(b, b)?.together == nil)
        let c = SyncTombstone(seen: SyncVersion([Self.s]), at: Self.s, together: ["photo.o", "photo.q"])
        #expect(SyncTombstone.join(a, c)?.together == ["photo.o", "photo.q", "photo.r"])
    }

    /// An older build that brings one record back (an edit it made) writes that record without
    /// the list. The record still tombed keeps its own list naming it, so the photo comes back
    /// whole all the same.
    @Test func aRecordBroughtBackByAnOlderBuildStillBringsItsPartnersBack() throws {
        var o = SyncMergeTests.photo(ids: ["p-o"], file: Self.file("r", from: "o"), at: Self.s)
        o.favorite = SyncRegister(true, SyncStamp(wall: Self.s.wall + 1, counter: 0, device: "x"))
        var r = SyncMergeTests.photo(ids: ["p-r"], file: Self.file("r"), at: Self.s)
        let at = SyncStamp(wall: Self.s.wall + 10, counter: 0, device: "d")
        let names = [SyncRecord.photoName(o.sourceHash), SyncRecord.photoName(r.sourceHash)].sorted()
        o.tomb = SyncTombstone(seen: o.version, at: at, together: names)
        r.tomb = SyncTombstone(seen: r.version, at: at) // as the older build re-sent it
        r.note = SyncRegister("unseen", SyncStamp(wall: Self.s.wall + 5, counter: 0, device: "old"))
        var replica = SyncReplica()
        replica.merge(.photo(o))
        replica.merge(.photo(r))
        let groups = SyncPhotoGroups(replica)
        #expect(groups.groups.count == 1)
        let merged = try #require(groups.groups.first?.merged)
        #expect(merged.note.value == "unseen" && merged.favorite.value, "the partner's favourite comes back with it")
    }
}
