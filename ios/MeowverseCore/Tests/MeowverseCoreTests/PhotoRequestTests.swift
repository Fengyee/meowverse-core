import Foundation
import Testing
@testable import MeowverseCore

@Suite struct PhotoRequestTests {
    @Test func cancellationForwardsToThePlatformWithoutWaitingForAFinalCallback() async {
        let (callbacks, started) = AsyncStream<@Sendable (Result<Int, Error>) -> Void>.makeStream()
        let (events, cancelled) = AsyncStream<Bool>.makeStream()
        let task = Task {
            try await PhotoRequest.value { callback in
                started.yield(callback)
                started.finish()
                return { cancelled.yield(true); cancelled.finish() }
            }
        }
        var callbacksIterator = callbacks.makeAsyncIterator()
        let late = await callbacksIterator.next()
        task.cancel()
        var eventsIterator = events.makeAsyncIterator()
        #expect(await eventsIterator.next() == true)
        if case .failure(let error) = await task.result {
            #expect(error is CancellationError)
        } else { Issue.record("Cancelled request returned an image") }
        late?(.success(10))
    }

    @Test func anImmediateResponseWinsOnlyOnce() async throws {
        let response: Int = try await PhotoRequest.value { reply in
            reply(.success(1))
            reply(.success(2))
            return {}
        }
        #expect(response == 1)
    }

    @Test func unfinishedWarmupDoesNotHoldTheReviewPastItsDeadline() async {
        let (ready, producer) = AsyncStream<Void>.makeStream()
        let clock = ContinuousClock()
        // End the fake producer independently so a regression fails instead of hanging the suite.
        // The margin is wide on purpose: a 20 ms deadline on a loaded, parallel run has been seen
        // past 2 s, while a regression waits the full 10 s.
        let task = Task {
            try? await Task.sleep(for: .seconds(10))
            producer.finish()
        }
        let elapsed = await clock.measure { await PhotoRequest.waitForWarmup(ready, upTo: .milliseconds(20)) }
        #expect(elapsed < .seconds(8))
        task.cancel()
        await task.value
    }
}
