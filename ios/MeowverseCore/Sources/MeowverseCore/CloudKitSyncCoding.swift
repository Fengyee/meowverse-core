#if canImport(CloudKit)
import CloudKit
import CryptoKit
import Foundation

/// The two CloudKit zones one library syncs through. The zones belong to the whole iCloud
/// account, while libraries are per folder: the user's own home (`Library`) keeps the zone names
/// sync always had, and every other library (a test library, `-MeowverseStore`) gets zones of
/// its own named after it, so it can never merge into the real home.
public struct CloudKitSyncZones: Sendable, Equatable {
    public let recordsZoneName: String
    public let filesZoneName: String

    /// The folder of the user's own library (`LaunchOptions.storeFolder`).
    public static let homeLibraryFolder = "Library"
    public static let home = CloudKitSyncZones(recordsZoneName: "Meowverse", filesZoneName: "MeowverseFiles")

    /// Zone names allow ASCII only, at most 255 characters, not starting with an underscore.
    /// Another library's name is kept readable (letters, digits, `-`, at most 40) and followed by
    /// a hash of the whole folder name, so two folders never share zones even when they read
    /// the same once cleaned, and none reads as the home's.
    public static func forLibrary(_ folder: String) -> CloudKitSyncZones {
        guard folder != homeLibraryFolder else { return home }
        let readable = String(folder.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
            .map(Character.init).prefix(40))
        let hash = SHA256.hash(data: Data(folder.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let suffix = (readable.isEmpty ? "" : readable + "-") + hash
        return CloudKitSyncZones(recordsZoneName: "Meowverse-" + suffix, filesZoneName: "MeowverseFiles-" + suffix)
    }

    public var recordsZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: recordsZoneName, ownerName: CKCurrentUserDefaultName)
    }

    public var filesZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: filesZoneName, ownerName: CKCurrentUserDefaultName)
    }

    public var names: [String] { [recordsZoneName, filesZoneName] }
}

/// How sync's records and files look in CloudKit (docs/ICLOUD_SYNC.md, "传输层"), apart from
/// any container, so it can be tested without one. The transport (App side) only moves these.
///
/// - Records live in the private database, in the library's records zone (`Meowverse` for the
///   user's home): record type = envelope type, record name = envelope name, fields `format`
///   and `payload` (bytes). A payload too big to sit in the record goes as an asset
///   `payloadAsset` with its SHA-256 in `payloadSHA256`.
/// - The records zone also holds one `MVZoneMarker` record with a random id, made once per
///   zone: a zone deleted and made again while this device was away has another id.
/// - Photo files live in the library's files zone (`MeowverseFiles`) as immutable `MVFile`
///   records named `file.<sha256>`, with the bytes as the asset `file`. A zone of their own
///   keeps CKSyncEngine, which fetches whole records, from downloading every copy of every photo.
public enum CloudKitSyncCoding {
    public static let fileRecordType = "MVFile"
    public static let markerRecordType = "MVZoneMarker"
    /// Not a name sync's records can have (`photo.`, `obs.`, `furniture.`, `room.`, `cat.`, `home`).
    public static let markerRecordName = "zone.marker"

    enum Field {
        static let format = "format"
        static let payload = "payload"
        static let payloadAsset = "payloadAsset"
        static let payloadSHA256 = "payloadSHA256"
        static let file = "file"
        static let fileSHA256 = "sha256"
        static let fileSize = "byteSize"
        static let marker = "marker"
    }

    /// A record holds at most 1 MB of fields; above this the payload goes as an asset.
    public static let inlinePayloadLimit = 512 * 1024

    // MARK: Records

    /// The CKRecord to save for `envelope`. With the system fields of the version the save is
    /// based on, the record carries that version's change tag, so the server refuses it if it
    /// has another version meanwhile. A payload written to an asset is at the returned URL
    /// (inside `scratch`): delete it once the save is over.
    public static func record(for envelope: SyncEnvelope, systemFields: Data?, zones: CloudKitSyncZones,
                              scratch: URL) throws -> (record: CKRecord, assetFile: URL?) {
        let id = CKRecord.ID(recordName: envelope.name, zoneID: zones.recordsZoneID)
        let record: CKRecord
        if let systemFields, let based = Self.record(fromSystemFields: systemFields),
           based.recordID == id, based.recordType == envelope.type {
            record = based
        } else {
            record = CKRecord(recordType: envelope.type, recordID: id)
        }
        record[Field.format] = envelope.format as NSNumber
        guard envelope.payload.count > inlinePayloadLimit else {
            record[Field.payload] = envelope.payload as NSData
            record[Field.payloadAsset] = nil
            record[Field.payloadSHA256] = nil
            return (record, nil)
        }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appendingPathComponent("payload-" + UUID().uuidString)
        try envelope.payload.write(to: file, options: .atomic)
        record[Field.payload] = nil
        record[Field.payloadAsset] = CKAsset(fileURL: file)
        record[Field.payloadSHA256] = PhotoIngest.sha256Hex(envelope.payload) as NSString
        return (record, file)
    }

