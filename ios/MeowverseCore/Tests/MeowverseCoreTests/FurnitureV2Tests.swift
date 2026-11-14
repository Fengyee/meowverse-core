import Foundation
import Testing
@testable import MeowverseCore

/// The v2 furniture library: legacy-id aliases, catalog validation of authored-size models,
/// mesh format v1/v2 decoding, resolved palette looks and pattern tiles (art/furniture/TECH_SPEC.md).
@Suite struct FurnitureAliasTests {
    /// An mv-style model: authored at 3 model units per cell, front +Z, orientationY 0.
    static func mvModel(id: String = "mv-chair-a", category: String = "chair",
                        sites: [[String: Any]]? = nil) -> [String: Any] {
        [
            "id": id, "label": "圆背椅", "category": category, "defaultSize": [1, 1], "sizes": [[1, 1], [2, 2]],
            "path": "", "sha256": "", "bytes": 0,
            "bounds": ["min": [-1.2, 0, -1.2], "max": [1.2, 3, 1.2]], "triangles": 1200, "orientationY": 0,
            "seat": ["position": [0, 1.4, 0], "facing": 0],
            "sites": sites ?? [["id": "seat", "label": "椅面", "position": [0, 1.4, 0], "facing": 0,
                                "actions": ["sit", "loaf"], "via": []]],
        ]
    }

    static func catalog(models: [[String: Any]], aliases: [[String: Any]]? = nil) throws -> FurnitureCatalog {
        var file: [String: Any] = ["models": models]
        if let aliases { file["aliases"] = aliases }
        return try FurnitureCatalog(data: JSONSerialization.data(withJSONObject: file))
    }

    @Test func legacyIdResolvesToItsTargetModel() throws {
        let catalog = try Self.catalog(models: [Self.mvModel()],
                                       aliases: [["from": "kenney-chair", "to": "mv-chair-a", "category": "chair"]])
        #expect(catalog.model(id: "kenney-chair")?.id == "mv-chair-a")
        #expect(catalog.canonicalId("kenney-chair") == "mv-chair-a")
        #expect(catalog.canonicalId("mv-chair-a") == "mv-chair-a")
        #expect(catalog.canonicalId("nobody") == nil)
        #expect(catalog.isLegacyAlias("kenney-chair"))
        #expect(!catalog.isLegacyAlias("mv-chair-a"))
        // Aliases are not offered as styles of their own.
        #expect(catalog.models(in: .chair).map(\.id) == ["mv-chair-a"])
        #expect(catalog.models.count == 1)
    }

