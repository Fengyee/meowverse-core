import Foundation
import Testing
@testable import MeowverseCore

@Suite struct FurnitureInteractionTests {
    // A turned test model with two levels reached from one stepping platform.
    private func catalog(edit: (inout [[String: Any]]) -> Void = { _ in }) throws -> FurnitureCatalog {
        let json = try #require(JSONSerialization.jsonObject(with: TestSupport.catalogData()) as? [String: Any])
        var model = try #require((json["models"] as? [[String: Any]])?.first)
        var sites: [[String: Any]] = [
            ["id": "top", "label": "高台", "position": [-1, 4, 1], "facing": 0.4,
             "actions": ["sit", "loaf"], "via": [[-1, 2, 0.5]]],
            ["id": "cave", "label": "洞口", "position": [-1.2, 0.3, 0.7], "facing": 0.0,
             "actions": ["hide"], "via": [[-1, 0.3, 0.1]]]
        ]
        edit(&sites)
        model["sites"] = sites
        model["category"] = "catTree"
        return try FurnitureCatalog(data: JSONSerialization.data(withJSONObject: ["models": [model]]))
    }

    private func tree(turn: Int = 0) -> PhotoFurniture {
        PhotoFurniture(instanceId: "tower", modelId: "kenney-chair", x: 3, z: 3, width: 2, depth: 2, turn: turn,
                       finish: .original, displayName: "爬架", sources: [.manual(photoId: "p")], tags: [], revision: 1)
    }

