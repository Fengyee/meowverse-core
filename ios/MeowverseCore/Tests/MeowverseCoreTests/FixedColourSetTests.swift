import Foundation
import Testing
@testable import MeowverseCore

/// The theme sets have their own colours and cannot be recoloured (owner, 2026-11-21).
@Suite struct FixedColourSetTests {
    private static let json = """
    {"version":1,
     "presets":[{"id":"oat","label":{"zh":"燕麦","en":"Oat"},"swatch":[0.9,0.8,0.7]},
                {"id":"sage","label":{"zh":"鼠尾草","en":"Sage"},"swatch":[0.5,0.6,0.5]}],
     "finishes":{"original":null,"cream":"oat","sage":"sage","blue":"oat"},
     "models":{
      "set-sofa":{"defaultPreset":"oat","fixedColours":true,"presets":{
        "oat":{"primary-fabric":{"color":[0.545,0.161,0.259],"roughness":0.8,"metallic":0,"sheen":0.1,"clearcoat":0,"clearcoatRoughness":0}},
        "sage":{"primary-fabric":{"color":[0.1,0.9,0.1],"roughness":0.8,"metallic":0,"sheen":0,"clearcoat":0,"clearcoatRoughness":0}}}},
      "plain-sofa":{"defaultPreset":"oat","presets":{
        "oat":{"primary-fabric":{"color":[0.9,0.8,0.7],"roughness":0.8,"metallic":0,"sheen":0,"clearcoat":0,"clearcoatRoughness":0}},
        "sage":{"primary-fabric":{"color":[0.5,0.6,0.5],"roughness":0.8,"metallic":0,"sheen":0,"clearcoat":0,"clearcoatRoughness":0}}}}}}
    """

    private func looks() throws -> FurnitureLooks { try FurnitureLooks(data: Data(Self.json.utf8)) }

    @Test(arguments: Finish.allCases)
    func everyStoredFinishDrawsTheSetsOwnColour(finish: Finish) throws {
        let looks = try looks()
        #expect(looks.material(modelId: "set-sofa", finish: finish, slot: "primary-fabric")?.color == [0.545, 0.161, 0.259])
        #expect(looks.presetId(for: finish, modelId: "set-sofa") == "oat")
    }

    @Test func aSetOffersNoSwatches() throws {
        let offered = try #require(try looks().pickerFinishes(modelId: "set-sofa"), "nil would bring back every v1 finish")
        #expect(offered.isEmpty)
    }

    @Test func ordinaryFurnitureStillRecolours() throws {
        let looks = try looks()
        #expect(looks.pickerFinishes(modelId: "plain-sofa")?.count == 2)
        #expect(looks.material(modelId: "plain-sofa", finish: .sage, slot: "primary-fabric")?.color == [0.5, 0.6, 0.5])
    }
}
