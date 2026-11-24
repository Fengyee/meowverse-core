import Foundation
import Testing
@testable import MeowverseCore

/// PRIVACY-5: a piece whose photos are still on their way is not a piece without photos.
@Suite struct PiecesSyncingFilterTests {
    @Test func aPieceWaitingForItsPhotosIsNotListedAsWithout() async throws {
        let catalog = try TestSupport.catalog()
        let store = LibraryStore(root: TestSupport.tempDir().appendingPathComponent("Library", isDirectory: true), catalog: catalog)
        try await store.load()
        let waiting = try await store.addFurniture(placement: SyncCheck.spot(0), displayName: "Waiting")
        let empty = try await store.addFurniture(placement: SyncCheck.spot(1), displayName: "Empty")
        let state = await store.snapshot()
        func listed(_ photos: FurnitureQuery.Photos) -> [String] {
            var query = FurnitureQuery()
            query.photos = photos
            return FurnitureLibrary.pieces(in: state, catalog: catalog, query: query, syncing: [waiting.instanceId]).map(\.instanceId)
        }
        #expect(listed(.without) == [empty.instanceId])
        #expect(listed(.with) == [waiting.instanceId])
    }
}
