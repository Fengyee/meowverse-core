import Foundation

/// Why a backup could not be written, read or switched in. Codes only; never a path, a
/// filename or file content. Whenever one of these is thrown the current library is untouched.
public enum BackupError: Error, Equatable, Sendable {
    /// Not a ZIP, or a ZIP that is not a Meowverse backup.
    case notABackup
    /// A Meowverse backup that is truncated, altered or inconsistent; the code names the check.
    case damaged(String)
    /// Over the size or entry-count limits.
    case tooLarge
    /// Written by a newer app (newer backup format or newer state schema).
    case newerVersion
    /// A web backup older than version 6: open it in the web app once and export again.
    case unsupportedVersion
    /// Web import: this many originals are intact but cannot be decoded on this device.
    case unreadablePhotos(Int)
    /// Export: this many originals are missing or no longer match their SHA-256.
    case libraryDamaged(Int)
    /// The staged library is gone (the app was restarted, or it was already used).
    case stale

    var code: String {
        switch self {
        case .notABackup: "notABackup"
        case .damaged(let code): "damaged:\(code)"
        case .tooLarge: "tooLarge"
        case .newerVersion: "newerVersion"
        case .unsupportedVersion: "unsupportedVersion"
        case .unreadablePhotos(let count): "unreadablePhotos:\(count)"
        case .libraryDamaged(let count): "libraryDamaged:\(count)"
        case .stale: "stale"
        }
    }
}

public struct BackupProgress: Sendable, Equatable {
    public var completedBytes: Int
    public var totalBytes: Int

    public var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
}

public struct StorageUsage: Sendable, Equatable {
    public var photoCount: Int
    public var furnitureCount: Int
    public var bytes: Int
}

public struct BackupSummary: Sendable, Equatable {
    public var photoCount: Int
    /// Every piece, in the room or put away (here and in `StorageUsage` / `BackupPreview`).
    public var furnitureCount: Int
    /// Size of the ZIP file.
    public var byteSize: Int
}

/// Something a web backup holds that the iOS app cannot show, or a change made while
/// carrying it over. Shown to the user before they confirm; nothing here is silent.
public enum BackupNote: Sendable, Equatable {
    /// Classic-mode (slot) furniture.
    case classicFurniture(Int)
    /// Imported GLB furniture models.
    case customModels(Int)
    /// An imported GLB cat.
    case customCat
    /// Analysis runs / consent records / observations no furniture refers to.
    case analysisRecords(runs: Int, consents: Int, observations: Int)
    /// Per-photo category corrections and custom tags.
    case photoAnnotations(Int)
    /// "Reviewed" marks and per-photo template exclusions.
    case reviewMarks(Int)
    /// A room theme other than the default.
    case roomTheme
    /// Furniture whose model this app version does not have; the names as the user wrote them.
    case unknownModels([String])
    /// Source links whose recognition record could not be matched; kept as manual links.
    case sourcesMadeManual(Int)
    /// Photos whose "from the photo's own data" date differs from what this device reads in the file.
    case datesFromFile(Int)
    /// The cat's name was longer than the app allows and was shortened.
    case catNameShortened
    /// Thumbnails are rebuilt from the originals (always, for a web backup).
    case thumbnailsRebuilt(Int)
}

/// What a backup contains, shown before anything is replaced.
public struct BackupPreview: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case iosBackup, webBackup
    }

    public var kind: Kind
    public var createdAt: Date
    /// The iOS app version that wrote it; nil for a web backup.
    public var appVersion: String?
    /// iOS backup: container format version. Web backup: manifest version (6).
    public var formatVersion: Int
    /// The state schema inside the backup.
    public var schemaVersion: Int
    public var photoCount: Int
    public var furnitureCount: Int
    public var originalBytes: Int
    public var catName: String
    public var notes: [BackupNote]
}

