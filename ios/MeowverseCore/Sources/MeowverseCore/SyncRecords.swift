import Foundation

// Multi-device iCloud sync: the records and how two versions of one record merge.
// See docs/ICLOUD_SYNC.md for the rules and why.
//
// Every merge here is a join: commutative, associative and idempotent. Two devices that have
// received the same versions of a record, in any order and any number of times, hold the same
// record. Nothing in a record is a device-local hint (`assetIdentifier`, file paths, local
// revisions): those stay in each device's own `state.json`.

// MARK: - Building blocks

/// A last-writer-wins value. Values written with equal stamps are the same write; if they
/// differ anyway (a damaged copy), the smaller encoding wins so every device picks the same.
public struct SyncRegister<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var value: Value
    public var stamp: SyncStamp

    public init(_ value: Value, _ stamp: SyncStamp) {
        self.value = value
        self.stamp = stamp
    }

    public func joined(_ other: SyncRegister<Value>) -> SyncRegister<Value> {
        if other.stamp != stamp { return other.stamp > stamp ? other : self }
        if other.value == value { return self }
        return SyncCoding.orderedBefore(other.value, value) ? other : self
    }

    private enum CodingKeys: String, CodingKey { case value = "v", stamp = "s" }
}

/// Per device, the newest stamp that device wrote into one record: a version vector. Each
/// device only ever adds its own entry, so a record's vector grows with every version made of it
/// anywhere, including a value that later lost to another write and a copy or id that was only
/// added (an import of a photo another device already had).
public struct SyncVersion: Codable, Sendable, Equatable {
    public private(set) var stamps: [String: SyncStamp] = [:]

    public init() {}

    init(_ stamps: [SyncStamp]) {
        for stamp in stamps { add(stamp) }
    }

    public subscript(device: String) -> SyncStamp? { stamps[device] }

    mutating func add(_ stamp: SyncStamp) {
        guard stamp != .zero else { return }
        if let old = stamps[stamp.device], old >= stamp { return }
        stamps[stamp.device] = stamp
    }

    func joined(_ other: SyncVersion) -> SyncVersion {
        var r = self
        for stamp in other.stamps.values { r.add(stamp) }
        return r
    }

    /// True when every write in `other` is one this version had seen.
    func covers(_ other: SyncVersion) -> Bool {
        other.stamps.allSatisfy { device, stamp in stamps[device].map { stamp <= $0 } ?? false }
    }

    var newest: SyncStamp { stamps.values.max() ?? .zero }

    /// Also reads a deletion's single `seen` stamp, as records kept it before versions.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let single = try? c.decode(SyncStamp.self) {
            self.init([single])
        } else {
            self.init()
            stamps = try c.decode([String: SyncStamp].self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(stamps)
    }
}

extension KeyedDecodingContainer {
    /// Records written before versions have no `edits`: read as none (the synthesized decoding
    /// of every record picks this overload for its `SyncVersion` fields).
    func decode(_ type: SyncVersion.Type, forKey key: Key) throws -> SyncVersion {
        try decodeIfPresent(SyncVersion.self, forKey: key) ?? SyncVersion()
    }
}

/// A deletion. `seen` is the record's version vector as the deleting device had it: the record
/// stays deleted only while every write on it is one the deletion saw. A version the deleting
/// device never saw, from any device and however old, brings the record back (observed-remove;
/// data is kept, see the design note).
public struct SyncTombstone: Codable, Sendable, Equatable {
    public var seen: SyncVersion
    public var at: SyncStamp
    /// Photo records only: the names of every record one deletion of a photo shown through
    /// several records (`SyncPhotoGroups`) tombed together, this one included, and any it
    /// could not write (held back). nil for a record deleted by itself. When one of them comes
    /// back (an edit the deletion did not see), the others rejoin it, so the photo comes back
    /// whole (docs/ICLOUD_SYNC.md §5); either record's list is enough.
    /// Optional, so decoded if present: records from before it read as deleted by themselves.
    /// Builds without it (format 1 too, see §9) read the deletion the same and drop the list
    /// from every record they write, live or deleted. They do not group, so they write only
    /// their own photo's record; its partners keep their lists, which name it.
    public var together: [String]?

    public init(seen: SyncVersion, at: SyncStamp, together: [String]? = nil) {
        self.seen = seen
        self.at = at
        self.together = together
    }

