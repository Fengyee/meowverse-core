import Foundation
import Testing
@testable import MeowverseCore

/// QA review of the sync core (2026-11-18): dates. "Unknown stays unknown", and a system
/// repair never writes the user's date register (docs/ICLOUD_SYNC.md §3).
@Suite struct SyncQADateTests {
    let clock = SyncTestClock()

    /// A web-backup photo explicitly shows "unknown" although its file has an EXIF day. It is a
    /// multi-image HEIF whose record came from item 0 (an old import), so opening it on any
    /// device runs the HEIF primary repair. The repair keeps the web record's unknown only when
    /// the thumbnail sits at the web importer's path, which another device's copy never does.
    @Test func aWebRecordsExplicitUnknownDaySurvivesTheHEIFRepairOnAnotherDevice() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice("A", cloud: cloud, clock: clock), b = try await QADevice("B", cloud: cloud, clock: clock)
        try await QACheck.settle([a, b])
        let heif = try TestSupport.designatedPrimaryHEIF()
        let draft = try PhotoIngest.makeDraft(data: heif, filename: "web.heic", reduce: false)
        let imported = try await a.store.importPhoto(draft: draft).photo
        #expect(imported.reducedFrom == nil)

        // Turn A's record into what the web importer wrote for an explicit unknown, with the
        // item-0 day an old import read.
        var state = await a.store.snapshot()
        let index = try #require(state.photos.firstIndex { $0.photoId == imported.photoId })
        let webThumb = WebBackup.thumbnailPath(forHash: imported.sha256)
        try FileManager.default.copyItem(at: a.root.appendingPathComponent(imported.thumbnailFile),
                                         to: a.root.appendingPathComponent(webThumb))
        let p = state.photos[index]
        state.photos[index] = PhotoRecord(
            photoId: p.photoId, filename: p.filename, sha256: p.sha256, mimeType: p.mimeType, byteSize: p.byteSize,
            width: p.width, height: p.height, originalFile: p.originalFile, thumbnailFile: webThumb,
            captureDate: nil, captureDateSource: .unknown, exifCaptureDate: "2018-01-02",
            importedAt: p.importedAt, favorite: p.favorite, note: p.note, revision: p.revision, reducedFrom: nil)
        try LibraryStore.encodeState(state).write(to: a.root.appendingPathComponent(LibraryStore.stateFile))
        _ = try await a.store.load()
        // Control: on A itself the repair keeps the explicit unknown.
        _ = await a.store.displayFiles(photoId: imported.photoId)
        #expect(try #require(await a.state().photos.first).captureDateSource == .unknown)
        try await QACheck.settle([a, b])

        let onB = try #require(await b.state().photos.first)
        #expect(onB.captureDate == nil && onB.captureDateSource == .unknown, "B shows the explicit unknown")
        _ = await b.store.displayFiles(photoId: onB.photoId)
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let shown = try #require(await device.state().photos.first)
            #expect(shown.captureDate == nil && shown.captureDateSource == .unknown,
                    "\(device.name): a system repair replaced the explicit unknown with \(shown.captureDate ?? "-")")
        }
    }

    /// The HEIF repair on another device writes only the file's day, never a user's choice.
    @Test func aUsersDayIsKeptWhenAnotherDeviceRepairsTheFilesDay() async throws {
        let cloud = SyncMemoryCloud()
        let a = try await QADevice("A", cloud: cloud, clock: clock), b = try await QADevice("B", cloud: cloud, clock: clock)
        try await QACheck.settle([a, b])
        let draft = try PhotoIngest.makeDraft(data: try TestSupport.designatedPrimaryHEIF(), filename: "old.heic", reduce: false)
        let imported = try await a.store.importPhoto(draft: draft).photo
        var state = await a.store.snapshot()
        state.photos[0].exifCaptureDate = "2018-01-02"
        state.photos[0].captureDate = "2018-01-02"
        state.photos[0].captureDateSource = .exif
        try LibraryStore.encodeState(state).write(to: a.root.appendingPathComponent(LibraryStore.stateFile))
        _ = try await a.store.load()
        try await QACheck.settle([a, b])
        clock.advance()
        _ = try await a.store.editPhoto(photoId: imported.photoId, PhotoEdit(captureDate: .set("2015-05-05")))
        try await a.session.captureLocalEdits()
        clock.advance()
        // B has not heard of the correction and opens the photo: the repair runs there.
        _ = await b.store.displayFiles(photoId: try #require(await b.state().photos.first).photoId)
        try await b.session.captureLocalEdits()
        try await QACheck.settle([a, b])
        for device in [a, b] {
            let shown = try #require(await device.state().photos.first)
            #expect(shown.captureDate == "2015-05-05" && shown.captureDateSource == .user, "\(device.name)")
            #expect(shown.exifCaptureDate == "2024-03-15", "\(device.name): the file's day comes from the primary")
        }
    }
}
