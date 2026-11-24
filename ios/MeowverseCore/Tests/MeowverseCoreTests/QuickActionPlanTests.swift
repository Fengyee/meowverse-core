import Foundation
import Testing
@testable import MeowverseCore

/// The Home Screen quick actions: which appear, in what order, and which piece "Revisit a
/// Memory" may open.
@Suite struct QuickActionPlanTests {
    @Test func fourActionsInTheBriefsOrder() {
        #expect(QuickActionPlan.kinds(hasCamera: true, hasMemory: true) == [.camera, .library, .companion, .memory])
        #expect(QuickActionPlan.kinds(hasCamera: true, hasMemory: true).map(\.rawValue)
                == ["app.meowverse.camera", "app.meowverse.library", "app.meowverse.companion", "app.meowverse.memory"])
    }

    @Test func noCameraNoMemoryNoItem() {
        #expect(QuickActionPlan.kinds(hasCamera: false, hasMemory: true) == [.library, .companion, .memory])
        #expect(QuickActionPlan.kinds(hasCamera: true, hasMemory: false) == [.camera, .library, .companion])
        #expect(QuickActionPlan.kinds(hasCamera: false, hasMemory: false) == [.library, .companion])
    }

    @Test func unknownTypesAreIgnored() {
        #expect(QuickActionKind(rawValue: "app.meowverse.settings") == nil)
    }

    /// Only a piece that has a photo is a memory, in the room or in the storage box.
    @Test func memoriesAreThePiecesWithPhotos() async throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, catalog: try TestSupport.catalog())
        let chair = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 71),
                                                       placement: Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2),
                                                       displayName: "椅", decision: .manual)
        _ = try await store.addFurniture(placement: Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1), displayName: "凳")
        #expect(QuickActionPlan.memoryCandidates(in: await store.snapshot()) == [chair.instanceId])

        try await store.stowFurniture(instanceId: chair.instanceId)
        #expect(QuickActionPlan.memoryCandidates(in: await store.snapshot()) == [chair.instanceId])
        #expect(QuickActionPlan.memoryCandidates(in: .empty).isEmpty)
    }

    @Test func theMemoryIsChosenAtRandomAmongThem() {
        var generator = SystemRandomNumberGenerator()
        #expect(QuickActionPlan.pickMemory(from: [], using: &generator) == nil)
        var seen = Set<String>()
        for _ in 0..<200 { seen.insert(QuickActionPlan.pickMemory(from: ["a", "b", "c"], using: &generator) ?? "") }
        #expect(seen == ["a", "b", "c"])
    }
}
