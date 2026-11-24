import CloudKit
import Foundation
import Testing
@testable import MeowverseCore

/// The pieces of the CloudKit transport that need no container: what a record looks like in
/// CloudKit, what a CloudKit failure means for sync, and the mirror that holds fetched records
/// until a cycle takes them (docs/ICLOUD_SYNC.md, "传输层").
struct CloudSyncTransportCodingTests {
    private func envelope(_ name: String = "furniture.f1", bytes: Int = 40, seed: UInt8 = 1) -> SyncEnvelope {
        SyncEnvelope(type: "MVFurniture", name: name, format: 1, payload: Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0) &+ seed }))
    }

    // MARK: Records

    @Test func aSmallPayloadSitsInTheRecordAndComesBackTheSame() throws {
        let scratch = TestSupport.tempDir()
        let original = envelope()
        let (record, file) = try CloudKitSyncCoding.record(for: original, systemFields: nil, zones: .home, scratch: scratch)
        #expect(file == nil)
        #expect(record.recordType == "MVFurniture")
        #expect(record.recordID.recordName == "furniture.f1")
        #expect(record.recordID.zoneID.zoneName == CloudKitSyncZones.home.recordsZoneName)
        #expect(CloudKitSyncCoding.envelope(from: record, zones: .home) == original)
    }

    @Test func aPayloadTooBigForARecordGoesAsAnAssetWithItsHash() throws {
        let scratch = TestSupport.tempDir()
        let big = envelope(bytes: CloudKitSyncCoding.inlinePayloadLimit + 1)
        let (record, file) = try CloudKitSyncCoding.record(for: big, systemFields: nil, zones: .home, scratch: scratch)
        let url = try #require(file)
        #expect(record["payload"] == nil)
        #expect(record["payloadAsset"] is CKAsset)
        #expect(CloudKitSyncCoding.envelope(from: record, zones: .home) == big)

        // A damaged asset is not handed to sync as the record.
        try Data("damaged".utf8).write(to: url)
        #expect(CloudKitSyncCoding.envelope(from: record, zones: .home) == nil)
    }

    @Test func aRecordThatIsNotSyncsIsLeftAlone() throws {
        let other = CKRecord(recordType: "MVFurniture", recordID: CKRecord.ID(recordName: "furniture.f1"))
        other["format"] = 1 as NSNumber
        other["payload"] = Data([1]) as NSData
        #expect(CloudKitSyncCoding.envelope(from: other, zones: .home) == nil, "the default zone is not sync's")
        let noPayload = CKRecord(recordType: "MVFurniture", recordID: CKRecord.ID(recordName: "furniture.f1", zoneID: CloudKitSyncZones.home.recordsZoneID))
        noPayload["format"] = 1 as NSNumber
        #expect(CloudKitSyncCoding.envelope(from: noPayload, zones: .home) == nil)
    }

    @Test func aSaveBasedOnAKnownVersionKeepsThatVersionsSystemFields() throws {
        let scratch = TestSupport.tempDir()
        let (first, _) = try CloudKitSyncCoding.record(for: envelope(), systemFields: nil, zones: .home, scratch: scratch)
        let fields = CloudKitSyncCoding.systemFields(of: first)
        let decoded = try #require(CloudKitSyncCoding.record(fromSystemFields: fields))
        #expect(decoded.recordID == first.recordID)
        #expect(decoded.recordType == first.recordType)

        let (next, _) = try CloudKitSyncCoding.record(for: envelope(seed: 9), systemFields: fields, zones: .home, scratch: scratch)
        #expect(next.recordID == first.recordID)
        #expect(CloudKitSyncCoding.envelope(from: next, zones: .home) == envelope(seed: 9))

        // System fields of another record are never used for this one.
        let (other, _) = try CloudKitSyncCoding.record(for: envelope("furniture.f2"), systemFields: fields, zones: .home, scratch: scratch)
        #expect(other.recordID.recordName == "furniture.f2")
        #expect(CloudKitSyncCoding.record(fromSystemFields: Data("not an archive".utf8)) == nil)
    }

    @Test func aFileComesBackOnlyWhenItHashesToItsName() throws {
        let scratch = TestSupport.tempDir()
        let bytes = Data("a photo's bytes".utf8)
        let sha = PhotoIngest.sha256Hex(bytes)
        let url = scratch.appendingPathComponent("upload")
        try bytes.write(to: url)
        let record = CloudKitSyncCoding.fileRecord(sha256: sha, file: url, byteSize: bytes.count, zones: .home)
        #expect(record.recordID.recordName == "file." + sha)
        #expect(record.recordID.zoneID.zoneName == CloudKitSyncZones.home.filesZoneName)
        #expect(CloudKitSyncCoding.fileData(from: record, sha256: sha) == bytes)
        #expect(CloudKitSyncCoding.envelope(from: record, zones: .home) == nil, "a file is never read as a record")
        try Data("other bytes".utf8).write(to: url)
        #expect(CloudKitSyncCoding.fileData(from: record, sha256: sha) == nil)
    }

    // MARK: Errors

    @Test func cloudKitFailuresBecomeWhatTheSettingsPageCanExplain() {
        func map(_ code: CKError.Code, _ info: [String: Any] = [:], ready: Bool = true) -> SyncTransportError {
            CloudKitSyncCoding.transportError(CKError(code, userInfo: info), zonesReady: ready)
        }
        #expect(map(.networkUnavailable) == .offline)
        #expect(map(.networkFailure) == .offline)
        #expect(map(.quotaExceeded) == .quotaExceeded)
        #expect(map(.notAuthenticated) == .signedOut)
        #expect(map(.accountTemporarilyUnavailable) == .signedOut)
        #expect(map(.userDeletedZone) == .cloudDataDeleted)
        #expect(map(.zoneNotFound, ready: true) == .cloudDataDeleted)
        #expect(map(.zoneNotFound, ready: false) == .rejected("zoneNotFound"), "a new account's zones are created, not reported")
        #expect(map(.requestRateLimited, [CKErrorRetryAfterKey: 7.2]) == .retryLater(seconds: 8))
        #expect(map(.serviceUnavailable) == .retryLater(seconds: 30))
        #expect(map(.unknownItem) == .missingFile)
        #expect(map(.badContainer) == .rejected("container"))
        #expect(CloudKitSyncCoding.transportError(URLError(.notConnectedToInternet), zonesReady: true) == .offline)
        #expect(CloudKitSyncCoding.transportError(CancellationError(), zonesReady: true) == .retryLater(seconds: 30))
        #expect(CloudKitSyncCoding.transportError(SyncTransportError.accountChanged, zonesReady: true) == .accountChanged)
    }

    @Test func aPartialFailureSaysWhatTheItemsHit() {
        let id = CKRecord.ID(recordName: "photo.a", zoneID: CloudKitSyncZones.home.recordsZoneID)
        let other = CKRecord.ID(recordName: "photo.b", zoneID: CloudKitSyncZones.home.recordsZoneID)
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [
            id: CKError(.batchRequestFailed), other: CKError(.quotaExceeded),
        ]])
        #expect(CloudKitSyncCoding.transportError(partial, zonesReady: true) == .quotaExceeded)
        let missing = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: CKError(.zoneNotFound)]])
        #expect(CloudKitSyncCoding.isZoneMissing(missing))
        #expect(CloudKitSyncCoding.isZoneMissing(CKError(.zoneNotFound)))
        #expect(!CloudKitSyncCoding.isZoneMissing(partial))
    }

    // MARK: Mirror

    @Test func theMirrorHandsOutWhatCameAfterAToken() {
        var mirror = CloudSyncMirror(epoch: "e1")
        let tookA = mirror.record(envelope("a"), tag: "1", systemFields: nil)
        let tookB = mirror.record(envelope("b"), tag: "1", systemFields: nil)
        #expect(tookA && tookB)
        let first = mirror.changes(since: nil)
        #expect(first.records.map(\.envelope.name) == ["a", "b"])
        #expect(!first.moreComing)

        let again = mirror.record(envelope("a"), tag: "1", systemFields: Data([1]))
        #expect(!again, "the same version again is not news")
        #expect(mirror.entry(named: "a")?.systemFields == Data([1]))
        #expect(mirror.changes(since: first.token).records.isEmpty)

        let newer = mirror.record(envelope("a", seed: 5), tag: "2", systemFields: nil)
        #expect(newer)
        let second = mirror.changes(since: first.token)
        #expect(second.records == [SyncServerRecord(envelope: envelope("a", seed: 5), tag: "2")])
        #expect(mirror.changes(since: SyncToken("garbage")).records.count == 2, "an unknown token gets everything")
    }

    @Test func aResetMirrorGivesEverythingToAnOldToken() throws {
        var mirror = CloudSyncMirror(epoch: "e1")
        mirror.record(envelope("a"), tag: "1", systemFields: nil)
        mirror.zonesReady = true
        mirror.cloudDataDeleted = true
        let old = mirror.changes(since: nil).token
        mirror.reset(account: "acct")
        #expect(mirror.entry(named: "a") == nil)
        #expect(!mirror.zonesReady && !mirror.cloudDataDeleted)
        #expect(mirror.account == "acct")
        mirror.record(envelope("b"), tag: "1", systemFields: nil)
        #expect(mirror.changes(since: old).records.map(\.envelope.name) == ["b"], "another epoch's token means start over")

        let reread = try #require(CloudSyncMirror.decode(try mirror.encoded()))
        #expect(reread == mirror)
        #expect(CloudSyncMirror.decode(Data("{}".utf8)) == nil)
    }
}
