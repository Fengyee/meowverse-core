import Foundation
import Testing
@testable import MeowverseCore

/// The tour's naming page writes the name the user typed (D24-10). The write is bound to the
/// library the page was answered in: a library restored or cleared before the write lands
/// keeps its own name.
@Suite struct RenameCatGenerationTests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try TestSupport.catalog() }

    @Test func aNameTypedForTheOldLibraryIsNotWrittenToTheRestoredOne() async throws {
        let parent = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = LibraryStore(root: parent.appending(path: "live"), catalog: catalog)
        _ = try await store.renameCat(catId: AppState.primaryCatId, name: "Mimi")
        let url = parent.appending(path: "backup.zip")
        _ = try await store.exportBackup(to: url, appVersion: "9.9")
        let typedIn = await store.generation
        let prepared = try BackupArchive.prepare(file: url, stagingURL: store.makeStagingURL(), catalog: catalog)
        _ = try await store.replaceLibrary(with: prepared)
        await #expect(throws: CancellationError.self) {
            try await store.renameCat(catId: AppState.primaryCatId, name: "Momo", generation: typedIn)
        }
        #expect(await store.snapshot().primaryCat.name == "Mimi")
    }

    @Test func aNameForTheCurrentLibraryIsWritten() async throws {
        let parent = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = LibraryStore(root: parent.appending(path: "live"), catalog: catalog)
        _ = try await store.renameCat(catId: AppState.primaryCatId, name: "Momo", generation: await store.generation)
        #expect(await store.snapshot().primaryCat.name == "Momo")
    }
}