    /// A deletion that saw `seen` and that device's earlier writes.
    public init(seen: SyncStamp, at: SyncStamp) {
        self.init(seen: SyncVersion([seen]), at: at)
    }

    /// Two deletions together hide what either one saw, and name every record either one
    /// deleted together with this one.
    static func join(_ a: SyncTombstone?, _ b: SyncTombstone?) -> SyncTombstone? {
        guard let a else { return b }
        guard let b else { return a }
        let together = a.together == nil && b.together == nil ? nil
            : Array(Set(a.together ?? []).union(b.together ?? [])).sorted()
        return SyncTombstone(seen: a.seen.joined(b.seen), at: max(a.at, b.at), together: together)
    }
}

enum SyncCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A total order on values for tie-breaks: by their sorted-key JSON bytes.
    static func orderedBefore<V: Encodable>(_ a: V, _ b: V) -> Bool {
        let ea = (try? encoder().encode(a)) ?? Data(), eb = (try? encoder().encode(b)) ?? Data()
        return ea.lexicographicallyPrecedes(eb)
    }
}

func minDate(_ a: Date?, _ b: Date?) -> Date? {
    guard let a else { return b }
    guard let b else { return a }
    return min(a, b)
}

func maxDate(_ a: Date?, _ b: Date?) -> Date? {
    guard let a else { return b }
    guard let b else { return a }
    return max(a, b)
}

func joinRegisters<V>(_ a: [String: SyncRegister<V>], _ b: [String: SyncRegister<V>]) -> [String: SyncRegister<V>] {
    a.merging(b) { $0.joined($1) }
}

// MARK: - Photo

/// The stored copy a photo record points at. Each device keeps the copy it has; the record
/// holds the best one any device has offered, which is what a device without a copy downloads.
public struct SyncFileInfo: Codable, Sendable, Equatable {
    public var sha256: String
    public var mimeType: String
    public var ext: String
    public var byteSize: Int
    public var width: Int
    public var height: Int
    public var reducedFrom: ReducedFrom?

    public init(sha256: String, mimeType: String, ext: String, byteSize: Int, width: Int, height: Int,
                reducedFrom: ReducedFrom?) {
        self.sha256 = sha256
        self.mimeType = mimeType
        self.ext = ext
        self.byteSize = byteSize
        self.width = width
        self.height = height
        self.reducedFrom = reducedFrom
    }

    init(_ photo: PhotoRecord) {
        let name = photo.originalFile.split(separator: "/").last.map(String.init) ?? ""
        let ext = name.split(separator: ".", omittingEmptySubsequences: false).dropFirst().last.map(String.init) ?? "bin"
        self.init(sha256: photo.sha256, mimeType: photo.mimeType, ext: ext, byteSize: photo.byteSize,
                  width: photo.width, height: photo.height, reducedFrom: photo.reducedFrom)
    }

    /// The photo all copies were made from: what tells two imports are the same photo.
    public var sourceHash: String { reducedFrom?.sha256 ?? sha256 }

    /// More pixels first (a whole file beats a 2048 px copy beats a 1024 px preview), then
    /// more bytes, then the hash, so every device ranks two copies the same way.
    func better(than other: SyncFileInfo) -> Bool {
        let a = area, b = other.area
        if a != b { return a > b }
        if byteSize != other.byteSize { return byteSize > other.byteSize }
        return sha256 > other.sha256
    }

    /// Pixels, saturating: a side no file has must not trap the ranking.
    private var area: Int {
        let (product, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? .max : product
    }

    /// The largest side or size a readable record may give a copy: more than any file the app
    /// stores, and small enough that every sum and product of two stays inside an `Int`.
    static let maxValue = Int(Int32.max)

    var isInRange: Bool {
        let fits: (Int) -> Bool = { $0 >= 0 && $0 <= Self.maxValue }
        return fits(width) && fits(height) && fits(byteSize)
            && reducedFrom.map { fits($0.width) && fits($0.height) && fits($0.byteSize) } ?? true
    }
}

/// How the shown capture day is chosen. Only a user action writes this register; reading a
/// file's EXIF writes `exifDay` instead, so a repair can never undo the user's choice.
public enum SyncDateChoice: Codable, Sendable, Equatable {
    /// The day from the file's EXIF, or unknown when it has none.
    case followFile
    /// Explicitly unknown even if the file has a day (a web backup's record).
    case unknown
    /// The day the user typed.
    case user(String)

