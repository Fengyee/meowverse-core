import Foundation
import Synchronization
import Testing
@testable import MeowverseCore

/// Audit A24-09: reading a linked photo's full original from Photos tries the current version,
/// then the original one. A failure reading the current version must not stop the original
/// version from being tried; cancelling stops both.
struct PhotoOriginalVersionTests {
    enum Version: Sendable, Equatable { case current, original }

    let bytes = Data("the original bytes".utf8)
    var expected: String { PhotoIngest.sha256Hex(bytes) }

    @Test func aFailingCurrentVersionFallsBackToTheOriginal() async throws {
        let asked = Mutex<[Version]>([])
        let data = try await PhotoOriginalVersions.read([Version.current, .original], expected: expected) { version in
            asked.withLock { $0.append(version) }
            if version == .current { throw PhotoSourceIssue.iCloud }
            return bytes
        }
        #expect(data == bytes)
        #expect(asked.withLock { $0 } == [.current, .original])
    }

    @Test func theCurrentVersionIsUsedWhenItMatches() async throws {
        let asked = Mutex<[Version]>([])
        let data = try await PhotoOriginalVersions.read([Version.current, .original], expected: expected) { version in
            asked.withLock { $0.append(version) }
            return bytes
        }
        #expect(data == bytes)
        #expect(asked.withLock { $0 } == [.current])
    }

    /// Nothing matched: the first reason a version could not be read is reported, not "changed",
    /// since the version that failed may still be the one that matches.
    @Test func whenNoVersionMatchesTheFirstFailureIsReported() async throws {
        await #expect(throws: PhotoSourceIssue.iCloud) {
            try await PhotoOriginalVersions.read([Version.current, .original], expected: expected) { version in
                if version == .current { throw PhotoSourceIssue.iCloud }
                return Data("edited".utf8)
            }
        }
        await #expect(throws: PhotoSourceIssue.changed) {
            try await PhotoOriginalVersions.read([Version.current, .original], expected: expected) { _ in Data("edited".utf8) }
        }
        await #expect(throws: PhotoSourceIssue.permission) {
            try await PhotoOriginalVersions.read([Version.current, .original], expected: expected) { _ in throw PhotoSourceIssue.permission }
        }
    }

    @Test func cancellingStopsWithoutTryingTheOriginal() async throws {
        let asked = Mutex<[Version]>([])
        await #expect(throws: CancellationError.self) {
            try await PhotoOriginalVersions.read([Version.current, .original], expected: expected) { version in
                asked.withLock { $0.append(version) }
                throw CancellationError()
            }
        }
        #expect(asked.withLock { $0 } == [.current])
    }
}