/// A library that was fully verified and written beside the live one, waiting for the user
/// to confirm. `LibraryStore.replaceLibrary(with:)` switches it in; `discard()` throws it away.
public struct PreparedLibrary: Sendable, Equatable {
    public let preview: BackupPreview
    let stagingURL: URL
    let state: AppState

    public func discard() {
        try? FileManager.default.removeItem(at: stagingURL)
    }
}

/// The iOS backup: one plain ZIP (stored entries) that Files can open.
///
/// ```
/// manifest.json                 format "meowverse-ios-backup", formatVersion 1
/// state.json                    the library state, exactly as the app stores it
/// originals/<sha256>.<ext>      every original, byte for byte
/// thumbnails/<name>.jpg         thumbnails (rebuilt on restore if one is missing)
/// ```
public enum BackupArchive {
    public static let format = "meowverse-ios-backup"
    public static let formatVersion = 1
    public static let manifestPath = "manifest.json"
    public static let statePath = "state.json"
    static let maxJSONBytes = 8 * 1024 * 1024

    struct FileEntry: Codable, Equatable {
        let path: String
        let byteSize: Int
        let sha256: String
    }

    struct Manifest: Codable {
        let format: String
        let formatVersion: Int
        let createdAt: Date
        let appVersion: String
        let schemaVersion: Int
        let photoCount: Int
        let furnitureCount: Int
        let state: FileEntry
        let files: [FileEntry]
    }

    private struct FormatProbe: Decodable { let format: String }