    init(_ photo: PhotoRecord) {
        switch photo.captureDateSource {
        case .user: self = .user(photo.captureDate ?? "")
        case .exif: self = .followFile
        case .unknown: self = photo.exifCaptureDate == nil ? .followFile : .unknown
        }
    }
}

public struct PhotoSyncRecord: Codable, Sendable, Equatable {
    /// SHA-256 of the photo every copy was made from. The record's name.
    public let sourceHash: String
    /// Every photo id a device gave this photo, sorted. The smallest is the one all devices use.
    public var photoIds: [String]
    /// When the photo first entered the home on any device.
    public var importedAt: Date
    /// Every stored copy a device has offered, by hash. Each device keeps its own; one
    /// without a copy downloads `file`, or the next best copy the cloud still has.
    public var copies: [SyncFileInfo]
    public var filename: SyncRegister<String?>
    public var exifDay: SyncRegister<String?>
    public var date: SyncRegister<SyncDateChoice>
    public var favorite: SyncRegister<Bool>
    public var note: SyncRegister<String>
    public var cloudIdentifier: SyncRegister<String?>
    public var tomb: SyncTombstone?
    /// Every device's newest write here, adding a copy or an id included.
    public var edits = SyncVersion()

    public var canonicalId: String { photoIds[0] }

    /// The best copy: what a device without one downloads.
    public var file: SyncFileInfo { copiesBestFirst[0] }

    public var copiesBestFirst: [SyncFileInfo] {
        copies.sorted { $0.better(than: $1) }
    }

    mutating func addCopy(_ copy: SyncFileInfo) {
        copies = Self.union(copies, [copy])
    }

    static func union(_ a: [SyncFileInfo], _ b: [SyncFileInfo]) -> [SyncFileInfo] {
        var bySha: [String: SyncFileInfo] = [:]
        for copy in a + b {
            bySha[copy.sha256] = bySha[copy.sha256].map { SyncCoding.orderedBefore(copy, $0) ? copy : $0 } ?? copy
        }
        return bySha.keys.sorted().map { bySha[$0]! }
    }

    var version: SyncVersion {
        edits.joined(SyncVersion([filename.stamp, exifDay.stamp, date.stamp, favorite.stamp, note.stamp, cloudIdentifier.stamp]))
    }

    func joined(_ o: PhotoSyncRecord) -> PhotoSyncRecord {
        var r = self
        r.photoIds = Array(Set(photoIds).union(o.photoIds)).sorted()
        r.importedAt = min(importedAt, o.importedAt)
        r.copies = Self.union(copies, o.copies)
        r.filename = filename.joined(o.filename)
        r.exifDay = exifDay.joined(o.exifDay)
        r.date = date.joined(o.date)
        r.favorite = favorite.joined(o.favorite)
        r.note = note.joined(o.note)
        r.cloudIdentifier = cloudIdentifier.joined(o.cloudIdentifier)
        r.tomb = SyncTombstone.join(tomb, o.tomb)
        r.edits = edits.joined(o.edits)
        return r
    }
}

// MARK: - Observation

/// A stored analysis. Never edited after it is made; it can only be deleted.
public struct ObservationSyncRecord: Codable, Sendable, Equatable {
    public var observation: PhotoObservation
    public var created: SyncStamp
    public var tomb: SyncTombstone?

    var version: SyncVersion { SyncVersion([created]) }

    func joined(_ o: ObservationSyncRecord) -> ObservationSyncRecord {
        var r = created == o.created ? (SyncCoding.orderedBefore(o.observation, observation) ? o : self)
            : (o.created > created ? o : self)
        r.tomb = SyncTombstone.join(tomb, o.tomb)
        return r
    }
}

// MARK: - Furniture

/// Where a piece is: in a room at a placement, or put away (keeping the placement as a hint).
/// One register, so a model, its size and its spot always come from the same edit.
public struct SyncPlace: Codable, Sendable, Equatable {
    public var stored: Bool
    public var roomId: String?
    public var modelId: String
    public var x: Int
    public var z: Int
    public var width: Int
    public var depth: Int
    public var turn: Int
    public var wall: WallSide?
    public var finish: Finish

