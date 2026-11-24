import Foundation
import Testing
@testable import MeowverseCore

/// iOS backup: export, verified restore, all-or-nothing switch, clear all, cat name, schema 3.
struct BackupRestoreTests {
    let fm = FileManager.default
    let catalog: FurnitureCatalog
    let chairAt44 = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2)
    let stoolAt00 = Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1)

    init() throws {
        catalog = try TestSupport.catalog()
    }

    /// A parent folder holding the store folder, so staging siblings are easy to list.
    private func sandbox() -> (parent: URL, root: URL) {
        let parent = TestSupport.tempDir()
        return (parent, parent.appendingPathComponent("Library", isDirectory: true))
    }

    private func exifDraft(seed: Int) throws -> ImportDraft {
        try PhotoIngest.makeDraft(data: TestSupport.imageData(seed: seed, dateTimeOriginal: "2026:03:14 09:26:53"), filename: "exif-\(seed).jpg")
    }

    /// Two pieces of furniture, three photos (one unlinked), with edits and a cat name.
    private func seed(_ store: LibraryStore) async throws -> AppState {
        let chair = try await store.commitNewFurniture(draft: try exifDraft(seed: 1), placement: chairAt44, displayName: "窗边的椅子", decision: .manual)
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 2), placement: stoolAt00, displayName: "小凳子", decision: .manual)
        let loose = try await store.addPhoto(draft: try TestSupport.draft(seed: 3))
        _ = try await store.editPhoto(photoId: chair.sources[0].photoId, PhotoEdit(favorite: true, note: "第一次上椅子"))
        _ = try await store.editPhoto(photoId: loose.photoId, PhotoEdit(captureDate: .set("2025-12-01")))
        _ = try await store.linkPhoto(photoId: loose.photoId, toInstance: chair.instanceId)
        try await store.setCatName("团子")
        return await store.snapshot()
    }

    private func export(_ store: LibraryStore, in dir: URL) async throws -> URL {
        let url = dir.appendingPathComponent("backup-\(UUID().uuidString).zip")
        _ = try await store.exportBackup(to: url, appVersion: "9.9")
        return url
    }

    private func siblings(_ parent: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).filter { $0.hasPrefix("Library.") }.sorted()
    }

    /// Everything under a folder: relative path -> bytes.
    private func contents(_ root: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        for path in TestSupport.listing(root) {
            var isDir: ObjCBool = false
            let url = root.appendingPathComponent(path)
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue { result[path] = TestSupport.bytes(url) }
        }
        return result
    }

    /// Rewrites a backup: `edit` gets path -> bytes and may change anything; ZIP checksums
    /// are recomputed, so only the backup's own checks can catch the change.
    private func rewrite(_ url: URL, fixManifest: Bool = true, _ edit: (inout [String: Data]) throws -> Void) throws -> URL {
        let reader = try ZipReader(fileURL: url, limits: .backup)
        var files: [String: Data] = [:]
        for entry in reader.entries { files[entry.path] = try reader.extract(entry) }
        try edit(&files)
        if fixManifest, let state = files["state.json"], let manifestData = files["manifest.json"],
           var manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] {
            manifest["state"] = ["path": "state.json", "byteSize": state.count, "sha256": PhotoIngest.sha256Hex(state)]
            files["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest)
        }
        let out = url.deletingLastPathComponent().appendingPathComponent("rewritten-\(UUID().uuidString).zip")
        let writer = try ZipWriter(url: out)
        for path in files.keys.sorted() { try writer.add(path: path, data: files[path]!) }
        try writer.finish()
        return out
    }

    private func editJSON(_ data: Data, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Round trip

    @Test func exportThenRestoreIntoAnotherLibraryKeepsBytesIdsAndEdits() async throws {
        let (parentA, rootA) = sandbox(), (parentB, rootB) = sandbox()
        defer { try? fm.removeItem(at: parentA); try? fm.removeItem(at: parentB) }
        let source = LibraryStore(root: rootA, catalog: catalog)
        let original = try await seed(source)
        let progress = ProgressLog()
        let url = parentA.appendingPathComponent("backup.zip")
        let summary = try await source.exportBackup(to: url, appVersion: "9.9") { progress.add($0) }
        #expect(summary.photoCount == 3 && summary.furnitureCount == 2)
        #expect(summary.byteSize == (try fm.attributesOfItem(atPath: url.path)[.size] as? Int))
        #expect(progress.values.last?.fraction == 1 && progress.values.map(\.completedBytes) == progress.values.map(\.completedBytes).sorted())
        // Exporting changes nothing in the library.
        #expect(await source.snapshot() == original)

        // The other phone already has something in it.
        let target = LibraryStore(root: rootB, catalog: catalog)
        _ = try await target.commitNewFurniture(draft: try TestSupport.draft(seed: 50), placement: chairAt44, displayName: "旧椅子", decision: .manual)
        let before = contents(rootB)

        let prepared = try BackupArchive.prepare(file: url, stagingURL: target.makeStagingURL(), catalog: catalog)
        #expect(prepared.preview.kind == .iosBackup && prepared.preview.appVersion == "9.9")
        #expect(prepared.preview.photoCount == 3 && prepared.preview.furnitureCount == 2)
        #expect(prepared.preview.schemaVersion == AppState.currentSchemaVersion && prepared.preview.formatVersion == 1)
        #expect(prepared.preview.catName == "团子" && prepared.preview.notes.isEmpty)
        #expect(abs(prepared.preview.createdAt.timeIntervalSinceNow) < 120)
        // Preparing (the preview step) has not touched the live library.
        #expect(contents(rootB) == before)
        #expect(siblings(parentB).count == 1)

        let restored = try await target.replaceLibrary(with: prepared)
        #expect(restored == original, "ids, placements, sources, dates, notes, favourites and the cat's name are identical")
        #expect(await target.snapshot() == original)
        #expect(siblings(parentB).isEmpty, "the old library and the staging folder are gone")
        for photo in original.photos {
            #expect(TestSupport.bytes(rootB.appendingPathComponent(photo.originalFile)) == TestSupport.bytes(rootA.appendingPathComponent(photo.originalFile)))
            #expect(TestSupport.bytes(rootB.appendingPathComponent(photo.thumbnailFile)) == TestSupport.bytes(rootA.appendingPathComponent(photo.thumbnailFile)))
            #expect(try await target.verifyOriginal(photoId: photo.photoId))
        }
        #expect(await target.integrityReport().isClean)
        #expect(!TestSupport.listing(rootB).contains { $0.contains("backup.json") }, "no stale fallback state from the replaced library")

        // Survives a reopen, and the restored library is a normal one: it can be changed.
        let reopened = LibraryStore(root: rootB, catalog: catalog)
        #expect(try await reopened.load() == original)
        _ = try await reopened.editPhoto(photoId: original.photos[0].photoId, PhotoEdit(favorite: false))
        #expect(await reopened.integrityReport().isClean)
    }

    @Test func restoreOverLaterChangesBringsBackTheExportedState() async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: root, catalog: catalog)
        let exported = try await seed(store)
        let url = try await export(store, in: parent)
        try await store.deletePhoto(photoId: exported.photos[0].photoId)
        _ = try await store.addPhoto(draft: try TestSupport.draft(seed: 9))
        try await store.setCatName("别的名字")

        let prepared = try BackupArchive.prepare(file: url, stagingURL: store.makeStagingURL(), catalog: catalog)
        #expect(try await store.replaceLibrary(with: prepared) == exported)
        #expect(await store.integrityReport().isClean)
        #expect(await store.storageUsage().photoCount == 3)
        // A prepared library can be used once.
        await #expect(throws: BackupError.stale) { try await store.replaceLibrary(with: prepared) }
        #expect(await store.snapshot() == exported)
    }

    @Test func aMissingThumbnailIsRebuiltOnRestore() async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: root, catalog: catalog)
        let state = try await seed(store)
        try fm.removeItem(at: root.appendingPathComponent(state.photos[1].thumbnailFile))
        let url = try await export(store, in: parent)
        let prepared = try BackupArchive.prepare(file: url, stagingURL: store.makeStagingURL(), catalog: catalog)
        #expect(prepared.preview.notes == [.thumbnailsRebuilt(1)])
        _ = try await store.replaceLibrary(with: prepared)
        #expect(await store.integrityReport().isClean)
    }

    // MARK: - Failure leaves the library as it was

    @Test func aFailedSwitchLeavesTheOldLibraryIntact() async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let fault = FaultSwitch(nil)
        let store = LibraryStore(root: root, catalog: catalog, fault: fault.handler)
        let exported = try await seed(store)
        let url = try await export(store, in: parent)
        _ = try await store.addPhoto(draft: try TestSupport.draft(seed: 9))
        let current = await store.snapshot()
        let before = contents(root)

        let prepared = try BackupArchive.prepare(file: url, stagingURL: store.makeStagingURL(), catalog: catalog)
        fault.arm(.swapLibrary)
        await #expect(throws: InjectedFault.failed(.swapLibrary)) { try await store.replaceLibrary(with: prepared) }
        #expect(await store.snapshot() == current)
        #expect(contents(root) == before, "every file of the old library is byte-identical")
        #expect(siblings(parent).isEmpty, "the staged copy was removed")
        #expect(try await LibraryStore(root: root, catalog: catalog).load() == current)

        // The same for clear all.
        fault.arm(.swapLibrary)
        await #expect(throws: InjectedFault.failed(.swapLibrary)) { try await store.clearAll() }
        #expect(await store.snapshot() == current && contents(root) == before && siblings(parent).isEmpty)

        // And a retry works.
        let again = try BackupArchive.prepare(file: url, stagingURL: store.makeStagingURL(), catalog: catalog)
        #expect(try await store.replaceLibrary(with: again) == exported)
    }

    @Test func damagedOrForeignPackagesAreRefusedAndNothingChanges() async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: root, catalog: catalog)
        let state = try await seed(store)
        let url = try await export(store, in: parent)
        let before = contents(root)
        let bytes = try Data(contentsOf: url)
        let first = state.photos[0]

        func expectRefused(_ file: URL, _ expected: (BackupError) -> Bool, _ label: String) {
            do {
                _ = try BackupArchive.prepare(file: file, stagingURL: store.makeStagingURL(), catalog: catalog)
                Issue.record("\(label): accepted")
            } catch let error as BackupError {
                #expect(expected(error), "\(label): \(error)")
            } catch {
                Issue.record("\(label): unexpected \(error)")
            }
            #expect(siblings(parent).isEmpty, "\(label): staging left behind")
            #expect(contents(root) == before, "\(label): live library changed")
        }
        func isDamaged(_ error: BackupError) -> Bool { if case .damaged = error { true } else { false } }
        func file(_ data: Data) throws -> URL {
            let out = parent.appendingPathComponent("case-\(UUID().uuidString).zip")
            try data.write(to: out)
            return out
        }

        // Truncated at several points, and not a ZIP at all.
        for length in [0, 10, bytes.count / 3, bytes.count / 2, bytes.count - 1] {
            expectRefused(try file(bytes.prefix(length)), { $0 == .notABackup || isDamaged($0) }, "truncated to \(length)")
        }
        expectRefused(try file(Data("这不是备份".utf8)), { $0 == .notABackup }, "text file")
        expectRefused(parent.appendingPathComponent("does-not-exist.zip"), { $0 == .notABackup }, "missing file")

        // One flipped byte in the middle (inside a stored original): the ZIP checksum catches it.
        var flipped = bytes
        flipped[bytes.count / 2] ^= 0x40
        expectRefused(try file(flipped), isDamaged, "flipped byte")

        // A valid ZIP that is not ours.
        let foreign = parent.appendingPathComponent("foreign.zip")
        let writer = try ZipWriter(url: foreign)
        try writer.add(path: "readme.txt", data: Data("hi".utf8))
        try writer.finish()
        expectRefused(foreign, { $0 == .notABackup }, "foreign zip")
        expectRefused(try rewrite(url, fixManifest: false) { files in
            files["manifest.json"] = try editJSON(files["manifest.json"]!) { $0["format"] = "someone-elses-backup" }
        }, { $0 == .notABackup }, "wrong format")

        // An original swapped for other bytes, with every ZIP checksum valid: SHA-256 catches it.
        expectRefused(try rewrite(url) { $0[first.originalFile] = TestSupport.imageData(seed: 77) }, { $0 == .damaged("originalSize") || $0 == .damaged("originalHash") }, "swapped original")
        expectRefused(try rewrite(url) { files in
            var same = files[first.originalFile]!
            same[same.count - 3] ^= 1
            files[first.originalFile] = same
        }, { $0 == .damaged("originalHash") }, "altered original, same length")
        // The state edited without updating the manifest hash.
        expectRefused(try rewrite(url, fixManifest: false) { files in
            files["state.json"] = try editJSON(files["state.json"]!) { $0["catName"] = "x" }
        }, { $0 == .damaged("stateHash") }, "state edited")
        // A missing original, and an extra file.
        expectRefused(try rewrite(url) { $0[first.originalFile] = nil }, isDamaged, "missing original")
        expectRefused(try rewrite(url) { $0["originals/extra.bin"] = Data([1, 2, 3]) }, isDamaged, "extra file")
        // A state that points outside the library.
        expectRefused(try rewrite(url) { files in
            files["state.json"] = try editJSON(files["state.json"]!) { object in
                var photos = object["photos"] as! [[String: Any]]
                photos[0]["thumbnailFile"] = "thumbnails/../../escape.jpg"
                object["photos"] = photos
            }
        }, isDamaged, "path escape")
        // A broken link: furniture pointing at a photo that is not there.
        expectRefused(try rewrite(url) { files in
            files["state.json"] = try editJSON(files["state.json"]!) { object in
                var items = object["items"] as! [[String: Any]]
                var sources = items[1]["sources"] as! [[String: Any]]
                sources[0]["photoId"] = "nobody"
                items[1]["sources"] = sources
                object["items"] = items
            }
        }, { $0 == .damaged("state") }, "dangling source")

        // Written by a newer app: newer state schema, or newer container format.
        expectRefused(try rewrite(url) { files in
            files["state.json"] = try editJSON(files["state.json"]!) { $0["schemaVersion"] = AppState.currentSchemaVersion + 1; $0["future"] = true }
        }, { $0 == .newerVersion }, "newer state schema")
        expectRefused(try rewrite(url) { files in
            files["manifest.json"] = try editJSON(files["manifest.json"]!) { $0["schemaVersion"] = 8 }
            files["state.json"] = try editJSON(files["state.json"]!) {
                $0["schemaVersion"] = 8
                $0["cats"] = [["catId": "cat-1", "name": "团子", "roomId": "missing-room"]]
            }
        }, { $0 == .damaged("state") }, "cat assigned to a missing room")
        expectRefused(try rewrite(url, fixManifest: false) { files in
            files["manifest.json"] = try editJSON(files["manifest.json"]!) { $0["schemaVersion"] = AppState.currentSchemaVersion + 1 }
        }, { $0 == .newerVersion }, "newer manifest schema")
        expectRefused(try rewrite(url, fixManifest: false) { files in
            files["manifest.json"] = try editJSON(files["manifest.json"]!) { $0["formatVersion"] = 2 }
        }, { $0 == .newerVersion }, "newer format")

        #expect(await store.snapshot() == state)
        #expect(await store.integrityReport().isClean)
    }

    @Test func exportRefusesALibraryWhoseOriginalIsDamaged() async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: root, catalog: catalog)
        let state = try await seed(store)
        let target = root.appendingPathComponent(state.photos[0].originalFile)
        var bytes = try Data(contentsOf: target)
        bytes[bytes.count / 2] ^= 1
        try bytes.write(to: target)
        let url = parent.appendingPathComponent("backup.zip")
        await #expect(throws: BackupError.libraryDamaged(1)) { try await store.exportBackup(to: url, appVersion: "1") }
        #expect(!fm.fileExists(atPath: url.path))
        #expect(await store.snapshot() == state)
    }

    @Test func cancellingStopsExportAndRestoreAndLeavesNothingBehind() async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: root, catalog: catalog)
        let state = try await seed(store)
        let good = try await export(store, in: parent)
        let before = contents(root)
        let catalog = self.catalog

        let url = parent.appendingPathComponent("cancelled.zip")
        let exporting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.exportBackup(to: url, appVersion: "1")
        }
        await #expect(throws: CancellationError.self) { try await exporting.value }
        #expect(!fm.fileExists(atPath: url.path))

        let staging = store.makeStagingURL()
        let restoring = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try BackupArchive.prepare(file: good, stagingURL: staging, catalog: catalog)
        }
        await #expect(throws: CancellationError.self) { try await restoring.value }
        #expect(siblings(parent).isEmpty)
        #expect(contents(root) == before)
        #expect(await store.snapshot() == state)
    }

    // MARK: - Clear all

    @Test func clearAllRemovesEverythingAndStaysEmptyAfterReopen() async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: root, catalog: catalog)
        _ = try await seed(store)
        let cleared = try await store.clearAll()
        #expect(cleared.photos.isEmpty && cleared.items.isEmpty && cleared.observations.isEmpty)
        #expect(cleared.catName == AppState.defaultCatName)
        #expect(await store.snapshot() == cleared)
        #expect(contents(root).keys.sorted() == ["state.json"], "no original, thumbnail or fallback state is left")
        #expect(siblings(parent).isEmpty)
        let usage = await store.storageUsage()
        #expect(usage.photoCount == 0 && usage.furnitureCount == 0)
        #expect(try await LibraryStore(root: root, catalog: catalog).load() == cleared)
        // The emptied library works normally.
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 1), placement: chairAt44, displayName: "a", decision: .manual)
        #expect(await store.integrityReport().isClean)
    }

    // MARK: - Cat name and schema 3

    @Test func catNameIsTrimmedValidatedAndPersisted() async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: root, catalog: catalog)
        #expect(try await store.load().catName == "Kitty")
        #expect(try await store.setCatName("  团子\n ").catName == "团子")
        let revision = await store.snapshot().revision
        #expect(try await store.setCatName("团子").revision == revision, "an unchanged name writes nothing")
        await #expect(throws: StoreError.invalidName) { try await store.setCatName("   ") }
        await #expect(throws: StoreError.invalidName) { try await store.setCatName(String(repeating: "喵", count: 21)) }
        #expect(try await store.setCatName(String(repeating: "喵", count: 20)).catName.count == 20)
        #expect(try await LibraryStore(root: root, catalog: catalog).load().catName.count == 20)
        let json = try #require(String(data: Data(contentsOf: root.appendingPathComponent("state.json")), encoding: .utf8))
        #expect(json.contains("\"schemaVersion\":\(AppState.currentSchemaVersion)") && json.contains("\"catName\""))
    }

    /// state.json as schema 1 and 2 wrote it (no `catName`; schema 1 also without the photo
    /// fields added in 2) still loads, shows "Bella", and is upgraded on the next save.
    @Test(arguments: [1, 2, 3, 4])
    func olderSchemaKeepsPhotosAndUpgradesOnNextWrite(version: Int) async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let seedStore = LibraryStore(root: root, catalog: catalog)
        let item = try await seedStore.commitNewFurniture(draft: try exifDraft(seed: 1), placement: chairAt44, displayName: "a", decision: .manual)
        _ = try await seedStore.addPhoto(draft: try TestSupport.draft(seed: 2))
        for name in ["state.json", "state.backup.json"] {
            let url = root.appendingPathComponent(name)
            try editJSON(Data(contentsOf: url)) { object in
                object["schemaVersion"] = version
                if version < 3 { object.removeValue(forKey: "catName") } else { object["catName"] = "Bella" }
                if version == 1 {
                    object["photos"] = (object["photos"] as! [[String: Any]]).map { photo in
                        var photo = photo
                        for key in ["favorite", "note", "exifCaptureDate"] { photo.removeValue(forKey: key) }
                        return photo
                    }
                }
            }.write(to: url)
        }
        let oldBytes = try Data(contentsOf: root.appendingPathComponent("state.json"))

        let store = LibraryStore(root: root, catalog: catalog)
        let state = try await store.load()
        #expect(state.schemaVersion == AppState.currentSchemaVersion && state.catName == "Bella")
        #expect(state.items.map(\.instanceId) == [item.instanceId] && state.photos.count == 2)
        #expect(state.photo(id: item.sources[0].photoId)?.exifCaptureDate == "2026-03-14")
        #expect(try Data(contentsOf: root.appendingPathComponent("state.json")) == oldBytes, "loading alone writes nothing")
        #expect(await store.integrityReport().isClean)

        try await store.setCatName("团子")
        let json = try #require(String(data: Data(contentsOf: root.appendingPathComponent("state.json")), encoding: .utf8))
        #expect(json.contains("\"schemaVersion\":\(AppState.currentSchemaVersion)") && json.contains("\"catName\":\"团子\""))
        #expect(try await LibraryStore(root: root, catalog: catalog).load() == (await store.snapshot()))

        // An older library can be backed up and restored like any other.
        let url = try await export(store, in: parent)
        let prepared = try BackupArchive.prepare(file: url, stagingURL: store.makeStagingURL(), catalog: catalog)
        #expect(try await store.replaceLibrary(with: prepared).catName == "团子")
    }

    // MARK: - Leftovers of an interrupted switch

    @Test func loadPutsBackAParkedLibraryAndRemovesStaleStaging() async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: root, catalog: catalog)
        let state = try await seed(store)
        let unrelated = ["Library.damaged-family", "Library.incoming-other", "Library.previous-zzz"]
        for name in unrelated { try fm.createDirectory(at: parent.appendingPathComponent(name), withIntermediateDirectories: false) }
        // A cancelled preview left behind by a killed app.
        let stale = store.makeStagingURL()
        try fm.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stale.appendingPathComponent("state.json"))
        #expect(try await LibraryStore(root: root, catalog: catalog).load() == state)
        #expect(siblings(parent) == unrelated)

        // The non-atomic fallback was interrupted after parking the live folder.
        try fm.moveItem(at: root, to: parent.appendingPathComponent("Library.previous-" + UUID().uuidString))
        let recovered = LibraryStore(root: root, catalog: catalog)
        #expect(try await recovered.load() == state)
        #expect(siblings(parent) == unrelated)
        #expect(await recovered.integrityReport().isClean)
        _ = try await recovered.clearAll()
        #expect(siblings(parent) == unrelated)
    }

    @Test(arguments: [false, true]) func directoryInstallReturnsDisplacedLibrary(forceFallback: Bool) throws {
        let parent = TestSupport.tempDir()
        defer { try? fm.removeItem(at: parent) }
        let a = parent.appendingPathComponent("a"), b = parent.appendingPathComponent("b")
        for (dir, text) in [(a, "A"), (b, "B")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: dir.appendingPathComponent("f"))
        }
        let displaced = try LibraryStore.install(a, at: b, forceFallback: forceFallback)
        #expect(try String(contentsOf: displaced.appendingPathComponent("f"), encoding: .utf8) == "B")
        #expect(try String(contentsOf: b.appendingPathComponent("f"), encoding: .utf8) == "A")
    }
}

