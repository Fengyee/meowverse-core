import CloudKit
import CryptoKit
import Foundation
import MeowverseCore
import os

/// `SyncTransport` on CloudKit (docs/ICLOUD_SYNC.md, "传输层"): the private database, sync's
/// records in the library's records zone moved by CKSyncEngine, photo files as immutable
/// `file.<sha256>` records with a CKAsset in the library's files zone, read and written directly.
/// The user's home uses the zones `Meowverse` and `MeowverseFiles`; any other library (a test
/// library) has zones of its own (`CloudKitSyncZones.forLibrary`).
///
/// CKSyncEngine fetches on its own (at launch, after a push) and moves its change token on. What
/// it delivers is written to `CloudSyncMirror` on disk before the engine's new state is (never
/// the state without the mirror: `CloudSyncMirrorFiles`), and the cycle takes it from there with
/// its own token, so nothing fetched is lost if the app dies before a cycle runs. A record that
/// cannot be read as delivered is fetched again on its own, never skipped. Sends happen only
/// inside `save`, which names the version each record replaces (CloudKit's system fields), so a
/// record changed elsewhere comes back as a conflict to merge and is never overwritten.
///
/// Every failure is a `SyncTransportError`; nothing here says "synced" for something that is not.
actor CloudKitSyncTransport: SyncCloud, CKSyncEngineDelegate {
    private let container: CKContainer
    private let zones: CloudKitSyncZones
    private let scratch: URL
    private var engine: CKSyncEngine?
    private var files: CloudSyncMirrorFiles
    private var mirror = CloudSyncMirror()
    /// Read on first use, not in `init`: a transport made while the previous one's `reset` is
    /// still queued must see the file that reset leaves.
    private var mirrorLoaded = false
    /// Records of the `save` call in progress, by id, for the engine to ask for.
    private var outgoing: [CKRecord.ID: CKRecord] = [:]
    private var outgoingEnvelopes: [String: SyncEnvelope] = [:]
    private var results: [String: SyncSaveResult] = [:]
    /// Conflicts of the `save` in progress whose server record came without its payload asset
    /// (CloudKit does not download assets for a conflict's server record): fetched on their own.
    private var conflictsToRead: Set<String> = []
    private var fetchedSomething = false
    /// Files known to be in the cloud (this account, this run): a photo record waits for one.
    private var filesInCloud: Set<String> = []
    /// Answers to "is this file in the cloud" for the part of the cycle in progress, asked many
    /// at a time. Forgotten when a cycle starts and once a fetch brought a fresh view.
    private var fileAnswers: [String: Bool] = [:]
    private var fileCandidates: [String]?
    /// The zone marker was checked in this cycle.
    private var zoneChecked = false
    private var onRemoteChange: (@Sendable () -> Void)?
    private let log = Logger(subsystem: "app.meowverse", category: "syncTransport")

    private var database: CKDatabase { container.privateCloudDatabase }
    /// Records fetched again one by one per call (those the engine delivered unreadable).
    private static let refetchBatch = 50
    /// Files asked about per existence check.
    private static let fileCheckBatch = 100

    /// `folder` holds the engine's state and the mirror; it is this app's own, per library, and
    /// so are `zones`.
    init(containerIdentifier: String, folder: URL, zones: CloudKitSyncZones) {
        container = CKContainer(identifier: containerIdentifier)
        self.zones = zones
        files = CloudSyncMirrorFiles(folder: folder) { data, url in try SyncFiles.writeDurably(data, to: url) }
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MeowverseSync", isDirectory: true)
    }

    // MARK: SyncCloud

    func start() async {
        loadMirror()
        _ = syncEngine()
    }

    func setRemoteChangeHandler(_ handler: @escaping @Sendable () -> Void) async {
        onRemoteChange = handler
    }

    func reset() async {
        await dropEngine()
        loadMirror()
        mirror.reset()
        saveMirror()
        log.notice("sync transport reset")
    }

    func recordsNotFetched() async -> Int {
        loadMirror()
        return mirror.unfetched.count
    }

    // MARK: SyncTransport

    func accountKey() async throws -> String {
        loadMirror()
        // Each cycle starts here: what it learns about files and the zone, it learns afresh.
        fileAnswers = [:]
        fileCandidates = nil
        zoneChecked = false
        let status: CKAccountStatus
        do { status = try await container.accountStatus() } catch { throw mapped(error) }
        switch status {
        case .available: break
        case .couldNotDetermine: throw SyncTransportError.offline
        default: throw SyncTransportError.signedOut
        }
        let id: CKRecord.ID
        do { id = try await container.userRecordID() } catch { throw mapped(error) }
        // Hashed: the opaque CloudKit user id itself is never stored or shown.
        let key = "ck-" + SHA256.hash(data: Data(id.recordName.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        if mirror.account != key {
            if mirror.account != nil {
                // Records of another account: never handed to this one.
                await dropEngine()
                mirror.reset(account: key)
                log.notice("sync transport: account differs from the mirror's, started over")
            } else {
                mirror.account = key
            }
            saveMirror()
        }
        return key
    }

    func fetchChanges(since token: SyncToken?) async throws -> SyncFetchResult {
        loadMirror()
        try checkUsable()
        try await ensureZones()
        try await checkZoneMarker()
        do {
            try await syncEngine().fetchChanges(CKSyncEngine.FetchChangesOptions(scope: .zoneIDs([zones.recordsZoneID])))
        } catch {
            throw mapped(error)
        }
        try checkUsable()
        await refetchUnreadable()
        // Files are judged on the view just fetched: answers from before it are asked again.
        fileAnswers = [:]
        fileCandidates = nil
        return files.changes(since: token, in: mirror)
    }

    func save(_ saves: [SyncSave]) async throws -> [SyncSaveResult] {
        loadMirror()
        try checkUsable()
        try await ensureZones()
        try await checkZoneMarker()
        var answered: [String: SyncSaveResult] = [:]
        // A photo record never goes before a file it points at.
        for save in saves {
            guard let needed = SyncFileGate.neededFiles(save.envelope) else { continue }
            if try await !anyFileInCloud(needed) {
                answered[save.envelope.name] = .failed(name: save.envelope.name, .missingFile)
            }
        }
        var left = saves.filter { answered[$0.envelope.name] == nil }
        // A second round only for records the engine did not answer (a batch that failed as a
        // whole): an answered record is never sent twice from one call.
        for _ in 0..<2 where !left.isEmpty {
            var assetFiles: [URL] = []
            defer { for file in assetFiles { try? FileManager.default.removeItem(at: file) } }
            outgoing = [:]
            outgoingEnvelopes = [:]
            results = [:]
            conflictsToRead = []
            for save in left {
                let name = save.envelope.name
                // The version this save replaces; without it the server refuses a record it has.
                let fields = save.baseTag.flatMap { tag in mirror.entry(named: name).flatMap { $0.tag == tag ? $0.systemFields : nil } }
                do {
                    let (record, file) = try CloudKitSyncCoding.record(for: save.envelope, systemFields: fields, zones: zones, scratch: scratch)
                    if let file { assetFiles.append(file) }
                    outgoing[record.recordID] = record
                    outgoingEnvelopes[name] = save.envelope
                } catch {
                    answered[name] = .failed(name: name, .rejected("encode"))
                }
            }
            let changes = outgoing.keys.map { CKSyncEngine.PendingRecordZoneChange.saveRecord($0) }
            guard !changes.isEmpty else { break }
            let engine = syncEngine()
            engine.state.add(pendingRecordZoneChanges: changes)
            do {
                try await engine.sendChanges(CKSyncEngine.SendChangesOptions(scope: .recordIDs(Array(outgoing.keys))))
            } catch {
                engine.state.remove(pendingRecordZoneChanges: changes)
                clearOutgoing()
                throw mapped(error)
            }
            // Sync keeps its own list of what is unsent; the engine never resends on its own.
            engine.state.remove(pendingRecordZoneChanges: changes)
            answered.merge(results) { _, new in new }
            let unread = conflictsToRead
            clearOutgoing()
            if !unread.isEmpty { answered.merge(await readConflicts(unread)) { _, new in new } }
            saveMirror()
            try checkUsable()
            left = left.filter { answered[$0.envelope.name] == nil }
        }
        return saves.map { answered[$0.envelope.name] ?? .failed(name: $0.envelope.name, .retryLater(seconds: 30)) }
    }

    /// Asks about many files in one request: the one wanted, and the other files of the photos
    /// the mirror holds that this part of the cycle has not asked about yet. A cycle's checks
    /// (sending, repairing, cleaning up) are then answered from that, not one round trip each.
    func hasFile(sha256: String) async throws -> Bool {
        loadMirror()
        try checkUsable()
        try await ensureZones()
        if let known = fileAnswers[sha256] { return known }
        if fileCandidates == nil { fileCandidates = CloudKitSyncCoding.photoFileHashes(mirror.entries.values.map(\.envelope)) }
        var batch = CloudKitSyncCoding.fileCheckBatch(asking: sha256, candidates: fileCandidates ?? [], known: Set(fileAnswers.keys),
                                                      limit: Self.fileCheckBatch)
        let found: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            found = try await database.records(for: batch.map { CloudKitSyncCoding.fileRecordID(sha256: $0, zones: zones) }, desiredKeys: [])
        } catch let error as CKError where error.code == .limitExceeded && batch.count > 1 {
            // The server's per-request limit is not documented: the one file on its own.
            batch = [sha256]
            do { found = try await database.records(for: [CloudKitSyncCoding.fileRecordID(sha256: sha256, zones: zones)], desiredKeys: []) } catch {
                throw mapped(error)
            }
        } catch {
            throw mapped(error)
        }
        let ids = batch.map { CloudKitSyncCoding.fileRecordID(sha256: $0, zones: zones) }
        for (sha, id) in zip(batch, ids) {
            switch found[id] {
            case .success:
                fileAnswers[sha] = true
                filesInCloud.insert(sha)
            case .failure(let error) where (error as? CKError)?.code == .unknownItem:
                fileAnswers[sha] = false
            default:
                break
            }
        }
        if let known = fileAnswers[sha256] { return known }
        if case .failure(let error) = found[ids[0]] { throw mapped(error) }
        return false
    }

    /// The server's creation date of the file record. Clean-up leaves a file stored within the
    /// last day alone: it may belong to a photo coming back whose record has not arrived yet.
    func fileStoredAt(sha256: String) async throws -> Date? {
        loadMirror()
        try checkUsable()
        let id = CloudKitSyncCoding.fileRecordID(sha256: sha256, zones: zones)
        let found: Result<CKRecord, any Error>?
        do { found = try await database.records(for: [id], desiredKeys: [])[id] } catch { throw mapped(error) }
        switch found {
        case .success(let record): return record.creationDate
        case .failure(let error) where (error as? CKError)?.code == .unknownItem: return nil
        case .failure(let error): throw mapped(error)
        case nil: return nil
        }
    }

    func uploadFile(sha256: String, data: Data) async throws {
        loadMirror()
        try checkUsable()
        try await ensureZones()
        guard PhotoIngest.sha256Hex(data) == sha256 else { throw SyncTransportError.rejected("hash") }
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appendingPathComponent("upload-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        do { try data.write(to: file) } catch { throw SyncTransportError.rejected("scratch") }
        let record = CloudKitSyncCoding.fileRecord(sha256: sha256, file: file, byteSize: data.count, zones: zones)
        let saved: Result<CKRecord, any Error>?
        do {
            saved = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged,
                                                     atomically: false).saveResults[record.recordID]
        } catch {
            throw mapped(error)
        }
        switch saved {
        case .success:
            filesInCloud.insert(sha256)
            fileAnswers[sha256] = true
        // Files never change: one already there under this hash is this file.
        case .failure(let error) where (error as? CKError)?.code == .serverRecordChanged:
            filesInCloud.insert(sha256)
            fileAnswers[sha256] = true
        case .failure(let error): throw mapped(error)
        case nil: throw SyncTransportError.retryLater(seconds: 30)
        }
    }

    func downloadFile(sha256: String) async throws -> Data {
        loadMirror()
        try checkUsable()
        let id = CloudKitSyncCoding.fileRecordID(sha256: sha256, zones: zones)
        let found: Result<CKRecord, any Error>?
        do { found = try await database.records(for: [id], desiredKeys: ["file"])[id] } catch { throw mapped(error) }
        switch found {
        case .success(let record):
            // A copy that does not hash to its name is never handed on as the photo.
            guard let data = CloudKitSyncCoding.fileData(from: record, sha256: sha256) else {
                log.error("sync transport: a downloaded file did not match its hash")
                throw SyncTransportError.rejected("hash")
            }
            return data
        case .failure(let error): throw mapped(error)
        case nil: throw SyncTransportError.missingFile
        }
    }

    func deleteFile(sha256: String) async throws {
        loadMirror()
        try checkUsable()
        // A record not read yet may list this file: nothing is deleted until every one is read.
        guard mirror.mayDeleteFiles else { throw SyncTransportError.retryLater(seconds: 30) }
        let id = CloudKitSyncCoding.fileRecordID(sha256: sha256, zones: zones)
        let deleted: Result<Void, any Error>?
        do {
            deleted = try await database.modifyRecords(saving: [], deleting: [id], atomically: false).deleteResults[id]
        } catch {
            throw mapped(error)
        }
        if case .failure(let error) = deleted, (error as? CKError)?.code != .unknownItem { throw mapped(error) }
        filesInCloud.remove(sha256)
        fileAnswers[sha256] = false
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        loadMirror()
        // An engine dropped after an account change may still finish an event.
        guard syncEngine === engine else { return }
        switch event {
        case .stateUpdate(let update):
            // Only with the mirror holding what was fetched on disk: a token past records nobody
            // kept would never bring them again.
            guard let data = try? JSONEncoder().encode(update.stateSerialization) else { return }
            if !files.saveEngineState(data, mirror: mirror) {
                log.error("sync transport: engine state not saved, the mirror is not on disk")
            }
        case .accountChange(let change):
            await accountChanged(change)
        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { zones.names.contains($0.zoneID.zoneName) }) {
                // Deleted in Settings (purged), by a reset of the encrypted data, or by another
                // device. The user decides what happens next; nothing is uploaded meanwhile.
                mirror.cloudDataDeleted = true
                saveMirror()
                log.notice("sync transport: the cloud zone was deleted")
                fetchedSomething = true
            }
        case .fetchedRecordZoneChanges(let changes):
            fetchedRecords(changes)
        case .sentRecordZoneChanges(let sent):
            sentChanges(sent)
        case .didFetchChanges:
            if fetchedSomething {
                fetchedSomething = false
                onRemoteChange?()
            }
        default:
            break
        }
    }

    /// The engine's own fetches (at launch, after a push) take the records zone only: the files
    /// zone holds every copy of every photo, read one by one when a photo needs it.
    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.scope = .zoneIDs([zones.recordsZoneID])
        return options
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        // An engine dropped after an account change never gets this account's records.
        guard syncEngine === engine else { return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        // A change with no record here (left by a run that ended mid-send) is removed: the
        // engine skips a change the provider has no record for but keeps it pending, and would
        // keep asking. Sync resends those records from its own list.
        let split = CloudKitSyncCoding.pendingToSend(pending, available: Set(outgoing.keys))
        if !split.stale.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: split.stale)
            log.notice("sync transport: removed \(split.stale.count, privacy: .public) pending changes without a record")
        }
        guard !split.send.isEmpty else { return nil }
        let records = outgoing
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: split.send) { id in records[id] }
    }

    // MARK: Internals

    private func syncEngine() -> CKSyncEngine {
        if let engine { return engine }
        loadMirror()
        let saved = files.engineState().flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let made = CKSyncEngine(CKSyncEngine.Configuration(database: database, stateSerialization: saved, delegate: self))
        engine = made
        // Saves a run left pending when it ended mid-send: sync resends them from its own list.
        let stale = made.state.pendingRecordZoneChanges
        if !stale.isEmpty {
            made.state.remove(pendingRecordZoneChanges: stale)
            log.notice("sync transport: dropped \(stale.count, privacy: .public) pending changes from an earlier run")
        }
        return made
    }

    private func fetchedRecords(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        var touched = false
        for modification in changes.modifications {
            let record = modification.record
            switch CloudKitSyncCoding.classify(record, zones: zones) {
            case .notOurs:
                continue
            case .zoneMarker(let marker):
                // The zone was deleted and made again elsewhere (seen as it happens).
                if let known = mirror.zoneMarker, known != marker, !mirror.cloudDataDeleted {
                    mirror.cloudDataDeleted = true
                    touched = true
                    fetchedSomething = true
                    log.notice("sync transport: the zone was made again elsewhere")
                }
            case .envelope(let envelope):
                touched = true
                guard let tag = record.recordChangeTag else {
                    mirror.noteUnfetched(envelope.name, tag: nil)
                    continue
                }
                if mirror.record(envelope, tag: tag, systemFields: CloudKitSyncCoding.systemFields(of: record)) { fetchedSomething = true }
            case .unreadable(let name):
                // Most often a payload asset that did not come down. Kept, fetched again on its
                // own; the settings page counts it until then.
                mirror.noteUnfetched(name, tag: record.recordChangeTag)
                touched = true
                fetchedSomething = true
                log.error("sync transport: a record could not be read as fetched; fetching it again")
            }
        }
        for deletion in changes.deletions where deletion.recordID.zoneID.zoneName == zones.recordsZoneName {
            // Sync never deletes records; one that went away has nothing left to fetch.
            if mirror.unfetched[deletion.recordID.recordName] != nil {
                mirror.forgetUnfetched(deletion.recordID.recordName)
                touched = true
            }
        }
        if touched { saveMirror() }
    }

    /// The records the engine delivered unreadable, fetched again one by one (with their
    /// assets). One that is still unreadable stays listed; one gone from the server is forgotten.
    private func refetchUnreadable() async {
        let names = Array(mirror.unfetchedNames.prefix(Self.refetchBatch))
        guard !names.isEmpty else { return }
        let ids = names.map { CKRecord.ID(recordName: $0, zoneID: zones.recordsZoneID) }
        let found: [CKRecord.ID: Result<CKRecord, any Error>]
        do { found = try await database.records(for: ids) } catch {
            log.notice("sync transport: records not read yet could not be fetched again")
            return
        }
        for id in ids {
            switch found[id] {
            case .success(let record):
                if case .envelope(let envelope) = CloudKitSyncCoding.classify(record, zones: zones), let tag = record.recordChangeTag {
                    mirror.record(envelope, tag: tag, systemFields: CloudKitSyncCoding.systemFields(of: record))
                }
            case .failure(let error) where (error as? CKError)?.code == .unknownItem:
                mirror.forgetUnfetched(id.recordName)
            default:
                break
            }
        }
        saveMirror()
    }

    /// Conflicts whose server record could not be read from the error: the server's version,
    /// fetched on its own, is merged like any conflict.
    private func readConflicts(_ names: Set<String>) async -> [String: SyncSaveResult] {
        let ids = names.sorted().map { CKRecord.ID(recordName: $0, zoneID: zones.recordsZoneID) }
        let found: [CKRecord.ID: Result<CKRecord, any Error>]
        do { found = try await database.records(for: ids) } catch {
            let failure = mapped(error)
            return Dictionary(uniqueKeysWithValues: names.map { ($0, SyncSaveResult.failed(name: $0, failure)) })
        }
        var answers: [String: SyncSaveResult] = [:]
        for id in ids {
            let name = id.recordName
            switch found[id] {
            case .success(let record):
                if case .envelope(let envelope) = CloudKitSyncCoding.classify(record, zones: zones), let tag = record.recordChangeTag {
                    mirror.record(envelope, tag: tag, systemFields: CloudKitSyncCoding.systemFields(of: record))
                    answers[name] = .conflict(SyncServerRecord(envelope: envelope, tag: tag))
                } else {
                    answers[name] = .failed(name: name, .rejected("unreadableServerRecord"))
                }
            case .failure(let error):
                answers[name] = .failed(name: name, mapped(error))
            case nil:
                answers[name] = .failed(name: name, .retryLater(seconds: 30))
            }
        }
        return answers
    }

    /// Once per cycle: the records zone is still the one this device synced with. A zone deleted
    /// and made again while this device was away looks like any zone, and records this device
    /// does not have waiting would never reach it; another marker id says so, and the cycle stops
    /// as for a deletion seen as it happened (the user chooses to upload this home again).
    private func checkZoneMarker() async throws {
        guard !zoneChecked else { return }
        let id = CloudKitSyncCoding.markerRecordID(zones: zones)
        let found: Result<CKRecord, any Error>?
        do { found = try await database.records(for: [id])[id] } catch { throw mapped(error) }
        let onServer: String?
        switch found {
        case .success(let record):
            guard case .zoneMarker(let marker) = CloudKitSyncCoding.classify(record, zones: zones) else {
                throw SyncTransportError.rejected("zoneMarker")
            }
            onServer = marker
        case .failure(let error) where (error as? CKError)?.code == .unknownItem:
            onServer = nil
        case .failure(let error):
            throw mapped(error)
        case nil:
            throw SyncTransportError.retryLater(seconds: 30)
        }
        switch CloudSyncZoneMarker.verdict(known: mirror.zoneMarker, onServer: onServer) {
        case .same:
            break
        case .adopt(let marker):
            mirror.zoneMarker = marker
            saveMirror()
        case .create:
            mirror.zoneMarker = try await createZoneMarker()
            saveMirror()
        case .replaced:
            mirror.cloudDataDeleted = true
            saveMirror()
            log.notice("sync transport: the zone is not the one this device synced with")
            throw SyncTransportError.cloudDataDeleted
        }
        zoneChecked = true
    }

    /// A new marker; one another device made meanwhile is the zone's.
    private func createZoneMarker() async throws -> String {
        let fresh = CloudSyncZoneMarker.newID()
        let record = CloudKitSyncCoding.markerRecord(id: fresh, zones: zones)
        let saved: Result<CKRecord, any Error>?
        do {
            saved = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged,
                                                     atomically: false).saveResults[record.recordID]
        } catch {
            throw mapped(error)
        }
        switch saved {
        case .success:
            return fresh
        case .failure(let error) where (error as? CKError)?.code == .serverRecordChanged:
            guard let server = (error as? CKError)?.serverRecord,
                  case .zoneMarker(let theirs) = CloudKitSyncCoding.classify(server, zones: zones) else {
                throw SyncTransportError.retryLater(seconds: 30)
            }
            return theirs
        case .failure(let error):
            throw mapped(error)
        case nil:
            throw SyncTransportError.retryLater(seconds: 30)
        }
    }

    private func anyFileInCloud(_ hashes: [String]) async throws -> Bool {
        if hashes.contains(where: filesInCloud.contains) { return true }
        for sha in hashes where try await hasFile(sha256: sha) { return true }
        return false
    }

    private func dropEngine() async {
        if let engine { await engine.cancelOperations() }
        engine = nil
        filesInCloud = []
        fileAnswers = [:]
        fileCandidates = nil
        files.dropEngineState()
    }

    private func accountChanged(_ change: CKSyncEngine.Event.AccountChange) async {
        switch change.changeType {
        case .signIn:
            log.notice("sync transport: signed in")
        case .signOut, .switchAccounts:
            // The engine's state and the records belong to the account that left. The library
            // is not touched; the next cycle sees the new account and stops to ask.
            log.notice("sync transport: signed out or switched accounts")
            await dropEngine()
            mirror.reset()
            saveMirror()
        @unknown default:
            break
        }
        onRemoteChange?()
    }

    private func sentChanges(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) {
        for record in sent.savedRecords {
            let name = record.recordID.recordName
            guard let envelope = outgoingEnvelopes[name] ?? CloudKitSyncCoding.envelope(from: record, zones: zones),
                  let tag = record.recordChangeTag else { continue }
            mirror.record(envelope, tag: tag, systemFields: CloudKitSyncCoding.systemFields(of: record))
            results[name] = .saved(name: name, tag: tag)
        }
        for failure in sent.failedRecordSaves {
            let name = failure.record.recordID.recordName
            switch failure.error.code {
            case .serverRecordChanged:
                // Another version is there: sync merges it and saves the merge. Its payload
                // asset, if it has one, is not downloaded with the error: then it is fetched.
                guard let server = failure.error.serverRecord,
                      case .envelope(let envelope) = CloudKitSyncCoding.classify(server, zones: zones),
                      let tag = server.recordChangeTag else {
                    conflictsToRead.insert(name)
                    continue
                }
                mirror.record(envelope, tag: tag, systemFields: CloudKitSyncCoding.systemFields(of: server))
                results[name] = .conflict(SyncServerRecord(envelope: envelope, tag: tag))
            case .batchRequestFailed:
                // Failed only because another record of the batch did: tried again.
                continue
            case .zoneNotFound, .userDeletedZone:
                mirror.cloudDataDeleted = true
                results[name] = .failed(name: name, .cloudDataDeleted)
            default:
                results[name] = .failed(name: name, mapped(failure.error))
            }
        }
    }

    private func clearOutgoing() {
        outgoing = [:]
        outgoingEnvelopes = [:]
        conflictsToRead = []
    }

    /// Both zones, created once per account. Saving a zone that exists changes nothing.
    private func ensureZones() async throws {
        guard !mirror.zonesReady else { return }
        let made = [CKRecordZone(zoneID: zones.recordsZoneID), CKRecordZone(zoneID: zones.filesZoneID)]
        do {
            let results = try await database.modifyRecordZones(saving: made, deleting: []).saveResults
            for zone in made {
                if case .failure(let error) = results[zone.zoneID] { throw error }
            }
        } catch {
            throw mapped(error)
        }
        mirror.zonesReady = true
        saveMirror()
    }

    private func checkUsable() throws {
        if mirror.cloudDataDeleted { throw SyncTransportError.cloudDataDeleted }
    }

    private func mapped(_ error: any Error) -> SyncTransportError {
        let mapped = CloudKitSyncCoding.transportError(error, zonesReady: mirror.zonesReady)
        if mapped == .cloudDataDeleted, !mirror.cloudDataDeleted {
            mirror.cloudDataDeleted = true
            saveMirror()
        }
        if case .rejected(let code) = mapped { log.error("sync transport failed: \(code, privacy: .public)") }
        return mapped
    }

    /// The mirror on disk; without one the engine's saved state is dropped too (it would resume
    /// past records the lost mirror held), so the engine fetches everything again.
    private func loadMirror() {
        guard !mirrorLoaded else { return }
        mirrorLoaded = true
        mirror = files.load()
    }

    private func saveMirror() {
        if !files.save(mirror) { log.error("sync transport: mirror not saved; the engine's state waits for it") }
    }
}
