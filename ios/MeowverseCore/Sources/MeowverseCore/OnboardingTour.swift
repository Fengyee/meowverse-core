import Foundation

// The guided tour: its chapters, and what is remembered about them on this device.
// Which chapter is due and the order they run in are in OnboardingTourRules.swift.
//
// Only the ending of each chapter is kept, per library, in UserDefaults. It is not part of the
// home: it is not in state.json, not in a backup, and it does not sync (docs/ONBOARDING_TOUR.md §3).

// MARK: - Chapters

/// Names a chapter by what it is about. The value is written to disk and used in text keys, so
/// it never changes once shipped and carries no number: the order of chapters may change.
public struct TourChapterID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    // The opening, in the order it runs.
    public static let welcome = TourChapterID("welcome")
    public static let bringPhoto = TourChapterID("bring-photo")
    public static let furnishFirst = TourChapterID("furnish-first")
    public static let play = TourChapterID("play")
    public static let topRow = TourChapterID("top-row")
    // Told when the user first gets to the feature.
    public static let memories = TourChapterID("memories")
    public static let moveAndLook = TourChapterID("move-and-look")
    public static let photoBatch = TourChapterID("photo-batch")
    public static let photoLibrary = TourChapterID("photo-library")
    public static let furnitureLibrary = TourChapterID("furniture-library")
    public static let sendCat = TourChapterID("send-cat")
    public static let company = TourChapterID("company")
    public static let tabletop = TourChapterID("tabletop")
    public static let reminders = TourChapterID("reminders")
    public static let backup = TourChapterID("backup")
}

/// Where the user is when a chapter can begin.
public enum TourSurface: Sendable, Equatable {
    /// The room, with nothing over it and nothing in progress.
    case room
    case interactionPanel
    case companyPage
    case photoLibrary
    case furnitureLibrary
    /// Anywhere else: a page no chapter begins on, or one of these pages with something over it.
    case elsewhere
}

public struct TourChapter: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// Runs once, in order, the first time an empty home is opened.
        case opening
        /// Told once, when the user gets to the feature and has something to show it with.
        case onDemand
    }

    public enum Audience: Sendable, Equatable {
        /// Only for someone who starts with an empty home. Waived for whoever had a home already.
        case newcomer
        case everyone
    }

    public var id: TourChapterID
    public var kind: Kind
    public var audience: Audience
    /// Where it begins when it comes up on its own.
    public var surface: TourSurface
    /// Raised only when a feature changed so much that those who saw the chapter should see it
    /// again. Rewording a chapter does not raise it. It has no effect on the opening, which is
    /// told once.
    public var revision: Int

    public init(id: TourChapterID, kind: Kind, audience: Audience, surface: TourSurface, revision: Int = 1) {
        self.id = id
        self.kind = kind
        self.audience = audience
        self.surface = surface
        self.revision = revision
    }
}

/// The chapters of one version of the app, in the order they are listed. The opening chapters
/// run in this order.
public struct TourCatalog: Sendable, Equatable {
    public var chapters: [TourChapter]

    public init(chapters: [TourChapter]) { self.chapters = chapters }

    public subscript(id: TourChapterID) -> TourChapter? { chapters.first { $0.id == id } }

    public var opening: [TourChapter] { chapters.filter { $0.kind == .opening } }
    public var onDemand: [TourChapter] { chapters.filter { $0.kind == .onDemand } }

    /// The chapters this build tells: since T5, all fifteen. The app still passes `current` as what
    /// 「全部跳过」 and the waiver settle (`TourMachine`'s `settles`), so a build that tells fewer
    /// chapters than the catalog has never opens the rest as new in a later one.
    public static let toldInThisBuild: Set<TourChapterID> = Set(current.chapters.map(\.id))

    /// `current`, cut to the chapters this build tells, in the same order.
    public static var thisBuild: TourCatalog {
        TourCatalog(chapters: current.chapters.filter { toldInThisBuild.contains($0.id) })
    }

