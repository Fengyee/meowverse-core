import Foundation

/// What the CloudKit transport has fetched, kept on disk until a sync cycle takes it
/// (docs/ICLOUD_SYNC.md, "传输层"). CKSyncEngine fetches on its own (after a push, at launch) and
/// moves its change token on; the records it delivered wait here, so a cycle that runs later, or
/// after the app was killed, still gets them. Never pruned: sync's merges are idempotent, and a
/// cycle that starts over (`SyncToken` nil, or from another epoch) is handed every record again.
///
/// The engine's change token is only as good as this file: `CloudSyncMirrorFiles` writes the
/// engine's state only once the mirror holding what it fetched is on disk, and drops the state
/// when the mirror is gone, so the engine fetches everything again.
///
/// Holds no photo files, only the records' envelopes, CloudKit's version tags and system fields.
public struct CloudSyncMirror: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var envelope: SyncEnvelope
        /// CloudKit's change tag of this version.
        public var tag: String
        /// CKRecord system fields of this version, so a save can name the version it replaces.
        public var systemFields: Data?
        public var sequence: Int
    }

    public static let currentVersion = 1

    public var version = Self.currentVersion
    /// Changes whenever the mirror is emptied: a token from another epoch means "everything".
    public private(set) var epoch: String
    /// `SyncTransport.accountKey` of the account these records came from.
    public var account: String?
    /// Both zones were created (or found) in this account. A missing zone after that means the
    /// user deleted the app's iCloud data.
    public var zonesReady = false
    /// The user deleted the app's iCloud data (zone purged). Every call fails with
    /// `cloudDataDeleted` until the user chooses what to do (`reset`).
    public var cloudDataDeleted = false
    /// The id of the records zone's marker as this device first found or made it. Another id
    /// on the server means the zone was deleted and made again while this device was away.
    public var zoneMarker: String?
    public private(set) var sequence = 0
    public private(set) var entries: [String: Entry] = [:]
    /// Records the engine delivered that could not be read (a payload asset that did not come
    /// down), by name, with the change tag seen. Fetched again one by one; until then no file is
    /// deleted from the cloud, since such a record may list it.
    public private(set) var unfetched: [String: String] = [:]

    public init(epoch: String = UUID().uuidString) {
        self.epoch = epoch
    }

    private enum CodingKeys: String, CodingKey {
        case version, epoch, account, zonesReady, cloudDataDeleted, zoneMarker, sequence, entries, unfetched
    }

    /// Fields added after the first version may be missing: a mirror from before still reads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        epoch = try c.decode(String.self, forKey: .epoch)
        account = try c.decodeIfPresent(String.self, forKey: .account)
        zonesReady = try c.decodeIfPresent(Bool.self, forKey: .zonesReady) ?? false
        cloudDataDeleted = try c.decodeIfPresent(Bool.self, forKey: .cloudDataDeleted) ?? false
        zoneMarker = try c.decodeIfPresent(String.self, forKey: .zoneMarker)
        sequence = try c.decode(Int.self, forKey: .sequence)
        entries = try c.decode([String: Entry].self, forKey: .entries)
        unfetched = try c.decodeIfPresent([String: String].self, forKey: .unfetched) ?? [:]
    }

    /// Takes a version the server has. Returns false when it is the version already held.
    @discardableResult
    public mutating func record(_ envelope: SyncEnvelope, tag: String, systemFields: Data?) -> Bool {
        // Every version handed here is the server's latest at the time (a fetch, a refetch, a
        // save's result, a conflict's server record), so it replaces one that could not be read.
        unfetched[envelope.name] = nil
        if let old = entries[envelope.name], old.tag == tag, old.envelope == envelope {
            if systemFields != nil, old.systemFields != systemFields { entries[envelope.name]?.systemFields = systemFields }
            return false
        }
        sequence += 1
        entries[envelope.name] = Entry(envelope: envelope, tag: tag, systemFields: systemFields, sequence: sequence)
        return true
    }

    /// A record the engine delivered that could not be read: fetched again on its own.
    public mutating func noteUnfetched(_ name: String, tag: String?) {
        unfetched[name] = tag ?? ""
    }

    /// Gone from the server: nothing left to fetch.
    public mutating func forgetUnfetched(_ name: String) {
        unfetched[name] = nil
    }

    public var unfetchedNames: [String] { unfetched.keys.sorted() }

    /// Files in the cloud may be deleted only while every record delivered could be read.
    public var mayDeleteFiles: Bool { unfetched.isEmpty }

    public func entry(named name: String) -> Entry? { entries[name] }

    /// Everything taken after `token`, oldest first; every record for nil or another epoch's
    /// token. The token handed back claims no more than `through` (default: everything held), so
    /// records only in memory are handed out again after a relaunch.
    public func changes(since token: SyncToken?, through: Int? = nil) -> SyncFetchResult {
        let after = token.flatMap(sequence(in:)) ?? 0
        let changed = entries.values.filter { $0.sequence > after }.sorted { $0.sequence < $1.sequence }
        return SyncFetchResult(records: changed.map { SyncServerRecord(envelope: $0.envelope, tag: $0.tag) },
                               token: SyncToken("\(epoch):\(min(through ?? sequence, sequence))"), moreComing: false)
    }

    /// Forgets every record (another account, or the cloud data was deleted and the user chose
    /// what to do). The next cycle with an old token gets everything there is.
    public mutating func reset(account: String? = nil) {
        epoch = UUID().uuidString
        self.account = account
        zonesReady = false
        cloudDataDeleted = false
        zoneMarker = nil
        entries = [:]
        unfetched = [:]
        // Kept increasing so a token from before can never look current.
        sequence += 1
    }

    private func sequence(in token: SyncToken) -> Int? {
        let parts = token.value.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == Substring(epoch), let value = Int(parts[1]) else { return nil }
        return value
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// nil for a file this version cannot read (damaged, or written by a newer build). The
    /// transport must not then keep the engine's state, whose token has moved past the records
    /// this file held: `CloudSyncMirrorFiles.load` drops both, and the engine fetches everything.
    public static func decode(_ data: Data) -> CloudSyncMirror? {
        guard let mirror = try? JSONDecoder().decode(CloudSyncMirror.self, from: data),
              mirror.version <= currentVersion else { return nil }
        return mirror
    }
}

