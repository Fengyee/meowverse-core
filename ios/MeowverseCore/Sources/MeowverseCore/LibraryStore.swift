import CryptoKit
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// Fault boundaries for storage tests. A writeState fault follows the durable temporary
/// write and precedes the rename that commits the snapshot or picker checkpoint.
public enum StoreStep: Sendable, Equatable {
    case writeOriginal, writeThumbnail, writeState
    case pickerSnapshotBackupInstalled, pickerSnapshotInstalled
    /// A failure before switching to the staged library leaves the live library in place.
    case swapLibrary
    case deletionBackupCopy, deletionBackupSync, deletionBackupRename, deletionFileRemoval
    /// After a sync commits the library, before sync's own file is updated.
    case syncStateAfterApply
}

public extension StoreError {
    /// A write that found no space: `.io` keeps only the system's code (`ioError`).
    var isOutOfSpace: Bool {
        guard case .io(let code) = self else { return false }
        return code.hasSuffix(":\(NSCocoaErrorDomain):\(CocoaError.Code.fileWriteOutOfSpace.rawValue)")
            || code.hasSuffix(":\(NSPOSIXErrorDomain):\(ENOSPC)")
    }
}

public enum StoreError: Error, Equatable, Sendable {
    case corruptState
    /// The deletion is committed. The next load or write retries updating the local copies.
    case deletionCleanupPending
    case clearCleanupPending
    case unknownInstance
    case unknownPhoto
    case placement([PlacementIssue])
    case duplicateSource
    /// A capture day that is not a real `yyyy-MM-dd` calendar day.
    case invalidDate
    /// A note longer than `LibraryStore.maxNoteLength` UTF-16 code units.
    case noteTooLong
    /// A cat name that is empty or longer than `AppState.maxCatNameLength` characters.
    case invalidName
    /// The piece is locked: unlock it before moving, restyling, putting away or deleting it.
    case locked
    /// A new photo order that is not exactly the piece's photos, each once.
    case invalidOrder
    case unknownRoom
    case unknownCat
    /// The home already has `AppState.maxRooms` rooms / `AppState.maxCats` cats.
    case tooManyRooms
    case tooManyCats
    /// The first room and the first cat always exist: they cannot be removed.
    case firstRoom
    case firstCat
    /// Technical code only (error domain and number), never a path or filename.
    case io(String)
    /// The stored state uses a layout this build cannot preserve. Nothing
    /// was read into memory, no fallback was tried and no file was touched.
    case newerSchema
}

public struct IntegrityReport: Codable, Sendable, Equatable {
    /// photoIds whose original file is missing.
    public var missingOriginals: [String]
    /// photoIds whose thumbnail file is missing.
    public var missingThumbnails: [String]
    /// photoIds whose original file does not hash to the recorded sha256.
    public var hashMismatches: [String]
    /// `"<instanceId>/<photoId>"` for sources that reference a missing photo or a bad observation.
    public var danglingSources: [String]
    /// Root-relative paths in originals/ or thumbnails/ that no record references.
    public var orphanFiles: [String]

    public init(missingOriginals: [String] = [], missingThumbnails: [String] = [], hashMismatches: [String] = [],
                danglingSources: [String] = [], orphanFiles: [String] = []) {
        self.missingOriginals = missingOriginals
        self.missingThumbnails = missingThumbnails
        self.hashMismatches = hashMismatches
        self.danglingSources = danglingSources
        self.orphanFiles = orphanFiles
    }

    public var isClean: Bool {
        missingOriginals.isEmpty && missingThumbnails.isEmpty && hashMismatches.isEmpty
            && danglingSources.isEmpty && orphanFiles.isEmpty
    }
}

/// What to show for one stored photo. The files and the metadata describe the same image.
public struct PhotoDisplayFiles: Sendable, Equatable {
    public var original: URL
    public var thumbnail: URL
    /// The stored record was corrected and saved: publish the store's state again.
    public var metadataChanged = false
    /// The pixels come from the designated primary, but saving its corrected record failed.
    /// Show `unsavedRepair.applied(to:)` of the stored record until a later retry saves it.
    public var unsavedRepair: PhotoMetadataRepair?
}

/// The size and EXIF day of a full original's designated primary image. Applying it keeps a
/// user-chosen day and a web record's explicit unknown; any other day follows the file.
public struct PhotoMetadataRepair: Sendable, Equatable {
    public let photoId: String
    public let sha256: String
    public let width: Int
    public let height: Int
    public let exifCaptureDate: String?

    init(photoId: String, draft: ImportDraft) {
        self.photoId = photoId
        sha256 = draft.sha256
        width = draft.width
        height = draft.height
        exifCaptureDate = draft.captureDate
    }

    /// The record with the primary's size and EXIF day; unchanged if it holds other bytes.
    /// The revision stays: this is what the record says, not a new save.
    public func applied(to photo: PhotoRecord) -> PhotoRecord {
        guard photo.photoId == photoId, photo.sha256 == sha256, photo.reducedFrom == nil else { return photo }
        var repaired = photo
        repaired.width = width
        repaired.height = height
        repaired.exifCaptureDate = exifCaptureDate
        // A v6 web record can explicitly show unknown even when its file has a known EXIF day.
        // Native imports show the file's date unless the user supplied one. On another device the
        // web record's choice arrives through sync as unknown next to a known file day (the same
        // reading as `SyncDateChoice`): a native import never stores that pair.
        let explicitUnknown = photo.captureDateSource == .unknown
            && (photo.thumbnailFile == WebBackup.thumbnailPath(forHash: photo.sha256) || photo.exifCaptureDate != nil)
        if photo.captureDateSource != .user && !explicitUnknown {
            repaired.captureDate = exifCaptureDate
            repaired.captureDateSource = exifCaptureDate == nil ? .unknown : .exif
        }
        return repaired
    }
}

extension AppState {
    /// The library as it is shown while some repairs could not be saved yet: every list, month
    /// group, filter and spoken date reads the same records the detail shows. Not for saving or
    /// backing up — the store keeps what it could write. Without repairs it is `self`.
    public func applying(_ repairs: [String: PhotoMetadataRepair]) -> AppState {
        guard !repairs.isEmpty else { return self }
        var shown = self
        shown.photos = photos.map { photo in repairs[photo.photoId]?.applied(to: photo) ?? photo }
        return shown
    }
}

