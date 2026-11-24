import Darwin
import Foundation
import Testing
@testable import MeowverseCore

/// Release-mode storage benchmark for PERF-07. Seed JPEGs have unique bytes and valid records.
/// The timer starts with the library loaded and the picker drafts decoded.
struct PickerScaleProbe {
    private let fm = FileManager.default

    @MainActor private final class VisibleLibrary {
        var state = AppState.empty
        var index = LibraryIndex(state: .empty)

        func publish(_ snapshot: (AppState, LibraryIndex)) {
            (state, index) = snapshot
            precondition(index.photo(id: state.photos.last!.photoId) != nil)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEOWVERSE_PERF07"] == "1"))
    func measure() async throws {
        let furniture = ProcessInfo.processInfo.environment["PERF07_FURNITURE"] == "1"
        let source = TestSupport.imageData(seed: 1)
        let count = furniture ? 20 : 100
        let drafts = try (10000..<(10000 + count)).map { try PhotoIngest.makeDraft(data: jpeg(source, number: $0), filename: nil) }
        for n in [100, 1000, 5000] {
            let root = TestSupport.tempDir()
            defer { try? fm.removeItem(at: root) }
            try seed(root, source: source, thumbnail: drafts[0].thumbnailJPEG, count: n)
            let store = LibraryStore(root: root, catalog: try TestSupport.catalog())
            try await store.load()
            var target: String?
            if furniture {
                let first = try PhotoIngest.makeDraft(data: jpeg(source, number: 0), filename: nil)
                let placement = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2, finish: .sage)
                target = try await store.commitNewFurniture(draft: first, placement: placement, displayName: "Chair", decision: .manual).instanceId
            }
            try await measurePicker(store: store, root: root, drafts: drafts, target: target, originalCount: n)
        }
    }

    private func jpeg(_ source: Data, number: Int) -> Data {
        // JPEG COM segment with an 8-byte payload, immediately after SOI.
        let comment = Array(String(format: "%08d", number).utf8)
        return Data(source.prefix(2)) + Data([0xff, 0xfe, 0, 10] + comment) + source.dropFirst(2)
    }

    private func seed(_ root: URL, source: Data, thumbnail: Data, count: Int) throws {
        for folder in [LibraryStore.thumbnailsDir, LibraryStore.originalsDir] {
            try fm.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        var initial = AppState.empty
        for number in 0..<count {
            let data = jpeg(source, number: number), hash = PhotoIngest.sha256Hex(data), id = UUID().uuidString
            let record = PhotoRecord(photoId: id, filename: nil, sha256: hash, mimeType: "image/jpeg", byteSize: data.count,
                width: 64, height: 32, originalFile: "originals/\(hash).jpeg", thumbnailFile: "thumbnails/\(id).jpg",
                captureDate: nil, captureDateSource: .unknown, exifCaptureDate: nil, importedAt: Date(timeIntervalSince1970: 10000), revision: 1)
            try data.write(to: root.appending(path: record.originalFile))
            try thumbnail.write(to: root.appending(path: record.thumbnailFile))
            initial.photos.append(record)
        }
        try LibraryStore.encodeState(initial).write(to: root.appending(path: LibraryStore.stateFile))
    }

    private func size(_ url: URL) throws -> Int {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        return try #require(attributes[.size] as? NSNumber).intValue
    }

    private func measurePicker(store: LibraryStore, root: URL, drafts: [ImportDraft], target: String?, originalCount: Int) async throws {
        let primary = root.appending(path: LibraryStore.stateFile)
        let baseSize = try size(primary)
        let visible = VisibleLibrary()
        await visible.publish(store.indexedSnapshot())
        var deltaBytes = 0, mainMS = 0.0, checkpoints = [Double]()
        let began = Date()
        for start in stride(from: 0, to: drafts.count, by: 3) {
            let tick = Date()
            let group = Array(drafts[start..<min(start + 3, drafts.count)])
            _ = try await store.importPickerPhotos(group, to: target)
            let snapshot = await store.indexedSnapshot()
            mainMS += await MainActor.run {
                let tick = Date()
                visible.publish(snapshot)
                return -tick.timeIntervalSinceNow * 1000
            }
            let file = String(format: "%08d.json", checkpoints.count + 1)
            deltaBytes += try size(root.appending(path: PickerImportJournal.directory).appending(path: file))
            checkpoints.append(-tick.timeIntervalSinceNow * 1000)
        }
        await store.finishPickerImport()
        let totalMS = -began.timeIntervalSinceNow * 1000
        let fullBytes = try size(primary), copies = baseSize + (try size(root.appending(path: LibraryStore.backupFile)))
        #expect(await store.snapshot().photos.count == originalCount + drafts.count)
        #expect(!fm.fileExists(atPath: root.appending(path: PickerImportJournal.directory).path))
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let p95 = checkpoints.sorted()[Int((Double(checkpoints.count) * 0.95).rounded(.up)) - 1]
        print("PERF07 n=\(originalCount) added=\(drafts.count) peak_process_mib=\(usage.ru_maxrss / 1_048_576) "
            + "time_ms=\(Int(totalMS)) p95_ms=\(Int(p95)) main_ms=\(mainMS) full_bytes=\(fullBytes) "
            + "copy_bytes=\(copies) delta_bytes=\(deltaBytes) checkpoints=\(checkpoints.count)")
    }
}
