import Foundation

// Multi-device iCloud sync: the clock that orders writes. See docs/ICLOUD_SYNC.md.

/// A hybrid logical clock stamp: wall time in milliseconds, a counter for writes in the same
/// millisecond (or while the wall clock lags a stamp already seen), and the random sync id of
/// the device that wrote it. Ordered by all three, so two stamps are never equal unless the
/// same device issued them, and an edit made after seeing another edit always sorts after it.
public struct SyncStamp: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public let wall: Int64
    public let counter: Int
    public let device: String

    public init(wall: Int64, counter: Int, device: String) {
        self.wall = wall
        self.counter = counter
        self.device = device
    }

    /// Below every stamp a device issues.
    public static let zero = SyncStamp(wall: 0, counter: 0, device: "")

    public static func < (a: SyncStamp, b: SyncStamp) -> Bool {
        if a.wall != b.wall { return a.wall < b.wall }
        if a.counter != b.counter { return a.counter < b.counter }
        return a.device < b.device
    }

    public var description: String { "\(wall).\(counter)@\(device)" }

    /// The highest counter a stamp may carry. Honest counters stay far below: a tick adds one
    /// per write within one millisecond, and an offer's counter is a library revision (at most
    /// 2^53, `LibraryStore.maxRevision`). A record with a higher one, or a negative one, is
    /// unreadable (`SyncEnvelope.decoded`), and no clock adopts it, so `counter + 1` never traps.
    public static let maxCounter = 1 << 60

    /// What a record from another device may carry (see `maxCounter`). The wall time is not
    /// bounded: a device whose clock runs ahead still writes honest records.
    var isInRange: Bool { (0...Self.maxCounter).contains(counter) }

    private enum CodingKeys: String, CodingKey { case wall = "w", counter = "c", device = "d" }
}

/// One device's clock. `tick` always passes every stamp `observe`d (short of the largest
/// readable one, far past any honest stamp; see `ceiling`),
/// so a user's later edit wins over anything the device had already seen, even when the
/// device's wall clock is behind another device's.
public struct SyncClock: Codable, Sendable, Equatable {
    public let device: String
    public private(set) var last: SyncStamp

    public init(device: String) {
        self.device = device
        last = SyncStamp(wall: 0, counter: 0, device: device)
    }

    /// A random 12-digit hex id, made once per install; never a hardware or account id.
    public static func newDeviceID() -> String {
        String(UUID().uuidString.lowercased().filter { $0 != "-" }.prefix(12))
    }

    public mutating func tick(now: Date) -> SyncStamp {
        let wall = Self.millis(now)
        // At the very top no tick could follow: it moves on from the ceiling.
        if last.wall == .max, last.counter >= SyncStamp.maxCounter {
            last = SyncStamp(wall: Self.ceiling.wall, counter: Self.ceiling.counter, device: device)
        }
        if wall > last.wall {
            last = SyncStamp(wall: wall, counter: 0, device: device)
        } else if last.counter < SyncStamp.maxCounter || last.wall == .max {
            last = SyncStamp(wall: last.wall, counter: min(last.counter, SyncStamp.maxCounter - 1) + 1, device: device)
        } else {
            // Out of counters in this millisecond: the next one, still after everything seen.
            last = SyncStamp(wall: last.wall + 1, counter: 0, device: device)
        }
        return last
    }

    /// The same clock under another id: what it has passed stays passed.
    func renamed(_ id: String) -> SyncClock {
        var clock = SyncClock(device: id)
        clock.last = SyncStamp(wall: last.wall, counter: last.counter, device: id)
        return clock
    }

    /// A stamp out of range (`SyncStamp.isInRange`) is not adopted: no build writes one, and
    /// readable records never carry one.
    public mutating func observe(_ stamp: SyncStamp) {
        guard stamp.isInRange else { return }
        if stamp > last { last = SyncStamp(wall: stamp.wall, counter: stamp.counter, device: device) }
    }

    /// Where `tick` goes on from once the clock reached the largest readable stamp (seen in a
    /// record, or stored by a test build): 2^59 ticks below it. At the last wall time only the
    /// counter still moves, and a clock left at the top would hand out that same stamp for
    /// every later edit, which would then no longer order after one another. A value written
    /// above it still wins over this device's later edits, as the top stamp would over any.
    static let ceiling = SyncStamp(wall: .max, counter: SyncStamp.maxCounter / 2, device: "")

    /// For data that existed before sync was turned on and has a time of its own (a piece's
    /// `updatedAt`): ordered by that time, so the version that changed last wins.
    public func seed(_ date: Date?) -> SyncStamp {
        SyncStamp(wall: date.map(Self.millis) ?? 0, counter: 0, device: device)
    }

    /// For a value with no time of its own that a first sync (or an import) offers: wall 0, so
    /// it loses to every real edit, which always has a wall time. Among such values a default
    /// one (`rank` 0, the same as nothing written) loses to any other; then the higher rank
    /// wins (the library's revision, `SyncCapture`), then the value's bytes. No device id: the
    /// result never depends on which device is which.
    static func seed(rank: Int) -> SyncStamp {
        rank <= 0 ? .zero : SyncStamp(wall: 0, counter: rank, device: "")
    }

    /// Written by a first sync or an import, not by a user's edit after sync was on.
    static func isSeed(_ stamp: SyncStamp) -> Bool { stamp.wall == 0 }

    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}