    /// nil for a record that is not one of sync's, or whose payload is missing or does not match
    /// its hash. Such a record is left alone (never overwritten from here).
    public static func envelope(from record: CKRecord, zones: CloudKitSyncZones) -> SyncEnvelope? {
        guard case .envelope(let envelope) = classify(record, zones: zones) else { return nil }
        return envelope
    }

    /// What a record fetched from the server is to sync.
    public enum Fetched: Equatable, Sendable {
        case envelope(SyncEnvelope)
        /// The zone's marker, with its id.
        case zoneMarker(String)
        /// One of sync's records that cannot be read as it came: most often a payload asset that
        /// was not downloaded (CloudKit leaves `fileURL` nil, for one, on the server record of a
        /// conflict), or a damaged one. Never dropped: fetched again on its own.
        case unreadable(name: String)
        /// Another zone's, a file, or another kind of record: not sync's.
        case notOurs
    }

    public static func classify(_ record: CKRecord, zones: CloudKitSyncZones) -> Fetched {
        guard record.recordID.zoneID.zoneName == zones.recordsZoneName, record.recordType != fileRecordType else { return .notOurs }
        if record.recordType == markerRecordType {
            guard let id = record[Field.marker] as? String, !id.isEmpty else { return .unreadable(name: record.recordID.recordName) }
            return .zoneMarker(id)
        }
        guard let format = (record[Field.format] as? NSNumber)?.intValue else { return .unreadable(name: record.recordID.recordName) }
        let payload: Data
        if let inline = record[Field.payload] as? Data {
            payload = inline
        } else if let asset = record[Field.payloadAsset] as? CKAsset, let url = asset.fileURL,
                  let data = try? Data(contentsOf: url), let expected = record[Field.payloadSHA256] as? String,
                  PhotoIngest.sha256Hex(data) == expected {
            payload = data
        } else {
            return .unreadable(name: record.recordID.recordName)
        }
        return .envelope(SyncEnvelope(type: record.recordType, name: record.recordID.recordName, format: format, payload: payload))
    }

    public static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    public static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    /// CloudKit's version tag of a record, as sync stores it. A record never saved has none.
    public static func tag(of record: CKRecord) -> String? { record.recordChangeTag }

    // MARK: Zone marker

    public static func markerRecordID(zones: CloudKitSyncZones) -> CKRecord.ID {
        CKRecord.ID(recordName: markerRecordName, zoneID: zones.recordsZoneID)
    }

    public static func markerRecord(id: String, zones: CloudKitSyncZones) -> CKRecord {
        let record = CKRecord(recordType: markerRecordType, recordID: markerRecordID(zones: zones))
        record[Field.marker] = id as NSString
        return record
    }

    // MARK: Files

    public static func fileRecordID(sha256: String, zones: CloudKitSyncZones) -> CKRecord.ID {
        CKRecord.ID(recordName: "file." + sha256, zoneID: zones.filesZoneID)
    }

    /// The record for a photo file already written to `file` (the asset is read from there).
    public static func fileRecord(sha256: String, file: URL, byteSize: Int, zones: CloudKitSyncZones) -> CKRecord {
        let record = CKRecord(recordType: fileRecordType, recordID: fileRecordID(sha256: sha256, zones: zones))
        record[Field.file] = CKAsset(fileURL: file)
        record[Field.fileSHA256] = sha256 as NSString
        record[Field.fileSize] = byteSize as NSNumber
        return record
    }

    /// The file's bytes, only if they hash to the record's name: a damaged download is never
    /// handed to sync as the photo.
    public static func fileData(from record: CKRecord, sha256: String) -> Data? {
        guard let asset = record[Field.file] as? CKAsset, let url = asset.fileURL,
              let data = try? Data(contentsOf: url), PhotoIngest.sha256Hex(data) == sha256 else { return nil }
        return data
    }

    /// Every file a live photo among `envelopes` lists, best first per photo, each once: the
    /// files a cycle may ask about. Checked many at a time (one request), not one per photo.
    public static func photoFileHashes(_ envelopes: some Sequence<SyncEnvelope>) -> [String] {
        var seen = Set<String>(), hashes: [String] = []
        for envelope in envelopes.sorted(by: { $0.name < $1.name }) where envelope.type == "MVPhoto" {
            guard let record = envelope.decoded(), record.isLive, case .photo(let photo) = record else { continue }
            for copy in photo.copiesBestFirst where seen.insert(copy.sha256).inserted { hashes.append(copy.sha256) }
        }
        return hashes
    }

