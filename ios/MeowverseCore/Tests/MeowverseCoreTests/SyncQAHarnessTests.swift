import Foundation
import Synchronization
import Testing
@testable import MeowverseCore

// QA harness for the sync review (no tests here, only helpers the SyncQA* suites share):
// a transport that can hold a call mid-flight and fail downloads, and a device built on it.

/// Holds the next armed `fetchChanges` until the test releases it, so a test can act while a
/// sync cycle is suspended on the network.
actor QAGate {
    private var armed = false
    private var held: CheckedContinuation<Void, Never>?
    private var arrivedWaiter: CheckedContinuation<Void, Never>?
    private var arrived = false

    func arm() { armed = true; arrived = false }

    func pass() async {
        guard armed else { return }
        armed = false
        arrived = true
        arrivedWaiter?.resume()
        arrivedWaiter = nil
        await withCheckedContinuation { held = $0 }
    }

    func waitUntilHeld() async {
        if arrived { return }
        await withCheckedContinuation { arrivedWaiter = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }
}

/// Switches a test flips per device.
final class QAFaults: Sendable {
    private let downloads = Mutex(false)
    var failDownloads: Bool {
        get { downloads.withLock { $0 } }
        set { downloads.withLock { $0 = newValue } }
    }
}

struct QATransport: SyncTransport {
    let inner: SyncMemoryEndpoint
    let gate: QAGate
    let faults: QAFaults

    func accountKey() async throws -> String { try await inner.accountKey() }
    func fetchChanges(since token: SyncToken?) async throws -> SyncFetchResult {
        await gate.pass()
        return try await inner.fetchChanges(since: token)
    }
    func save(_ records: [SyncSave]) async throws -> [SyncSaveResult] { try await inner.save(records) }
    func hasFile(sha256: String) async throws -> Bool { try await inner.hasFile(sha256: sha256) }
    func uploadFile(sha256: String, data: Data) async throws { try await inner.uploadFile(sha256: sha256, data: data) }
    func downloadFile(sha256: String) async throws -> Data {
        if faults.failDownloads { throw SyncTransportError.offline }
        return try await inner.downloadFile(sha256: sha256)
    }
    func deleteFile(sha256: String) async throws { try await inner.deleteFile(sha256: sha256) }
}

/// A device whose session runs on `QATransport`. Same folder layout as `SyncDevice`.
struct QADevice {
    let name: String
    let root: URL
    let store: LibraryStore
    let session: SyncSession
    let cloud: SyncMemoryCloud
    let gate = QAGate()
    let faults = QAFaults()
    let catalog: FurnitureCatalog
    let now: @Sendable () -> Date

    init(_ name: String, cloud: SyncMemoryCloud, clock: SyncTestClock, skew: TimeInterval = 0,
         fault: (@Sendable (StoreStep) throws -> Void)? = nil) async throws {
        self.name = name
        self.cloud = cloud
        root = TestSupport.tempDir().appendingPathComponent("Library-\(name)", isDirectory: true)
        catalog = try TestSupport.catalog()
        store = LibraryStore(root: root, catalog: catalog, fault: fault)
        try await store.load()
        now = clock.reader(skew: skew)
        session = SyncSession(store: store, transport: QATransport(inner: cloud.endpoint(name), gate: gate, faults: faults),
                              catalog: catalog, deviceID: "dev\(name)", now: now)
    }

    @discardableResult
    func sync() async throws -> SyncReport { try await session.sync() }

    func state() async -> AppState { await store.snapshot() }

    var syncStateURL: URL { root.appendingPathComponent(LibraryStore.syncStateFile) }

    /// Every photo's stored copy and thumbnail are on disk and the copy matches its hash.
    func filesAreWhole() async -> [String] {
        var problems: [String] = []
        for photo in await state().photos {
            let original = root.appendingPathComponent(photo.originalFile)
            let thumbnail = root.appendingPathComponent(photo.thumbnailFile)
            if let data = try? Data(contentsOf: original) {
                if PhotoIngest.sha256Hex(data) != photo.sha256 { problems.append("\(name): \(photo.photoId) copy has other bytes") }
            } else {
                problems.append("\(name): \(photo.photoId) copy missing")
            }
            if !FileManager.default.fileExists(atPath: thumbnail.path) { problems.append("\(name): \(photo.photoId) thumbnail missing") }
        }
        return problems
    }
}

enum QACheck {
    /// Like `SyncCheck.settle`, for `QADevice`s, with more rounds for more devices.
    @discardableResult
    static func settle(_ devices: [QADevice], rounds: Int = 12, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Int {
        for round in 1...rounds {
            var changed = false
            for device in devices {
                let report = try await device.sync()
                if report.applied || report.sent > 0 || report.received > 0 || report.unsent > 0 || report.problem != nil
                    || report.waitingForFiles > 0 { changed = true }
            }
            if !changed { return round }
        }
        Issue.record("did not settle in \(rounds) rounds", sourceLocation: sourceLocation)
        return rounds
    }

    static func expectConverged(_ devices: [QADevice], sourceLocation: SourceLocation = #_sourceLocation) async {
        var views: [SyncCheck.View] = []
        for device in devices {
            let state = await device.state()
            #expect(LibraryStore.isConsistent(state), "\(device.name) is consistent", sourceLocation: sourceLocation)
            views.append(SyncCheck.view(state))
        }
        for (index, other) in views.enumerated().dropFirst() where other != views[0] {
            Issue.record("device \(devices[index].name) differs from \(devices[0].name):\n\(views[0])\n---\n\(other)",
                         sourceLocation: sourceLocation)
        }
    }

    /// Rewrites a device's sync file through the store (keeps the store's own checks).
    static func rewriteSyncState(_ store: LibraryStore, _ change: (inout [String: Any]) throws -> Void) async throws {
        let (_, generation) = try await store.syncSnapshot()
        let data = try #require(try await store.readSyncState())
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        try change(&json)
        try await store.writeSyncState(try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), generation: generation)
    }
}