    /// `word` is the word for "backup" in the file name; the app passes it in its interface language.
    public static func defaultFilename(now: Date = Date(), word: String = "备份") -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Meowverse-\(word)-\(formatter.string(from: now)).zip"
    }

    // MARK: - Writing

    static func write(state: AppState, root: URL, to fileURL: URL, appVersion: String,
                      progress: @Sendable (BackupProgress) -> Void) throws -> BackupSummary {
        let fm = FileManager.default
        guard LibraryStore.isConsistent(state) else { throw BackupError.damaged("state") }
        try validateValuesAndPaths(state)
        let stateData = try LibraryStore.encodeState(state)
        guard stateData.count <= maxJSONBytes else { throw BackupError.tooLarge }
        let total = state.photos.reduce(0) { $0 + $1.byteSize }
        var done = 0
        progress(BackupProgress(completedBytes: 0, totalBytes: total))

        // Refuse before writing anything if an original is missing or altered.
        var damaged = 0
        for photo in state.photos {
            try Task.checkCancellation()
            if LibraryStore.hashFile(root.appendingPathComponent(photo.originalFile)) != photo.sha256 { damaged += 1 }
        }
        guard damaged == 0 else { throw BackupError.libraryDamaged(damaged) }

        do {
            let writer = try ZipWriter(url: fileURL, limits: .backup)
            try writer.add(path: statePath, data: stateData)
            var files: [FileEntry] = []
            var written = Set<String>()
            for photo in state.photos {
                try Task.checkCancellation()
                if written.insert(photo.originalFile).inserted {
                    let data = try Data(contentsOf: root.appendingPathComponent(photo.originalFile))
                    // Hash what is actually being written, not what was read a moment ago.
                    guard data.count == photo.byteSize, PhotoIngest.sha256Hex(data) == photo.sha256 else {
                        throw BackupError.libraryDamaged(1)
                    }
                    try writer.add(path: photo.originalFile, data: data)
                    files.append(FileEntry(path: photo.originalFile, byteSize: data.count, sha256: photo.sha256))
                }
                let thumbURL = root.appendingPathComponent(photo.thumbnailFile)
                if written.insert(photo.thumbnailFile).inserted, fm.fileExists(atPath: thumbURL.path),
                   let thumb = try? Data(contentsOf: thumbURL), !thumb.isEmpty {
                    try writer.add(path: photo.thumbnailFile, data: thumb)
                    files.append(FileEntry(path: photo.thumbnailFile, byteSize: thumb.count, sha256: PhotoIngest.sha256Hex(thumb)))
                }
                done += photo.byteSize
                progress(BackupProgress(completedBytes: done, totalBytes: total))
            }
            let manifest = Manifest(
                format: format, formatVersion: formatVersion, createdAt: LibraryStore.now(), appVersion: appVersion,
                schemaVersion: state.schemaVersion, photoCount: state.photos.count,
                furnitureCount: state.items.count + state.storage.count,
                state: FileEntry(path: statePath, byteSize: stateData.count, sha256: PhotoIngest.sha256Hex(stateData)),
                files: files)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let manifestData = try encoder.encode(manifest)
            guard manifestData.count <= maxJSONBytes else { throw BackupError.tooLarge }
            try writer.add(path: manifestPath, data: manifestData)
            let size = try writer.finish()
            return BackupSummary(photoCount: state.photos.count, furnitureCount: state.items.count + state.storage.count, byteSize: size)
        } catch let error as ZipError {
            throw error == .tooLarge ? BackupError.tooLarge : BackupError.damaged("zipWrite")
        }
    }

    // MARK: - Reading

    /// Reads a backup file (iOS backup or web backup v6), verifies all of it and builds the
    /// resulting library at `stagingURL` (from `LibraryStore.makeStagingURL()`). The live
    /// library is not touched. Synchronous and heavy: call off the main actor, inside a task;
    /// cancelling the task stops it. On any failure nothing is left at `stagingURL`.
    public static func prepare(file: URL, stagingURL: URL, catalog: FurnitureCatalog,
                               progress: @Sendable (BackupProgress) -> Void = { _ in }) throws -> PreparedLibrary {
        do {
            let reader = try ZipReader(fileURL: file, limits: .backup)
            try Task.checkCancellation()
            let manifestData = try json(reader, manifestPath)
            guard let probe = try? JSONDecoder().decode(FormatProbe.self, from: manifestData) else { throw BackupError.notABackup }
            let staged = Staging(url: stagingURL)
            do {
                let prepared: PreparedLibrary
                switch probe.format {
                case format:
                    prepared = try prepareIOS(reader, manifestData: manifestData, staging: staged, progress: progress)
                case WebBackup.format:
                    prepared = try WebBackup.prepare(reader, manifestData: manifestData, staging: staged, catalog: catalog, progress: progress)
                default:
                    throw BackupError.notABackup
                }
                return prepared
            } catch {
                staged.remove()
                throw error
            }
        } catch let error as ZipError {
            throw backupError(error)
        }
    }

    static func backupError(_ error: ZipError) -> BackupError {
        switch error {
        case .notZip: .notABackup
        case .tooLarge: .tooLarge
        case .unsupported: .damaged("zipUnsupported")
        case .corrupt(let code): .damaged("zip:\(code)")
        case .unsafePath: .damaged("zipPath")
        case .duplicateEntry: .damaged("zipDuplicate")
        case .checksum: .damaged("zipChecksum")
        }
    }

    /// A JSON entry: must exist and stay under 8 MiB.
    static func json(_ reader: ZipReader, _ path: String) throws -> Data {
        guard let entry = reader.entry(path) else { throw BackupError.notABackup }
        guard entry.uncompressedSize <= maxJSONBytes else { throw BackupError.tooLarge }
        return try reader.extract(entry)
    }

    static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    private static func prepareIOS(_ reader: ZipReader, manifestData: Data, staging: Staging,
                                   progress: @Sendable (BackupProgress) -> Void) throws -> PreparedLibrary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        struct VersionProbe: Decodable { let formatVersion: Int; let schemaVersion: Int }
        guard let versions = try? decoder.decode(VersionProbe.self, from: manifestData) else { throw BackupError.damaged("manifest") }
        guard versions.formatVersion <= formatVersion, versions.schemaVersion <= AppState.currentSchemaVersion else {
            throw BackupError.newerVersion
        }
        guard versions.formatVersion >= 1, let manifest = try? decoder.decode(Manifest.self, from: manifestData),
              manifest.state.path == statePath, isHash(manifest.state.sha256)
        else { throw BackupError.damaged("manifest") }

        // The archive holds exactly what the manifest lists: nothing missing, nothing extra.
        let listed = [manifestPath, statePath] + manifest.files.map(\.path)
        guard Set(listed).count == listed.count, listed.count == reader.entries.count,
              listed.allSatisfy({ reader.entry($0) != nil }) else { throw BackupError.damaged("entries") }
        let described = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })

        let stateData = try json(reader, statePath)
        guard stateData.count == manifest.state.byteSize, PhotoIngest.sha256Hex(stateData) == manifest.state.sha256 else {
            throw BackupError.damaged("stateHash")
        }
        let state: AppState
        switch LibraryStore.decodeState(stateData) {
        case .newer: throw BackupError.newerVersion
        case .invalid, .unreadable: throw BackupError.damaged("state")
        case .valid(var decoded):
            // A hand-edited name must still be one the app could have stored.
            decoded.catName = AppState.normalizedCatName(decoded.catName) ?? AppState.defaultCatName
            if !decoded.cats.isEmpty { decoded.cats[0].name = decoded.catName }
            state = decoded
        }
        let referenced = try validateValuesAndPaths(state)
        guard state.photos.allSatisfy({ described[$0.originalFile] != nil }) else { throw BackupError.damaged("photoPaths") }
        guard described.keys.allSatisfy(referenced.contains) else { throw BackupError.damaged("extraFiles") }
        // The manifest says the same as the state (audit R02-002, A24-08): each original's line
        // has the state's size and hash, and the counts are the state's. A backup that contradicts
        // itself is not trusted, even where the bytes would pass on their own.
        guard state.photos.allSatisfy({ described[$0.originalFile]?.byteSize == $0.byteSize && described[$0.originalFile]?.sha256 == $0.sha256 })
        else { throw BackupError.damaged("manifestFiles") }
        guard manifest.photoCount == state.photos.count, manifest.furnitureCount == state.items.count + state.storage.count else {
            throw BackupError.damaged("manifestCounts")
        }

        try staging.create()
        let total = state.photos.reduce(0) { $0 + $1.byteSize }
        var done = 0, rebuilt = 0
        progress(BackupProgress(completedBytes: 0, totalBytes: total))
        for photo in state.photos {
            try Task.checkCancellation()
            guard let entry = reader.entry(photo.originalFile), entry.uncompressedSize == photo.byteSize else {
                throw BackupError.damaged("originalSize")
            }
            let original = try reader.extract(entry)
            guard original.count == photo.byteSize, PhotoIngest.sha256Hex(original) == photo.sha256 else {
                throw BackupError.damaged("originalHash")
            }
            try staging.write(original, to: photo.originalFile)

            var thumbnail: Data?
            // A thumbnail is used only when it is what the manifest says, size and hash; else it
            // is rebuilt from the original (and the preview says so).
            if let listed = described[photo.thumbnailFile], let entry = reader.entry(photo.thumbnailFile),
               entry.uncompressedSize == listed.byteSize,
               let data = try? reader.extract(entry), data.count == listed.byteSize, PhotoIngest.sha256Hex(data) == listed.sha256,
               PhotoIngest.downsampledImage(data: data, maxPixel: 16) != nil {
                thumbnail = data
            } else if let draft = try? PhotoIngest.makeDraft(data: original, filename: nil, reduce: false) {
                thumbnail = draft.thumbnailJPEG
                rebuilt += 1
            }
            // An undecodable original still restores byte for byte; only its thumbnail is absent.
            if let thumbnail { try staging.write(thumbnail, to: photo.thumbnailFile) }
            done += photo.byteSize
            progress(BackupProgress(completedBytes: done, totalBytes: total))
        }
        try staging.write(try LibraryStore.encodeState(state), to: statePath, fullSync: true)
        staging.sync()

        let preview = BackupPreview(
            kind: .iosBackup, createdAt: manifest.createdAt, appVersion: String(manifest.appVersion.prefix(40)),
            formatVersion: manifest.formatVersion, schemaVersion: manifest.schemaVersion,
            photoCount: state.photos.count, furnitureCount: state.items.count + state.storage.count, originalBytes: total,
            catName: state.catName, notes: rebuilt > 0 ? [.thumbnailsRebuilt(rebuilt)] : [])
        return PreparedLibrary(preview: preview, stagingURL: staging.url, state: state)
    }

    @discardableResult
    private static func validateValuesAndPaths(_ state: AppState) throws -> Set<String> {
        guard state.photos.count <= ZipLimits.backup.maxEntries - 2 else { throw BackupError.tooLarge }
        guard (state.items + state.storage).allSatisfy(isPlausible), state.photos.allSatisfy({ $0.note.utf16.count <= LibraryStore.maxNoteLength }) else {
            throw BackupError.damaged("stateValues")
        }

        // Every stored path must be one the app itself would have written.
        var referenced = Set<String>()
        for photo in state.photos {
            guard isHash(photo.sha256), photo.byteSize > 0, photo.byteSize <= PhotoIngest.maxBytes,
                  isOriginalPath(photo.originalFile, sha256: photo.sha256), isThumbnailPath(photo.thumbnailFile),
                  referenced.insert(photo.originalFile).inserted, referenced.insert(photo.thumbnailFile).inserted
            else { throw BackupError.damaged("photoPaths") }
        }
        return referenced
    }

    /// Not the grid rules (rooms are never re-validated on load), only values a renderer can
    /// take: a quarter turn, a footprint and a position of sane size, bounded text.
    static func isPlausible(_ item: PhotoFurniture) -> Bool {
        (0...3).contains(item.turn) && (1...32).contains(item.width) && (1...32).contains(item.depth)
            && (-64...64).contains(item.x) && (-64...64).contains(item.z)
            && !item.instanceId.isEmpty && item.instanceId.utf8.count <= 200 && item.modelId.utf8.count <= 200
            && item.tags.count <= 50 && item.tags.allSatisfy { $0.count <= 200 }
            && LibraryStore.validRevision(item.revision)
    }

    /// `originals/<sha256>.<ext>` with a short lowercase extension.
    static func isOriginalPath(_ path: String, sha256: String) -> Bool {
        let prefix = "\(LibraryStore.originalsDir)/\(sha256)."
        guard path.hasPrefix(prefix) else { return false }
        let ext = path.dropFirst(prefix.count).utf8
        return (1...8).contains(ext.count) && ext.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) }
    }

    /// `thumbnails/<name>.jpg`, one path component, safe characters only.
    static func isThumbnailPath(_ path: String) -> Bool {
        let prefix = "\(LibraryStore.thumbnailsDir)/"
        guard path.hasPrefix(prefix), path.hasSuffix(".jpg"), ZipReader.isSafePath(path) else { return false }
        return !path.dropFirst(prefix.count).contains("/")
    }
}

/// The folder a library is assembled in before it replaces the live one.
struct Staging {
    let url: URL

    func create() throws {
        let fm = FileManager.default
        for dir in [url, url.appendingPathComponent(LibraryStore.originalsDir), url.appendingPathComponent(LibraryStore.thumbnailsDir)] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: LibraryStore.protectionAttributes)
        }
    }

    func write(_ data: Data, to relative: String, fullSync: Bool = false) throws {
        try LibraryStore.writeDurably(data, to: url.appendingPathComponent(relative, isDirectory: false), fullSync: fullSync)
    }

    func sync() {
        for dir in [LibraryStore.originalsDir, LibraryStore.thumbnailsDir] { LibraryStore.fsyncDirectory(url.appendingPathComponent(dir)) }
        LibraryStore.fsyncDirectory(url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