    /// The files one existence check asks about: `asked` first, then candidates not yet known,
    /// up to `limit`, starting after `asked` in the candidates' order and wrapping round. Sync
    /// walks photos in the same order (by source hash, as the record names sort), so the next
    /// questions of a cycle are mostly answered by this one.
    public static func fileCheckBatch(asking asked: String, candidates: [String], known: Set<String>, limit: Int) -> [String] {
        var batch = [asked], taken: Set<String> = [asked]
        let start = candidates.firstIndex(of: asked).map { $0 + 1 } ?? 0
        for offset in 0..<candidates.count where batch.count < limit {
            let sha = candidates[(start + offset) % candidates.count]
            if !known.contains(sha), taken.insert(sha).inserted { batch.append(sha) }
        }
        return batch
    }

    // MARK: Sending

    /// The engine's pending saves split into those this `save` call has a record for, and the
    /// rest: left in the engine's state by a run that ended mid-send (the engine persists its
    /// pending list). The engine skips a change whose record the provider does not give, and
    /// keeps it pending, so it would ask again and again; the rest is removed, and sync sends
    /// those records again from its own list of what is unsent. Deletions are never sync's.
    public static func pendingToSend(_ pending: [CKSyncEngine.PendingRecordZoneChange],
                                     available: Set<CKRecord.ID>) -> (send: [CKSyncEngine.PendingRecordZoneChange], stale: [CKSyncEngine.PendingRecordZoneChange]) {
        var send: [CKSyncEngine.PendingRecordZoneChange] = [], stale: [CKSyncEngine.PendingRecordZoneChange] = []
        for change in pending {
            if case .saveRecord(let id) = change, available.contains(id) { send.append(change) } else { stale.append(change) }
        }
        return (send, stale)
    }

    // MARK: Errors

    /// What a CloudKit failure means for sync, in words the settings page can explain. Codes
    /// only: never record contents. `zonesReady` says whether this account's zones existed
    /// before: a zone missing after that is the user having deleted the app's iCloud data.
    public static func transportError(_ error: any Error, zonesReady: Bool) -> SyncTransportError {
        if let error = error as? SyncTransportError { return error }
        if error is CancellationError { return .retryLater(seconds: 30) }
        if let error = error as? URLError {
            return error.code == .notConnectedToInternet || error.code == .networkConnectionLost ? .offline : .retryLater(seconds: 30)
        }
        guard let error = error as? CKError else { return .rejected("other") }
        let retry = max(1, Int((error.retryAfterSeconds ?? 30).rounded(.up)))
        switch error.code {
        case .networkUnavailable, .networkFailure:
            return .offline
        case .serviceUnavailable, .requestRateLimited, .zoneBusy, .operationCancelled, .serverResponseLost:
            return .retryLater(seconds: retry)
        case .quotaExceeded:
            return .quotaExceeded
        case .notAuthenticated, .accountTemporarilyUnavailable, .managedAccountRestricted:
            return .signedOut
        case .userDeletedZone:
            return .cloudDataDeleted
        case .zoneNotFound:
            return zonesReady ? .cloudDataDeleted : .rejected("zoneNotFound")
        case .unknownItem:
            return .missingFile
        case .partialFailure:
            // The first item's own error says it best; quota and sign-in come first.
            let inner = (error.partialErrorsByItemID ?? [:]).values.map { transportError($0, zonesReady: zonesReady) }
            for wanted in [SyncTransportError.cloudDataDeleted, .signedOut, .quotaExceeded, .offline] where inner.contains(wanted) {
                return wanted
            }
            return inner.first(where: { if case .retryLater = $0 { true } else { false } }) ?? inner.first ?? .rejected("partialFailure")
        case .badContainer, .missingEntitlement, .permissionFailure:
            return .rejected("container")
        case .incompatibleVersion:
            return .rejected("incompatibleVersion")
        case .limitExceeded:
            return .rejected("limitExceeded")
        default:
            return .rejected("ck\(error.code.rawValue)")
        }
    }

    /// The zone the operation needed is not there (yet): create it and try once more.
    public static func isZoneMissing(_ error: any Error) -> Bool {
        guard let error = error as? CKError else { return false }
        if error.code == .zoneNotFound { return true }
        if error.code == .partialFailure {
            return (error.partialErrorsByItemID ?? [:]).values.contains { ($0 as? CKError)?.code == .zoneNotFound }
        }
        return false
    }
}
#endif
