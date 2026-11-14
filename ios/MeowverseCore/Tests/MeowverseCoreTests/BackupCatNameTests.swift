import Foundation
import Testing
@testable import MeowverseCore

struct BackupCatNameTests {
    @Test(arguments: [" 团子 ", "   "])
    func normalizedPrimaryCatNameSurvivesRestoreAndReopen(_ raw: String) async throws {
        let parent = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let room = Room(roomId: "study", name: "书房")
        var state = AppState.empty
        state.catName = raw
        state.rooms = [Room(roomId: AppState.primaryRoomId), room]
        state.cats = [
            Cat(catId: AppState.primaryCatId, name: raw, roomId: room.roomId),
            Cat(catId: "second", name: "芝麻")
        ]
        let archive = parent.appendingPathComponent("cats.zip")
        _ = try BackupArchive.write(state: state, root: parent, to: archive, appVersion: "test") { _ in }
        let root = parent.appendingPathComponent("library")
        let catalog = try TestSupport.catalog()
        let target = LibraryStore(root: root, catalog: catalog)
        let prepared = try BackupArchive.prepare(file: archive, stagingURL: target.makeStagingURL(), catalog: catalog)
        _ = try await target.replaceLibrary(with: prepared)

        let reopened = try await LibraryStore(root: root, catalog: catalog).load()
        let expectedName = AppState.normalizedCatName(raw) ?? AppState.defaultCatName
        #expect(prepared.preview.catName == expectedName)
        #expect(reopened.catName == expectedName)
        #expect(reopened.primaryCat == Cat(catId: AppState.primaryCatId, name: expectedName, roomId: room.roomId))
        #expect(reopened.allCats.last == state.cats.last)
    }
}
