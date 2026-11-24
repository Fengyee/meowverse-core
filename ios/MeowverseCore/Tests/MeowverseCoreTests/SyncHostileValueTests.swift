import Foundation
import Testing
@testable import MeowverseCore

/// Values in a cloud record that no build of the app writes (round-12 audit CLOUDKIT-4): a
/// damaged write, a tester build, or someone else's writer in the user's own database. Before
/// the fix, two copies of 4-billion-pixel sides trapped `width * height` in ranking copies, and a
/// stamp with `counter == Int.max` trapped the next `tick`, on every launch. Such a record is now
/// unreadable to this build, for that record only: kept as it came, the thing it names left as
/// this device has it, everything else synced.
@Suite struct SyncHostileValueTests {
    let clock = SyncTestClock()

    static let hash = String(repeating: "c", count: 64)
    static func file(_ sha: String = hash, width: Int = 4, height: Int = 2, byteSize: Int = 10) -> SyncFileInfo {
        SyncFileInfo(sha256: sha, mimeType: "image/jpeg", ext: "jpg", byteSize: byteSize, width: width, height: height, reducedFrom: nil)
    }

    /// A photo record with two copies of `photo.<hash>`, so ranking them multiplies their sides.
    static func photo(width: Int = 4, height: Int = 2, counter: Int = 0, byteSize: Int = 10) -> SyncRecord {
        let s = SyncStamp(wall: 1_800_000_000_000, counter: counter, device: "zz")
        let source = file()
        let copy = SyncFileInfo(sha256: String(repeating: "d", count: 64), mimeType: "image/jpeg", ext: "jpg", byteSize: byteSize,
                                width: width, height: height, reducedFrom: ReducedFrom(sha256: hash, byteSize: 10, width: 4, height: 2))
        var record = SyncMergeTests.photo(ids: ["hostile"], file: source, at: s)
        record.addCopy(copy)
        record.addCopy(file(String(repeating: "e", count: 64), width: width, height: height).reducedCopy(of: source))
        return .photo(record)
    }

    @Test func recordsWithValuesNoBuildWritesAreUnreadable() throws {
        let fine = try SyncEnvelope(Self.photo())
        #expect(fine.decoded() != nil, "an honest record still reads")
        for (label, record) in [
            ("sides past Int32", Self.photo(width: 4_294_967_296, height: 4_294_967_296)),
            ("negative side", Self.photo(width: -1)),
            ("negative size", Self.photo(byteSize: -5)),
            ("counter at Int.max", Self.photo(counter: Int.max)),
            ("negative counter", Self.photo(counter: -1)),
        ] {
            #expect(try SyncEnvelope(record).decoded() == nil, "\(label)")
        }
        var piece = SyncMergeTests.furniture(SyncStamp(wall: 5, counter: 0, device: "b"))
        #expect(try SyncEnvelope(.furniture(piece)).decoded() != nil)
        piece.place.value.x = Int.max
        #expect(try SyncEnvelope(.furniture(piece)).decoded() == nil, "a spot no room has")
        var link = SyncMergeTests.furniture(SyncStamp(wall: 5, counter: 0, device: "b"))
        link.links["p"] = SyncRegister(nil, SyncStamp(wall: 5, counter: Int.max, device: "b"))
        #expect(try SyncEnvelope(.furniture(link)).decoded() == nil, "a stamp deep in a link register")
        var tomb = SyncMergeTests.furniture(SyncStamp(wall: 5, counter: 0, device: "b"))
        tomb.tomb = SyncTombstone(seen: SyncStamp(wall: 5, counter: Int.max, device: "b"), at: SyncStamp(wall: 6, counter: 0, device: "b"))
        #expect(try SyncEnvelope(.furniture(tomb)).decoded() == nil, "a stamp in what a deletion saw")
        let home = HomeSyncRecord(roomOrder: SyncRegister([], .zero), catOrder: SyncRegister([], .zero),
                                  settings: ["k": SyncRegister("v", SyncStamp(wall: 1, counter: Int.max, device: "b"))])
        #expect(try SyncEnvelope(.home(home)).decoded() == nil, "a setting's stamp")
    }