/// Collects progress callbacks from another isolation domain.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BackupProgress] = []

    func add(_ value: BackupProgress) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [BackupProgress] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

// MARK: - Schema 6: storage, photo-less pieces, wall pieces

extension BackupRestoreTests {
    @Test func storedPhotolessAndWallPiecesRoundTripThroughABackup() async throws {
        let (parentA, rootA) = sandbox(), (parentB, rootB) = sandbox()
        defer { try? fm.removeItem(at: parentA); try? fm.removeItem(at: parentB) }
        // The bundled catalog has the built-in photo board.
        let catalog = try FurnitureCatalog.bundled()
        let source = LibraryStore(root: rootA, catalog: catalog)
        let chair = try await source.commitNewFurniture(draft: try exifDraft(seed: 70), placement: chairAt44, displayName: "收起来的椅子", decision: .manual)
        _ = try await source.addFurniture(placement: stoolAt00, displayName: "没有照片的凳子")
        let board = try await source.addFurniture(placement: Placement(modelId: "wall-photo-board", x: 3, z: 0, width: 3, depth: 1, wall: .left), displayName: "")
        let portrait = try await source.addPhoto(draft: try TestSupport.draft(seed: 71))
        _ = try await source.linkPhoto(photoId: portrait.photoId, toInstance: board.instanceId)
        let emptyStored = try await source.addFurniture(placement: Placement(modelId: "kenney-chair", x: 7, z: 0, width: 2, depth: 2), displayName: "空椅子")
        _ = try await source.stowFurniture(instanceId: chair.instanceId)
        _ = try await source.stowFurniture(instanceId: emptyStored.instanceId)
        let original = await source.snapshot()
        #expect(original.items.count == 2 && original.storage.map(\.instanceId) == [chair.instanceId, emptyStored.instanceId])

        let url = parentA.appendingPathComponent("backup.zip")
        let summary = try await source.exportBackup(to: url, appVersion: "9.9")
        #expect(summary.photoCount == 2 && summary.furnitureCount == 4, "stored pieces are furniture too")

        let target = LibraryStore(root: rootB, catalog: catalog)
        let prepared = try BackupArchive.prepare(file: url, stagingURL: target.makeStagingURL(), catalog: catalog)
        #expect(prepared.preview.schemaVersion == AppState.currentSchemaVersion && prepared.preview.furnitureCount == 4 && prepared.preview.photoCount == 2)
        let restored = try await target.replaceLibrary(with: prepared)
        #expect(restored == original, "storage, empty source lists and wall sides come back exactly")
        #expect(restored.storedItem(id: chair.instanceId)?.sources == chair.sources)
        #expect(restored.item(id: board.instanceId)?.wall == .left)
        #expect(await target.integrityReport().isClean)
        let reopened = LibraryStore(root: rootB, catalog: catalog)
        #expect(try await reopened.load() == original)
        // The restored stored piece can still come back into the room.
        #expect(try await reopened.restoreFurniture(instanceId: chair.instanceId, placement: chairAt44).sources == chair.sources)
    }

