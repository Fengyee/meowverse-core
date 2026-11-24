import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MeowverseCore

@Suite struct PhotoIngestTests {
    @Test func shaMatchesCryptoKitOverOriginalBytes() throws {
        let data = TestSupport.imageData(width: 80, height: 40)
        let draft = try PhotoIngest.makeDraft(data: data, filename: "x.jpg")
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(draft.sha256 == expected)
        #expect(draft.data == data)
        #expect(draft.byteSize == data.count)
        #expect(draft.mimeType == "image/jpeg")
        #expect(draft.width == 80 && draft.height == 40)
        #expect(draft.filename == "x.jpg")
    }

    @Test func exifDateTimeOriginalBecomesDay() throws {
        let data = TestSupport.imageData(dateTimeOriginal: "2024:03:15 23:59:58")
        let draft = try PhotoIngest.makeDraft(data: data, filename: "2019-01-01.jpg")
        #expect(draft.captureDate == "2024-03-15")
        #expect(draft.captureDateSource == .exif)
    }

    @Test func missingOrInvalidExifIsUnknownNeverFilename() throws {
        let plain = try PhotoIngest.makeDraft(data: TestSupport.imageData(), filename: "IMG_20190101_120000.jpg")
        #expect(plain.captureDate == nil)
        #expect(plain.captureDateSource == .unknown)
        let bogus = try PhotoIngest.makeDraft(data: TestSupport.imageData(dateTimeOriginal: "0000:00:00 00:00:00"), filename: nil)
        #expect(bogus.captureDate == nil && bogus.captureDateSource == .unknown)
        #expect(PhotoIngest.exifDay("2023:02:29 10:00:00") == nil)
        #expect(PhotoIngest.exifDay("2024:02:29 10:00:00") == "2024-02-29")
    }

    @Test func orientationCorrectedSizeAndThumbnail() throws {
        // Stored 120x60 with orientation 6 (rotate 90 CW) displays as 60x120.
        let data = TestSupport.imageData(width: 120, height: 60, orientation: 6)
        let draft = try PhotoIngest.makeDraft(data: data, filename: nil)
        #expect(draft.width == 60 && draft.height == 120)
        let thumb = try #require(CGImageSourceCreateWithData(draft.thumbnailJPEG as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(thumb, 0, nil) as? [CFString: Any])
        let tw = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let th = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        #expect(th > tw, "thumbnail has orientation applied")
        #expect(CGImageSourceGetType(thumb) as String? == "public.jpeg")
    }

    @Test func thumbnailIsAtMost512() throws {
        let draft = try PhotoIngest.makeDraft(data: TestSupport.imageData(width: 1600, height: 900), filename: nil)
        let image = try #require(PhotoIngest.downsampledImage(data: draft.thumbnailJPEG, maxPixel: 4096))
        #expect(max(image.width, image.height) == 512)
        let small = try #require(PhotoIngest.downsampledImage(data: draft.data, maxPixel: 100))
        #expect(max(small.width, small.height) == 100)
    }

    @Test func pngMimeType() throws {
        let draft = try PhotoIngest.makeDraft(data: TestSupport.imageData(type: .png), filename: nil)
        #expect(draft.mimeType == "image/png")
    }

    @Test func rejectsEmptyNonImageAndTooLarge() {
        #expect(throws: IngestError.empty) { try PhotoIngest.makeDraft(data: Data(), filename: nil) }
        #expect(throws: IngestError.notAnImage) { try PhotoIngest.makeDraft(data: Data("not a picture".utf8), filename: nil) }
        let huge = Data(count: PhotoIngest.maxBytes + 1)
        #expect(throws: IngestError.tooLarge(bytes: PhotoIngest.maxBytes + 1)) { try PhotoIngest.makeDraft(data: huge, filename: nil) }
    }

    @Test func downsampleFromURL() throws {
        let dir = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.jpg")
        try TestSupport.imageData(width: 300, height: 200).write(to: file)
        let image = try #require(PhotoIngest.downsampledImage(at: file, maxPixel: 150))
        #expect(image.width == 150 && image.height == 100)
        #expect(PhotoIngest.downsampledImage(at: dir.appendingPathComponent("missing.jpg"), maxPixel: 10) == nil)
    }

