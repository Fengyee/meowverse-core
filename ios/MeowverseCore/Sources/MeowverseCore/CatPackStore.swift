import Foundation

public struct CatPackLimits: Sendable, Equatable {
    public var maxFileBytes: Int
    public var maxTotalBytes: Int
    public var maxEntries: Int

    public init(maxFileBytes: Int, maxTotalBytes: Int, maxEntries: Int) {
        self.maxFileBytes = maxFileBytes
        self.maxTotalBytes = maxTotalBytes
        self.maxEntries = maxEntries
    }

    /// A high-resolution USDZ is the largest file; three meshes and the rig are a few MB each.
    public static let standard = CatPackLimits(maxFileBytes: 40 * 1_048_576, maxTotalBytes: 120 * 1_048_576, maxEntries: 32)
}

/// A pack on disk under the store root.
public struct InstalledCatPack: Sendable, Equatable {
    public let manifest: CatPackManifest
    public let directory: URL
    public let revision: String
}

/// A validated pack written to a hidden staging folder; invisible until `commit`.
public struct StagedCatPack: Sendable, Equatable {
    public let manifest: CatPackManifest
    /// A pack with this id is already installed and would be replaced.
    public let replacesExisting: Bool
    let stagingURL: URL
}

/// Imported cat packs: `<root>/<id>/<file>`. A `.meowcat` file is an untrusted ZIP; it is read
/// with the strict `ZipReader`, every file is validated before anything is written, and the
/// folder appears in one rename.
public final class CatPackStore: Sendable {
    public let root: URL
    public let reservedIDs: Set<String>
    public let limits: CatPackLimits

    public init(root: URL, reservedIDs: Set<String>, limits: CatPackLimits = .standard) {
        self.root = root
        self.reservedIDs = reservedIDs
        self.limits = limits
    }

    private var fm: FileManager { .default }

    public func directory(for id: String) -> URL {
        root.appending(path: id, directoryHint: .isDirectory)
    }

    /// Valid packs only, sorted by name. A folder whose manifest is unreadable or names another id is skipped.
    public func installed() -> [InstalledCatPack] {
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter(CatPackManifest.isValidID).compactMap { id -> InstalledCatPack? in
            let folder = directory(for: id)
            guard let data = try? Data(contentsOf: folder.appending(path: "cat.json")),
                  let manifest = try? CatPackManifest.decode(data), manifest.id == id,
                  !reservedIDs.contains(id) else { return nil }
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate)?.timeIntervalSince1970 ?? 0
            let inode = (try? fm.attributesOfItem(atPath: folder.path)[.systemFileNumber] as? NSNumber)?.stringValue ?? ""
            return InstalledCatPack(manifest: manifest, directory: folder, revision: "\(created)-\(inode)")
        }
        .sorted { ($0.manifest.name, $0.manifest.id) < ($1.manifest.name, $1.manifest.id) }
    }

    // MARK: Import

    /// Reads and validates the archive, then writes it to a staging folder. Throws `CatPackError`.
    public func stage(archiveAt url: URL) throws -> StagedCatPack {
        let zipLimits = ZipLimits(maxArchiveBytes: limits.maxTotalBytes + 1_048_576, maxEntries: limits.maxEntries,
                                  maxEntryBytes: limits.maxFileBytes, maxTotalBytes: limits.maxTotalBytes)
        let reader: ZipReader
        do {
            reader = try ZipReader(fileURL: url, limits: zipLimits)
        } catch let error as ZipError {
            switch error {
            case .tooLarge: throw CatPackError.tooLarge
            case .unsafePath, .duplicateEntry: throw CatPackError.unsafeName
            default: throw CatPackError.notArchive
            }
        }
        guard !reader.entries.contains(where: { $0.path.contains("/") }) else { throw CatPackError.nestedFolder }
        func read(_ name: String) throws -> Data? {
            guard let entry = reader.entry(name) else { return nil }
            do { return try reader.extract(entry) } catch { throw CatPackError.notArchive }
        }
        guard let manifestData = try read("cat.json") else { throw CatPackError.missingManifest }
        let manifest = try CatPackManifest.decode(manifestData)
        guard !reservedIDs.contains(manifest.id) else { throw CatPackError.reservedID }

        // Pass one: everything decodes. Nothing is written yet.
        try CatPackValidator.validate(manifest: manifest, file: read)

        // Pass two: write the files the manifest names, and only those.
        let staging = root.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try manifestData.write(to: staging.appending(path: "cat.json"))
            for name in manifest.requiredFiles + manifest.optionalFiles {
                guard let data = try read(name) else { throw CatPackError.missingFile(name) }
                try data.write(to: staging.appending(path: name))
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error as? CatPackError ?? .writeFailed
        }
        return StagedCatPack(manifest: manifest, replacesExisting: fm.fileExists(atPath: directory(for: manifest.id).path),
                             stagingURL: staging)
    }

    /// Moves the staged folder into place, replacing a pack with the same id. On failure the
    /// previous pack (if any) is still there.
    public func commit(_ staged: StagedCatPack) throws {
        let destination = directory(for: staged.manifest.id)
        guard staged.stagingURL.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              fm.fileExists(atPath: staged.stagingURL.path) else { throw CatPackError.notFound }
        do {
            if fm.fileExists(atPath: destination.path) {
                let old = root.appending(path: ".old-\(UUID().uuidString)", directoryHint: .isDirectory)
                try fm.moveItem(at: destination, to: old)
                do {
                    try fm.moveItem(at: staged.stagingURL, to: destination)
                } catch {
                    try? fm.moveItem(at: old, to: destination)
                    throw error
                }
                try? fm.removeItem(at: old)
            } else {
                try fm.moveItem(at: staged.stagingURL, to: destination)
            }
        } catch {
            try? fm.removeItem(at: staged.stagingURL)
            throw CatPackError.writeFailed
        }
    }

    public func discard(_ staged: StagedCatPack) {
        guard staged.stagingURL.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return }
        try? fm.removeItem(at: staged.stagingURL)
    }

    public func delete(id: String) throws {
        guard CatPackManifest.isValidID(id) else { throw CatPackError.invalidID }
        let folder = directory(for: id)
        guard fm.fileExists(atPath: folder.path) else { throw CatPackError.notFound }
        do { try fm.removeItem(at: folder) } catch { throw CatPackError.writeFailed }
    }

    /// Staging and replaced folders left by an interrupted import.
    public func removeLeftovers() {
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(".staging-") || name.hasPrefix(".old-") {
            try? fm.removeItem(at: root.appending(path: name))
        }
    }
}