/// On-device photo library + room layout.
///
/// Layout under `root`: `state.json`, `state.backup.json`, `originals/<sha256>.<ext>`,
/// `thumbnails/<photoId>.jpg`. Ordinary writes replace a synced state file. Picker groups
/// commit a small delta in `import-checkpoints/` after the blobs are durable. Compaction
/// updates both complete snapshots before the deltas can be retired.
public actor LibraryStore {
    public static let stateFile = "state.json"
    public static let backupFile = "state.backup.json"
    public static let originalsDir = "originals"
    public static let thumbnailsDir = "thumbnails"
    static let tempStateFile = "state.json.tmp"
    static let deletionFile = "state.deletion.json"
    static let tempBackupFile = "state.backup.json.tmp"

    public static let onDeviceAnalyzerOrigin: SourceOrigin = .model
    /// Same limit as `PhotoDetail.note` in contracts/domain.ts (UTF-16 code units).
    public static let maxNoteLength = 2000

    private let root: URL
    private let catalog: FurnitureCatalog
    private let fault: (@Sendable (StoreStep) throws -> Void)?
    private let log = Logger(subsystem: "app.meowverse", category: "store")
    private let fm = FileManager.default

    /// nil until a `load()` succeeds. No write happens while nil.
    public private(set) var generation = UUID()
    private var state: AppState? {
        didSet { cachedIndex = nil; pickerLookup = nil }
    }
    private var cachedIndex: LibraryIndex?
    private var checkedHEIFOriginals = Set<String>()
    private var pickerLookup: PickerPhotoLookup?
    private var pickerCheckpointCount = 0
    private var pickerQuarantinePending = false
    /// The folder still carries `newLibraryMarker` (see `load`).
    private var newLibraryMarked = false
    private var pickerJournal: PickerImportJournal { PickerImportJournal(root: root) }

    private func checkGeneration(_ expected: UUID?) throws {
        if let expected, generation != expected { throw CancellationError() }
    }

    /// The library a caller's change is meant for (the app sets it around each change, and
    /// around an undo to the library the receipt came from). A change that starts after the
    /// library was replaced is refused (`CancellationError`) in the same step it would write in.
    @TaskLocal public static var expectedGeneration: UUID?
    /// Whether `state.json` on disk is the decoded, valid state (vs. loaded from the backup).
    private var primaryIsGood = false
    public private(set) var deletionPending = false
    private var retryDeletionIDs = Set<String>()
    /// True when the last `load()` found the primary unusable and returned the backup instead.
    public private(set) var recoveredFromBackup = false
    /// The staged library `replaceLibrary` is about to switch in; spared by stale-folder cleanup.
    private var keptStaging: URL?

    public init(root: URL, catalog: FurnitureCatalog, fault: (@Sendable (StoreStep) throws -> Void)? = nil) {
        self.root = root
        self.catalog = catalog
        self.fault = fault
    }

    // MARK: - Loading

    @discardableResult
    public func load() throws -> AppState {
        state = nil
        checkedHEIFOriginals.removeAll()
        pickerCheckpointCount = 0
        primaryIsGood = false
        recoveredFromBackup = false
        try recoverInterruptedSwap()
        newLibraryMarked = fm.fileExists(atPath: url(Self.newLibraryMarker).path)
        let primaryURL = url(Self.stateFile), backupURL = url(Self.backupFile)
        let primaryExists = fm.fileExists(atPath: primaryURL.path)
        let backupExists = fm.fileExists(atPath: backupURL.path)

        // Decode before touching anything: a newer schema must leave every file as it is.
        let primary: Decoded = primaryExists ? decode(primaryURL) : .invalid
        if case .newer(let version) = primary {
            log.fault("load: primary has unsupported layout, schema \(version, privacy: .public); refusing to read or write")
            throw StoreError.newerSchema
        }
        var backup: Decoded?
        if case .valid = primary {} else if backupExists {
            backup = decode(backupURL)
            if case .newer(let version) = backup {
                log.fault("load: backup has unsupported layout, schema \(version, privacy: .public); refusing to read or write")
                throw StoreError.newerSchema
            }
        }

        if fm.fileExists(atPath: url(Self.deletionFile).path) {
            if case .newer = decode(backupURL) { throw StoreError.newerSchema }
            switch decode(url(Self.deletionFile)) {
            case .newer: throw StoreError.newerSchema
            case .unreadable(let code): throw unreadable(code, op: "loadDeletion")
            case .invalid: throw StoreError.corruptState
            case .valid(let committed):
                state = committed
                deletionPending = true
                // A valid committed journal is readable even if cleanup still needs disk space.
                do { try finishDeletion(committed) } catch StoreError.deletionCleanupPending {}
                return committed
            }
        }
        deletionPending = false
        // A primary that exists but cannot be read now (I/O, protection) is unknown, not
        // corrupt: an older backup must not take its place and be saved over it (audit T24-01).
        if case .unreadable(let code) = primary { throw unreadable(code, op: "loadPrimary") }

        do {
            for dir in [root, url(Self.originalsDir), url(Self.thumbnailsDir)] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: Self.protectionAttributes)
            }
        } catch {
            throw ioError(error, op: "mkdir")
        }

        // A checkpoint that cannot be read now is unknown: open nothing, change nothing, and
        // read the whole sequence again next time (audit T24-03).
        let journal: PickerImportJournal.Entries
        do { journal = try pickerJournal.read() } catch { throw ioError(error, op: "journalRead") }
        let hasJournal = journal.fileCount > 0 || !journal.compactionProofs.isEmpty
        let baseline: AppState?
        let journalBase = hasJournal ? decode(pickerJournal.base) : .invalid
        if case .unreadable(let code) = journalBase { throw unreadable(code, op: "journalBase") }
        if case .valid(let base) = journalBase {
            baseline = base
        } else if hasJournal, !fm.fileExists(atPath: pickerJournal.base.path),
                  journal.prefix.first?.baseRevision == AppState.empty.revision {
            baseline = .empty
        } else {
            baseline = nil
        }
        var decoded: AppState
        if case .valid(let primaryState) = primary {
            decoded = primaryState
            primaryIsGood = true
        } else if let baseline {
            decoded = baseline
            recoveredFromBackup = true
        } else if case .valid(let backupState) = backup {
            decoded = backupState
            recoveredFromBackup = true
        } else if case .unreadable(let code) = backup {
            throw unreadable(code, op: "loadBackup")
        } else if !primaryExists && !backupExists {
            // No state at all is a new library only while the folder holds no photos. Media
            // without any record means the metadata was lost: keep every file for recovery
            // rather than let the orphan sweep below erase the only copies (audit T24-01).
            // With a journal, its damaged-tail path parks the whole folder instead.
            // Only a folder marked new, which has never committed anything, may hold the files
            // of a first save that stopped before its state: those are ordinary leftovers.
            if !hasJournal {
                var media: [String] = []
                for dir in [Self.originalsDir, Self.thumbnailsDir] {
                    do { media += try fm.contentsOfDirectory(atPath: url(dir).path) } catch {
                        throw ioError(error, op: "loadMedia")
                    }
                }
                if !media.isEmpty, !newLibraryMarked {
                    log.error("load: photos remain without a readable state; not starting an empty library")
                    throw StoreError.corruptState
                }
                if !newLibraryMarked { markNewLibrary() }
            }
            decoded = .empty
        } else {
            throw StoreError.corruptState
        }

        var damaged = false
        if hasJournal {
            do {
                (decoded, damaged) = try recoverPickerSnapshot(decoded, baseline: baseline, journal: journal)
            } catch { throw ioError(error, op: "journalRead") }
            pickerCheckpointCount = journal.fileCount
        }
        state = decoded
        pickerQuarantinePending = damaged
        if damaged {
            // An unreadable tail cannot invalidate an earlier, independently valid state.
            // If copying fails (e.g. disk full), keep it readable and retry before writing.
            do { try quarantinePickerTail(decoded) } catch { log.error("picker: preserving damaged import in place") }
            recoveredFromBackup = true
            rebaseSyncState(onto: decoded)
            return decoded
        }
        if recoveredFromBackup { rebaseSyncState(onto: decoded) }
        if primaryExists || backupExists { forgetNewLibraryMarker() }
        if journal.fileCount == 0 { try? pickerJournal.retire() } else { finishPickerImport() }
        if primaryIsGood || (!primaryExists && !backupExists) {
            removeStaleTempFiles()
            removeStaleStagingDirectories()
            cleanOrphans(in: decoded)
        }
        return decoded
    }

    /// Written when an empty folder becomes a library, removed at its first commit (a state
    /// file, a picker checkpoint). While it exists nothing was ever saved here (audit T24-01).
    static let newLibraryMarker = "library.new"

    private func markNewLibrary() {
        do {
            try writeDurably(Data(), to: url(Self.newLibraryMarker), fullSync: true)
            Self.fsyncDirectory(root)
            newLibraryMarked = true
        } catch {
            // Without it an interrupted first save asks for recovery instead of cleaning up.
            log.error("load: new-library marker not written: \(Self.code(error), privacy: .public)")
        }
    }

    /// After a commit: from now on, no state at all means lost metadata.
    private func forgetNewLibraryMarker() {
        guard newLibraryMarked else { return }
        do {
            try fm.removeItem(at: url(Self.newLibraryMarker))
            Self.fsyncDirectory(root)
            newLibraryMarked = false
        } catch {
            if Self.isMissingFile(error) { newLibraryMarked = false; return }
            log.error("new-library marker not removed yet: \(Self.code(error), privacy: .public)")
        }
    }

    private func unreadable(_ code: String, op: String) -> StoreError {
        log.error("load: state exists but cannot be read now (\(op, privacy: .public) \(code, privacy: .public))")
        return .io("\(op):\(code)")
    }

    private func recoverPickerSnapshot(_ snapshot: AppState, baseline: AppState?, journal: PickerImportJournal.Entries) throws
        -> (AppState, Bool) {
        let base = baseline ?? snapshot
        let replay = Self.replayVerified(journal.prefix[...], from: base, checking: snapshot)
        var damaged = journal.damaged || replay.count != journal.prefix.count || !replay.includesSnapshot
        let fallback = replay.includesSnapshot ? replay.state : snapshot
        // An installed snapshot is compared even when every delta decodes: a legacy writer left
        // no proof, and a checkpoint can be well-formed JSON with wrong contents. Its backup and
        // temp agreeing byte for byte outweighs one checkpoint file. It must preserve the
        // independently verified snapshot, not the replay that may be the damaged part.
        var installed = try pickerJournal.installedCompaction(extending: snapshot, baseRevision: baseline?.revision,
                                                              entries: journal)
        // A legacy backup whose temp is gone corroborates nothing by itself. But when the
        // checkpoints it covers all decode and say something else at its revision, the two are
        // contradicting evidence: take the complete snapshot and park the tree, rather than
        // silently trusting the delta. With an unreadable checkpoint there is no contradiction,
        // only a lone backup, and the verified baseline stays.
        if installed == nil, journal.compactionProofs.isEmpty,
           let lone = try pickerJournal.installedCompaction(extending: snapshot, baseRevision: baseline?.revision,
                                                            entries: journal, withoutTemp: true) {
            let covered = Self.replayVerified(journal.prefix.prefix(lone.checkpoint), from: base, checking: snapshot)
            if covered.count == lone.checkpoint, covered.includesSnapshot, covered.state != lone.state { installed = lone }
        }
        guard let installed else { return (fallback, damaged) }

        // Compare only the entries covered by the installed bytes. Even a well-formed delta
        // can have different contents at the same revision. Later entries descend from the
        // installed state and must be replayed from that state.
        let coveredEntries = journal.prefix.prefix(installed.checkpoint)
        let covered = coveredEntries.count == journal.prefix.count ? replay
            : Self.replayVerified(coveredEntries, from: base, checking: snapshot)
        damaged = damaged || covered.count != installed.checkpoint || covered.state != installed.state
        let suffix: ArraySlice<PickerImportDelta>
        if installed.checkpoint <= journal.prefix.count {
            suffix = journal.prefix.dropFirst(installed.checkpoint)
        } else {
            let later = try pickerJournal.read(after: installed.checkpoint)
            damaged = damaged || later.damaged
            suffix = later.prefix[...]
        }
        let result = Self.replayVerified(suffix, from: installed.state)
        return (result.state, damaged || result.count != suffix.count)
    }

    private static func replayVerified(_ deltas: ArraySlice<PickerImportDelta>, from base: AppState,
                                       checking snapshot: AppState? = nil) -> (state: AppState, count: Int, includesSnapshot: Bool) {
        var state = base, applied = 0
        var includesSnapshot = snapshot == base
        for delta in deltas {
            var candidate = state
            do { try delta.replay(into: &candidate) } catch { break }
            guard isConsistent(candidate) else { break }
            state = candidate
            if !includesSnapshot, state.revision == snapshot?.revision { includesSnapshot = state == snapshot }
            applied += 1
        }
        return (state, applied, includesSnapshot)
    }

    public func snapshot() -> AppState {
        state ?? .empty
    }

    /// State and its reverse links are published together. Building the index belongs to the
    /// store actor; UI consumers take a value snapshot without walking the photo library.
    public func indexedSnapshot() -> (state: AppState, index: LibraryIndex) {
        let current = snapshot()
        let index = cachedIndex ?? LibraryIndex(state: current)
        cachedIndex = index
        return (current, index)
    }

    // MARK: - Queries

    public func existingPhoto(matching draft: ImportDraft) -> PhotoRecord? {
        guard let state else { return nil }
        if pickerLookup == nil { pickerLookup = PickerPhotoLookup(state.photos) }
        return pickerLookup?.match(draft).map { state.photos[$0] }
    }

    public func furniture(containingPhoto photoId: String) -> [PhotoFurniture] {
        state?.furniture(containing: photoId) ?? []
    }

    public func originalURL(photoId: String) -> URL? {
        displayFiles(photoId: photoId)?.original
    }

    public func thumbnailURL(photoId: String) -> URL? {
        displayFiles(photoId: photoId)?.thumbnail
    }

    /// Old imports derived their thumbnail and EXIF from item zero. Inspect only a requested
    /// full HEIF, and decode it for repair only if ImageIO designates a different item.
    public func displayFiles(photoId: String) -> PhotoDisplayFiles? {
        guard let photo = state?.photo(id: photoId) else { return nil }
        let original = url(photo.originalFile), thumbnail = url(photo.thumbnailFile)
        var files = PhotoDisplayFiles(original: original, thumbnail: thumbnail)
        guard photo.reducedFrom == nil,
              ["image/heic", "image/heif", "image/heic-sequence", "image/heif-sequence", "image/avif"].contains(photo.mimeType),
              !checkedHEIFOriginals.contains(photo.sha256),
              let source = CGImageSourceCreateWithURL(original as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let index = PhotoIngest.primaryIndex(of: source) else { return files }
        if index != 0 {
            do {
                guard try original.resourceValues(forKeys: [.fileSizeKey]).fileSize == photo.byteSize,
                      photo.byteSize <= PhotoIngest.maxBytes else { return files }
                let bytes = try Data(contentsOf: original, options: .mappedIfSafe)
                let draft = try PhotoIngest.makeDraft(data: bytes, filename: nil, reduce: false)
                guard draft.sha256 == photo.sha256 else { return files }
                // If the cache cannot be written, the display decoder can still read this verified original.
                // From here on the pixels are the primary's, so the shown metadata must be too.
                let repair = PhotoMetadataRepair(photoId: photo.photoId, draft: draft)
                files.thumbnail = original
                files.unsavedRepair = repair
                files.metadataChanged = try repairHEIFRecord(photo, repair: repair, thumbnail: thumbnail,
                                                             thumbnailJPEG: draft.thumbnailJPEG)
                files.thumbnail = thumbnail
                files.unsavedRepair = nil
            } catch {
                log.error("display: failed to repair HEIF metadata or thumbnail, will retry")
                return files
            }
        }
        checkedHEIFOriginals.insert(photo.sha256)
        return files
    }

    private func repairHEIFRecord(_ photo: PhotoRecord, repair: PhotoMetadataRepair, thumbnail: URL,
                                  thumbnailJPEG: Data) throws -> Bool {
        var current = try loadedState()
        guard let index = current.photos.firstIndex(where: { $0.photoId == photo.photoId }) else { throw StoreError.unknownPhoto }
        if !blobMatches(thumbnail, sha256: PhotoIngest.sha256Hex(thumbnailJPEG), byteSize: thumbnailJPEG.count) {
            let temp = thumbnail.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".heif-tmp")
            defer { try? fm.removeItem(at: temp) }
            try writeDurably(thumbnailJPEG, to: temp)
            try Self.rename(temp, to: thumbnail)
            Self.fsyncDirectory(thumbnail.deletingLastPathComponent())
        }
        current.photos[index] = repair.applied(to: current.photos[index])
        guard current.photos[index] != photo else { return false }
        Self.advanceRevision(&current.photos[index].revision)
        try persist(current)
        return true
    }

    /// Re-hashes the stored original. False if the file is missing or differs.
    public func verifyOriginal(photoId: String) throws -> Bool {
        let current = try loadedState()
        guard let photo = current.photo(id: photoId) else { throw StoreError.unknownPhoto }
        guard let hash = Self.hashFile(url(photo.originalFile)) else { return false }
        return hash == photo.sha256
    }

    public func integrityReport() -> IntegrityReport {
        let current = state ?? .empty
        var report = IntegrityReport()
        for photo in current.photos {
            let original = url(photo.originalFile)
            if !fm.fileExists(atPath: original.path) {
                report.missingOriginals.append(photo.photoId)
            } else if Self.hashFile(original) != photo.sha256 {
                report.hashMismatches.append(photo.photoId)
            }
            if !fm.fileExists(atPath: url(photo.thumbnailFile).path) {
                report.missingThumbnails.append(photo.photoId)
            }
        }
        // Structural only: a catalog change (model removed/re-categorised) is not data damage.
        for item in current.items + current.storage {
            for source in item.sources where !Self.sourceIsStructurallyValid(source, in: current) {
                report.danglingSources.append("\(item.instanceId)/\(source.photoId)")
            }
        }
        report.orphanFiles = orphanPaths(in: current)
        return report
    }

    // MARK: - Mutations

    public func commitNewFurniture(draft: ImportDraft, placement: Placement, displayName: String,
                                   decision: SourceDecision, roomId: String = AppState.primaryRoomId,
                                   generation: UUID? = nil) throws -> PhotoFurniture {
        try checkGeneration(generation)
        let current = try loadedState()
        let issues = GridRules.validate(placement, in: try Self.pieces(inRoom: roomId, of: current), catalog: catalog)
        guard issues.isEmpty, let model = catalog.model(id: placement.modelId) else {
            log.notice("commit: placement rejected issues=\(issues.count, privacy: .public)")
            throw StoreError.placement(issues.isEmpty ? [.unknownModel] : issues)
        }
        try checkDraft(draft)

        var next = current
        var created: [URL] = []
        do {
            let photo = try ensurePhoto(draft: draft, in: &next, created: &created)
            let source = appendObservation(decision: decision, photoId: photo.photoId,
                                           category: model.category, in: &next)
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let item = PhotoFurniture(
                instanceId: UUID().uuidString, modelId: placement.modelId,
                x: placement.x, z: placement.z, width: placement.width, depth: placement.depth,
                turn: placement.turn, wall: placement.wall, finish: placement.finish,
                displayName: trimmed.isEmpty ? model.label : trimmed,
                sources: [source], tags: [], revision: 1, createdAt: Self.now(), roomId: Self.stored(roomId))
            next.items.append(item)
            try persist(next)
            log.info("commit: instance=\(item.instanceId, privacy: .public) photo=\(photo.photoId, privacy: .public) origin=\(source.origin.rawValue, privacy: .public) bytes=\(draft.byteSize, privacy: .public)")
            return item
        } catch {
            rollback(created)
            let surfaced = publicError(error, op: "commit")
            log.error("commit failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
    }

    public func addSource(draft: ImportDraft, toInstance instanceId: String,
                          decision: SourceDecision, generation: UUID? = nil) throws -> PhotoFurniture {
        try checkGeneration(generation)
        try Task.checkCancellation()
        let current = try loadedState()
        guard let (shelf, index) = Self.locate(instanceId, in: current) else {
            throw StoreError.unknownInstance
        }
        guard let model = catalog.model(id: current[keyPath: shelf][index].modelId) else {
            throw StoreError.placement([.unknownModel])
        }
        if let existing = current.photos.first(where: { $0.isSamePhoto(as: draft) }),
           current[keyPath: shelf][index].sources.contains(where: { $0.photoId == existing.photoId }) {
            // The link already exists, but reselecting a photo may repair its files or Photos binding.
            if (try? checkDraft(draft)) != nil { _ = try importPhoto(draft: draft) }
            throw StoreError.duplicateSource
        }
        try checkDraft(draft)

        var next = current
        var created: [URL] = []
        do {
            let photo = try ensurePhoto(draft: draft, in: &next, created: &created)
            let source = appendObservation(decision: decision, photoId: photo.photoId,
                                           category: model.category, in: &next)
            next[keyPath: shelf][index].sources.append(source)
            Self.advanceRevision(&next[keyPath: shelf][index].revision)
            next[keyPath: shelf][index].updatedAt = Self.now()
            let item = next[keyPath: shelf][index]
            try persist(next)
            log.info("addSource: instance=\(instanceId, privacy: .public) photo=\(photo.photoId, privacy: .public) sources=\(item.sources.count, privacy: .public)")
            return item
        } catch {
            rollback(created)
            let surfaced = publicError(error, op: "addSource")
            log.error("addSource failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
    }

    /// Moves/resizes/rotates/refinishes an instance in the room (a stored piece has no place to
    /// change: `restoreFurniture` gives it one). If the model changes to another category,
    /// model-origin sources whose observed object no longer matches become manual (user) links,
    /// mirroring the web rule that a model source must match the furniture's category.
    ///
    /// `roomId` moves the piece to another room as part of the same change; nil keeps its room.
    public func updatePlacement(instanceId: String, placement: Placement, roomId: String? = nil, displayName: String? = nil) throws -> PhotoFurniture {
        let current = try loadedState()
        guard let index = current.items.firstIndex(where: { $0.instanceId == instanceId }) else {
            throw StoreError.unknownInstance
        }
        guard !current.items[index].isLocked else { throw StoreError.locked }
        let room = roomId ?? AppState.roomId(of: current.items[index])
        let issues = GridRules.validate(placement, in: try Self.pieces(inRoom: room, of: current), catalog: catalog, ignoring: instanceId)
        guard issues.isEmpty, let model = catalog.model(id: placement.modelId) else {
            throw StoreError.placement(issues.isEmpty ? [.unknownModel] : issues)
        }
        var next = current
        var item = placed(current.items[index], at: placement, model: model, displayName: displayName, in: current)
        item.roomId = Self.stored(room)
        next.items[index] = item
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: "updatePlacement")
            log.error("updatePlacement failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("updatePlacement: instance=\(instanceId, privacy: .public) rev=\(item.revision, privacy: .public)")
        return item
    }

    /// Renames an instance. The name is trimmed; an empty (or unchanged) name keeps the
    /// existing one and writes nothing. Otherwise all-or-nothing like the other mutations and
    /// bumps the item's and the state's revision.
    public func rename(instanceId: String, displayName: String) throws -> PhotoFurniture {
        let current = try loadedState()
        guard let (shelf, index) = Self.locate(instanceId, in: current) else {
            throw StoreError.unknownInstance
        }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != current[keyPath: shelf][index].displayName else {
            return current[keyPath: shelf][index]
        }
        var next = current
        next[keyPath: shelf][index].displayName = trimmed
        Self.advanceRevision(&next[keyPath: shelf][index].revision)
        next[keyPath: shelf][index].updatedAt = Self.now()
        let item = next[keyPath: shelf][index]
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: "rename")
            log.error("rename failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("rename: instance=\(instanceId, privacy: .public) rev=\(item.revision, privacy: .public)")
        return item
    }

    /// Deletes an instance, whether it is in the room or put away. Its photos (records, files,
    /// observations) stay in the library, unlinked if no other furniture uses them; only
    /// `deletePhoto` deletes photos. To take a piece out of the room and keep it, use
    /// `stowFurniture`.
    public func removeFurniture(instanceId: String) throws {
        try removeFurniture(instanceIds: [instanceId])
    }

    /// Deletes several pieces as one write. An unknown or locked piece rejects the whole call
    /// and nothing changes. Photos stay in the library, as with one piece.
    public func removeFurniture(instanceIds: [String]) throws {
        let current = try loadedState()
        let ids = Set(instanceIds)
        let pieces = current.allFurniture.filter { ids.contains($0.instanceId) }
        guard pieces.count == ids.count else { throw StoreError.unknownInstance }
        guard !pieces.contains(where: \.isLocked) else { throw StoreError.locked }
        guard !ids.isEmpty else { return }
        var next = current
        next.items.removeAll { ids.contains($0.instanceId) }
        next.storage.removeAll { ids.contains($0.instanceId) }
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: "remove")
            log.error("remove failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("remove: count=\(ids.count, privacy: .public) photosKept=true")
    }

    /// Places a piece straight from the catalog. It has no source photos yet and no
    /// observation is written: nothing is claimed about any photo. Photos can be linked later.
    public func addFurniture(placement: Placement, displayName: String, roomId: String = AppState.primaryRoomId) throws -> PhotoFurniture {
        let current = try loadedState()
        let issues = GridRules.validate(placement, in: try Self.pieces(inRoom: roomId, of: current), catalog: catalog)
        guard issues.isEmpty, let model = catalog.model(id: placement.modelId) else {
            throw StoreError.placement(issues.isEmpty ? [.unknownModel] : issues)
        }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = PhotoFurniture(
            instanceId: UUID().uuidString, modelId: placement.modelId,
            x: placement.x, z: placement.z, width: placement.width, depth: placement.depth,
            turn: placement.turn, wall: placement.wall, finish: placement.finish,
            displayName: trimmed.isEmpty ? model.label : trimmed, sources: [], tags: [], revision: 1, createdAt: Self.now(),
            roomId: Self.stored(roomId))
        var next = current
        next.items.append(item)
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: "addFurniture")
            log.error("addFurniture failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("addFurniture: instance=\(item.instanceId, privacy: .public) wall=\(item.wall != nil, privacy: .public)")
        return item
    }

    /// Puts a piece away: it leaves the room and keeps everything else (photos, name, and its
    /// placement as a hint for later). Taking a piece out can never cut Bella off, so there is
    /// nothing to validate.
    public func stowFurniture(instanceId: String) throws -> PhotoFurniture {
        guard let item = try stowFurniture(instanceIds: [instanceId]).first else { throw StoreError.unknownInstance }
        return item
    }

    /// Puts several pieces away as one write, in the order they stand in the room. A piece that
    /// is not in the room, or a locked one, rejects the whole call and nothing changes.
    @discardableResult
    public func stowFurniture(instanceIds: [String]) throws -> [PhotoFurniture] {
        let current = try loadedState()
        let ids = Set(instanceIds)
        let pieces = current.items.filter { ids.contains($0.instanceId) }
        guard pieces.count == ids.count else { throw StoreError.unknownInstance }
        guard !pieces.contains(where: \.isLocked) else { throw StoreError.locked }
        guard !ids.isEmpty else { return [] }
        var next = current
        let now = Self.now()
        next.items.removeAll { ids.contains($0.instanceId) }
        let stowed = pieces.map { piece in
            var item = piece
            Self.advanceRevision(&item.revision)
            item.updatedAt = now
            return item
        }
        next.storage += stowed
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: "stow")
            log.error("stow failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("stow: count=\(stowed.count, privacy: .public) stored=\(next.storage.count, privacy: .public)")
        return stowed
    }

    /// Locks or unlocks pieces as one write. Returns how many changed. An unknown piece rejects
    /// the whole call.
    @discardableResult
    public func setLocked(instanceIds: [String], _ locked: Bool) throws -> Int {
        let current = try loadedState()
        var next = current
        var changed = 0
        let now = Self.now()
        for id in Set(instanceIds) {
            guard let (shelf, index) = Self.locate(id, in: next) else { throw StoreError.unknownInstance }
            guard next[keyPath: shelf][index].isLocked != locked else { continue }
            next[keyPath: shelf][index].locked = locked ? true : nil
            Self.advanceRevision(&next[keyPath: shelf][index].revision)
            next[keyPath: shelf][index].updatedAt = now
            changed += 1
        }
        guard changed > 0 else { return 0 }
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: "setLocked")
            log.error("setLocked failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("setLocked: locked=\(locked, privacy: .public) changed=\(changed, privacy: .public)")
        return changed
    }

    /// Chooses the photo that stands for a piece in lists; nil goes back to the first photo.
    /// The photo must be on the piece.
    @discardableResult
    public func setCover(instanceId: String, photoId: String?) throws -> PhotoFurniture {
        try editAlbum(instanceId: instanceId, op: "setCover") { item in
            if let photoId, !item.sources.contains(where: { $0.photoId == photoId }) { throw StoreError.unknownPhoto }
            // The first photo is the cover anyway: keep the file free of a redundant choice.
            item.coverPhotoId = photoId == item.sources.first?.photoId ? nil : photoId
        }
    }

    /// Puts a piece's photos in a new order. `order` must name exactly the piece's photos, each
    /// once. A cover that was never chosen stays "the first photo", so it follows the new order.
    @discardableResult
    public func reorderPhotos(instanceId: String, order: [String]) throws -> PhotoFurniture {
        try editAlbum(instanceId: instanceId, op: "reorderPhotos") { item in
            let byPhoto = Dictionary(item.sources.map { ($0.photoId, $0) }, uniquingKeysWith: { first, _ in first })
            guard order.count == item.sources.count, Set(order).count == order.count,
                  order.allSatisfy({ byPhoto[$0] != nil }) else { throw StoreError.invalidOrder }
            item.sources = order.compactMap { byPhoto[$0] }
        }
    }

    /// One change to a piece's album. Writes nothing when the change leaves the piece as it was.
    private func editAlbum(instanceId: String, op: String, _ change: (inout PhotoFurniture) throws -> Void) throws -> PhotoFurniture {
        let current = try loadedState()
        guard let (shelf, index) = Self.locate(instanceId, in: current) else { throw StoreError.unknownInstance }
        var item = current[keyPath: shelf][index]
        try change(&item)
        guard item != current[keyPath: shelf][index] else { return item }
        Self.advanceRevision(&item.revision)
        item.updatedAt = Self.now()
        var next = current
        next[keyPath: shelf][index] = item
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: op)
            log.error("\(op, privacy: .public) failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("\(op, privacy: .public): instance=\(instanceId, privacy: .public) rev=\(item.revision, privacy: .public)")
        return item
    }

    /// Brings a stored piece back into the room at `placement`, which is judged like a new
    /// placement (the room may have changed while the piece was away; the item limit applies).
    /// A different model follows the same source rule as `updatePlacement`.
    public func restoreFurniture(instanceId: String, placement: Placement, roomId: String = AppState.primaryRoomId,
                                 displayName: String? = nil) throws -> PhotoFurniture {
        let current = try loadedState()
        guard let index = current.storage.firstIndex(where: { $0.instanceId == instanceId }) else {
            throw StoreError.unknownInstance
        }
        guard !current.storage[index].isLocked else { throw StoreError.locked }
        let issues = GridRules.validate(placement, in: try Self.pieces(inRoom: roomId, of: current), catalog: catalog)
        guard issues.isEmpty, let model = catalog.model(id: placement.modelId) else {
            throw StoreError.placement(issues.isEmpty ? [.unknownModel] : issues)
        }
        var next = current
        var item = placed(next.storage.remove(at: index), at: placement, model: model, displayName: displayName, in: current)
        item.roomId = Self.stored(roomId)
        next.items.append(item)
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: "restore")
            log.error("restore failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("restore: instance=\(instanceId, privacy: .public) rev=\(item.revision, privacy: .public)")
        return item
    }

    /// `item` with the placement applied and its revision bumped. Model-origin sources whose
    /// observed object does not match the (possibly new) model's category become manual links.
    private func placed(_ item: PhotoFurniture, at placement: Placement, model: CatalogModel, displayName: String?,
                        in current: AppState) -> PhotoFurniture {
        var item = item
        if let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            item.displayName = trimmed
        }
        item.modelId = placement.modelId
        item.x = placement.x
        item.z = placement.z
        item.width = placement.width
        item.depth = placement.depth
        item.turn = placement.turn
        item.wall = placement.wall
        item.finish = placement.finish
        item.sources = item.sources.map { source in
            guard source.observationId != nil else { return source }
            var probe = item
            probe.modelId = model.id
            return Self.sourceIsValid(source, item: probe, in: current, catalog: catalog)
                ? source : .manual(photoId: source.photoId, addedAt: source.addedAt)
        }
        Self.advanceRevision(&item.revision)
        item.updatedAt = Self.now()
        return item
    }

    // MARK: - Photos

    /// Stores a photo without any furniture. Identical bytes are stored once: a second import
    /// reuses the existing record, repairing its files and filling in a missing picker identifier.
    public func addPhoto(draft: ImportDraft, generation: UUID? = nil) throws -> PhotoRecord {
        try checkGeneration(generation)
        return try importPhoto(draft: draft).photo
    }

    /// Whether these bytes created a new record is decided in the same actor turn as the write.
    public func importPhoto(draft: ImportDraft) throws -> (photo: PhotoRecord, inserted: Bool) {
        try importPhotos([draft])[0]
    }

    /// A picker checkpoint commits its records together. Already committed checkpoints survive a
    /// later cancellation or failure; no result is returned before the state file is durable.
    public func importPhotos(_ drafts: [ImportDraft], generation: UUID? = nil) throws -> [(photo: PhotoRecord, inserted: Bool)] {
        try checkGeneration(generation)
        let current = try loadedState()
        var next = current
        var created: [URL] = []
        var changed = false
        var results: [(photo: PhotoRecord, inserted: Bool)] = []
        do {
            for draft in drafts {
                try Task.checkCancellation()
                try checkDraft(draft)
                if let index = next.photos.firstIndex(where: { $0.isSamePhoto(as: draft) }) {
                    let existing = next.photos[index]
                    do { try healBlobs(of: existing, from: draft) } catch {
                        log.error("addPhoto: heal failed \(Self.code(self.publicError(error, op: "heal")), privacy: .public)")
                    }
                    next.photos[index].learnLibraryIdentifiers(from: draft)
                    let photo = next.photos[index]
                    changed = changed || photo != existing
                    results.append((photo, false))
                } else {
                    let photo = try writeNewPhoto(draft: draft, in: &next, created: &created)
                    changed = true
                    results.append((photo, true))
                }
            }
            try Task.checkCancellation()
            if changed { try persist(next) }
            return results
        } catch {
            rollback(created)
            if error is CancellationError { throw error }
            throw publicError(error, op: "addPhoto")
        }
    }

    /// Commit one picker group without serializing all the unrelated records. Both picker
    /// entry points keep at most three decoded drafts; earlier groups survive a later failure.
    public func importPickerPhotos(_ drafts: [ImportDraft], to target: String? = nil, generation: UUID? = nil) throws
        -> [(photo: PhotoRecord, inserted: Bool, linked: Bool)] {
        try checkGeneration(generation)
        let current = try loadedState()
        var next = current
        let location = target.flatMap { Self.locate($0, in: current) }
        if target != nil {
            guard let location else { throw StoreError.unknownInstance }
            guard catalog.model(id: current[keyPath: location.shelf][location.index].modelId) != nil else {
                throw StoreError.placement([.unknownModel])
            }
        }
        var held = Set(location.map { current[keyPath: $0.shelf][$0.index].sources.map(\.photoId) } ?? [])
        var delta = PickerImportDelta(baseRevision: current.revision, revision: Self.nextRevision(current.revision))
        var created: [URL] = [], results: [(PhotoRecord, Bool, Bool)] = []
        if pickerLookup == nil { pickerLookup = PickerPhotoLookup(current.photos) }
        do {
            for draft in drafts {
                try Task.checkCancellation()
                try checkDraft(draft)
                let photo: PhotoRecord
                let offset = pickerLookup?.match(draft)
                if let offset {
                    let old = next.photos[offset]
                    if location != nil {
                        _ = try healBlobs(of: old, from: draft)
                    } else if (try? healBlobs(of: old, from: draft)) == nil {
                        log.error("picker: could not repair an existing photo")
                    }
                    next.photos[offset].learnLibraryIdentifiers(from: draft)
                    photo = next.photos[offset]
                    if photo != old { delta.photos.append(.init(offset: offset, record: photo)) }
                } else {
                    photo = try writeNewPhoto(draft: draft, in: &next, created: &created)
                    let i = next.photos.count - 1
                    pickerLookup?.add(photo, at: i)
                    delta.photos.append(.init(offset: i, record: photo))
                }

                let link = location != nil && held.insert(photo.photoId).inserted
                if let location, link {
                    let source = PhotoCarrierSource.manual(photoId: photo.photoId, addedAt: Self.now())
                    next[keyPath: location.shelf][location.index].sources.append(source)
                    Self.advanceRevision(&next[keyPath: location.shelf][location.index].revision)
                    next[keyPath: location.shelf][location.index].updatedAt = Self.now()
                    let item = next[keyPath: location.shelf][location.index]
                    if delta.links == nil {
                        delta.links = .init(target: item.instanceId, sources: [], revision: item.revision, updatedAt: item.updatedAt)
                    }
                    delta.links?.sources.append(source)
                    delta.links?.revision = item.revision
                    delta.links?.updatedAt = item.updatedAt
                }
                results.append((photo, offset == nil, link))
            }
            try Task.checkCancellation()
            if !delta.photos.isEmpty || delta.links != nil {
                if pickerCheckpointCount == 0 {
                    let base = primaryIsGood ? url(Self.stateFile) : (recoveredFromBackup ? url(Self.backupFile) : nil)
                    try pickerJournal.prepare(baseline: base)
                }
                try pickerJournal.commit(delta, ordinal: pickerCheckpointCount + 1) {
                    try fire(.writeState)
                    try Task.checkCancellation()
                }
                pickerCheckpointCount += 1
                forgetNewLibraryMarker()
                next.revision = delta.revision
                var index = cachedIndex
                let lookup = pickerLookup
                state = next
                index?.applyPickerPhotos(delta.photos.map(\.record), to: location.map { next[keyPath: $0.shelf][$0.index] },
                                       links: delta.links?.sources ?? [])
                cachedIndex = index
                pickerLookup = lookup
            }
            return results
        } catch {
            pickerLookup = nil
            if pickerCheckpointCount == 0 { try? pickerJournal.retire() }
            rollback(created)
            if error is CancellationError { throw error }
            throw publicError(error, op: "picker")
        }
    }

    /// Compaction is housekeeping. A synced checkpoint remains authoritative even when the
    /// snapshots cannot be refreshed (e.g. disk full); a later load or normal write retries.
    public func finishPickerImport() {
        do { try compactPickerImports() } catch { log.error("picker: snapshot compaction deferred") }
    }

    private func quarantinePickerTail(_ recovered: AppState) throws {
        let staging = makeStagingURL()
        defer { try? fm.removeItem(at: staging) }
        for dir in [Self.originalsDir, Self.thumbnailsDir] {
            try fm.createDirectory(at: staging.appending(path: dir), withIntermediateDirectories: true,
                                   attributes: Self.protectionAttributes)
        }
        for photo in recovered.photos {
            for path in [photo.originalFile, photo.thumbnailFile] where fm.fileExists(atPath: url(path).path) {
                let copy = staging.appending(path: path)
                try fm.copyItem(at: url(path), to: copy)
                try Self.fsync(copy)
            }
        }
        for dir in [Self.originalsDir, Self.thumbnailsDir] { Self.fsyncDirectory(staging.appending(path: dir)) }
        let data = try Self.encodeState(recovered)
        for name in [Self.stateFile, Self.backupFile] {
            try writeDurably(data, to: staging.appending(path: name), fullSync: true)
        }
        // Sync's own files go along: without them the next sync would start over and lose what
        // it had captured but not sent. `load` rebases them onto the recovered library.
        for name in [Self.syncStateFile, Self.syncStateBackupFile] where fm.fileExists(atPath: url(name).path) {
            let copy = staging.appending(path: name)
            try fm.copyItem(at: url(name), to: copy)
            try Self.fullFsync(copy)
        }
        // A held camera capture, and any set aside, is in no record and maybe nowhere else: it
        // stays with this same library, still out of device backups (audit W24-02).
        let held = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0 == PendingCapture.fileName || $0.hasPrefix(PendingCapture.keptPrefix) }
        for name in held {
            let copy = staging.appending(path: name)
            try fm.copyItem(at: url(name), to: copy)
            try Self.fullFsync(copy)
            try Self.excludeFromBackup(copy)
        }
        // Existing disaster recovery parks the entire old tree and counts it until Clear All.
        let currentGeneration = generation
        try swapIn(staging: staging, state: recovered, preserveDamaged: true)
        generation = currentGeneration
    }

    private func compactPickerImports() throws {
        if pickerQuarantinePending, let state { try quarantinePickerTail(state); return }
        guard pickerCheckpointCount > 0, let state else { return }
        let temp = url(Self.tempStateFile), backupTemp = url(Self.tempBackupFile)
        for file in [temp, backupTemp] where fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        let data = try Self.encodeState(state)
        try writeDurably(data, to: temp, fullSync: true)
        try fm.copyItem(at: temp, to: backupTemp)
        try Self.fullFsync(backupTemp)
        try pickerJournal.recordCompaction(data, checkpoint: pickerCheckpointCount)
        try Self.rename(backupTemp, to: url(Self.backupFile))
        try fire(.pickerSnapshotBackupInstalled)
        try Self.rename(temp, to: url(Self.stateFile))
        try fire(.pickerSnapshotInstalled)
        Self.fsyncDirectory(root)
        try pickerJournal.retire()
        pickerCheckpointCount = 0
        primaryIsGood = true
    }

    /// A skipped batch entry may undo only its own import. An edit, observation or a furniture
    /// link made since then takes precedence. Retrying after a completed discard is harmless.
    public func discardBatchPhoto(photoId: String, ifUnchangedSince revision: Int, generation: UUID? = nil) throws {
        try checkGeneration(generation)
        let current = try loadedState()
        guard current.photo(id: photoId)?.revision == revision,
              current.furniture(containing: photoId).isEmpty,
              !current.observations.contains(where: { $0.photoId == photoId }) else { return }
        try deletePhoto(photoId: photoId)
    }

    /// Links an already stored photo to an instance (in the room or put away) as a manual
    /// (user) source.
    public func linkPhoto(photoId: String, toInstance instanceId: String) throws -> PhotoFurniture {
        let current = try loadedState()
        guard let (shelf, index) = Self.locate(instanceId, in: current) else {
            throw StoreError.unknownInstance
        }
        guard current.photo(id: photoId) != nil else { throw StoreError.unknownPhoto }
        guard !current[keyPath: shelf][index].sources.contains(where: { $0.photoId == photoId }) else {
            throw StoreError.duplicateSource
        }
        var next = current
        next[keyPath: shelf][index].sources.append(.manual(photoId: photoId, addedAt: Self.now()))
        Self.advanceRevision(&next[keyPath: shelf][index].revision)
        next[keyPath: shelf][index].updatedAt = Self.now()
        let item = next[keyPath: shelf][index]
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: "linkPhoto")
            log.error("linkPhoto failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("linkPhoto: instance=\(instanceId, privacy: .public) photo=\(photoId, privacy: .public) sources=\(item.sources.count, privacy: .public)")
        return item
    }

    /// Takes one photo off an instance (in the room or put away). Only the link goes: the photo
    /// and its observations stay in the library, and the piece stays even with no photos left.
    /// `unknownPhoto` when the piece does not hold that photo.
    public func unlinkPhoto(photoId: String, fromInstance instanceId: String) throws -> PhotoFurniture {
        let current = try loadedState()
        guard let (shelf, index) = Self.locate(instanceId, in: current) else {
            throw StoreError.unknownInstance
        }
        guard current[keyPath: shelf][index].sources.contains(where: { $0.photoId == photoId }) else {
            throw StoreError.unknownPhoto
        }
        var next = current
        next[keyPath: shelf][index].sources.removeAll { $0.photoId == photoId }
        Self.advanceRevision(&next[keyPath: shelf][index].revision)
        next[keyPath: shelf][index].updatedAt = Self.now()
        let item = next[keyPath: shelf][index]
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: "unlinkPhoto")
            log.error("unlinkPhoto failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("unlinkPhoto: instance=\(instanceId, privacy: .public) photo=\(photoId, privacy: .public) sources=\(item.sources.count, privacy: .public)")
        return item
    }

    /// Applies the user's metadata edit as one all-or-nothing write. A part that fails
    /// validation rejects the whole edit; an edit that changes nothing writes nothing.
    /// The original file, `importedAt` and `exifCaptureDate` are never touched.
    public func editPhoto(photoId: String, _ edit: PhotoEdit) throws -> PhotoRecord {
        let current = try loadedState()
        guard let index = current.photos.firstIndex(where: { $0.photoId == photoId }) else {
            throw StoreError.unknownPhoto
        }
        var photo = current.photos[index]
        if let favorite = edit.favorite { photo.favorite = favorite }
        if let note = edit.note {
            guard note.utf16.count <= Self.maxNoteLength else { throw StoreError.noteTooLong }
            photo.note = note
        }
        switch edit.captureDate {
        case .set(let day):
            guard PhotoLibrary.isValidDay(day) else { throw StoreError.invalidDate }
            photo.captureDate = day
            photo.captureDateSource = .user
        case .clear:
            photo.captureDate = photo.exifCaptureDate
            photo.captureDateSource = photo.exifCaptureDate == nil ? .unknown : .exif
        case nil:
            break
        }
        guard photo != current.photos[index] else { return photo }
        Self.advanceRevision(&photo.revision)
        var next = current
        next.photos[index] = photo
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: "editPhoto")
            log.error("editPhoto failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("editPhoto: photo=\(photoId, privacy: .public) rev=\(photo.revision, privacy: .public) dateSource=\(photo.captureDateSource.rawValue, privacy: .public)")
        return photo
    }

    /// Deletes one photo: its record, observations and both files. Every piece that showed it,
    /// in the room or put away, loses that one link and nothing else: a piece is never deleted
    /// with a photo, even its last one (see `AppState.deletionImpact`). Files are deleted
    /// after the new state is durable and the backup no longer references them.
    public func deletePhoto(photoId: String) throws {
        try deletePhotos(photoIds: [photoId])
    }

    /// Deletes several photos as one write, by the rules of `deletePhoto`. An id that is not in
    /// the library rejects the whole call (`unknownPhoto`) and nothing changes.
    public func deletePhotos(photoIds: [String]) throws {
        let ids = Set(photoIds)
        let resuming = deletionPending && retryDeletionIDs == ids
        let current = try loadedState()
        try compactPickerImports()
        let doomed = current.photos.filter { ids.contains($0.photoId) }
        if resuming && doomed.isEmpty { return }
        guard doomed.count == ids.count else { throw StoreError.unknownPhoto }
        guard !doomed.isEmpty else { return }
        var next = current
        next.photos.removeAll { ids.contains($0.photoId) }
        next.observations.removeAll { ids.contains($0.photoId) }
        var updatedItems = 0
        for shelf in [\AppState.items, \AppState.storage] {
            for index in next[keyPath: shelf].indices
            where next[keyPath: shelf][index].sources.contains(where: { ids.contains($0.photoId) }) {
                next[keyPath: shelf][index].sources.removeAll { ids.contains($0.photoId) }
                Self.advanceRevision(&next[keyPath: shelf][index].revision)
                next[keyPath: shelf][index].updatedAt = Self.now()
                updatedItems += 1
            }
        }
        // This journal is the commit point. Until the two state files and the photo
        // directory agree, every reader on restart uses it ahead of either state file.
        Self.advanceRevision(&next.revision)
        let temp = url(Self.tempStateFile)
        do {
            try? fm.removeItem(at: temp)
            try writeDurably(try Self.encodeState(next), to: temp, fullSync: true)
            try fire(.writeState)
            try Self.rename(temp, to: url(Self.deletionFile))
            Self.fsyncDirectory(root)
        } catch {
            try? fm.removeItem(at: temp)
            throw publicError(error, op: "deletePhoto")
        }
        state = next
        deletionPending = true
        retryDeletionIDs = ids
        try finishDeletion(next)
        log.info("deletePhoto: photos=\(doomed.count, privacy: .public) furnitureUpdated=\(updatedItems, privacy: .public)")
    }

    // MARK: - Several photos at once

    /// What a batch change did. `changed` photos were linked, unlinked or moved; `unchanged`
    /// were already as asked (already on the piece, or not on it).
    public struct BatchOutcome: Sendable, Equatable {
        public let changed: Int
        public let unchanged: Int
    }

    /// Puts stored photos on a piece (in the room or put away) as manual links, as one write.
    /// A photo already on the piece is left as it is. An unknown photo or piece rejects the
    /// whole call and nothing changes.
    @discardableResult
    public func linkPhotos(photoIds: [String], toInstance instanceId: String) throws -> BatchOutcome {
        try changeLinks(photoIds: photoIds, from: nil, to: instanceId, op: "linkPhotos")
    }

    /// Takes photos off a piece as one write. Only the links go. A photo that is not on the
    /// piece is skipped.
    @discardableResult
    public func unlinkPhotos(photoIds: [String], fromInstance instanceId: String) throws -> BatchOutcome {
        try changeLinks(photoIds: photoIds, from: instanceId, to: nil, op: "unlinkPhotos")
    }

    /// What `unlinkPhotos(photoIds:fromInstances:)` took off, enough to put it back exactly.
    public struct UnlinkReceipt: Sendable, Equatable {
        public struct Removed: Sendable, Equatable {
            public let instanceId: String
            /// Where the link was in the piece's album.
            public let position: Int
            /// The link as it was: origin, observation, relation and when it was made.
            public let link: PhotoCarrierSource
        }

        public let removed: [Removed]
        /// The library the links were taken off in.
        public let generation: UUID
    }

    /// Takes photos off several pieces as one write: off the pieces in `instanceIds`, or, with
    /// nil, off every piece each photo is on. Only the links go: the photos, their observations
    /// and the pieces stay. A photo not on a named piece is skipped. An unknown photo or piece
    /// rejects the whole call and nothing changes.
    @discardableResult
    public func unlinkPhotos(photoIds: [String], fromInstances instanceIds: [String]?) throws -> UnlinkReceipt {
        let current = try loadedState()
        let ids = Set(photoIds)
        guard ids.isSubset(of: Set(current.photos.map(\.photoId))) else { throw StoreError.unknownPhoto }
        let pieces = try instanceIds.map { named in
            try named.map { id in
                guard Self.locate(id, in: current) != nil else { throw StoreError.unknownInstance }
                return id
            }
        }
        var next = current
        let now = Self.now()
        var removed: [UnlinkReceipt.Removed] = []
        for piece in current.allFurniture where pieces?.contains(piece.instanceId) ?? true {
            let leaving = piece.sources.enumerated().filter { ids.contains($0.element.photoId) }
            guard !leaving.isEmpty, let (shelf, index) = Self.locate(piece.instanceId, in: next) else { continue }
            removed += leaving.map { .init(instanceId: piece.instanceId, position: $0.offset, link: $0.element) }
            next[keyPath: shelf][index].sources.removeAll { ids.contains($0.photoId) }
            Self.advanceRevision(&next[keyPath: shelf][index].revision)
            next[keyPath: shelf][index].updatedAt = now
        }
        let receipt = UnlinkReceipt(removed: removed, generation: generation)
        guard !removed.isEmpty else { return receipt }
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: "unlinkPhotosFromPieces")
            log.error("unlinkPhotosFromPieces failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("unlinkPhotosFromPieces: links=\(removed.count, privacy: .public)")
        return receipt
    }

    /// Puts back what `unlinkPhotos(photoIds:fromInstances:)` took off, as one write. Each link
    /// goes back where it was, as it was, so a recognised link never comes back as one made by
    /// hand. What changed meanwhile wins: a link is skipped when its piece or photo is gone or
    /// the photo is on that piece again. Returns how many links went back.
    @discardableResult
    public func undoUnlink(_ receipt: UnlinkReceipt) throws -> Int {
        let current = try loadedState()
        let photos = Set(current.photos.map(\.photoId))
        let observations = Set(current.observations.map(\.observationId))
        var next = current
        let now = Self.now()
        var restored = 0
        // In album order per piece, so each earlier position is already back when the next goes in.
        for entry in receipt.removed.sorted(by: { ($0.instanceId, $0.position) < ($1.instanceId, $1.position) }) {
            // A recognised link goes back only with its observation (another device may have
            // taken the suggestion back meanwhile): half a link would be a made-up provenance.
            guard photos.contains(entry.link.photoId), entry.link.observationId.map(observations.contains) ?? true,
                  let (shelf, index) = Self.locate(entry.instanceId, in: next),
                  !next[keyPath: shelf][index].sources.contains(where: { $0.photoId == entry.link.photoId }) else { continue }
            let count = next[keyPath: shelf][index].sources.count
            next[keyPath: shelf][index].sources.insert(entry.link, at: min(entry.position, count))
            Self.advanceRevision(&next[keyPath: shelf][index].revision)
            next[keyPath: shelf][index].updatedAt = now
            restored += 1
        }
        guard restored > 0 else { return 0 }
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: "undoUnlink")
            log.error("undoUnlink failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("undoUnlink: restored=\(restored, privacy: .public)")
        return restored
    }

    /// Moves photos from one piece to another as one write: off `source`, onto `target`. A
    /// photo already on `target` just leaves `source`. A photo not on `source` is skipped.
    @discardableResult
    public func movePhotos(photoIds: [String], fromInstance source: String, toInstance target: String) throws -> BatchOutcome {
        guard source != target else { throw StoreError.duplicateSource }
        return try changeLinks(photoIds: photoIds, from: source, to: target, op: "movePhotos")
    }

    private func changeLinks(photoIds: [String], from source: String?, to target: String?, op: String) throws -> BatchOutcome {
        var added: [PhotoCarrierSource] = []
        return try changeLinks(photoIds: photoIds, from: source, to: target, op: op, added: &added)
    }

    /// `added` gets the links put on `target`, as written, once the write succeeded.
    private func changeLinks(photoIds: [String], from source: String?, to target: String?, op: String,
                             added: inout [PhotoCarrierSource]) throws -> BatchOutcome {
        let current = try loadedState()
        var seen = Set<String>()
        let ids = photoIds.filter { seen.insert($0).inserted }
        let known = Set(current.photos.map(\.photoId))
        guard ids.allSatisfy(known.contains) else { throw StoreError.unknownPhoto }
        var next = current
        let now = Self.now()
        var eligible = ids
        var changed = 0
        var arrivingLinks: [PhotoCarrierSource] = []
        if let source {
            guard let (shelf, index) = Self.locate(source, in: next) else { throw StoreError.unknownInstance }
            let held = Set(next[keyPath: shelf][index].sources.map(\.photoId))
            eligible = ids.filter(held.contains)
            if !eligible.isEmpty {
                let leaving = Set(eligible)
                next[keyPath: shelf][index].sources.removeAll { leaving.contains($0.photoId) }
                Self.advanceRevision(&next[keyPath: shelf][index].revision)
                next[keyPath: shelf][index].updatedAt = now
                changed = eligible.count
            }
        }
        if let target {
            guard let (shelf, index) = Self.locate(target, in: next) else { throw StoreError.unknownInstance }
            let held = Set(next[keyPath: shelf][index].sources.map(\.photoId))
            let arriving = eligible.filter { !held.contains($0) }
            if !arriving.isEmpty {
                arrivingLinks = arriving.map { .manual(photoId: $0, addedAt: now) }
                next[keyPath: shelf][index].sources += arrivingLinks
                Self.advanceRevision(&next[keyPath: shelf][index].revision)
                next[keyPath: shelf][index].updatedAt = now
            }
            if source == nil { changed = arriving.count }
        }
        let outcome = BatchOutcome(changed: changed, unchanged: ids.count - changed)
        guard next != current else { return outcome }
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: op)
            log.error("\(op, privacy: .public) failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("\(op, privacy: .public): changed=\(outcome.changed, privacy: .public) unchanged=\(outcome.unchanged, privacy: .public)")
        added = arrivingLinks
        return outcome
    }

    /// What `linkPhotosForUndo` added, exactly as added, so 撤销 takes back only those links.
    public struct LinkReceipt: Sendable, Equatable {
        public let instanceId: String
        public let added: [PhotoCarrierSource]
        /// The library the links were made in.
        public let generation: UUID
    }

    /// `linkPhotos`, returning the links this save made (not the ones already there).
    /// The links come from the save itself, so a photo another change put there first is not in it.
    public func linkPhotosForUndo(photoIds: [String], toInstance instanceId: String) throws -> LinkReceipt {
        var added: [PhotoCarrierSource] = []
        _ = try changeLinks(photoIds: photoIds, from: nil, to: instanceId, op: "linkPhotos", added: &added)
        return LinkReceipt(instanceId: instanceId, added: added, generation: generation)
    }

    /// Takes back the links of `receipt` that are still on the piece exactly as they were made,
    /// as one write; a link taken off and made again since is someone else's and stays. Refused
    /// (`CancellationError`) in another library than the receipt's. Returns how many went.
    @discardableResult
    public func undoLink(_ receipt: LinkReceipt) throws -> Int {
        try checkGeneration(receipt.generation)
        let current = try loadedState()
        guard let (shelf, index) = Self.locate(receipt.instanceId, in: current) else { return 0 }
        var next = current
        let before = next[keyPath: shelf][index].sources.count
        next[keyPath: shelf][index].sources.removeAll { receipt.added.contains($0) }
        let removed = before - next[keyPath: shelf][index].sources.count
        guard removed > 0 else { return 0 }
        Self.advanceRevision(&next[keyPath: shelf][index].revision)
        next[keyPath: shelf][index].updatedAt = Self.now()
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: "undoLink")
            log.error("undoLink failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("undoLink: removed=\(removed, privacy: .public)")
        return removed
    }

    // MARK: - Suggestions confirmed in a batch

    /// What `fileSuggestions` did, enough to undo it exactly.
    public struct SuggestionReceipt: Sendable, Equatable {
        public struct Filed: Sendable, Equatable {
            public let photoId: String
            public let instanceId: String
            /// The observation recording the suggestion; the new link points at it.
            public let observationId: String
            /// The board links the photo had before, exactly as they were and where they were.
            public let boardLinks: [BoardLink]
        }

        public struct BoardLink: Sendable, Equatable {
            public let instanceId: String
            public let position: Int
            public let link: PhotoCarrierSource
        }

        public let filed: [Filed]
        /// Offers that no longer described the home (filed or moved by hand meanwhile, piece
        /// gone, or a photo board as target) and were left alone.
        public let skipped: [String]
        /// The library the photos were filed in.
        public let generation: UUID
        /// Nothing was filed because the offers were worked out on an older home than this one
        /// (`basedOnRevision`): a refusal, not "no offer held" (owner 2026-11-24, L24-02).
        public private(set) var homeChanged = false
    }

    /// Files confirmed suggestions as one write. Each photo gets a model-origin link backed by an
    /// on-device observation whose analyzer is `BatchSuggestionSettings.analyzer` (the category
    /// is the piece's, the label is the analyzer of the prints compared), so the record says
    /// "suggested by the app, confirmed by the user" and never reads as a hand-picked filing.
    /// A photo on a board leaves the boards it was offered from. An offer that is no longer
    /// current (`BatchSuggestions.isCurrent`) is skipped: a move the user made by hand wins.
    public func fileSuggestions(_ offers: [BatchSuggestion], printsBy embedderAnalyzer: String,
                                generation: UUID? = nil, basedOnRevision: Int? = nil) throws -> SuggestionReceipt {
        try checkGeneration(generation)
        let current = try loadedState()
        // Worked out on another home than this one (a remote change landed since): none holds.
        if let basedOnRevision, current.revision != basedOnRevision {
            log.notice("fileSuggestions: home changed since the offers, none filed")
            return SuggestionReceipt(filed: [], skipped: offers.map(\.photoId), generation: self.generation, homeChanged: true)
        }
        var next = current
        var filed: [SuggestionReceipt.Filed] = []
        var skipped: [String] = []
        var seen = Set<String>()
        let now = Self.now()
        for offer in offers {
            guard seen.insert(offer.photoId).inserted else { skipped.append(offer.photoId); continue }
            guard BatchSuggestions.isCurrent(offer, in: next, catalog: catalog),
                  let (shelf, index) = Self.locate(offer.instanceId, in: next),
                  let model = catalog.model(id: next[keyPath: shelf][index].modelId) else {
                skipped.append(offer.photoId)
                continue
            }
            var boardLinks: [SuggestionReceipt.BoardLink] = []
            for board in offer.fromBoards.sorted() {
                guard let (boardShelf, boardIndex) = Self.locate(board, in: next),
                      let position = next[keyPath: boardShelf][boardIndex].sources.firstIndex(where: { $0.photoId == offer.photoId })
                else { continue }
                boardLinks.append(.init(instanceId: board, position: position,
                                        link: next[keyPath: boardShelf][boardIndex].sources[position]))
                next[keyPath: boardShelf][boardIndex].sources.removeAll { $0.photoId == offer.photoId }
                Self.advanceRevision(&next[keyPath: boardShelf][boardIndex].revision)
                next[keyPath: boardShelf][boardIndex].updatedAt = now
            }
            let observation = PhotoObservation(
                observationId: UUID().uuidString, photoId: offer.photoId, origin: .model, mode: .onDevice,
                analyzer: BatchSuggestionSettings.analyzer, analyzerRevision: BatchSuggestionSettings.analyzerRevision,
                // The rule passes or not; it has no graded confidence.
                objects: [ObservedObject(kind: model.category, label: embedderAnalyzer, confidence: 1)], createdAt: now)
            next.observations.append(observation)
            next[keyPath: shelf][index].sources.append(
                PhotoCarrierSource(photoId: offer.photoId, observationId: observation.observationId, objectIndex: 0,
                                   origin: .model, relationToCat: .unclear, addedAt: now))
            Self.advanceRevision(&next[keyPath: shelf][index].revision)
            next[keyPath: shelf][index].updatedAt = now
            filed.append(.init(photoId: offer.photoId, instanceId: offer.instanceId, observationId: observation.observationId,
                               boardLinks: boardLinks))
        }
        let receipt = SuggestionReceipt(filed: filed, skipped: skipped, generation: self.generation)
        guard !filed.isEmpty else { return receipt }
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: "fileSuggestions")
            log.error("fileSuggestions failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("fileSuggestions: filed=\(filed.count, privacy: .public) skipped=\(skipped.count, privacy: .public)")
        return receipt
    }

    /// Takes back what `fileSuggestions` did, as one write: each suggested link that is still
    /// there goes, with its observation, and the photo goes back onto the boards it came from
    /// (with the links it had). A photo the user has since moved or unlinked by hand is left as
    /// it is. Returns how many photos were taken back.
    @discardableResult
    public func undoSuggestions(_ receipt: SuggestionReceipt) throws -> Int {
        let current = try loadedState()
        var next = current
        let now = Self.now()
        var undone = 0
        for entry in receipt.filed {
            guard let (shelf, index) = Self.locate(entry.instanceId, in: next),
                  next[keyPath: shelf][index].sources.contains(where: { $0.photoId == entry.photoId && $0.observationId == entry.observationId })
            else { continue }
            next[keyPath: shelf][index].sources.removeAll { $0.photoId == entry.photoId && $0.observationId == entry.observationId }
            Self.advanceRevision(&next[keyPath: shelf][index].revision)
            next[keyPath: shelf][index].updatedAt = now
            next.observations.removeAll { $0.observationId == entry.observationId }
            for board in entry.boardLinks {
                guard let (boardShelf, boardIndex) = Self.locate(board.instanceId, in: next),
                      !next[keyPath: boardShelf][boardIndex].sources.contains(where: { $0.photoId == entry.photoId }) else { continue }
                let sources = next[keyPath: boardShelf][boardIndex].sources
                next[keyPath: boardShelf][boardIndex].sources.insert(board.link, at: min(board.position, sources.count))
                Self.advanceRevision(&next[keyPath: boardShelf][boardIndex].revision)
                next[keyPath: boardShelf][boardIndex].updatedAt = now
            }
            undone += 1
        }
        guard undone > 0 else { return 0 }
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: "undoSuggestions")
            log.error("undoSuggestions failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("undoSuggestions: undone=\(undone, privacy: .public)")
        return undone
    }

    /// Sets or clears the favourite mark on several photos as one write. Returns how many changed.
    @discardableResult
    public func setFavorite(photoIds: [String], _ favorite: Bool) throws -> Int {
        try changeFavorites(photoIds: photoIds, favorite, op: "setFavorite").count
    }

    /// The photos whose mark this write changed, in library order.
    private func changeFavorites(photoIds: [String], _ favorite: Bool, op: String) throws -> [String] {
        let current = try loadedState()
        let ids = Set(photoIds)
        guard ids.isSubset(of: Set(current.photos.map(\.photoId))) else { throw StoreError.unknownPhoto }
        var next = current
        var changed: [String] = []
        for index in next.photos.indices where ids.contains(next.photos[index].photoId) && next.photos[index].favorite != favorite {
            next.photos[index].favorite = favorite
            Self.advanceRevision(&next.photos[index].revision)
            changed.append(next.photos[index].photoId)
        }
        guard !changed.isEmpty else { return [] }
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: op)
            log.error("\(op, privacy: .public) failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("\(op, privacy: .public): changed=\(changed.count, privacy: .public)")
        return changed
    }

    /// What `setFavoriteForUndo` changed: the photos whose mark it set to `favorite`.
    public struct FavoriteReceipt: Sendable, Equatable {
        public let photoIds: [String]
        public let favorite: Bool
        /// The library the marks were changed in.
        public let generation: UUID
    }

    /// `setFavorite`, returning the photos this save changed.
    public func setFavoriteForUndo(photoIds: [String], _ favorite: Bool) throws -> FavoriteReceipt {
        FavoriteReceipt(photoIds: try changeFavorites(photoIds: photoIds, favorite, op: "setFavorite"), favorite: favorite,
                        generation: generation)
    }

    /// Puts back the marks of `receipt` that are still as it set them, as one write; a mark
    /// changed again since stays. Refused (`CancellationError`) in another library than the
    /// receipt's. Returns how many changed.
    @discardableResult
    public func undoFavorite(_ receipt: FavoriteReceipt) throws -> Int {
        try checkGeneration(receipt.generation)
        let present = Set(try loadedState().photos.map(\.photoId))
        return try changeFavorites(photoIds: receipt.photoIds.filter(present.contains), !receipt.favorite, op: "undoFavorite").count
    }

    // MARK: - Settings, backup, restore

    /// Renames the cat. The name is user data: trimmed, single line, 1...20 characters.
    /// An unchanged name writes nothing.
    @discardableResult
    public func setCatName(_ raw: String) throws -> AppState {
        let current = try loadedState()
        guard let name = AppState.normalizedCatName(raw) else { throw StoreError.invalidName }
        guard name != current.catName else { return current }
        var next = current
        next.catName = name
        if !next.cats.isEmpty { next.cats[0].name = name }
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: "setCatName")
            log.error("setCatName failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("setCatName: length=\(name.count, privacy: .public)")
        return state ?? next
    }

    // MARK: - Rooms and cats

    /// The pieces a placement in `roomId` is judged against.
    static func pieces(inRoom roomId: String, of state: AppState) throws -> [PhotoFurniture] {
        guard state.room(id: roomId) != nil else { throw StoreError.unknownRoom }
        return state.furniture(inRoom: roomId)
    }

    /// How a room id is written on a piece: the first room is not written at all.
    static func stored(_ roomId: String) -> String? {
        roomId == AppState.primaryRoomId ? nil : roomId
    }

    /// Adds an empty room after the others. `name` nil or blank leaves it unnamed.
    public func addRoom(name: String? = nil) throws -> Room {
        let room = Room(roomId: UUID().uuidString, name: try Self.roomName(name), createdAt: Self.now())
        try change(op: "addRoom") { next in
            guard next.allRooms.count < AppState.maxRooms else { throw StoreError.tooManyRooms }
            next.rooms = next.allRooms + [room]
        }
        return room
    }

    /// Names a room; nil or blank goes back to the default name.
    @discardableResult
    public func renameRoom(roomId: String, name: String?) throws -> Room {
        let name = try Self.roomName(name)
        let state = try change(op: "renameRoom") { next in
            var rooms = next.allRooms
            guard let index = rooms.firstIndex(where: { $0.roomId == roomId }) else { throw StoreError.unknownRoom }
            rooms[index].name = name
            next.rooms = rooms
        }
        return state.room(id: roomId) ?? Room(roomId: roomId, name: name)
    }

    /// Removes a room. Its furniture goes to the storage box with its photos (nothing is
    /// deleted); a cat that lived there keeps the user company instead. The first room stays.
    /// A locked piece in the room rejects the call: unlock it or move it first.
    public func removeRoom(roomId: String) throws {
        try change(op: "removeRoom") { next in
            guard roomId != AppState.primaryRoomId else { throw StoreError.firstRoom }
            guard next.room(id: roomId) != nil else { throw StoreError.unknownRoom }
            let leaving = next.furniture(inRoom: roomId)
            guard !leaving.contains(where: \.isLocked) else { throw StoreError.locked }
            let now = Self.now()
            next.items.removeAll { AppState.roomId(of: $0) == roomId }
            next.storage += leaving.map { piece in
                var item = piece
                item.roomId = nil
                Self.advanceRevision(&item.revision)
                item.updatedAt = now
                return item
            }
            // Pieces put away earlier remembered this room as where they came from.
            for index in next.storage.indices where next.storage[index].roomId == roomId { next.storage[index].roomId = nil }
            next.rooms.removeAll { $0.roomId == roomId }
            for index in next.cats.indices where next.cats[index].roomId == roomId { next.cats[index].roomId = nil }
        }
    }

    /// Adds a cat after the others. `roomId` nil = it keeps the user company.
    public func addCat(name: String, roomId: String? = nil) throws -> Cat {
        guard let name = AppState.normalizedCatName(name) else { throw StoreError.invalidName }
        let cat = Cat(catId: UUID().uuidString, name: name, roomId: roomId)
        try change(op: "addCat") { next in
            guard next.allCats.count < AppState.maxCats else { throw StoreError.tooManyCats }
            if let roomId, next.room(id: roomId) == nil { throw StoreError.unknownRoom }
            next.cats = next.allCats + [cat]
        }
        return cat
    }

    /// Renames a cat. The first cat's name is also `catName`.
    @discardableResult
    public func renameCat(catId: String, name: String, generation: UUID? = nil) throws -> Cat {
        try checkGeneration(generation)
        guard let name = AppState.normalizedCatName(name) else { throw StoreError.invalidName }
        let state = try change(op: "renameCat") { next in
            var cats = next.allCats
            guard let index = cats.firstIndex(where: { $0.catId == catId }) else { throw StoreError.unknownCat }
            cats[index].name = name
            next.cats = cats
            if index == 0 { next.catName = name }
        }
        return state.cat(id: catId) ?? Cat(catId: catId, name: name)
    }

    /// Says which room a cat lives in; nil = it keeps the user company.
    @discardableResult
    public func setCatRoom(catId: String, roomId: String?) throws -> Cat {
        let state = try change(op: "setCatRoom") { next in
            var cats = next.allCats
            guard let index = cats.firstIndex(where: { $0.catId == catId }) else { throw StoreError.unknownCat }
            if let roomId, next.room(id: roomId) == nil { throw StoreError.unknownRoom }
            cats[index].roomId = roomId
            next.cats = cats
        }
        return state.cat(id: catId) ?? Cat(catId: catId, name: "", roomId: roomId)
    }

    /// Removes a cat. Photos and furniture are untouched. The first cat stays.
    public func removeCat(catId: String) throws {
        try change(op: "removeCat") { next in
            guard catId != AppState.primaryCatId else { throw StoreError.firstCat }
            guard next.cat(id: catId) != nil else { throw StoreError.unknownCat }
            next.cats.removeAll { $0.catId == catId }
        }
    }

    private static func roomName(_ raw: String?) throws -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let name = AppState.normalizedRoomName(raw) else { throw StoreError.invalidName }
        return name
    }

    /// One change to the rooms or cats, saved as one write. The lists go back to "absent" when
    /// they say no more than the default (one unnamed room, one cat that keeps the user company),
    /// so such a home's file is the same as before rooms and cats existed. Writes nothing when
    /// nothing changed.
    @discardableResult
    private func change(op: String, _ body: (inout AppState) throws -> Void) throws -> AppState {
        let current = try loadedState()
        var next = current
        try body(&next)
        if next.rooms == [Room(roomId: AppState.primaryRoomId)] { next.rooms = [] }
        if next.cats == [Cat(catId: AppState.primaryCatId, name: next.catName)] { next.cats = [] }
        guard next != current else { return current }
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: op)
            log.error("\(op, privacy: .public) failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("\(op, privacy: .public): rooms=\(next.allRooms.count, privacy: .public) cats=\(next.allCats.count, privacy: .public)")
        return state ?? next
    }

    /// Photo/furniture counts and the bytes the library's own files take on disk. Furniture
    /// counts every piece the user has, in the room or put away.
    public func storageUsage() -> StorageUsage {
        let current = state ?? .empty
        var bytes = 0
        var paths = [Self.stateFile, Self.backupFile, Self.deletionFile]
        for dir in [Self.originalsDir, Self.thumbnailsDir, PickerImportJournal.directory, PickerImportJournal.retiredDirectory] {
            let names = (try? fm.contentsOfDirectory(atPath: url(dir).path)) ?? []
            paths.append(contentsOf: names.map { "\(dir)/\($0)" })
        }
        for path in paths {
            if let size = (try? fm.attributesOfItem(atPath: url(path).path))?[.size] as? NSNumber { bytes += size.intValue }
        }
        let parent = root.deletingLastPathComponent()
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] where isQuarantinedDirectory(name) {
            let contents = fm.enumerator(at: parent.appendingPathComponent(name), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            while let file = contents?.nextObject() as? URL {
                if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true {
                    bytes += values.fileSize ?? 0
                }
            }
        }
        return StorageUsage(photoCount: current.photos.count, furnitureCount: current.items.count + current.storage.count, bytes: bytes)
    }

    /// Writes the whole library as one ZIP at `fileURL` (see `BackupArchive`). Every original
    /// is re-hashed first: a library with a missing or altered original is not exported.
    /// Runs on the store's executor, so no change can slip in half-way. Honors task
    /// cancellation; a failed or cancelled export leaves no file behind and changes nothing.
    public func exportBackup(to fileURL: URL, appVersion: String,
                             progress: @Sendable (BackupProgress) -> Void = { _ in }) throws -> BackupSummary {
        let current = try state ?? load()
        let output = fileURL.deletingLastPathComponent().appendingPathComponent(".export-" + UUID().uuidString)
        defer { try? fm.removeItem(at: output) }
        do {
            let summary = try BackupArchive.write(state: current, root: root, to: output, appVersion: appVersion, progress: progress)
            try Task.checkCancellation()
            try Self.rename(output, to: fileURL)
            log.info("export: photos=\(summary.photoCount, privacy: .public) bytes=\(summary.byteSize, privacy: .public)")
            return summary
        } catch {
            let surfaced = ioError(error, op: "export")
            log.error("export failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
    }

    /// Where `BackupArchive.prepare` builds a library before it replaces this one: a sibling
    /// of the store's folder, so the final switch is one rename on the same volume.
    public nonisolated func makeStagingURL() -> URL {
        root.deletingLastPathComponent()
            .appendingPathComponent(Self.stagingPrefix(for: root) + UUID().uuidString, isDirectory: true)
    }

    /// Installs a verified library after user confirmation. Disaster recovery preserves the
    /// displaced directory so its photos remain available until the user clears all data.
    @discardableResult
    public func replaceLibrary(with prepared: PreparedLibrary, recoveringCorruptLibrary: Bool = false) throws -> AppState {
        let staging = prepared.stagingURL
        // A first load cleans up abandoned staging folders; this one is not abandoned.
        keptStaging = staging
        defer { keptStaging = nil }
        if recoveringCorruptLibrary {
            // Check again at confirmation in case a newer-schema file became available.
            do { _ = try load() } catch StoreError.corruptState {}
        } else {
            _ = try state ?? load()
        }
        guard staging.deletingLastPathComponent().standardizedFileURL == root.deletingLastPathComponent().standardizedFileURL,
              Self.generatedDirectory(staging.lastPathComponent, prefix: Self.stagingPrefix(for: root)),
              fm.fileExists(atPath: staging.appendingPathComponent(Self.stateFile).path)
        else { throw BackupError.stale }
        do {
            try swapIn(staging: staging, state: prepared.state, preserveDamaged: recoveringCorruptLibrary || pickerQuarantinePending)
        } catch {
            let surfaced = publicError(error, op: "replace")
            log.error("replace failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("replace: photos=\(prepared.state.photos.count, privacy: .public) items=\(prepared.state.items.count, privacy: .public)")
        return prepared.state
    }

    /// Switches in an empty library, then erases previously quarantined libraries.
    /// A cleanup error is reported separately so a retry can finish erasing old copies.
    @discardableResult
    public func clearAll() throws -> AppState {
        _ = try state ?? load()
        let staging = makeStagingURL()
        let empty = AppState.empty
        do {
            for dir in [staging, staging.appendingPathComponent(Self.originalsDir), staging.appendingPathComponent(Self.thumbnailsDir)] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: Self.protectionAttributes)
            }
            try Self.writeDurably(try Self.encodeState(empty), to: staging.appendingPathComponent(Self.stateFile), fullSync: true)
            try swapIn(staging: staging, state: empty)
        } catch {
            try? fm.removeItem(at: staging)
            let surfaced = publicError(error, op: "clearAll")
            log.error("clearAll failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        // The user also asked to erase old copies retained during disaster recovery.
        do {
            let parent = root.deletingLastPathComponent()
            for name in try fm.contentsOfDirectory(atPath: parent.path)
            where isQuarantinedDirectory(name) || isSwapDirectory(name) {
                try fm.removeItem(at: parent.appendingPathComponent(name))
            }
            Self.fsyncDirectory(parent)
        } catch {
            throw StoreError.clearCleanupPending
        }
        log.info("clearAll: done")
        return empty
    }

    /// The commit point of restore / import / clear: the staged folder and the live folder
    /// trade places atomically, then the old one (now at the staging path) is deleted.
    private func swapIn(staging: URL, state next: AppState, preserveDamaged: Bool = false) throws {
        let displaced: URL
        do {
            try fire(.swapLibrary)
            Self.fsyncDirectory(staging)
            displaced = try Self.install(staging, at: root, preserveDamaged: preserveDamaged)
        } catch {
            if !fm.fileExists(atPath: root.path) { state = nil }
            try? fm.removeItem(at: staging)
            throw error
        }
        Self.fsyncDirectory(root.deletingLastPathComponent())
        state = next
        pickerCheckpointCount = 0
        pickerQuarantinePending = false
        newLibraryMarked = false
        checkedHEIFOriginals.removeAll()
        generation = UUID()
        primaryIsGood = true
        recoveredFromBackup = false
        deletionPending = false
        if preserveDamaged {
            try? archiveDamagedDirectory(displaced)
        } else {
            try? fm.removeItem(at: displaced)
        }
    }

    static func stagingPrefix(for root: URL) -> String { root.lastPathComponent + ".incoming-" }
    static func previousPrefix(for root: URL) -> String { root.lastPathComponent + ".previous-" }
    private static func recoveryDirectory(_ root: URL) -> URL {
        root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".recovering", isDirectory: true)
    }

    /// Returns the displaced library's actual location. After staging becomes live there is
    /// no fallible third rename in the transaction. Its caller owns cleanup or quarantine.
    static func install(_ staging: URL, at live: URL, preserveDamaged: Bool = false,
                        forceFallback: Bool = false,
                        move: (URL, URL) throws -> Void = { try rename($0, to: $1) }) throws -> URL {
        if !preserveDamaged && !forceFallback {
            if renamex_np(staging.path, live.path, UInt32(RENAME_SWAP)) == 0 { return staging }
            let code = errno
            guard code == ENOTSUP || code == EINVAL else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        }
        let parent = live.deletingLastPathComponent()
        let parked = preserveDamaged ? recoveryDirectory(live) : parent.appendingPathComponent(previousPrefix(for: live) + "active", isDirectory: true)
        try move(live, parked)
        fsyncDirectory(parent)
        do {
            try move(staging, live)
        } catch {
            try move(parked, live)
            fsyncDirectory(parent)
            throw error
        }
        return parked
    }

    private static func generatedDirectory(_ name: String, prefix: String) -> Bool {
        name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private func isPreviousDirectory(_ name: String) -> Bool {
        let prefix = Self.previousPrefix(for: root)
        return name == prefix + "active" || Self.generatedDirectory(name, prefix: prefix)
    }

    private func isSwapDirectory(_ name: String) -> Bool {
        isPreviousDirectory(name) || Self.generatedDirectory(name, prefix: Self.stagingPrefix(for: root))
    }

    private func isQuarantinedDirectory(_ name: String) -> Bool {
        name == Self.recoveryDirectory(root).lastPathComponent || Self.generatedDirectory(name, prefix: root.lastPathComponent + ".damaged-")
    }

    private func archiveDamagedDirectory(_ displaced: URL) throws {
        let parent = root.deletingLastPathComponent()
        try Self.rename(displaced, to: parent.appendingPathComponent(root.lastPathComponent + ".damaged-" + UUID().uuidString))
        Self.fsyncDirectory(parent)
    }

    private func recoverInterruptedSwap() throws {
        let recovery = Self.recoveryDirectory(root)
        if fm.fileExists(atPath: recovery.path) {
            if fm.fileExists(atPath: root.path) {
                // Already committed. Keep the previous files even if quarantine cleanup fails.
                try? archiveDamagedDirectory(recovery)
            } else {
                try Self.rename(recovery, to: root)
            }
            Self.fsyncDirectory(root.deletingLastPathComponent())
        }
        guard !fm.fileExists(atPath: root.path) else { return }
        let parent = root.deletingLastPathComponent()
        let prefix = Self.previousPrefix(for: root)
        guard fm.fileExists(atPath: parent.path) else { return }
        let parked = try fm.contentsOfDirectory(atPath: parent.path).filter(isPreviousDirectory).sorted()
        let active = prefix + "active"
        guard let name = parked.contains(active) ? active : parked.last else { return }
        try Self.rename(parent.appendingPathComponent(name), to: root)
        Self.fsyncDirectory(parent)
        log.error("load: restored the library parked by an interrupted replace")
    }

    /// Staged or parked folders nobody will switch in any more (cancelled preview, crash).
    private func removeStaleStagingDirectories() {
        let parent = root.deletingLastPathComponent()
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        where name != keptStaging?.lastPathComponent && isSwapDirectory(name) {
            try? fm.removeItem(at: parent.appendingPathComponent(name))
        }
    }

    // MARK: - A capture waiting for confirmation (PendingCapture.swift)

    /// Holds a capture until it is confirmed or discarded, replacing any earlier one. Never
    /// changes the library: no record, no revision, nothing for backups or sync.
    public func keepPendingCapture(_ capture: PendingCapture) throws {
        _ = try state ?? load()
        let temp = url(PendingCapture.tempFileName), final = url(PendingCapture.fileName)
        do {
            try? fm.removeItem(at: temp)
            try writeDurably(try PendingCapture.encode(capture, library: root.lastPathComponent), to: temp)
            try Self.excludeFromBackup(temp)
            try Self.rename(temp, to: final)
            try Self.excludeFromBackup(final)
        } catch {
            try? fm.removeItem(at: temp)
            let surfaced = ioError(error, op: "pendingCapture")
            log.error("pending capture not kept: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
    }

    /// The capture to offer again, if there is one (audit E24-04). Only a readable copy in the
    /// library makes the file redundant; nothing else deletes it here:
    /// - a file that cannot be read now, or a library that cannot be opened, stays as it is
    ///   and is asked about next time;
    /// - a file that is not a whole capture of this library is set aside unchanged
    ///   (`PendingCapture.keptPrefix`), never offered, and goes only with clear-all or a restore.
    /// `generation`: the library the caller asks about; another one's question gets nil.
    public func pendingCapture(generation expected: UUID? = nil) -> PendingCapture? {
        if let expected, expected != generation { return nil }
        let file = url(PendingCapture.fileName), temp = url(PendingCapture.tempFileName)
        let library = root.lastPathComponent
        if fm.fileExists(atPath: temp.path) {
            // Written in full but stopped before taking its name: the newest capture.
            if let bytes = try? Data(contentsOf: temp), PendingCapture.decode(bytes, library: library) != nil,
               (try? Self.rename(temp, to: file)) != nil {
                try? Self.excludeFromBackup(file)
            } else {
                try? fm.removeItem(at: temp)
            }
        }
        guard fm.fileExists(atPath: file.path) else { return nil }
        let bytes: Data
        do { bytes = try Data(contentsOf: file) } catch {
            log.error("pending capture unreadable now; kept: \(Self.code(error), privacy: .public)")
            return nil
        }
        guard let capture = PendingCapture.decode(bytes, library: library) else {
            setPendingCaptureAside(file)
            return nil
        }
        guard let current = try? state ?? load() else {
            log.error("pending capture kept: the library did not open")
            return nil
        }
        let sha = capture.sha256
        if let stored = current.photos.first(where: { $0.sha256 == sha && $0.reducedFrom == nil }),
           blobMatches(url(stored.originalFile), sha256: sha, byteSize: stored.byteSize) {
            // Confirmed, then the app stopped before the file went.
            try? fm.removeItem(at: file)
            return nil
        }
        return capture
    }

    private func setPendingCaptureAside(_ file: URL) {
        let aside = url(PendingCapture.keptPrefix + UUID().uuidString)
        do {
            try Self.rename(file, to: aside)
            Self.fsyncDirectory(root)
            try? Self.excludeFromBackup(aside)
            log.error("pending capture not offerable; set aside")
        } catch {
            log.error("pending capture not offerable; kept in place")
        }
    }

    /// Deletes the held capture, only if it is still this one (`sha256`) of this library
    /// (`generation`): a newer capture, a file that cannot be read or matched, and a later
    /// library's file all stay.
    public func removePendingCapture(sha256: String, generation expected: UUID? = nil) {
        if let expected, expected != generation { return }
        let file = url(PendingCapture.fileName)
        guard let bytes = try? Data(contentsOf: file),
              let held = PendingCapture.decode(bytes, library: root.lastPathComponent), held.sha256 == sha256 else { return }
        try? fm.removeItem(at: file)
    }

    static func excludeFromBackup(_ fileURL: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = fileURL
        try target.setResourceValues(values)
    }

    // MARK: - Sync (SyncSession.swift)

    /// Sync's own file. It lives in the library folder, so a restore or a clear, which switch
    /// in a whole new folder, leave sync with nothing to diff against: it then merges as on
    /// first sync and never reads the switch as "the user deleted everything".
    static let syncStateFile = "sync-state.json"
    /// The sync file before its last write. A damaged sync file falls back to it: one write
    /// behind, but consistent with the library (the library is only written after sync's own
    /// file), and it still has the edits captured but not sent.
    static let syncStateBackupFile = "sync-state.backup.json"

    /// The library, and the token that changes when the library is replaced as a whole.
    public func syncSnapshot() throws -> (state: AppState, generation: UUID) {
        (try loadedState(), generation)
    }

    public func readSyncState() throws -> Data? {
        try readSyncFile(Self.syncStateFile)
    }

    func readSyncStateBackup() throws -> Data? {
        try readSyncFile(Self.syncStateBackupFile)
    }

    private func readSyncFile(_ name: String) throws -> Data? {
        _ = try state ?? load()
        let file = url(name)
        guard fm.fileExists(atPath: file.path) else { return nil }
        do { return try Data(contentsOf: file) } catch { throw ioError(error, op: "readSyncState") }
    }

    /// Refused if the library was replaced since `generation` was read.
    public func writeSyncState(_ data: Data, generation expected: UUID) throws {
        guard generation == expected else { throw SyncApplyError.libraryReplaced }
        try writeSyncStateFile(data)
    }

    /// Suffix of the copies sync's file and its backup are moved to when neither could be read
    /// and sync starts over: kept, not deleted (what to do with them is not decided here).
    static let unreadableSuffix = ".unreadable"

    /// Moves sync's file and its backup aside before a start over replaces them (both unreadable).
    func setAsideUnreadableSyncState(generation expected: UUID) throws {
        guard generation == expected else { throw SyncApplyError.libraryReplaced }
        do {
            for name in [Self.syncStateFile, Self.syncStateBackupFile] where fm.fileExists(atPath: url(name).path) {
                try Self.rename(url(name), to: url(name + Self.unreadableSuffix))
            }
            Self.fsyncDirectory(root)
        } catch {
            throw ioError(error, op: "setAsideSyncState")
        }
    }

    /// Switches to a library sync built from `syncSnapshot()`, as one write: new photos' files
    /// first, then the state (through the deletion journal when files go), then sync's own
    /// file. Refused, with nothing changed, if the library changed since `revision` (an edit
    /// came in: capture it and build again) or was replaced.
    public func applySynced(_ next: AppState, ifRevision revision: Int, generation expected: UUID,
                            writes: [SyncFileWrite], syncState: (AppState) throws -> Data) throws -> AppState {
        guard generation == expected else { throw SyncApplyError.libraryReplaced }
        let current = try loadedState()
        guard current.revision == revision else { throw SyncApplyError.localChanged }
        var candidate = next
        candidate.revision = current.revision
        let wanted = Set(candidate.photos.flatMap { [$0.originalFile, $0.thumbnailFile] })
        let fault = Self.consistencyFault(candidate)
            ?? (writes.allSatisfy({ wanted.contains($0.originalFile) && wanted.contains($0.thumbnailFile) }) ? nil : "syncWrites")
        if let fault {
            log.error("sync: built library refused: \(fault, privacy: .public)")
            throw SyncApplyError.inconsistent
        }
        var created: [URL] = []
        do {
            for write in writes {
                // Copied from where sync staged it (a clone on APFS): the staged copy stays
                // until the library is committed, so a failed write downloads nothing again.
                let original = url(write.originalFile), thumbnail = url(write.thumbnailFile)
                if !blobMatches(original, sha256: write.file.info.sha256, byteSize: write.file.info.byteSize) {
                    try? fm.removeItem(at: original)
                    try fm.copyItem(at: url(write.file.stagedFile), to: original)
                    created.append(original)
                    try Self.fsync(original)
                }
                try fire(.writeOriginal)
                if !fm.fileExists(atPath: thumbnail.path) {
                    try fm.copyItem(at: url(write.file.stagedThumbnail), to: thumbnail)
                    created.append(thumbnail)
                    try Self.fsync(thumbnail)
                }
                try fire(.writeThumbnail)
            }
            if !writes.isEmpty {
                Self.fsyncDirectory(url(Self.originalsDir))
                Self.fsyncDirectory(url(Self.thumbnailsDir))
            }
            let gone = Set(current.photos.flatMap { [$0.originalFile, $0.thumbnailFile] }).subtracting(wanted)
            if gone.isEmpty {
                try persist(candidate)
            } else {
                // Photos deleted on another device: committed like `deletePhotos`.
                try compactPickerImports()
                Self.advanceRevision(&candidate.revision)
                let temp = url(Self.tempStateFile)
                do {
                    try? fm.removeItem(at: temp)
                    try writeDurably(try Self.encodeState(candidate), to: temp, fullSync: true)
                    try fire(.writeState)
                    try Self.rename(temp, to: url(Self.deletionFile))
                    Self.fsyncDirectory(root)
                } catch {
                    try? fm.removeItem(at: temp)
                    throw error
                }
                state = candidate
                deletionPending = true
                retryDeletionIDs = []
                do { try finishDeletion(candidate) } catch StoreError.deletionCleanupPending {}
            }
        } catch {
            rollback(created)
            let surfaced = publicError(error, op: "applySynced")
            log.error("applySynced failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        let committed = state ?? candidate
        do { try fire(.syncStateAfterApply) } catch { throw publicError(error, op: "applySynced") }
        try writeSyncStateFile(try syncState(committed))
        for write in writes {
            try? fm.removeItem(at: url(write.file.stagedFile))
            try? fm.removeItem(at: url(write.file.stagedThumbnail))
        }
        log.info("applySynced: photos=\(committed.photos.count, privacy: .public) files=\(writes.count, privacy: .public)")
        return committed
    }

    /// Copies sync downloaded and checked, waiting for `applySynced`: `<sha256>.copy` and its
    /// thumbnail `<sha256>.thumb`. They outlast a cycle that has to start again (an edit came
    /// in) or fails, so a long first sync never downloads the same file twice, and only one
    /// file at a time is in memory. Not part of the library: backups, restores and the orphan
    /// check never look here.
    static let syncIncomingDir = "sync-incoming"

    private func stagedPaths(_ sha256: String) -> (copy: String, thumbnail: String) {
        ("\(Self.syncIncomingDir)/\(sha256).copy", "\(Self.syncIncomingDir)/\(sha256).thumb")
    }

    /// Stores a downloaded copy whose bytes match `info` (the caller checked them and made the
    /// thumbnail), each file written in full before it takes its name.
    /// Refused if the library was replaced since `generation` was read: a download from before a
    /// restore is not written into the new library (DD24-02).
    func stageSyncedFile(_ data: Data, thumbnailJPEG: Data, info: SyncFileInfo, generation expected: UUID) throws -> SyncIncomingFile {
        guard generation == expected else { throw SyncApplyError.libraryReplaced }
        guard BackupArchive.isHash(info.sha256), data.count == info.byteSize else { throw StoreError.io("stageSyncedFile:name") }
        let (copy, thumbnail) = stagedPaths(info.sha256)
        do {
            try fm.createDirectory(at: url(Self.syncIncomingDir), withIntermediateDirectories: true, attributes: Self.protectionAttributes)
            for (bytes, path) in [(thumbnailJPEG, thumbnail), (data, copy)] {
                let temp = url(path + ".tmp")
                try? fm.removeItem(at: temp)
                try writeDurably(bytes, to: temp)
                try Self.rename(temp, to: url(path))
            }
            Self.fsyncDirectory(url(Self.syncIncomingDir))
        } catch {
            throw ioError(error, op: "stageSyncedFile")
        }
        return SyncIncomingFile(info: info, stagedFile: copy, stagedThumbnail: thumbnail)
    }

    /// The staged copy of `info`, if one is here whole and still matches its hash.
    func stagedSyncedFile(_ info: SyncFileInfo) -> SyncIncomingFile? {
        guard BackupArchive.isHash(info.sha256) else { return nil }
        let (copy, thumbnail) = stagedPaths(info.sha256)
        guard fm.fileExists(atPath: url(thumbnail).path), blobMatches(url(copy), sha256: info.sha256, byteSize: info.byteSize) else {
            return nil
        }
        return SyncIncomingFile(info: info, stagedFile: copy, stagedThumbnail: thumbnail)
    }

    /// Drops staged copies sync no longer waits for (nil: all of them).
    func pruneSyncIncoming(keeping: Set<String>?) {
        let dir = url(Self.syncIncomingDir)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            let sha = String(name.prefix { $0 != "." })
            if let keeping, keeping.contains(sha), !name.hasSuffix(".tmp") { continue }
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// The library was opened from something older than the newest state (the backup, a picker
    /// baseline, a quarantined import), while sync's file stayed. Sync's base becomes the library
    /// as opened, before any new edit: what the opened copy lacks or has older is then not read
    /// as the user deleting or changing it, and the merged records bring the newer state back.
    /// A base older than the opened library is left alone: the difference is real edits.
    /// The generation changes, so a cycle that read the old base is refused and starts again.
    private func rebaseSyncState(onto opened: AppState) {
        let names = [Self.syncStateFile, Self.syncStateBackupFile]
        // A newer version's file is never rewritten from an older copy (COMPAT-4).
        let reads = names.compactMap { (try? Data(contentsOf: self.url($0))).map(SyncDeviceState.read) }
        if reads.contains(where: { if case .newer = $0 { true } else { false } }) { return }
        guard var device = names.lazy.compactMap({ (try? Data(contentsOf: self.url($0))).flatMap(SyncDeviceState.decode) }).first,
              let base = device.base, base.revision >= opened.revision, base != opened else { return }
        device.base = opened
        do {
            let data = try device.encoded()
            // Twice, so the backup is rebased too.
            try writeSyncStateFile(data)
            try writeSyncStateFile(data)
            generation = UUID()
            log.notice("load: sync rebased onto the recovered library")
        } catch {
            // The session makes the same check on its next capture.
            log.error("load: sync rebase not written")
        }
    }

    private func writeSyncStateFile(_ data: Data) throws {
        let temp = url(Self.syncStateFile + ".tmp"), primary = url(Self.syncStateFile)
        do {
            try? fm.removeItem(at: temp)
            try writeDurably(data, to: temp, fullSync: true)
            // The previous version becomes the backup. A crash between the two renames leaves
            // only the backup, which is read as the previous write. A previous version that
            // cannot be read (sync fell back to the backup) does not replace the backup: until
            // the new file has its name, the backup is the only good copy (AA24-02).
            if fm.fileExists(atPath: primary.path), primaryWorthKeeping(primary) {
                try Self.rename(primary, to: url(Self.syncStateBackupFile))
            }
            try Self.rename(temp, to: primary)
            Self.fsyncDirectory(root)
        } catch {
            try? fm.removeItem(at: temp)
            throw ioError(error, op: "writeSyncState")
        }
    }

    /// The file about to become the backup: kept unless it cannot be read while a backup is there.
    private func primaryWorthKeeping(_ primary: URL) -> Bool {
        guard fm.fileExists(atPath: url(Self.syncStateBackupFile).path) else { return true }
        guard let data = try? Data(contentsOf: primary) else { return false }
        if case .unreadable = SyncDeviceState.read(data) { return false }
        return true
    }

    // MARK: - Internals

    private func loadedState() throws -> AppState {
        if let expected = Self.expectedGeneration, expected != generation { throw CancellationError() }
        let current = try state ?? load()
        if pickerQuarantinePending { try quarantinePickerTail(current) }
        if deletionPending { try finishDeletion(current) }
        return current
    }

    /// Where an instance lives: in the room (`items`) or put away (`storage`).
    static func locate(_ instanceId: String, in state: AppState) -> (shelf: WritableKeyPath<AppState, [PhotoFurniture]>, index: Int)? {
        for shelf in [\AppState.items, \AppState.storage] {
            if let index = state[keyPath: shelf].firstIndex(where: { $0.instanceId == instanceId }) { return (shelf, index) }
        }
        return nil
    }

    private func url(_ relative: String) -> URL {
        root.appendingPathComponent(relative, isDirectory: false)
    }

    private func checkDraft(_ draft: ImportDraft) throws {
        guard !draft.data.isEmpty, draft.byteSize == draft.data.count,
              PhotoIngest.sha256Hex(draft.data) == draft.sha256 else {
            throw StoreError.io("draftMismatch")
        }
    }

    /// Reuses the record for identical bytes; otherwise writes original + thumbnail and appends a record.
    private func ensurePhoto(draft: ImportDraft, in next: inout AppState, created: inout [URL]) throws -> PhotoRecord {
        if let index = next.photos.firstIndex(where: { $0.isSamePhoto(as: draft) }) {
            let existing = next.photos[index]
            log.info("ingest: dedupe photo=\(existing.photoId, privacy: .public)")
            // The record exists; heal its blobs from the (hash-verified) draft if they are
            // missing or damaged. A healed blob holds exactly the bytes its committed record
            // describes, so it is kept even if this commit later rolls back.
            let healed = try healBlobs(of: existing, from: draft)
            if healed.original { try fire(.writeOriginal) }
            if healed.thumbnail { try fire(.writeThumbnail) }
            next.photos[index].learnLibraryIdentifiers(from: draft)
            return next.photos[index]
        }
        return try writeNewPhoto(draft: draft, in: &next, created: &created)
    }

    private func writeNewPhoto(draft: ImportDraft, in next: inout AppState, created: inout [URL]) throws -> PhotoRecord {
        let photoId = UUID().uuidString
        let ext = UTType(mimeType: draft.mimeType)?.preferredFilenameExtension ?? "bin"
        let originalFile = "\(Self.originalsDir)/\(draft.sha256).\(ext)"
        let thumbnailFile = "\(Self.thumbnailsDir)/\(photoId).jpg"

        let originalURL = url(originalFile)
        if blobMatches(originalURL, sha256: draft.sha256, byteSize: draft.byteSize) {
            // A leftover blob with identical bytes (e.g. from an interrupted import): reuse it.
        } else {
            try? fm.removeItem(at: originalURL)
            try writeDurably(draft.data, to: originalURL)
            created.append(originalURL)
            Self.fsyncDirectory(url(Self.originalsDir))
        }
        try fire(.writeOriginal)

        let thumbURL = url(thumbnailFile)
        try writeDurably(draft.thumbnailJPEG, to: thumbURL)
        created.append(thumbURL)
        Self.fsyncDirectory(url(Self.thumbnailsDir))
        try fire(.writeThumbnail)

        let record = PhotoRecord(
            photoId: photoId, filename: draft.filename, sha256: draft.sha256, mimeType: draft.mimeType,
            byteSize: draft.byteSize, width: draft.width, height: draft.height,
            originalFile: originalFile, thumbnailFile: thumbnailFile,
            captureDate: draft.captureDate, captureDateSource: draft.captureDateSource,
            exifCaptureDate: draft.captureDateSource == .exif ? draft.captureDate : nil,
            importedAt: Self.now(), revision: 1, reducedFrom: draft.reducedFrom,
            assetIdentifier: draft.assetIdentifier, cloudIdentifier: draft.cloudIdentifier)
        next.photos.append(record)
        return record
    }

    /// Stores the recognition (if any) and returns the source per the commit rule.
    private func appendObservation(decision: SourceDecision, photoId: String, category: FurnitureCategory,
                                   in next: inout AppState) -> PhotoCarrierSource {
        guard let recognition = decision.recognition else { return .manual(photoId: photoId, addedAt: Self.now()) }
        let observation = PhotoObservation(
            observationId: UUID().uuidString, photoId: photoId, origin: .model, mode: .onDevice,
            analyzer: recognition.analyzer, analyzerRevision: recognition.analyzerRevision,
            objects: recognition.objects, createdAt: Self.now())
        next.observations.append(observation)
        if let index = decision.acceptedObjectIndex, recognition.objects.indices.contains(index),
           recognition.objects[index].kind == category {
            return PhotoCarrierSource(photoId: photoId, observationId: observation.observationId,
                                      objectIndex: index, origin: .model, relationToCat: .unclear, addedAt: Self.now())
        }
        return .manual(photoId: photoId, addedAt: Self.now())
    }

    /// Writes `candidate` as the new primary. On success updates memory; on failure leaves
    /// disk state files and memory untouched (callers remove their own new blobs).
    private func persist(_ candidate: AppState) throws {
        try compactPickerImports()
        var next = candidate
        Self.advanceRevision(&next.revision)
        let tempURL = url(Self.tempStateFile), tempBackupURL = url(Self.tempBackupFile)
        let primaryURL = url(Self.stateFile), backupURL = url(Self.backupFile)
        do {
            let data = try Self.encodeState(next)
            try? fm.removeItem(at: tempURL)
            try writeDurably(data, to: tempURL, fullSync: true)
            // Injected faults propagate unchanged (like the blob-step faults).
            try fire(.writeState)

            var stageBackup = false
            if primaryIsGood, fm.fileExists(atPath: primaryURL.path) {
                try? fm.removeItem(at: tempBackupURL)
                try fm.copyItem(at: primaryURL, to: tempBackupURL)
                try Self.fullFsync(tempBackupURL)
                stageBackup = true
            }
            // The commit point: atomic replace of the primary.
            try Self.rename(tempURL, to: primaryURL)
            Self.fsyncDirectory(root)
            forgetNewLibraryMarker()
            if stageBackup {
                // The new primary is already durable; a failure here only leaves an older backup.
                do { try Self.rename(tempBackupURL, to: backupURL) } catch {
                    log.error("persist: backup rotate failed \(Self.code(error), privacy: .public)")
                    try? fm.removeItem(at: tempBackupURL)
                }
                Self.fsyncDirectory(root)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            try? fm.removeItem(at: tempBackupURL)
            // Injected faults stay wrapped so the public entry point can pass them through
            // unchanged; everything else becomes a path-free StoreError here.
            if error is InjectedFaultPassthrough || error is StoreError { throw error }
            throw ioError(error, op: "persist")
        }
        state = next
        primaryIsGood = true
        recoveredFromBackup = false
    }

    private func finishDeletion(_ committed: AppState) throws {
        let journal = url(Self.deletionFile)
        do {
            for (tempName, name) in [(Self.tempStateFile, Self.stateFile), (Self.tempBackupFile, Self.backupFile)] {
                let temp = url(tempName)
                try? fm.removeItem(at: temp)
                if name == Self.backupFile { try fire(.deletionBackupCopy) }
                try fm.copyItem(at: journal, to: temp)
                if name == Self.backupFile { try fire(.deletionBackupSync) }
                try Self.fullFsync(temp)
                if name == Self.backupFile { try fire(.deletionBackupRename) }
                try Self.rename(temp, to: url(name))
            }
            Self.fsyncDirectory(root)
            let kept = Set(committed.photos.flatMap { [$0.originalFile, $0.thumbnailFile] })
            for dir in [Self.originalsDir, Self.thumbnailsDir] {
                try fm.createDirectory(at: url(dir), withIntermediateDirectories: true, attributes: Self.protectionAttributes)
                for name in try fm.contentsOfDirectory(atPath: url(dir).path) {
                    let path = "\(dir)/\(name)"
                    if !kept.contains(path), !name.hasPrefix(".") || BackupArchive.isThumbnailPath(path) {
                        try fire(.deletionFileRemoval)
                        try fm.removeItem(at: url(path))
                    }
                }
                Self.fsyncDirectory(url(dir))
            }
            try pickerJournal.retire()
            try fm.removeItem(at: journal)
            Self.fsyncDirectory(root)
            retryDeletionIDs.removeAll()
            deletionPending = false
            primaryIsGood = true
            recoveredFromBackup = false
        } catch {
            log.error("deletePhoto: committed cleanup pending")
            throw StoreError.deletionCleanupPending
        }
    }

    /// Runs the test fault hook; its errors are tagged so they propagate unchanged.
    private func fire(_ step: StoreStep) throws {
        guard let fault else { return }
        do { try fault(step) } catch { throw InjectedFaultPassthrough(error) }
    }

    /// What a public mutating API throws: injected faults unchanged, StoreErrors as is,
    /// every real I/O error as a path-free `StoreError.io`.
    private func publicError(_ error: Error, op: String) -> Error {
        if let passthrough = error as? InjectedFaultPassthrough { return passthrough.error }
        return ioError(error, op: op)
    }

    /// Cheap size check first, then (at most once) a full hash.
    private func blobMatches(_ fileURL: URL, sha256: String, byteSize: Int) -> Bool {
        guard let attributes = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber, size.intValue == byteSize
        else { return false }
        return Self.hashFile(fileURL) == sha256
    }

    /// Rewrites a record's original (missing or hash mismatch) and thumbnail (missing or undecodable) from a
    /// draft whose bytes were verified against `photo.sha256`. The original is replaced
    /// atomically via a temp file + rename, so the old copy is never lost half-way.
    @discardableResult
    private func healBlobs(of photo: PhotoRecord, from draft: ImportDraft) throws -> (original: Bool, thumbnail: Bool) {
        guard draft.sha256 == photo.sha256 else { return (false, false) }
        var healed = (original: false, thumbnail: false)
        let originalURL = url(photo.originalFile)
        if !blobMatches(originalURL, sha256: photo.sha256, byteSize: photo.byteSize) {
            let tempURL = url("\(Self.originalsDir)/\(photo.sha256).heal-tmp")
            do {
                try? fm.removeItem(at: tempURL)
                try writeDurably(draft.data, to: tempURL)
                try Self.rename(tempURL, to: originalURL)
            } catch {
                try? fm.removeItem(at: tempURL)
                throw error
            }
            Self.fsyncDirectory(url(Self.originalsDir))
            checkedHEIFOriginals.remove(photo.sha256)
            healed.original = true
            log.notice("ingest: healed original photo=\(photo.photoId, privacy: .public)")
        }
        // A thumbnail is derived from these verified bytes: one that is missing or does not
        // decode (e.g. cut short) is replaced whole through a temp file (audit T24-06).
        let thumbURL = url(photo.thumbnailFile)
        let thumbnailUsable = (try? Data(contentsOf: thumbURL)).flatMap { PhotoIngest.downsampledImage(data: $0, maxPixel: 16) } != nil
        if !thumbnailUsable, !draft.thumbnailJPEG.isEmpty {
            let tempURL = url("\(Self.thumbnailsDir)/\(photo.photoId).heal-tmp")
            do {
                try? fm.removeItem(at: tempURL)
                try writeDurably(draft.thumbnailJPEG, to: tempURL)
                try Self.rename(tempURL, to: thumbURL)
            } catch {
                try? fm.removeItem(at: tempURL)
                throw error
            }
            Self.fsyncDirectory(url(Self.thumbnailsDir))
            healed.thumbnail = true
            log.notice("ingest: healed thumbnail photo=\(photo.photoId, privacy: .public)")
        }
        return healed
    }

    private func removeStaleTempFiles() {
        for name in [Self.tempStateFile, Self.tempBackupFile] {
            try? fm.removeItem(at: url(name))
        }
    }

    private func rollback(_ created: [URL]) {
        for file in created { try? fm.removeItem(at: file) }
    }

    enum Decoded {
        case valid(AppState)
        case newer(Int)
        case invalid
        /// The file is there but reading it failed (I/O, data protection): its contents are
        /// unknown. A missing file is `.invalid`; callers check existence themselves.
        case unreadable(String)
    }

    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }

    /// Loading never depends on the catalog: only structural consistency is checked.
    private func decode(_ fileURL: URL) -> Decoded {
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch {
            return Self.isMissingFile(error) ? .invalid : .unreadable(Self.code(error))
        }
        return Self.decodeState(data)
    }

    static func isMissingFile(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.fileReadNoSuchFile.rawValue || ns.code == CocoaError.fileNoSuchFile.rawValue {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        return (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map(isMissingFile) ?? false
    }

    /// The one way a state file is written, for the store and for backups alike.
    static func encodeState(_ state: AppState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(state)
    }

    /// The one way a state file is read (schema 1...current, structurally consistent).
    static func decodeState(_ data: Data) -> Decoded {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let probe = try? decoder.decode(SchemaProbe.self, from: data) else { return .invalid }
        if probe.schemaVersion > AppState.currentSchemaVersion { return .newer(probe.schemaVersion) }
        guard var decoded = try? decoder.decode(AppState.self, from: data),
              (AppState.oldestReadableSchemaVersion...AppState.currentSchemaVersion).contains(decoded.schemaVersion),
              Self.isConsistent(decoded)
        else { return .invalid }
        // Older layouts are migrated in memory (PhotoRecord fills the missing fields while
        // decoding); the file itself is rewritten in the current layout by the next save.
        decoded.schemaVersion = AppState.currentSchemaVersion
        return .valid(decoded)
    }

    private func orphanPaths(in current: AppState) -> [String] {
        let referenced = Set(current.photos.flatMap { [$0.originalFile, $0.thumbnailFile] })
        var orphans: [String] = []
        for dir in [Self.originalsDir, Self.thumbnailsDir] {
            let names = (try? fm.contentsOfDirectory(atPath: url(dir).path)) ?? []
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = "\(dir)/\(name)"
                if !referenced.contains(path) { orphans.append(path) }
            }
        }
        return orphans
    }

    /// Only after a good primary load: blobs no record references are leftovers of an
    /// interrupted mutation. Never runs when we fell back to the backup.
    private func cleanOrphans(in current: AppState) {
        var orphans = orphanPaths(in: current)
        guard !orphans.isEmpty else { return }
        switch decode(url(Self.backupFile)) {
        case .newer: return // A rollback from a different layout may still own these files.
        case .unreadable: return // The backup may still own them; its contents are unknown now.
        case .valid(let backup):
            let referenced = Set(backup.photos.flatMap { [$0.originalFile, $0.thumbnailFile] })
            orphans.removeAll { referenced.contains($0) }
        case .invalid: break
        }
        guard !orphans.isEmpty else { return }
        var removed = 0
        for path in orphans where (try? fm.removeItem(at: url(path))) != nil { removed += 1 }
        log.notice("load: removed orphan files=\(removed, privacy: .public) of \(orphans.count, privacy: .public)")
    }

    private func writeDurably(_ data: Data, to fileURL: URL, fullSync: Bool = false) throws {
        try Self.writeDurably(data, to: fileURL, fullSync: fullSync)
    }

    static func writeDurably(_ data: Data, to fileURL: URL, fullSync: Bool = false) throws {
        var options: Data.WritingOptions = [.withoutOverwriting]
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: fileURL, options: options)
        if fullSync { try Self.fullFsync(fileURL) } else { try Self.fsync(fileURL) }
    }

    private func ioError(_ error: Error, op: String) -> any Error {
        if error is StoreError || error is BackupError || error is CancellationError { return error }
        let ns = error as NSError
        return StoreError.io("\(op):\(ns.domain):\(ns.code)")
    }

    // MARK: - Static helpers

    static var protectionAttributes: [FileAttributeKey: Any]? {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        return nil
        #endif
    }

    /// Whole-second timestamps round-trip exactly through ISO-8601 JSON.
    static func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    static func code(_ error: Error) -> String {
        switch error {
        case let e as StoreError:
            switch e {
            case .corruptState: return "corruptState"
            case .deletionCleanupPending: return "deletionCleanupPending"
            case .clearCleanupPending: return "clearCleanupPending"
            case .unknownInstance: return "unknownInstance"
            case .unknownPhoto: return "unknownPhoto"
            case .placement(let issues): return "placement(\(issues.count))"
            case .duplicateSource: return "duplicateSource"
            case .invalidDate: return "invalidDate"
            case .noteTooLong: return "noteTooLong"
            case .invalidName: return "invalidName"
            case .locked: return "locked"
            case .invalidOrder: return "invalidOrder"
            case .unknownRoom: return "unknownRoom"
            case .unknownCat: return "unknownCat"
            case .tooManyRooms: return "tooManyRooms"
            case .tooManyCats: return "tooManyCats"
            case .firstRoom: return "firstRoom"
            case .firstCat: return "firstCat"
            case .io(let code): return "io(\(code))"
            case .newerSchema: return "newerSchema"
            }
        case let e as BackupError:
            return "backup(\(e.code))"
        case is CancellationError:
            return "cancelled"
        default:
            let ns = error as NSError
            return "\(ns.domain):\(ns.code)"
        }
    }

    static func hashFile(_ fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data
            do { chunk = try handle.read(upToCount: 1 << 20) ?? Data() } catch { return nil }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fsync(_ fileURL: URL) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    /// `F_FULLFSYNC` asks the drive to flush its own cache too (plain fsync on Darwin does
    /// not). Falls back to fsync where the file system does not support it.
    static func fullFsync(_ fileURL: URL) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        let fd = handle.fileDescriptor
        if fcntl(fd, F_FULLFSYNC) == -1, Darwin.fsync(fd) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func fsyncDirectory(_ dir: URL) {
        let fd = open(dir.path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = Darwin.fsync(fd)
        close(fd)
    }

    /// POSIX rename(2): atomically replaces `destination`.
    static func rename(_ source: URL, to destination: URL) throws {
        if Darwin.rename(source.path, destination.path) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// Write-path rule: structurally valid AND a model-origin source's observed object matches
    /// the furniture's current catalog category. Never used on load.
    static func sourceIsValid(_ source: PhotoCarrierSource, item: PhotoFurniture, in state: AppState,
                              catalog: FurnitureCatalog) -> Bool {
        guard sourceIsStructurallyValid(source, in: state) else { return false }
        guard let observationId = source.observationId else { return true }
        guard let observation = state.observation(id: observationId),
              let index = source.objectIndex,
              let model = catalog.model(id: item.modelId),
              observation.objects[index].kind == model.category
        else { return false }
        return true
    }

    /// Catalog-independent: the photo exists and any observation reference resolves.
    static func sourceIsStructurallyValid(_ source: PhotoCarrierSource, in state: AppState) -> Bool {
        sourceIsStructurallyValid(source, photoExists: { state.photo(id: $0) != nil }, observation: { state.observation(id: $0) })
    }

    private static func sourceIsStructurallyValid(_ source: PhotoCarrierSource, photoExists: (String) -> Bool,
                                                  observation: (String) -> PhotoObservation?) -> Bool {
        guard photoExists(source.photoId) else { return false }
        guard let observationId = source.observationId else {
            return source.objectIndex == nil && source.origin == .user
        }
        guard let observation = observation(observationId),
              observation.photoId == source.photoId,
              observation.origin == source.origin,
              let index = source.objectIndex,
              observation.objects.indices.contains(index)
        else { return false }
        return true
    }

    // Revisions are equality tokens. Keep them exactly representable in web backups and
    // leave room for arithmetic. Crossing the format boundary starts a new token sequence.
    static let maxRevision = 9_007_199_254_740_991
    static func validRevision(_ value: Int) -> Bool { (0...maxRevision).contains(value) }
    static func nextRevision(_ revision: Int) -> Int { revision == maxRevision ? 1 : revision + 1 }
    private static func advanceRevision(_ revision: inout Int) { revision = nextRevision(revision) }

    /// Structural consistency checked on load; a state failing this is treated as corrupt.
    /// Deliberately independent of the catalog and of the item limit (which applies to adding).
    static func isConsistent(_ state: AppState) -> Bool { consistencyFault(state) == nil }

    /// The first check of `isConsistent` that `state` fails, as a short code for logs (never
    /// contents), or nil when it passes them all. Sync builds a library from records and must
    /// never hand the store one that fails here (`SyncProjection.project`).
    static func consistencyFault(_ state: AppState) -> String? {
        guard validRevision(state.revision), state.photos.allSatisfy({ validRevision($0.revision) }),
              (state.items + state.storage).allSatisfy({ validRevision($0.revision) }) else { return "revision" }
        guard Set(state.photos.map(\.photoId)).count == state.photos.count else { return "photoId" }
        // One photo per stored file: equal bytes are the same photo (`PhotoRecord.isSamePhoto`).
        guard Set(state.photos.map(\.sha256)).count == state.photos.count else { return "photoFile" }
        guard Set(state.observations.map(\.observationId)).count == state.observations.count else { return "observationId" }
        // One instance is in the room or put away, never both.
        guard Set((state.items + state.storage).map(\.instanceId)).count == state.items.count + state.storage.count
        else { return "instanceId" }
        let photoIds = Set(state.photos.map(\.photoId))
        for photo in state.photos {
            for path in [photo.originalFile, photo.thumbnailFile] {
                guard !path.hasPrefix("/"), !path.contains(".."),
                      path.hasPrefix("\(originalsDir)/") || path.hasPrefix("\(thumbnailsDir)/")
                else { return "photoPath" }
            }
        }
        guard state.observations.allSatisfy({ photoIds.contains($0.photoId) }) else { return "observationPhoto" }
        // Rooms and cats: unique ids, the first of each is the one that always exists, and
        // nothing points at a room that is not there.
        let rooms = state.allRooms, cats = state.allCats
        guard rooms.count <= AppState.maxRooms, cats.count <= AppState.maxCats else { return "roomOrCatCount" }
        let roomIds = Set(rooms.map(\.roomId))
        guard roomIds.count == rooms.count, rooms[0].roomId == AppState.primaryRoomId,
              state.items.allSatisfy({ roomIds.contains(AppState.roomId(of: $0)) }) else { return "room" }
        guard Set(cats.map(\.catId)).count == cats.count,
              cats[0].catId == AppState.primaryCatId, cats[0].name == state.catName,
              cats.allSatisfy({ $0.roomId.map(roomIds.contains) ?? true })
        else { return "cat" }
        // No sources is fine (a piece placed from the catalog, or one whose photos were deleted).
        let observations = Dictionary(uniqueKeysWithValues: state.observations.map { ($0.observationId, $0) })
        for item in state.items + state.storage {
            guard Set(item.sources.map(\.photoId)).count == item.sources.count,
                  item.sources.allSatisfy({ sourceIsStructurallyValid($0, photoExists: photoIds.contains, observation: { observations[$0] }) })
            else { return "source" }
        }
        return nil
    }
}

private struct InjectedFaultPassthrough: Error {
    let error: Error
    init(_ error: Error) { self.error = error }
}
