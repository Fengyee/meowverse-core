import Foundation
import Testing
@testable import MeowverseCore

/// The room caption names where Bella rests (`BellaStatus.caption` in the app). Round 10's site
/// labels said the piece twice ("在纸箱的纸箱里", "on the in the box of the cardboard box"), so
/// they get a caption place of their own; every older label keeps the wording it always had.
@Suite struct CaptionPlaceTests {
    let catalog: FurnitureCatalog
    init() throws { catalog = try FurnitureCatalog.bundled() }

    static let round10 = GridRules.newPieces

    @Test func round10SitesHaveTheirOwnCaptionPlace() throws {
        let expected: [String: [String: CaptionPlace]] = [
            "mv-sofa-d": ["seat-left": .part("左座垫"), "seat-right": .part("右座垫"), "seat-middle": .part("座垫中间")],
            "mv-hideout-d": ["in-box": .insidePiece, "peek": .part("门洞")],
            "mv-chair-d": ["seat": .part("座位")],
            "mv-chair-e": ["seat": .part("座位"), "nap": .part("坐垫")],
            "mv-bed-f": ["nest": .part("软垫")],
            "mv-toy-g": ["wheel": .insidePiece],
        ]
        #expect(Set(expected.keys) == Self.round10)
        for (id, sites) in expected {
            let model = try #require(catalog.model(id: id))
            #expect(Set(model.interactionSites.map(\.id)) == Set(sites.keys), "\(id)")
            for site in model.interactionSites {
                #expect(CaptionPlace.forSite(site.label) == sites[site.id], "\(id)/\(site.id) \(site.label)")
            }
        }
    }

    /// Only labels of round 10's pieces are remapped, so no older piece's caption changes.
    @Test func everyOtherSiteKeepsItsLabel() {
        var older = 0
        for model in catalog.models where !Self.round10.contains(model.id) {
            for site in model.interactionSites {
                #expect(CaptionPlace.forSite(site.label) == .part(site.label), "\(model.id)/\(site.id) \(site.label)")
                older += 1
            }
        }
        #expect(older > 100)
        let round10Labels = Set(catalog.models.filter { Self.round10.contains($0.id) }.flatMap(\.interactionSites).map(\.label))
        #expect(Set(CaptionPlace.overrides.keys).isSubset(of: round10Labels))
    }

    /// Each part named by an override is a built-in name with an English translation, so the
    /// English caption says "the doorway", not the Chinese word.
    @Test func everyNewCaptionPartHasAnEnglishName() throws {
        let file = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../Meowverse/CatalogNames.xcstrings").standardized
        let strings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])["strings"] as? [String: Any]
        for case .part(let name) in CaptionPlace.overrides.values {
            let entry = try #require(strings?[name] as? [String: Any], "\(name) is in CatalogNames")
            let english = ((entry["localizations"] as? [String: Any])?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
            #expect((english?["value"] as? String)?.isEmpty == false, "\(name) has an English name")
        }
    }
}
