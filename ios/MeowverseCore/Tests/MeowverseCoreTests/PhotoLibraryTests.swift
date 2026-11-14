import Foundation
import Testing
@testable import MeowverseCore

/// Photo library: unlinked photos, per-photo edits, the delete cascade, and the v1 -> v2 schema.
@Suite struct PhotoLibraryTests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try TestSupport.catalog() }

    let fm = FileManager.default
    let chairAt44 = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2)
    let stoolAt00 = Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1)

    func files(_ root: URL, _ dir: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)) ?? []).sorted()
    }

    func exifDraft(seed: Int, day: String = "2026:03:14 09:26:53") throws -> ImportDraft {
        try PhotoIngest.makeDraft(data: TestSupport.imageData(seed: seed, dateTimeOriginal: day), filename: nil)
    }

    func editJSON(_ fileURL: URL, _ edit: (inout [String: Any]) -> Void) throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        edit(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)
    }

    // MARK: - Schema

    /// A state.json exactly as version 1 wrote it: no favorite / note / exifCaptureDate keys.
    @Test func version1FileLoadsWithDefaultsAndIsRewrittenAsCurrentVersion() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let seedStore = LibraryStore(root: root, catalog: catalog)
        let exif = try await seedStore.commitNewFurniture(draft: try exifDraft(seed: 1), placement: chairAt44, displayName: "a", decision: .manual)
        let plain = try await seedStore.commitNewFurniture(draft: try TestSupport.draft(seed: 2), placement: stoolAt00, displayName: "b", decision: .manual)
        for name in ["state.json", "state.backup.json"] {
            try editJSON(root.appendingPathComponent(name)) { object in
                object["schemaVersion"] = 1
                object["photos"] = (object["photos"] as! [[String: Any]]).map { photo in
                    var photo = photo
                    for key in ["favorite", "note", "exifCaptureDate"] { photo.removeValue(forKey: key) }
                    if photo["captureDate"] is NSNull { photo.removeValue(forKey: "captureDate") }
                    return photo
                }
            }
        }
        let v1Bytes = try Data(contentsOf: root.appendingPathComponent("state.json"))

        let store = LibraryStore(root: root, catalog: catalog)
        let state = try await store.load()
        #expect(state.schemaVersion == AppState.currentSchemaVersion)
        #expect(state.items.map(\.instanceId) == [exif.instanceId, plain.instanceId])
        let exifPhoto = try #require(state.photo(id: exif.sources[0].photoId))
        #expect(exifPhoto.captureDate == "2026-03-14" && exifPhoto.captureDateSource == .exif)
        #expect(exifPhoto.exifCaptureDate == "2026-03-14", "the EXIF day of a v1 record is carried over")
        #expect(exifPhoto.favorite == false && exifPhoto.note == "")
        let plainPhoto = try #require(state.photo(id: plain.sources[0].photoId))
        #expect(plainPhoto.captureDate == nil && plainPhoto.captureDateSource == .unknown && plainPhoto.exifCaptureDate == nil)
        // Loading alone writes nothing.
        #expect(try Data(contentsOf: root.appendingPathComponent("state.json")) == v1Bytes)
        #expect(await store.integrityReport().isClean)

        // The first mutation writes the current version, and it reloads identically.
        _ = try await store.editPhoto(photoId: exifPhoto.photoId, PhotoEdit(favorite: true))
        let json = try #require(String(data: Data(contentsOf: root.appendingPathComponent("state.json")), encoding: .utf8))
        #expect(json.contains("\"schemaVersion\":\(AppState.currentSchemaVersion)"))
        #expect(json.contains("\"exifCaptureDate\":\"2026-03-14\""))
        #expect(json.contains("\"exifCaptureDate\":null"))
        let reopened = LibraryStore(root: root, catalog: catalog)
        #expect(try await reopened.load() == (await store.snapshot()))
    }

    /// A v1 primary that is torn falls back to a v1 backup.
    @Test func version1BackupIsStillAValidFallback() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let seedStore = LibraryStore(root: root, catalog: catalog)
        let a = try await seedStore.commitNewFurniture(draft: try TestSupport.draft(seed: 3), placement: chairAt44, displayName: "a", decision: .manual)
        _ = try await seedStore.commitNewFurniture(draft: try TestSupport.draft(seed: 4), placement: stoolAt00, displayName: "b", decision: .manual)
        try editJSON(root.appendingPathComponent("state.backup.json")) { object in
            object["schemaVersion"] = 1
            object["photos"] = (object["photos"] as! [[String: Any]]).map { photo in
                var photo = photo
                for key in ["favorite", "note", "exifCaptureDate", "captureDate"] { photo.removeValue(forKey: key) }
                return photo
            }
        }
        try Data("{ torn".utf8).write(to: root.appendingPathComponent("state.json"))
        let store = LibraryStore(root: root, catalog: catalog)
        let state = try await store.load()
        #expect(await store.recoveredFromBackup)
        #expect(state.items.map(\.instanceId) == [a.instanceId])
        #expect(state.schemaVersion == AppState.currentSchemaVersion)
    }

    @Test func schemaVersionZeroIsNotAccepted() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let seedStore = LibraryStore(root: root, catalog: catalog)
        _ = try await seedStore.addPhoto(draft: try TestSupport.draft(seed: 5))
        try editJSON(root.appendingPathComponent("state.json")) { $0["schemaVersion"] = 0 }
        let store = LibraryStore(root: root, catalog: catalog)
        await #expect(throws: StoreError.corruptState) { try await store.load() }
    }

    // MARK: - Photos without furniture

    @Test func batchReportsOnlyNewPhotosAndSkippingAnUnchangedPhotoRemovesItsFiles() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let draft = try TestSupport.draft(seed: 160)
        let first = try await store.importPhoto(draft: draft)
        let duplicate = try await store.importPhoto(draft: draft)
        #expect(first.inserted && !duplicate.inserted)
        #expect(duplicate.photo == first.photo)
        try await store.discardBatchPhoto(photoId: first.photo.photoId, ifUnchangedSince: first.photo.revision)
        try await store.discardBatchPhoto(photoId: first.photo.photoId, ifUnchangedSince: first.photo.revision)
        #expect(await store.snapshot().photos.isEmpty)
        #expect(files(root, "originals").isEmpty && files(root, "thumbnails").isEmpty)
    }

    @Test func skippingPreservesUserEditsAndLinksIncludingStoredFurniture() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let draft = try TestSupport.draft(seed: 161)
        let photo = try await store.addPhoto(draft: draft)
        let edited = try await store.editPhoto(photoId: photo.photoId, PhotoEdit(favorite: true, note: "keep", captureDate: .set("2026-03-02")))
        try await store.discardBatchPhoto(photoId: photo.photoId, ifUnchangedSince: photo.revision)
        #expect(await store.snapshot().photo(id: photo.photoId) == edited)

        let linkedDraft = try TestSupport.draft(seed: 162)
        let linked = try await store.addPhoto(draft: linkedDraft)
        let chair = try await store.commitNewFurniture(draft: linkedDraft, placement: chairAt44, displayName: "chair", decision: .manual)
        _ = try await store.stowFurniture(instanceId: chair.instanceId)
        try await store.discardBatchPhoto(photoId: linked.photoId, ifUnchangedSince: linked.revision)
        #expect(await store.snapshot().photo(id: linked.photoId) == linked)
        #expect(await store.snapshot().storage.first?.sources.first?.photoId == linked.photoId)
    }

    @Test func photoOnlyImportIsUnlinkedAndSurvivesReopen() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let draft = try exifDraft(seed: 10)
        let photo = try await store.addPhoto(draft: draft)
        #expect(photo.captureDate == "2026-03-14" && photo.exifCaptureDate == "2026-03-14")
        let state = await store.snapshot()
        #expect(state.items.isEmpty && state.photos == [photo] && state.revision == 1)
        #expect(state.furniture(containing: photo.photoId).isEmpty)
        #expect(try Data(contentsOf: try #require(await store.originalURL(photoId: photo.photoId))) == draft.data)

        // The same bytes again: one record, no new write.
        let again = try await store.addPhoto(draft: try exifDraft(seed: 10))
        #expect(again == photo)
        #expect(await store.snapshot().revision == 1)
        #expect(files(root, "originals").count == 1)

        // An unlinked photo is not an orphan: reopening keeps both of its files.
        let reopened = LibraryStore(root: root, catalog: catalog)
        #expect(try await reopened.load() == state)
        #expect(files(root, "originals").count == 1 && files(root, "thumbnails").count == 1)
        #expect(await reopened.integrityReport().isClean)
    }

    @Test func unlinkedPhotoBecomesFurnitureOrJoinsOneWithoutASecondCopy() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let draft = try TestSupport.draft(seed: 11)
        let photo = try await store.addPhoto(draft: draft)

        // Turn it into furniture: the import flow commits the same bytes again.
        let chair = try await store.commitNewFurniture(draft: draft, placement: chairAt44, displayName: "椅", decision: .manual)
        #expect(chair.sources.map(\.photoId) == [photo.photoId])
        // Attach it to another existing piece by id (photo detail) ...
        let stool = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 12), placement: stoolAt00, displayName: "凳", decision: .manual)
        let linked = try await store.linkPhoto(photoId: photo.photoId, toInstance: stool.instanceId)
        #expect(linked.sources.map(\.photoId) == [stool.sources[0].photoId, photo.photoId])
        #expect(linked.sources[1].untimed == .manual(photoId: photo.photoId))
        #expect(linked.revision == stool.revision + 1)
        await #expect(throws: StoreError.duplicateSource) { try await store.linkPhoto(photoId: photo.photoId, toInstance: stool.instanceId) }
        await #expect(throws: StoreError.unknownPhoto) { try await store.linkPhoto(photoId: "nope", toInstance: stool.instanceId) }
        await #expect(throws: StoreError.unknownInstance) { try await store.linkPhoto(photoId: photo.photoId, toInstance: "nope") }

        let state = await store.snapshot()
        #expect(state.photos.count == 2)
        #expect(files(root, "originals").count == 2)
        #expect(state.furniture(containing: photo.photoId).map(\.instanceId) == [chair.instanceId, stool.instanceId])
        #expect(await store.integrityReport().isClean)
    }

    /// The path the UI takes for "再添一张照片" and "放进已有的家具".
    @Test func addSourceFromDraftsLinksStoredAndNewPhotosOnce() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let chair = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 20), placement: chairAt44, displayName: "椅", decision: .manual)
        let stored = try await store.addPhoto(draft: try TestSupport.draft(seed: 21))

        // Several picked at once: an already-stored photo, a new one, and one that is already a source.
        var added = 0, duplicates = 0
        for seed in [21, 22, 20] {
            do {
                _ = try await store.addSource(draft: try TestSupport.draft(seed: seed), toInstance: chair.instanceId, decision: .manual)
                added += 1
            } catch StoreError.duplicateSource {
                duplicates += 1
            }
        }
        #expect(added == 2 && duplicates == 1)
        let state = await store.snapshot()
        let item = try #require(state.item(id: chair.instanceId))
        #expect(item.sources.count == 3)
        #expect(item.sources[1].photoId == stored.photoId, "the stored photo is reused, not copied")
        #expect(state.photos.count == 3 && files(root, "originals").count == 3)
        #expect(await store.integrityReport().isClean)
    }

    // MARK: - Removing furniture keeps photos

    @Test func removingFurnitureLeavesItsPhotosUnlinked() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let recognition = RecognitionResult(analyzer: "test", analyzerRevision: 1,
                                            objects: [ObservedObject(kind: .chair, label: "chair", confidence: 0.9)], catLikely: nil)
        let draft = try TestSupport.draft(seed: 30)
        let chair = try await store.commitNewFurniture(draft: draft, placement: chairAt44, displayName: "椅",
                                                       decision: SourceDecision(recognition: recognition, acceptedObjectIndex: 0))
        let photoId = chair.sources[0].photoId
        try await store.removeFurniture(instanceId: chair.instanceId)

        let state = await store.snapshot()
        #expect(state.items.isEmpty)
        #expect(state.photos.map(\.photoId) == [photoId])
        #expect(state.observations.count == 1, "what was seen in the photo stays with the photo")
        #expect(try await store.verifyOriginal(photoId: photoId))
        #expect(files(root, "originals").count == 1 && files(root, "thumbnails").count == 1)
        let reopened = LibraryStore(root: root, catalog: catalog)
        #expect(try await reopened.load() == state)
        #expect(files(root, "originals").count == 1)
        #expect(await reopened.integrityReport().isClean)
    }

    // MARK: - Editing

    @Test func favouriteAndNoteArePersistedAndBumpRevisions() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let photo = try await store.addPhoto(draft: try TestSupport.draft(seed: 40))
        let originalBytes = try Data(contentsOf: try #require(await store.originalURL(photoId: photo.photoId)))

        let edited = try await store.editPhoto(photoId: photo.photoId, PhotoEdit(favorite: true, note: "窗边晒太阳 ☀️"))
        #expect(edited.favorite && edited.note == "窗边晒太阳 ☀️" && edited.revision == photo.revision + 1)
        #expect(await store.snapshot().revision == 2)

        // Nothing changed: nothing written.
        let same = try await store.editPhoto(photoId: photo.photoId, PhotoEdit(favorite: true, note: "窗边晒太阳 ☀️"))
        #expect(same == edited)
        #expect(await store.snapshot().revision == 2)

        let limit = String(repeating: "喵", count: LibraryStore.maxNoteLength)
        #expect(try await store.editPhoto(photoId: photo.photoId, PhotoEdit(note: limit)).note == limit)
        await #expect(throws: StoreError.noteTooLong) { try await store.editPhoto(photoId: photo.photoId, PhotoEdit(note: limit + "喵")) }
        await #expect(throws: StoreError.unknownPhoto) { try await store.editPhoto(photoId: "nope", PhotoEdit(favorite: true)) }
        #expect(await store.snapshot().photo(id: photo.photoId)?.note == limit)

        let reopened = LibraryStore(root: root, catalog: catalog)
        let state = try await reopened.load()
        #expect(state.photo(id: photo.photoId)?.favorite == true)
        #expect(state.photo(id: photo.photoId)?.note == limit)
        #expect(state.photo(id: photo.photoId)?.importedAt == photo.importedAt)
        #expect(try Data(contentsOf: try #require(await reopened.originalURL(photoId: photo.photoId))) == originalBytes)
        #expect(try await reopened.verifyOriginal(photoId: photo.photoId))
    }

    @Test func userDateOverridesExifAndClearingRestoresIt() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let photo = try await store.addPhoto(draft: try exifDraft(seed: 50))

        let set = try await store.editPhoto(photoId: photo.photoId, PhotoEdit(captureDate: .set("2025-12-24")))
        #expect(set.captureDate == "2025-12-24" && set.captureDateSource == .user)
        #expect(set.exifCaptureDate == "2026-03-14", "the EXIF day is kept beside the user's")

        // Survives a reopen with the EXIF value intact.
        let reopened = LibraryStore(root: root, catalog: catalog)
        let loaded = try #require(try await reopened.load().photo(id: photo.photoId))
        #expect(loaded == set)

        // Choosing the very day the file carries is still the user's statement.
        let sameDay = try await reopened.editPhoto(photoId: photo.photoId, PhotoEdit(captureDate: .set("2026-03-14")))
        #expect(sameDay.captureDateSource == .user && sameDay.captureDate == "2026-03-14")

        let cleared = try await reopened.editPhoto(photoId: photo.photoId, PhotoEdit(captureDate: .clear))
        #expect(cleared.captureDate == "2026-03-14" && cleared.captureDateSource == .exif)
        #expect(cleared.exifCaptureDate == "2026-03-14")
        // Clearing again changes nothing and writes nothing.
        let revision = await reopened.snapshot().revision
        #expect(try await reopened.editPhoto(photoId: photo.photoId, PhotoEdit(captureDate: .clear)) == cleared)
        #expect(await reopened.snapshot().revision == revision)
    }

    @Test func clearingAUserDateWithoutExifGoesBackToUnknown() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let photo = try await store.addPhoto(draft: try TestSupport.draft(seed: 51))
        #expect(photo.captureDate == nil && photo.captureDateSource == .unknown)

        let set = try await store.editPhoto(photoId: photo.photoId, PhotoEdit(captureDate: .set("2024-02-29")))
        #expect(set.captureDate == "2024-02-29" && set.captureDateSource == .user && set.exifCaptureDate == nil)
        let cleared = try await store.editPhoto(photoId: photo.photoId, PhotoEdit(captureDate: .clear))
        #expect(cleared.captureDate == nil && cleared.captureDateSource == .unknown && cleared.exifCaptureDate == nil)
    }

    @Test(arguments: ["2025-02-30", "2025-13-01", "20250101", "2025-1-1", "0000-01-01", "", "2025-02-28 10:00:00", "昨天"])
    func invalidDatesAreRejectedWithoutWriting(day: String) async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let photo = try await store.addPhoto(draft: try exifDraft(seed: 52))
        await #expect(throws: StoreError.invalidDate) { try await store.editPhoto(photoId: photo.photoId, PhotoEdit(favorite: true, captureDate: .set(day))) }
        #expect(await store.snapshot().photos == [photo], "a rejected edit applies none of its parts")
    }

    /// Re-importing the same bytes must not undo what the user said about the photo.
    @Test func reimportKeepsUserEdits() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let photo = try await store.addPhoto(draft: try exifDraft(seed: 53))
        let edited = try await store.editPhoto(photoId: photo.photoId, PhotoEdit(favorite: true, note: "n", captureDate: .set("2020-01-02")))
        _ = try await store.addPhoto(draft: try exifDraft(seed: 53))
        let chair = try await store.commitNewFurniture(draft: try exifDraft(seed: 53), placement: chairAt44, displayName: "椅", decision: .manual)
        #expect(chair.sources[0].photoId == photo.photoId)
        #expect(await store.snapshot().photo(id: photo.photoId) == edited)
    }

    // MARK: - Deleting a photo

    // Schema 6 rule: a photo never takes furniture with it (the web cascade removed `only`).
    @Test func deletingAPhotoUnlinksItAndKeepsEveryPiece() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let recognition = RecognitionResult(analyzer: "test", analyzerRevision: 1,
                                            objects: [ObservedObject(kind: .chair, label: "chair", confidence: 0.9)], catLikely: nil)
        let shared = try TestSupport.draft(seed: 60)
        // `only` has just the shared photo; `multi` has the shared photo and one more; `other` is unrelated.
        let only = try await store.commitNewFurniture(draft: shared, placement: chairAt44, displayName: "only",
                                                      decision: SourceDecision(recognition: recognition, acceptedObjectIndex: 0))
        let multi0 = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 61), placement: stoolAt00, displayName: "multi", decision: .manual)
        let multi = try await store.addSource(draft: shared, toInstance: multi0.instanceId, decision: .manual)
        let other = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 62),
                                                       placement: Placement(modelId: "kenney-table", x: 0, z: 7, width: 3, depth: 2),
                                                       displayName: "other", decision: .manual)
        let sharedId = only.sources[0].photoId
        let before = await store.snapshot()

        let impact = before.deletionImpact(photoId: sharedId)
        #expect(impact.furnitureToUpdate.map(\.instanceId) == [only.instanceId, multi.instanceId])
        #expect(before.deletionImpact(photoId: "nope") == PhotoDeletionImpact(furnitureToUpdate: []))
        #expect(await store.snapshot() == before, "the preview changes nothing")

        try await store.deletePhoto(photoId: sharedId)
        let state = await store.snapshot()
        #expect(state.items.map(\.instanceId) == [only.instanceId, multi.instanceId, other.instanceId])
        let emptied = try #require(state.item(id: only.instanceId))
        #expect(emptied.sources.isEmpty, "its last photo is gone; the piece stays where it was")
        #expect(emptied.placement == only.placement && emptied.revision == only.revision + 1)
        #expect(state.photo(id: sharedId) == nil)
        #expect(state.observations.isEmpty)
        let kept = try #require(state.item(id: multi.instanceId))
        #expect(kept.sources.map(\.photoId) == [multi0.sources[0].photoId])
        #expect(kept.revision == multi.revision + 1)
        #expect(state.item(id: other.instanceId) == other)
        #expect(files(root, "originals").count == 2 && files(root, "thumbnails").count == 2)
        #expect(!files(root, "originals").contains { $0.hasPrefix(shared.sha256) })
        #expect(await store.integrityReport().isClean)
        await #expect(throws: StoreError.unknownPhoto) { try await store.deletePhoto(photoId: sharedId) }

        // The backup no longer describes the deleted photo either.
        try Data("{ torn".utf8).write(to: root.appendingPathComponent("state.json"))
        let reopened = LibraryStore(root: root, catalog: catalog)
        let recovered = try await reopened.load()
        #expect(recovered.photo(id: sharedId) == nil)
        #expect(await reopened.integrityReport().isClean)
    }

    @Test func deletingAnUnlinkedPhotoRemovesOnlyItsOwnFiles() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let keep = try await store.addPhoto(draft: try TestSupport.draft(seed: 70))
        let gone = try await store.addPhoto(draft: try TestSupport.draft(seed: 71))
        try await store.deletePhoto(photoId: gone.photoId)
        #expect(await store.snapshot().photos == [keep])
        #expect(files(root, "originals") == [String(keep.originalFile.dropFirst("originals/".count))])
        #expect(files(root, "thumbnails") == ["\(keep.photoId).jpg"])
        #expect(try await store.verifyOriginal(photoId: keep.photoId))
    }

    // MARK: - Failed saves

    @Test func failedSavesLeaveMemoryAndDiskUnchangedAndRetryWorks() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let fault = FaultSwitch(nil)
        let store = LibraryStore(root: root, catalog: catalog, fault: fault.handler)
        let chair = try await store.commitNewFurniture(draft: try exifDraft(seed: 80), placement: chairAt44, displayName: "椅", decision: .manual)
        let spare = try await store.addPhoto(draft: try TestSupport.draft(seed: 81))
        let photoId = chair.sources[0].photoId
        let stateBytes = TestSupport.bytes(root.appendingPathComponent("state.json"))
        let listing = TestSupport.listing(root)
        let memory = await store.snapshot()
        let unlinkedDraft = try TestSupport.draft(seed: 82)

        func expectUnchanged(_ what: String) async {
            #expect(TestSupport.bytes(root.appendingPathComponent("state.json")) == stateBytes, "\(what): state.json")
            #expect(TestSupport.listing(root) == listing, "\(what): files")
            #expect(await store.snapshot() == memory, "\(what): memory")
        }

        fault.arm(.writeState)
        await #expect(throws: InjectedFault.failed(.writeState)) { try await store.editPhoto(photoId: photoId, PhotoEdit(favorite: true, note: "x", captureDate: .set("2020-01-01"))) }
        await expectUnchanged("edit")
        fault.arm(.writeState)
        await #expect(throws: InjectedFault.failed(.writeState)) { try await store.deletePhoto(photoId: photoId) }
        await expectUnchanged("delete")
        fault.arm(.writeState)
        await #expect(throws: InjectedFault.failed(.writeState)) { try await store.linkPhoto(photoId: spare.photoId, toInstance: chair.instanceId) }
        await expectUnchanged("link")
        for step in [StoreStep.writeOriginal, .writeThumbnail, .writeState] {
            fault.arm(step)
            await #expect(throws: InjectedFault.failed(step)) { try await store.addPhoto(draft: unlinkedDraft) }
            await expectUnchanged("addPhoto at \(step)")
        }
        fault.arm(.writeState)
        await #expect(throws: InjectedFault.failed(.writeState)) { try await store.removeFurniture(instanceId: chair.instanceId) }
        await expectUnchanged("remove")

        // Every one of them works on retry.
        _ = try await store.editPhoto(photoId: photoId, PhotoEdit(favorite: true, note: "x", captureDate: .set("2020-01-01")))
        _ = try await store.linkPhoto(photoId: spare.photoId, toInstance: chair.instanceId)
        _ = try await store.addPhoto(draft: unlinkedDraft)
        try await store.deletePhoto(photoId: photoId)
        #expect(await store.snapshot().item(id: chair.instanceId)?.sources.map(\.photoId) == [spare.photoId])
        #expect(await store.integrityReport().isClean)
        let reopened = LibraryStore(root: root, catalog: catalog)
        #expect(try await reopened.load() == (await store.snapshot()))
    }

    // MARK: - Library sections

    @Test func sectionsGroupByCaptureMonthNewestFirstWithUnknownLast() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let march14 = try await store.addPhoto(draft: try exifDraft(seed: 90, day: "2026:03:14 10:00:00"))
        let march02 = try await store.addPhoto(draft: try exifDraft(seed: 91, day: "2026:03:02 10:00:00"))
        let lastYear = try await store.addPhoto(draft: try exifDraft(seed: 92, day: "2025:11:30 10:00:00"))
        // The filename looks like a date; it must never be used as one.
        let unknown = try await store.addPhoto(draft: try PhotoIngest.makeDraft(data: TestSupport.imageData(seed: 93), filename: "IMG_20240101_120000.jpg"))
        let chair = try await store.commitNewFurniture(draft: try exifDraft(seed: 90, day: "2026:03:14 10:00:00"), placement: chairAt44, displayName: "椅", decision: .manual)
        #expect(chair.sources[0].photoId == march14.photoId)
        _ = try await store.editPhoto(photoId: lastYear.photoId, PhotoEdit(favorite: true))
        var state = await store.snapshot()

        let all = PhotoLibrary.sections(in: state, filter: .all)
        #expect(all.map(\.month) == ["2026-03", "2025-11", nil])
        #expect(all.map { $0.photos.map(\.photoId) } == [[march14.photoId, march02.photoId], [lastYear.photoId], [unknown.photoId]])
        #expect(PhotoLibrary.sections(in: state, filter: .favorites).map { $0.photos.map(\.photoId) } == [[lastYear.photoId]])
        #expect(PhotoLibrary.sections(in: state, filter: .unlinked).map { $0.photos.map(\.photoId) }
                == [[march02.photoId], [lastYear.photoId], [unknown.photoId]])
        #expect(PhotoLibrary.count(in: state, filter: .unlinked) == 3)

        // A user date moves the photo into that month; clearing it returns it to "unknown".
        _ = try await store.editPhoto(photoId: unknown.photoId, PhotoEdit(captureDate: .set("2026-03-20")))
        state = await store.snapshot()
        #expect(PhotoLibrary.sections(in: state, filter: .all).first?.photos.map(\.photoId) == [unknown.photoId, march14.photoId, march02.photoId])
        _ = try await store.editPhoto(photoId: unknown.photoId, PhotoEdit(captureDate: .clear))
        state = await store.snapshot()
        #expect(PhotoLibrary.sections(in: state, filter: .all).last?.month == nil)
        #expect(PhotoLibrary.sections(in: .empty, filter: .all).isEmpty)
    }

    @Test func dayValidation() {
        #expect(PhotoLibrary.isValidDay("2024-02-29"))
        #expect(!PhotoLibrary.isValidDay("2023-02-29"))
        #expect(!PhotoLibrary.isValidDay("2024-2-29"))
        #expect(!PhotoLibrary.isValidDay("2024-02-29T00:00:00Z"))
    }
}

