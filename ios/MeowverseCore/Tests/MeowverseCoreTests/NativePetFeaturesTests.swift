import Foundation
import Testing
@testable import MeowverseCore

@Suite struct NativePetFeaturesTests {
    @Test func everyBundledPetSiteWorksAtAllFourRotations() throws {
        let catalog = try FurnitureCatalog.bundled()
        // An aliased legacy model opens as its replacement, which this loop covers.
        for model in catalog.models where model.sites != nil && !catalog.isLegacyAlias(model.id) {
            for turn in 0...3 {
                let item = PhotoFurniture(instanceId: model.id, modelId: model.id, x: 2, z: 2,
                                          width: model.defaultWidth, depth: model.defaultDepth, turn: turn,
                                          finish: .original, displayName: model.label, sources: [.manual(photoId: "p")],
                                          tags: [], revision: 1)
                #expect(GridRules.validate(item.placement, in: [], catalog: catalog).isEmpty, "\(model.id)/\(turn)")
                for site in model.interactionSites {
                    for action in site.actions {
                        let trip = try #require(CatRoutine.invitedTrip(items: [item], from: .atEntrance,
                                                                      catalog: catalog, itemId: item.instanceId,
                                                                      siteId: site.id, action: action), "\(model.id)/\(turn)/\(site.id)")
                        #expect(trip.end.action == action && trip.end.siteId == site.id)
                        let exit = CatRoutine.nextTrip(items: [item], from: trip.end, sample: 0.5, catalog: catalog)
                        #expect(exit.leaving == trip.seat && exit.exitVia == trip.entryVia.reversed())
                        #expect(exit.end.itemId == nil)
                    }
                }
            }
        }
    }

    @Test(arguments: ["pet-litter-box", "pet-window-seat", "pet-feeding-station", "pet-flower-fountain", "pet-feather-wand"])
    func eachAdditionSurvivesSaveReopenAndBackupWithOriginalSource(modelId: String) async throws {
        let catalog = try FurnitureCatalog.bundled()
        let model = try #require(catalog.model(id: modelId))
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("library")
        let store = LibraryStore(root: directory, catalog: catalog)
        let placement = try #require(GridRules.firstFreePlacement(for: model, in: [], catalog: catalog))
        let draft = try TestSupport.draft()
        let item = try await store.commitNewFurniture(draft: draft, placement: placement,
                                                      displayName: model.label, decision: .manual)
        let reopen = LibraryStore(root: directory, catalog: catalog)
        let state = try await reopen.load()
        #expect(state.items == [item] && state.observations.isEmpty)
        let photo = try #require(state.photos.first)
        #expect(photo.sha256 == draft.sha256 && photo.captureDateSource == .unknown)
        #expect(item.sources.map(\.untimed) == [.manual(photoId: photo.photoId)])
        #expect(try await reopen.verifyOriginal(photoId: photo.photoId))
        let zip = root.appendingPathComponent("backup.zip")
        _ = try await reopen.exportBackup(to: zip, appVersion: "test")
        let restored = LibraryStore(root: root.appendingPathComponent("restored"), catalog: catalog)
        let prepared = try BackupArchive.prepare(file: zip, stagingURL: restored.makeStagingURL(), catalog: catalog)
        #expect(try await restored.replaceLibrary(with: prepared) == state)
        #expect(try await restored.verifyOriginal(photoId: photo.photoId))
    }
}
