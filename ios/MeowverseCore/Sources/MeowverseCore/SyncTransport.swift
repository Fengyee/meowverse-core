import Foundation

// Multi-device iCloud sync: what the cloud must offer. The CloudKit implementation is the next
// stage (docs/ICLOUD_SYNC.md, "传输层"); `SyncMemoryCloud` implements it in memory for tests.

/// Where the last fetch ended (a server change token, opaque to sync).
public struct SyncToken: Codable, Sendable, Equatable {
    public let value: String
    public init(_ value: String) { self.value = value }
}

/// A record as the server has it, with the server's version tag (CloudKit's change tag).
public struct SyncServerRecord: Sendable, Equatable {
    public let envelope: SyncEnvelope
    public let tag: String
    public init(envelope: SyncEnvelope, tag: String) {
        self.envelope = envelope
        self.tag = tag
    }
}

public struct SyncFetchResult: Sendable, Equatable {
    public let records: [SyncServerRecord]
    public let token: SyncToken
    public let moreComing: Bool
    public init(records: [SyncServerRecord], token: SyncToken, moreComing: Bool) {
        self.records = records
        self.token = token
        self.moreComing = moreComing
    }
}

/// A version to save. It replaces the server's only if the server still has `baseTag`.
public struct SyncSave: Sendable, Equatable {
    public let envelope: SyncEnvelope
    public let baseTag: String?
    public init(envelope: SyncEnvelope, baseTag: String?) {
        self.envelope = envelope
        self.baseTag = baseTag
    }
}

public enum SyncSaveResult: Sendable, Equatable {
    case saved(name: String, tag: String)
    /// The server has another version: merge it in and save the merge.
    case conflict(SyncServerRecord)
    case failed(name: String, SyncTransportError)
}

/// Codes only, never record contents.
public enum SyncTransportError: Error, Sendable, Equatable {
    case offline
    /// The user's iCloud storage is full.
    case quotaExceeded
    /// No iCloud account, or iCloud is off for the app.
    case signedOut
    /// A different iCloud account than the one this device last synced with.
    case accountChanged
    /// The user deleted the app's iCloud data (CloudKit: zone deleted / user deleted zone).
    case cloudDataDeleted
    /// The server asked to wait.
    case retryLater(seconds: Int)
    case missingFile
    case rejected(String)
}

public protocol SyncTransport: Sendable {
    /// A stable, opaque key for the signed-in account (never shown, never a name or address).
    func accountKey() async throws -> String
    /// Every record changed since `token` (all records for nil), latest version each.
    func fetchChanges(since token: SyncToken?) async throws -> SyncFetchResult
    func save(_ records: [SyncSave]) async throws -> [SyncSaveResult]
    func hasFile(sha256: String) async throws -> Bool
    func uploadFile(sha256: String, data: Data) async throws
    func downloadFile(sha256: String) async throws -> Data
    func deleteFile(sha256: String) async throws
    /// When the cloud stored this file, by the server's clock; nil when the transport cannot
    /// tell. Clean-up leaves a file stored within `SyncSession.fileGrace` alone: it may belong
    /// to a photo coming back whose record has not arrived yet.
    func fileStoredAt(sha256: String) async throws -> Date?
}

extension SyncTransport {
    /// A transport that cannot tell: clean-up then judges on the records alone.
    public func fileStoredAt(sha256: String) async throws -> Date? { nil }
}
