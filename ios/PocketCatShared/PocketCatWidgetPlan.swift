import Foundation

/// What the Home Screen and Lock Screen widgets show over time (round 11, step one). Foundation
/// only: the Core tests compile this file through a symlink
/// (`MeowverseCore/Tests/MeowverseCoreTests/PocketCatShared/`).
///
/// Keeping company: the widget follows the Live Activity's own rotation, so the widget and the
/// Lock Screen never show two different cats (art director, E2). Not keeping company: a calm
/// rotation through the six expressions on the hour.
nonisolated enum PocketCatWidgetPlan {
    /// A running companion as the app left it in the App Group (`PocketCatCompanyShelf`).
    struct Companion: Hashable {
        let sessionID: String
        let state: PocketCatState
        /// When the system will have ended it (its eight-hour limit), or nil if unknown.
        var endsBy: Date? = nil
    }

    /// One timeline entry.
    struct Moment: Hashable {
        let date: Date
        let mood: PocketCatMood
        /// The running companion's id, or nil when there is none. The button changes the
        /// expression of this companion, or starts one.
        let sessionID: String?

        var keepsCompany: Bool { sessionID != nil }

        /// The Home Screen button: "Keep me company" starts company; while keeping company it
        /// reads "Change expression" and changes that companion's expression (E1).
        var button: Button {
            if let sessionID { .change(sessionID: sessionID) } else { .start }
        }
    }

    enum Button: Hashable {
        case start
        case change(sessionID: String)
    }

    struct Plan: Hashable {
        let moments: [Moment]
        /// When WidgetKit should ask again.
        let reloadAt: Date
    }

    /// The idle rotation's step, aligned to the clock.
    static let idleInterval: TimeInterval = 60 * 60
    /// How far an idle timeline reaches before it is asked again.
    static let idleSteps = 6
    /// A companion whose state carries no rotation (none is started that way today) keeps its
    /// one expression; ask again after this long in case it ended.
    static let fixedCompanionRecheck: TimeInterval = 30 * 60

    static func plan(at now: Date, companion: Companion?) -> Plan {
        guard let companion else { return idlePlan(at: now) }
        if let end = companion.endsBy, end <= now { return idlePlan(at: now) }
        let state = companion.state
        let id = companion.sessionID
        let company: Plan
        if let rotation = state.rotation {
            // One whole round of the expressions: the Live Activity's own changes, then ask
            // again, which also notices a companion that ended where the app could not say so
            // (dismissed on the Lock Screen).
            var moments = [Moment(date: now, mood: state.mood(at: now), sessionID: id)]
            var change = rotation.nextChange(after: now)
            for _ in 1..<rotation.order.count {
                moments.append(Moment(date: change, mood: state.mood(at: change), sessionID: id))
                change = rotation.nextChange(after: change)
            }
            company = Plan(moments: moments, reloadAt: change)
        } else {
            company = Plan(moments: [Moment(date: now, mood: state.mood, sessionID: id)],
                           reloadAt: now.addingTimeInterval(fixedCompanionRecheck))
        }
        // The system's time limit falls inside this plan: company until then, the cat at rest
        // from then on.
        guard let end = companion.endsBy, end < company.reloadAt else { return company }
        let rest = idlePlan(at: end)
        return Plan(moments: company.moments.filter { $0.date < end } + rest.moments, reloadAt: rest.reloadAt)
    }

    private static func idlePlan(at now: Date) -> Plan {
        var moments = [Moment(date: now, mood: idleMood(at: now), sessionID: nil)]
        var change = nextIdleChange(after: now)
        for _ in 1..<idleSteps {
            moments.append(Moment(date: change, mood: idleMood(at: change), sessionID: nil))
            change = nextIdleChange(after: change)
        }
        return Plan(moments: moments, reloadAt: change)
    }

    private static func idleSlot(at date: Date) -> Int {
        Int(floor(date.timeIntervalSince1970 / idleInterval))
    }

    private static func nextIdleChange(after date: Date) -> Date {
        Date(timeIntervalSince1970: Double(idleSlot(at: date) + 1) * idleInterval)
    }

    /// The idle expression for a moment: the six in order, one per `idleInterval` of clock time.
    static func idleMood(at date: Date) -> PocketCatMood {
        let moods = PocketCatMood.allCases
        let index = idleSlot(at: date) % moods.count
        return moods[index < 0 ? index + moods.count : index]
    }
}
