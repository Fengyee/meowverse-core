nonisolated enum GroundGait: String, CaseIterable, Identifiable {
    case groundWalk = "ground_walk"
    case gracefulWalk = "graceful_walk"
    case groundRun = "ground_run"
    case groundJump = "ground_jump"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .groundWalk: String(localized: "散步")
        case .gracefulWalk: String(localized: "慢步")
        case .groundRun: String(localized: "奔跑")
        case .groundJump: String(localized: "蹦跳")
        }
    }
}