    @Test func anAliasWinsOverTheLegacyModelItReplacesAndHidesItFromNewPlacements() throws {
        var legacy = Self.mvModel(id: "kenney-chair")
        legacy["label"] = "木椅"
        let catalog = try Self.catalog(models: [Self.mvModel(), legacy],
                                       aliases: [["from": "kenney-chair", "to": "mv-chair-a", "category": "chair"]])
        // Saved rooms resolve, draw and edit the legacy id as its replacement.
        #expect(catalog.model(id: "kenney-chair")?.id == "mv-chair-a")
        #expect(catalog.canonicalId("kenney-chair") == "mv-chair-a")
        #expect(catalog.isLegacyAlias("kenney-chair"))
        // The pickers (models(in:)) offer only the replacement.
        #expect(catalog.models(in: .chair).map(\.id) == ["mv-chair-a"])
        let item = PhotoFurniture(instanceId: "old", modelId: "kenney-chair", x: 3, z: 3, width: 2, depth: 2, turn: 0,
                                  finish: .sage, displayName: "木椅", sources: [.manual(photoId: "p")], tags: [], revision: 1)
        #expect(GridRules.validate(item.placement, in: [], catalog: catalog).isEmpty)
        #expect(CatRoutine.invitedTrip(items: [item], from: .atEntrance, catalog: catalog,
                                       itemId: "old", siteId: "seat", action: .loaf) != nil)
    }

    @Test func theBundledPickersHideEveryAliasedLegacyModel() throws {
        let catalog = try FurnitureCatalog.bundled()
        let offered = Set(FurnitureCategory.allCases.flatMap { catalog.models(in: $0).map(\.id) })
        #expect(!offered.contains("pet-lookout-tree"))
        for legacy in ["pet-lookout-tree", "kenney-chair", "pet-sisal-post"] where catalog.isLegacyAlias(legacy) {
            #expect(!offered.contains(legacy))
            #expect(catalog.model(id: legacy)?.id.hasPrefix("mv-") == true)
        }
    }

    @Test func aliasesToMissingModelsOrAnotherCategoryAreRejected() {
        #expect(throws: CatalogError.invalid("badAlias")) {
            try Self.catalog(models: [Self.mvModel()], aliases: [["from": "kenney-sofa", "to": "mv-sofa-a", "category": "sofa"]])
        }
        #expect(throws: CatalogError.invalid("badAlias")) {
            try Self.catalog(models: [Self.mvModel()], aliases: [["from": "kenney-chair", "to": "mv-chair-a", "category": "sofa"]])
        }
        #expect(throws: CatalogError.invalid("badAlias")) {
            try Self.catalog(models: [Self.mvModel()], aliases: [
                ["from": "kenney-chair", "to": "mv-chair-a", "category": "chair"],
                ["from": "kenney-chair", "to": "mv-chair-a", "category": "chair"]])
        }
    }

    @Test func legacyPlacementsKeepWorkingThroughTheAlias() throws {
        let catalog = try Self.catalog(models: [Self.mvModel()],
                                       aliases: [["from": "kenney-chair", "to": "mv-chair-a", "category": "chair"]])
        let item = PhotoFurniture(instanceId: "old", modelId: "kenney-chair", x: 3, z: 3, width: 2, depth: 2, turn: 0,
                                  finish: .sage, displayName: "木椅", sources: [.manual(photoId: "p")], tags: [], revision: 1)
        // Bella still gets onto it, at the new model's site, scaled for the stored 2 × 2 footprint.
        let trip = try #require(CatRoutine.invitedTrip(items: [item], from: .atEntrance, catalog: catalog,
                                                      itemId: "old", siteId: "seat", action: .loaf))
        #expect(trip.end.siteId == "seat")
        let seat = try #require(trip.seat)
        // A bigger stored footprint never scales the model up: it keeps its default-size scale.
        let scale = 1.0 / 3
        #expect(abs(seat.y - 1.4 * scale) < 1e-9)
        #expect(GridRules.validate(item.placement, in: [], catalog: catalog).isEmpty)
    }

    @Test func aFootprintLargerThanTheDefaultKeepsTheDefaultScaleAndCentresTheModel() throws {
        var raw = Self.mvModel()
        raw["bounds"] = ["min": [-1.0, 0, -1.4], "max": [1.4, 3, 1.0]]   // off-centre, 2.4 × 2.4
        let model = try #require(try Self.catalog(models: [raw]).model(id: "mv-chair-a"))
        let base = try #require(GridRules.fit(model, width: 1, depth: 1))
        #expect(abs(base.scale - 0.84 / 2.4) > 1e-9 && abs(base.scale - 1.0 / 3) < 1e-9)
        for (w, d) in [(2, 2), (3, 3), (2, 1), (1, 3)] {
            let fit = try #require(GridRules.fit(model, width: w, depth: d))
            #expect(abs(fit.scale - base.scale) < 1e-12, "\(w)×\(d)")
            // The bounds centre sits on the footprint centre, feet on the floor.
            #expect(zip(fit.offset, [-0.2, 0, 0.2]).allSatisfy { abs($0 - $1) < 1e-12 }, "\(w)×\(d)")
        }
    }

    @Test func aFootprintSmallerThanTheDefaultStillScalesDown() throws {
        var raw = Self.mvModel()
        raw["defaultSize"] = [2, 2]
        raw["bounds"] = ["min": [-2.76, 0, -2.76], "max": [2.76, 3, 2.76]]   // 1.84 cells at 1/3
        let model = try #require(try Self.catalog(models: [raw]).model(id: "mv-chair-a"))
        let big = try #require(GridRules.fit(model, width: 2, depth: 2))
        let small = try #require(GridRules.fit(model, width: 1, depth: 1))
        #expect(abs(big.scale - 1.0 / 3) < 1e-9)
        #expect(abs(small.scale - (1.0 / 3) * 0.84 / 1.84) < 1e-9)
    }

    @Test func authoredSizeSitesAreValidatedInsideTheFootprint() throws {
        // 1 × 1 footprint: |x| ≤ 0.52 cells, 1.56 model units at scale 1/3.
        _ = try Self.catalog(models: [Self.mvModel(sites: [["id": "edge", "label": "边", "position": [1.5, 1.4, 0],
                                                           "facing": 0, "actions": ["sit"], "via": []]])])
        #expect(throws: CatalogError.invalid("badSite")) {
            try Self.catalog(models: [Self.mvModel(sites: [["id": "out", "label": "外", "position": [1.7, 1.4, 0],
                                                           "facing": 0, "actions": ["sit"], "via": []]])])
        }
    }

    @Test func aPawFlatScratchSiteIsReadFromItsPoseHint() throws {
        let catalog = try Self.catalog(models: [Self.mvModel(id: "mv-scratcher-c", category: "scratcher", sites: [
            ["id": "board", "label": "波浪板", "position": [0, 0.3, 0], "facing": 0, "actions": ["scratch"], "via": [],
             "poseHint": "paw-flat"],
            ["id": "post", "label": "立柱", "position": [0, 0.3, 0.5], "facing": 0, "actions": ["scratch"], "via": [],
             "poseHint": "paw-up"],
            ["id": "seat", "label": "椅面", "position": [0, 1.4, 0], "facing": 0, "actions": ["sit"], "via": []],
        ])])
        let sites = try #require(catalog.model(id: "mv-scratcher-c")?.interactionSites)
        #expect(sites.map(\.poseHint) == ["paw-flat", "paw-up", nil])
        #expect(sites.map(\.scratchesFlat) == [true, false, false])
        // The bundled v2 catalog carries the exporter's hints.
        let bundled = try FurnitureCatalog.bundled()
        #expect(bundled.models.flatMap { $0.interactionSites }.contains { $0.poseHint == "paw-up" })
    }
}

