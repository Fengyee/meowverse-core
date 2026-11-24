import Foundation
import os

/// A photo request did not answer in the time allowed, also when started again. Not the same as
/// an unreadable photo: picking it again later can work.
public struct LoadTimedOut: Error, Equatable {
    public init() {}
}

public struct LoadWatch: Sendable {
    /// The time each attempt gets, in turn. After the last one the photo is given up.
    public var limits: [Duration]
    /// How often a waiting attempt looks at `suspensions`.
    public var poll: Duration
    /// Changes each time iOS suspends the app (its background time ran out). A request under
    /// way across a suspension is suspect: it is started again as soon as the app runs, and a
    /// failure it ended with is not believed. Such a restart uses up no time limit.
    public var suspensions: @Sendable () -> Int

    public init(limits: [Duration], poll: Duration = .seconds(1), suspensions: @escaping @Sendable () -> Int = { 0 }) {
        self.limits = limits
        self.poll = poll
        self.suspensions = suspensions
    }

    /// A picked photo coming from iCloud can take minutes, and a request sometimes never answers
    /// (also with the app on screen) yet succeeds when asked again. The picker's progress cannot
    /// tell the two apart (it stays indeterminate), so the limit is plain time.
    public static let photos = LoadWatch(limits: [.seconds(60), .seconds(120)])
}

/// Keeps a photo request from holding an import forever.
public enum LoadWatchdog {
    private static let log = Logger(subsystem: "app.meowverse", category: "import")

    private enum Outcome<T: Sendable>: Sendable {
        case done(T)
        case failed(any Error)
        case timedOut
        case suspended
        case cancelled
    }

    /// Runs `attempt` with the first time limit; when it runs out the attempt is cancelled and
    /// started again with the next. After the last, throws `LoadTimedOut`. A failure is passed on
    /// as it is, without retrying. A timed-out attempt is never waited for, so even a request
    /// that ignores cancellation cannot hold the caller. `timedOut` is called on every time-out.
    public static func load<T: Sendable>(_ watch: LoadWatch, timedOut: @escaping @Sendable () -> Void = {},
                                         _ attempt: @escaping @Sendable () async throws -> T) async throws -> T {
        var number = 0
        while number < watch.limits.count {
            let limit = watch.limits[number]
            try Task.checkCancellation()
            let suspended = watch.suspensions()
            let (outcomes, report) = AsyncStream<Outcome<T>>.makeStream(bufferingPolicy: .bufferingOldest(1))
            let work = Task {
                do {
                    report.yield(.done(try await attempt()))
                } catch {
                    report.yield(.failed(error))
                }
            }
            let timer = Task {
                let clock = ContinuousClock(), deadline = clock.now + limit
                while clock.now < deadline {
                    do { try await Task.sleep(for: min(watch.poll, deadline - clock.now)) } catch { return }
                    if watch.suspensions() != suspended {
                        report.yield(.suspended)
                        return
                    }
                }
                report.yield(.timedOut)
            }
            let outcome = await withTaskCancellationHandler {
                var iterator = outcomes.makeAsyncIterator()
                return await iterator.next() ?? .cancelled
            } onCancel: {
                report.yield(.cancelled)
            }
            work.cancel()
            timer.cancel()
            report.finish()
            switch outcome {
            case .done(let value):
                return value
            case .failed(let error):
                guard watch.suspensions() != suspended, !(error is CancellationError) else { throw error }
                log.notice("photo request failed after the app was suspended; asking again")
            case .cancelled:
                throw CancellationError()
            case .suspended:
                log.notice("photo request was under way when the app was suspended; asking again")
            case .timedOut:
                log.notice("photo request timed out after \(limit.components.seconds, privacy: .public) s (attempt \(number + 1, privacy: .public) of \(watch.limits.count, privacy: .public))")
                timedOut()
                number += 1
            }
        }
        throw LoadTimedOut()
    }
}