    @Test(arguments: [0, 1, 2, 3]) func visitsExactSiteAndReversesAccessRoute(turn: Int) throws {
        let catalog = try catalog(), item = tree(turn: turn)
        let trip = try #require(CatRoutine.invitedTrip(items: [item], from: .atEntrance, catalog: catalog,
                                                      itemId: item.instanceId, siteId: "top", action: .loaf))
        #expect(trip.end.siteId == "top")
        #expect(trip.end.action == .loaf)
        #expect(trip.entryVia.count == 1)
        #expect(try #require(trip.entryVia.first).y == 2.0 / 3)
        #expect(try #require(trip.seat).y == 4.0 / 3)
        #expect(abs(trip.rotation - (Double(turn) * .pi / 2 + .pi + 0.4)) < 1e-8)
        let exit = CatRoutine.nextTrip(items: [item], from: trip.end, sample: 0.5, catalog: catalog)
        #expect(exit.leaving == trip.seat)
        #expect(exit.exitVia == Array(trip.entryVia.reversed()))
        #expect(exit.path.first == trip.path.last)
        #expect(exit.end.itemId == nil)
        let toCave = try #require(CatRoutine.invitedTrip(items: [item], from: trip.end, catalog: catalog,
                                                       itemId: "tower", siteId: "cave", action: .hide))
        #expect(toCave.leaving == trip.seat)
        #expect(toCave.end.action == .hide)
        #expect(toCave.seat != trip.seat)
    }

    @Test func eachActionComesUpOnSuccessiveVisitsEvenWithConstantRandomSample() throws {
        let catalog = try catalog(), item = tree()
        var rest = CatRest.atEntrance, outcomes = Set<String>()
        for _ in 0..<3 {
            let visit = CatRoutine.nextTrip(items: [item], from: rest, sample: 0.3, catalog: catalog)
            outcomes.insert("\(visit.end.siteId ?? "")/\(visit.end.action.rawValue)")
            rest = CatRoutine.nextTrip(items: [item], from: visit.end, sample: 0.3, catalog: catalog).end
        }
        #expect(outcomes == ["top/sit", "top/loaf", "cave/hide"])
    }

    @Test func staysOnTheSameLandingWhenChangingActivityAndUsesSharedStepsBetweenLevels() throws {
        let catalog = try catalog {
            $0[1]["via"] = [[-1, 2, 0.5]]
        }
        let item = tree()
        func invite(from rest: CatRest, site: String, action: CatAction) throws -> CatTrip {
            try #require(CatRoutine.invitedTrip(items: [item], from: rest, catalog: catalog,
                                               itemId: "tower", siteId: site, action: action))
        }
        let top = try invite(from: .atEntrance, site: "top", action: .sit)
        let settled = try invite(from: top.end, site: "top", action: .loaf)
        #expect(settled.sharedAccessPath == [try #require(top.seat)])
        let changed = try invite(from: settled.end, site: "cave", action: .hide)
        #expect(changed.points == [try #require(top.seat), try #require(top.entryVia.first), try #require(changed.seat)])
    }

    @Test func rejectsUnsupportedOrInaccessibleInvitation() throws {
        let catalog = try catalog()
        var item = tree()
        func invite(_ site: String, _ action: CatAction) -> CatTrip? {
            CatRoutine.invitedTrip(items: [item], from: .atEntrance, catalog: catalog,
                                 itemId: "tower", siteId: site, action: action)
        }
        #expect(invite("removed", .sit) == nil)
        #expect(invite("cave", .play) == nil)
        // Front cell outside the room: refused before schema 6, now she comes in from the side.
        item.z = 13
        #expect(invite("cave", .hide)?.end.cell == GridCell(x: 5, z: 14))
        // Boxed in on every side: no way onto it at all.
        let box = [(3, 11), (5, 13), (2, 13)].enumerated().map { index, at in
            PhotoFurniture(instanceId: "box\(index)", modelId: "kenney-chair", x: at.0, z: at.1, width: 2, depth: 2, turn: 0,
                           finish: .original, displayName: "箱", sources: [], tags: [], revision: 1)
        }
        #expect(CatRoutine.invitedTrip(items: [item] + box, from: .atEntrance, catalog: catalog,
                                       itemId: "tower", siteId: "cave", action: .hide) == nil)
    }

    @Test func occupiedDiagonalApproachInvalidatesTheSiteAndClearsAnOldRest() throws {
        let catalog = try catalog {
            $0[1]["position"] = [1.7, 0.3, -1.7]
            $0[1]["via"] = []
        }
        let item = tree()
        let arriving = try #require(CatRoutine.invitedTrip(items: [item], from: .atEntrance, catalog: catalog,
                                                           itemId: "tower", siteId: "cave", action: .hide))
        let neighbour = PhotoFurniture(instanceId: "stool", modelId: "kenney-stoolBar", x: 3, z: 5,
                                       width: 1, depth: 1, turn: 0, finish: .original, displayName: "凳子",
                                       sources: [.manual(photoId: "p")], tags: [], revision: 1)
        let room = [item, neighbour]
        #expect(CatRoutine.route(items: room, from: GridRules.entrance, to: arriving.end.cell) != nil)
        #expect(CatRoutine.invitedTrip(items: room, from: .atEntrance, catalog: catalog,
                                      itemId: "tower", siteId: "cave", action: .hide) == nil)
        let settled = CatRoutine.settled(arriving.end, items: room, catalog: catalog)
        #expect(settled.itemId == nil && settled.siteId == nil && settled.action == .loaf)
    }

    @Test func visitingNewTowerPreservesConfirmedPhotoThroughNativeBackup() async throws {
        let catalog = try FurnitureCatalog.bundled()
        let model = try #require(catalog.models(in: .catTree).first)
        let parent = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = LibraryStore(root: parent.appendingPathComponent("source"), catalog: catalog)
        let target = LibraryStore(root: parent.appendingPathComponent("target"), catalog: catalog)
        let placement = try #require(GridRules.firstFreePlacement(for: model, in: [], catalog: catalog))
        let confirmed = try await source.commitNewFurniture(draft: TestSupport.draft(), placement: placement,
                                                            displayName: model.label, decision: .manual)
        let state = await source.snapshot()
        #expect(state.observations.isEmpty)
        let site = try #require(model.interactionSites.first { $0.actions.contains(.hide) })
        let trip = try #require(CatRoutine.invitedTrip(items: state.items, from: .atEntrance, catalog: catalog,
                                                      itemId: confirmed.instanceId, siteId: site.id, action: .hide))
        #expect(trip.end.itemId == confirmed.instanceId)
        let archive = parent.appendingPathComponent("synthetic.zip")
        _ = try await source.exportBackup(to: archive, appVersion: "test")
        let backup = try BackupArchive.prepare(file: archive, stagingURL: target.makeStagingURL(), catalog: catalog)
        #expect(try await target.replaceLibrary(with: backup) == state)
        let photo = try #require(state.photos.first)
        #expect(photo.captureDate == nil && confirmed.sources.map(\.untimed) == [.manual(photoId: photo.photoId)])
        #expect(try await target.verifyOriginal(photoId: photo.photoId))
    }

    @Test func catalogRejectsBrokenSites() {
        #expect(throws: (any Error).self) { try catalog { $0.append($0[0]) } }
        #expect(throws: (any Error).self) { try catalog { $0[0]["actions"] = [] } }
        #expect(throws: (any Error).self) { try catalog { $0[0]["via"] = [[42, 2]] } }
        #expect(throws: (any Error).self) { try catalog { $0[0]["position"] = [500, 4, 1] } }
    }
}
