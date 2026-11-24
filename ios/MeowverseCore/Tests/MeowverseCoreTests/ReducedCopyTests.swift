import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MeowverseCore

/// Schema 8: a large photo is stored as a reduced copy; the record says what it was made from.
@Suite struct ReducedCopyTests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try TestSupport.catalog() }
    let fm = FileManager.default

    /// A noisy image, so it does not compress to almost nothing like a gradient does.
    static func noisyData(width: Int, height: Int, seed: UInt64, orientation: Int? = nil,
                          dateTimeOriginal: String? = nil) -> Data {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            pixels[i] = UInt8(truncatingIfNeeded: state >> 33)
            pixels[i + 1] = UInt8(truncatingIfNeeded: state >> 41)
            pixels[i + 2] = UInt8(truncatingIfNeeded: state >> 49)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        if let dateTimeOriginal {
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: dateTimeOriginal]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test func largePhotoIsStoredAsAReducedCopyThatRemembersItsSource() throws {
        let source = Self.noisyData(width: 3000, height: 1500, seed: 1, orientation: 6, dateTimeOriginal: "2025:06:01 08:00:00")
        let draft = try PhotoIngest.makeDraft(data: source, filename: "big.jpg")
        // Orientation 6 displays as 1500x3000; the long side becomes 2048.
        #expect(draft.width == 1024 && draft.height == 2048)
        #expect(draft.byteSize == draft.data.count && draft.byteSize < source.count)
        #expect(draft.sha256 == PhotoIngest.sha256Hex(draft.data))
        #expect(draft.reducedFrom == ReducedFrom(sha256: PhotoIngest.sha256Hex(source), byteSize: source.count, width: 1500, height: 3000))
        #expect(draft.captureDate == "2025-06-01" && draft.captureDateSource == .exif)
        // The stored bytes are a real image of the stated size and type.
        let stored = try #require(PhotoIngest.downsampledImage(data: draft.data, maxPixel: 4096))
        #expect(stored.width == 1024 && stored.height == 2048)
        #expect(["image/heic", "image/jpeg"].contains(draft.mimeType))
        #expect(PhotoIngest.downsampledImage(data: draft.thumbnailJPEG, maxPixel: 4096).map { max($0.width, $0.height) } == 512)
    }

    @Test func photoWithinTheLimitIsStoredUntouched() throws {
        let source = Self.noisyData(width: 2048, height: 1000, seed: 2)
        let draft = try PhotoIngest.makeDraft(data: source, filename: nil)
        #expect(draft.data == source && draft.reducedFrom == nil)
    }

    @Test func backupsAskForTheBytesUntouched() throws {
        let source = Self.noisyData(width: 3000, height: 1500, seed: 3)
        let draft = try PhotoIngest.makeDraft(data: source, filename: nil, reduce: false)
        #expect(draft.data == source && draft.reducedFrom == nil && draft.width == 3000)
    }

    @Test func sameSourceTwiceIsOnePhotoAndTheRecordSurvivesReload() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let source = Self.noisyData(width: 2600, height: 1300, seed: 4)
        let store = LibraryStore(root: root, catalog: catalog)
        let first = try await store.addPhoto(draft: try PhotoIngest.makeDraft(data: source, filename: nil))
        let again = try PhotoIngest.makeDraft(data: source, filename: nil)
        let second = try await store.addPhoto(draft: again)
        #expect(first.photoId == second.photoId)
        #expect(await store.existingPhoto(matching: again)?.photoId == first.photoId)
        #expect(first.reducedFrom?.sha256 == PhotoIngest.sha256Hex(source))
        #expect(first.byteSize < source.count && first.width == 2048)
        #expect(try await store.verifyOriginal(photoId: first.photoId))

        let reopened = LibraryStore(root: root, catalog: catalog)
        let state = try await reopened.load()
        #expect(state.schemaVersion == AppState.currentSchemaVersion && state.schemaVersion >= 8)
        #expect(state.photos.count == 1 && state.photos[0].reducedFrom == first.reducedFrom)
        #expect(await reopened.integrityReport().isClean)
    }

    @Test func repeatedBatchLearnsIdentifierWithoutChangingTheReducedCopyOrSkipRevision() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let source = Self.noisyData(width: 2600, height: 1300, seed: 14)
        var draft = try PhotoIngest.makeDraft(data: source, filename: nil)
        let first = try await store.importPhoto(draft: draft)
        #expect(first.inserted && first.photo.reducedFrom != nil)

        draft.assetIdentifier = "ASSET-14"
        let failing = LibraryStore(root: root, catalog: catalog) { step in
            if step == .writeState { throw StoreError.io("test") }
        }
        draft.cloudIdentifier = "CLOUD-14"
        let pickedAgain = draft
        await #expect(throws: StoreError.io("test")) { try await failing.importPhoto(draft: pickedAgain) }
        let retry = LibraryStore(root: root, catalog: catalog)
        #expect(try await retry.load().photos == [first.photo])
        let result = try await retry.importPhoto(draft: draft)
        #expect(!result.inserted)
        var expected = first.photo
        expected.assetIdentifier = draft.assetIdentifier
        expected.cloudIdentifier = draft.cloudIdentifier
        let reopened = LibraryStore(root: root, catalog: catalog)
        #expect(result.photo == expected)
        #expect(try await reopened.load().photos == [expected])
        try await reopened.discardBatchPhoto(photoId: first.photo.photoId, ifUnchangedSince: first.photo.revision)
        #expect(await reopened.snapshot().photos.isEmpty)
        #expect(await reopened.integrityReport().isClean)
    }

    /// "Make furniture from this photo" reads the stored copy back in: it must find its own record.
    @Test func theStoredCopyReadBackInMatchesItsOwnRecord() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let photo = try await store.addPhoto(draft: try PhotoIngest.makeDraft(data: Self.noisyData(width: 2600, height: 1300, seed: 5), filename: nil))
        let url = try #require(await store.originalURL(photoId: photo.photoId))
        let reread = try PhotoIngest.makeDraft(data: Data(contentsOf: url), filename: nil)
        #expect(reread.reducedFrom == nil && reread.sha256 == photo.sha256)
        #expect(await store.existingPhoto(matching: reread)?.photoId == photo.photoId)
    }

    /// A photo stored whole by an older build, picked again now: still the same photo.
    @Test func aPhotoStoredWholeEarlierIsRecognisedWhenPickedAgain() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let source = Self.noisyData(width: 2600, height: 1300, seed: 6)
        let store = LibraryStore(root: root, catalog: catalog)
        let whole = try await store.addPhoto(draft: try PhotoIngest.makeDraft(data: source, filename: nil, reduce: false))
        let again = try await store.addPhoto(draft: try PhotoIngest.makeDraft(data: source, filename: nil))
        #expect(again.photoId == whole.photoId && again.reducedFrom == nil)
        #expect(try await store.load().photos.count == 1)
        #expect(try Data(contentsOf: #require(await store.originalURL(photoId: whole.photoId))) == source)
    }

    @Test func schema7RecordHasNoSourceAndABackupKeepsIt() async throws {
        let json = #"{"photoId":"p","sha256":"ab","mimeType":"image/jpeg","byteSize":3,"width":1,"height":1,"originalFile":"originals/ab.jpeg","thumbnailFile":"thumbnails/p.jpg","captureDate":null,"captureDateSource":"unknown","exifCaptureDate":null,"importedAt":0,"favorite":false,"note":"","revision":1}"#
        #expect(try JSONDecoder().decode(PhotoRecord.self, from: Data(json.utf8)).reducedFrom == nil)

        let parent = TestSupport.tempDir()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: parent.appendingPathComponent("a"), catalog: catalog)
        let photo = try await store.addPhoto(draft: try PhotoIngest.makeDraft(data: Self.noisyData(width: 2600, height: 1300, seed: 7), filename: nil))
        let url = parent.appendingPathComponent("backup.zip")
        _ = try await store.exportBackup(to: url, appVersion: "9.9")
        let target = LibraryStore(root: parent.appendingPathComponent("b"), catalog: catalog)
        let prepared = try BackupArchive.prepare(file: url, stagingURL: target.makeStagingURL(), catalog: catalog)
        let restored = try await target.replaceLibrary(with: prepared)
        #expect(restored.photos.map(\.reducedFrom) == [photo.reducedFrom] && photo.reducedFrom != nil)
        #expect(try await target.verifyOriginal(photoId: photo.photoId))
    }

    // MARK: The photo library's identifier

    @Test func theLibraryIdentifierIsKeptWithTheRecordAndInABackup() async throws {
        let parent = TestSupport.tempDir()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: parent.appendingPathComponent("a"), catalog: catalog)
        var draft = try PhotoIngest.makeDraft(data: Self.noisyData(width: 2600, height: 1300, seed: 8), filename: nil)
        draft.assetIdentifier = "ASSET-1/L0/001"
        let photo = try await store.addPhoto(draft: draft)
        #expect(photo.assetIdentifier == "ASSET-1/L0/001")
        let reopened = LibraryStore(root: parent.appendingPathComponent("a"), catalog: catalog)
        #expect(try await reopened.load().photos.map(\.assetIdentifier) == ["ASSET-1/L0/001"])

        let url = parent.appendingPathComponent("backup.zip")
        _ = try await store.exportBackup(to: url, appVersion: "9.9")
        let target = LibraryStore(root: parent.appendingPathComponent("b"), catalog: catalog)
        let prepared = try BackupArchive.prepare(file: url, stagingURL: target.makeStagingURL(), catalog: catalog)
        #expect(try await target.replaceLibrary(with: prepared).photos.map(\.assetIdentifier) == ["ASSET-1/L0/001"])
    }

    /// The identifier is a hint, never the test for "same photo": that stays with the bytes.
    @Test func theLibraryIdentifierNeverDecidesWhetherTwoPhotosAreTheSame() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        var one = try TestSupport.draft(seed: 801), other = try TestSupport.draft(seed: 802)
        one.assetIdentifier = "SAME"
        other.assetIdentifier = "SAME"
        let first = try await store.addPhoto(draft: one)
        let second = try await store.addPhoto(draft: other)
        #expect(first.photoId != second.photoId)
        // And the same bytes under another identifier are still one photo, keeping the first.
        var renamed = try TestSupport.draft(seed: 801)
        renamed.assetIdentifier = "OTHER"
        renamed.cloudIdentifier = "OTHER-CLOUD"
        let duplicate = try await store.addPhoto(draft: renamed)
        #expect(duplicate.assetIdentifier == "SAME" && duplicate.cloudIdentifier == nil)
        one.cloudIdentifier = "SAME-CLOUD"
        #expect(try await store.addPhoto(draft: one).cloudIdentifier == "SAME-CLOUD")
        #expect(try await store.load().photos.count == 2)
    }

    /// A photo stored before identifiers were recorded learns its own when it is picked again
    /// for a piece of furniture.
    @Test func aPhotoWithoutAnIdentifierLearnsItWhenPickedAgain() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let chair = try await store.commitNewFurniture(
            draft: try TestSupport.draft(seed: 810),
            placement: Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2, finish: .sage),
            displayName: "椅", decision: .manual)
        let loose = try await store.addPhoto(draft: try TestSupport.draft(seed: 811))
        #expect(loose.assetIdentifier == nil)
        var again = try TestSupport.draft(seed: 811)
        again.assetIdentifier = "LATER"
        _ = try await store.addSource(draft: again, toInstance: chair.instanceId, decision: .manual)
        let reopened = LibraryStore(root: root, catalog: catalog)
        let photos = try await reopened.load().photos
        #expect(photos.count == 2 && photos.first { $0.photoId == loose.photoId }?.assetIdentifier == "LATER")
    }

    // MARK: A photo the app can read back from the photo library

    /// Such a photo keeps a smaller copy, and is still the same photo as one kept at the
    /// normal size from the same picked file, whichever came first.
    @Test func aLinkedPhotoKeepsASmallerCopyAndStillMatchesTheSameSource() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let source = Self.noisyData(width: 2600, height: 1300, seed: 9)
        var linked = try PhotoIngest.makeDraft(data: source, filename: nil, maxPixel: PhotoIngest.linkedMaxPixel)
        linked.assetIdentifier = "LOCAL"
        linked.cloudIdentifier = "CLOUD"
        let normal = try PhotoIngest.makeDraft(data: source, filename: nil)
        #expect(linked.width == 1024 && normal.width == 2048 && linked.byteSize < normal.byteSize)
        #expect(linked.reducedFrom == normal.reducedFrom && linked.reducedFrom?.width == 2600)

        let store = LibraryStore(root: root, catalog: catalog)
        let first = try await store.addPhoto(draft: linked)
        #expect(first.width == 1024 && first.cloudIdentifier == "CLOUD")
        #expect(try await store.addPhoto(draft: normal).photoId == first.photoId)
        #expect(try await store.verifyOriginal(photoId: first.photoId))
        let reopened = LibraryStore(root: root, catalog: catalog)
        let photos = try await reopened.load().photos
        #expect(photos.count == 1 && photos[0].cloudIdentifier == "CLOUD" && photos[0].assetIdentifier == "LOCAL")
        #expect(await reopened.integrityReport().isClean)

        // The other order: kept at the normal size first, picked again as a linked photo.
        let other = LibraryStore(root: root.appendingPathComponent("other"), catalog: catalog)
        let kept = try await other.addPhoto(draft: normal)
        let again = try await other.addPhoto(draft: linked)
        #expect(again.photoId == kept.photoId && again.width == 2048)
    }

    @Test func fullOriginalPickedAfterLinkedPreviewKeepsThePhotoAndRebindsOnlyTheVerifiedMissingPair() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        let source = Self.noisyData(width: 1500, height: 800, seed: 19)
        var preview = try PhotoIngest.makeDraft(data: source, filename: nil, maxPixel: PhotoIngest.linkedMaxPixel)
        preview.assetIdentifier = "MISSING"
        let first = try await store.addPhoto(draft: preview)
        #expect(first.reducedFrom != nil)
        var original = try PhotoIngest.makeDraft(data: source, filename: nil)
        #expect(original.reducedFrom == nil)
        original.assetIdentifier = "NEW"
        original.cloudIdentifier = "NEW-CLOUD"
        #expect(try await store.addPhoto(draft: original) == first)
        original.missingLibraryBinding = MissingLibraryBinding.confirmed(photo: first, selected: "NEW", hasFullAccess: { true },
                                                                        localExists: { $0 == "NEW" }, cloudIsMissing: { _ in true })
        let relinked = try await store.addPhoto(draft: original)
        #expect(relinked.photoId == first.photoId && relinked.sha256 == first.sha256)
        #expect(relinked.assetIdentifier == "NEW" && relinked.cloudIdentifier == "NEW-CLOUD")
        original.assetIdentifier = "OTHER"
        #expect(try await store.addPhoto(draft: original) == relinked)
        #expect(try await LibraryStore(root: root, catalog: catalog).load().photos == [relinked])
    }

    @Test func uncertainPhotosPermissionOrCloudIdentityKeepsTheOriginalBinding() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: catalog)
        var draft = try TestSupport.draft(seed: 996)
        draft.assetIdentifier = "OLD"
        draft.cloudIdentifier = "CLOUD"
        let photo = try await store.addPhoto(draft: draft)
        func evidence(access: Bool, existingLocals: Set<String>, cloudMissing: Bool) -> MissingLibraryBinding? {
            MissingLibraryBinding.confirmed(photo: photo, selected: "NEW", hasFullAccess: { access },
                                            localExists: existingLocals.contains, cloudIsMissing: { _ in cloudMissing })
        }
        #expect(evidence(access: false, existingLocals: ["NEW"], cloudMissing: true) == nil)
        #expect(evidence(access: true, existingLocals: [], cloudMissing: true) == nil)
        #expect(evidence(access: true, existingLocals: ["OLD", "NEW"], cloudMissing: true) == nil)
        #expect(evidence(access: true, existingLocals: ["NEW"], cloudMissing: false) == nil)
        #expect(evidence(access: true, existingLocals: ["NEW"], cloudMissing: true) != nil)
    }

    @Test func lateFurnitureAppendCannotWriteToRestoredFurnitureWithTheSameID() async throws {
        let parent = TestSupport.tempDir()
        defer { try? fm.removeItem(at: parent) }
        let store = LibraryStore(root: parent.appending(path: "live"), catalog: catalog)
        let chair = try await store.commitNewFurniture(
            draft: try TestSupport.draft(seed: 920),
            placement: Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2, finish: .sage),
            displayName: "椅", decision: .manual)
        let old = await store.generation
        let url = parent.appending(path: "backup.zip")
        _ = try await store.exportBackup(to: url, appVersion: "9.9")
        let prepared = try BackupArchive.prepare(file: url, stagingURL: store.makeStagingURL(), catalog: catalog)
        let restored = try await store.replaceLibrary(with: prepared)
        let draft = try TestSupport.draft(seed: 921)
        await #expect(throws: CancellationError.self) {
            try await store.addSource(draft: draft, toInstance: chair.instanceId, decision: .manual, generation: old)
        }
        #expect(await store.snapshot() == restored)
        let next = await store.generation
        _ = try await store.clearAll()
        await #expect(throws: CancellationError.self) { try await store.importPhotos([draft], generation: next) }
        #expect(await store.snapshot().photos.isEmpty)
    }

    @Test func batchCheckpointDeduplicatesAndRollsBackEveryNewBlobOnFailure() async throws {
        let root = TestSupport.tempDir()
        defer { try? fm.removeItem(at: root) }
        let drafts = try [901, 902, 901].map { try TestSupport.draft(seed: $0) }
        let failing = LibraryStore(root: root, catalog: catalog) { step in
            if step == .writeState { throw StoreError.io("test") }
        }
        await #expect(throws: StoreError.io("test")) { try await failing.importPhotos(drafts) }
        #expect(await failing.snapshot().photos.isEmpty)
        #expect(await failing.integrityReport().isClean)
        let store = LibraryStore(root: root, catalog: catalog)
        let results = try await store.importPhotos(drafts)
        #expect(results.map(\.inserted) == [true, true, false])
        #expect(results.first?.photo == results.last?.photo)
        let reopened = try await LibraryStore(root: root, catalog: catalog).load()
        #expect(reopened.photos.count == 2 && reopened.revision == 1)
    }

    @Test func aPhotoAlreadySmallEnoughIsUntouchedWhenLinked() throws {
        let source = Self.noisyData(width: 1024, height: 700, seed: 10)
        let draft = try PhotoIngest.makeDraft(data: source, filename: nil, maxPixel: PhotoIngest.linkedMaxPixel)
        #expect(draft.data == source && draft.reducedFrom == nil)
    }
}
