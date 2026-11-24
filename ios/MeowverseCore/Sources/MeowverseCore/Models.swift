import Foundation

/// Where a capture date came from. Mirrors `captureDateSource` in contracts/domain.ts.
public enum CaptureDateSource: String, Codable, Sendable, Equatable {
    case exif, user, unknown
}

/// One imported original. `id == photoId`.
///
/// `captureDate` / `captureDateSource` are the day the app shows. `exifCaptureDate` is the day
/// read from the file, so a user edit can always be undone.
public struct PhotoRecord: Identifiable, Codable, Sendable, Equatable {
    public var id: String { photoId }

    public let photoId: String
    public var filename: String?
    public let sha256: String
    public let mimeType: String
    public let byteSize: Int
    public internal(set) var width: Int
    public internal(set) var height: Int
    /// Path relative to the store root, e.g. `originals/<sha256>.jpeg`.
    public let originalFile: String
    /// Path relative to the store root, e.g. `thumbnails/<photoId>.jpg`.
    public let thumbnailFile: String
    /// `yyyy-MM-dd` calendar day, or nil when unknown.
    public var captureDate: String?
    public var captureDateSource: CaptureDateSource
    /// `yyyy-MM-dd` from the file's EXIF DateTimeOriginal, or nil if the file has none.
    public internal(set) var exifCaptureDate: String?
    public let importedAt: Date
    public var favorite: Bool
    /// Plain text, at most 2000 UTF-16 code units; empty allowed.
    public var note: String
    public var revision: Int
    /// Schema 8. Set when the stored file is a reduced copy: `sha256`, `byteSize`, `width` and
    /// `height` then describe that copy, and this describes the photo it was made from (which
    /// the app does not keep). nil when the stored file is the picked photo itself.
    public let reducedFrom: ReducedFrom?
    /// The photo library's local identifier of the asset this photo was picked from, or nil
    /// (a photo from a backup made elsewhere, the web import, or a build before this field).
    /// Only a hint: it means something on the device that picked the photo and nowhere else,
    /// the asset may since be deleted, and reading the library through it needs a permission
    /// the app does not ask for. Never used to decide whether two photos are the same.
    public var assetIdentifier: String?
    /// The photo library's cross-device identifier (`PHCloudIdentifier`) of the same asset, or
    /// nil. It finds the asset again on another device signed in to the same iCloud Photos
    /// library. A hint, like `assetIdentifier`.
    public var cloudIdentifier: String?

    public init(photoId: String, filename: String?, sha256: String, mimeType: String, byteSize: Int,
                width: Int, height: Int, originalFile: String, thumbnailFile: String,
                captureDate: String?, captureDateSource: CaptureDateSource, exifCaptureDate: String?,
                importedAt: Date, favorite: Bool = false, note: String = "", revision: Int,
                reducedFrom: ReducedFrom? = nil, assetIdentifier: String? = nil,
                cloudIdentifier: String? = nil) {
        self.photoId = photoId
        self.filename = filename
        self.sha256 = sha256
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.width = width
        self.height = height
        self.originalFile = originalFile
        self.thumbnailFile = thumbnailFile
        self.captureDate = captureDate
        self.captureDateSource = captureDateSource
        self.exifCaptureDate = exifCaptureDate
        self.importedAt = importedAt
        self.favorite = favorite
        self.note = note
        self.revision = revision
        self.reducedFrom = reducedFrom
        self.assetIdentifier = assetIdentifier
        self.cloudIdentifier = cloudIdentifier
    }

    /// True when `draft` is this photo: the same stored bytes, or made from the same source.
    /// A photo an older build stored whole matches the reduced draft of the same picked file.
    public func isSamePhoto(as draft: ImportDraft) -> Bool {
        if sha256 == draft.sha256 { return true }
        return (reducedFrom?.sha256 ?? sha256) == (draft.reducedFrom?.sha256 ?? draft.sha256)
    }