    init(_ piece: PhotoFurniture, stored: Bool) {
        self.stored = stored
        roomId = piece.roomId
        modelId = piece.modelId
        x = piece.x
        z = piece.z
        width = piece.width
        depth = piece.depth
        turn = piece.turn
        wall = piece.wall
        finish = piece.finish
    }

    func apply(to piece: inout PhotoFurniture) {
        piece.roomId = roomId
        piece.modelId = modelId
        piece.x = x
        piece.z = z
        piece.width = width
        piece.depth = depth
        piece.turn = turn
        piece.wall = wall
        piece.finish = finish
    }
}

public struct FurnitureSyncRecord: Codable, Sendable, Equatable {
    public let instanceId: String
    public var place: SyncRegister<SyncPlace>
    public var name: SyncRegister<String>
    public var tags: SyncRegister<[String]>
    public var locked: SyncRegister<Bool?>
    public var cover: SyncRegister<String?>
    /// The photo order last chosen on some device. Photos it does not mention follow it.
    public var order: SyncRegister<[String]>
    /// One register per photo id as it was written: the link, or nil once taken off.
    public var links: [String: SyncRegister<PhotoCarrierSource?>]
    public var createdAt: Date?
    public var updatedAt: Date?
    public var tomb: SyncTombstone?
    /// Every device's newest write here.
    public var edits = SyncVersion()

    var version: SyncVersion {
        edits.joined(SyncVersion([place.stamp, name.stamp, tags.stamp, locked.stamp, cover.stamp, order.stamp] + links.values.map(\.stamp)))
    }

    func joined(_ o: FurnitureSyncRecord) -> FurnitureSyncRecord {
        var r = self
        r.place = place.joined(o.place)
        r.name = name.joined(o.name)
        r.tags = tags.joined(o.tags)
        r.locked = locked.joined(o.locked)
        r.cover = cover.joined(o.cover)
        r.order = order.joined(o.order)
        r.links = joinRegisters(links, o.links)
        r.createdAt = minDate(createdAt, o.createdAt)
        r.updatedAt = maxDate(updatedAt, o.updatedAt)
        r.tomb = SyncTombstone.join(tomb, o.tomb)
        r.edits = edits.joined(o.edits)
        return r
    }
}

// MARK: - Rooms, cats, home

public struct RoomSyncRecord: Codable, Sendable, Equatable {
    public let roomId: String
    public var name: SyncRegister<String?>
    public var createdAt: Date?
    public var tomb: SyncTombstone?
    public var edits = SyncVersion()

    var version: SyncVersion { edits.joined(SyncVersion([name.stamp])) }

    func joined(_ o: RoomSyncRecord) -> RoomSyncRecord {
        var r = self
        r.name = name.joined(o.name)
        r.createdAt = minDate(createdAt, o.createdAt)
        r.tomb = SyncTombstone.join(tomb, o.tomb)
        r.edits = edits.joined(o.edits)
        return r
    }
}

public struct CatSyncRecord: Codable, Sendable, Equatable {
    public let catId: String
    public var name: SyncRegister<String>
    public var roomId: SyncRegister<String?>
    public var tomb: SyncTombstone?
    public var edits = SyncVersion()

    var version: SyncVersion { edits.joined(SyncVersion([name.stamp, roomId.stamp])) }

    func joined(_ o: CatSyncRecord) -> CatSyncRecord {
        var r = self
        r.name = name.joined(o.name)
        r.roomId = roomId.joined(o.roomId)
        r.tomb = SyncTombstone.join(tomb, o.tomb)
        r.edits = edits.joined(o.edits)
        return r
    }
}

/// The one record for the home as a whole: the order of rooms and cats and the few app
/// settings that follow the user (each its own register). It is never deleted.
public struct HomeSyncRecord: Codable, Sendable, Equatable {
    public var roomOrder: SyncRegister<[String]>
    public var catOrder: SyncRegister<[String]>
    public var settings: [String: SyncRegister<String?>]

    public static let empty = HomeSyncRecord(roomOrder: SyncRegister([], .zero), catOrder: SyncRegister([], .zero), settings: [:])

