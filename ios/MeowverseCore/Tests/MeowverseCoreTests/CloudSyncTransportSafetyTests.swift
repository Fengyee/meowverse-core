import CloudKit
import Foundation
import Testing
@testable import MeowverseCore

/// What keeps the CloudKit transport from losing or mixing records, without a container
/// (docs/ICLOUD_SYNC.md §11): the mirror is on disk before the engine's state, a record that
/// cannot be read is fetched again instead of dropped, a zone made again elsewhere is noticed,
/// and a test library never shares zones with the user's home.
struct CloudSyncTransportSafetyTests {
    private func envelope(_ name: String, seed: UInt8 = 1) -> SyncEnvelope {
        SyncEnvelope(type: "MVFurniture", name: name, format: 1, payload: Data([seed, seed &+ 1, seed &+ 2]))
    }

    private struct WriteFailure: Error {}

    /// Writes like the app does, except to a path in `failing`.
    private final class Disk: @unchecked Sendable {
        var failing: Set<String> = []
        func write(_ data: Data, _ url: URL) throws {
            if failing.contains(url.lastPathComponent) { throw WriteFailure() }
            try data.write(to: url, options: .atomic)
        }
    }

    private func files(_ folder: URL, _ disk: Disk) -> CloudSyncMirrorFiles {
        CloudSyncMirrorFiles(folder: folder) { data, url in try disk.write(data, url) }
    }

    // MARK: S1: the mirror before the engine's state

    @Test func theEnginesStateIsNotSavedWhileTheMirrorIsNot() throws {
        let folder = TestSupport.tempDir(), disk = Disk()
        var store = files(folder, disk)
        var mirror = store.load()
        mirror.record(envelope("a"), tag: "1", systemFields: nil)
        let ok1 = store.save(mirror)
        #expect(ok1)
        let ok2 = store.saveEngineState(Data("state-1".utf8), mirror: mirror)
        #expect(ok2)

        // The engine fetched b; the mirror could not be written.
        disk.failing = ["mirror.json"]
        mirror.record(envelope("b"), tag: "1", systemFields: nil)
        let ok3 = store.save(mirror)
        #expect(!ok3)
        let ok4 = store.saveEngineState(Data("state-2".utf8), mirror: mirror)
        #expect(!ok4, "the engine would never fetch b again")
        #expect(try Data(contentsOf: folder.appendingPathComponent("engine-state.json")) == Data("state-1".utf8))

        // Once the mirror can be written, the state follows it.
        disk.failing = []
        let ok5 = store.saveEngineState(Data("state-3".utf8), mirror: mirror)
        #expect(ok5)
        var reread = files(folder, disk)
        #expect(reread.load().entry(named: "b") != nil)
        #expect(reread.engineState() == Data("state-3".utf8))
    }