    @Test func rankingCopiesAndTickingNeverTrap() {
        let huge = Self.file(width: Int.max, height: Int.max)
        #expect(huge.better(than: Self.file()), "more pixels, even past what an Int holds")
        #expect(!Self.file().better(than: huge))
        var clock = SyncClock(device: "a")
        clock.observe(SyncStamp(wall: 10, counter: Int.max, device: "z"))
        #expect(clock.last == SyncStamp(wall: 0, counter: 0, device: "a"), "an absurd stamp is not adopted")
        let next = clock.tick(now: Date(timeIntervalSince1970: 0))
        #expect(next.counter >= 0 && next.counter <= SyncStamp.maxCounter, "an absurd stamp is not adopted")
        var saturated = SyncClock(device: "a")
        saturated.observe(SyncStamp(wall: 10, counter: SyncStamp.maxCounter, device: "z"))
        let a = saturated.tick(now: Date(timeIntervalSince1970: 0)), b = saturated.tick(now: Date(timeIntervalSince1970: 0))
        #expect(a > SyncStamp(wall: 10, counter: SyncStamp.maxCounter, device: "z") && b > a, "still after what it saw, still in range")
        #expect(a.counter <= SyncStamp.maxCounter && b.counter <= SyncStamp.maxCounter)
    }

    @Test func aHostileRecordInTheCloudIsHeldBackAndEverythingElseStillSyncs() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await SyncDevice("A", cloud: cloud, clock: clock)
        let b = try await SyncDevice("B", cloud: cloud, clock: clock)
        let chair = try await a.store.commitNewFurniture(draft: try TestSupport.draft(seed: 1), placement: SyncCheck.chair,
                                                         displayName: "Chair", decision: .manual)
        try await SyncCheck.settle([a, b])

        // Another writer puts in a photo whose copies overflow, and rewrites the chair with a
        // stamp no clock reaches.
        let photo = try SyncEnvelope(Self.photo(width: 4_294_967_296, height: 4_294_967_296))
        let stored = try #require(try await a.session.deviceState()?.replica["furniture.\(chair.instanceId)"])
        guard case .furniture(var bad) = stored else { Issue.record("no chair record"); return }
        bad.name = SyncRegister("Overflow", SyncStamp(wall: SyncClock.millis(clock.now) + 10, counter: Int.max, device: "zz"))
        let piece = try SyncEnvelope(.furniture(bad))
        let tag = try #require(try await a.session.deviceState()?.tags[piece.name])
        _ = try await cloud.endpoint("N").save([SyncSave(envelope: photo, baseTag: nil), SyncSave(envelope: piece, baseTag: tag)])

        // Edits elsewhere keep flowing, both ways, and each device edits on.
        clock.advance()
        _ = try await a.store.renameCat(catId: AppState.primaryCatId, name: "Mochi")
        let report = try await a.sync()
        #expect(report.heldBack.contains(photo.name) && report.heldBack.contains(piece.name))
        clock.advance()
        _ = try await b.store.renameRoom(roomId: AppState.primaryRoomId, name: "Attic")
        try await SyncCheck.settle([a, b])
        for device in [a, b] {
            let state = await device.state()
            #expect(state.catName == "Mochi" && state.allRooms.first?.name == "Attic", "\(device.name) got the other's edit")
            #expect(state.items.map(\.displayName) == ["Chair"], "\(device.name) keeps its own chair")
            #expect(!state.photos.contains { $0.photoId == "hostile" })
        }
        let inCloud = await cloud.allEnvelopes
        #expect(inCloud.contains(photo) && inCloud.contains(piece), "nothing overwrites them")
        // The clock never took the absurd stamp: the next edit still stamps and sends.
        let clockNow = try #require(try await b.session.deviceState()?.clock.last)
        #expect(clockNow.counter <= SyncStamp.maxCounter)
    }

    #if canImport(CloudKit)
    @Test func listingCloudFilesSkipsAHostilePhotoRecord() throws {
        let hostile = try SyncEnvelope(Self.photo(width: 4_294_967_296, height: 4_294_967_296))
        let fine = try SyncEnvelope(.photo(SyncMergeTests.photo(ids: ["p"], file: Self.file(String(repeating: "f", count: 64)),
                                                                at: SyncStamp(wall: 1, counter: 0, device: "a"))))
        #expect(CloudKitSyncCoding.photoFileHashes([hostile, fine]) == [String(repeating: "f", count: 64)])
    }
    #endif
}

private extension SyncFileInfo {
    /// This file as a reduced copy of `source`.
    func reducedCopy(of source: SyncFileInfo) -> SyncFileInfo {
        SyncFileInfo(sha256: sha256, mimeType: mimeType, ext: ext, byteSize: byteSize, width: width, height: height,
                     reducedFrom: ReducedFrom(sha256: source.sha256, byteSize: source.byteSize, width: source.width, height: source.height))
    }
}