    @Test func aBackupWithDamagedStorageIsRefused() async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: root, catalog: catalog)
        let chair = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 72), placement: chairAt44, displayName: "椅", decision: .manual)
        _ = try await store.stowFurniture(instanceId: chair.instanceId)
        let url = try await export(store, in: parent)
        let before = await store.snapshot()
        func damaged(_ code: String, _ edit: @escaping (inout [String: Any]) -> Void) throws {
            let bad = try rewrite(url) { $0["state.json"] = try editJSON($0["state.json"]!, edit) }
            #expect(throws: BackupError.damaged(code)) {
                try BackupArchive.prepare(file: bad, stagingURL: store.makeStagingURL(), catalog: catalog)
            }
        }
        // The stored piece also in the room; a stored piece pointing at a photo that is not there;
        // a stored piece with values no renderer could take.
        try damaged("state") { $0["items"] = $0["storage"] }
        try damaged("state") { object in
            var stored = (object["storage"] as! [[String: Any]])[0]
            var sources = stored["sources"] as! [[String: Any]]
            sources[0]["photoId"] = "missing"
            stored["sources"] = sources
            object["storage"] = [stored]
        }
        try damaged("stateValues") { object in
            var stored = (object["storage"] as! [[String: Any]])[0]
            stored["turn"] = 9
            object["storage"] = [stored]
        }
        #expect(await store.snapshot() == before && siblings(parent).isEmpty)
    }
}