@Suite struct FurnitureMeshTests {
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    @Test func versionOneTriangleSoupDecodesOnePartPerGroup() throws {
        let mesh = try FurnitureMesh.decode(Self.json([
            "version": 1,
            "meshes": [[
                "positions": [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1],
                "normals": [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 1, 0, 0, 1, 0, 0, 1, 0],
                "groups": [["start": 0, "count": 3, "materialIndex": 1], ["start": 3, "count": 3, "materialIndex": 0]],
                "materials": [["name": "wood", "color": [0.5, 0.4, 0.3]], ["name": "fabric", "color": [0.9, 0.8, 0.7]]],
            ]],
        ]))
        #expect(mesh.version == 1)
        #expect(mesh.parts.count == 2)
        #expect(mesh.parts[0].material.name == "fabric")
        #expect(mesh.parts[0].material.slot == nil)
        #expect(mesh.parts[0].indices == [0, 1, 2])
        #expect(mesh.parts[1].positions == [0, 0, 1, 1, 0, 1, 0, 1, 1])
        #expect(mesh.parts[1].uvs == nil)
        #expect(mesh.triangleCount == 2)
    }

    @Test func versionOneWithoutGroupsIsOnePartWithMaterialZero() throws {
        let mesh = try FurnitureMesh.decode(Self.json([
            "version": 1,
            "meshes": [["name": "toy-ball", "pivot": [0, 2, 0],
                        "positions": [0, 0, 0, 1, 0, 0, 0, 1, 0], "normals": [0, 0, 1, 0, 0, 1, 0, 0, 1],
                        "groups": [], "materials": [["name": "blush", "color": [1, 0.8, 0.8]]]]],
        ]))
        #expect(mesh.parts.count == 1)
        #expect(mesh.parts[0].pivot == [0, 2, 0])
        #expect(mesh.parts[0].isPendant)
    }

