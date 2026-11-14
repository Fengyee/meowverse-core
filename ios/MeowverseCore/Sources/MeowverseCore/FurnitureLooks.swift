import Foundation

/// Resolved palette looks for v2 furniture (`Resources/Art/furniture-looks.json`, written by
/// art/furniture/blender/export/look.py through the bake). The app does no palette logic: a
/// stored `Finish` picks a preset, and each material slot of a model has ready-made parameters.
public struct FurnitureLooks: Sendable, Equatable {
    public struct Pattern: Codable, Sendable, Equatable {
        public let id: String
        /// Bundle resource name of the mask PNG (`pattern-<id>`).
        public let file: String
        /// Repeat period in cells; UV0 has one unit per cell.
        public let periodCells: Double
        public let angleDeg: Double
        /// sRGB colours of the r, g, b mask layers, in that order.
        public let layers: [[Double]]
    }

    public struct MaterialLook: Codable, Sendable, Equatable {
        /// sRGB 0...1.
        public let color: [Double]
        public let roughness: Double
        public let metallic: Double
        public let sheen: Double
        public let clearcoat: Double
        public let clearcoatRoughness: Double
        public let pattern: Pattern?
    }

    public struct Preset: Codable, Sendable, Equatable {
        public let id: String
        public let label: [String: String]
        public let swatch: [Double]
    }

    private struct ModelLooks: Codable, Sendable, Equatable {
        let defaultPreset: String
        let presets: [String: [String: MaterialLook]]
    }

    private struct File: Codable {
        let version: Int
        let presets: [Preset]
        let finishes: [String: String?]
        let models: [String: ModelLooks]
    }

    public let presets: [Preset]
    private let finishes: [String: String?]
    private let models: [String: ModelLooks]

    public init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.version == 1 else { throw CatalogError.invalid("looksVersion") }
        presets = file.presets
        finishes = file.finishes
        models = file.models
    }

    public static let empty = FurnitureLooks()

    private init() {
        presets = []
        finishes = [:]
        models = [:]
    }

    public func hasModel(_ modelId: String) -> Bool { models[modelId] != nil }

    /// `original` is the model's own default preset; the other legacy finishes map to presets
    /// through `finishes`; a schema 7 finish names its preset. A finish whose preset the file
    /// does not define falls back to the model's default.
    public func presetId(for finish: Finish, modelId: String) -> String? {
        guard let model = models[modelId] else { return nil }
        return mappedPreset(finish) ?? model.defaultPreset
    }

    /// The preset a finish names on its own, without the model-default fallback.
    private func mappedPreset(_ finish: Finish) -> String? {
        if let mapped = finishes[finish.rawValue], let mapped { return mapped }
        if finish != .original, presets.contains(where: { $0.id == finish.rawValue }) { return finish.rawValue }
        return nil
    }

    /// One picker swatch: the finish that is stored and the preset it shows.
    public struct PickerChoice: Sendable, Equatable {
        public let finish: Finish
        public let preset: Preset
    }

    /// The swatches a v2 model offers: one per preset in presets order, no "original" (it is the
    /// default preset). nil for a model without looks (v1 art), which keeps every `Finish`.
    public func pickerFinishes(modelId: String) -> [PickerChoice]? {
        guard hasModel(modelId) else { return nil }
        return presets.compactMap { preset in
            finish(forPreset: preset.id).map { PickerChoice(finish: $0, preset: preset) }
        }
    }

    /// The finish the picker marks as selected: "original" shows as the model's default preset.
    public func shownFinish(_ finish: Finish, modelId: String) -> Finish {
        guard finish == .original, let preset = presetId(for: .original, modelId: modelId) else { return finish }
        return self.finish(forPreset: preset) ?? finish
    }

    private func finish(forPreset id: String) -> Finish? {
        Finish.allCases.first { mappedPreset($0) == id }
    }

    /// nil when the model, the preset or the slot has no look: draw the mesh's own colour.
    public func material(modelId: String, finish: Finish, slot: String) -> MaterialLook? {
        guard let preset = presetId(for: finish, modelId: modelId) else { return nil }
        return models[modelId]?.presets[preset]?[slot]
    }
}

/// Pattern tiles: the mask's channels blend the base colour toward each layer colour in turn
/// (TECH_SPEC §3), giving the RGBA8 texture the material samples. Same rule as the Blender
/// previews, in sRGB.
public enum PatternTile {
    public static func compose(mask: [UInt8], channels: Int, base: [Double], layers: [[Double]]) -> [UInt8] {
        let pixels = channels > 0 ? mask.count / channels : 0
        var out = [UInt8](repeating: 255, count: pixels * 4)
        let usable = layers.prefix(min(3, channels)).filter { $0.count >= 3 }
        for pixel in 0..<pixels {
            var c = (base.count >= 3 ? Array(base.prefix(3)) : [1, 1, 1])
            for (channel, layer) in usable.enumerated() {
                let t = Double(mask[pixel * channels + channel]) / 255
                for k in 0..<3 { c[k] += (layer[k] - c[k]) * t }
            }
            for k in 0..<3 { out[pixel * 4 + k] = UInt8(max(0, min(255, (c[k] * 255).rounded(.toNearestOrEven)))) }
        }
        return out
    }
}
