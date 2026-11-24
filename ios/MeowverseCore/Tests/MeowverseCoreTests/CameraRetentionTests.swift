import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MeowverseCore

/// A photo taken in the app is kept whole unless Photos confirmed it has the full-size file.
///
/// The camera hands over pixels larger than the 2048 px the app keeps of a picked photo. When
/// the save to Photos is off, refused or fails, the file `CameraCapture` encoded is the only
/// full-size one: after the user confirms, it must come back byte for byte from the library,
/// after a relaunch, from "分享原文件" and from a backup restore. When Photos has it, the app
/// keeps the reduced copy as before and the full file comes from Photos.
@Suite struct CameraRetentionTests {
    /// Sensor pixels 3600x2700 shown a quarter turn (EXIF 6), as a phone held upright gives them.
    static let sensorWidth = 3600, sensorHeight = 2700

    /// Noise, so a reduced copy is clearly smaller than the full file (the case that loses data).
    private static func noisyImage(width: Int, height: Int, seed: UInt64) -> CGImage {
        var state = seed
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            pixels[i] = UInt8(truncatingIfNeeded: state >> 24)
            pixels[i + 1] = UInt8(truncatingIfNeeded: state >> 40)
            pixels[i + 2] = UInt8(truncatingIfNeeded: state >> 56)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// What `InAppCamera.encode` makes of a large shot: the camera's EXIF day, no location.
    static func largeShot() throws -> Data {
        let metadata: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2026:05:20 16:42:10"],
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 1.0],
        ]
        return try CameraCapture.encode(noisyImage(width: sensorWidth, height: sensorHeight, seed: 7), orientation: 6,
                                        metadata: metadata).data
    }

    static let outcomes: [CameraCapture.LibrarySave] = [.notWanted, .refused, .failed, .saved(assetIdentifier: "camera-asset")]

    @Test func onlyAConfirmedSaveCountsAsACopyInPhotos() {
        #expect(CameraCapture.LibrarySave.notWanted.fullSizeCopy == .onlyHere)
        #expect(CameraCapture.LibrarySave.refused.fullSizeCopy == .onlyHere)
        #expect(CameraCapture.LibrarySave.failed.fullSizeCopy == .onlyHere)
        #expect(CameraCapture.LibrarySave.saved(assetIdentifier: nil).fullSizeCopy == .inPhotoLibrary)
        #expect(CameraCapture.LibrarySave.saved(assetIdentifier: "a").assetIdentifier == "a")
        #expect(CameraCapture.LibrarySave.failed.assetIdentifier == nil)
        #expect(!CameraCapture.LibrarySave.notWanted.saveFailed)
        #expect(CameraCapture.LibrarySave.refused.saveFailed && CameraCapture.LibrarySave.failed.saveFailed)
        #expect(!CameraCapture.LibrarySave.saved(assetIdentifier: nil).saveFailed)
    }

    /// The import the app makes after "使用照片" for each outcome of the save to Photos, then
    /// "只存照片": the four cases the review asked for, each followed through relaunch, the
    /// original-file export and a backup restore.
    @Test(arguments: outcomes)
    func confirmedCameraPhotoKeepsItsFullFileUnlessPhotosHasIt(save: CameraCapture.LibrarySave) async throws {
        let parent = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let shot = try Self.largeShot()
        let shotHash = PhotoIngest.sha256Hex(shot)
        // The trigger: the default import would keep a smaller reduced copy of these bytes.
        let reducible = try PhotoIngest.makeDraft(data: shot, filename: nil)
        try #require(reducible.reducedFrom != nil && reducible.byteSize < shot.count)

        var draft = try PhotoIngest.makeDraft(data: shot, filename: nil, fullSizeCopy: save.fullSizeCopy)
        draft.assetIdentifier = save.assetIdentifier
        #expect(draft.captureDate == "2026-05-20" && draft.captureDateSource == .exif)

        let catalog = try TestSupport.catalog()
        let root = parent.appending(path: "library")
        let store = LibraryStore(root: root, catalog: catalog)
        try await store.load()
        let record = try await store.addPhoto(draft: draft)
        let keptWhole = save.fullSizeCopy == .onlyHere

        if keptWhole {
            #expect(record.reducedFrom == nil)
            #expect(record.sha256 == shotHash && record.byteSize == shot.count)
            #expect(record.width == Self.sensorHeight && record.height == Self.sensorWidth)
            #expect(record.assetIdentifier == nil)
        } else {
            #expect(record.reducedFrom == ReducedFrom(sha256: shotHash, byteSize: shot.count,
                                                      width: Self.sensorHeight, height: Self.sensorWidth))
            #expect(max(record.width, record.height) == PhotoIngest.storedMaxPixel)
            #expect(record.assetIdentifier == "camera-asset")
        }
        #expect(record.captureDate == "2026-05-20")
        let storedURL = try #require(await store.originalURL(photoId: record.photoId))
        #expect((try Data(contentsOf: storedURL) == shot) == keptWhole)

        // Relaunch: the same record and the same bytes.
        let reopened = LibraryStore(root: root, catalog: catalog)
        let state = try await reopened.load()
        #expect(state.photos == [record])
        let reopenedURL = try #require(await reopened.originalURL(photoId: record.photoId))
        #expect((try Data(contentsOf: reopenedURL) == shot) == keptWhole)

        // "分享原文件" with Photos unreachable: a whole file is the original; a reduced one is a copy.
        let exports = parent.appending(path: "exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let offline = try await PhotoExport.prepare(photo: record, stored: reopenedURL, in: exports) {
            throw PhotoSourceIssue.missing
        }
        if keptWhole {
            #expect(offline.copyReason == nil)
            #expect(try Data(contentsOf: offline.url) == shot)
        } else {
            #expect(offline.copyReason == .missing)
            // Unchanged: with Photos reachable the full file still comes from there.
            let online = try await PhotoExport.prepare(photo: record, stored: reopenedURL, in: exports) { shot }
            #expect(online.copyReason == nil)
            #expect(try Data(contentsOf: online.url) == shot)
        }

        // A backup restored into an empty library gives back the same bytes.
        let zip = parent.appending(path: "backup.zip")
        _ = try await reopened.exportBackup(to: zip, appVersion: "test")
        let restored = LibraryStore(root: parent.appending(path: "restored"), catalog: catalog)
        let prepared = try BackupArchive.prepare(file: zip, stagingURL: restored.makeStagingURL(), catalog: catalog)
        #expect(try await restored.replaceLibrary(with: prepared).photos == [record])
        let restoredURL = try #require(await restored.originalURL(photoId: record.photoId))
        #expect((try Data(contentsOf: restoredURL) == shot) == keptWhole)
        #expect(try await restored.verifyOriginal(photoId: record.photoId))
    }

    /// Confirming the camera photo into a new piece writes the same whole file.
    @Test func cameraPhotoPlacedInFurnitureKeepsItsFullFile() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let shot = try Self.largeShot()
        let draft = try PhotoIngest.makeDraft(data: shot, filename: nil, fullSizeCopy: CameraCapture.LibrarySave.refused.fullSizeCopy)
        let store = LibraryStore(root: root, catalog: try TestSupport.catalog())
        try await store.load()
        let placement = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2)
        let piece = try await store.commitNewFurniture(draft: draft, placement: placement, displayName: "Chair", decision: .manual)
        let photoId = try #require(piece.sources.first?.photoId)
        let url = try #require(await store.originalURL(photoId: photoId))
        #expect(try Data(contentsOf: url) == shot)
        #expect(await store.snapshot().photo(id: photoId)?.reducedFrom == nil)
    }

    /// Bytes read back from the app's own library keep their hash, so they match their record.
    @Test func storedBytesReadBackMatchTheirRecord() async throws {
        let shot = try Self.largeShot()
        let again = try PhotoIngest.makeDraft(data: shot, filename: nil, fullSizeCopy: .onlyHere)
        #expect(again.sha256 == PhotoIngest.sha256Hex(shot) && again.reducedFrom == nil)
    }
}