    func joined(_ o: HomeSyncRecord) -> HomeSyncRecord {
        HomeSyncRecord(roomOrder: roomOrder.joined(o.roomOrder), catOrder: catOrder.joined(o.catOrder),
                       settings: joinRegisters(settings, o.settings))
    }
}

// MARK: - Any record

public enum SyncRecord: Sendable, Equatable {
    case photo(PhotoSyncRecord)
    case observation(ObservationSyncRecord)
    case furniture(FurnitureSyncRecord)
    case room(RoomSyncRecord)
    case cat(CatSyncRecord)
    case home(HomeSyncRecord)

    /// Record names: `photo.<source sha256>`, `obs.<id>`, `furniture.<id>`, `room.<id>`,
    /// `cat.<id>`, `home`. Stable on every device: a photo is named by its content, the rest
    /// by the id made once when the thing was made.
    public var name: String {
        switch self {
        case .photo(let r): Self.photoName(r.sourceHash)
        case .observation(let r): "obs.\(r.observation.observationId)"
        case .furniture(let r): "furniture.\(r.instanceId)"
        case .room(let r): "room.\(r.roomId)"
        case .cat(let r): "cat.\(r.catId)"
        case .home: "home"
        }
    }

    static func photoName(_ sourceHash: String) -> String { "photo.\(sourceHash)" }

    public var type: String {
        switch self {
        case .photo: "MVPhoto"
        case .observation: "MVObservation"
        case .furniture: "MVFurniture"
        case .room: "MVRoom"
        case .cat: "MVCat"
        case .home: "MVHome"
        }
    }

    /// False for a record whose deletion saw every write on it. The home record always lives.
    public var isLive: Bool {
        guard let tomb else { return true }
        return !tomb.seen.covers(version)
    }

    var tomb: SyncTombstone? {
        switch self {
        case .photo(let r): r.tomb
        case .observation(let r): r.tomb
        case .furniture(let r): r.tomb
        case .room(let r): r.tomb
        case .cat(let r): r.tomb
        case .home: nil
        }
    }

    /// Per device, the newest write on the record. The home record has none: it is never deleted.
    var version: SyncVersion {
        switch self {
        case .photo(let r): r.version
        case .observation(let r): r.version
        case .furniture(let r): r.version
        case .room(let r): r.version
        case .cat(let r): r.version
        case .home: SyncVersion()
        }
    }

    /// This version, marked as written by the device that issued `stamp`. An observation is
    /// never edited (its `created` already says who made it), the home record never deleted.
    func written(_ stamp: SyncStamp) -> SyncRecord {
        switch self {
        case .photo(var r): r.edits.add(stamp); return .photo(r)
        case .furniture(var r): r.edits.add(stamp); return .furniture(r)
        case .room(var r): r.edits.add(stamp); return .room(r)
        case .cat(var r): r.edits.add(stamp); return .cat(r)
        case .observation, .home: return self
        }
    }

    /// The record's own `edits` as stored; nil for those without (observations, the home).
    var edits: SyncVersion? {
        switch self {
        case .photo(let r): r.edits
        case .furniture(let r): r.edits
        case .room(let r): r.edits
        case .cat(let r): r.edits
        case .observation, .home: nil
        }
    }

    /// The newest stamp anywhere in the record, deletions included.
    var newestStamp: SyncStamp {
        switch self {
        case .home(let r): ([r.roomOrder.stamp, r.catOrder.stamp] + r.settings.values.map(\.stamp)).max()!
        default: [version.newest, tomb?.at ?? .zero, tomb?.seen.newest ?? .zero].max()!
        }
    }

    /// The newest write in this record issued under `device`'s id.
    func newestStamp(of device: String) -> SyncStamp? {
        var stamps: [SyncStamp]
        switch self {
        case .home(let r): stamps = [r.roomOrder.stamp, r.catOrder.stamp] + r.settings.values.map(\.stamp)
        default: stamps = [version[device], tomb?.at, tomb?.seen[device]].compactMap { $0 }
        }
        return stamps.filter { $0.device == device }.max()
    }

