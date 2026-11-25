import Foundation
import Testing

/// The widgets' timeline (`ios/PocketCatShared/PocketCatWidgetPlan.swift`, compiled in here
/// through the `PocketCatShared` symlinks). While a companion runs, the widget must show the
/// same expression as the Live Activity at every moment, and its button must say what it does
/// (art director's review, E1 and E2, `art/ui/reviews/r11-widgets.md`).
@Suite struct PocketCatWidgetPlanTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func companion(_ mood: PocketCatMood = .watching, interval: TimeInterval = 300, startedAt: Date? = nil) -> PocketCatWidgetPlan.Companion {
        .init(sessionID: "session-1", state: PocketCatState(startingWith: mood, at: startedAt ?? start, interval: interval))
    }

    /// The mood the plan shows at `date`: the last moment at or before it.
    private func shown(_ plan: PocketCatWidgetPlan.Plan, at date: Date) -> PocketCatWidgetPlan.Moment? {
        plan.moments.last(where: { $0.date <= date })
    }

    // MARK: Keeping company

    /// Sampled every 7 seconds across the whole plan, including the seconds around each
    /// change, the widget and the Live Activity show the same expression.
    @Test(arguments: [0.0, 1, 299, 300, 301, 1234, 25_200] as [TimeInterval])
    func aCompanionsWidgetShowsTheLiveActivitysExpressionThroughout(secondsIn seconds: TimeInterval) throws {
        let running = companion()
        let now = start.addingTimeInterval(seconds)
        let plan = PocketCatWidgetPlan.plan(at: now, companion: running)
        let first = try #require(plan.moments.first)
        #expect(first.date == now)
        #expect(plan.reloadAt > now)
        var t = now
        while t < plan.reloadAt {
            let moment = try #require(shown(plan, at: t))
            #expect(moment.mood == running.state.mood(at: t), "at \(t.timeIntervalSince(start)) s")
            #expect(moment.sessionID == "session-1")
            t.addTimeInterval(7)
        }
        for boundary in [-0.001, 0, 0.001] {
            let change = try #require(running.state.nextChange(after: now)).addingTimeInterval(boundary)
            #expect(shown(plan, at: change)?.mood == running.state.mood(at: change))
        }
    }

    /// A change of expression lands on the minute the Live Activity changes, never earlier and
    /// never later, and the moments are in order.
    @Test func momentsChangeExactlyWhenTheActivityDoes() throws {
        let running = companion(.eating)
        let now = start.addingTimeInterval(42)
        let plan = PocketCatWidgetPlan.plan(at: now, companion: running)
        let dates = plan.moments.map(\.date)
        #expect(dates == dates.sorted())
        #expect(Set(dates).count == dates.count)
        for moment in plan.moments.dropFirst() {
            #expect(running.state.nextChange(after: moment.date.addingTimeInterval(-1)) == moment.date)
        }
        // One whole round of the six expressions before WidgetKit asks again.
        #expect(plan.moments.count >= PocketCatMood.allCases.count)
        #expect(Set(plan.moments.map(\.mood)) == Set(PocketCatMood.allCases))
        #expect(plan.reloadAt == plan.moments.last?.date.addingTimeInterval(300))
    }

    /// The five-second test rotation (`-MeowverseFastPocketCat`) gives a short plan, not hours
    /// of entries five seconds apart.
    @Test func theFastTestRotationStaysShort() {
        let plan = PocketCatWidgetPlan.plan(at: start.addingTimeInterval(3), companion: companion(interval: 5))
        #expect(plan.moments.count >= PocketCatMood.allCases.count)
        #expect(plan.moments.count <= 12)
        #expect(plan.reloadAt <= start.addingTimeInterval(3 + 60))
    }

    /// While keeping company the button changes this companion's expression (E1).
    @Test func theButtonChangesTheRunningCompanionsExpression() throws {
        let plan = PocketCatWidgetPlan.plan(at: start, companion: companion())
        #expect(!plan.moments.isEmpty)
        for moment in plan.moments {
            #expect(moment.keepsCompany)
            #expect(moment.button == .change(sessionID: "session-1"))
        }
    }

    /// Planned a few minutes before the system's eight-hour limit, the widget stops showing
    /// company at the limit, with "Keep me company" back, instead of carrying on for the rest
    /// of the round.
    @Test(arguments: [7.0 * 60, 1, 0.001] as [TimeInterval])
    func companyStopsAtTheSystemsLimit(minutesLeft left: TimeInterval) throws {
        let limit = start.addingTimeInterval(8 * 3600)
        let running = PocketCatWidgetPlan.Companion(sessionID: "session-1",
                                                    state: PocketCatState(startingWith: .watching, at: start, interval: 300),
                                                    endsBy: limit)
        let now = limit.addingTimeInterval(-left)
        let plan = PocketCatWidgetPlan.plan(at: now, companion: running)
        #expect(plan.moments.first?.date == now)
        for moment in plan.moments {
            #expect(moment.keepsCompany == (moment.date < limit), "at \(moment.date.timeIntervalSince(limit)) s")
        }
        let after = try #require(shown(plan, at: limit))
        #expect(after.button == .start)
        #expect(after.mood == PocketCatWidgetPlan.idleMood(at: limit))
        #expect(plan.reloadAt > limit)
    }

    /// At or past the limit there is no company to show at all.
    @Test(arguments: [0.0, 90] as [TimeInterval])
    func aCompanionPastTheLimitIsIdle(secondsPast past: TimeInterval) {
        let limit = start.addingTimeInterval(8 * 3600)
        let running = PocketCatWidgetPlan.Companion(sessionID: "s", state: PocketCatState(startingWith: .eating, at: start, interval: 300), endsBy: limit)
        let now = limit.addingTimeInterval(past)
        let plan = PocketCatWidgetPlan.plan(at: now, companion: running)
        #expect(plan == PocketCatWidgetPlan.plan(at: now, companion: nil))
    }

    // MARK: Not keeping company

    /// No companion: the six expressions in turn, one per hour of clock time, and the button
    /// starts company.
    @Test func withoutACompanionTheCatRotatesOnTheHour() throws {
        let now = start.addingTimeInterval(25 * 60)
        let plan = PocketCatWidgetPlan.plan(at: now, companion: nil)
        #expect(plan.moments.first?.date == now)
        #expect(plan.moments.count == PocketCatWidgetPlan.idleSteps)
        for (moment, next) in zip(plan.moments, plan.moments.dropFirst()) {
            #expect(next.mood != moment.mood)
            #expect(next.date.timeIntervalSince1970.truncatingRemainder(dividingBy: PocketCatWidgetPlan.idleInterval) == 0)
        }
        for moment in plan.moments {
            #expect(!moment.keepsCompany)
            #expect(moment.button == .start)
            #expect(moment.mood == PocketCatWidgetPlan.idleMood(at: moment.date))
        }
        #expect(Set(plan.moments.map(\.mood)).count == PocketCatWidgetPlan.idleSteps)
        #expect(plan.reloadAt == plan.moments.last?.date.addingTimeInterval(PocketCatWidgetPlan.idleInterval))
    }

    /// The idle expression depends only on the clock, so the small widget, the medium one and
    /// the Lock Screen show the same cat at the same moment.
    @Test func theIdleExpressionIsTheSameForEveryWidget() {
        let hour = Date(timeIntervalSince1970: 1_800_003_600)
        #expect(PocketCatWidgetPlan.idleMood(at: hour) == PocketCatWidgetPlan.idleMood(at: hour.addingTimeInterval(3599)))
        #expect(PocketCatWidgetPlan.idleMood(at: hour) != PocketCatWidgetPlan.idleMood(at: hour.addingTimeInterval(3600)))
        let six = (0..<6).map { PocketCatWidgetPlan.idleMood(at: hour.addingTimeInterval(Double($0) * 3600)) }
        #expect(Set(six) == Set(PocketCatMood.allCases))
    }

    /// A companion whose state has no rotation keeps its one expression, and is checked again.
    @Test func aCompanionWithoutARotationKeepsItsExpression() throws {
        let fixed = try JSONDecoder().decode(PocketCatState.self, from: Data(#"{"mood":"thinking"}"#.utf8))
        let plan = PocketCatWidgetPlan.plan(at: start, companion: .init(sessionID: "s", state: fixed))
        #expect(plan.moments == [.init(date: start, mood: .thinking, sessionID: "s")])
        #expect(plan.reloadAt == start.addingTimeInterval(PocketCatWidgetPlan.fixedCompanionRecheck))
    }

    /// X24-03: the system's limit falls exactly when the round would have asked again. The
    /// timeline still ends company at the limit itself instead of leaving the last expression
    /// up until WidgetKit gets round to the reload.
    @Test func companyStopsAtTheLimitWhenItFallsOnTheReload() throws {
        let state = PocketCatState(startingWith: .watching, at: start, interval: 300)
        let now = start.addingTimeInterval(10)
        let open = PocketCatWidgetPlan.plan(at: now, companion: .init(sessionID: "s", state: state))
        let limit = open.reloadAt
        let plan = PocketCatWidgetPlan.plan(at: now, companion: .init(sessionID: "s", state: state, endsBy: limit))
        let after = try #require(shown(plan, at: limit))
        #expect(after.button == .start)
        #expect(after.date == limit)
        #expect(plan.reloadAt > limit)
    }
}