    @Test func versionTwoRebasesEachGroupOntoItsOwnVertexRange() throws {
        let mesh = try FurnitureMesh.decode(Self.json([
            "version": 2, "unitsPerCell": 3,
            "meshes": [[
                "name": "body",
                "positions": [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0, 5, 5, 5, 6, 5, 5, 5, 6, 5],
                "normals": [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 1, 0, 0, 1, 0, 0, 1, 0],
                "uvs": [0, 0, 1, 0, 0, 1, 1, 1, 5, 5, 6, 5, 5, 6],
                "indices": [0, 1, 2, 2, 1, 3, 4, 5, 6],
                "groups": [["start": 0, "count": 6, "materialIndex": 0], ["start": 6, "count": 3, "materialIndex": 1]],
                "materials": [["name": "soft-fill", "slot": "soft-fill", "color": [0.9, 0.9, 0.8]],
                              ["name": "wood", "slot": "wood", "color": [0.6, 0.4, 0.3]]],
            ]],
        ]))
        #expect(mesh.version == 2)
        #expect(mesh.parts.count == 2)
        #expect(mesh.parts[0].indices == [0, 1, 2, 2, 1, 3])
        #expect(mesh.parts[0].positions.count == 12)
        #expect(mesh.parts[1].indices == [0, 1, 2])
        #expect(mesh.parts[1].positions == [5, 5, 5, 6, 5, 5, 5, 6, 5])
        #expect(mesh.parts[1].uvs == [5, 5, 6, 5, 5, 6])
        #expect(mesh.parts[1].material.slot == "wood")
        #expect(mesh.triangleCount == 3)
    }

    @Test func versionTwoRejectsBrokenBuffers() throws {
        func doc(indices: [Int], count: Int, uvs: [Float] = [0, 0, 1, 0, 0, 1]) throws -> Data {
            try Self.json(["version": 2, "meshes": [[
                "name": "body", "positions": [0, 0, 0, 1, 0, 0, 0, 1, 0], "normals": [0, 0, 1, 0, 0, 1, 0, 0, 1],
                "uvs": uvs, "indices": indices, "groups": [["start": 0, "count": count, "materialIndex": 0]],
                "materials": [["name": "wood", "slot": "wood", "color": [1, 1, 1]]]]]])
        }
        #expect(throws: FurnitureMesh.DecodeError.self) { try FurnitureMesh.decode(doc(indices: [0, 1, 3], count: 3)) }
        #expect(throws: FurnitureMesh.DecodeError.self) { try FurnitureMesh.decode(doc(indices: [0, 1, 2], count: 2)) }
        #expect(throws: FurnitureMesh.DecodeError.self) { try FurnitureMesh.decode(doc(indices: [0, 1, 2], count: 6)) }
        #expect(throws: FurnitureMesh.DecodeError.self) { try FurnitureMesh.decode(doc(indices: [0, 1, 2], count: 3, uvs: [0, 0])) }
        #expect(throws: FurnitureMesh.DecodeError.self) {
            try FurnitureMesh.decode(Self.json(["version": 3, "meshes": []]))
        }
    }
}

@Suite struct FurnitureLooksTests {
    static var document: [String: Any] { [
        "version": 1,
        "presets": [["id": "oat", "label": ["zh": "燕麦", "en": "Oat"], "swatch": [0.9, 0.9, 0.8]],
                    ["id": "sage", "label": ["zh": "鼠尾草", "en": "Sage"], "swatch": [0.6, 0.7, 0.6]],
                    ["id": "mist", "label": ["zh": "雾蓝", "en": "Mist"], "swatch": [0.6, 0.7, 0.8]],
                    ["id": "blush", "label": ["zh": "蔷薇", "en": "Blush"], "swatch": [0.9, 0.7, 0.7]]],
        "finishes": ["original": NSNull(), "cream": "oat", "sage": "sage", "blue": "mist"],
        "models": ["mv-sofa-a": [
            "defaultPreset": "blush",
            "presets": [
                "blush": ["primary-fabric": ["color": [0.92, 0.72, 0.75], "roughness": 0.86, "metallic": 0, "sheen": 0.15,
                                             "clearcoat": 0, "clearcoatRoughness": 0,
                                             "pattern": ["id": "gingham", "file": "pattern-gingham", "periodCells": 0.24,
                                                         "angleDeg": 0, "layers": [[0.8, 0.6, 0.6], [0.7, 0.5, 0.5]]]]],
                "oat": ["primary-fabric": ["color": [0.93, 0.89, 0.82], "roughness": 0.86, "metallic": 0, "sheen": 0.15,
                                           "clearcoat": 0, "clearcoatRoughness": 0]],
                "mist": ["primary-fabric": ["color": [0.62, 0.73, 0.83], "roughness": 0.86, "metallic": 0, "sheen": 0.15,
                                            "clearcoat": 0, "clearcoatRoughness": 0]],
            ],
        ]],
    ] }

