import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MeowverseCore

/// Adversarial review probes (data integrity + privacy). The "Defects" section were proven
/// defects (formerly wrapped in known-issue markers); they are fixed and now assert the desired
/// behaviour as regression tests. The "Soundness checks" passed from the start.
@Suite struct AdversarialReviewTests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try TestSupport.catalog() }

    let fm = FileManager.default
    let chairAt44 = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2)
    let stoolAt00 = Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1)
    let tableAt07 = Placement(modelId: "kenney-table", x: 0, z: 7, width: 3, depth: 2)

    func recognition(_ kinds: [FurnitureCategory]) -> RecognitionResult {
        RecognitionResult(analyzer: "test", analyzerRevision: 1,
                          objects: kinds.enumerated().map { ObservedObject(kind: $1, label: $1.rawValue, confidence: 0.9 - Double($0) * 0.1) },
                          catLikely: nil)
    }

    /// The bundled catalog after an "innocuous" edit of one model.
    func catalog(editing id: String, _ edit: (inout [String: Any]) -> Bool) throws -> FurnitureCatalog {
        var root = try #require(JSONSerialization.jsonObject(with: TestSupport.catalogData()) as? [String: Any])
        var models = try #require(root["models"] as? [[String: Any]])
        var out: [[String: Any]] = []
        for var model in models {
            if model["id"] as? String == id {
                if edit(&model) { out.append(model) }
            } else {
                out.append(model)
            }
        }
        models = out
        root["models"] = models
        return try FurnitureCatalog(data: JSONSerialization.data(withJSONObject: root))
    }

    func files(_ root: URL, _ dir: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)) ?? []).sorted()
    }

    // MARK: - Defects

    /// A catalog update that renames/removes or re-categorises ONE model makes the whole
    /// library unopenable when any model-origin source uses that model.
    @Test(arguments: ["removed", "recategorised"])
    func catalogChangeMustNotBrickTheLibrary(change: String) async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let chair = try await store.commitNewFurniture(
            draft: try TestSupport.draft(seed: 900), placement: chairAt44, displayName: "chair",
            decision: SourceDecision(recognition: recognition([.chair]), acceptedObjectIndex: 0))
        #expect(chair.sources[0].origin == .model)
        // One more mutation so the backup contains the chair too.
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 901), placement: stoolAt00,
                                               displayName: "stool", decision: .manual)

        let updated = try catalog(editing: "kenney-chair") { model in
            if change == "removed" { return false }
            model["category"] = "stool"
            return true
        }
        let reopened = LibraryStore(root: root, catalog: updated)
        let state = try await reopened.load()
        #expect(state.items.count == 2)
        #expect(state.photos.count == 2)
        #expect(state.item(id: chair.instanceId)?.sources == chair.sources)
        #expect(await reopened.recoveredFromBackup == false)
    }

    /// Same trigger, worse outcome when the affected item is the newest commit: load() silently
    /// falls back to the backup (item gone, no error), the next save overwrites the only state
    /// that knew the item, and the following launch deletes its original photo as an "orphan".
    @Test func catalogChangeMustNotSilentlyDropItemAndDeleteItsPhoto() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let stool = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 910), placement: stoolAt00,
                                                       displayName: "stool", decision: .manual)
        let chairDraft = try TestSupport.draft(seed: 911)
        let chair = try await store.commitNewFurniture(
            draft: chairDraft, placement: chairAt44, displayName: "chair",
            decision: SourceDecision(recognition: recognition([.chair]), acceptedObjectIndex: 0))
        let chairOriginal = try #require(await store.originalURL(photoId: chair.sources[0].photoId))
        #expect(try Data(contentsOf: chairOriginal) == chairDraft.data)

        let updated = try catalog(editing: "kenney-chair") { $0["category"] = "stool"; return true }

        // Launch 1 after the update: no error is raised, the chair is simply not there.
        let launch1 = LibraryStore(root: root, catalog: updated)
        let state1 = try await launch1.load()
        #expect(state1.item(id: chair.instanceId) != nil)
        // The user does anything at all (moves the stool).
        var moved = stoolAt00; moved.x = 9
        _ = try await launch1.updatePlacement(instanceId: stool.instanceId, placement: moved)

        // Launch 2: the chair's original photo is deleted from disk.
        let launch2 = LibraryStore(root: root, catalog: updated)
        _ = try await launch2.load()
        #expect(fm.fileExists(atPath: chairOriginal.path))
        // Rolling the catalog back does not help any more.
        let rolledBack = LibraryStore(root: root, catalog: catalog)
        let state3 = try await rolledBack.load()
        #expect(state3.item(id: chair.instanceId) != nil)
    }

    /// The stored original got truncated (bit rot / interrupted write). The user re-imports the
    /// very same photo, i.e. hands the store intact bytes. The dedupe path keeps the damaged
    /// blob, throws the good bytes away, and links the new furniture to the damaged original.
    @Test func reimportShouldHealADamagedOriginal() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let draft = try TestSupport.draft(seed: 920)
        let first = try await store.commitNewFurniture(draft: draft, placement: chairAt44, displayName: "a", decision: .manual)
        let photoId = first.sources[0].photoId
        let original = try #require(await store.originalURL(photoId: photoId))
        try draft.data.prefix(draft.data.count / 2).write(to: original)
        #expect(try await store.verifyOriginal(photoId: photoId) == false)

        let second = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 920), placement: tableAt07,
                                                        displayName: "b", decision: .manual)
        #expect(second.sources[0].photoId == photoId)
        let verified = try await store.verifyOriginal(photoId: photoId)
        let onDisk = try Data(contentsOf: original)
        #expect(verified)
        #expect(onDisk == draft.data)
    }

    /// Authentic kill points: the fault hook copies the store directory at the instant the step
    /// finished, which is exactly what the disk holds if the process dies there.
    /// On a store that never had a successful save, the photo's bytes stay on disk for good.
    @Test(arguments: [StoreStep.writeOriginal, .writeThumbnail, .writeState])
    func killDuringFirstEverSaveLeavesNoPhotoBehind(step: StoreStep) async throws {
        let root = TestSupport.tempDir(), frozen = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: frozen) }
        let image = frozen.appendingPathComponent("disk")
        let store = LibraryStore(root: root, catalog: catalog) { reached in
            if reached == step { try FileManager.default.copyItem(at: root, to: image) }
        }
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 930), placement: chairAt44,
                                               displayName: "a", decision: .manual)

        let relaunched = LibraryStore(root: image, catalog: catalog)
        #expect(try await relaunched.load() == .empty)
        #expect(files(image, "originals").isEmpty)
        #expect(files(image, "thumbnails").isEmpty)
        #expect(!fm.fileExists(atPath: image.appendingPathComponent("state.json.tmp").path))
        // A second relaunch does not clean it either.
        let again = LibraryStore(root: image, catalog: catalog)
        _ = try await again.load()
        let orphans = await again.integrityReport().orphanFiles
        #expect(orphans.isEmpty)
    }

    /// After a photo deletion the backup still describes the deleted photo and its furniture,
    /// whose files are gone. If the primary is then unreadable, the removed item comes back
    /// without a readable original.
    @Test func backupAfterPhotoDeletionReferencesDeletedPhoto() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let a = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 940), placement: chairAt44,
                                                   displayName: "a", decision: .manual)
        try await store.deletePhoto(photoId: a.sources[0].photoId)
        #expect(files(root, "originals").isEmpty)
        try Data("{ torn".utf8).write(to: root.appendingPathComponent("state.json"))

        let reopened = LibraryStore(root: root, catalog: catalog)
        let state = try await reopened.load()
        let missing = await reopened.integrityReport().missingOriginals
        // Schema 6: the piece outlives its last photo; the backup must not bring the photo back.
        #expect(state.items.map(\.instanceId) == [a.instanceId] && state.items[0].sources.isEmpty)
        #expect(state.photos.isEmpty)
        #expect(missing.isEmpty)
    }

    // MARK: - Soundness checks (pass today)

    /// Kill at each blob/state step of a commit on a store that already has a committed item:
    /// the earlier item and its original are intact and the half-import is cleaned up.
    @Test(arguments: [StoreStep.writeOriginal, .writeThumbnail, .writeState])
    func killDuringLaterSaveKeepsEarlierItemAndCleansUp(step: StoreStep) async throws {
        let root = TestSupport.tempDir(), frozen = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: frozen) }
        let image = frozen.appendingPathComponent("disk")
        let armed = FaultSwitch(nil)
        let store = LibraryStore(root: root, catalog: catalog) { reached in
            do { try armed.handler(reached) } catch { try FileManager.default.copyItem(at: root, to: image) }
        }
        let firstDraft = try TestSupport.draft(seed: 950)
        let first = try await store.commitNewFurniture(draft: firstDraft, placement: chairAt44, displayName: "a", decision: .manual)
        let committed = await store.snapshot()
        armed.arm(step)
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 951), placement: stoolAt00,
                                               displayName: "b", decision: .manual)

        let relaunched = LibraryStore(root: image, catalog: catalog)
        let state = try await relaunched.load()
        #expect(state == committed)
        let photoId = first.sources[0].photoId
        #expect(try await relaunched.verifyOriginal(photoId: photoId))
        #expect(try Data(contentsOf: try #require(await relaunched.originalURL(photoId: photoId))) == firstDraft.data)
        #expect(await relaunched.integrityReport().isClean)
        // A stale temp state file from the kill does not block the next save.
        _ = try await relaunched.commitNewFurniture(draft: try TestSupport.draft(seed: 952), placement: tableAt07,
                                                    displayName: "c", decision: .manual)
        #expect(!fm.fileExists(atPath: image.appendingPathComponent("state.json.tmp").path))
        #expect(await relaunched.integrityReport().isClean)
    }

    /// Kill after a photo deletion became durable but before its files were deleted.
    @Test func killBetweenPhotoDeletionCommitAndFileDeletion() async throws {
        let root = TestSupport.tempDir(), frozen = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: frozen) }
        let image = frozen.appendingPathComponent("disk")
        let store = LibraryStore(root: root, catalog: catalog)
        let keep = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 960), placement: chairAt44, displayName: "keep", decision: .manual)
        let gone = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 961), placement: stoolAt00, displayName: "gone", decision: .manual)
        try fm.copyItem(at: root, to: image)                       // blobs still present
        try await store.deletePhoto(photoId: gone.sources[0].photoId)
        for name in ["state.json", "state.backup.json"] {          // ...but the new state is durable
            try? fm.removeItem(at: image.appendingPathComponent(name))
            try fm.copyItem(at: root.appendingPathComponent(name), to: image.appendingPathComponent(name))
        }
        let relaunched = LibraryStore(root: image, catalog: catalog)
        let state = try await relaunched.load()
        // Schema 6: "gone" stays in the room without its photo.
        #expect(state.items.map(\.instanceId) == [keep.instanceId, gone.instanceId])
        #expect(state.item(id: gone.instanceId)?.sources == [] && state.photos.count == 1)
        #expect(await relaunched.integrityReport().isClean)
        #expect(files(image, "originals").count == 1)
    }

    /// Real (not injected) I/O errors: an unwritable thumbnails directory, then an unwritable root.
    @Test func realIOErrorsRollBackAndRetryWorks() async throws {
        let root = TestSupport.tempDir()
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("thumbnails").path)
            try? fm.removeItem(at: root)
        }
        let store = LibraryStore(root: root, catalog: catalog)
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 970), placement: chairAt44, displayName: "a", decision: .manual)
        let memory = await store.snapshot()
        let listing = TestSupport.listing(root)
        let stateBytes = TestSupport.bytes(root.appendingPathComponent("state.json"))
        let draft = try TestSupport.draft(seed: 971)

        for locked in [root.appendingPathComponent("thumbnails"), root] {
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
            do {
                _ = try await store.commitNewFurniture(draft: draft, placement: stoolAt00, displayName: "b", decision: .manual)
                Issue.record("commit unexpectedly succeeded")
            } catch {
                let description = String(describing: error)
                if locked == root {
                    // persist() wraps its errors: technical code only.
                    #expect(error is StoreError)
                    #expect(!description.contains(root.path))
                } else {
                    // Blob-step errors are wrapped too: technical code only, no path or file name.
                    #expect(error is StoreError)
                    #expect(!description.contains("thumbnails/"))
                    #expect(!description.contains(root.path))
                }
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            #expect(TestSupport.listing(root) == listing)
            #expect(TestSupport.bytes(root.appendingPathComponent("state.json")) == stateBytes)
            #expect(await store.snapshot() == memory)
        }
        _ = try await store.commitNewFurniture(draft: draft, placement: stoolAt00, displayName: "b", decision: .manual)
        #expect(await store.integrityReport().isClean)
    }

    /// Rollback itself fails (the blob cannot be deleted): state stays intact, retry reuses the
    /// leftover blob, nothing is duplicated.
    @Test func failureDuringRollbackStillLeavesAConsistentStore() async throws {
        let root = TestSupport.tempDir()
        let originals = root.appendingPathComponent("originals")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: originals.path)
            try? fm.removeItem(at: root)
        }
        let armed = FaultSwitch(nil)
        let store = LibraryStore(root: root, catalog: catalog) { reached in
            do { try armed.handler(reached) } catch {
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: originals.path)
                throw error
            }
        }
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 980), placement: chairAt44, displayName: "a", decision: .manual)
        let memory = await store.snapshot()
        let draft = try TestSupport.draft(seed: 981)
        armed.arm(.writeOriginal)
        await #expect(throws: InjectedFault.failed(.writeOriginal)) {
            try await store.commitNewFurniture(draft: draft, placement: stoolAt00, displayName: "b", decision: .manual)
        }
        #expect(files(root, "originals").count == 2, "rollback could not delete the new blob")
        #expect(await store.snapshot() == memory)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: originals.path)

        let item = try await store.commitNewFurniture(draft: draft, placement: stoolAt00, displayName: "b", decision: .manual)
        #expect(try await store.verifyOriginal(photoId: item.sources[0].photoId))
        #expect(await store.integrityReport().isClean)
        let reopened = LibraryStore(root: root, catalog: catalog)
        #expect(try await reopened.load().items.count == 2)
    }

    /// Thumbnails must not carry GPS / capture metadata of the original.
    @Test func thumbnailCarriesNoGPSOrExifFromOriginal() throws {
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        let props: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 38.9897, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 76.9378, kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:03:15 10:00:00",
                                             kCGImagePropertyExifLensModel: "secret lens"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SecretMake", kCGImagePropertyTIFFModel: "SecretModel"],
        ]
        CGImageDestinationAddImage(dest, TestSupport.cgImage(width: 800, height: 600, seed: 5), props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let data = out as Data

        // The fixture really has GPS.
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let sourceProps = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(sourceProps[kCGImagePropertyGPSDictionary] != nil)

        let draft = try PhotoIngest.makeDraft(data: data, filename: nil)
        #expect(draft.captureDate == "2024-03-15")
        let thumb = try #require(CGImageSourceCreateWithData(draft.thumbnailJPEG as CFData, nil))
        let thumbProps = try #require(CGImageSourceCopyPropertiesAtIndex(thumb, 0, nil) as? [CFString: Any])
        #expect(thumbProps[kCGImagePropertyGPSDictionary] == nil)
        let exif = thumbProps[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
        #expect(exif?[kCGImagePropertyExifLensModel] == nil)
        let tiff = thumbProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
        for needle in ["SecretMake", "SecretModel", "secret lens", "2024:03:15"] {
            #expect(draft.thumbnailJPEG.range(of: Data(needle.utf8)) == nil, "thumbnail bytes contain \(needle)")
        }
    }

    /// Dates only ever come from EXIF DateTimeOriginal: not TIFF DateTime, not the digitized
    /// date, not the filename.
    @Test func captureDateIsNeverTakenFromOtherFields() throws {
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeDigitized: "2021:05:06 10:00:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: "2022:07:08 10:00:00"],
        ]
        CGImageDestinationAddImage(dest, TestSupport.cgImage(width: 64, height: 32, seed: 6), props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let draft = try PhotoIngest.makeDraft(data: out as Data, filename: "2020-01-02 12.00.00.jpg")
        #expect(draft.captureDate == nil)
        #expect(draft.captureDateSource == .unknown)
    }

    /// Random walks over the review state machine as the app drives it (one analysis per
    /// session): a manual choice is never changed by a result, and an accepted index always
    /// names an object of the selected category.
    @Test func reviewInvariantsUnderRandomInterleavings() {
        var rng = SystemRandomNumberGenerator()
        let kinds = FurnitureCategory.allCases
        for _ in 0..<5000 {
            var review = CandidateReview()
            let token = review.beginAnalysis()
            let staleToken = UUID()
            var delivered = false
            var lastManual: FurnitureCategory?? = nil   // .some(x) once the user decided (x may be nil = cleared)
            for _ in 0..<12 {
                switch Int.random(in: 0..<7, using: &rng) {
                case 0:
                    let pick = kinds.randomElement(using: &rng)!
                    review.chooseManually(pick); lastManual = .some(pick)
                case 1:
                    review.clearSelection(); lastManual = .some(nil)
                case 2:
                    let before = review
                    review.acceptSuggestion(objectIndex: Int.random(in: -1...4, using: &rng))
                    if review != before { lastManual = nil }
                case 3:
                    review.receive(recognition(Array(kinds.shuffled(using: &rng).prefix(Int.random(in: 0...3, using: &rng)))), token: staleToken)
                case 4:
                    review.receive(nil, token: staleToken)
                default:
                    let userChoiceBefore = review.selectedCategory
                    let wasUser = review.selectionOrigin == .user
                    let wasDelivered = delivered
                    let before = review
                    if Bool.random(using: &rng) {
                        review.receive(recognition(Array(kinds.shuffled(using: &rng).prefix(Int.random(in: 0...3, using: &rng)))), token: token)
                    } else {
                        review.receive(nil, token: token)
                    }
                    delivered = true
                    if wasDelivered { #expect(review == before, "a second delivery is ignored") }
                    if wasUser {
                        #expect(review.selectionOrigin == .user)
                        #expect(review.selectedCategory == userChoiceBefore)
                    }
                }
                if case .some(let manual) = lastManual {
                    #expect(review.selectionOrigin == .user)
                    #expect(review.selectedCategory == manual)
                    #expect(review.sourceDecision.acceptedObjectIndex == nil)
                }
                let decision = review.sourceDecision
                if let index = decision.acceptedObjectIndex {
                    #expect(decision.recognition?.objects.indices.contains(index) == true)
                    #expect(decision.recognition?.objects[index].kind == review.selectedCategory)
                }
            }
        }
    }

    /// Latent (not reachable from the app today, which starts one analysis per session):
    /// restarting analysis keeps a stale accepted index that then points into a different result.
    @Test func restartedAnalysisKeepsStaleAcceptedIndex() {
        var review = CandidateReview()
        let first = review.beginAnalysis()
        review.receive(recognition([.sofa, .table]), token: first)
        review.acceptSuggestion(objectIndex: 1)                     // user accepts "table"
        let second = review.beginAnalysis()
        // Restarting drops the suggestion (it indexed the old result); the new top one is preselected.
        #expect(review.selectionOrigin == .none && review.selectedCategory == nil)
        review.receive(recognition([.chair, .table, .bed]), token: second)
        #expect(review.selectedCategory == .chair && review.selectionOrigin == .suggested(objectIndex: 0))
        review.acceptSuggestion(objectIndex: 1)
        let third = review.beginAnalysis()
        review.receive(recognition([.table, .bed]), token: third)   // index 1 is now "bed"
        let decision = review.sourceDecision
        #expect(decision.recognition?.objects[decision.acceptedObjectIndex ?? 0].kind == review.selectedCategory)

        // A user's own choice survives a restart untouched.
        review.chooseManually(.sofa)
        let fourth = review.beginAnalysis()
        #expect(review.selectionOrigin == .user && review.selectedCategory == .sofa)
        review.receive(recognition([.bed]), token: fourth)
        #expect(review.selectionOrigin == .user && review.selectedCategory == .sofa)
        #expect(review.sourceDecision.acceptedObjectIndex == nil)
    }
}