    /// Identical bytes may belong to two distinct Photos assets. Keep identifiers paired.
    mutating func learnLibraryIdentifiers(from draft: ImportDraft) {
        guard let local = draft.assetIdentifier else { return }
        if draft.missingLibraryBinding?.matches(self) == true {
            assetIdentifier = local
            cloudIdentifier = draft.cloudIdentifier
            return
        }
        guard assetIdentifier == nil || assetIdentifier == local,
              cloudIdentifier == nil || draft.cloudIdentifier == cloudIdentifier else { return }
        assetIdentifier = local
        if cloudIdentifier == nil { cloudIdentifier = draft.cloudIdentifier }
    }

    private enum CodingKeys: String, CodingKey {
        case photoId, filename, sha256, mimeType, byteSize, width, height, originalFile, thumbnailFile
        case captureDate, captureDateSource, exifCaptureDate, importedAt, favorite, note, revision, reducedFrom, assetIdentifier, cloudIdentifier
    }

    /// Reads schema 1 and 2. Schema 1 has no `favorite`, `note` or `exifCaptureDate`: they
    /// default to false, "" and (when the stored day came from EXIF) that day.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        photoId = try c.decode(String.self, forKey: .photoId)
        filename = try c.decodeIfPresent(String.self, forKey: .filename)
        sha256 = try c.decode(String.self, forKey: .sha256)
        mimeType = try c.decode(String.self, forKey: .mimeType)
        byteSize = try c.decode(Int.self, forKey: .byteSize)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        originalFile = try c.decode(String.self, forKey: .originalFile)
        thumbnailFile = try c.decode(String.self, forKey: .thumbnailFile)
        captureDate = try c.decodeIfPresent(String.self, forKey: .captureDate)
        captureDateSource = try c.decode(CaptureDateSource.self, forKey: .captureDateSource)
        if c.contains(.exifCaptureDate) {
            exifCaptureDate = try c.decodeIfPresent(String.self, forKey: .exifCaptureDate)
        } else {
            exifCaptureDate = captureDateSource == .exif ? captureDate : nil
        }
        importedAt = try c.decode(Date.self, forKey: .importedAt)
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        revision = try c.decode(Int.self, forKey: .revision)
        reducedFrom = try c.decodeIfPresent(ReducedFrom.self, forKey: .reducedFrom)
        assetIdentifier = try c.decodeIfPresent(String.self, forKey: .assetIdentifier)
        cloudIdentifier = try c.decodeIfPresent(String.self, forKey: .cloudIdentifier)
    }

    /// Both day fields are written as explicit nulls, like the web contract.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(photoId, forKey: .photoId)
        try c.encodeIfPresent(filename, forKey: .filename)
        try c.encode(sha256, forKey: .sha256)
        try c.encode(mimeType, forKey: .mimeType)
        try c.encode(byteSize, forKey: .byteSize)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(originalFile, forKey: .originalFile)
        try c.encode(thumbnailFile, forKey: .thumbnailFile)
        try c.encode(captureDate, forKey: .captureDate)
        try c.encode(captureDateSource, forKey: .captureDateSource)
        try c.encode(exifCaptureDate, forKey: .exifCaptureDate)
        try c.encode(importedAt, forKey: .importedAt)
        try c.encode(favorite, forKey: .favorite)
        try c.encode(note, forKey: .note)
        try c.encode(revision, forKey: .revision)
        try c.encodeIfPresent(reducedFrom, forKey: .reducedFrom)
        try c.encodeIfPresent(assetIdentifier, forKey: .assetIdentifier)
        try c.encodeIfPresent(cloudIdentifier, forKey: .cloudIdentifier)
    }
}

/// Mirrors `SourceOrigin` in contracts/domain.ts.
public enum SourceOrigin: String, Codable, Sendable, Equatable {
    case curatedFixture = "curated_fixture"
    case user
    case model
}

/// Mirrors `Relation` in contracts/domain.ts.
public enum Relation: String, Codable, Sendable, Equatable {
    case on, `in`, under, near, background, unclear
}

/// How an observation was produced on iOS.
public enum AnalysisMode: String, Codable, Sendable, Equatable {
    case manual
    case onDevice = "on_device"
    /// Only on observations carried over from a web backup (contracts `AnalysisMode`).
    case fixture
    case remote
}

