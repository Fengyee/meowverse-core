import Foundation
import Testing
@testable import MeowverseCore

/// External audit 2026-11-24, CC24-03: a push's time limit holds and cancels only the push's own
/// work. The limit is a fake: `sleep` returns when the test says the time is up.
@Suite struct SyncDeadlineTests {
    /// Work that hangs and ignores cancellation (a CloudKit call that does not return): at the
    /// limit the caller gets `timedOut` at once, and the work was told to stop.
    @Test func aHungWorkIsLeftAtTheLimit() async {
        let gate = QAGate()
        await gate.arm()
        let (ended, endedSink) = AsyncStream.makeStream(of: Bool.self)
        let outcome = await SyncDeadline.run(limit: .seconds(25), sleep: { _ in await gate.waitUntilHeld() }) {
            await gate.pass()                     // hangs until released, whatever happens
            endedSink.yield(Task.isCancelled)
            endedSink.finish()
            return 1
        }
        guard case .timedOut = outcome else { Issue.record("expected timedOut, got \(outcome)"); return }
        // Only now does the hung call return: it was cancelled, and nobody waited for it.
        await gate.release()
        var iterator = ended.makeAsyncIterator()
        #expect(await iterator.next() == true, "the work it started was cancelled")
    }

    /// Work that ends first: its value, and the timer does not cancel it.
    @Test func workThatEndsInTimeGivesItsValue() async {
        let outcome = await SyncDeadline.run(limit: .seconds(25), sleep: { _ in try await Task.sleep(for: .seconds(3600)) }) {
            Task.isCancelled ? -1 : 7
        }
        guard case .finished(let value) = outcome else { Issue.record("expected finished, got \(outcome)"); return }
        #expect(value == 7)
    }

    /// The caller cancelled (the system took the push's time back): cancelled at once, the work
    /// told to stop.
    @Test func aCancelledCallerDoesNotWaitForTheWork() async {
        let gate = QAGate()
        await gate.arm()
        let (ended, endedSink) = AsyncStream.makeStream(of: Bool.self)
        let caller = Task {
            await SyncDeadline.run(limit: .seconds(25), sleep: { _ in try await Task.sleep(for: .seconds(3600)) }) {
                await gate.pass()
                endedSink.yield(Task.isCancelled)
                endedSink.finish()
                return 1
            }
        }
        await gate.waitUntilHeld()
        caller.cancel()
        guard case .cancelled = await caller.value else { Issue.record("expected cancelled"); return }
        await gate.release()
        var iterator = ended.makeAsyncIterator()
        #expect(await iterator.next() == true)
    }

    /// Waiting for a task the caller does not own (a cycle that was already running when the push
    /// came): a cancelled caller stops waiting and that task goes on, not cancelled.
    @Test func waitingForAnotherTaskNeverCancelsIt() async {
        let gate = QAGate()
        await gate.arm()
        let other = Task<Bool, Never> {
            await gate.pass()
            return Task.isCancelled
        }
        await gate.waitUntilHeld()
        let waiter = Task { await SyncDeadline.value(of: other) }
        waiter.cancel()
        #expect(await waiter.value == nil, "stopped waiting")
        await gate.release()
        #expect(await other.value == false, "the task it waited for was not cancelled")
        // Not cancelled: the value.
        #expect(await SyncDeadline.value(of: Task { 5 }) == 5)
    }
}
