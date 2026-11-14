import Foundation
import Testing
@testable import MeowverseCore

@Suite struct CatPlayTests {
    private let catalog: FurnitureCatalog
    init() throws { catalog = try TestSupport.catalog() }

    private func obstacle(x: Int, z: Int, width: Int = 2, depth: Int = 2) -> PhotoFurniture {
        PhotoFurniture(instanceId: "obstacle", modelId: "kenney-chair", x: x, z: z,
                       width: width, depth: depth, turn: 0, finish: .original, displayName: "椅子",
                       sources: [.manual(photoId: "p")], tags: [], revision: 1)
    }

    @Test(arguments: CatPlayItem.allCases) func emptyRoomTargetsHaveSafeApproachAndExactContact(item: CatPlayItem) throws {
        for z in 0..<GridRules.size {
            for x in 0..<GridRules.size {
                let request = CatPlayRequest(item: item, cell: GridCell(x: x, z: z))
                let trip = try #require(CatRoutine.playTrip(items: [], from: .atEntrance, catalog: catalog, request: request))
                #expect(abs(trip.end.cell.x - x) + abs(trip.end.cell.z - z) == 1)
                #expect(trip.end.itemId == nil && trip.end.siteId == nil && trip.end.action == item.action)
                #expect(trip.path.last == trip.end.cell)
                let end = try #require(trip.seat), half = Double(GridRules.size) / 2
                #expect(Int(floor(end.x + half)) == trip.end.cell.x)
                #expect(Int(floor(end.z + half)) == trip.end.cell.z)
                let point = request.point
                let localX: Double, localZ: Double
                switch item {
                case .treatSalmon, .treatChicken, .treatBiscuit: (localX, localZ) = (-0.097085, 0.62)
                case .toyMouse, .toyBall: (localX, localZ) = (0.013701, 0.55)
                case .featherWand: (localX, localZ) = (-0.15, 0.807)
                }
                let yaw = trip.rotation
                #expect(abs(end.x + cos(yaw) * localX + sin(yaw) * localZ - point.x) < 1e-6)
                #expect(abs(end.z - sin(yaw) * localX + cos(yaw) * localZ - point.z) < 1e-6)
            }
        }
    }

    @Test func rejectsOutOfRoomOccupiedAndEnclosedTargets() {
        for cell in [GridCell(x: -1, z: 3), GridCell(x: 15, z: 3), GridCell(x: 1, z: 15)] {
            #expect(CatRoutine.playTrip(items: [], from: .atEntrance, catalog: catalog,
                                        request: CatPlayRequest(item: .toyBall, cell: cell)) == nil)
        }
        let chair = obstacle(x: 3, z: 3)
        #expect(CatRoutine.playTrip(items: [chair], from: .atEntrance, catalog: catalog,
                                    request: CatPlayRequest(item: .toyMouse, cell: GridCell(x: 3, z: 3))) == nil)
        let corner = [obstacle(x: 0, z: 1), obstacle(x: 1, z: 0)]
        #expect(CatRoutine.playTrip(items: corner, from: .atEntrance, catalog: catalog,
                                    request: CatPlayRequest(item: .toyBall, cell: GridCell(x: 0, z: 0))) == nil)
    }

    @Test func routeWalksAroundFurnitureAndRetainsSafeExitFromASeat() throws {
        let chair = obstacle(x: 3, z: 3)
        let seated = try #require(CatRoutine.invitedTrip(items: [chair], from: .atEntrance,
                                                        catalog: catalog, itemId: chair.instanceId,
                                                        siteId: "seat", action: .sit))
        let request = CatPlayRequest(item: .treatSalmon, cell: GridCell(x: 3, z: 1))
        let trip = try #require(CatRoutine.playTrip(items: [chair], from: seated.end, catalog: catalog, request: request))
        #expect(trip.leaving == seated.seat && trip.legacyExit)
        #expect(trip.path.first == seated.end.cell)
        let blocked = GridRules.blockedCells([chair])
        #expect(trip.path.allSatisfy { !blocked.contains($0) })
        #expect(zip(trip.path, trip.path.dropFirst()).allSatisfy { abs($0.x - $1.x) + abs($0.z - $1.z) == 1 })
        #expect(trip.end.lastItemId == chair.instanceId)
    }

    @Test func replacingARequestKeepsDistinctConsumptionIdentity() {
        let a = CatPlayRequest(item: .treatChicken, cell: GridCell(x: 4, z: 4))
        let b = CatPlayRequest(item: .treatChicken, cell: a.cell)
        #expect(a.id != b.id)
        #expect(a.item == b.item && a.point == b.point)
        #expect(CatPlayItem.allCases.filter(\.isTreat).count == 3)
    }
}
