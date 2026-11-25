import Foundation
import MeowverseCore
import Network
import os

/// The app's own folder in the user's iCloud Drive (Files › iCloud Drive › Meowverse).
/// Every call may block and must be made off the main actor. Used only when
/// `FeatureFlags.iCloudBackup` is on; UI tests use `FolderBackupDestination` instead.
///
/// None of this can run on the simulator without an iCloud account: it is exercised only on
/// a device with the entitlement.
nonisolated struct UbiquityBackupDestination: BackupDestination {
    static let containerID = "iCloud.io.github.fengyee.meowverse"

    private static let listKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey,
    ]

    init() {
        assert(FeatureFlags.iCloudBackup, "iCloud backup is switched off: nothing may reach the ubiquity container")
    }

    func availability() -> CloudAvailability {
        // The switch is checked here too, so even a stray call never asks iCloud anything.
        guard FeatureFlags.iCloudBackup else { return .containerUnavailable }
        guard FileManager.default.ubiquityIdentityToken != nil else { return .signedOut }
        return documents() == nil ? .containerUnavailable : .available
    }

    /// The identity token says which Apple Account iCloud Drive belongs to; only its
    /// fingerprint is kept (`CloudBackupAccount`). Fast, and does not touch the container.
    func accountFingerprint() -> String? {
        guard FeatureFlags.iCloudBackup, let token = FileManager.default.ubiquityIdentityToken else { return nil }
        // The token is an opaque `NSCoding` object (`NSData` on macOS 26): its bytes, else its archive.
        if let data = token as? Data { return CloudBackupAccount.fingerprint(token: data) }
        guard let archived = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false) else { return nil }
        return CloudBackupAccount.fingerprint(token: archived)
    }

    /// `Documents` inside the container is what Files shows. Made only when a backup is written:
    /// looking (the listing, a check after an account switch) leaves no empty Meowverse folder
    /// in someone's iCloud Drive.
    private func documents(create: Bool = false) -> URL? {
        guard FeatureFlags.iCloudBackup else { return nil }
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: Self.containerID) else { return nil }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        if create { try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true) }
        return documents
    }

    private func requireDocuments(create: Bool = false) throws -> URL {
        guard let documents = documents(create: create) else { throw CloudBackupError.unavailable(availability()) }
        return documents
    }

    private func url(_ name: String, in documents: URL) throws -> URL {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), name.utf8.count <= 200 else { throw CloudBackupError.io("name") }
        return documents.appendingPathComponent(name, isDirectory: false)
    }

    /// Older systems keep a file that is not downloaded as a hidden `.<name>.icloud` placeholder.
    private static func placeholderName(_ fileName: String) -> String? {
        guard fileName.hasPrefix("."), fileName.hasSuffix(".icloud"), fileName.count > 8 else { return nil }
        return String(fileName.dropFirst().dropLast(7))
    }

    func list() throws -> [CloudBackupFile] {
        let documents = try requireDocuments()
        // Nothing was ever backed up into this account.
        guard FileManager.default.fileExists(atPath: documents.path) else { return [] }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: Array(Self.listKeys), options: [])
        } catch {
            throw Self.map(error, fallback: "list")
        }
        var files: [String: CloudBackupFile] = [:]
        for url in urls {
            let fileName = url.lastPathComponent
            if let name = Self.placeholderName(fileName) {
                if files[name] == nil { files[name] = CloudBackupFile(name: name, byteSize: nil, isDownloaded: false, upload: .uploaded) }
                continue
            }
            guard !fileName.hasPrefix("."), let values = try? url.resourceValues(forKeys: Self.listKeys), values.isRegularFile == true else { continue }
            let upload: CloudUploadState
            if let error = values.ubiquitousItemUploadingError {
                upload = .failed(quotaExceeded: error.code == NSUbiquitousFileNotUploadedDueToQuotaError)
            } else if values.ubiquitousItemIsUploaded == true {
                upload = .uploaded
            } else if values.ubiquitousItemIsUploading == true {
                upload = .uploading
            } else {
                upload = .pending
            }
            let downloaded = values.ubiquitousItemDownloadingStatus != .notDownloaded
            // A file whose content is not here may report a size of 0 or nothing: say "unknown"
            // rather than let a size check call a good, evicted backup damaged.
            files[fileName] = CloudBackupFile(name: fileName, byteSize: downloaded ? values.fileSize : nil,
                                              isDownloaded: downloaded, upload: upload)
        }
        return files.values.sorted { $0.name < $1.name }
    }

    /// The file itself when its content is on this device.
    func localURL(for name: String) -> URL? {
        guard let documents = documents(), let url = try? url(name, in: documents),
              FileManager.default.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
              values.ubiquitousItemDownloadingStatus != .notDownloaded
        else { return nil }
        return url
    }

    func readSmallFile(_ name: String) throws -> Data {
        guard let url = localURL(for: name) else {
            // Not here yet: ask the system for it and let the next listing pick it up.
            if let documents = documents(), let url = try? url(name, in: documents) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
            throw CloudBackupError.notFound
        }
        var result: Result<Data, any Error> = .failure(CloudBackupError.io("read"))
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { actual in
            // Through the same cap as the plain folder: never more than an info file can be (B24-03).
            result = Result { try CloudBackupInfo.readBounded(at: actual) }
        }
        if let coordinationError { throw Self.map(coordinationError, fallback: "read") }
        do { return try result.get() } catch { throw Self.map(error, fallback: "read") }
    }

    func place(_ local: URL, as name: String) throws {
        let documents = try requireDocuments(create: true)
        let target = try url(name, in: documents)
        guard !FileManager.default.fileExists(atPath: target.path),
              !FileManager.default.fileExists(atPath: documents.appendingPathComponent(".\(name).icloud").path)
        else { throw CloudBackupError.nameTaken }
        do {
            // A coordinated move into iCloud. It fails rather than replace an existing item.
            try FileManager.default.setUbiquitous(true, itemAt: local, destinationURL: target)
        } catch {
            throw Self.map(error, fallback: "place")
        }
    }

    func writeSmallFile(_ data: Data, as name: String) throws {
        let target = try url(name, in: try requireDocuments(create: true))
        var failure: (any Error)?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { actual in
            do { try data.write(to: actual, options: .atomic) } catch { failure = error }
        }
        if let error = coordinationError ?? failure { throw Self.map(error, fallback: "write") }
    }

    func remove(_ name: String) throws {
        let documents = try requireDocuments()
        let target = try url(name, in: documents)
        let exists = FileManager.default.fileExists(atPath: target.path)
            || FileManager.default.fileExists(atPath: documents.appendingPathComponent(".\(name).icloud").path)
        guard exists else { return }
        var failure: (any Error)?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forDeleting, error: &coordinationError) { actual in
            do { try FileManager.default.removeItem(at: actual) } catch { failure = error }
        }
        if let error = coordinationError ?? failure { throw Self.map(error, fallback: "remove") }
    }

    func download(_ name: String, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        if let local = localURL(for: name) {
            progress(1)
            return local
        }
        let documents = try requireDocuments()
        let target = try url(name, in: documents)
        guard try list().contains(where: { $0.name == name }) else { throw CloudBackupError.notFound }
        guard await Self.isOnline() else { throw CloudBackupError.offline }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: target)
        } catch {
            throw Self.map(error, fallback: "download")
        }
        progress(nil)
        // Online but no new amount for `CloudDownloadWatch.stallLimit`: the download ends with a
        // failure the user can retry, instead of waiting for ever (audit A24-06).
        let watch = OSAllocatedUnfairLock(initialState: CloudDownloadWatch(start: Date()))
        let report: @Sendable (Double?) -> Void = { fraction in
            watch.withLock { $0.note(fraction, at: Date()) }
            progress(fraction)
        }
        let watcher = await UbiquityDownloadWatcher(name: name, progress: report)
        do {
            var ticks = 0
            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(500))
                ticks += 1
                // The connection went away mid-download: say so instead of waiting for ever.
                if ticks % 20 == 0, !(await Self.isOnline()) { throw CloudBackupError.offline }
                if watch.withLock({ $0.isStalled(at: Date()) }) { throw CloudBackupError.downloadStalled }
                // A fresh URL each time: resource values are cached per URL object.
                let fresh = documents.appendingPathComponent(name, isDirectory: false)
                let values = try? fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey])
                if let error = values?.ubiquitousItemDownloadingError { throw Self.map(error, fallback: "download") }
                if values?.ubiquitousItemDownloadingStatus == .current, FileManager.default.fileExists(atPath: fresh.path) {
                    await watcher.stop()
                    progress(1)
                    return fresh
                }
            }
        } catch {
            await watcher.stop()
            throw error
        }
    }

    /// One reading of the current network path.
    private static func isOnline() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let answered = OSAllocatedUnfairLock(initialState: false)
            monitor.pathUpdateHandler = { path in
                let first = answered.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                guard first else { return }
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: .global(qos: .utility))
        }
    }

    static func map(_ error: any Error, fallback: String) -> CloudBackupError {
        if let error = error as? CloudBackupError { return error }
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        if ns.domain == NSURLErrorDomain || underlying?.domain == NSURLErrorDomain { return .offline }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSUbiquitousFileNotUploadedDueToQuotaError: return .quotaExceeded
            case NSUbiquitousFileUbiquityServerNotAvailable: return .offline
            case NSUbiquitousFileUnavailableError: return .unavailable(.containerUnavailable)
            case NSFileWriteOutOfSpaceError: return .io("space")
            case NSFileWriteFileExistsError: return .nameTaken
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .notFound
            default: break
            }
        }
        return .io(fallback)
    }
}

/// Reports how much of one iCloud file has been downloaded. Progress only: whether the
/// download finished is decided by the file's own resource values, not by this query.
final class UbiquityDownloadWatcher {
    private let query = NSMetadataQuery()
    private var observers: [any NSObjectProtocol] = []

    init(name: String, progress: @escaping @Sendable (Double?) -> Void) {
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, name)
        for notification in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: notification, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report(progress) }
            })
        }
        query.start()
    }

    private func report(_ progress: (Double?) -> Void) {
        query.disableUpdates()
        defer { query.enableUpdates() }
        guard let item = query.results.first as? NSMetadataItem,
              let percent = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double else { return }
        progress(min(1, max(0, percent / 100)))
    }

    func stop() {
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