public struct ObservedObject: Codable, Sendable, Equatable {
    public let kind: FurnitureCategory
    /// Raw classifier identifier that produced this category.
    public let label: String
    public let confidence: Double

    public init(kind: FurnitureCategory, label: String, confidence: Double) {
        self.kind = kind
        self.label = label
        self.confidence = confidence
    }
}

public struct RecognitionResult: Codable, Sendable, Equatable {
    public let analyzer: String
    public let analyzerRevision: Int
    /// Best label per category, sorted by confidence descending.
    public let objects: [ObservedObject]
    /// nil = the analyzer could not say.
    public let catLikely: Bool?

    public init(analyzer: String, analyzerRevision: Int, objects: [ObservedObject], catLikely: Bool?) {
        self.analyzer = analyzer
        self.analyzerRevision = analyzerRevision
        self.objects = objects
        self.catLikely = catLikely
    }
}

/// A stored analysis of one photo. Object indexes are only meaningful within one observation.
public struct PhotoObservation: Identifiable, Codable, Sendable, Equatable {
    public var id: String { observationId }

    public let observationId: String
    public let photoId: String
    public let origin: SourceOrigin
    public let mode: AnalysisMode
    public let analyzer: String
    public let analyzerRevision: Int
    public let objects: [ObservedObject]
    public let createdAt: Date

    public init(observationId: String, photoId: String, origin: SourceOrigin, mode: AnalysisMode,
                analyzer: String, analyzerRevision: Int, objects: [ObservedObject], createdAt: Date) {
        self.observationId = observationId
        self.photoId = photoId
        self.origin = origin
        self.mode = mode
        self.analyzer = analyzer
        self.analyzerRevision = analyzerRevision
        self.objects = objects
        self.createdAt = createdAt
    }
}

/// Mirrors `PhotoCarrierSource` in contracts/photo-world.ts.
public struct PhotoCarrierSource: Codable, Sendable, Equatable {
    public let photoId: String
    public let observationId: String?
    public let objectIndex: Int?
    public let origin: SourceOrigin
    public let relationToCat: Relation
    /// When the photo was put on the piece. nil on links made before this field existed and on
    /// links from a web backup: unknown stays unknown, the import time never stands in for it.
    public var addedAt: Date?

    public init(photoId: String, observationId: String?, objectIndex: Int?, origin: SourceOrigin, relationToCat: Relation,
                addedAt: Date? = nil) {
        self.photoId = photoId
        self.observationId = observationId
        self.objectIndex = objectIndex
        self.origin = origin
        self.relationToCat = relationToCat
        self.addedAt = addedAt
    }

    /// A purely manual link: no observation reference, unclear relation.
    public static func manual(photoId: String, addedAt: Date? = nil) -> PhotoCarrierSource {
        PhotoCarrierSource(photoId: photoId, observationId: nil, objectIndex: nil, origin: .user, relationToCat: .unclear,
                           addedAt: addedAt)
    }

    // The web contract stores explicit nulls; keep that on disk.
    private enum CodingKeys: String, CodingKey { case photoId, observationId, objectIndex, origin, relationToCat, addedAt }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(photoId, forKey: .photoId)
        try c.encode(observationId, forKey: .observationId)
        try c.encode(objectIndex, forKey: .objectIndex)
        try c.encode(origin, forKey: .origin)
        try c.encode(relationToCat, forKey: .relationToCat)
        try c.encodeIfPresent(addedAt, forKey: .addedAt)
    }
}

/// The two walls the room draws. `.left` runs along the z axis at the x = 0 edge, `.back` along
/// the x axis at the z = 0 edge.
public enum WallSide: String, Codable, Sendable {
    case left, back
}

/// Mirrors `PhotoFurniture` in contracts/photo-world.ts. `id == instanceId`.
///
/// `sources` may be empty: a piece placed straight from the catalog has no photos yet, and a
/// piece keeps its place when its last photo is deleted.
///
/// A wall-mounted piece (`wall != nil`) uses no floor cells: `x` is its offset along that wall
/// in cells, `z` is 0, `width` its span along the wall, `depth` 1 (nominal) and `turn` 0.
public struct PhotoFurniture: Identifiable, Codable, Sendable, Equatable {
    public var id: String { instanceId }

