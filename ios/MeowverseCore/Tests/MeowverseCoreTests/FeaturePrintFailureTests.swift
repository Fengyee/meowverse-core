import Foundation
import Testing
@testable import MeowverseCore

/// A photo whose print cannot be made must not make every refresh start over: the app works the
/// suggestions out again when prints were being prepared, and that refreshes again (endless
/// recognition, found while fixing IMPORT-2). It is attempted again on a real trigger only: a
/// new launch, a changed file, a file that can be read again, or a new import.
@Suite(.timeLimit(.minutes(1))) struct FeaturePrintFailureTests {
    private static let analyzer = "test.failures"

    private actor Embedder {
        private(set) var calls = 0
        func print(_ data: Data) throws -> FeaturePrint {
            calls += 1
            guard data.first == UInt8(ascii: "g") else { throw RecognitionError.undecodableImage }
            return FeaturePrint(analyzer: FeaturePrintFailureTests.analyzer, revision: 1, vector: [1, 0])
        }
    }

    private actor Plans {
        private(set) var counts: [Int] = []
        func add(_ count: Int) { counts.append(count) }
    }

    private let folder = TestSupport.tempDir()
    private var photo: URL { folder.appendingPathComponent("photo.jpg") }

    private func cache() -> FeaturePrintCache {
        FeaturePrintCache(fileURL: folder.appendingPathComponent("prints.bin"), analyzer: Self.analyzer, revision: 1)
    }

    @discardableResult
    private func refresh(_ cache: FeaturePrintCache, _ embedder: Embedder, plans: Plans? = nil) async -> Int {
        let photo = photo
        return await cache.refresh(["p"], input: { _ in photo }, embed: { try await embedder.print($0) },
                                   planned: { await plans?.add($0) })
    }

    @Test func aPrintThatFailsIsAttemptedOnceHoweverOftenTheCacheRefreshes() async throws {
        try Data("bad".utf8).write(to: photo)
        let cache = cache(), embedder = Embedder(), plans = Plans()
        for _ in 0..<20 { await refresh(cache, embedder, plans: plans) }
        #expect(await embedder.calls == 1)
        #expect(await plans.counts == [1] + Array(repeating: 0, count: 19), "a given-up print is not planned again")
        #expect(await cache.print(for: "p") == nil)
    }

    /// A print made by another analyzer (an embedder that fell back without saying so) is not
    /// kept, and counts as a failure: not attempted again at every refresh (QA launch 1.0, M3).
    @Test func aPrintFromAnotherAnalyzerIsHeldAsFailed() async throws {
        actor Foreign {
            private(set) var calls = 0
            func print(_ data: Data) -> FeaturePrint {
                calls += 1
                return FeaturePrint(analyzer: "test.someone-else", revision: 1, vector: [1, 0])
            }
        }
        try Data("good".utf8).write(to: photo)
        let cache = cache(), foreign = Foreign(), plans = Plans(), photo = photo
        for _ in 0..<5 {
            await cache.refresh(["p"], input: { _ in photo }, embed: { await foreign.print($0) }, planned: { await plans.add($0) })
        }
        #expect(await foreign.calls == 1)
        #expect(await plans.counts == [1, 0, 0, 0, 0], "a print that isn't ours is not planned again")
        #expect(await cache.print(for: "p") == nil)
    }

    @Test func aChangedFileIsTriedAgain() async throws {
        try Data("bad".utf8).write(to: photo)
        let cache = cache(), embedder = Embedder()
        await refresh(cache, embedder)
        try Data("good now".utf8).write(to: photo, options: .atomic)
        #expect(await refresh(cache, embedder) == 1)
        #expect(await cache.print(for: "p") != nil)
    }

    @Test func aNewLaunchTriesAgain() async throws {
        try Data("bad".utf8).write(to: photo)
        let embedder = Embedder()
        await refresh(cache(), embedder)
        await refresh(cache(), embedder)
        #expect(await embedder.calls == 2)
    }

    @Test func aNewImportTriesAgainAndOnlyOnce() async throws {
        try Data("bad".utf8).write(to: photo)
        let cache = cache(), embedder = Embedder()
        await refresh(cache, embedder)
        await refresh(cache, embedder)
        await cache.retryFailed()
        await refresh(cache, embedder)
        await refresh(cache, embedder)
        #expect(await embedder.calls == 2)
    }

    @Test func aForgottenPhotoIsNoLongerHeldAsFailed() async throws {
        try Data("bad".utf8).write(to: photo)
        let cache = cache(), embedder = Embedder()
        await refresh(cache, embedder)
        await cache.retain(only: [])
        await refresh(cache, embedder)
        #expect(await embedder.calls == 2)
    }

    /// Stopping is not failing: the next refresh makes it.
    @Test func aCancelledPrintIsNotGivenUp() async throws {
        try Data("good".utf8).write(to: photo)
        let cache = cache(), photo = photo
        let (started, start) = AsyncStream<Void>.makeStream()
        let stopped = Task {
            await cache.refresh(["p"], input: { _ in photo }, embed: { _ in
                start.yield()
                try await Task.sleep(for: .seconds(30))
                throw RecognitionError.undecodableImage
            })
        }
        for await _ in started { break }
        stopped.cancel()
        _ = await stopped.value
        #expect(await refresh(cache, Embedder()) == 1)
    }

    /// A locked phone cannot read its files, and their dates do not change when it unlocks.
    @Test func anUnreadableFileIsNotReplannedAndIsMadeOnceReadable() async throws {
        try Data("good".utf8).write(to: photo)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: photo.path)
        let cache = cache(), embedder = Embedder(), plans = Plans()
        for _ in 0..<3 { await refresh(cache, embedder, plans: plans) }
        #expect(await plans.counts == [1, 0, 0])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: photo.path)
        #expect(await refresh(cache, embedder) == 1)
    }

    @Test func aMissingFileIsNotReplannedAndIsMadeWhenItArrives() async throws {
        let cache = cache(), embedder = Embedder(), plans = Plans()
        for _ in 0..<3 { await refresh(cache, embedder, plans: plans) }
        #expect(await plans.counts == [1, 0, 0])
        try Data("good".utf8).write(to: photo)
        #expect(await refresh(cache, embedder) == 1)
    }
}