    /// This catalog with one more chapter at the end, as a later version would have.
    public func adding(_ chapter: TourChapter) -> TourCatalog { TourCatalog(chapters: chapters + [chapter]) }

    public static let current = TourCatalog(chapters: [
        TourChapter(id: .welcome, kind: .opening, audience: .newcomer, surface: .room),
        TourChapter(id: .bringPhoto, kind: .opening, audience: .newcomer, surface: .room),
        TourChapter(id: .furnishFirst, kind: .opening, audience: .newcomer, surface: .room),
        TourChapter(id: .play, kind: .opening, audience: .newcomer, surface: .room),
        TourChapter(id: .topRow, kind: .opening, audience: .newcomer, surface: .room),
        TourChapter(id: .memories, kind: .onDemand, audience: .everyone, surface: .room),
        TourChapter(id: .moveAndLook, kind: .onDemand, audience: .everyone, surface: .room),
        TourChapter(id: .photoBatch, kind: .onDemand, audience: .everyone, surface: .room),
        TourChapter(id: .photoLibrary, kind: .onDemand, audience: .everyone, surface: .photoLibrary),
        TourChapter(id: .furnitureLibrary, kind: .onDemand, audience: .everyone, surface: .furnitureLibrary),
        TourChapter(id: .sendCat, kind: .onDemand, audience: .everyone, surface: .interactionPanel),
        TourChapter(id: .company, kind: .onDemand, audience: .everyone, surface: .room),
        TourChapter(id: .tabletop, kind: .onDemand, audience: .everyone, surface: .interactionPanel),
        // For everyone: whether it is needed is the device's to tell (`answeredReminderSetup`),
        // not the home's. A home restored on a new device was never asked here (§3.1.1 #11).
        TourChapter(id: .reminders, kind: .onDemand, audience: .everyone, surface: .room),
        TourChapter(id: .backup, kind: .onDemand, audience: .everyone, surface: .room),
    ])
}

// MARK: - The record

/// How a chapter ended. Read to the end and skipped are kept apart: the finish card draws them
/// differently.
public enum TourOutcome: Sendable, Equatable, Codable {
    /// Read to the end, or the user did what it asked.
    case completed
    /// The user skipped this chapter.
    case skipped
    /// The user skipped everything while this chapter was still to come.
    case skippedAll
    /// Waived: the home was not empty when the tour first met it.
    case grandfathered
    /// Passed over for good because it no longer applies (a reminder is already on, or this
    /// device already answered the old reminder setup page).
    case notNeeded
    /// Written by a later version. Counts as an ending, and is written back as it was read.
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "completed": self = .completed
        case "skipped": self = .skipped
        case "skippedAll": self = .skippedAll
        case "grandfathered": self = .grandfathered
        case "notNeeded": self = .notNeeded
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .completed: "completed"
        case .skipped: "skipped"
        case .skippedAll: "skippedAll"
        case .grandfathered: "grandfathered"
        case .notNeeded: "notNeeded"
        case .other(let word): word
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct TourEntry: Sendable, Equatable, Codable {
    public var outcome: TourOutcome
    /// The revision of the chapter this ending belongs to.
    public var revision: Int

    public init(outcome: TourOutcome, revision: Int) {
        self.outcome = outcome
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey { case outcome, revision }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outcome = try c.decode(TourOutcome.self, forKey: .outcome)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
    }
}

/// What this device remembers about the tour for one library. A chapter without an entry has
/// not been seen: that alone is how a chapter added by a later version reaches everyone once.
///
/// It holds no date, no device identifier and nothing about photos.
public struct TourRecord: Sendable, Equatable, Codable {
    public static let currentFormat = 1

