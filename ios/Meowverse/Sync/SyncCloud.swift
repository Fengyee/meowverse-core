import Foundation
import MeowverseCore

/// A cloud the app can sync with: CloudKit (`CloudKitSyncTransport`), or in Debug and drill
/// builds a plain shared folder (`FolderSyncCloud`, `-MeowverseSyncFolder <name>`).
nonisolated protocol SyncCloud: SyncTransport {
    /// Starts listening for changes made elsewhere (CloudKit: creates the sync engine, which
    /// subscribes to pushes). Nothing is sent before a sync cycle asks for it.
    func start() async
    /// Called when another device changed something: the app runs a cycle to take it.
    func setRemoteChangeHandler(_ handler: @escaping @Sendable () -> Void) async
    /// Forgets everything fetched and every token (the user chose to start over in another
    /// account or after the iCloud data was deleted, or turned sync off). Nothing in the cloud
    /// or in the library is deleted.
    func reset() async
    /// Records changed elsewhere that reached this device but could not be read yet (CloudKit: a
    /// payload asset that did not download). They are fetched again; the settings page says so.
    func recordsNotFetched() async -> Int
}

extension SyncCloud {
    nonisolated func recordsNotFetched() async -> Int { 0 }
}

/// A photo record reaches the cloud only after a file it points at is there: a device that
/// takes the record must always find a copy to download (another device falls back to the next
/// best copy, so one is enough). Both transports check this in `save`, whatever order sync
/// sends in.
nonisolated enum SyncFileGate {
    /// The file hashes a photo record needs one of, best first; nil for any other record, and
    /// for a deleted photo, which is never downloaded (one brought back after deletion is live).
    static func neededFiles(_ envelope: SyncEnvelope) -> [String]? {
        guard let record = envelope.decoded(), record.isLive, case .photo(let photo) = record else { return nil }
        return photo.copiesBestFirst.map(\.sha256)
    }
}

/// Small file helpers shared by the transports.
nonisolated enum SyncFiles {
    /// Written through a temporary file, flushed, then renamed: after a crash the file is
    /// either the old one or the new one, never half.
    static func writeDurably(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temp) }
        guard fm.createFile(atPath: temp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: temp)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: url)
        }
    }

    static var applicationSupport: URL {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
    }
}