/// The link index and the room / cat accessors (docs/IOS_LIBRARY_MODEL.md).
@Suite struct LibraryIndexTests {
    private func photo(_ id: String) -> PhotoRecord {
        PhotoRecord(photoId: id, filename: nil, sha256: id, mimeType: "image/jpeg", byteSize: 1, width: 1, height: 1,
                    originalFile: "originals/\(id).jpeg", thumbnailFile: "thumbnails/\(id).jpg", captureDate: nil,
                    captureDateSource: .unknown, exifCaptureDate: nil, importedAt: Date(timeIntervalSince1970: 0), revision: 1)
    }

    private func piece(_ id: String, _ sources: [PhotoCarrierSource]) -> PhotoFurniture {
        PhotoFurniture(instanceId: id, modelId: "kenney-chair", x: 0, z: 0, width: 2, depth: 2, turn: 0, finish: .original,
                       displayName: id, sources: sources, tags: [], revision: 1)
    }

    private var state: AppState {
        let early = Date(timeIntervalSince1970: 100), late = Date(timeIntervalSince1970: 200)
        return AppState(revision: 1, photos: [photo("a"), photo("b"), photo("c")], observations: [],
                        items: [piece("chair", [.manual(photoId: "a", addedAt: early), .manual(photoId: "b", addedAt: late)])],
                        storage: [piece("bed", [.manual(photoId: "b")]), piece("empty", [])])
    }

