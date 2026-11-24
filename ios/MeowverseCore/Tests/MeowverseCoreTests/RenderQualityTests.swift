import Foundation
import Testing
@testable import MeowverseCore

/// 设置 › 画质 (2026-11-20): the user's choice, the tier 自动 gives by the device's memory, the
/// one-step drop when the device runs hot, and the table of what each tier renders.
@Suite struct RenderQualityTests {
    private static let gib: UInt64 = 1 << 30

    // MARK: Memory class

    /// Devices report a little less than the box says (a 4 GB phone about 3.7 GiB), so each class
    /// is checked at its nominal size and at 90% of it.
    @Test(arguments: [(3.0, RenderQualityTier.low), (4.0, .low), (6.0, .medium), (8.0, .high), (12.0, .high), (16.0, .high)])
    func memoryClassAtNominalAndReportedSizes(nominal: Double, tier: RenderQualityTier) {
        let full = UInt64(nominal * Double(Self.gib))
        #expect(RenderQuality.deviceTier(physicalMemory: full) == tier)
        #expect(RenderQuality.deviceTier(physicalMemory: full / 10 * 9) == tier)
    }

    /// The cut-offs sit between the classes, 5 GiB and 7 GiB, with room on both sides.
    @Test func cutOffsSitBetweenTheClasses() {
        #expect(RenderQuality.deviceTier(physicalMemory: 5 * Self.gib - 1) == .low)
        #expect(RenderQuality.deviceTier(physicalMemory: 5 * Self.gib) == .medium)
        #expect(RenderQuality.deviceTier(physicalMemory: 7 * Self.gib - 1) == .medium)
        #expect(RenderQuality.deviceTier(physicalMemory: 7 * Self.gib) == .high)
        #expect(RenderQuality.deviceTier(physicalMemory: 0) == .low)
    }

    // MARK: Choice

    @Test func storedChoiceReadsBackAndAnythingElseIsAuto() {
        for choice in RenderQualityChoice.allCases {
            #expect(RenderQualityChoice(stored: choice.rawValue) == choice)
        }
        #expect(RenderQualityChoice(stored: nil) == .auto)
        #expect(RenderQualityChoice(stored: "ultra") == .auto)
        #expect(RenderQualityChoice.allCases == [.auto, .high, .medium, .low])
    }

    @Test(arguments: RenderQualityTier.allCases)
    func autoFollowsTheDeviceAndAFixedChoiceIgnoresIt(device: RenderQualityTier) {
        #expect(RenderQualityState(choice: .auto, deviceTier: device).tier == device)
        #expect(RenderQualityState(choice: .high, deviceTier: device).tier == .high)
        #expect(RenderQualityState(choice: .medium, deviceTier: device).tier == .medium)
        #expect(RenderQualityState(choice: .low, deviceTier: device).tier == .low)
    }

    // MARK: Running hot

    @Test(arguments: [ProcessInfo.ThermalState.serious, .critical])
    func runningHotOnAutoDropsOneStepAndSaysSo(hot: ProcessInfo.ThermalState) {
        var high = RenderQualityState(choice: .auto, deviceTier: .high)
        let said1 = high.observe(hot)
        #expect(said1)
        #expect(high.tier == .medium)
        #expect(high.steppedDown)

        var medium = RenderQualityState(choice: .auto, deviceTier: .medium)
        let said2 = medium.observe(hot)
        #expect(said2)
        #expect(medium.tier == .low)
    }

    @Test(arguments: [ProcessInfo.ThermalState.nominal, .fair])
    func warmIsNotHot(state: ProcessInfo.ThermalState) {
        var quality = RenderQualityState(choice: .auto, deviceTier: .high)
        let said3 = quality.observe(state)
        #expect(!said3)
        #expect(quality.tier == .high)
        #expect(!quality.steppedDown)
    }

    /// One step only, and only down, until the next launch: cooling off does not bring it back,
    /// and a second hot spell does not drop it again.
    @Test func onlyOneStepAndOnlyDownUntilTheNextLaunch() {
        var quality = RenderQualityState(choice: .auto, deviceTier: .high)
        let said4 = quality.observe(.serious)
        #expect(said4)
        let said5 = quality.observe(.nominal)
        #expect(!said5)
        #expect(quality.tier == .medium)
        let said6 = quality.observe(.critical)
        #expect(!said6)
        #expect(quality.tier == .medium)
        // The next launch starts afresh.
        #expect(RenderQualityState(choice: .auto, deviceTier: .high).tier == .high)
    }

