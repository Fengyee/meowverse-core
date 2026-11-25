import Foundation

/// One completed group from a picker. Only changed records and newly made links go to disk.
struct PickerImportDelta: Codable {
    struct Photo: Codable {
        let offset: Int
        let record: PhotoRecord
    }

    struct Links: Codable {
        let target: String
        var sources: [PhotoCarrierSource]
        var revision: Int
        var updatedAt: Date?
    }

    let baseRevision: Int
    var revision: Int
    var photos: [Photo] = []
    var links: Links?

    func replay(into state: inout AppState) throws {
        guard state.revision == baseRevision, revision == LibraryStore.nextRevision(baseRevision) else {
            throw StoreError.corruptState
        }
        for photo in photos {
            if photo.offset == state.photos.count {
                state.photos.append(photo.record)
            } else if state.photos.indices.contains(photo.offset), state.photos[photo.offset].photoId == photo.record.photoId {
                state.photos[photo.offset] = photo.record
            } else {
                throw StoreError.corruptState
            }
        }
        if let links {
            guard let (shelf, index) = LibraryStore.locate(links.target, in: state) else { throw StoreError.corruptState }
            state[keyPath: shelf][index].sources += links.sources
            state[keyPath: shelf][index].revision = links.revision
            state[keyPath: shelf][index].updatedAt = links.updatedAt
        }
        state.revision = revision
    }
}

struct PickerImportJournal {
    let root: URL
    static let directory = "import-checkpoints"
    static let retiredDirectory = "import-checkpoints.retired"
    private var folder: URL { root.appending(path: Self.directory) }
    var base: URL { folder.appending(path: "base.json") }
    private var retired: URL { root.appending(path: Self.retiredDirectory) }
    private let fm = FileManager.default