    public let instanceId: String
    public var modelId: String
    public var x: Int
    public var z: Int
    /// Unrotated footprint width in cells (one of the catalog `sizes`).
    public var width: Int
    /// Unrotated footprint depth in cells.
    public var depth: Int
    /// Quarter turns, 0...3. Odd turns swap width/depth on the grid.
    public var turn: Int
    /// The wall it hangs on; nil (and absent in files before schema 6) = stands on the floor.
    public var wall: WallSide?
    public var finish: Finish
    public var displayName: String
    public var sources: [PhotoCarrierSource]
    public var tags: [String]
    public var revision: Int
    /// When the piece was made, and when it last changed in any way (photos, name, look, place).
    /// Both nil on pieces from before these fields existed: unknown stays unknown.
    public var createdAt: Date?
    public var updatedAt: Date?
    /// `true` while the piece is locked: it cannot be moved, turned, restyled, put away or
    /// deleted until it is unlocked. Photos, name and tags stay editable. nil (and absent in
    /// the file) = not locked, so unlocking leaves the file as it was before the lock.
    public var locked: Bool?
    /// The photo shown for the piece in lists. nil, or a photo no longer on the piece = the
    /// first photo (`cover`).
    public var coverPhotoId: String?
    /// The room the piece stands in. nil (and absent in the file) = the first room, so a home
    /// with one room has no room ids at all. A piece in the storage box keeps the room it came
    /// from as a hint; it is not checked while stored.
    public var roomId: String?

    public init(instanceId: String, modelId: String, x: Int, z: Int, width: Int, depth: Int, turn: Int,
                wall: WallSide? = nil, finish: Finish, displayName: String, sources: [PhotoCarrierSource],
                tags: [String], revision: Int, createdAt: Date? = nil, updatedAt: Date? = nil,
                locked: Bool? = nil, coverPhotoId: String? = nil, roomId: String? = nil) {
        self.instanceId = instanceId
        self.modelId = modelId
        self.x = x
        self.z = z
        self.width = width
        self.depth = depth
        self.turn = turn
        self.wall = wall
        self.finish = finish
        self.displayName = displayName
        self.sources = sources
        self.tags = tags
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.locked = locked
        self.coverPhotoId = coverPhotoId
        self.roomId = roomId
    }

    public var isLocked: Bool { locked == true }

    /// The photo that stands for the piece: the chosen cover while it is still on the piece,
    /// otherwise the first photo; nil for a piece without photos.
    public var cover: String? {
        if let coverPhotoId, sources.contains(where: { $0.photoId == coverPhotoId }) { return coverPhotoId }
        return sources.first?.photoId
    }

    public var placement: Placement {
        Placement(modelId: modelId, x: x, z: z, width: width, depth: depth, turn: turn, finish: finish, wall: wall)
    }
}

/// One room of the home. Every room has the same grid and the same rules; the first room
/// always exists and keeps the id `AppState.primaryRoomId`.
public struct Room: Identifiable, Codable, Sendable, Equatable {
    public var id: String { roomId }
    public let roomId: String
    /// The name the user gave it. nil = not named: the interface shows a default.
    public var name: String?
    /// nil for the first room (it was never "made") and for rooms from before this was recorded.
    public var createdAt: Date?

    public init(roomId: String, name: String? = nil, createdAt: Date? = nil) {
        self.roomId = roomId
        self.name = name
        self.createdAt = createdAt
    }
}

/// A cat of the home. The first cat always exists, keeps the id `AppState.primaryCatId`, and
/// its name is also `AppState.catName` (the field older files and the web backup know).
public struct Cat: Identifiable, Codable, Sendable, Equatable {
    public var id: String { catId }
    public let catId: String
    public var name: String
    /// The room the cat lives in. nil = it keeps the user company: it is in whichever room is
    /// on screen.
    public var roomId: String?

    public init(catId: String, name: String, roomId: String? = nil) {
        self.catId = catId
        self.name = name
        self.roomId = roomId
    }
}

