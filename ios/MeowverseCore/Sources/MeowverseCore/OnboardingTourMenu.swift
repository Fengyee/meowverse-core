import Foundation

// Settings → 使用导览: the chapters that can be seen again (PRODUCT_PLAN §4.1, LINES.md §6), and
// when the first app-icon change may come (PRODUCT_PLAN §2.2 item 2, chapter 14).

// MARK: - The replay list

/// What Settings → 使用导览 lists. `catalog` is what this build tells: a chapter without a script
/// is not listed, since a row that opens nothing promises a feature that is not there.
public struct TourMenu: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case seen
        case skipped
        /// Not seen on this device: no ending, or waived because the home was already lived in.
        case notYet
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public var id: TourChapterID
        public var status: Status
    }

    /// 「开场」 (First steps), in the order the opening runs.
    public var opening: [Row]
    /// 「用到时再讲的」. Empty while this build tells no feature chapter; the group is then not shown.
    public var onDemand: [Row]

    /// 「从头看一遍」: the whole opening, one chapter after the other.
    public var fromTheStart: [TourChapterID] { opening.map(\.id) }

    public init(catalog: TourCatalog, stored: TourStored, snapshot: TourSnapshot) {
        let record: TourRecord
        if case .record(let read) = stored { record = read } else { record = TourRecord() }
        func row(_ chapter: TourChapter) -> Row {
            let status: Status = switch record.entry(for: chapter.id)?.outcome {
            case .completed: .seen
            case .skipped, .skippedAll: .skipped
            case .grandfathered, .notNeeded, .other, nil: .notYet
            }
            return Row(id: chapter.id, status: status)
        }
        let listed = catalog.chapters.filter { TourRules.isOnThisDevice($0, snapshot: snapshot) }
        opening = listed.filter { $0.kind == .opening }.map(row)
        onDemand = listed.filter { $0.kind == .onDemand }.map(row)
    }
}

// MARK: - The first icon change

/// Whether the app may ask iOS to change its icon now. The system's alert about it cannot be
/// hidden, so the first one waits until the opening is behind the user (or the next open).
public enum TourIconTiming: Sendable, Equatable {
    /// The tour has not looked at this library yet; ask again in a moment.
    case wait
    /// Not this time in the foreground: a newcomer's opening is still to come.
    case hold
    case go
}

extension TourRules {
    /// `atLaunch` is the record as this process found it, before the tour counted this open;
    /// `now` is the record as it is now. `catalog` is what this build tells.
    public static func iconTiming(atLaunch: TourStored, now: TourStored, catalog: TourCatalog) -> TourIconTiming {
        // An earlier open of this library: the opening had its first open (PRODUCT_PLAN §2.2: "或第二次打开 App 时").
        if case .record(let earlier) = atLaunch, earlier.opens > 0 { return .go }
        // Not readable: the tour holds back its saves until an ending, so this could hold for good.
        if case .unreadable = atLaunch { return .go }
        switch now {
        case .missing: return .wait
        case .unreadable: return .go
        case .record(let record):
            guard record.opens > 0 else { return .wait }
            // Waived (a home already lived in), finished or skipped.
            return openingIsOver(catalog: catalog, record: record) ? .go : .hold
        }
    }
}