    /// Already at the bottom: nothing to drop, so no notice.
    @Test func lowHasNothingToDropAndSaysNothing() {
        var quality = RenderQualityState(choice: .auto, deviceTier: .low)
        let said7 = quality.observe(.critical)
        #expect(!said7)
        #expect(quality.tier == .low)
    }

    /// The user's own choice is never changed for them.
    @Test(arguments: [RenderQualityChoice.high, .medium, .low])
    func aFixedChoiceIsNeverChangedForHeat(choice: RenderQualityChoice) {
        var quality = RenderQualityState(choice: choice, deviceTier: .high)
        let said8 = quality.observe(.critical)
        #expect(!said8)
        #expect(quality.tier == choice.fixedTier)
        #expect(!quality.steppedDown)
    }

    /// Switching to 自动 while the device is hot takes the drop at once (and says so); switching
    /// away and back later in the same launch keeps it.
    @Test func choosingAutoWhileHotDropsAndTheDropStaysForTheLaunch() {
        var quality = RenderQualityState(choice: .high, deviceTier: .high)
        let said9 = quality.observe(.serious)
        #expect(!said9)
        let said10 = quality.choose(.auto, thermal: .serious)
        #expect(said10)
        #expect(quality.tier == .medium)
        let said11 = quality.choose(.high, thermal: .nominal)
        #expect(!said11)
        #expect(quality.tier == .high)
        let said12 = quality.choose(.auto, thermal: .nominal)
        #expect(!said12)
        #expect(quality.tier == .medium)
    }

    @Test func choosingAutoWhileCoolKeepsTheDeviceTier() {
        var quality = RenderQualityState(choice: .low, deviceTier: .high)
        let said13 = quality.choose(.auto, thermal: .fair)
        #expect(!said13)
        #expect(quality.tier == .high)
        #expect(quality.autoTier == .high)
    }

    // MARK: What each tier renders

    @Test func highUsesNativeScaleUpToThreeWithShadows() {
        let high = RenderQualityTier.high.settings
        #expect(high.sunShadows)
        #expect(high.renderScale(screenScale: 4) == 3)
        #expect(high.renderScale(screenScale: 3) == 3)
        #expect(high.renderScale(screenScale: 2) == 2)
        #expect(high.renderScale(screenScale: 1) == 1)
    }

    /// Each step down costs no more than the one above it, and saves something.
    @Test func eachStepDownSaves() {
        let tiers = RenderQualityTier.allCases.sorted().reversed().map(\.settings)
        for (upper, lower) in zip(tiers, tiers.dropFirst()) {
            #expect(lower.maxRenderScale <= upper.maxRenderScale)
            #expect(!lower.sunShadows || upper.sunShadows)
            #expect(lower.furnitureTextureLimit < upper.furnitureTextureLimit)
            #expect(lower != upper)
        }
        #expect(RenderQualityTier.medium.settings.renderScale(screenScale: 3) == 1.75)
        #expect(RenderQualityTier.low.settings.renderScale(screenScale: 3) == 1.5)
        #expect(!RenderQualityTier.low.settings.sunShadows)
        // Never above the screen's own scale.
        #expect(RenderQualityTier.medium.settings.renderScale(screenScale: 1) == 1)
    }

    @Test func authoredFurnitureTextureSizes() {
        #expect(RenderQualityTier.low.settings.furnitureTextureLimit == 0)
        #expect(RenderQualityTier.medium.settings.furnitureTextureLimit == 128)
        #expect(RenderQualityTier.high.settings.furnitureTextureLimit == 256)
    }

    @Test func furnitureOcclusionIsAvailableAtEveryTier() {
        #expect(RenderQualityTier.allCases.allSatisfy { $0.settings.furnitureOcclusion })
    }

    @Test func highAddsFloorShadowsHDREnvironmentAndSurfaceMaps() {
        for tier in RenderQualityTier.allCases {
            let settings = tier.settings
            #expect(settings.softFloorShadows == (tier == .high))
            #expect(settings.hdrEnvironment == (tier == .high))
            #expect(settings.furnitureSurfaceMaps == (tier == .high))
        }
    }

    @Test func lowerStopsAtLow() {
        #expect(RenderQualityTier.high.lower == .medium)
        #expect(RenderQualityTier.medium.lower == .low)
        #expect(RenderQualityTier.low.lower == .low)
    }
}
