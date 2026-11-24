import Foundation
import os
import Testing
@testable import MeowverseCore

/// A photo request that never answers (an iCloud download that stalls, on screen or after the
/// app was suspended) gets a time limit, one retry with a longer limit, and is then given up:
/// the import never hangs.
@Suite struct LoadWatchdogTests {
    /// Counts attempts, their cancellations and the time-outs reported.
    final class Tally: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (started: 0, cancelled: 0, timedOut: 0))
        var started: Int { state.withLock { $0.started } }
        var cancelled: Int { state.withLock { $0.cancelled } }
        var timedOut: Int { state.withLock { $0.timedOut } }
        /// Returns the attempt's number, from 1.
        func start() -> Int { state.withLock { $0.started += 1; return $0.started } }
        func cancel() { state.withLock { $0.cancelled += 1 } }
        func timeOut() { state.withLock { $0.timedOut += 1 } }
    }

    private let watch = LoadWatch(limits: [.milliseconds(150), .milliseconds(500)])

    /// Never answers and ignores cancellation, as the worst platform request could.
    private static func hang(_ tally: Tally) async {
        await withTaskCancellationHandler {
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        } onCancel: {
            tally.cancel()
        }
    }

    @Test func aRequestThatNeverAnswersIsRetriedOnceThenGivenUp() async {
        let tally = Tally()
        let clock = ContinuousClock(), start = clock.now
        await #expect(throws: LoadTimedOut.self) {
            try await LoadWatchdog.load(watch, timedOut: { tally.timeOut() }) { () async throws -> Int in
                _ = tally.start()
                await Self.hang(tally)
                return 0
            }
        }
        let elapsed = clock.now - start
        #expect(tally.started == 2, "the first request and one retry")
        #expect(tally.cancelled == 2, "every timed-out request is cancelled")
        #expect(tally.timedOut == 2)
        #expect(elapsed >= .milliseconds(650), "each attempt had its own limit: \(elapsed)")
        #expect(elapsed < .seconds(5))
    }

    /// The retry gets the longer limit: an answer after 300 ms is in time on the second attempt.
    @Test func theRetryHasTheLongerLimit() async throws {
        let tally = Tally()
        let value = try await LoadWatchdog.load(watch, timedOut: { tally.timeOut() }) { () async throws -> Int in
            if tally.start() == 1 { await Self.hang(tally) }
            try await Task.sleep(for: .milliseconds(300))
            return 7
        }
        #expect(value == 7)
        #expect(tally.started == 2 && tally.timedOut == 1)
    }

    @Test func anAnswerInTimeIsUsedAsIs() async throws {
        let tally = Tally()
        let value = try await LoadWatchdog.load(watch, timedOut: { tally.timeOut() }) { () async throws -> Int in
            _ = tally.start()
            try await Task.sleep(for: .milliseconds(50))
            return 3
        }
        #expect(value == 3)
        #expect(tally.started == 1 && tally.timedOut == 0)
    }

    struct Unreadable: Error {}

    @Test func aFailureIsPassedOnWithoutRetrying() async {
        let tally = Tally()
        await #expect(throws: Unreadable.self) {
            try await LoadWatchdog.load(watch) { () async throws -> Int in
                _ = tally.start()
                throw Unreadable()
            }
        }
        #expect(tally.started == 1)
    }

    /// Stopping the import ends the wait at once, even on a request that ignores cancellation.
    @Test func cancellingTheCallerEndsTheWait() async {
        let tally = Tally()
        let task = Task {
            try await LoadWatchdog.load(LoadWatch(limits: [.seconds(60)])) { () async throws -> Int in
                _ = tally.start()
                await Self.hang(tally)
                return 0
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(tally.started == 1 && tally.cancelled == 1)
    }

    final class Counter: Sendable {
        private let value = OSAllocatedUnfairLock(initialState: 0)
        var current: Int { value.withLock { $0 } }
        func bump() { value.withLock { $0 += 1 } }
    }

    /// A request under way when the app was suspended is asked again as soon as the app runs,
    /// without waiting out its limit and without using up the retry.
    @Test func aRequestCaughtBySuspensionIsAskedAgainAtOnce() async throws {
        let tally = Tally(), suspensions = Counter()
        let watch = LoadWatch(limits: [.seconds(60)], poll: .milliseconds(20), suspensions: { suspensions.current })
        let clock = ContinuousClock(), start = clock.now
        let value = try await LoadWatchdog.load(watch, timedOut: { tally.timeOut() }) { () async throws -> Int in
            if tally.start() == 1 {
                Task { try? await Task.sleep(for: .milliseconds(100)); suspensions.bump() }
                await Self.hang(tally)
            }
            return 5
        }
        #expect(value == 5)
        #expect(tally.started == 2 && tally.timedOut == 0 && tally.cancelled == 1)
        #expect(clock.now - start < .seconds(5))
    }

    /// A request that failed across a suspension is not believed: it is asked again.
    @Test func aFailureAcrossASuspensionIsAskedAgain() async throws {
        let tally = Tally(), suspensions = Counter()
        let watch = LoadWatch(limits: [.seconds(60)], poll: .milliseconds(20), suspensions: { suspensions.current })
        let value = try await LoadWatchdog.load(watch) { () async throws -> Int in
            if tally.start() == 1 {
                suspensions.bump()
                throw Unreadable()
            }
            return 6
        }
        #expect(value == 6)
        #expect(tally.started == 2)
    }

    @Test func theShippedLimitsAreAMinuteThenTwo() {
        #expect(LoadWatch.photos.limits == [.seconds(60), .seconds(120)])
    }
}