    /// art-director's picker rule: a v2 model offers one swatch per preset, in presets order, with
    /// no "original"; a piece stored as "original" shows its default preset as selected.
    @Test func pickerOffersPresetsAndShowsOriginalAsTheDefaultPreset() throws {
        let looks = try FurnitureLooks(data: JSONSerialization.data(withJSONObject: Self.document))
        let offered = try #require(looks.pickerFinishes(modelId: "mv-sofa-a"))
        #expect(offered.map(\.finish) == [.cream, .sage, .blue, .blush])
        #expect(offered.map(\.preset.id) == ["oat", "sage", "mist", "blush"])
        #expect(looks.shownFinish(.original, modelId: "mv-sofa-a") == .blush)
        #expect(looks.shownFinish(.sage, modelId: "mv-sofa-a") == .sage)
        #expect(looks.pickerFinishes(modelId: "kenney-chair") == nil, "v1 art keeps the full finish list")
        #expect(looks.shownFinish(.original, modelId: "kenney-chair") == .original)
    }

    @Test func legacyFinishesSelectPresetsAndOriginalIsTheModelDefault() throws {
        let looks = try FurnitureLooks(data: JSONSerialization.data(withJSONObject: Self.document))
        #expect(looks.presetId(for: .original, modelId: "mv-sofa-a") == "blush")
        #expect(looks.presetId(for: .cream, modelId: "mv-sofa-a") == "oat")
        #expect(looks.presetId(for: .blue, modelId: "mv-sofa-a") == "mist")
        // Schema 7 finishes name their preset directly, even when the finishes map predates them.
        #expect(looks.presetId(for: .blush, modelId: "mv-sofa-a") == "blush")
        // A finish whose preset the file does not define falls back to the model's default.
        #expect(looks.presetId(for: .apricot, modelId: "mv-sofa-a") == "blush")
        let pattern = try #require(looks.material(modelId: "mv-sofa-a", finish: .original, slot: "primary-fabric")?.pattern)
        #expect(pattern.file == "pattern-gingham")
        #expect(pattern.layers.count == 2)
        #expect(looks.material(modelId: "mv-sofa-a", finish: .cream, slot: "primary-fabric")?.color == [0.93, 0.89, 0.82])
        // A preset the model has no entry for, an unknown slot and a v1 model: no look, the caller falls back.
        #expect(looks.material(modelId: "mv-sofa-a", finish: .sage, slot: "primary-fabric") == nil)
        #expect(looks.material(modelId: "mv-sofa-a", finish: .cream, slot: "wood") == nil)
        #expect(looks.material(modelId: "kenney-chair", finish: .cream, slot: "wood") == nil)
        #expect(!looks.hasModel("kenney-chair"))
        #expect(looks.presets.map(\.id) == ["oat", "sage", "mist", "blush"])
    }

    @Test func patternTilesComposeLayersInChannelOrder() {
        // Pixels: no coverage, full r, full g over full r, half r.
        let mask: [UInt8] = [0, 0, 0, 255, 0, 0, 255, 255, 0, 128, 0, 0]
        let tile = PatternTile.compose(mask: mask, channels: 3, base: [1, 1, 1], layers: [[0, 0, 0], [1, 0, 0]])
        #expect(tile.count == 16)
        #expect(Array(tile[0..<4]) == [255, 255, 255, 255])
        #expect(Array(tile[4..<8]) == [0, 0, 0, 255])
        #expect(Array(tile[8..<12]) == [255, 0, 0, 255])
        #expect(Array(tile[12..<16]) == [127, 127, 127, 255])
    }
}