public struct AppState: Codable, Sendable, Equatable {
    /// 2: photos gained `favorite`, `note`, `exifCaptureDate`; photos may exist without furniture.
    /// 3: `catName`; observations may carry the web analysis modes `fixture` / `remote`.
    /// 4: pet furniture model IDs and categories, unreadable by the original catalog.
    /// 5: litter boxes, window perches and drinking furniture.
    /// 6: `storage` (pieces put away, out of the room but still holding their photos); furniture
    ///    may have no source photos; wall-mounted pieces (`wall`) and the photo board category.
    ///    An older build would drop or misplace all three, so it must refuse these files.
    /// 7: `finish` may be a palette preset (`apricot`, `blush`, `lavender`). An older build cannot
    ///    decode those, so it must report the file as newer rather than damaged.
    /// 8: a photo may be stored as a reduced copy (`reducedFrom`). An older build would drop the
    ///    field and then show the copy as the untouched original, so it must refuse these files.
    ///    Main's schema 8 may also hold local and cloud photo identifiers, furniture dates, lock
    ///    and cover choices, and when each photo was linked.
    /// 9: placements can use a 15×15 grid. Earlier versions support only the first 10×10 cells.
    /// 10: the combined layout keeps both the expanded room and all v8 library metadata.
    ///     The installed v9 room build would discard cloud identifiers, locks, covers and dates.
    /// 11: room and cat lists, plus each piece's room assignment. Development v8 homes may
    ///     already contain these fields. V9 and v10 readers would drop them on their next save.
    /// 12: ten household categories (bookcase … fireplace) in observations and through their
    ///     model ids. A v11 reader cannot decode them, so it must report the file as newer.
    ///     Nothing else changed: v11 files load as they are.
    public static let currentSchemaVersion = 12
    /// Oldest layout this build still reads (and rewrites as the current one on the next save).
    public static let oldestReadableSchemaVersion = 1
    public static let defaultCatName = "Kitty"
    /// Counted in characters (grapheme clusters).
    public static let maxCatNameLength = 20
    /// The id of the first room and the first cat, which always exist.
    public static let primaryRoomId = "room-1"
    public static let primaryCatId = "cat-1"
    public static let maxRooms = 8
    public static let maxCats = 6
    public static let maxRoomNameLength = 20

    public var schemaVersion: Int
    public var revision: Int
    /// The cat's name as the user wrote it. Never inferred from photos.
    public var catName: String
    public var photos: [PhotoRecord]
    public var observations: [PhotoObservation]
    /// The furniture in the room. Grid rules and Bella's routine look only here.
    public var items: [PhotoFurniture]
    /// Furniture put away: not in the room, photos and links intact. Each piece keeps its last
    /// placement fields as a hint for putting it back; they are not validated while stored.
    public var storage: [PhotoFurniture]
    /// Every room, the first one first. Empty (and absent in the file) = just the first room,
    /// unnamed. Read `allRooms`, which is never empty.
    public var rooms: [Room]
    /// Every cat, the first one first. Empty (and absent in the file) = just the first cat,
    /// named `catName`. Read `allCats`, which is never empty.
    public var cats: [Cat]

