import BackgroundTasks
import MeowverseCore
import os
import UIKit

/// Lets a photo import the user started carry on after they leave the app.
///
/// iOS 26 and later: a continued-processing task. The system shows the import's progress while
/// the app is away and offers to stop it; stopping there, or the system ending the task, stops the
/// import the way 「停止导入」 does: photos already stored stay, the rest are reported on return.
/// Earlier systems, or when the system declines the task: the usual short grace period after
/// leaving, then iOS suspends the app and the import carries on when the user comes back. Photo
/// requests under way across that suspension are asked again at once (`Suspensions`).
///
/// Imports commit three photos at a time either way; this only decides how long the app runs.
@MainActor
final class ImportBackgroundTime {
    private static let log = Logger(subsystem: "app.meowverse", category: "import")
    /// Matches `BGTaskSchedulerPermittedIdentifiers` (`$(PRODUCT_BUNDLE_IDENTIFIER).import.*`).
    /// Every run gets its own suffix: an identifier may be registered only once per launch.
    private static var identifierPrefix: String { (Bundle.main.bundleIdentifier ?? "app.meowverse") + ".import." }

    /// Stops every running import, as 「停止导入」 does.
    var stopImports: () -> Void = {}
    #if DEBUG || DRILLS
    /// Drill: acts as if the system ended the task this many seconds after an import started.
    var drillExpiryAfter: Double?
    #endif

    private var tally = ImportRunTally()
    private var grace = UIBackgroundTaskIdentifier.invalid
    /// The run's identifier while its request is with the system.
    private var requested: String?
    /// The running `BGContinuedProcessingTask` (iOS 26+; a stored property cannot be gated).
    private var running: AnyObject?
    private var expired = false
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentAway() }
        }
    }

    /// Called with an import's counts whenever they change, and with nil when it ends.
    func update(_ kind: ImportRunTally.Kind, _ counts: ImportRunTally.Counts?) {
        let wasRunning = tally.isRunning
        tally.update(kind, counts)
        switch (wasRunning, tally.isRunning) {
        case (false, true): begin()
        case (true, false): finish()
        case (true, true): report()
        case (false, false): break
        }
    }

    private var title: String { String(localized: "正在导入照片") }
    private var subtitle: String { String(localized: "\(tally.completed) / \(tally.total) 张") }

    private func begin() {
        expired = false
        holdGrace()
        if #available(iOS 26, *) { requestContinuedProcessing() }
        #if DEBUG || DRILLS
        if let delay = drillExpiryAfter {
            let identifier = requested ?? "drill"
            requested = identifier
            Task {
                try? await Task.sleep(for: .seconds(delay))
                expire(identifier)
            }
        }
        #endif
    }

    private func wentAway() {
        // Each time the app leaves, the import gets the short grace period again.
        if tally.isRunning { holdGrace() }
    }

    private func holdGrace() {
        guard grace == .invalid else { return }
        grace = UIApplication.shared.beginBackgroundTask(withName: "PhotoImport") { [weak self] in
            // Without a continued-processing task iOS suspends the app now; the import carries on
            // where it stopped once the user is back.
            if self?.running == nil {
                Suspensions.increment()
                Self.log.notice("import: grace period over, waiting for the app to return")
            }
            self?.endGrace()
        }
    }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

    @available(iOS 26, *)
    private func requestContinuedProcessing() {
        let identifier = Self.identifierPrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.started(task, identifier: identifier)
            }
        }
        guard registered else {
            Self.log.error("import: continued processing identifier not permitted")
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // The import already runs in the app: a task the system could only start later is no use.
        request.strategy = .fail
        requested = identifier
        do {
            try BGTaskScheduler.shared.submit(request)
            Self.log.notice("import: continued processing requested")
        } catch {
            requested = nil
            // Declined (busy system, Background App Refresh off, simulator): the grace period remains.
            Self.log.notice("import: continued processing declined, code \((error as NSError).code, privacy: .public)")
        }
    }

    @available(iOS 26, *)
    private func started(_ task: BGContinuedProcessingTask, identifier: String) {
        guard requested == identifier, tally.isRunning else {
            // The import ended before the system got to it.
            task.setTaskCompleted(success: true)
            return
        }
        Self.log.notice("import: continued processing running")
        running = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expire(identifier) }
        }
        report()
    }

    /// The user stopped the import from the system's progress, or the system ended the task.
    private func expire(_ identifier: String) {
        guard requested == identifier, tally.isRunning, !expired else { return }
        expired = true
        Self.log.notice("import: background time ended, stopping the import")
        stopImports()
        // `finish` completes the task once the imports have wound down.
    }

    private func report() {
        guard #available(iOS 26, *), let task = running as? BGContinuedProcessingTask else { return }
        task.progress.totalUnitCount = Int64(max(tally.total, 1))
        task.progress.completedUnitCount = Int64(tally.completed)
        task.updateTitle(title, subtitle: subtitle)
    }

    private func finish() {
        if #available(iOS 26, *) {
            if let task = running as? BGContinuedProcessingTask {
                // An import can end early by itself (a failed save, photos that never arrived, 停止).
                let ending = tally.ending(expired: expired)
                task.progress.totalUnitCount = ending.total
                task.progress.completedUnitCount = ending.completed
                task.setTaskCompleted(success: ending.success)
            } else if let requested {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requested)
            }
        }
        running = nil
        requested = nil
        expired = false
        endGrace()
    }
}

/// How many times iOS has suspended the app during an import since launch: the background time
/// ran out with no continued-processing task. A photo request under way across one is suspect
/// (`LoadWatch.suspensions`) and is asked again once the app runs.
nonisolated enum Suspensions {
    private static let count = OSAllocatedUnfairLock(initialState: 0)

    static var current: Int { count.withLock { $0 } }

    static func increment() { count.withLock { $0 += 1 } }
}
