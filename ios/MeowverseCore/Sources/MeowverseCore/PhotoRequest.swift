import Foundation

/// Bridges a one-shot picker or PhotoKit callback and its cancellation handle. The stream can
/// receive an immediate callback before the platform returns the handle. Cancellation also
/// ends the wait when the platform delivers no final callback.
public enum PhotoRequest {
    public static func value<Value: Sendable>(
        start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> @Sendable () -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        let (stream, continuation) = AsyncThrowingStream<Value, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let cancel = start { result in
            switch result {
            case .success(let value):
                continuation.yield(value)
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
        return try await withTaskCancellationHandler {
            var iterator = stream.makeAsyncIterator()
            guard let value = try await iterator.next() else { throw CancellationError() }
            try Task.checkCancellation()
            return value
        } onCancel: {
            continuation.finish(throwing: CancellationError())
            cancel()
        }
    }

    /// Waiting for a warm cache is optional. Cancelling the stream iterator at the deadline
    /// leaves the cache producer running for the next review.
    public static func waitForWarmup(_ ready: AsyncStream<Void>, upTo timeout: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in ready {} }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }
}
