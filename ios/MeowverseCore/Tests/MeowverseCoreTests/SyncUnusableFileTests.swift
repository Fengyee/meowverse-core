import Foundation
import Synchronization
import Testing
@testable import MeowverseCore

/// ERRORS-1: a photo file this device can't use is said and not pulled again on every cycle; one
/// that just isn't there yet still waits; a repair upload that fails is said like a push.
@Suite(.timeLimit(.minutes(2))) struct SyncUnusableFileTests {
    final class Faults: Sendable {
        enum Download { case none, damaged, rejected, offlineOnce }
        let download = Mutex(Download.none)
        let downloads = Mutex(0)
        let uploadFails = Mutex(false)
    }

    struct Transport: SyncTransport {
        let inner: SyncMemoryEndpoint
        let faults: Faults
        func accountKey() async throws -> String { try await inner.accountKey() }
        func fetchChanges(since token: SyncToken?) async throws -> SyncFetchResult { try await inner.fetchChanges(since: token) }
        func save(_ records: [SyncSave]) async throws -> [SyncSaveResult] { try await inner.save(records) }
        func hasFile(sha256: String) async throws -> Bool { try await inner.hasFile(sha256: sha256) }
        func deleteFile(sha256: String) async throws { try await inner.deleteFile(sha256: sha256) }
        func fileStoredAt(sha256: String) async throws -> Date? { try await inner.fileStoredAt(sha256: sha256) }
        func uploadFile(sha256: String, data: Data) async throws {
            if faults.uploadFails.withLock({ $0 }) { throw SyncTransportError.quotaExceeded }
            try await inner.uploadFile(sha256: sha256, data: data)
        }
        func downloadFile(sha256: String) async throws -> Data {
            faults.downloads.withLock { $0 += 1 }
            switch faults.download.withLock({ $0 }) {
            case .none: break
            case .damaged: return Data("not a photo".utf8)
            case .rejected: throw SyncTransportError.rejected("hash")
            case .offlineOnce:
                faults.download.withLock { $0 = .none }
                throw SyncTransportError.offline
            }
            return try await inner.downloadFile(sha256: sha256)
        }
    }

    private struct Phone {
        let store: LibraryStore
        let session: SyncSession
        let faults = Faults()

        init(_ name: String, cloud: SyncMemoryCloud, clock: SyncTestClock) async throws {
            let catalog = try TestSupport.catalog()
            store = LibraryStore(root: TestSupport.tempDir().appendingPathComponent("Library-\(name)", isDirectory: true), catalog: catalog)
            try await store.load()
            session = SyncSession(store: store, transport: Transport(inner: cloud.endpoint(name), faults: faults),
                                  catalog: catalog, deviceID: "dev\(name)", now: clock.reader())
        }
    }

    /// A has sent a photo; B has not synced yet.
    private func sentPhoto() async throws -> (cloud: SyncMemoryCloud, a: Phone, b: Phone, photo: PhotoRecord) {
        let cloud = SyncMemoryCloud(), clock = SyncTestClock()
        let a = try await Phone("A", cloud: cloud, clock: clock), b = try await Phone("B", cloud: cloud, clock: clock)
        let photo = try await a.store.importPhoto(draft: try TestSupport.draft(seed: 731)).photo
        _ = try await a.session.sync()
        return (cloud, a, b, photo)
    }

    @Test(arguments: [Faults.Download.damaged, .rejected]) func anUnusableFileIsSaidAndPulledOnce(kind: Faults.Download) async throws {
        let (_, _, b, _) = try await sentPhoto()
        b.faults.download.withLock { $0 = kind }
        let first = try await b.session.sync()
        #expect(first.unusableFiles == 1)
        #expect(first.waitingForFiles == 0, "nothing is being downloaded")
        let again = try await b.session.sync()
        #expect(again.unusableFiles == 1 && again.waitingForFiles == 0)
        #expect(b.faults.downloads.withLock { $0 } == 1, "pulled again in full")
    }

    @Test func aFailedConnectionStillWaitsAndTriesAgain() async throws {
        let (_, _, b, photo) = try await sentPhoto()
        b.faults.download.withLock { $0 = .offlineOnce }
        let first = try await b.session.sync()
        #expect(first.waitingForFiles == 1 && first.unusableFiles == 0)
        let second = try await b.session.sync()
        #expect(second.waitingForFiles == 0 && second.unusableFiles == 0)
        #expect(await b.store.snapshot().photos.map(\.sha256) == [photo.sha256])
    }

    @Test func aFailedRepairUploadIsSaid() async throws {
        let (cloud, a, _, photo) = try await sentPhoto()
        try await cloud.endpoint("A").deleteFile(sha256: photo.sha256)
        a.faults.uploadFails.withLock { $0 = true }
        let report = try await a.session.sync()
        #expect(report.problem == .quotaExceeded)
    }
}
