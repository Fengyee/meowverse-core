import Foundation

/// The outcome of the DINOv2 load-time self-check (requested compute units against the CPU on a
/// fixed picture), remembered so later launches load one model instead of two. Valid only for
/// the app build, iOS version and model revision it was made on: any of them changing can change
/// what the accelerator does, so the check runs again.
public enum ComputeUnitsMemo {
    public enum Choice: String, Sendable, Equatable {
        /// The requested units agreed with the CPU: load only those.
        case requested
        /// They disagreed (or gave no usable print): load only the CPU model.
        case cpuOnly
    }

    public static let defaultsKey = "MeowverseDinoUnitsCheck"

    /// What the check is valid for, e.g. "build 59|iOS 27.1|model 2".
    public static func scope(build: String, os: String, modelRevision: Int) -> String {
        "build \(build)|iOS \(os)|model \(modelRevision)"
    }

    /// The remembered choice for `scope`, nil when none was made for exactly it.
    public static func recall(_ scope: String, in defaults: UserDefaults) -> Choice? {
        guard let stored = defaults.dictionary(forKey: defaultsKey), stored["scope"] as? String == scope,
              let raw = stored["choice"] as? String else { return nil }
        return Choice(rawValue: raw)
    }

    /// Keeps `choice` for `scope`, replacing whatever was kept for another scope.
    public static func remember(_ choice: Choice, for scope: String, in defaults: UserDefaults) {
        defaults.set(["scope": scope, "choice": choice.rawValue], forKey: defaultsKey)
    }
}