    @Test func aRecordHandedOutButNeverOnDiskIsHandedOutAgainAfterARelaunch() throws {
        let folder = TestSupport.tempDir(), disk = Disk()
        var store = files(folder, disk)
        var mirror = store.load()
        mirror.record(envelope("a"), tag: "1", systemFields: nil)
        let ok6 = store.save(mirror)
        #expect(ok6)
        let ok7 = store.saveEngineState(Data("state-1".utf8), mirror: mirror)
        #expect(ok7)

        disk.failing = ["mirror.json"]
        mirror.record(envelope("b"), tag: "1", systemFields: nil)
        let ok8 = store.save(mirror)
        #expect(!ok8)
        // A cycle takes b now, from memory.
        let taken = store.changes(since: nil, in: mirror)
        #expect(taken.records.map(\.envelope.name) == ["a", "b"])

        // The app dies. The engine's old state fetches b again into the mirror read from disk.
        disk.failing = []
        var relaunched = files(folder, disk)
        var again = relaunched.load()
        #expect(relaunched.engineState() == Data("state-1".utf8))
        again.record(envelope("b"), tag: "1", systemFields: nil)
        #expect(relaunched.changes(since: taken.token, in: again).records.map(\.envelope.name) == ["b"],
                "the token handed out must not claim what never reached the disk")
    }

    @Test func aMirrorThatIsGoneOrUnreadableTakesTheEnginesStateWithIt() throws {
        for damage in ["missing", "garbage", "newer"] {
            let folder = TestSupport.tempDir(), disk = Disk()
            var store = files(folder, disk)
            var mirror = store.load()
            mirror.record(envelope("a"), tag: "1", systemFields: nil)
            let ok9 = store.save(mirror)
            #expect(ok9)
            let ok10 = store.saveEngineState(Data("state".utf8), mirror: mirror)
            #expect(ok10)
            let url = folder.appendingPathComponent("mirror.json")
            switch damage {
            case "missing": try FileManager.default.removeItem(at: url)
            case "garbage": try Data("{".utf8).write(to: url)
            default:
                var newer = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
                newer["version"] = CloudSyncMirror.currentVersion + 1
                try JSONSerialization.data(withJSONObject: newer).write(to: url)
            }
            var reread = files(folder, disk)
            let loaded = reread.load()
            #expect(loaded.entry(named: "a") == nil, "\(damage)")
            #expect(reread.engineState() == nil, "\(damage): the engine must fetch everything again")
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("engine-state.json").path), "\(damage)")
        }
    }

    @Test func aMirrorFromBeforeTheNewFieldsStillReads() throws {
        let old = #"{"version":1,"epoch":"e1","account":"ck-1","zonesReady":true,"cloudDataDeleted":false,"sequence":1,"entries":{"a":{"envelope":{"type":"MVFurniture","name":"a","format":1,"payload":"AQID"},"tag":"1","sequence":1}}}"#
        let mirror = try #require(CloudSyncMirror.decode(Data(old.utf8)))
        #expect(mirror.entry(named: "a")?.tag == "1")
        #expect(mirror.zonesReady && mirror.account == "ck-1")
        #expect(mirror.unfetched.isEmpty && mirror.zoneMarker == nil)
    }

    // MARK: S2, S4: a record that cannot be read

    @Test func aRecordWhosePayloadAssetDidNotComeIsUnreadableNotSkipped() throws {
        let zones = CloudKitSyncZones.home
        let big = SyncEnvelope(type: "MVFurniture", name: "furniture.f1", format: 1,
                               payload: Data(repeating: 7, count: CloudKitSyncCoding.inlinePayloadLimit + 1))
        let (record, file) = try CloudKitSyncCoding.record(for: big, systemFields: nil, zones: zones, scratch: TestSupport.tempDir())
        #expect(CloudKitSyncCoding.classify(record, zones: zones) == .envelope(big))
        // A conflict's server record, or a fetch whose asset did not download: no file behind it.
        try FileManager.default.removeItem(at: try #require(file))
        #expect(CloudKitSyncCoding.classify(record, zones: zones) == .unreadable(name: "furniture.f1"))
        let other = CKRecord(recordType: "MVFurniture", recordID: CKRecord.ID(recordName: "furniture.f1"))
        #expect(CloudKitSyncCoding.classify(other, zones: zones) == .notOurs)
    }

    @Test func anUnreadableRecordWaitsInTheMirrorUntilItIsRead() {
        var mirror = CloudSyncMirror(epoch: "e1")
        mirror.record(envelope("a"), tag: "1", systemFields: nil)
        #expect(mirror.mayDeleteFiles)
        mirror.noteUnfetched("a", tag: "2")
        mirror.noteUnfetched("b", tag: "1")
        #expect(mirror.unfetchedNames == ["a", "b"])
        #expect(!mirror.mayDeleteFiles, "a record not read yet may still list a file")
        // The version held stays what sync gets until the newer one is read.
        #expect(mirror.changes(since: nil).records.map(\.tag) == ["1"])

        mirror.record(envelope("a", seed: 9), tag: "2", systemFields: nil)
        #expect(mirror.unfetchedNames == ["b"])
        mirror.forgetUnfetched("b")
        #expect(mirror.unfetchedNames.isEmpty && mirror.mayDeleteFiles)

        // Kept across a relaunch.
        mirror.noteUnfetched("c", tag: "5")
        let reread = CloudSyncMirror.decode(try! mirror.encoded())
        #expect(reread == mirror)
        mirror.reset()
        #expect(mirror.unfetchedNames.isEmpty)
    }

    // MARK: S6: a zone made again elsewhere

    @Test func aZoneWithAnotherMarkerIsAZoneMadeAgain() {
        #expect(CloudSyncZoneMarker.verdict(known: nil, onServer: nil) == .create)
        #expect(CloudSyncZoneMarker.verdict(known: nil, onServer: "m1") == .adopt("m1"))
        #expect(CloudSyncZoneMarker.verdict(known: "m1", onServer: "m1") == .same)
        #expect(CloudSyncZoneMarker.verdict(known: "m1", onServer: "m2") == .replaced)
        #expect(CloudSyncZoneMarker.verdict(known: "m1", onServer: nil) == .replaced, "a zone made again by a build without markers")

        let zones = CloudKitSyncZones.home
        let marker = CloudKitSyncCoding.markerRecord(id: "m1", zones: zones)
        #expect(CloudKitSyncCoding.classify(marker, zones: zones) == .zoneMarker("m1"))
        #expect(CloudKitSyncCoding.envelope(from: marker, zones: zones) == nil, "the marker is never one of sync's records")
        #expect(SyncEnvelope(type: "MVFurniture", name: CloudKitSyncCoding.markerRecordName, format: 1, payload: Data()).decoded() == nil)
    }

    @Test func theMarkerIsForgottenWithTheMirror() {
        var mirror = CloudSyncMirror(epoch: "e1")
        mirror.zoneMarker = "m1"
        mirror.reset(account: "a")
        #expect(mirror.zoneMarker == nil)
    }

    // MARK: S8: a test library's own zones

    @Test func onlyTheHomeLibraryUsesTheHomeZones() {
        let home = CloudKitSyncZones.forLibrary("Library")
        #expect(home == .home)
        #expect(home.recordsZoneName == "Meowverse" && home.filesZoneName == "MeowverseFiles", "the home's zone names never change")

        let folders = ["Test-sync", "Test-sync2", "Test-a b", "Test-ab", "Test-猫", "Library ", "library", String(repeating: "x", count: 300)]
        var seen = Set(home.names)
        for folder in folders {
            let zones = CloudKitSyncZones.forLibrary(folder)
            for name in zones.names {
                #expect(seen.insert(name).inserted, "\(folder) shares a zone")
                #expect(name.count <= 255 && !name.hasPrefix("_") && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            }
            #expect(zones == CloudKitSyncZones.forLibrary(folder), "stable across launches")
        }
        #expect(CloudKitSyncZones.forLibrary("Test-sync").recordsZoneName.contains("Test-sync"), "named after the library")
    }

    @Test func aRecordOfOneLibrarysZoneIsNeverReadAsAnothers() throws {
        let test = CloudKitSyncZones.forLibrary("Test-sync")
        let (record, _) = try CloudKitSyncCoding.record(for: envelope("furniture.f1"), systemFields: nil, zones: test, scratch: TestSupport.tempDir())
        #expect(record.recordID.zoneID.zoneName == test.recordsZoneName)
        #expect(CloudKitSyncCoding.envelope(from: record, zones: test) == envelope("furniture.f1"))
        #expect(CloudKitSyncCoding.envelope(from: record, zones: .home) == nil)
        #expect(CloudKitSyncCoding.fileRecordID(sha256: "ab", zones: test).zoneID.zoneName == test.filesZoneName)
        let (home, _) = try CloudKitSyncCoding.record(for: envelope("furniture.f1"), systemFields: nil, zones: .home, scratch: TestSupport.tempDir())
        #expect(CloudKitSyncCoding.envelope(from: home, zones: test) == nil)
    }

    // MARK: S5: pending changes left by an interrupted run

    @Test func aPendingSaveWithNoRecordIsRemovedNotSkipped() {
        let zone = CloudKitSyncZones.home.recordsZoneID
        let mine = CKRecord.ID(recordName: "furniture.f1", zoneID: zone)
        let left = CKRecord.ID(recordName: "furniture.f2", zoneID: zone)
        let pending: [CKSyncEngine.PendingRecordZoneChange] = [.saveRecord(left), .saveRecord(mine), .deleteRecord(mine)]
        let split = CloudKitSyncCoding.pendingToSend(pending, available: [mine])
        #expect(split.send == [.saveRecord(mine)])
        #expect(split.stale == [.saveRecord(left), .deleteRecord(mine)])
        #expect(CloudKitSyncCoding.pendingToSend(pending, available: []).send.isEmpty)
    }

    // MARK: S11: files checked many at a time

    @Test func fileChecksGoManyToARequest() throws {
        let a = SyncMergeTests.file(String(repeating: "a", count: 64), 2048, source: "s1")
        let a2 = SyncMergeTests.file(String(repeating: "c", count: 64), 1024, source: "s1")
        let b = SyncMergeTests.file(String(repeating: "b", count: 64), 1024, source: "s2")
        let stamp = SyncMergeTests.stamp(1)
        var first = SyncMergeTests.photo(ids: ["p1"], file: a, at: stamp)
        first.copies.append(a2)
        var gone = SyncMergeTests.photo(ids: ["p2"], file: b, at: stamp)
        gone.tomb = SyncTombstone(seen: stamp, at: stamp)
        let envelopes = [try SyncEnvelope(.photo(first)), try SyncEnvelope(.photo(gone)), envelope("furniture.f1")]
        #expect(CloudKitSyncCoding.photoFileHashes(envelopes) == [a.sha256, a2.sha256], "a deleted photo's files are not asked about")

        let candidates = (0..<500).map { String(format: "%064x", $0) }
        let batch = CloudKitSyncCoding.fileCheckBatch(asking: "asked", candidates: candidates, known: [candidates[0]], limit: 200)
        #expect(batch.count == 200 && batch[0] == "asked")
        #expect(!batch.contains(candidates[0]), "known answers are not asked again")
        #expect(Set(batch).count == batch.count)

        // Sync asks in the candidates' order: a batch covers the questions that come next.
        let middle = CloudKitSyncCoding.fileCheckBatch(asking: candidates[300], candidates: candidates, known: [], limit: 100)
        #expect(middle == Array(candidates[300..<400]))
        let end = CloudKitSyncCoding.fileCheckBatch(asking: candidates[450], candidates: candidates, known: [], limit: 100)
        #expect(end == Array(candidates[450..<500] + candidates[0..<50]), "wraps round")
        #expect(CloudKitSyncCoding.fileCheckBatch(asking: "x", candidates: [], known: [], limit: 100) == ["x"])
    }
}