extension BackupRestoreTests {
    @Test(arguments: [200, 201]) func historicalLongFurnitureNamesRoundTrip(count: Int) async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: root, catalog: catalog)
        let name = String(repeating: "椅", count: count)
        let item = try await store.addFurniture(placement: chairAt44, displayName: name)
        let url = try await export(store, in: parent)
        let prepared = try BackupArchive.prepare(file: url, stagingURL: store.makeStagingURL(), catalog: catalog)
        try await store.replaceLibrary(with: prepared)
        #expect(try await LibraryStore(root: root, catalog: catalog).load().item(id: item.instanceId)?.displayName == name)
    }

    @Test func exportHonorsStateAndManifestBudgetsAndPreservesPreviousFile() async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: root, catalog: catalog)
        let file = parent.appendingPathComponent("backup.zip")
        _ = try await store.exportBackup(to: file, appVersion: "")
        let reader = try ZipReader(fileURL: file, limits: .backup)
        let overhead = try #require(reader.entry(BackupArchive.manifestPath)).uncompressedSize
        let version = String(repeating: "x", count: BackupArchive.maxJSONBytes - overhead)
        _ = try await store.exportBackup(to: file, appVersion: version)
        try BackupArchive.prepare(file: file, stagingURL: store.makeStagingURL(), catalog: catalog).discard()
        let previous = try Data(contentsOf: file)
        await #expect(throws: BackupError.tooLarge) { try await store.exportBackup(to: file, appVersion: version + "x") }
        #expect(try Data(contentsOf: file) == previous)

        let item = try await store.addFurniture(placement: chairAt44, displayName: "x")
        _ = try await store.rename(instanceId: item.instanceId, displayName: "y")
        let bytes = try LibraryStore.encodeState(await store.snapshot()).count
        let name = String(repeating: "x", count: BackupArchive.maxJSONBytes - bytes + 1)
        _ = try await store.rename(instanceId: item.instanceId, displayName: name)
        _ = try await store.exportBackup(to: file, appVersion: "1")
        let good = try BackupArchive.prepare(file: file, stagingURL: store.makeStagingURL(), catalog: catalog)
        try await store.replaceLibrary(with: good)
        #expect(try await store.load().items[0].displayName == name)
        let previousState = try Data(contentsOf: file)
        _ = try await store.rename(instanceId: item.instanceId, displayName: name + "x")
        await #expect(throws: BackupError.tooLarge) { try await store.exportBackup(to: file, appVersion: "1") }
        #expect(try Data(contentsOf: file) == previousState)
    }

    @Test func writerHonorsReadersEntryBudget() throws {
        let temp = TestSupport.tempDir()
        defer { try? fm.removeItem(at: temp) }
        let url = temp.appendingPathComponent("entries.zip")
        let writer = try ZipWriter(url: url, limits: .backup)
        let byte = Data([42])
        for n in 0..<ZipLimits.backup.maxEntries { try writer.add(path: "p\(n)", data: byte) }
        #expect(throws: ZipError.tooLarge) { try writer.add(path: "one-too-many", data: byte) }
        try writer.finish()
        #expect(try ZipReader(fileURL: url, limits: .backup).entries.count == ZipLimits.backup.maxEntries)
    }

    @Test(arguments: [-1, Int.max - 1, Int.max]) func extremeRevisionIsRejectedForEachRecord(value: Int) async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: root, catalog: catalog)
        let before = try await seed(store)
        let file = try await export(store, in: parent)
        for field in ["revision", "photos", "items"] {
            let bad = try rewrite(file) { files in
                files["state.json"] = try editJSON(files["state.json"]!) { obj in
                    if field == "revision" { obj[field] = value; return }
                    var records = obj[field] as! [[String: Any]]
                    records[0]["revision"] = value
                    obj[field] = records
                }
            }
            #expect(throws: BackupError.damaged("state")) {
                try BackupArchive.prepare(file: bad, stagingURL: store.makeStagingURL(), catalog: catalog)
            }
        }
        #expect(await store.snapshot() == before)
    }

    @Test func legalRevisionBoundaryRemainsEditable() async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: root, catalog: catalog)
        let seeded = try await seed(store)
        var state = seeded
        state.revision = LibraryStore.maxRevision
        state.photos[0].revision = LibraryStore.maxRevision
        state.items[0].revision = LibraryStore.maxRevision
        try LibraryStore.encodeState(state).write(to: root.appendingPathComponent(LibraryStore.stateFile))
        _ = try await store.load()
        #expect(try await store.rename(instanceId: state.items[0].instanceId, displayName: "椅").revision == 1)
        #expect(try await store.editPhoto(photoId: state.photos[0].photoId, PhotoEdit(note: "改")).revision == 1)
        #expect(try await store.load().revision == 2)
    }

    @Test func corruptLibraryCanBeRecoveredWithoutDiscardingItsFiles() async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let fault = FaultSwitch(nil)
        let store = LibraryStore(root: root, catalog: catalog, fault: fault.handler)
        let seeded = try await seed(store)
        let backup = try await export(store, in: parent)
        for path in [LibraryStore.stateFile, LibraryStore.backupFile] {
            try Data("bad".utf8).write(to: root.appendingPathComponent(path))
        }
        let damaged = contents(root)
        await #expect(throws: StoreError.corruptState) { try await store.load() }
        func prepare() throws -> PreparedLibrary {
            try BackupArchive.prepare(file: backup, stagingURL: store.makeStagingURL(), catalog: catalog)
        }
        try prepare().discard()
        #expect(contents(root) == damaged)
        fault.arm(.swapLibrary)
        let staged = try prepare()
        await #expect(throws: InjectedFault.failed(.swapLibrary)) {
            try await store.replaceLibrary(with: staged, recoveringCorruptLibrary: true)
        }
        #expect(contents(root) == damaged)
        let good = try prepare()
        #expect(try await store.replaceLibrary(with: good, recoveringCorruptLibrary: true) == seeded)
        #expect(try await LibraryStore(root: root, catalog: catalog).load() == seeded)
        #expect(siblings(parent).count == 1)
        let quarantined = try #require(siblings(parent).first)
        #expect(quarantined.hasPrefix("Library.damaged-"))
        #expect(contents(parent.appendingPathComponent(quarantined)) == damaged)
        _ = try await store.clearAll()
        #expect(siblings(parent).isEmpty)
    }

    @Test func recoveryDoesNotOverwriteNewerBackupSchema() async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: root, catalog: catalog)
        _ = try await seed(store)
        let backup = try await export(store, in: parent)
        try Data("bad".utf8).write(to: root.appendingPathComponent(LibraryStore.stateFile))
        try Data("{\"schemaVersion\":9999}".utf8).write(to: root.appendingPathComponent(LibraryStore.backupFile))
        let before = contents(root)
        let reopened = LibraryStore(root: root, catalog: catalog)
        let prepared = try BackupArchive.prepare(file: backup, stagingURL: reopened.makeStagingURL(), catalog: catalog)
        defer { prepared.discard() }
        await #expect(throws: StoreError.newerSchema) {
            try await reopened.replaceLibrary(with: prepared, recoveringCorruptLibrary: true)
        }
        #expect(contents(root) == before)
    }

    @Test(arguments: [StoreStep.deletionBackupCopy, .deletionBackupSync, .deletionBackupRename, .deletionFileRemoval])
    func committedDeletionSurvivesCleanupFaultAndPrimaryDamage(step: StoreStep) async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let fault = FaultSwitch(nil)
        let store = LibraryStore(root: root, catalog: catalog, fault: fault.handler)
        let seeded = try await seed(store)
        let photo = seeded.photos[0]
        fault.arm(step)
        await #expect(throws: StoreError.deletionCleanupPending) { try await store.deletePhoto(photoId: photo.photoId) }
        let after = await store.snapshot()
        #expect(after.photo(id: photo.photoId) == nil)
        try Data("bad".utf8).write(to: root.appendingPathComponent(LibraryStore.stateFile))
        let reopened = LibraryStore(root: root, catalog: catalog)
        #expect(try await reopened.load() == after)
        #expect(await reopened.integrityReport().isClean)
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(photo.originalFile).path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(photo.thumbnailFile).path))
        try Data("bad again".utf8).write(to: root.appendingPathComponent(LibraryStore.stateFile))
        #expect(try await reopened.load() == after)
    }

    @Test func pendingCleanupStillAllowsReadingAndExportButBlocksFurtherWrites() async throws {
        let (parent, root) = sandbox()
        defer { try? fm.removeItem(at: parent) }
        let block: @Sendable (StoreStep) throws -> Void = { step in
            if step == .deletionBackupCopy { throw InjectedFault.failed(step) }
        }
        let store = LibraryStore(root: root, catalog: catalog, fault: block)
        let seeded = try await seed(store)
        await #expect(throws: StoreError.deletionCleanupPending) { try await store.deletePhoto(photoId: seeded.photos[0].photoId) }
        try Data("bad".utf8).write(to: root.appendingPathComponent(LibraryStore.stateFile))
        let reopened = LibraryStore(root: root, catalog: catalog, fault: block)
        let current = try await reopened.load()
        #expect(current.photos.count == seeded.photos.count - 1)
        #expect(await reopened.deletionPending)
        let file = try await export(reopened, in: parent)
        let prepared = try BackupArchive.prepare(file: file, stagingURL: reopened.makeStagingURL(), catalog: catalog)
        defer { prepared.discard() }
        #expect(prepared.state == current)
        await #expect(throws: StoreError.deletionCleanupPending) { try await reopened.setCatName("猫") }
    }

    @Test(arguments: [1, 2]) func fallbackInstallFailureRestoresOldDirectory(failingMove: Int) throws {
        let parent = TestSupport.tempDir()
        defer { try? fm.removeItem(at: parent) }
        let staged = parent.appendingPathComponent("staged"), live = parent.appendingPathComponent("live")
        for dir in [staged, live] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(dir.lastPathComponent.utf8).write(to: dir.appendingPathComponent("id"))
        }
        var count = 0
        #expect(throws: InjectedFault.failed(.swapLibrary)) {
            try LibraryStore.install(staged, at: live, forceFallback: true) { src, dst in
                count += 1
                if count == failingMove { throw InjectedFault.failed(.swapLibrary) }
                try LibraryStore.rename(src, to: dst)
            }
        }
        #expect(try String(contentsOf: live.appendingPathComponent("id"), encoding: .utf8) == "live")
        #expect(try String(contentsOf: staged.appendingPathComponent("id"), encoding: .utf8) == "staged")
    }
}