    /// The format this record was written in. A record from a later format is still read, and
    /// keeps its number when written back.
    public var format: Int
    /// By chapter id. Ids this version does not know are kept and written back.
    public var chapters: [String: TourEntry]
    /// How often an outside request cut a chapter short. Only for chapters without an ending.
    public var interruptions: [String: Int]
    // Earlier builds also wrote `quiet`, a "nothing on its own" switch that nothing set. It is
    // gone (PRODUCT_PLAN §3.1.1 #8): a mute the user can neither see nor undo would only hide
    // the tour when a record goes wrong. Records that carry it still read; it is not written back.
    /// How many times the app was opened on this library since the tour exists: launches, and
    /// returns after `TourRules.awayThreshold`. Zero until the tour first meets the library.
    public var opens: Int

    public init() {
        format = Self.currentFormat
        chapters = [:]
        interruptions = [:]
        opens = 0
    }

    private enum CodingKeys: String, CodingKey { case format, chapters, interruptions, opens }

    // Every key is optional when reading: a file written before a key existed must still read
    // (tech-craft: synthesized decoding ignores property defaults).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? Self.currentFormat
        chapters = try c.decodeIfPresent([String: TourEntry].self, forKey: .chapters) ?? [:]
        interruptions = try c.decodeIfPresent([String: Int].self, forKey: .interruptions) ?? [:]
        opens = max(0, try c.decodeIfPresent(Int.self, forKey: .opens) ?? 0)
    }

    public func entry(for id: TourChapterID) -> TourEntry? { chapters[id.rawValue] }

    /// The library had furniture or photos when the tour first met it, or such a home was
    /// restored while the opening was still to come. Chapters for newcomers are waived, now and
    /// in later versions.
    public var isVeteran: Bool { chapters.values.contains { $0.outcome == .grandfathered } }

    /// The bytes that are stored. Keys are sorted so the same record gives the same bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// nil when the bytes are not a record.
    public static func decode(_ data: Data) -> TourRecord? {
        try? JSONDecoder().decode(TourRecord.self, from: data)
    }
}

// MARK: - Where the record is kept

/// What the store holds for a library.
public enum TourStored: Sendable, Equatable {
    /// Nothing was ever written.
    case missing
    /// Something is there that this version cannot read. Treated as nothing seen, but it is not
    /// written over until there is an ending to keep (`TourMachine`).
    case unreadable
    case record(TourRecord)
}

/// Keeps one record per library. `library` is the library folder's name (`LaunchOptions.storeFolder`
/// in the app), as for the other per-library preferences.
public protocol TourRecordStore {
    func load(library: String) -> TourStored
    func save(_ record: TourRecord, library: String)
    /// Forgets the library's record (`-MeowverseResetStore`).
    func remove(library: String)
}

public struct UserDefaultsTourRecordStore: TourRecordStore {
    public static func key(library: String) -> String { "tour.record.\(library)" }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load(library: String) -> TourStored {
        guard let object = defaults.object(forKey: Self.key(library: library)) else { return .missing }
        guard let data = object as? Data, let record = TourRecord.decode(data) else { return .unreadable }
        return .record(record)
    }

    public func save(_ record: TourRecord, library: String) {
        guard let data = try? record.encoded() else { return }
        defaults.set(data, forKey: Self.key(library: library))
    }

    public func remove(library: String) {
        defaults.removeObject(forKey: Self.key(library: library))
    }
}

/// For tests: keeps the same bytes the real store would, in memory.
public final class InMemoryTourRecordStore: TourRecordStore {
    private var values: [String: Data] = [:]

    public init() {}

    public func load(library: String) -> TourStored {
        guard let data = values[library] else { return .missing }
        guard let record = TourRecord.decode(data) else { return .unreadable }
        return .record(record)
    }

    public func save(_ record: TourRecord, library: String) {
        guard let data = try? record.encoded() else { return }
        values[library] = data
    }

    public func remove(library: String) { values[library] = nil }

    /// Puts bytes there as another version, or a fault, would have left them.
    public func plant(_ raw: Data, library: String) { values[library] = raw }

    public func raw(library: String) -> Data? { values[library] }
}
