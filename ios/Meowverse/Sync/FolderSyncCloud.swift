#if DEBUG || DRILLS
import Foundation
import MeowverseCore

/// Test switch for iCloud sync (`-MeowverseSyncFolder <name>`): a plain folder inside the app's
/// container stands in for CloudKit, with CloudKit's rules (version tags, conflicts, files by
/// hash). Two test libraries given the same name see each other's changes, so UI tests and the
/// simulator can run sync from end to end without an iCloud account.
///
/// `-MeowverseSyncAccount <name>` names the signed-in account; `-MeowverseSyncFault <kind>`
/// makes it fail the way CloudKit does: `offline`, `signedOut`, `quota` (only photo files don't
/// fit any more), `full` (nothing fits: files and records are refused, as CKError.quotaExceeded
/// is for both), `deleted` (the user deleted the app's iCloud data; cleared by `reset`).
actor FolderSyncCloud: SyncCloud {
    enum Fault: String {
        case offline, signedOut, quota, full, deleted
    }

    private struct Stored: Codable {
        var envelope: SyncEnvelope
        var tag: Int
        var sequence: Int
    }

    private struct Index: Codable {
        var sequence = 0
        var records: [String: Stored] = [:]
    }

    private let folder: URL
    private let account: String
    private var fault: Fault?

    private var indexURL: URL { folder.appendingPathComponent("records.json") }
    private var filesFolder: URL { folder.appendingPathComponent("files", isDirectory: true) }

    init(folder: URL, account: String, fault: Fault?) {
        self.folder = folder
        self.account = account
        self.fault = fault
    }

    func start() async {}
    func setRemoteChangeHandler(_ handler: @escaping @Sendable () -> Void) async {}

    func reset() async {
        // The user chose to start over after the data was deleted: the cloud is empty from here.
        if fault == .deleted {
            fault = nil
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func check(_ allowDeleted: Bool = false) throws {
        switch fault {
        case .offline: throw SyncTransportError.offline
        case .deleted where !allowDeleted: throw SyncTransportError.cloudDataDeleted
        default: break
        }
    }

    private func load() -> Index {
        (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode(Index.self, from: $0) } ?? Index()
    }

    private func store(_ index: Index) throws {
        do { try SyncFiles.writeDurably(try JSONEncoder().encode(index), to: indexURL) } catch {
            throw SyncTransportError.offline
        }
    }

    func accountKey() async throws -> String {
        try check(true)
        if fault == .signedOut { throw SyncTransportError.signedOut }
        return "folder-" + account
    }

    func fetchChanges(since token: SyncToken?) async throws -> SyncFetchResult {
        try check()
        let index = load()
        let after = token.flatMap { Int($0.value) } ?? 0
        let changed = index.records.values.filter { $0.sequence > after }.sorted { $0.sequence < $1.sequence }
        return SyncFetchResult(records: changed.map { SyncServerRecord(envelope: $0.envelope, tag: String($0.tag)) },
                               token: SyncToken(String(index.sequence)), moreComing: false)
    }

    func save(_ saves: [SyncSave]) async throws -> [SyncSaveResult] {
        try check()
        if fault == .full { return saves.map { .failed(name: $0.envelope.name, .quotaExceeded) } }
        var index = load()
        var results: [SyncSaveResult] = []
        for save in saves {
            let name = save.envelope.name
            if let needed = SyncFileGate.neededFiles(save.envelope),
               !needed.contains(where: { fileURL($0).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }) {
                results.append(.failed(name: name, .missingFile))
                continue
            }
            if let stored = index.records[name], save.baseTag != String(stored.tag) {
                results.append(.conflict(SyncServerRecord(envelope: stored.envelope, tag: String(stored.tag))))
                continue
            }
            index.sequence += 1
            let tag = (index.records[name]?.tag ?? 0) + 1
            index.records[name] = Stored(envelope: save.envelope, tag: tag, sequence: index.sequence)
            results.append(.saved(name: name, tag: String(tag)))
        }
        try store(index)
        return results
    }

    private func fileURL(_ sha: String) -> URL? {
        guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else { return nil }
        return filesFolder.appendingPathComponent(sha)
    }

    func hasFile(sha256: String) async throws -> Bool {
        try check()
        guard let url = fileURL(sha256) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func uploadFile(sha256: String, data: Data) async throws {
        try check()
        if fault == .quota || fault == .full { throw SyncTransportError.quotaExceeded }
        guard let url = fileURL(sha256), PhotoIngest.sha256Hex(data) == sha256 else { throw SyncTransportError.rejected("hash") }
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do { try SyncFiles.writeDurably(data, to: url) } catch { throw SyncTransportError.offline }
    }

    func downloadFile(sha256: String) async throws -> Data {
        try check()
        guard let url = fileURL(sha256), let data = try? Data(contentsOf: url) else { throw SyncTransportError.missingFile }
        guard PhotoIngest.sha256Hex(data) == sha256 else { throw SyncTransportError.rejected("hash") }
        return data
    }

    func deleteFile(sha256: String) async throws {
        try check()
        guard let url = fileURL(sha256) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