    /// The join of two versions of the same record; nil when they are not the same record.
    public func joined(_ other: SyncRecord) -> SyncRecord? {
        switch (self, other) {
        case (.photo(let a), .photo(let b)) where a.sourceHash == b.sourceHash: .photo(a.joined(b))
        case (.observation(let a), .observation(let b)) where a.observation.observationId == b.observation.observationId:
            .observation(a.joined(b))
        case (.furniture(let a), .furniture(let b)) where a.instanceId == b.instanceId: .furniture(a.joined(b))
        case (.room(let a), .room(let b)) where a.roomId == b.roomId: .room(a.joined(b))
        case (.cat(let a), .cat(let b)) where a.catId == b.catId: .cat(a.joined(b))
        case (.home(let a), .home(let b)): .home(a.joined(b))
        default: nil
        }
    }
}

// MARK: - On the wire

/// A record as it is stored in the cloud: type, name, format and a JSON payload. A format this
/// build does not know is kept as it is, never merged, rewritten or deleted.
public struct SyncEnvelope: Codable, Sendable, Equatable {
    /// Bump for any change a reader of the previous format would drop or misread, including a
    /// new field: an older build then keeps the record untouched instead of losing the field.
    /// The one exception so far is `SyncTombstone.together` (round 12): an older build drops it
    /// from the records it writes, but it writes only its own photo's record, and a partner's
    /// list (which names that record) is enough to rejoin them (docs/ICLOUD_SYNC.md §9, with the
    /// case this leaves open). Bumping would instead hold back every deleted shared photo on
    /// those builds.
    public static let currentFormat = 1

    /// The record types this build reads. Any other type is from a newer version (§9).
    static let knownTypes: Set<String> = ["MVPhoto", "MVObservation", "MVFurniture", "MVRoom", "MVCat", "MVHome"]

    public var type: String
    public var name: String
    public var format: Int
    public var payload: Data

    public init(type: String, name: String, format: Int, payload: Data) {
        self.type = type
        self.name = name
        self.format = format
        self.payload = payload
    }

    public init(_ record: SyncRecord) throws {
        let encoder = SyncCoding.encoder()
        let payload: Data
        switch record {
        case .photo(let r): payload = try encoder.encode(r)
        case .observation(let r): payload = try encoder.encode(r)
        case .furniture(let r): payload = try encoder.encode(r)
        case .room(let r): payload = try encoder.encode(r)
        case .cat(let r): payload = try encoder.encode(r)
        case .home(let r): payload = try encoder.encode(r)
        }
        self.init(type: record.type, name: record.name, format: Self.currentFormat, payload: payload)
    }

    /// nil for a newer format, an unknown type, a payload that does not decode, or a payload
    /// whose own name disagrees with the envelope's.
    public func decoded() -> SyncRecord? {
        guard format <= Self.currentFormat else { return nil }
        let decoder = SyncCoding.decoder()
        let record: SyncRecord?
        switch type {
        case "MVPhoto": record = (try? decoder.decode(PhotoSyncRecord.self, from: payload)).map(SyncRecord.photo)
        case "MVObservation": record = (try? decoder.decode(ObservationSyncRecord.self, from: payload)).map(SyncRecord.observation)
        case "MVFurniture": record = (try? decoder.decode(FurnitureSyncRecord.self, from: payload)).map(SyncRecord.furniture)
        case "MVRoom": record = (try? decoder.decode(RoomSyncRecord.self, from: payload)).map(SyncRecord.room)
        case "MVCat": record = (try? decoder.decode(CatSyncRecord.self, from: payload)).map(SyncRecord.cat)
        case "MVHome": record = (try? decoder.decode(HomeSyncRecord.self, from: payload)).map(SyncRecord.home)
        default: record = nil
        }
        guard let record, record.name == name, record.isInRange else { return nil }
        if case .photo(let photo) = record, photo.photoIds.isEmpty || photo.copies.isEmpty
            || photo.copies.contains(where: { $0.sourceHash != photo.sourceHash }) { return nil }
        return record
    }

