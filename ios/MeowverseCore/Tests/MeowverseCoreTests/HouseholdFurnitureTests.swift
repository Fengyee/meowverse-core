import Foundation
import Testing
@testable import MeowverseCore

/// Round 7 household furniture (art/furniture/TECH_SPEC.md §4, §5): ten catalogue-only
/// categories, and decorative pieces the cat walks round instead of using.
@Suite struct HouseholdFurnitureTests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try FurnitureCatalog.bundled() }

    static let household: [FurnitureCategory] = [.bookcase, .sideboard, .mediaConsole, .writingDesk, .vanity,
                                                 .coatRack, .floorLamp, .roomDivider, .plantStand, .fireplace]

    @Test func everyHouseholdCategoryShipsWithHyphenatedIds() {
        let kebab: [FurnitureCategory: String] = [.bookcase: "bookcase", .sideboard: "sideboard", .mediaConsole: "media-console",
            .writingDesk: "writing-desk", .vanity: "vanity", .coatRack: "coat-rack", .floorLamp: "floor-lamp",
            .roomDivider: "room-divider", .plantStand: "plant-stand", .fireplace: "fireplace"]
        for category in Self.household {
            let models = catalog.models(in: category)
            #expect(!models.isEmpty, "\(category) has a model in the catalogue")
            for model in models {
                #expect(model.id.wholeMatch(of: /mv-[a-z]+(-[a-z]+)*-[a-z]/) != nil && model.id.hasPrefix("mv-\(kebab[category]!)-"), "\(model.id)")
                #expect(model.mount == .floor)
            }
        }
    }

    @Test func aDecorativePieceHasNothingForTheCat() throws {
        let hearth = try #require(catalog.model(id: "mv-fireplace-a"))
        #expect(hearth.sites == [])
        #expect(hearth.isDecorative && hearth.interactionSites.isEmpty)
        let bookcase = try #require(catalog.model(id: "mv-bookcase-a"))
        #expect(!bookcase.isDecorative && bookcase.interactionSites.contains { $0.actions.contains(.loaf) })
        // Legacy models (no site list) still get their synthesised seat, and are not decorative.
        let legacy = try #require(catalog.models.first { $0.sites == nil && $0.mount == .floor })
        #expect(!legacy.isDecorative && legacy.interactionSites.count == 1)
    }

    /// An explicit empty list is the decorative rule; it used to be refused as badSites.
    @Test func theCatalogueAcceptsAnExplicitlyEmptySiteList() throws {
        let json = """
        {"models":[{"id":"mv-floor-lamp-z","label":"测试灯","category":"floorLamp","defaultSize":[2,2],"sizes":[[2,2]],
        "path":"mv/mv-floor-lamp-z.json","sha256":"x","bytes":1,"bounds":{"min":[-1,0,-1],"max":[1,6,1]},"triangles":1,
        "orientationY":0,"seat":{"position":[0,0,0],"facing":0},"sites":[]}]}
        """
        let decoded = try FurnitureCatalog(data: Data(json.utf8))
        #expect(decoded.models.first?.isDecorative == true)
    }

    func piece(_ modelId: String, x: Int, z: Int, width: Int, depth: Int) -> PhotoFurniture {
        PhotoFurniture(instanceId: modelId, modelId: modelId, x: x, z: z, width: width, depth: depth, turn: 0, wall: nil,
                       finish: .original, displayName: modelId, sources: [], tags: [], revision: 1,
                       createdAt: Date(timeIntervalSince1970: 0))
    }

    /// She never picks a decorative piece, never stands inside it, and still uses the rest.
    @Test func theCatWalksRoundDecorativePiecesAndUsesTheOthers() throws {
        let hearth = piece("mv-fireplace-a", x: 3, z: 3, width: 3, depth: 2)
        let alone = [hearth]
        for step in 0..<20 {
            let trip = CatRoutine.nextTrip(items: alone, from: .atEntrance, sample: Double(step) / 20, catalog: catalog)
            #expect(trip.end.itemId == nil && trip.seat == nil, "nothing to visit: she stays on the floor")
            let blocked = GridRules.blockedCells(alone)
            #expect(trip.path.allSatisfy { !blocked.contains($0) }, "the hearth is an obstacle")
        }
        #expect(CatRoutine.invitedTrip(items: alone, from: .atEntrance, catalog: catalog, itemId: hearth.instanceId,
                                       siteId: "seat", action: .sit) == nil)
        let bookcase = piece("mv-bookcase-a", x: 7, z: 6, width: 3, depth: 2)
        let room = [hearth, bookcase]
        var visited = Set<String>()
        for step in 0..<20 {
            let trip = CatRoutine.nextTrip(items: room, from: .atEntrance, sample: Double(step) / 20, catalog: catalog)
            if let id = trip.end.itemId { visited.insert(id) }
        }
        #expect(visited == [bookcase.instanceId])
    }

    /// The owner's soft furnishings that stand on the floor: two toys batted at ground level (the
    /// raised bat reaches 0.70 up, far above them) and two beds.
    @Test func softFurnishingsJoinTheToysAndBeds() throws {
        for id in ["mv-toy-e", "mv-toy-f"] {
            let toy = try #require(catalog.model(id: id))
            #expect(toy.category == .toy && !toy.isDecorative)
            #expect(toy.interactionSites.allSatisfy { $0.actions == [.play] && $0.batsAtGround }, "\(id)")
        }
        // The other toys keep the raised bat.
        #expect(catalog.model(id: "mv-toy-d")?.interactionSites.allSatisfy { !$0.batsAtGround } == true)
        for id in ["mv-bed-d", "mv-bed-e"] {
            let bed = try #require(catalog.model(id: id))
            #expect(bed.category == .bed && bed.interactionSites.contains { $0.actions.contains(.sleep) }, "\(id)")
        }
    }

    /// Catalogue only this round: photo recognition never names them and the photo review's
    /// manual list leaves them out.
    @Test func householdCategoriesAreNotRecognisedFromPhotos() {
        let recognised = Set(VisionFurnitureRecognizer.labelTable.values)
        for category in Self.household {
            #expect(!recognised.contains(category), "\(category)")
            #expect(!category.isRecognisedFromPhotos)
        }
        #expect(FurnitureCategory.allCases.filter(\.isRecognisedFromPhotos).count == 15)
    }
}