    private func legacyLibrary(at root: URL, dateSource: CaptureDateSource, web: Bool = false) throws -> (Data, AppState) {
        let firstDate = dateSource == .unknown ? nil : "2018:01:02 09:00:00"
        let bytes = try TestSupport.designatedPrimaryHEIF(firstDate: firstDate), hash = PhotoIngest.sha256Hex(bytes)
        let exifDay = firstDate.flatMap(PhotoIngest.exifDay)
        let photo = PhotoRecord(photoId: "pair", filename: "pair.heic", sha256: hash, mimeType: "image/heic",
                                byteSize: bytes.count, width: 320, height: 256, originalFile: "originals/\(hash).heic",
                                thumbnailFile: web ? "thumbnails/\(hash).jpg" : "thumbnails/pair.jpg",
                                captureDate: dateSource == .user ? "2020-02-29" : exifDay, captureDateSource: dateSource,
                                exifCaptureDate: exifDay, importedAt: Date(timeIntervalSince1970: 100),
                                favorite: true, note: "window", revision: 3, assetIdentifier: "local", cloudIdentifier: "cloud")
        var state = AppState.empty
        state.photos = [photo]
        state.items = [PhotoFurniture(instanceId: "chair", modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2,
                                     turn: 0, finish: .original, displayName: "Chair", sources: [.manual(photoId: photo.photoId)],
                                     tags: [], revision: 1, coverPhotoId: photo.photoId)]
        for dir in [LibraryStore.originalsDir, LibraryStore.thumbnailsDir] {
            try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
        try bytes.write(to: root.appending(path: photo.originalFile))
        try TestSupport.imageData(width: 320, height: 256).write(to: root.appending(path: photo.thumbnailFile))
        try LibraryStore.encodeState(state).write(to: root.appending(path: LibraryStore.stateFile))
        return (bytes, state)
    }

    @Test(arguments: [(CaptureDateSource.user, false), (.exif, false), (.unknown, false), (.unknown, true)])
    func openingLegacyHEIFRepairsItsThumbnailAndMetadata(dateSource: CaptureDateSource, web: Bool) async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (bytes, before) = try legacyLibrary(at: root, dateSource: dateSource, web: web)
        let store = LibraryStore(root: root, catalog: try TestSupport.catalog())
        #expect(try await store.load() == before)
        let thumb = try #require(await store.thumbnailURL(photoId: "pair"))
        try TestSupport.expectUprightHEIFPrimary(PhotoIngest.downsampledImage(at: thumb, maxPixel: 512), width: 512, height: 256)
        let stored = try #require(await store.originalURL(photoId: "pair"))
        #expect(try Data(contentsOf: stored) == bytes)
        let after = await store.snapshot()
        let photo = try #require(after.photo(id: "pair"))
        #expect(after.items == before.items)
        #expect(photo.width == 640 && photo.height == 320)
        #expect(photo.exifCaptureDate == "2024-03-15")
        if web {
            #expect(photo.captureDate == nil && photo.captureDateSource == .unknown)
        } else if dateSource == .user {
            #expect(photo.captureDate == "2020-02-29" && photo.captureDateSource == .user)
        } else {
            #expect(photo.captureDate == "2024-03-15" && photo.captureDateSource == .exif)
        }
        #expect(photo.favorite && photo.note == "window" && photo.assetIdentifier == "local" && photo.cloudIdentifier == "cloud")
        #expect(await store.integrityReport().isClean)
        let reopened = LibraryStore(root: root, catalog: try TestSupport.catalog())
        #expect(try await reopened.load() == after)
        _ = await reopened.thumbnailURL(photoId: "pair")
        #expect(await reopened.snapshot() == after)
        #expect(await reopened.indexedSnapshot().index.photo(id: "pair") == photo)
        let zip = root.appending(path: "heif.zip")
        _ = try await reopened.exportBackup(to: zip, appVersion: "test")
        let restored = LibraryStore(root: root.appending(path: "restored"), catalog: try TestSupport.catalog())
        let prepared = try BackupArchive.prepare(file: zip, stagingURL: restored.makeStagingURL(), catalog: TestSupport.catalog())
        #expect(try await restored.replaceLibrary(with: prepared) == after)
        #expect(try Data(contentsOf: #require(await restored.originalURL(photoId: "pair"))) == bytes)
        #expect(try Data(contentsOf: #require(await restored.thumbnailURL(photoId: "pair"))) == Data(contentsOf: thumb))
    }

