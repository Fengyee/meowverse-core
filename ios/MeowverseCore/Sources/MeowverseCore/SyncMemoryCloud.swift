import Foundation

/// The cloud in memory, for tests and drills: per-record version tags like CloudKit's, a change
/// log with tokens, files by hash, and faults a test can switch on per device.
public actor SyncMemoryCloud {
    struct Stored {
        var envelope: SyncEnvelope
        var tag: Int
        var sequence: Int
    }

    private var records: [String: Stored] = [:]
    private var history: [String: [SyncServerRecord]] = [:]
    private var sequence = 0
    private var files: [String: Data] = [:]
    private var storedAt: [String: Date] = [:]
    /// The cloud's own clock, for `fileStoredAt`; nil = it cannot tell (as a transport may not).
    private let clock: (@Sendable () -> Date)?
    private var rng: SeededRandom

    public var account = "account-1"
    /// Records per fetch page.
    public var pageSize = 25
    /// Total file bytes allowed; nil = no limit.
    public var quotaBytes: Int?
    /// Fetches also return duplicates and older versions, shuffled.
    public var messyDelivery = false

    private var offline = Set<String>()
    private var failingSaves: [String: Int] = [:]
    private var savesBeforeDrop: [String: Int] = [:]

    public init(seed: UInt64 = 1, clock: (@Sendable () -> Date)? = nil) {
        rng = SeededRandom(seed: seed)
        self.clock = clock
    }

    public nonisolated func endpoint(_ device: String) -> SyncMemoryEndpoint {
        SyncMemoryEndpoint(cloud: self, device: device)
    }

    // MARK: Faults

    public func setOffline(_ device: String, _ isOffline: Bool) {
        if isOffline { offline.insert(device) } else { offline.remove(device) }
    }

    /// The next `count` save calls from `device` fail before saving anything.
    public func failSaves(_ device: String, count: Int) { failingSaves[device] = count }

    /// The next save call from `device` stores the first `count` records, then the connection
    /// drops: the device gets an error and does not learn what was saved.
    public func dropAfterSaving(_ device: String, count: Int) { savesBeforeDrop[device] = count }

    public func setQuota(_ bytes: Int?) { quotaBytes = bytes }
    public func setMessyDelivery(_ on: Bool) { messyDelivery = on }
    public func setAccount(_ key: String) { account = key }

    // MARK: Inspection

    public var allEnvelopes: [SyncEnvelope] { records.keys.sorted().map { records[$0]!.envelope } }
    public var fileHashes: Set<String> { Set(files.keys) }
    public var fileBytes: Int { files.values.reduce(0) { $0 + $1.count } }

    // MARK: Transport

    func check(_ device: String) throws {
        if offline.contains(device) { throw SyncTransportError.offline }
    }

    func fetch(_ device: String, since token: SyncToken?) throws -> SyncFetchResult {
        try check(device)
        let after = token.flatMap { Int($0.value) } ?? 0
        let changed = records.values.filter { $0.sequence > after }.sorted { $0.sequence < $1.sequence }
        let page = Array(changed.prefix(pageSize))
        var out = page.map { SyncServerRecord(envelope: $0.envelope, tag: String($0.tag)) }
        if messyDelivery {
            for stored in page {
                let older = history[stored.envelope.name] ?? []
                if let stale = older.randomElement(using: &rng), Bool.random(using: &rng) { out.append(stale) }
                if Bool.random(using: &rng) { out.append(SyncServerRecord(envelope: stored.envelope, tag: String(stored.tag))) }
            }
            out.shuffle(using: &rng)
        }
        let last = page.last?.sequence ?? max(after, 0)
        return SyncFetchResult(records: out, token: SyncToken(String(last)), moreComing: changed.count > page.count)
    }

    func save(_ device: String, _ saves: [SyncSave]) throws -> [SyncSaveResult] {
        try check(device)
        if let left = failingSaves[device], left > 0 {
            failingSaves[device] = left - 1
            throw SyncTransportError.offline
        }
        let dropAfter = savesBeforeDrop.removeValue(forKey: device)
        var results: [SyncSaveResult] = []
        for (index, save) in saves.enumerated() {
            if let dropAfter, index >= dropAfter { throw SyncTransportError.offline }
            let name = save.envelope.name
            if let stored = records[name], save.baseTag != String(stored.tag) {
                results.append(.conflict(SyncServerRecord(envelope: stored.envelope, tag: String(stored.tag))))
                continue
            }
            sequence += 1
            let tag = (records[name]?.tag ?? 0) + 1
            records[name] = Stored(envelope: save.envelope, tag: tag, sequence: sequence)
            history[name, default: []].append(SyncServerRecord(envelope: save.envelope, tag: String(tag)))
            results.append(.saved(name: name, tag: String(tag)))
        }
        return results
    }

    func hasFile(_ device: String, _ sha: String) throws -> Bool {
        try check(device)
        return files[sha] != nil
    }

    func upload(_ device: String, _ sha: String, _ data: Data) throws {
        try check(device)
        guard files[sha] == nil else { return }
        if let quotaBytes, fileBytes + data.count > quotaBytes { throw SyncTransportError.quotaExceeded }
        files[sha] = data
        storedAt[sha] = clock?()
    }

    func download(_ device: String, _ sha: String) throws -> Data {
        try check(device)
        guard let data = files[sha] else { throw SyncTransportError.missingFile }
        return data
    }

    func delete(_ device: String, _ sha: String) throws {
        try check(device)
        files[sha] = nil
        storedAt[sha] = nil
    }

    func stored(_ device: String, _ sha: String) throws -> Date? {
        try check(device)
        return files[sha] == nil ? nil : storedAt[sha]
    }
}

public struct SyncMemoryEndpoint: SyncTransport {
    let cloud: SyncMemoryCloud
    let device: String

    public func accountKey() async throws -> String {
        try await cloud.check(device)
        return await cloud.account
    }
    public func fetchChanges(since token: SyncToken?) async throws -> SyncFetchResult { try await cloud.fetch(device, since: token) }
    public func save(_ records: [SyncSave]) async throws -> [SyncSaveResult] { try await cloud.save(device, records) }
    public func hasFile(sha256: String) async throws -> Bool { try await cloud.hasFile(device, sha256) }
    public func uploadFile(sha256: String, data: Data) async throws { try await cloud.upload(device, sha256, data) }
    public func downloadFile(sha256: String) async throws -> Data { try await cloud.download(device, sha256) }
    public func deleteFile(sha256: String) async throws { try await cloud.delete(device, sha256) }
    public func fileStoredAt(sha256: String) async throws -> Date? { try await cloud.stored(device, sha256) }
}

/// SplitMix64, so a fake cloud's mess is the same on every run.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