    @Test func bothDirectionsOfTheLink() {
        let index = LibraryIndex(state: state)
        #expect(index.furniture(ofPhoto: "b").map(\.instanceId) == ["chair", "bed"])
        #expect(index.furniture(ofPhoto: "c") == [])
        #expect(index.photos(ofFurniture: "chair").map(\.photoId) == ["a", "b"])
        #expect(index.linkCount(ofPhoto: "b") == 2)
        #expect(index.photoCount(ofFurniture: "empty") == 0)
        #expect(index.linkedPhotoIds == ["a", "b"])
        #expect(!index.isLinked("c"))
    }

    @Test func aPhotoOnAStoredPieceIsNotInTheRoom() {
        let index = LibraryIndex(state: state)
        #expect(index.photos(inRoom: AppState.primaryRoomId, of: state).map(\.photoId) == ["a", "b"])
        #expect(index.photos(inRoom: "room-2", of: state) == [])
        #expect(state.roomId(ofFurniture: "bed") == nil)
        #expect(state.roomId(ofFurniture: "chair") == AppState.primaryRoomId)
    }

    @Test func lastPhotoAddedStaysUnknownWithoutATime() {
        let index = LibraryIndex(state: state)
        #expect(index.lastPhotoAdded(toFurniture: "chair") == Date(timeIntervalSince1970: 200))
        #expect(index.lastPhotoAdded(toFurniture: "bed") == nil)
        #expect(index.lastPhotoAdded(toFurniture: "empty") == nil)
    }