/// The marker record in the records zone (docs/ICLOUD_SYNC.md §11): a random id written once per
/// zone. A device that was away when the zone was deleted and made again elsewhere never hears
/// of the deletion, and its records not waiting to be sent would never reach the new zone;
/// it finds out because the marker's id is not the one it knows.
public enum CloudSyncZoneMarker {
    public enum Verdict: Equatable, Sendable {
        /// The zone this device knows.
        case same
        /// First look at this zone (or after starting over): this is its marker.
        case adopt(String)
        /// No marker yet: make one (if another device made one meanwhile, adopt that).
        case create
        /// Another zone than the one this device synced with: as if the deletion had been seen.
        case replaced
    }

    public static func verdict(known: String?, onServer: String?) -> Verdict {
        switch (known, onServer) {
        case (nil, nil): .create
        case (nil, let server?): .adopt(server)
        case (let known?, let server?) where known == server: .same
        default: .replaced
        }
    }

    public static func newID() -> String { UUID().uuidString }
}

/// The mirror and CKSyncEngine's state on disk, in the order that keeps them true to each other
/// (docs/ICLOUD_SYNC.md §11). The engine's state carries its change token: written while the
/// mirror holding what it fetched is not on disk, a relaunch would resume past records nobody
/// ever kept. So the state is written only after the mirror; a mirror that is gone or cannot be
/// read takes the state with it; and the token handed to a cycle claims only what is on disk.
public struct CloudSyncMirrorFiles: Sendable {
    public typealias Writer = @Sendable (Data, URL) throws -> Void

    public let mirrorURL: URL
    public let stateURL: URL
    private let write: Writer
    /// The mirror as last written; nil while this run has written or read none.
    private var onDisk: CloudSyncMirror?
    /// The engine's saved state is not to be used even if deleting it failed.
    private var stateDiscarded = false

    /// `write` must replace a file atomically (the app's `SyncFiles.writeDurably`).
    public init(folder: URL, write: @escaping Writer) {
        mirrorURL = folder.appendingPathComponent("mirror.json")
        stateURL = folder.appendingPathComponent("engine-state.json")
        self.write = write
    }

    /// The mirror on disk, or an empty one. Without a readable mirror the engine's state goes
    /// too: its token has moved past records that only the lost mirror held.
    public mutating func load() -> CloudSyncMirror {
        if let data = try? Data(contentsOf: mirrorURL), let mirror = CloudSyncMirror.decode(data) {
            onDisk = mirror
            return mirror
        }
        onDisk = nil
        dropEngineState()
        return CloudSyncMirror()
    }

    /// The engine's saved state; nil once it no longer matches the mirror.
    public func engineState() -> Data? {
        stateDiscarded ? nil : try? Data(contentsOf: stateURL)
    }

    /// Returns false when the mirror could not be written.
    @discardableResult
    public mutating func save(_ mirror: CloudSyncMirror) -> Bool {
        guard let data = try? mirror.encoded() else { return false }
        do { try write(data, mirrorURL) } catch { return false }
        onDisk = mirror
        return true
    }

    /// Writes the engine's state only with the mirror it describes on disk: the mirror first if
    /// it changed since it was last written. Returns false when the state was not written; the
    /// state already on disk is older and stays true to the mirror on disk.
    @discardableResult
    public mutating func saveEngineState(_ data: Data, mirror: CloudSyncMirror) -> Bool {
        if onDisk != mirror, !save(mirror) { return false }
        do { try write(data, stateURL) } catch { return false }
        stateDiscarded = false
        return true
    }

    /// The engine starts from nothing next time (another account, a reset, a lost mirror).
    public mutating func dropEngineState() {
        stateDiscarded = true
        try? FileManager.default.removeItem(at: stateURL)
    }

    /// What a cycle takes. The token claims no more than the mirror on disk: after a relaunch the
    /// engine fetches again what only memory held, and the records reach the cycle once more.
    public func changes(since token: SyncToken?, in mirror: CloudSyncMirror) -> SyncFetchResult {
        guard let onDisk, onDisk.epoch == mirror.epoch else { return mirror.changes(since: token, through: 0) }
        return mirror.changes(since: token, through: onDisk.sequence)
    }
}
