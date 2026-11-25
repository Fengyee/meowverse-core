import Foundation
import Synchronization

/// Waiting with a limit that holds (audit 2026-11-24, CC24-03). Awaiting a task's value ignores
/// cancellation: a push handler that cancelled its cycle at 25 seconds and then awaited it still
/// returned only when the cycle did, however long a CloudKit call inside it hung. These return
/// at the limit (or when the caller is cancelled) whether or not the work has ended, and cancel
/// only the work they started themselves.
public enum SyncDeadline {
    public enum Outcome<Value: Sendable>: Sendable {
        case finished(Value)
        /// The limit came first: the work was cancelled and not waited for.
        case timedOut
        /// The caller was cancelled first: the work was cancelled and not waited for.
        case cancelled
    }

    /// Runs `work` in a task of its own. At `limit` (measured by `sleep`, which tests replace)
    /// that task, and nothing else, is cancelled, and this returns without waiting for it.
    public static func run<Value: Sendable>(
        limit: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ work: @escaping @Sendable () async -> Value
    ) async -> Outcome<Value> {
        let once = OneShot<Outcome<Value>>()
        let task = Task { await work() }
        let waiter = Task {
            let value = await task.value
            once.resume(.finished(value))
        }
        let timer = Task {
            do { try await sleep(limit) } catch { return }
            task.cancel()
            once.resume(.timedOut)
        }
        let outcome = await withTaskCancellationHandler {
            await once.value()
        } onCancel: {
            task.cancel()
            once.resume(.cancelled)
        }
        timer.cancel()
        _ = waiter
        return outcome
    }

    /// `task`'s value, or nil once the caller is cancelled first. `task` is not the caller's to
    /// stop: it is never cancelled here and goes on.
    public static func value<Value: Sendable>(of task: Task<Value, Never>) async -> Value? {
        let once = OneShot<Value?>()
        let waiter = Task { once.resume(await task.value) }
        let value = await withTaskCancellationHandler {
            await once.value()
        } onCancel: {
            once.resume(nil)
        }
        _ = waiter
        return value
    }
}

/// The first value given wins; later ones are dropped. Safe to resume before anyone waits.
private final class OneShot<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var waiter: CheckedContinuation<Value, Never>?
        var done = false
    }

    private let state = Mutex(State())

    func resume(_ value: Value) {
        let waiter: CheckedContinuation<Value, Never>? = state.withLock { s in
            guard !s.done else { return nil }
            s.done = true
            if let w = s.waiter {
                s.waiter = nil
                return w
            }
            s.value = value
            return nil
        }
        waiter?.resume(returning: value)
    }

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            let ready: Value? = state.withLock { s in
                if s.done, let v = s.value { return v }
                s.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
