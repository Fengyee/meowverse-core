import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import MeowverseCore

@Suite struct PhotoExportTests {
    @Test(arguments: [PhotoSourceIssue.missing, .permission, .iCloud, .unlinked, .unavailable])
    func fallbackPreservesPhotoAndFurniture(_ reason: PhotoSourceIssue) async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = ReducedCopyTests.noisyData(width: 400, height: 240, seed: 24)
        let draft = try PhotoIngest.makeDraft(data: data, filename: nil, maxPixel: 100)
        let store = LibraryStore(root: root, catalog: try TestSupport.catalog())
        let placement = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2)
        let item = try await store.commitNewFurniture(draft: draft, placement: placement, displayName: "Chair", decision: .manual)
        let photo = try #require(try await store.load().photos.first)
        let stored = try #require(await store.originalURL(photoId: photo.photoId))
        let output = try await PhotoExport.prepare(photo: photo, stored: stored, in: root) { throw reason }
        #expect(output.copyReason == reason)
        #expect(try Data(contentsOf: output.url) == draft.data)
        let state = try await store.load()
        #expect(state.photos == [photo])
        #expect(state.allFurniture.first?.instanceId == item.instanceId)
        #expect(state.allFurniture.first?.sources.first?.photoId == photo.photoId)
        let original = try await PhotoExport.prepare(photo: photo, stored: stored, in: root) { data }
        #expect(original.copyReason == nil)
        #expect(try Data(contentsOf: original.url) == data)
        let changed = try await PhotoExport.prepare(photo: photo, stored: stored, in: root) { draft.data }
        #expect(changed.copyReason == .changed)
    }

    @Test(arguments: [UTType.heic, .jpeg, .png])
    func compatibleShareUsesFullResolutionUprightJPEG(_ type: UTType) async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = TestSupport.imageData(width: 180, height: 120, seed: 3, type: type, orientation: 6)
        let source = root.appendingPathComponent("source").appendingPathExtension(try #require(type.preferredFilenameExtension))
        try data.write(to: source)
        let output = try await PhotoExport(url: source, copyReason: nil).compatibleJPEG()
        let image = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        #expect(CGImageSourceGetType(image) == UTType.jpeg.identifier as CFString)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 120)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 180)
        #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        #expect(try Data(contentsOf: source) == data)
    }

    @Test(arguments: [false, true])
    func designatedHEIFPrimarySurvivesImportDisplayAndShare(reduce: Bool) async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try TestSupport.designatedPrimaryHEIF()
        let draft = try PhotoIngest.makeDraft(data: bytes, filename: "two-images.heic", reduce: reduce, maxPixel: 128)
        let sourceHash = PhotoIngest.sha256Hex(bytes)
        let source = ReducedFrom(sha256: sourceHash, byteSize: bytes.count, width: 640, height: 320)
        #expect(draft.reducedFrom == (reduce ? source : nil))
        let store = LibraryStore(root: root, catalog: try TestSupport.catalog())
        let photo = try await store.addPhoto(draft: draft)
        let width = reduce ? 128 : 640, height = reduce ? 64 : 320
        #expect(photo.width == width && photo.height == height)
        #expect(photo.captureDate == "2024-03-15" && photo.exifCaptureDate == photo.captureDate && photo.captureDateSource == .exif)
        let thumb = try #require(await store.thumbnailURL(photoId: photo.photoId))
        try TestSupport.expectUprightHEIFPrimary(PhotoIngest.downsampledImage(at: thumb, maxPixel: 512), width: 512, height: 256)
        let stored = try #require(await store.originalURL(photoId: photo.photoId))
        try TestSupport.expectUprightHEIFPrimary(PhotoIngest.downsampledImage(at: stored, maxPixel: 1024), width: width, height: height)
        try TestSupport.expectUprightHEIFPrimary(PhotoIngest.downsampledImage(data: bytes, maxPixel: 256), width: 256, height: 128)

        let original = try await PhotoExport.prepare(photo: photo, stored: stored, in: root) { bytes }
        #expect(original.copyReason == nil)
        let jpeg = try await original.compatibleJPEG()
        let output = try #require(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
        try TestSupport.expectUprightHEIFPrimary(CGImageSourceCreateImageAtIndex(output, 0, nil), width: 640, height: 320)
        #expect(try Data(contentsOf: original.url) == bytes)
        #expect(try Data(contentsOf: stored) == draft.data)
        if reduce {
            let fallback = try await PhotoExport.prepare(photo: photo, stored: stored, in: root) { throw PhotoSourceIssue.missing }
            #expect(fallback.copyReason == .missing && fallback.copyCaptureDay?.day == "2024-03-15")
            let copy = try await fallback.compatibleJPEG()
            try TestSupport.expectUprightHEIFPrimary(PhotoIngest.downsampledImage(at: copy, maxPixel: 128), width: 128, height: 64)
            #expect(try Data(contentsOf: fallback.url) == draft.data)
        } else {
            #expect(draft.data == bytes)
        }
    }

    @Test func localOriginalIsVerifiedWithoutPhotosPermission() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: try TestSupport.catalog())
        let draft = try TestSupport.draft()
        let photo = try await store.addPhoto(draft: draft)
        let stored = try #require(await store.originalURL(photoId: photo.photoId))
        let exported = try await PhotoExport.prepare(photo: photo, stored: stored, in: root) {
            Issue.record("A verified local original needs no library access")
            throw PhotoSourceIssue.permission
        }
        #expect(exported.copyReason == nil)
        #expect(try Data(contentsOf: exported.url) == draft.data)
        try Data([0]).write(to: stored)
        await #expect(throws: (any Error).self) {
            try await PhotoExport.prepare(photo: photo, stored: stored, in: root) { throw PhotoSourceIssue.missing }
        }
    }
}
