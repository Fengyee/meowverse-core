import AppIntents
import Foundation
import Testing

/// Round 11, owner: the "Keep Me Company" control can be set to start company with a chosen
/// expression (`ios/PocketCatShared/PocketCatCompanyMood.swift` and `PocketCatCompanyToggle.swift`,
/// compiled in here through the `PocketCatShared` symlinks), and a change of expression from the
/// Live Activity reaches the widgets and the control.
@Suite struct PocketCatCompanyMoodTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func shelf() -> PocketCatCompanyShelf {
        let name = "PocketCatCompanyMoodTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return PocketCatCompanyShelf(defaults: defaults)
    }

    // MARK: The default

    /// A control added before it could be configured, or never configured, starts company
    /// exactly as it did: asleep.
    @Test func theDefaultIsAsleepAsBefore() {
        #expect(PocketCatCompanyToggle.defaultMood == .sleeping)
        #expect(PocketCatCompanyToggle.startingMood(nil) == .sleeping)
    }

    @Test(arguments: PocketCatMood.allCases)
    func aChosenMoodIsTheOneCompanyStartsWith(mood: PocketCatMood) {
        #expect(PocketCatCompanyToggle.startingMood(mood) == mood)
        #expect(PocketCatCompanyToggle.action(turningOn: true, ongoing: [], mood: mood) == .start(mood))
    }

    /// Already keeping company: turning the control on keeps the running companion as it is,
    /// whatever mood the control is set to.
    @Test(arguments: PocketCatMood.allCases)
    func aRunningCompanionIsKeptWhateverTheChoice(mood: PocketCatMood) {
        #expect(PocketCatCompanyToggle.action(turningOn: true, ongoing: ["A"], mood: mood) == .adopt("A"))
        #expect(PocketCatCompanyToggle.action(turningOn: false, ongoing: ["A"], mood: mood) == .end(["A"]))
    }

    // MARK: The choice as the system offers it

    /// Every expression can be chosen, under the same name the widgets and the companion page
    /// use, and the value stored for each is the mood's own raw value (so a saved choice
    /// survives a reorder of the cases).
    @Test func everyMoodIsOfferedUnderItsTitle() {
        #expect(Set(PocketCatMood.caseDisplayRepresentations.keys) == Set(PocketCatMood.allCases))
        for mood in PocketCatMood.allCases {
            let shown = PocketCatMood.caseDisplayRepresentations[mood]?.title
            #expect(shown?.key == mood.title.key, "\(mood)")
            #expect(shown?.table == "PocketCat")
            #expect(PocketCatMood(rawValue: mood.rawValue) == mood)
        }
    }

    /// The setting is called "Expression", as on the companion page and "Change expression".
    @Test func theChoiceIsCalledExpression() {
        #expect(PocketCatMood.typeDisplayRepresentation.name.key == "Expression")
        #expect(PocketCatMood.typeDisplayRepresentation.name.table == "PocketCat")
    }

    /// The control's title carries the chosen expression ("陪我一会儿 · 在玩"), as one string
    /// with a placeholder, so a translation can put the expression where its language wants it.
    @Test func theControlsTitleNamesTheChosenMood() {
        let title = PocketCatCompanyToggle.title(.playing)
        #expect(title.key == "Keep Me Company · %@")
        #expect(title.table == "PocketCat")
        // No PocketCat table in the test bundle, so the key's own English comes back, filled in.
        for mood in PocketCatMood.allCases {
            #expect(String(localized: PocketCatCompanyToggle.title(mood)) == "Keep Me Company · " + String(localized: mood.title))
        }
        #expect(String(localized: PocketCatCompanyToggle.title(.playing)) == "Keep Me Company · Playing")
        #expect(String(localized: PocketCatCompanyToggle.title(nil)) == "Keep Me Company · Sleeping")
    }

    /// Company started by the control begins on the chosen expression and rotates from there at
    /// the usual pace; an unset choice begins asleep, as before.
    @Test(arguments: PocketCatMood.allCases)
    func companyStartsOnTheChosenMood(mood: PocketCatMood) {
        let state = PocketCatCompanyToggle.startingState(mood, at: t0)
        #expect(state.mood == mood)
        #expect(state.mood(at: t0) == mood)
        #expect(state.mood(at: t0.addingTimeInterval(PocketCatRotation.standardInterval - 1)) == mood)
        #expect(state.rotation?.interval == PocketCatRotation.standardInterval)
        #expect(state.rotation?.startedAt == t0)
    }

    @Test func anUnsetChoiceStartsAsleep() {
        #expect(PocketCatCompanyToggle.startingState(nil, at: t0).mood == .sleeping)
    }

    /// The control's configuration starts on the default, so a control already in Control
    /// Center behaves as before.
    @Test func theConfigurationStartsOnTheDefault() throws {
        guard #available(macOS 26.0, *) else { return }
        let configuration = PocketCatCompanyConfiguration()
        #expect(configuration.mood == PocketCatCompanyToggle.defaultMood)
        #expect(PocketCatCompanyConfiguration(mood: .zoomies).mood == .zoomies)
    }

    // MARK: A change from the Live Activity

    /// "Change expression" on the Lock Screen or in the Dynamic Island writes the new state to
    /// the App Group (`PocketCatCompanyMirror.kept`): the widgets plan from it, and the control
    /// stays on.
    @Test(arguments: PocketCatMood.allCases)
    func aChangeFromTheLiveActivityReachesTheWidgetsAndTheControl(chosen: PocketCatMood) throws {
        let shelf = shelf()
        let started = PocketCatCompanyToggle.startingState(chosen, at: t0)
        shelf.keep(sessionID: "A", state: started, at: t0)
        let later = t0.addingTimeInterval(70)
        // What `ChangePocketCatMood` writes (`Activity.changeExpression`).
        let changed = started.changed(at: later)
        #expect(changed.mood == chosen.next)
        #expect(changed.rotation?.interval == started.rotation?.interval)
        shelf.keep(sessionID: "A", state: changed, at: later)

        let now = later.addingTimeInterval(1)
        let companion = try #require(shelf.companion(at: now))
        let plan = PocketCatWidgetPlan.plan(at: now, companion: companion)
        #expect(plan.moments.first?.mood == chosen.next)
        #expect(plan.moments.first?.button == .change(sessionID: "A"))
        #expect(PocketCatCompanyToggle.isOn(shelf, at: now))
        // The start keeps its place for the eight-hour limit.
        #expect(shelf.record?.startedAt == t0)
    }

    /// The control's start reaching the App Group after the Lock Screen's change (it was slow
    /// to write) doesn't put the chosen expression back over the newer one.
    @Test func aLateStartDoesNotUndoTheChange() throws {
        let shelf = shelf()
        let started = PocketCatCompanyToggle.startingState(.playing, at: t0)
        let changed = started.changed(at: t0.addingTimeInterval(30))
        shelf.keep(sessionID: "A", state: changed, at: t0.addingTimeInterval(30))
        shelf.keep(sessionID: "A", state: started, at: t0.addingTimeInterval(31))
        #expect(shelf.record?.state == changed)
    }

    /// The change follows what the Lock Screen shows at that moment, not the expression company
    /// started on: after the rotation has moved on, the next one is after the current one.
    @Test func aChangeAfterTheRotationMovedOnFollowsTheCurrentExpression() {
        let started = PocketCatCompanyToggle.startingState(.eating, at: t0)
        let later = t0.addingTimeInterval(PocketCatRotation.standardInterval * 2 + 10)
        let showing = started.mood(at: later)
        #expect(started.changed(at: later).mood == showing.next)
    }
}
