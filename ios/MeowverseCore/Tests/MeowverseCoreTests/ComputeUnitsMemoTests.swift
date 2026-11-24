import Foundation
import Testing
@testable import MeowverseCore

/// The self-check runs once per build, iOS version and model revision; its answer, either way,
/// is reused until one of them changes.
@Suite struct ComputeUnitsMemoTests {
    private func defaults() -> UserDefaults {
        let name = "ComputeUnitsMemoTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aCheckIsRememberedOnlyForItsBuildOSAndModel() {
        let store = defaults()
        let here = ComputeUnitsMemo.scope(build: "59", os: "27.1", modelRevision: 2)
        #expect(ComputeUnitsMemo.recall(here, in: store) == nil, "first load of this build: the check runs")
        ComputeUnitsMemo.remember(.requested, for: here, in: store)
        #expect(ComputeUnitsMemo.recall(here, in: store) == .requested)
        #expect(ComputeUnitsMemo.recall(ComputeUnitsMemo.scope(build: "60", os: "27.1", modelRevision: 2), in: store) == nil)
        #expect(ComputeUnitsMemo.recall(ComputeUnitsMemo.scope(build: "59", os: "27.2", modelRevision: 2), in: store) == nil)
        #expect(ComputeUnitsMemo.recall(ComputeUnitsMemo.scope(build: "59", os: "27.1", modelRevision: 3), in: store) == nil)
    }

    @Test func aFailedCheckIsRememberedAsCPUOnlyAndANewScopeReplacesTheOld() {
        let store = defaults()
        let old = ComputeUnitsMemo.scope(build: "59", os: "27.1", modelRevision: 2)
        ComputeUnitsMemo.remember(.cpuOnly, for: old, in: store)
        #expect(ComputeUnitsMemo.recall(old, in: store) == .cpuOnly)
        let new = ComputeUnitsMemo.scope(build: "60", os: "27.1", modelRevision: 2)
        ComputeUnitsMemo.remember(.requested, for: new, in: store)
        #expect(ComputeUnitsMemo.recall(new, in: store) == .requested)
        #expect(ComputeUnitsMemo.recall(old, in: store) == nil, "one entry: an update does not leave old answers behind")
        store.set(["scope": new, "choice": "garbage"], forKey: ComputeUnitsMemo.defaultsKey)
        #expect(ComputeUnitsMemo.recall(new, in: store) == nil, "an unreadable entry means: check again")
    }
}