    @Test func repairWithAFailedCommitShowsTheVerifiedPrimaryAndRetries() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (bytes, before) = try legacyLibrary(at: root, dateSource: .user)
        let store = LibraryStore(root: root, catalog: try TestSupport.catalog(), fault: FaultSwitch(.writeState).handler)
        _ = try await store.load()
        let first = try #require(await store.displayFiles(photoId: "pair"))
        #expect(!first.metadataChanged && first.thumbnail == first.original)
        #expect(first.unsavedRepair?.applied(to: before.photos[0]).exifCaptureDate == "2024-03-15")
        try TestSupport.expectUprightHEIFPrimary(PhotoIngest.downsampledImage(at: first.thumbnail, maxPixel: 512), width: 512, height: 256)
        #expect(try Data(contentsOf: first.original) == bytes)
        #expect(await store.snapshot() == before)
        let retry = try #require(await store.displayFiles(photoId: "pair"))
        #expect(retry.metadataChanged && retry.thumbnail != retry.original && retry.unsavedRepair == nil)
        #expect(await store.snapshot().photo(id: "pair")?.exifCaptureDate == "2024-03-15")
    }

    /// The fourth review: item zero says 2018-01-02, the designated primary 2024-03-15, and
    /// every state write fails. The shown pixels are the primary's, so the shown size and day
    /// must be the primary's too, while the saved library stays exactly as it was.
    @Test(arguments: [(CaptureDateSource.exif, false), (.user, false), (.unknown, false), (.unknown, true)])
    func persistentRepairFailureShowsThePrimarysMetadataWithoutSavingIt(dateSource: CaptureDateSource, web: Bool) async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (bytes, before) = try legacyLibrary(at: root, dateSource: dateSource, web: web)
        let stateBytes = try Data(contentsOf: root.appending(path: LibraryStore.stateFile))
        let fault = PersistentFault(.writeState)
        let store = LibraryStore(root: root, catalog: try TestSupport.catalog(), fault: fault.handler)
        #expect(try await store.load() == before)

        func expectShown(_ shown: PhotoRecord?, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(shown?.width == 640 && shown?.height == 320, sourceLocation: sourceLocation)
            #expect(shown?.exifCaptureDate == "2024-03-15", sourceLocation: sourceLocation)
            switch (dateSource, web) {
            case (.user, _):
                #expect(shown?.captureDate == "2020-02-29" && shown?.captureDateSource == .user, sourceLocation: sourceLocation)
            case (.unknown, true):
                #expect(shown?.captureDate == nil && shown?.captureDateSource == .unknown, sourceLocation: sourceLocation)
            default:
                #expect(shown?.captureDate == "2024-03-15" && shown?.captureDateSource == .exif, sourceLocation: sourceLocation)
            }
            // Everything the user owns is unchanged, including the revision a later edit is checked against.
            #expect(shown?.revision == before.photos[0].revision && shown?.note == "window" && shown?.favorite == true,
                    sourceLocation: sourceLocation)
        }

        for _ in 0..<2 {
            let display = try #require(await store.displayFiles(photoId: "pair"))
            #expect(!display.metadataChanged)
            try TestSupport.expectUprightHEIFPrimary(PhotoIngest.downsampledImage(at: display.thumbnail, maxPixel: 512),
                                                     width: 512, height: 256)
            let stored = try #require(await store.snapshot().photo(id: "pair"))
            #expect(stored == before.photos[0])
            // What AppModel.photo(_:) publishes next to these pixels.
            expectShown(display.unsavedRepair?.applied(to: stored) ?? stored)
            // The repair belongs to these bytes only.
            let other = PhotoRecord(photoId: "pair", filename: nil, sha256: "other bytes", mimeType: "image/heic", byteSize: 1,
                                    width: 1, height: 1, originalFile: "originals/other.heic", thumbnailFile: "thumbnails/pair.jpg",
                                    captureDate: "2019-05-05", captureDateSource: .exif, exifCaptureDate: "2019-05-05",
                                    importedAt: Date(timeIntervalSince1970: 0), revision: stored.revision)
            #expect(display.unsavedRepair?.applied(to: other) ?? other == other)

            // Fifth review (R5-05): the gallery's month groups, count and cells read the same
            // record as the detail, not item zero's 2018-01.
            let repairs = display.unsavedRepair.map { [$0.photoId: $0] } ?? [:]
            let shownState = await store.snapshot().applying(repairs)
            let sections = PhotoLibrary.sections(in: shownState, filter: .all)
            #expect(sections.flatMap(\.photos).count == 1 && PhotoLibrary.count(in: shownState, filter: .all) == 1)
            let cell = try #require(sections.first?.photos.first)
            expectShown(cell)
            #expect(cell == display.unsavedRepair?.applied(to: stored))
            switch (dateSource, web) {
            case (.user, _): #expect(sections.map(\.month) == ["2020-02"])
            case (.unknown, true): #expect(sections.map(\.month) == [nil])
            default: #expect(sections.map(\.month) == ["2024-03"])
            }
            // Only the repaired photo changes; the saved snapshot does not.
            #expect(shownState.revision == before.revision && shownState.items == before.items)
            #expect(await store.snapshot() == before)
        }
        #expect(await store.snapshot().applying([:]) == before)
        #expect(try Data(contentsOf: root.appending(path: LibraryStore.stateFile)) == stateBytes)
        #expect(try Data(contentsOf: root.appending(path: before.photos[0].originalFile)) == bytes)
        #expect(try await LibraryStore(root: root, catalog: try TestSupport.catalog()).load() == before)

        // Once writes work again the next look saves the same record that was shown.
        let lastFailed = await store.displayFiles(photoId: "pair")
        let shownBeforeSave = lastFailed?.unsavedRepair?.applied(to: before.photos[0]) ?? before.photos[0]
        fault.clear()
        let saved = try #require(await store.displayFiles(photoId: "pair"))
        #expect(saved.metadataChanged && saved.unsavedRepair == nil)
        let photo = try #require(await store.snapshot().photo(id: "pair"))
        expectShown({ var p = photo; p.revision = before.photos[0].revision; return p }())
        var comparable = photo
        comparable.revision = shownBeforeSave.revision
        #expect(comparable == shownBeforeSave)
        #expect(try await LibraryStore(root: root, catalog: try TestSupport.catalog()).load().photo(id: "pair") == photo)
        #expect(try Data(contentsOf: root.appending(path: before.photos[0].originalFile)) == bytes)
        #expect(await store.integrityReport().isClean)
    }

    @Test func reselectingTheOriginalRechecksAPreviouslyDamagedHEIF() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (bytes, before) = try legacyLibrary(at: root, dateSource: .exif)
        let original = root.appending(path: before.photos[0].originalFile)
        try TestSupport.imageData(type: .heic).write(to: original)
        let store = LibraryStore(root: root, catalog: try TestSupport.catalog())
        _ = try await store.load()
        _ = await store.thumbnailURL(photoId: "pair")
        #expect(await store.snapshot() == before)
        _ = try await store.addPhoto(draft: PhotoIngest.makeDraft(data: bytes, filename: nil, reduce: false))
        let thumbnail = try #require(await store.thumbnailURL(photoId: "pair"))
        try TestSupport.expectUprightHEIFPrimary(PhotoIngest.downsampledImage(at: thumbnail, maxPixel: 512), width: 512, height: 256)
        #expect(await store.snapshot().photo(id: "pair")?.captureDate == "2024-03-15")
        #expect(try Data(contentsOf: original) == bytes)
    }
}
