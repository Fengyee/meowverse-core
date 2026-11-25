import Foundation

/// Reading a linked photo's full original from Photos, one version after another (audit A24-09).
/// The picker read the current version; after an edit in Photos the original version may still be
/// the bytes that were imported. A version that cannot be read is not the end: the next one is
/// tried. Cancelling stops at once.
public enum PhotoOriginalVersions {
    /// The first version whose bytes hash to `expected`. When none does: the first reason a
    /// version could not be read (the version that failed may be the one that matches), else
    /// `PhotoSourceIssue.changed`.
    public static func read<Version: Sendable>(_ versions: [Version], expected: String,
                                               fetch: (Version) async throws -> Data) async throws -> Data {
        var firstFailure: (any Error)?
        for version in versions {
            try Task.checkCancellation()
            let data: Data
            do {
                data = try await fetch(version)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstFailure == nil { firstFailure = error }
                continue
            }
            if PhotoIngest.sha256Hex(data) == expected { return data }
        }
        throw firstFailure ?? PhotoSourceIssue.changed
    }
}
