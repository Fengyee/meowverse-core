import Foundation

/// 设置 › 画质 (owner, 2026-11-20): how much the room scene costs to draw. The choice is a device
/// setting, kept in UserDefaults; it is not in the library, its backups or sync.
public enum RenderQualityChoice: String, CaseIterable, Sendable {
    /// By the device's memory (`RenderQuality.deviceTier`), one step lower after running hot.
    case auto, high, medium, low

    /// Anything unknown or missing (a first launch, a value from a later version) is 自动.
    public init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .auto
    }

    /// The tier a fixed choice always gives; nil for 自动.
    public var fixedTier: RenderQualityTier? {
        switch self {
        case .auto: nil
        case .high: .high
        case .medium: .medium
        case .low: .low
        }
    }
}

/// What the room actually draws with.
public enum RenderQualityTier: Int, CaseIterable, Comparable, Sendable {
    case low = 0, medium, high

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// One step cheaper; low stays low.
    public var lower: Self { Self(rawValue: rawValue - 1) ?? .low }

    public var settings: RenderQualitySettings {
        switch self {
        case .high: RenderQualitySettings(maxRenderScale: 3, sunShadows: true, furnitureTextureLimit: 256, furnitureOcclusion: true,
                                          softFloorShadows: true, hdrEnvironment: true, furnitureSurfaceMaps: true)
        case .medium: RenderQualitySettings(maxRenderScale: 1.75, sunShadows: true, furnitureTextureLimit: 128, furnitureOcclusion: true)
        case .low: RenderQualitySettings(maxRenderScale: 1.5, sunShadows: false, furnitureTextureLimit: 0, furnitureOcclusion: true)
        }
    }
}

public struct RenderQualitySettings: Equatable, Sendable {
    /// The most pixels per point the room is drawn with; the screen's own scale caps it.
    public let maxRenderScale: Double
    /// The sun casts shadows (furniture and cats on the floor and walls).
    public let sunShadows: Bool
    /// Maximum edge of an optional authored furniture base colour, in pixels. Zero uses the palette colour.
    public let furnitureTextureLimit: Int

    /// A geometry-baked ambient occlusion term on catalog furniture.
    public let furnitureOcclusion: Bool

    public let softFloorShadows: Bool
    public let hdrEnvironment: Bool
    public let furnitureSurfaceMaps: Bool

    public init(maxRenderScale: Double, sunShadows: Bool, furnitureTextureLimit: Int, furnitureOcclusion: Bool = true,
                softFloorShadows: Bool = false, hdrEnvironment: Bool = false, furnitureSurfaceMaps: Bool = false) {
        self.maxRenderScale = maxRenderScale
        self.sunShadows = sunShadows
        self.furnitureTextureLimit = furnitureTextureLimit
        self.furnitureOcclusion = furnitureOcclusion
        self.softFloorShadows = softFloorShadows
        self.hdrEnvironment = hdrEnvironment
        self.furnitureSurfaceMaps = furnitureSurfaceMaps
    }

    public func renderScale(screenScale: Double) -> Double { min(screenScale, maxRenderScale) }
}

public enum RenderQuality {
    /// Below this the device is a 4 GB (or smaller) one. Devices report a little less than the
    /// box says (a 4 GB phone about 3.7 GiB, a 6 GB one about 5.6 GiB), so the cut-offs sit
    /// halfway between the classes rather than at them.
    public static let mediumFrom: UInt64 = 5 << 30
    /// From here on the device is an 8 GB (or larger) one: 8 GB phones report about 7.5 GiB.
    public static let highFrom: UInt64 = 7 << 30

    /// What 自动 gives this device (`ProcessInfo.physicalMemory`).
    public static func deviceTier(physicalMemory: UInt64) -> RenderQualityTier {
        if physicalMemory >= highFrom { return .high }
        if physicalMemory >= mediumFrom { return .medium }
        return .low
    }

    /// Serious and critical are hot; nominal and fair are not.
    public static func isHot(_ thermal: ProcessInfo.ThermalState) -> Bool {
        thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }
}

/// The choice and the device, with the drop for heat: on 自动, the first time the device runs
/// hot (`thermalState` serious or above) the tier goes one step down and stays there until the
/// next launch. Cooling off does not bring it back, a second hot spell does not drop it again,
/// and a fixed choice is never changed for the user.
public struct RenderQualityState: Equatable, Sendable {
    public private(set) var choice: RenderQualityChoice
    /// What the device's memory gives (`RenderQuality.deviceTier`).
    public let deviceTier: RenderQualityTier
    /// The device ran hot on 自动 during this launch.
    public private(set) var steppedDown = false

    public init(choice: RenderQualityChoice, deviceTier: RenderQualityTier) {
        self.choice = choice
        self.deviceTier = deviceTier
    }

    /// What 自动 gives now.
    public var autoTier: RenderQualityTier { steppedDown ? deviceTier.lower : deviceTier }

    /// What the room draws with now.
    public var tier: RenderQualityTier { choice.fixedTier ?? autoTier }

    /// A thermal reading. True when it just lowered what the room draws, so the app tells the
    /// user (once); nothing is said when there was nothing to lower.
    @discardableResult
    public mutating func observe(_ thermal: ProcessInfo.ThermalState) -> Bool {
        guard choice == .auto, !steppedDown, RenderQuality.isHot(thermal) else { return false }
        let before = tier
        steppedDown = true
        return tier < before
    }

    /// The user picks a choice. Picking 自动 while the device is hot takes the drop at once;
    /// true when that lowered the tier (the same notice as `observe`).
    @discardableResult
    public mutating func choose(_ choice: RenderQualityChoice, thermal: ProcessInfo.ThermalState) -> Bool {
        self.choice = choice
        return observe(thermal)
    }
}