    /// Keep a separately readable baseline until both compacted snapshots have been synced.
    func prepare(baseline: URL?) throws {
        if !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: LibraryStore.protectionAttributes)
            LibraryStore.fsyncDirectory(root)
        }
        if let baseline {
            let temp = folder.appending(path: "base.tmp")
            if fm.fileExists(atPath: temp.path) { try fm.removeItem(at: temp) }
            try fm.copyItem(at: baseline, to: temp)
            try LibraryStore.fullFsync(temp)
            try LibraryStore.rename(temp, to: base)
            LibraryStore.fsyncDirectory(folder)
        } else if fm.fileExists(atPath: base.path) {
            try fm.removeItem(at: base)
        }
    }

    func commit(_ delta: PickerImportDelta, ordinal: Int, beforeCommit: () throws -> Void) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let temp = folder.appending(path: "next.tmp")
        if fm.fileExists(atPath: temp.path) { try fm.removeItem(at: temp) }
        try LibraryStore.writeDurably(try encoder.encode(delta), to: temp, fullSync: true)
        try beforeCommit()
        try LibraryStore.rename(temp, to: folder.appending(path: filename(ordinal)))
        LibraryStore.fsyncDirectory(folder)
    }

    /// This proof belongs to this journal and is retired with it. Keep prior proofs when a
    /// retry prepares a later snapshot: the earlier backup may still be installed at a crash.
    func recordCompaction(_ data: Data, checkpoint: Int) throws {
        let temp = folder.appending(path: "compaction.tmp")
        if fm.fileExists(atPath: temp.path) { try fm.removeItem(at: temp) }
        let proof = Self.compactionDigest(stateHash: PhotoIngest.sha256Hex(data), checkpoint: checkpoint)
        try LibraryStore.writeDurably(Data(proof.utf8), to: temp, fullSync: true)
        try LibraryStore.rename(temp, to: folder.appending(path: "compaction-\(checkpoint)"))
        LibraryStore.fsyncDirectory(folder)
    }

    private static func compactionDigest(stateHash: String, checkpoint: Int) -> String {
        PhotoIngest.sha256Hex(Data("\(checkpoint):\(stateHash)".utf8))
    }

    /// `baseRevision` is the revision of the independently decoded `base.json`, if any. A
    /// legacy group can have a single checkpoint; when it is unreadable the journal itself
    /// names no starting revision, but the verified baseline still does.
    ///
    /// `withoutTemp` also accepts a legacy backup whose temp is gone. Alone it is not
    /// corroborated; the caller uses it only when the checkpoints contradict it.
    func installedCompaction(extending known: AppState, baseRevision: Int?, entries: Entries,
                             withoutTemp: Bool = false) throws -> (state: AppState, checkpoint: Int)? {
        let backup = root.appending(path: LibraryStore.backupFile)
        if !entries.compactionProofs.isEmpty {
            var latest: (state: AppState, checkpoint: Int)?
            for file in [backup, root.appending(path: LibraryStore.stateFile)] {
                guard let snapshot = try readSnapshot(file),
                      let checkpoint = provenCheckpoint(for: snapshot.bytes, proofs: entries.compactionProofs),
                      checkpoint > (latest?.checkpoint ?? 0) else { continue }
                latest = (snapshot.state, checkpoint)
            }
            return latest
        }

        guard let (_, state) = try readSnapshot(backup) else { return nil }
        // Older writers synced the same bytes at both paths before renaming the primary.
        let legacyTemp = root.appending(path: LibraryStore.tempStateFile)
        guard var revision = baseRevision ?? entries.prefix.first?.baseRevision,
              LibraryStore.validRevision(revision), entries.fileCount > 0,
              fm.contentsEqual(atPath: backup.path, andPath: legacyTemp.path)
                || (withoutTemp && !fm.fileExists(atPath: legacyTemp.path)),
              Self.preservesPickerPrefix(known, in: state) else { return nil }
        for checkpoint in 1...entries.fileCount {
            revision = LibraryStore.nextRevision(revision)
            if revision == state.revision { return (state, checkpoint) }
        }
        return nil
    }

    private func readSnapshot(_ location: URL) throws -> (bytes: Data, state: AppState)? {
        guard let bytes = try? Data(contentsOf: location) else { return nil }
        switch LibraryStore.decodeState(bytes) {
        case .valid(let state): return (bytes, state)
        case .newer: throw StoreError.newerSchema
        case .invalid, .unreadable: return nil
        }
    }

    private func provenCheckpoint(for bytes: Data, proofs: [String]) -> Int? {
        let stateHash = PhotoIngest.sha256Hex(bytes)
        for file in proofs {
            guard let checkpoint = Int(file.dropFirst("compaction-".count)),
                  (1...LibraryStore.maxRevision).contains(checkpoint),
                  let digest = try? String(contentsOf: folder.appending(path: file), encoding: .utf8),
                  digest == Self.compactionDigest(stateHash: stateHash, checkpoint: checkpoint) else { continue }
            return checkpoint
        }
        return nil
    }

    /// A legacy temp can corroborate only a snapshot which preserves the verified photos,
    /// links, and user edits. The picker may learn identifiers or append photos and links.
    private static func preservesPickerPrefix(_ prefix: AppState, in candidate: AppState) -> Bool {
        guard candidate.photos.count >= prefix.photos.count else { return false }
        var prior = candidate
        prior.revision = prefix.revision
        prior.photos = Array(candidate.photos.prefix(prefix.photos.count))
        for (i, photo) in prefix.photos.enumerated() {
            prior.photos[i].assetIdentifier = photo.assetIdentifier
            prior.photos[i].cloudIdentifier = photo.cloudIdentifier
        }
        for shelf in [\AppState.items, \AppState.storage] {
            guard prior[keyPath: shelf].count == prefix[keyPath: shelf].count else { return false }
            for (i, piece) in prefix[keyPath: shelf].enumerated() {
                let sources = prior[keyPath: shelf][i].sources
                guard sources.starts(with: piece.sources) else { return false }
                if sources.count > piece.sources.count {
                    prior[keyPath: shelf][i].sources = piece.sources
                    prior[keyPath: shelf][i].revision = piece.revision
                    prior[keyPath: shelf][i].updatedAt = piece.updatedAt
                }
            }
        }
        return prior == prefix
    }

    struct Entries {
        var prefix: [PickerImportDelta] = []
        var damaged = false
        var fileCount = 0
        var compactionProofs: [String] = []
    }

    func read(after checkpoint: Int = 0) throws -> Entries {
        if !fm.fileExists(atPath: folder.path) { return Entries() }
        let files = try fm.contentsOfDirectory(atPath: folder.path)
        let names = files.filter { $0.hasSuffix(".json") && $0 != "base.json" }.sorted()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries = Entries(fileCount: names.count, compactionProofs: files.filter { $0.hasPrefix("compaction-") })
        let remaining = checkpoint == 0 ? names[...] : names.drop { $0 <= filename(checkpoint) }
        for (offset, name) in remaining.enumerated() {
            guard name == filename(checkpoint + offset + 1) else { entries.damaged = true; break }
            let data = try Data(contentsOf: folder.appending(path: name))
            guard let delta = try? decoder.decode(PickerImportDelta.self, from: data) else { entries.damaged = true; break }
            entries.prefix.append(delta)
        }
        return entries
    }

    /// Retire the complete sequence in one rename. A crash during recursive cleanup cannot
    /// leave a prefix missing from a sequence which the next launch still needs to replay.
    ///
    /// The rename is the commit point: once it succeeds the journal is retired and the caller
    /// must reset its count, so removing the retired copy afterwards cannot fail the call.
    /// A copy that could not be removed is retried by the next retire (audit T24-02).
    func retire() throws {
        let leftovers = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter(Self.isRetiredName)
        for name in leftovers { try? fm.removeItem(at: root.appending(path: name)) }
        guard fm.fileExists(atPath: folder.path) else { return }
        let target = fm.fileExists(atPath: retired.path)
            ? root.appending(path: Self.retiredDirectory + "-" + UUID().uuidString) : retired
        try LibraryStore.rename(folder, to: target)
        LibraryStore.fsyncDirectory(root)
        try? fm.removeItem(at: target)
    }

    static func isRetiredName(_ name: String) -> Bool {
        name == retiredDirectory
            || (name.hasPrefix(retiredDirectory + "-") && UUID(uuidString: String(name.dropFirst(retiredDirectory.count + 1))) != nil)
    }

    private func filename(_ ordinal: Int) -> String { String(format: "%08ld.json", ordinal) }
}

/// Matches PhotoRecord.isSamePhoto, including historical reduced/full records which can
/// collide on source identity. The first matching record still wins.
struct PickerPhotoLookup {
    var stored: [String: Int] = [:]
    var source: [String: Int] = [:]

    init(_ photos: [PhotoRecord]) {
        for (i, photo) in photos.enumerated() { add(photo, at: i) }
    }

    mutating func add(_ photo: PhotoRecord, at i: Int) {
        if stored[photo.sha256] == nil { stored[photo.sha256] = i }
        let original = photo.reducedFrom?.sha256 ?? photo.sha256
        if source[original] == nil { source[original] = i }
    }

    func match(_ draft: ImportDraft) -> Int? {
        [stored[draft.sha256], source[draft.reducedFrom?.sha256 ?? draft.sha256]].compactMap { $0 }.min()
    }
}
