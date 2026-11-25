import Foundation
import MeowverseCore
import OSLog
import UIKit

/// Collects the inputs for a `FeedbackReport`: device facts, library counts and this process's
/// own log. What ends up in the text, and the scrubbing, is decided in `FeedbackReport`.
enum FeedbackGatherer {
    /// The subsystems Meowverse logs under.
    nonisolated static let subsystems = ["app.meowverse", "Meowverse"]

    static func report(state: AppState, recognition: RecognitionDiagnostics? = nil) async -> FeedbackReport {
        let environment = environment()
        let terms = FeedbackReport.privateTerms(in: state)
        let log = await Task.detached(priority: .utility) { recentLog(limit: FeedbackReport.maxLogLines) }.value
        return FeedbackReport(environment: environment, library: .init(state: state), rawLogLines: log.lines,
                              privateTerms: terms, logUnavailableReason: log.unavailable,
                              featurePrint: FeaturePrintTimingLog.shared.timings, photoLoads: PhotoLoadLog.shared.stats,
                              recognition: recognition)
    }

    static func environment() -> FeedbackReport.Environment {
        let info = Bundle.main.infoDictionary ?? [:]
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        return .init(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
            build: info["CFBundleVersion"] as? String ?? "?",
            configuration: configuration,
            channel: FeedbackConfig.channel,
            osVersion: UIDevice.current.systemVersion,
            deviceModel: deviceModel(),
            locale: Locale.current.identifier,
            textSize: UIApplication.shared.preferredContentSizeCategory.rawValue,
            reduceMotion: UIAccessibility.isReduceMotionEnabled,
            voiceOver: UIAccessibility.isVoiceOverRunning,
            freeDiskBytes: freeDiskBytes())
    }

    /// The hardware identifier, e.g. "iPhone17,1". Not the user-set device name.
    private static func deviceModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated + " (Simulator)"
        }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func freeDiskBytes() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    struct LogRead: Sendable {
        var lines: [String]
        var unavailable: String?
    }

    /// The newest `limit` entries Meowverse itself logged in this run. Each message is rebuilt from
    /// its fixed format string and allow-listed arguments (`FeedbackReport.renderLogMessage`), never
    /// taken from the store's composed text, so free text in an argument stays out (R01-001).
    /// Slow on a long run, so call it off the main actor.
    nonisolated static func recentLog(limit: Int) -> LogRead {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let predicate = NSPredicate(format: "subsystem IN %@", subsystems)
            let entries = try store.getEntries(matching: predicate)
            let clock = Date.FormatStyle(date: .omitted, time: .standard, locale: Locale(identifier: "en_US_POSIX"))
            var lines: [String] = []
            lines.reserveCapacity(limit * 2)
            for case let entry as OSLogEntryLog in entries {
                lines.append("\(entry.date.formatted(clock)) \(name(entry.level)) \(entry.category): \(message(entry))")
                if lines.count >= limit * 2 { lines.removeFirst(lines.count - limit) }
            }
            return LogRead(lines: Array(lines.suffix(limit)), unavailable: nil)
        } catch {
            return LogRead(lines: [], unavailable: "OSLogStore: \((error as NSError).domain) \((error as NSError).code)")
        }
    }

    nonisolated private static func message(_ entry: OSLogEntryLog) -> String {
        // One component per placeholder (plus one for the closing text); a redacted argument
        // reads as undefined, so it keeps its slot as `.redacted`.
        let arguments = entry.components.map { component -> FeedbackReport.LogArgument in
            switch component.argumentCategory {
            case .undefined: return .redacted
            case .int64: return .number(String(component.argumentInt64Value))
            case .uInt64: return .number(String(component.argumentUInt64Value))
            case .double: return .number(String(component.argumentDoubleValue))
            case .string: return component.argumentStringValue.map { .text($0) } ?? .redacted
            case .data: return .redacted
            @unknown default: return .redacted
            }
        }
        return FeedbackReport.renderLogMessage(format: entry.formatString, arguments: arguments)
    }

    nonisolated private static func name(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "log"
        }
    }
}