    public init(schemaVersion: Int = AppState.currentSchemaVersion, revision: Int, catName: String = AppState.defaultCatName,
                photos: [PhotoRecord], observations: [PhotoObservation], items: [PhotoFurniture],
                storage: [PhotoFurniture] = [], rooms: [Room] = [], cats: [Cat] = []) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.catName = catName
        self.photos = photos
        self.observations = observations
        self.items = items
        self.storage = storage
        self.rooms = rooms
        self.cats = cats
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, revision, catName, photos, observations, items, storage, rooms, cats }

    /// `rooms` and `cats` are written only when there is more to say than "one room, one cat".
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(revision, forKey: .revision)
        try c.encode(catName, forKey: .catName)
        try c.encode(photos, forKey: .photos)
        try c.encode(observations, forKey: .observations)
        try c.encode(items, forKey: .items)
        try c.encode(storage, forKey: .storage)
        if !rooms.isEmpty { try c.encode(rooms, forKey: .rooms) }
        if !cats.isEmpty { try c.encode(cats, forKey: .cats) }
    }

    /// Files older than 3 have no `catName`: it defaults to "Bella"; files
    /// older than 6 have no `storage`: nothing was put away.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        revision = try c.decode(Int.self, forKey: .revision)
        catName = try c.decodeIfPresent(String.self, forKey: .catName) ?? "Bella" // The implicit name of libraries saved before schema 3.
        photos = try c.decode([PhotoRecord].self, forKey: .photos)
        observations = try c.decode([PhotoObservation].self, forKey: .observations)
        items = try c.decode([PhotoFurniture].self, forKey: .items)
        storage = try c.decodeIfPresent([PhotoFurniture].self, forKey: .storage) ?? []
        rooms = try c.decodeIfPresent([Room].self, forKey: .rooms) ?? []
        cats = try c.decodeIfPresent([Cat].self, forKey: .cats) ?? []
    }

    public static let empty = AppState(revision: 0, photos: [], observations: [], items: [])

    public func photo(id: String) -> PhotoRecord? { photos.first { $0.photoId == id } }
    /// A piece in the room. Stored pieces are not found here: see `storedItem` / `anyItem`.
    public func item(id: String) -> PhotoFurniture? { items.first { $0.instanceId == id } }
    public func storedItem(id: String) -> PhotoFurniture? { storage.first { $0.instanceId == id } }
    /// A piece wherever it is, in the room or put away.
    public func anyItem(id: String) -> PhotoFurniture? { item(id: id) ?? storedItem(id: id) }
    public func observation(id: String) -> PhotoObservation? { observations.first { $0.observationId == id } }

    /// A name ready to store: trimmed, single line, 1...`maxCatNameLength` characters; nil if it is not.
    public static func normalizedCatName(_ raw: String) -> String? {
        normalizedName(raw, max: maxCatNameLength)
    }

    /// The same rule for a room's name.
    public static func normalizedRoomName(_ raw: String) -> String? {
        normalizedName(raw, max: maxRoomNameLength)
    }

    private static func normalizedName(_ raw: String, max: Int) -> String? {
        // Whitespace and joiners at either end join nothing (QA_T2 R2-2).
        let atTheEnds = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200C}\u{200D}"))
        let cleaned = String(raw.unicodeScalars.filter { !isDroppedFromName($0) })
            .trimmingCharacters(in: atTheEnds)
        // At least one scalar that is seen: joiners and tag characters alone are no name.
        let seen = cleaned.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .format, .control, .spaceSeparator, .lineSeparator, .paragraphSeparator: false
            default: !scalar.properties.isWhitespace
            }
        }
        guard seen, cleaned.count <= max else { return nil }
        return cleaned
    }

    /// Control characters, line breaks and invisible format characters. Not the format characters
    /// that hold an emoji together: the zero-width joiner and non-joiner (🐈‍⬛, 👩‍👩‍👧) and the tag
    /// characters of a subdivision flag. `CharacterSet.controlCharacters` takes in all format
    /// characters and split those emoji. Variation selectors are marks, never dropped.
    private static func isDroppedFromName(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.newlines.contains(scalar) { return true }
        switch scalar.properties.generalCategory {
        case .control: return true
        case .format: return !(scalar.value == 0x200C || scalar.value == 0x200D || (0xE0020...0xE007F).contains(scalar.value))
        default: return false
        }
    }
}

/// A proposed footprint for one furniture instance. With `wall` set it is a span on that wall
/// instead (see `PhotoFurniture`).
public struct Placement: Sendable, Equatable {
    public var modelId: String
    public var x: Int
    public var z: Int
    public var width: Int
    public var depth: Int
    public var turn: Int
    public var finish: Finish
    public var wall: WallSide?

    public init(modelId: String, x: Int, z: Int, width: Int, depth: Int, turn: Int = 0, finish: Finish = .original,
                wall: WallSide? = nil) {
        self.modelId = modelId
        self.x = x
        self.z = z
        self.width = width
        self.depth = depth
        self.turn = turn
        self.finish = finish
        self.wall = wall
    }
}
