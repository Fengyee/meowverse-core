import Foundation
import os

/// How picked photos have been fetched since launch, for the 反馈问题 diagnostics. Counts of
/// requests only: no photo names, identifiers or sizes.
public struct PhotoLoadStats: Sendable, Equatable {
    /// Photos asked for.
    public var requested = 0
    /// Attempts cancelled for taking too long (a photo can time out twice).
    public var timedOut = 0
    /// Photos given up after the retry.
    public var gaveUp = 0
    /// Photos whose request failed outright (not a time-out).
    public var failed = 0

    public init() {}

    /// e.g. "Photo requests since launch: 12, timed out 3, given up 1, failed 0".
    public var line: String {
        "Photo requests since launch: \(requested), timed out \(timedOut), given up \(gaveUp), failed \(failed)"
    }
}

/// The running tally behind `PhotoLoadStats`. Reset only by relaunching.
public final class PhotoLoadLog: Sendable {
    public static let shared = PhotoLoadLog()

    private let state = OSAllocatedUnfairLock(initialState: PhotoLoadStats())

    public init() {}

    public var stats: PhotoLoadStats { state.withLock { $0 } }

    public func record(_ change: @Sendable (inout PhotoLoadStats) -> Void) {
        state.withLock { change(&$0) }
    }
}