    /// For a version this device stored itself, which an earlier build (no range check) may
    /// have merged from a record with a stamp past `SyncStamp.maxCounter`: the same record
    /// with such counters brought back into range, so the rest of it, this device's unsent
    /// edits included, is kept and sent. nil when anything else is wrong with it: a value out
    /// of range is not guessed at.
    ///
    /// Counters past the limit keep their order among themselves (a re-import after a deletion
    /// still comes after it) and land just under `SyncClock.ceiling`, where a clock that reached
    /// the top goes on from: this device's next edit, and any device's after it has seen them,
    /// still comes later. A negative counter becomes 0.
    func decodedClampingCounters() -> SyncRecord? {
        guard format <= Self.currentFormat, let json = try? JSONSerialization.jsonObject(with: payload) else { return nil }
        // A stamp: exactly the keys of `SyncStamp.CodingKeys`, with an integer counter.
        func counter(_ object: [String: Any]) -> Int? {
            guard Set(object.keys) == ["w", "c", "d"], let number = object["c"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return object["c"] as? Int
        }
        var past = Set<Int>()
        func collect(_ value: Any) {
            if let array = value as? [Any] { array.forEach(collect); return }
            guard let object = value as? [String: Any] else { return }
            if let c = counter(object) { if c > SyncStamp.maxCounter { past.insert(c) }; return }
            object.values.forEach(collect)
        }
        collect(json)
        let order = past.sorted()
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let base = SyncClock.ceiling.counter - order.count
        func clamp(_ value: Any) -> Any {
            if let array = value as? [Any] { return array.map(clamp) }
            guard var object = value as? [String: Any] else { return value }
            if let c = counter(object) {
                if c < 0 { object["c"] = 0 } else if let r = rank[c] { object["c"] = base + r }
                return object
            }
            return object.mapValues(clamp)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: clamp(json)) else { return nil }
        return SyncEnvelope(type: type, name: name, format: format, payload: data).decoded()
    }
}

// MARK: - Values a readable record may hold

extension SyncTombstone {
    /// A group deletion names its records; no library holds this many copies of one photo.
    static let maxTogether = 1_000

    var isInRange: Bool { at.isInRange && seen.isInRange && (together?.count ?? 0) <= Self.maxTogether }
}

extension SyncVersion {
    /// Also only what `add` builds: each stamp under the id of the device that issued it, and
    /// never the zero stamp. A vector with devB's stamp under devA's key joins as neither
    /// idempotent nor commutative (`joined` adds by the stamp's own device), so devices holding
    /// it would not settle on one record (audit C24-08). No build writes one; it is held back.
    var isInRange: Bool {
        stamps.allSatisfy { key, stamp in key == stamp.device && stamp != .zero && stamp.isInRange }
    }
}

extension SyncPlace {
    /// Far past any room (15 cells) or piece, and small enough that cell arithmetic on it
    /// (`x + width`, `2 * x + w`) stays inside an `Int`.
    static let maxValue = 1 << 20

    var isInRange: Bool {
        [x, z, width, depth, turn].allSatisfy { (-Self.maxValue...Self.maxValue).contains($0) }
    }
}

extension SyncRecord {
    /// False for values no build of the app writes (round-12 audit CLOUDKIT-4): a stamp past
    /// `SyncStamp.maxCounter`, a copy's side or size past `SyncFileInfo.maxValue`, a spot no
    /// room has. Ranking copies, ticking a clock that saw the stamp, or laying out the piece
    /// would trap on them, on every launch, since the record stays in the cloud. Such a record
    /// is unreadable to this build, like one from a newer format: kept as it came and never
    /// merged, and what it names stays as this device has it. Wall times are not checked: a
    /// device whose clock runs ahead still writes honest records.
    var isInRange: Bool {
        // `version` is a join and so always well keyed: the stored `edits` are checked as stored.
        let stampsFit = version.isInRange && (tomb?.isInRange ?? true) && (edits?.isInRange ?? true)
        switch self {
        case .photo(let r):
            return stampsFit && r.copies.allSatisfy(\.isInRange)
                && [r.filename.stamp, r.exifDay.stamp, r.date.stamp, r.favorite.stamp, r.note.stamp, r.cloudIdentifier.stamp].allSatisfy(\.isInRange)
        case .observation(let r):
            return stampsFit && r.created.isInRange
        case .furniture(let r):
            return stampsFit && r.place.value.isInRange
                && ([r.place.stamp, r.name.stamp, r.tags.stamp, r.locked.stamp, r.cover.stamp, r.order.stamp] + r.links.values.map(\.stamp)).allSatisfy(\.isInRange)
        case .room(let r):
            return stampsFit && r.name.stamp.isInRange
        case .cat(let r):
            return stampsFit && r.name.stamp.isInRange && r.roomId.stamp.isInRange
        case .home(let r):
            return ([r.roomOrder.stamp, r.catOrder.stamp] + r.settings.values.map(\.stamp)).allSatisfy(\.isInRange)
        }
    }
}

// MARK: - A device's copy of every record

/// Every record this device knows, merged. Records it cannot read are kept as they came.
public struct SyncReplica: Codable, Sendable, Equatable {
    public private(set) var records: [String: SyncRecord] = [:]
    /// Envelopes of a newer format or unknown type, by name.
    public private(set) var unreadable: [String: SyncEnvelope] = [:]

