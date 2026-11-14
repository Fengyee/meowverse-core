import CryptoKit
import Foundation
import os
import UniformTypeIdentifiers

/// Steps of a mutation at which a test fault may be injected. The fault runs right AFTER the
/// step's file has been written (for `.writeState`: after the temp state file is written and
/// fsynced, before it replaces `state.json`), so rollback of that file is exercised.
public enum StoreStep: Sendable, Equatable {
    case writeOriginal, writeThumbnail, writeState
    /// Fired right before a fully staged library (restore, web import, clear all) is switched
    /// in. A fault here must leave the current library exactly as it was.
    case swapLibrary
}

public enum StoreError: Error, Equatable, Sendable {
    case corruptState
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

/// On-device photo library + room layout.
///
/// Layout under `root`: `state.json`, `state.backup.json`, `originals/<sha256>.<ext>`,
/// `thumbnails/<photoId>.jpg`. Every mutation is all-or-nothing: blobs first, then the new
/// state is written to a temp file, fsynced and atomically renamed over `state.json`
/// (the previous good primary becomes `state.backup.json`).
public actor LibraryStore {
    public static let stateFile = "state.json"
    public static let backupFile = "state.backup.json"
    public static let originalsDir = "originals"
    public static let thumbnailsDir = "thumbnails"
    static let tempStateFile = "state.json.tmp"
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
    private var state: AppState?
    /// Whether `state.json` on disk is the decoded, valid state (vs. loaded from the backup).
    private var primaryIsGood = false
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
        primaryIsGood = false
        recoveredFromBackup = false
        recoverInterruptedSwap()
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

        do {
            for dir in [root, url(Self.originalsDir), url(Self.thumbnailsDir)] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: Self.protectionAttributes)
            }
        } catch {
            throw ioError(error, op: "mkdir")
        }

        if !primaryExists && !backupExists {
            state = .empty
            log.info("load: empty store")
            // Leftovers of an interrupted first-ever save: no state ever referenced them.
            removeStaleTempFiles()
            removeStaleStagingDirectories()
            cleanOrphans(in: .empty)
            return .empty
        }
        if case .valid(let decoded) = primary {
            state = decoded
            primaryIsGood = true
            log.info("load: primary rev=\(decoded.revision, privacy: .public) photos=\(decoded.photos.count, privacy: .public) items=\(decoded.items.count, privacy: .public)")
            removeStaleTempFiles()
            removeStaleStagingDirectories()
            cleanOrphans(in: decoded)
            return decoded
        }
        if case .valid(let decoded) = backup {
            state = decoded
            recoveredFromBackup = true
            log.error("load: primary unusable (exists=\(primaryExists, privacy: .public)), using backup rev=\(decoded.revision, privacy: .public)")
            return decoded
        }
        log.fault("load: primary and backup unusable; refusing to write")
        throw StoreError.corruptState
    }

    public func snapshot() -> AppState {
        state ?? .empty
    }

    // MARK: - Queries

    public func existingPhoto(matching draft: ImportDraft) -> PhotoRecord? {
        state?.photos.first { $0.isSamePhoto(as: draft) }
    }

    public func furniture(containingPhoto photoId: String) -> [PhotoFurniture] {
        state?.furniture(containing: photoId) ?? []
    }

    public func originalURL(photoId: String) -> URL? {
        state?.photo(id: photoId).map { url($0.originalFile) }
    }

    public func thumbnailURL(photoId: String) -> URL? {
        state?.photo(id: photoId).map { url($0.thumbnailFile) }
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
                                   decision: SourceDecision, roomId: String = AppState.primaryRoomId) throws -> PhotoFurniture {
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
                          decision: SourceDecision) throws -> PhotoFurniture {
        let current = try loadedState()
        guard let (shelf, index) = Self.locate(instanceId, in: current) else {
            throw StoreError.unknownInstance
        }
        guard let model = catalog.model(id: current[keyPath: shelf][index].modelId) else {
            throw StoreError.placement([.unknownModel])
        }
        if let existing = current.photos.first(where: { $0.isSamePhoto(as: draft) }),
           current[keyPath: shelf][index].sources.contains(where: { $0.photoId == existing.photoId }) {
            // Nothing to link, but intact bytes in hand still repair a damaged stored copy.
            if (try? checkDraft(draft)) != nil {
                do { try healBlobs(of: existing, from: draft) } catch {
                    log.error("addSource: heal failed \(Self.code(self.publicError(error, op: "heal")), privacy: .public)")
                }
            }
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
            next[keyPath: shelf][index].revision += 1
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
    public func updatePlacement(instanceId: String, placement: Placement, roomId: String? = nil) throws -> PhotoFurniture {
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
        var item = placed(current.items[index], at: placement, model: model, in: current)
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
        next[keyPath: shelf][index].revision += 1
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
            item.revision += 1
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
            next[keyPath: shelf][index].revision += 1
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
        item.revision += 1
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
    public func restoreFurniture(instanceId: String, placement: Placement, roomId: String = AppState.primaryRoomId) throws -> PhotoFurniture {
        let current = try loadedState()
        guard let index = current.storage.firstIndex(where: { $0.instanceId == instanceId }) else {
            throw StoreError.unknownInstance
        }
        let issues = GridRules.validate(placement, in: try Self.pieces(inRoom: roomId, of: current), catalog: catalog)
        guard issues.isEmpty, let model = catalog.model(id: placement.modelId) else {
            throw StoreError.placement(issues.isEmpty ? [.unknownModel] : issues)
        }
        var next = current
        var item = placed(next.storage.remove(at: index), at: placement, model: model, in: current)
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
    private func placed(_ item: PhotoFurniture, at placement: Placement, model: CatalogModel, in current: AppState) -> PhotoFurniture {
        var item = item
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
                ? source : .manual(photoId: source.photoId)
        }
        item.revision += 1
        item.updatedAt = Self.now()
        return item
    }

    // MARK: - Photos

    /// Stores a photo without any furniture. Identical bytes are stored once: a second import
    /// reuses the existing record, repairing its files and filling in a missing picker identifier.
    public func addPhoto(draft: ImportDraft) throws -> PhotoRecord {
        try importPhoto(draft: draft).photo
    }

    /// Whether these bytes created a new record is decided in the same actor turn as the write.
    public func importPhoto(draft: ImportDraft) throws -> (photo: PhotoRecord, inserted: Bool) {
        let current = try loadedState()
        try checkDraft(draft)
        if let index = current.photos.firstIndex(where: { $0.isSamePhoto(as: draft) }) {
            let existing = current.photos[index]
            do { try healBlobs(of: existing, from: draft) } catch {
                log.error("addPhoto: heal failed \(Self.code(self.publicError(error, op: "heal")), privacy: .public)")
            }
            var linked = existing
            linked.learnLibraryIdentifiers(from: draft)
            if linked != existing {
                var next = current
                next.photos[index] = linked
                do { try persist(next) } catch { throw publicError(error, op: "addPhoto") }
                return (linked, false)
            }
            return (existing, false)
        }
        var next = current
        var created: [URL] = []
        do {
            let photo = try ensurePhoto(draft: draft, in: &next, created: &created)
            try persist(next)
            log.info("addPhoto: photo=\(photo.photoId, privacy: .public) bytes=\(draft.byteSize, privacy: .public)")
            return (photo, true)
        } catch {
            rollback(created)
            let surfaced = publicError(error, op: "addPhoto")
            log.error("addPhoto failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
    }

    /// A skipped batch entry may undo only its own import. An edit, observation or a furniture
    /// link made since then takes precedence. Retrying after a completed discard is harmless.
    public func discardBatchPhoto(photoId: String, ifUnchangedSince revision: Int) throws {
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
        next[keyPath: shelf][index].revision += 1
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
        next[keyPath: shelf][index].revision += 1
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
        photo.revision += 1
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
        let current = try loadedState()
        let ids = Set(photoIds)
        let doomed = current.photos.filter { ids.contains($0.photoId) }
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
                next[keyPath: shelf][index].revision += 1
                next[keyPath: shelf][index].updatedAt = Self.now()
                updatedItems += 1
            }
        }
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: "deletePhoto")
            log.error("deletePhoto failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        // A state restored from the backup must never reference blobs we delete: make the
        // backup describe the post-deletion library first. If that fails, keep the files
        // (load-time orphan cleanup spares blobs the backup still references).
        do {
            try replaceBackupWithPrimary()
        } catch {
            log.error("deletePhoto: backup replace failed \(Self.code(self.ioError(error, op: "backup")), privacy: .public); keeping files")
            return
        }
        var paths = Set(doomed.map(\.thumbnailFile))
        let kept = Set(next.photos.map(\.originalFile))
        for photo in doomed where !kept.contains(photo.originalFile) { paths.insert(photo.originalFile) }
        var leftovers = 0
        for path in paths {
            do { try fm.removeItem(at: url(path)) } catch { leftovers += 1 }
        }
        log.info("deletePhoto: photos=\(doomed.count, privacy: .public) furnitureUpdated=\(updatedItems, privacy: .public) leftoverFiles=\(leftovers, privacy: .public)")
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

    /// Moves photos from one piece to another as one write: off `source`, onto `target`. A
    /// photo already on `target` just leaves `source`. A photo not on `source` is skipped.
    @discardableResult
    public func movePhotos(photoIds: [String], fromInstance source: String, toInstance target: String) throws -> BatchOutcome {
        guard source != target else { throw StoreError.duplicateSource }
        return try changeLinks(photoIds: photoIds, from: source, to: target, op: "movePhotos")
    }

    private func changeLinks(photoIds: [String], from source: String?, to target: String?, op: String) throws -> BatchOutcome {
        let current = try loadedState()
        var seen = Set<String>()
        let ids = photoIds.filter { seen.insert($0).inserted }
        let known = Set(current.photos.map(\.photoId))
        guard ids.allSatisfy(known.contains) else { throw StoreError.unknownPhoto }
        var next = current
        let now = Self.now()
        var eligible = ids
        var changed = 0
        if let source {
            guard let (shelf, index) = Self.locate(source, in: next) else { throw StoreError.unknownInstance }
            let held = Set(next[keyPath: shelf][index].sources.map(\.photoId))
            eligible = ids.filter(held.contains)
            if !eligible.isEmpty {
                let leaving = Set(eligible)
                next[keyPath: shelf][index].sources.removeAll { leaving.contains($0.photoId) }
                next[keyPath: shelf][index].revision += 1
                next[keyPath: shelf][index].updatedAt = now
                changed = eligible.count
            }
        }
        if let target {
            guard let (shelf, index) = Self.locate(target, in: next) else { throw StoreError.unknownInstance }
            let held = Set(next[keyPath: shelf][index].sources.map(\.photoId))
            let arriving = eligible.filter { !held.contains($0) }
            if !arriving.isEmpty {
                next[keyPath: shelf][index].sources += arriving.map { .manual(photoId: $0, addedAt: now) }
                next[keyPath: shelf][index].revision += 1
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
        return outcome
    }

    /// Sets or clears the favourite mark on several photos as one write. Returns how many changed.
    @discardableResult
    public func setFavorite(photoIds: [String], _ favorite: Bool) throws -> Int {
        let current = try loadedState()
        let ids = Set(photoIds)
        guard ids.isSubset(of: Set(current.photos.map(\.photoId))) else { throw StoreError.unknownPhoto }
        var next = current
        var changed = 0
        for index in next.photos.indices where ids.contains(next.photos[index].photoId) && next.photos[index].favorite != favorite {
            next.photos[index].favorite = favorite
            next.photos[index].revision += 1
            changed += 1
        }
        guard changed > 0 else { return 0 }
        do {
            try persist(next)
        } catch {
            let surfaced = publicError(error, op: "setFavorite")
            log.error("setFavorite failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("setFavorite: changed=\(changed, privacy: .public)")
        return changed
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
                item.revision += 1
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
    public func renameCat(catId: String, name: String) throws -> Cat {
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
        var paths = [Self.stateFile, Self.backupFile]
        for dir in [Self.originalsDir, Self.thumbnailsDir] {
            let names = (try? fm.contentsOfDirectory(atPath: url(dir).path)) ?? []
            paths.append(contentsOf: names.map { "\(dir)/\($0)" })
        }
        for path in paths {
            if let size = (try? fm.attributesOfItem(atPath: url(path).path))?[.size] as? NSNumber { bytes += size.intValue }
        }
        return StorageUsage(photoCount: current.photos.count, furnitureCount: current.items.count + current.storage.count, bytes: bytes)
    }

    /// Writes the whole library as one ZIP at `fileURL` (see `BackupArchive`). Every original
    /// is re-hashed first: a library with a missing or altered original is not exported.
    /// Runs on the store's executor, so no change can slip in half-way. Honors task
    /// cancellation; a failed or cancelled export leaves no file behind and changes nothing.
    public func exportBackup(to fileURL: URL, appVersion: String,
                             progress: @Sendable (BackupProgress) -> Void = { _ in }) throws -> BackupSummary {
        let current = try loadedState()
        do {
            let summary = try BackupArchive.write(state: current, root: root, to: fileURL, appVersion: appVersion, progress: progress)
            log.info("export: photos=\(summary.photoCount, privacy: .public) bytes=\(summary.byteSize, privacy: .public)")
            return summary
        } catch {
            try? fm.removeItem(at: fileURL)
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

    /// Replaces the whole library with a staged, fully verified one. All-or-nothing: on any
    /// failure the current library (files, memory, backup state) is exactly as before and
    /// the staged copy is removed. The caller must have asked the user first.
    @discardableResult
    public func replaceLibrary(with prepared: PreparedLibrary) throws -> AppState {
        let staging = prepared.stagingURL
        // A first load cleans up abandoned staging folders; this one is not abandoned.
        keptStaging = staging
        defer { keptStaging = nil }
        _ = try loadedState()
        guard staging.deletingLastPathComponent().standardizedFileURL == root.deletingLastPathComponent().standardizedFileURL,
              staging.lastPathComponent.hasPrefix(Self.stagingPrefix(for: root)),
              fm.fileExists(atPath: staging.appendingPathComponent(Self.stateFile).path)
        else { throw BackupError.stale }
        do {
            try swapIn(staging: staging, state: prepared.state)
        } catch {
            let surfaced = publicError(error, op: "replace")
            log.error("replace failed: \(Self.code(surfaced), privacy: .public)")
            throw surfaced
        }
        log.info("replace: photos=\(prepared.state.photos.count, privacy: .public) items=\(prepared.state.items.count, privacy: .public)")
        return prepared.state
    }

    /// Deletes every photo, piece of furniture (stored ones too) and the cat's name. All-or-nothing like a
    /// restore: an empty library is staged beside this one and switched in.
    @discardableResult
    public func clearAll() throws -> AppState {
        _ = try loadedState()
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
        log.info("clearAll: done")
        return empty
    }

    /// The commit point of restore / import / clear: the staged folder and the live folder
    /// trade places atomically, then the old one (now at the staging path) is deleted.
    private func swapIn(staging: URL, state next: AppState) throws {
        do {
            try fire(.swapLibrary)
            Self.fsyncDirectory(staging)
            try Self.exchange(staging, root)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        Self.fsyncDirectory(root.deletingLastPathComponent())
        state = next
        primaryIsGood = true
        recoveredFromBackup = false
        // The previous library now sits at the staging path. If this fails it is removed by
        // the next load.
        try? fm.removeItem(at: staging)
    }

    static func stagingPrefix(for root: URL) -> String { root.lastPathComponent + ".incoming-" }
    static func previousPrefix(for root: URL) -> String { root.lastPathComponent + ".previous-" }

    /// Swaps two directories on one volume. APFS does it in one atomic step; elsewhere the
    /// live folder is parked under a `.previous-` name first and moved back if step two fails.
    static func exchange(_ staging: URL, _ live: URL) throws {
        if renamex_np(staging.path, live.path, UInt32(RENAME_SWAP)) == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        let parked = live.deletingLastPathComponent()
            .appendingPathComponent(previousPrefix(for: live) + UUID().uuidString, isDirectory: true)
        try rename(live, to: parked)
        do {
            try rename(staging, to: live)
        } catch {
            try? rename(parked, to: live)
            throw error
        }
        try rename(parked, to: staging)
    }

    /// Only reachable after a crash between the two renames of the non-atomic fallback: the
    /// live folder is gone and its parked copy is still there. Put it back.
    private func recoverInterruptedSwap() {
        guard !fm.fileExists(atPath: root.path) else { return }
        let parent = root.deletingLastPathComponent()
        let prefix = Self.previousPrefix(for: root)
        let parked = ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).filter { $0.hasPrefix(prefix) }.sorted()
        guard let name = parked.last else { return }
        if (try? Self.rename(parent.appendingPathComponent(name), to: root)) != nil {
            log.error("load: restored the library parked by an interrupted replace")
        }
    }

    /// Staged or parked folders nobody will switch in any more (cancelled preview, crash).
    private func removeStaleStagingDirectories() {
        let parent = root.deletingLastPathComponent()
        let prefixes = [Self.stagingPrefix(for: root), Self.previousPrefix(for: root)]
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        where prefixes.contains(where: { name.hasPrefix($0) }) && name != keptStaging?.lastPathComponent {
            try? fm.removeItem(at: parent.appendingPathComponent(name))
        }
    }

    // MARK: - Internals

    private func loadedState() throws -> AppState {
        if let state { return state }
        return try load()
    }

    /// Where an instance lives: in the room (`items`) or put away (`storage`).
    private static func locate(_ instanceId: String, in state: AppState) -> (shelf: WritableKeyPath<AppState, [PhotoFurniture]>, index: Int)? {
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
        var next = candidate
        next.revision += 1
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

    /// Makes `state.backup.json` a durable copy of the (already durable) primary.
    private func replaceBackupWithPrimary() throws {
        let tempBackupURL = url(Self.tempBackupFile)
        do {
            try? fm.removeItem(at: tempBackupURL)
            try fm.copyItem(at: url(Self.stateFile), to: tempBackupURL)
            try Self.fullFsync(tempBackupURL)
            try Self.rename(tempBackupURL, to: url(Self.backupFile))
            Self.fsyncDirectory(root)
        } catch {
            try? fm.removeItem(at: tempBackupURL)
            throw error
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

    /// Rewrites a record's original (missing or hash mismatch) and thumbnail (missing) from a
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
            healed.original = true
            log.notice("ingest: healed original photo=\(photo.photoId, privacy: .public)")
        }
        let thumbURL = url(photo.thumbnailFile)
        if !fm.fileExists(atPath: thumbURL.path), !draft.thumbnailJPEG.isEmpty {
            try writeDurably(draft.thumbnailJPEG, to: thumbURL)
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
    }

    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }

    /// Loading never depends on the catalog: only structural consistency is checked.
    private func decode(_ fileURL: URL) -> Decoded {
        guard let data = try? Data(contentsOf: fileURL) else { return .invalid }
        return Self.decodeState(data)
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
        guard state.photo(id: source.photoId) != nil else { return false }
        guard let observationId = source.observationId else {
            return source.objectIndex == nil && source.origin == .user
        }
        guard let observation = state.observation(id: observationId),
              observation.photoId == source.photoId,
              observation.origin == source.origin,
              let index = source.objectIndex,
              observation.objects.indices.contains(index)
        else { return false }
        return true
    }

    /// Structural consistency checked on load; a state failing this is treated as corrupt.
    /// Deliberately independent of the catalog and of the item limit (which applies to adding).
    static func isConsistent(_ state: AppState) -> Bool {
        guard state.revision >= 0,
              Set(state.photos.map(\.photoId)).count == state.photos.count,
              Set(state.photos.map(\.sha256)).count == state.photos.count,
              Set(state.observations.map(\.observationId)).count == state.observations.count,
              // One instance is in the room or put away, never both.
              Set((state.items + state.storage).map(\.instanceId)).count == state.items.count + state.storage.count
        else { return false }
        let photoIds = Set(state.photos.map(\.photoId))
        for photo in state.photos {
            for path in [photo.originalFile, photo.thumbnailFile] {
                guard !path.hasPrefix("/"), !path.contains(".."),
                      path.hasPrefix("\(originalsDir)/") || path.hasPrefix("\(thumbnailsDir)/")
                else { return false }
            }
        }
        guard state.observations.allSatisfy({ photoIds.contains($0.photoId) }) else { return false }
        // Rooms and cats: unique ids, the first of each is the one that always exists, and
        // nothing points at a room that is not there.
        let rooms = state.allRooms, cats = state.allCats
        guard rooms.count <= AppState.maxRooms, cats.count <= AppState.maxCats else { return false }
        let roomIds = Set(rooms.map(\.roomId))
        guard roomIds.count == rooms.count, rooms[0].roomId == AppState.primaryRoomId,
              state.items.allSatisfy({ roomIds.contains(AppState.roomId(of: $0)) }),
              Set(cats.map(\.catId)).count == cats.count,
              cats[0].catId == AppState.primaryCatId, cats[0].name == state.catName,
              cats.allSatisfy({ $0.roomId.map(roomIds.contains) ?? true })
        else { return false }
        // No sources is fine (a piece placed from the catalog, or one whose photos were deleted).
        for item in state.items + state.storage {
            guard Set(item.sources.map(\.photoId)).count == item.sources.count,
                  item.sources.allSatisfy({ sourceIsStructurallyValid($0, in: state) })
            else { return false }
        }
        return true
    }
}

private struct InjectedFaultPassthrough: Error {
    let error: Error
    init(_ error: Error) { self.error = error }
}