    @Test func accessorsNameTheSamePiecesAsTheFile() {
        #expect(state.placedFurniture.map(\.instanceId) == ["chair"])
        #expect(state.storedFurniture.map(\.instanceId) == ["bed", "empty"])
        #expect(state.allFurniture.map(\.instanceId) == ["chair", "bed", "empty"])
        #expect(state.primaryCat == Cat(catId: AppState.primaryCatId, name: state.catName))
    }

    @Test func theStoreRecordsWhenPiecesAndLinksWereMade() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: try TestSupport.catalog())
        let before = LibraryStore.now()
        let chair = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 31),
                                                       placement: Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2),
                                                       displayName: "椅", decision: .manual)
        #expect(try #require(chair.createdAt) >= before)
        #expect(chair.updatedAt == nil)
        #expect(try #require(chair.sources[0].addedAt) >= before)

        let loose = try await store.addPhoto(draft: try TestSupport.draft(seed: 32))
        let linked = try await store.linkPhoto(photoId: loose.photoId, toInstance: chair.instanceId)
        #expect(try #require(linked.sources[1].addedAt) >= before)
        #expect(try #require(linked.updatedAt) >= before)
        #expect(linked.createdAt == chair.createdAt)

        // The times survive a reload.
        let reopened = LibraryStore(root: root, catalog: try TestSupport.catalog())
        let state = try await reopened.load()
        #expect(state.placedFurniture == [linked])
        #expect(LibraryIndex(state: state).lastPhotoAdded(toFurniture: chair.instanceId) == linked.sources[1].addedAt)
    }

    // MARK: Several photos at once

    private func library() async throws -> (root: URL, store: LibraryStore, chair: PhotoFurniture, stool: PhotoFurniture, loose: [PhotoRecord]) {
        let root = TestSupport.tempDir()
        let store = LibraryStore(root: root, catalog: try TestSupport.catalog())
        let chair = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 41),
                                                       placement: Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2),
                                                       displayName: "椅", decision: .manual)
        let stool = try await store.addFurniture(placement: Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1), displayName: "凳")
        var loose: [PhotoRecord] = []
        for seed in 42...44 { loose.append(try await store.addPhoto(draft: try TestSupport.draft(seed: seed))) }
        return (root, store, chair, stool, loose)
    }

    @Test func linkingSeveralPhotosIsOneWriteAndSkipsThoseAlreadyThere() async throws {
        let (root, store, chair, _, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = await store.snapshot().revision
        let ids = loose.map(\.photoId)
        #expect(try await store.linkPhotos(photoIds: ids + [chair.sources[0].photoId, ids[0]], toInstance: chair.instanceId)
                == LibraryStore.BatchOutcome(changed: 3, unchanged: 1))
        let state = await store.snapshot()
        #expect(state.revision == before + 1)
        #expect(state.placedFurniture[0].sources.map(\.photoId) == [chair.sources[0].photoId] + ids)
        // Asking again changes nothing and writes nothing.
        #expect(try await store.linkPhotos(photoIds: ids, toInstance: chair.instanceId).changed == 0)
        #expect(await store.snapshot().revision == before + 1)
    }

    @Test func anUnknownPhotoOrPieceRejectsTheWholeBatch() async throws {
        let (root, store, chair, _, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = await store.snapshot()
        await #expect(throws: StoreError.unknownPhoto) {
            try await store.linkPhotos(photoIds: [loose[0].photoId, "nope"], toInstance: chair.instanceId)
        }
        await #expect(throws: StoreError.unknownInstance) { try await store.linkPhotos(photoIds: [loose[0].photoId], toInstance: "nope") }
        await #expect(throws: StoreError.unknownPhoto) { try await store.deletePhotos(photoIds: [loose[0].photoId, "nope"]) }
        #expect(await store.snapshot() == before)
    }

    @Test func movingTakesPhotosOffOnePieceAndOntoAnother() async throws {
        let (root, store, chair, stool, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = loose.map(\.photoId)
        try await store.linkPhotos(photoIds: ids, toInstance: chair.instanceId)
        try await store.linkPhotos(photoIds: [ids[0]], toInstance: stool.instanceId)
        // ids[0] is already on the stool: it only leaves the chair. ids[2] stays on the chair.
        let before = await store.snapshot().revision
        #expect(try await store.movePhotos(photoIds: [ids[0], ids[1]], fromInstance: chair.instanceId, toInstance: stool.instanceId)
                == LibraryStore.BatchOutcome(changed: 2, unchanged: 0))
        let state = await store.snapshot()
        #expect(state.revision == before + 1)
        let index = LibraryIndex(state: state)
        #expect(index.photos(ofFurniture: chair.instanceId).map(\.photoId) == [chair.sources[0].photoId, ids[2]])
        #expect(index.photos(ofFurniture: stool.instanceId).map(\.photoId) == [ids[0], ids[1]])
        #expect(state.photos.count == 4)

        #expect(try await store.unlinkPhotos(photoIds: ids, fromInstance: stool.instanceId)
                == LibraryStore.BatchOutcome(changed: 2, unchanged: 1))
        #expect(await store.snapshot().allFurniture.count == 2)
        #expect(await store.snapshot().photos.count == 4)
    }

    @Test func deletingSeveralPhotosKeepsEveryPieceAndRemovesTheFiles() async throws {
        let (root, store, chair, _, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = loose.map(\.photoId)
        try await store.linkPhotos(photoIds: ids, toInstance: chair.instanceId)
        try await store.deletePhotos(photoIds: [ids[0], ids[1], chair.sources[0].photoId])
        let state = await store.snapshot()
        #expect(state.photos.map(\.photoId) == [ids[2]])
        #expect(state.placedFurniture[0].sources.map(\.photoId) == [ids[2]])
        #expect(state.allFurniture.count == 2)
        let fm = FileManager.default
        #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("originals").path).count == 1)
        #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("thumbnails").path).count == 1)
        #expect(await store.integrityReport().isClean)
    }

    @Test func favouriteMarksSeveralPhotosAtOnce() async throws {
        let (root, store, _, _, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = loose.map(\.photoId)
        _ = try await store.editPhoto(photoId: ids[0], PhotoEdit(favorite: true))
        #expect(try await store.setFavorite(photoIds: ids, true) == 2)
        #expect(await store.snapshot().photos.filter(\.favorite).count == 3)
        #expect(try await store.setFavorite(photoIds: ids, true) == 0)
    }

    @Test func theLibraryCanShowOnlyPhotosOnChosenPieces() async throws {
        let (root, store, chair, stool, loose) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.linkPhotos(photoIds: [loose[0].photoId], toInstance: stool.instanceId)
        let state = await store.snapshot()
        #expect(PhotoLibrary.count(in: state, filter: .all, onFurniture: [stool.instanceId]) == 1)
        #expect(PhotoLibrary.count(in: state, filter: .all, onFurniture: [stool.instanceId, chair.instanceId]) == 2)
        #expect(PhotoLibrary.count(in: state, filter: .unlinked, onFurniture: [chair.instanceId]) == 0)
        #expect(PhotoLibrary.sections(in: state, filter: .all, onFurniture: [stool.instanceId]).flatMap(\.photos).map(\.photoId) == [loose[0].photoId])
    }
}