    public init() {}

    public subscript(name: String) -> SyncRecord? { records[name] }

    /// Merges one version in. Returns true when the stored record changed.
    @discardableResult
    public mutating func merge(_ record: SyncRecord) -> Bool {
        let name = record.name
        guard let old = records[name] else {
            records[name] = record
            return true
        }
        guard let joined = old.joined(record), joined != old else { return false }
        records[name] = joined
        return true
    }

    /// Merges a version from the cloud. One this build cannot read is kept as it came (the
    /// highest format, then the latest delivered); the thing it describes is then left as this
    /// device has it, and this device never uploads that record.
    @discardableResult
    public mutating func merge(_ envelope: SyncEnvelope) -> Bool {
        if let record = envelope.decoded() {
            // A version of this build's format that could not be read (values out of range) is
            // replaced by the cloud's next readable one. A newer format stays held: which of the
            // two is newer cannot be told.
            var cleared = false
            if let kept = unreadable[envelope.name], kept.format <= SyncEnvelope.currentFormat {
                unreadable[envelope.name] = nil
                cleared = true
            }
            return merge(record) || cleared
        }
        // Which of two unreadable versions is newer cannot be told; every device keeps the same
        // one (higher format, then the larger payload), and `readHeldBack` refetches all anyway.
        if let kept = unreadable[envelope.name], kept == envelope || kept.format > envelope.format
            || kept.format == envelope.format && !kept.payload.lexicographicallyPrecedes(envelope.payload) { return false }
        unreadable[envelope.name] = envelope
        return true
    }

    /// Treats `names` as held back, for building a library without them (`holdingBack`).
    mutating func markUnreadable(_ names: Set<String>) {
        for name in names where unreadable[name] == nil {
            let type = records[name]?.type ?? ""
            unreadable[name] = SyncEnvelope(type: type, name: name, format: .max, payload: Data())
        }
    }

    /// After an upgrade: held-back versions this build can read now are merged and no longer
    /// held back. Returns true when there were any; the device then fetches everything again,
    /// since the version it kept may not have been the newest.
    mutating func readHeldBack() -> Bool {
        var read = false
        for (name, envelope) in unreadable {
            guard let record = envelope.decoded() else { continue }
            unreadable[name] = nil
            merge(record)
            read = true
        }
        return read
    }

    var photos: [PhotoSyncRecord] {
        records.values.compactMap { if case .photo(let r) = $0 { r } else { nil } }
    }

    var observations: [ObservationSyncRecord] {
        records.values.compactMap { if case .observation(let r) = $0 { r } else { nil } }
    }

    var furniture: [FurnitureSyncRecord] {
        records.values.compactMap { if case .furniture(let r) = $0 { r } else { nil } }
    }

    var rooms: [RoomSyncRecord] {
        records.values.compactMap { if case .room(let r) = $0 { r } else { nil } }
    }

    var cats: [CatSyncRecord] {
        records.values.compactMap { if case .cat(let r) = $0 { r } else { nil } }
    }

    var home: HomeSyncRecord {
        if case .home(let r) = records["home"] { return r }
        return .empty
    }

    // Codable: the enum is stored as envelopes, the same bytes as in the cloud.
    private enum CodingKeys: String, CodingKey { case records, unreadable }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unreadable = try c.decode([String: SyncEnvelope].self, forKey: .unreadable)
        for envelope in try c.decode([SyncEnvelope].self, forKey: .records) {
            guard let record = envelope.decoded() ?? envelope.decodedClampingCounters() else {
                // One this build no longer accepts (an earlier build merged it before the range
                // check, CLOUDKIT-4) and that bringing its counters into range does not save:
                // held back by itself, like a newer format, and never sent. The rest of the file
                // still reads; the next readable version replaces it.
                if unreadable[envelope.name] == nil { unreadable[envelope.name] = envelope }
                continue
            }
            records[record.name] = record
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(try records.keys.sorted().map { try SyncEnvelope(records[$0]!) }, forKey: .records)
        try c.encode(unreadable, forKey: .unreadable)
    }
}
