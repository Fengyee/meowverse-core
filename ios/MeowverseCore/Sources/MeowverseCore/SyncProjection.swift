import Foundation
import os

// Multi-device iCloud sync: from the merged records back to this device's library.
// See docs/ICLOUD_SYNC.md.
//
// The projection only shows what this device can show truthfully: a photo appears once its
// file is here, a link once its photo and observation are here. Everything else waits in the
// records, untouched. Device-local fields (`assetIdentifier`, file paths, the stored copy
// this device keeps, revisions) always come from the device's own library.

/// A copy downloaded from the cloud, checked against its hash and staged in the library folder
/// with a thumbnail made on this device (`LibraryStore.syncIncomingDir`), ready to be stored.
/// Only paths: the bytes stay on disk, so a first sync with hundreds of photos holds one in memory.
public struct SyncIncomingFile: Sendable, Equatable {
    public let info: SyncFileInfo
    /// Relative to the library folder.
    public let stagedFile: String
    public let stagedThumbnail: String

    public init(info: SyncFileInfo, stagedFile: String, stagedThumbnail: String) {
        self.info = info
        self.stagedFile = stagedFile
        self.stagedThumbnail = stagedThumbnail
    }

    /// Checks downloaded bytes against the record and makes the thumbnail. nil if they do not match.
    static func thumbnail(of data: Data, for info: SyncFileInfo) -> Data? {
        guard data.count == info.byteSize, PhotoIngest.sha256Hex(data) == info.sha256,
              let draft = try? PhotoIngest.makeDraft(data: data, filename: nil, reduce: false),
              draft.sha256 == info.sha256 else { return nil }
        return draft.thumbnailJPEG
    }
}

/// A file the store writes when a projected state is applied.
public struct SyncFileWrite: Sendable, Equatable {
    public let originalFile: String
    public let thumbnailFile: String
    public let file: SyncIncomingFile
}

public struct SyncProjectionResult: Sendable {
    /// The library to switch to. Its `revision` is the local one it was built from.
    public var state: AppState
    /// Per photo still to come: its copies, best first. Any one of them is enough.
    public var missingFiles: [[SyncFileInfo]]
    /// Per piece: links not shown yet because their photo or observation has not arrived. The
    /// interface must not call such a piece "no photos yet" while this is above zero.
    public var pendingLinks: [String: Int]
    /// Records whose content this device does not show as merged: a newer format, an unknown
    /// furniture model, values that fail this build's checks, or a record held back because the
    /// library built with it would fail the store's own checks (`quarantined`). Its own version stays.
    /// A photo's other records of the same copy that wait with it (`SyncPhotoGroups.isHeld`)
    /// are not listed: the photo is said once, by the record that cannot be read.
    public var heldBack: [String]
    public var writes: [SyncFileWrite]
    /// Every synced setting (`HomeSyncRecord.settings`).
    public var settings: [String: String?]
    /// The part of `heldBack` that a newer version of the app would not explain: records whose
    /// photo another photo here already has the id or the file of, records left out because the
    /// library built with them failed the store's checks (`LibraryStore.consistencyFault`: a
    /// bug, or records that disagree in a way this build does not resolve), and records of this
    /// build's format with values out of range (`SyncRecord.isInRange`). Each cycle tries again.
    public var quarantined: [String] = []
    /// Pieces held back because this build doesn't have their model. What stands here for one is
    /// the piece as it was, so its place (which carries the model) is not changed from here.
    public var piecesFromNewerVersion: Set<String> = []
    /// Photos here that are on those pieces: not "on no furniture", though no piece here shows them.
    public var photosOnNewerPieces: Set<String> = []
}

/// What sync's records say about this library, without the network (`SyncSession.standing`).
public struct SyncStanding: Sendable, Equatable {
    public var pendingLinks: [String: Int] = [:]
    public var piecesFromNewerVersion: Set<String> = []
    public var photosOnNewerPieces: Set<String> = []

    init() {}
}

enum SyncProjection {
    private static let log = Logger(subsystem: "app.meowverse", category: "sync")

    /// The library this device shows for the merged records. Never one the store refuses
    /// (`LibraryStore.applySynced` checks `isConsistent`, and a refusal there would stop every
    /// incoming change on every cycle): when the full build fails those checks, the records
    /// behind it are held back, the fewest first, and reported, and the rest is shown.
    /// `fault` is the store's check; tests pass their own to reach each stage.
    static func project(_ replica: SyncReplica, local: AppState, downloaded: [String: SyncIncomingFile] = [:],
                        catalog: FurnitureCatalog? = nil,
                        fault: (AppState) -> String? = LibraryStore.consistencyFault) -> SyncProjectionResult {
        // Records of this build's format and a type it knows that it still cannot read: their
        // values are out of range. Not from a newer version, so not said to be. An unknown type
        // is from a newer version at any format (§9).
        let unreadableHere = Set(replica.unreadable.filter {
            $0.value.format <= SyncEnvelope.currentFormat && SyncEnvelope.knownTypes.contains($0.value.type)
        }.keys)
        let newer = Set(replica.unreadable.keys).subtracting(unreadableHere)
        func finished(_ built: SyncProjectionResult, holding held: Set<String>) -> SyncProjectionResult {
            var result = built
            let quarantined = Set(built.quarantined).union(held).union(unreadableHere)
            result.heldBack = Array(Set(built.heldBack).union(quarantined)).sorted()
            result.quarantined = quarantined.subtracting(newer).sorted()
            return result
        }
        let first = build(replica, local: local, downloaded: downloaded, catalog: catalog)
        guard let firstFault = fault(first.state) else { return finished(first, holding: []) }
        log.error("sync: built library fails \(firstFault, privacy: .public); holding back")
        // First the photos the build put side by side with another of the same id or file.
        // Then, with them, one kind of record at a time, then two, then three: photos and
        // observations new to this device; pieces; the records of photos and observations
        // already here (those stay as they are); rooms, cats and the home. Each try starts from
        // all records again, so a kind that did not help is not held in the next try. The first
        // try that clears the fault holds the fewest kinds, not the fewest records; between tries
        // of as many kinds, new photos come first (a known limit: holding the pieces might have
        // been enough and been smaller).
        let clashing = Self.clashing(in: first.state, replica: replica)
        let fresh = Self.newToThisDevice(replica, local: local)
        let pieces = Set(replica.records.keys.filter { $0.hasPrefix("furniture.") })
        let here = Set(replica.records.keys.filter { $0.hasPrefix("photo.") || $0.hasPrefix("obs.") }).subtracting(fresh)
        let rest = Set(replica.records.keys).subtracting(fresh).subtracting(pieces).subtracting(here)
        let kinds = [fresh, pieces, here, rest]
        let subsets = (0..<(1 << kinds.count)).sorted { ($0.nonzeroBitCount, $0) < ($1.nonzeroBitCount, $1) }
        var tried: [Set<String>] = []
        for (stage, mask) in subsets.enumerated() {
            let held = kinds.indices.filter { mask & (1 << $0) != 0 }.reduce(clashing) { $0.union(kinds[$1]) }
            guard !held.isEmpty, !tried.contains(held) else { continue }
            tried.append(held)
            let result = build(replica.holdingBack(held), local: local, downloaded: downloaded, catalog: catalog)
            if let stillFails = fault(result.state) {
                log.error("sync: try \(stage, privacy: .public) still fails \(stillFails, privacy: .public)")
                continue
            }
            return finished(result, holding: held)
        }
        // Nothing narrower helps: this device's library as it is, and every record held.
        var kept = first
        kept.state = local
        kept.missingFiles = []
        kept.pendingLinks = [:]
        kept.writes = []
        return finished(kept, holding: Set(replica.records.keys).union(replica.unreadable.keys))
    }

    /// Photo records behind photos the build shows twice under one id or one stored file.
    private static func clashing(in built: AppState, replica: SyncReplica) -> Set<String> {
        var seenIds = Set<String>(), seenShas = Set<String>(), clashing = Set<String>()
        for photo in built.photos {
            if !seenIds.insert(photo.photoId).inserted || !seenShas.insert(photo.sha256).inserted { clashing.insert(photo.photoId) }
        }
        let byId = Dictionary(built.photos.map { ($0.photoId, $0.sha256) }, uniquingKeysWith: { a, _ in a })
        let clashingShas = Set(clashing.compactMap { byId[$0] })
        return Set(replica.photos.filter { record in
            record.photoIds.contains(where: clashing.contains) || record.copies.contains { clashingShas.contains($0.sha256) }
        }.map { SyncRecord.photoName($0.sourceHash) })
    }

    /// Photo and observation records this library has nothing of yet.
    private static func newToThisDevice(_ replica: SyncReplica, local: AppState) -> Set<String> {
        let mine = Set(local.photos.map(\.photoId))
        let photos = replica.photos.filter { !$0.photoIds.contains(where: mine.contains) }.map { SyncRecord.photoName($0.sourceHash) }
        let localObservations = Set(local.observations.map(\.observationId))
        let observations = replica.observations.filter { !localObservations.contains($0.observation.observationId) }
            .map { "obs.\($0.observation.observationId)" }
        return Set(photos + observations)
    }

    private static func build(_ replica: SyncReplica, local: AppState, downloaded: [String: SyncIncomingFile],
                              catalog: FurnitureCatalog?) -> SyncProjectionResult {
        var result = SyncProjectionResult(state: local, missingFiles: [], pendingLinks: [:], heldBack: [], writes: [],
                                          settings: replica.home.settings.mapValues(\.value))
        let groups = SyncPhotoGroups(replica)
        let aliases = SyncAliases(replica, groups: groups)

        // Photos: this device's order first, then new ones by import time. Records the store
        // counts as one photo (they share a stored copy) are shown once, through `groups`.
        var photos: [PhotoRecord] = []
        var usedIds = Set<String>(), usedShas = Set<String>()
        var canonical: [String: String] = [:] // any photo id → the id the projected photo has
        var claimedBy: [Int: String] = [:] // group → the local photo shown for it
        var localsIn: [Int: Int] = [:]
        for photo in local.photos {
            for index in groups.indices(for: photo) { localsIn[index, default: 0] += 1 }
        }
        func show(_ photo: PhotoRecord) {
            photos.append(photo)
            usedIds.insert(photo.photoId)
            usedShas.insert(photo.sha256)
        }
        for photo in local.photos {
            let key = SyncFileInfo(photo).sourceHash, name = SyncRecord.photoName(key)
            let mine = groups.indices(for: photo)
            func keepAsItIs() {
                show(photo)
                canonical[photo.photoId] = photo.photoId
                for index in mine where claimedBy[index] == nil { claimedBy[index] = photo.photoId }
            }
            // One record of its stored copy that this build cannot read (a newer version, or
            // held back below): the photo stays as this device has it, id and all (§9), and
            // every id of the group still means it, so no link on them waits. Said once, by the
            // record that cannot be read (`replica.unreadable`, below), whatever its partners.
            guard !mine.contains(where: { groups.groups[$0].isHeld }) else {
                keepAsItIs()
                continue
            }
            guard replica.unreadable[name] == nil else {
                result.heldBack.append(name)
                keepAsItIs()
                continue
            }
            guard case .photo(let record) = replica[name] else {
                // Not in the records yet: shown as it is until this device's edits are captured.
                keepAsItIs()
                continue
            }
            // One photo with other records of the same stored copy: shown with all their values
            // joined, the same on every device, and live while any of them is. Two photos here
            // in one group (each in its own record) are shown each from its own record, as the
            // store keeps both.
            let group = groups.group(for: photo).flatMap { found in
                localsIn[found.index] == 1 && found.group.members.map(\.sourceHash) != [key] ? found : nil
            }
            let view: PhotoSyncRecord
            if let group {
                var joined = group.group.merged
                // Which Photos asset this device's photo is stays its own record's.
                joined.cloudIdentifier = record.cloudIdentifier
                view = joined
            } else {
                guard SyncRecord.photo(record).isLive else { continue }
                view = record
            }
            let projected = Self.photo(from: view, file: SyncFileInfo(photo), local: photo,
                                       originalFile: photo.originalFile, thumbnailFile: photo.thumbnailFile)
            // An id another photo here already shows under: this one stays as it is, said.
            let clashes = projected.map { usedIds.contains($0.photoId) } ?? false
            if projected == nil || clashes { result.heldBack.append(contentsOf: group?.group.names ?? [name]) }
            if clashes { result.quarantined.append(contentsOf: group?.group.names ?? [name]) }
            let shown = clashes ? photo : projected ?? photo
            show(shown)
            for id in (clashes ? [] : view.photoIds) + [photo.photoId] { canonical[id] = shown.photoId }
            for index in mine where claimedBy[index] == nil { claimedBy[index] = shown.photoId }
        }
        // A group shown through a local photo: every id it has means that photo.
        for (index, shownId) in claimedBy {
            for id in groups.groups[index].merged.photoIds where canonical[id] == nil { canonical[id] = shownId }
        }
        let fresh = groups.groups.indices.filter { claimedBy[$0] == nil }
            .sorted { (groups.groups[$0].merged.importedAt, groups.groups[$0].merged.canonicalId)
                < (groups.groups[$1].merged.importedAt, groups.groups[$1].merged.canonicalId) }
        for index in fresh {
            let group = groups.groups[index]
            var record = group.merged
            // Not shown until this build can read all of it; said by that record.
            guard !group.isHeld else { continue }
            // The best copy that arrived; the copy decides the stored file's name. What is known
            // of its history (`reducedFrom`) comes from the records, the best any of them says.
            guard let file = record.copiesBestFirst.lazy.compactMap({ downloaded[$0.sha256] }).first else {
                result.missingFiles.append(record.copiesBestFirst)
                continue
            }
            var copy = file.info
            copy.reducedFrom = record.copies.first { $0.sha256 == copy.sha256 }?.reducedFrom ?? copy.reducedFrom
            // Which Photos asset it is comes from the record that history names, the one this
            // photo is shown from on the next cycle (its own record, as for any local photo).
            if let own = group.members.first(where: { $0.sourceHash == copy.sourceHash }) {
                record.cloudIdentifier = own.cloudIdentifier
            }
            let originalFile = "\(LibraryStore.originalsDir)/\(copy.sha256).\(copy.ext)"
            // A web photo keeps its web id, which need not be a file name: then the file's hash is.
            let thumbnailFile = Self.safeId(record.canonicalId) ? "\(LibraryStore.thumbnailsDir)/\(record.canonicalId).jpg"
                : "\(LibraryStore.thumbnailsDir)/s-\(copy.sha256).jpg"
            guard Self.safeExtension(copy.ext), BackupArchive.isHash(copy.sha256), Self.validPhotoId(record.canonicalId),
                  let photo = Self.photo(from: record, file: copy, local: nil,
                                         originalFile: originalFile, thumbnailFile: thumbnailFile) else {
                result.heldBack.append(contentsOf: group.names)
                continue
            }
            // Another photo here with the same id or the same stored file: the store would refuse
            // both, so this one waits, said, and everything else still comes in.
            guard !usedIds.contains(photo.photoId), !usedShas.contains(photo.sha256) else {
                result.heldBack.append(contentsOf: group.names)
                result.quarantined.append(contentsOf: group.names)
                continue
            }
            show(photo)
            for id in record.photoIds { canonical[id] = photo.photoId }
            result.writes.append(SyncFileWrite(originalFile: originalFile, thumbnailFile: thumbnailFile, file: file))
        }
        // Readable or not, a record this device does not show as merged is said.
        result.heldBack += replica.unreadable.keys
        let shownPhotos = Set(photos.map(\.photoId))

        // Observations: kept only with their photo, renamed to the photo's projected id.
        var observations: [PhotoObservation] = []
        var seenObservations = Set<String>()
        func add(_ o: PhotoObservation) {
            guard let photoId = canonical[o.photoId], shownPhotos.contains(photoId) else { return }
            observations.append(PhotoObservation(observationId: o.observationId, photoId: photoId, origin: o.origin, mode: o.mode,
                                                 analyzer: o.analyzer, analyzerRevision: o.analyzerRevision,
                                                 objects: o.objects, createdAt: o.createdAt))
        }
        for o in local.observations {
            let name = "obs.\(o.observationId)"
            seenObservations.insert(o.observationId)
            guard case .observation(let record) = replica[name], replica.unreadable[name] == nil else { add(o); continue }
            if SyncRecord.observation(record).isLive { add(record.observation) }
        }
        for record in replica.observations.sorted(by: { ($0.observation.createdAt, $0.observation.observationId) < ($1.observation.createdAt, $1.observation.observationId) })
        where !seenObservations.contains(record.observation.observationId) && SyncRecord.observation(record).isLive
            && replica.unreadable["obs.\(record.observation.observationId)"] == nil {
            add(record.observation)
        }
        let observationsById = Dictionary(observations.map { ($0.observationId, $0) }, uniquingKeysWith: { a, _ in a })

        // Rooms: the first room always, then the synced order, then by creation.
        let localRooms = Dictionary(local.allRooms.map { ($0.roomId, $0) }, uniquingKeysWith: { a, _ in a })
        var roomsById: [String: Room] = [:]
        for record in replica.rooms where record.roomId == AppState.primaryRoomId || SyncRecord.room(record).isLive {
            let name = record.name.value
            if let name, AppState.normalizedRoomName(name) != name {
                result.heldBack.append("room.\(record.roomId)")
                if let kept = localRooms[record.roomId] { roomsById[record.roomId] = kept }
                continue
            }
            roomsById[record.roomId] = Room(roomId: record.roomId, name: name, createdAt: record.createdAt)
        }
        for room in local.allRooms where replica["room.\(room.roomId)"] == nil || replica.unreadable["room.\(room.roomId)"] != nil {
            roomsById[room.roomId] = room
        }
        if roomsById[AppState.primaryRoomId] == nil { roomsById[AppState.primaryRoomId] = localRooms[AppState.primaryRoomId] ?? Room(roomId: AppState.primaryRoomId) }
        let rooms = Array(Self.ordered(roomsById, first: AppState.primaryRoomId, order: replica.home.roomOrder.value,
                                       created: { $0.createdAt }).prefix(AppState.maxRooms))
        let roomIds = Set(rooms.map(\.roomId))

        // Cats: the same, with a room that is not shown meaning "keeps the user company".
        let localCats = Dictionary(local.allCats.map { ($0.catId, $0) }, uniquingKeysWith: { a, _ in a })
        var catsById: [String: Cat] = [:]
        for record in replica.cats where record.catId == AppState.primaryCatId || SyncRecord.cat(record).isLive {
            guard AppState.normalizedCatName(record.name.value) == record.name.value else {
                result.heldBack.append("cat.\(record.catId)")
                if let kept = localCats[record.catId] { catsById[record.catId] = kept }
                continue
            }
            catsById[record.catId] = Cat(catId: record.catId, name: record.name.value, roomId: record.roomId.value)
        }
        for cat in local.allCats where replica["cat.\(cat.catId)"] == nil || replica.unreadable["cat.\(cat.catId)"] != nil {
            catsById[cat.catId] = cat
        }
        if catsById[AppState.primaryCatId] == nil { catsById[AppState.primaryCatId] = localCats[AppState.primaryCatId] }
        var cats = Array(Self.ordered(catsById, first: AppState.primaryCatId, order: replica.home.catOrder.value,
                                      created: { _ in nil }).prefix(AppState.maxCats))
        for index in cats.indices where cats[index].roomId.map({ !roomIds.contains($0) }) ?? false { cats[index].roomId = nil }

        // Furniture.
        let localPieces = Dictionary(local.allFurniture.map { ($0.instanceId, $0) }, uniquingKeysWith: { a, _ in a })
        var placed: [String: PhotoFurniture] = [:], stored: [String: PhotoFurniture] = [:]
        func keepLocal(_ piece: PhotoFurniture, wasStored: Bool) {
            var kept = piece
            var seen = Set<String>()
            kept.sources = piece.sources.compactMap { source in
                guard let id = canonical[source.photoId], shownPhotos.contains(id), seen.insert(id).inserted else { return nil }
                let link = PhotoCarrierSource(photoId: id, observationId: source.observationId, objectIndex: source.objectIndex,
                                              origin: source.origin, relationToCat: source.relationToCat, addedAt: source.addedAt)
                return SyncProjection.linkIsValid(link, photoExists: shownPhotos.contains,
                                                              observation: { observationsById[$0] }) ? link : nil
            }
            kept.coverPhotoId = piece.coverPhotoId.flatMap { canonical[$0] }
            if kept != piece { kept.revision = LibraryStore.nextRevision(piece.revision) }
            if wasStored || !roomIds.contains(AppState.roomId(of: kept)) { stored[kept.instanceId] = kept } else { placed[kept.instanceId] = kept }
        }
        let storedLocally = Set(local.storage.map(\.instanceId))
        for record in replica.furniture where SyncRecord.furniture(record).isLive {
            let name = "furniture.\(record.instanceId)"
            guard replica.unreadable[name] == nil else { continue }
            let local = localPieces[record.instanceId]
            guard catalog.map({ $0.model(id: record.place.value.modelId) != nil }) ?? true else {
                result.heldBack.append(name)
                result.piecesFromNewerVersion.insert(record.instanceId)
                let (onIt, _) = Self.sources(of: record, aliases: aliases, canonical: canonical, shownPhotos: shownPhotos,
                                             observations: observationsById)
                result.photosOnNewerPieces.formUnion(onIt.map(\.photoId))
                if let local {
                    keepLocal(local, wasStored: storedLocally.contains(local.instanceId))
                    let (_, waiting) = Self.sources(of: record, aliases: aliases, canonical: canonical, shownPhotos: shownPhotos,
                                                    observations: observationsById)
                    if waiting > 0 { result.pendingLinks[record.instanceId] = waiting }
                }
                continue
            }
            let (sources, pending) = Self.sources(of: record, aliases: aliases, canonical: canonical, shownPhotos: shownPhotos,
                                                  observations: observationsById)
            if pending > 0 { result.pendingLinks[record.instanceId] = pending }
            let place = record.place.value
            var piece = PhotoFurniture(instanceId: record.instanceId, modelId: place.modelId, x: place.x, z: place.z,
                                       width: place.width, depth: place.depth, turn: place.turn, wall: place.wall,
                                       finish: place.finish, displayName: record.name.value, sources: sources,
                                       tags: record.tags.value, revision: 1, createdAt: record.createdAt,
                                       updatedAt: record.updatedAt, locked: record.locked.value,
                                       coverPhotoId: record.cover.value.flatMap { canonical[$0] ?? aliases.canonical($0) },
                                       roomId: place.roomId)
            if let local {
                piece.revision = local.revision
                if piece != local { piece.revision = LibraryStore.nextRevision(local.revision) }
            }
            if place.stored || !roomIds.contains(AppState.roomId(of: piece)) { stored[piece.instanceId] = piece } else { placed[piece.instanceId] = piece }
        }
        for piece in local.allFurniture {
            let name = "furniture.\(piece.instanceId)"
            if replica.unreadable[name] != nil { result.heldBack.append(name) }
            if replica[name] == nil || replica.unreadable[name] != nil {
                keepLocal(piece, wasStored: storedLocally.contains(piece.instanceId))
            }
        }
        let items = Self.keepingOrder(placed, local: local.items)
        let storage = Self.keepingOrder(stored, local: local.storage)

        var state = local
        state.schemaVersion = AppState.currentSchemaVersion
        state.photos = photos
        state.observations = observations
        state.items = items
        state.storage = storage
        state.catName = cats.first?.name ?? local.catName
        state.rooms = rooms == [Room(roomId: AppState.primaryRoomId)] ? [] : rooms
        if cats.isEmpty { cats = [Cat(catId: AppState.primaryCatId, name: state.catName)] }
        state.cats = cats == [Cat(catId: AppState.primaryCatId, name: state.catName)] ? [] : cats
        result.state = state
        result.heldBack = Array(Set(result.heldBack)).sorted()
        result.quarantined = Array(Set(result.quarantined)).sorted()
        return result
    }

    /// Projected photo for a record, or nil when its values fail this build's checks.
    static func photo(from record: PhotoSyncRecord, file: SyncFileInfo, local: PhotoRecord?,
                      originalFile: String, thumbnailFile: String) -> PhotoRecord? {
        guard record.note.value.utf16.count <= LibraryStore.maxNoteLength,
              record.exifDay.value.map(PhotoLibrary.isValidDay) ?? true else { return nil }
        let day: String?, source: CaptureDateSource
        switch record.date.value {
        case .user(let typed):
            guard PhotoLibrary.isValidDay(typed) else { return nil }
            (day, source) = (typed, .user)
        case .followFile:
            (day, source) = (record.exifDay.value, record.exifDay.value == nil ? .unknown : .exif)
        case .unknown:
            (day, source) = (nil, .unknown)
        }
        var photo = PhotoRecord(
            photoId: record.canonicalId, filename: record.filename.value, sha256: file.sha256, mimeType: file.mimeType,
            byteSize: file.byteSize, width: file.width, height: file.height, originalFile: originalFile,
            thumbnailFile: thumbnailFile, captureDate: day, captureDateSource: source, exifCaptureDate: record.exifDay.value,
            importedAt: record.importedAt, favorite: record.favorite.value, note: record.note.value,
            revision: local?.revision ?? 1, reducedFrom: file.reducedFrom, assetIdentifier: local?.assetIdentifier,
            cloudIdentifier: record.cloudIdentifier.value)
        if let local, photo != local { photo.revision = LibraryStore.nextRevision(local.revision) }
        return photo
    }

    /// The links to show, in order, and how many wait for a photo or an observation.
    static func sources(of record: FurnitureSyncRecord, aliases: SyncAliases, canonical: [String: String],
                        shownPhotos: Set<String>, observations: [String: PhotoObservation]) -> ([PhotoCarrierSource], Int) {
        // Links written under different ids of one photo count as one: the newest write wins.
        var winners: [String: SyncRegister<PhotoCarrierSource?>] = [:]
        for (key, register) in record.links {
            let id = canonical[key] ?? aliases.canonical(key) ?? key
            winners[id] = winners[id].map { $0.joined(register) } ?? register
        }
        var shown: [String: PhotoCarrierSource] = [:]
        var pending = 0
        for (id, register) in winners {
            guard let link = register.value else { continue }
            let source = PhotoCarrierSource(photoId: id, observationId: link.observationId, objectIndex: link.objectIndex,
                                            origin: link.origin, relationToCat: link.relationToCat, addedAt: link.addedAt)
            if SyncProjection.linkIsValid(source, photoExists: shownPhotos.contains, observation: { observations[$0] }) {
                shown[id] = source
            } else if !aliases.isDeleted(id), link.observationId.map(aliases.observationIsDeleted) != true {
                // Not here yet. A photo or observation deleted everywhere will not arrive.
                pending += 1
            }
        }
        var ordered: [PhotoCarrierSource] = []
        for key in record.order.value {
            let id = canonical[key] ?? aliases.canonical(key) ?? key
            if let source = shown.removeValue(forKey: id) { ordered.append(source) }
        }
        ordered += shown.values.sorted { ($0.addedAt ?? .distantPast, $0.photoId) < ($1.addedAt ?? .distantPast, $1.photoId) }
        return (ordered, pending)
    }

    static func ordered<T>(_ byId: [String: T], first: String, order: [String], created: (T) -> Date?) -> [T] {
        var rest = byId
        var out: [T] = []
        if let head = rest.removeValue(forKey: first) { out.append(head) }
        for id in order { if let next = rest.removeValue(forKey: id) { out.append(next) } }
        out += rest.sorted { (created($0.value) ?? .distantPast, $0.key) < (created($1.value) ?? .distantPast, $1.key) }.map(\.value)
        return out
    }

    static func keepingOrder(_ pieces: [String: PhotoFurniture], local: [PhotoFurniture]) -> [PhotoFurniture] {
        var rest = pieces
        var out = local.compactMap { rest.removeValue(forKey: $0.instanceId) }
        out += rest.values.sorted { ($0.createdAt ?? .distantPast, $0.instanceId) < ($1.createdAt ?? .distantPast, $1.instanceId) }
        return out
    }

    /// Ids become file names (thumbnails): letters, digits and hyphens only.
    static func safeId(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64
            && id.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 }
    }

    /// What a photo id may be: the web importer's rule (`WebBackupImport`). Never a path.
    static func validPhotoId(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 200
    }

    /// Only plain extensions become part of a file name.
    static func safeExtension(_ ext: String) -> Bool {
        !ext.isEmpty && ext.utf8.count <= 8 && ext.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) }
    }

    /// The load-time link rule of `LibraryStore.isConsistent`: the photo is here, and an
    /// observation it names is here, is about the same photo, has the same origin and the index.
    static func linkIsValid(_ source: PhotoCarrierSource, photoExists: (String) -> Bool,
                            observation: (String) -> PhotoObservation?) -> Bool {
        guard photoExists(source.photoId) else { return false }
        guard let observationId = source.observationId else { return source.objectIndex == nil && source.origin == .user }
        guard let found = observation(observationId), found.photoId == source.photoId, found.origin == source.origin,
              let index = source.objectIndex, found.objects.indices.contains(index) else { return false }
        return true
    }
}

/// Every id a photo has had, from all photo records (deleted ones too). Records the store
/// counts as one photo (`SyncPhotoGroups`) share their ids.
struct SyncAliases {
    /// Per id, every id of the same photo.
    private var idsOf: [String: Set<String>] = [:]
    /// Per id of a live photo, the id every device shows it under.
    private var liveCanonical: [String: String] = [:]
    private var deletedObservations = Set<String>()

    init(_ replica: SyncReplica, groups: SyncPhotoGroups? = nil) {
        let groups = groups ?? SyncPhotoGroups(replica)
        for record in replica.photos {
            for id in record.photoIds { idsOf[id, default: []].formUnion(record.photoIds) }
        }
        // Every live record's ids name a live photo; a group's ids, the one it is shown as.
        for record in replica.photos where SyncRecord.photo(record).isLive {
            for id in record.photoIds { liveCanonical[id] = record.canonicalId }
        }
        for group in groups.groups {
            let ids = Set(group.merged.photoIds)
            for id in ids {
                idsOf[id, default: []].formUnion(ids)
                liveCanonical[id] = group.merged.canonicalId
            }
        }
        for record in replica.observations where !SyncRecord.observation(record).isLive {
            deletedObservations.insert(record.observation.observationId)
        }
    }

    /// A photo the records know only as deleted.
    func isDeleted(_ id: String) -> Bool {
        idsOf[id] != nil && liveCanonical[id] == nil
    }

    func observationIsDeleted(_ id: String) -> Bool { deletedObservations.contains(id) }

    /// The id every device uses for this photo, if a live record knows `id`.
    func canonical(_ id: String) -> String? { liveCanonical[id] }

    /// `id` and every other id of the same photo.
    func all(_ id: String) -> [String] {
        Array((idsOf[id] ?? []).union([id])).sorted()
    }
}

/// Live photo records the library counts as one photo (round-12 audit CLOUDKIT-1). Records are
/// named by the source every copy was made from, but the store also counts equal stored bytes
/// as the same photo (`PhotoRecord.isSamePhoto`) and keeps each stored file once. Two records
/// list one copy when a device imports the app's own stored copy from another device
/// (「分享原文件」 hands it out byte for byte when the Photos original is gone or edited): the
/// device that made it says "made from O", the other "a source of its own". Records that share
/// a copy, directly or through others, are one photo here. Every device groups them the same
/// way and shows them as one, with the values of all of them joined (each a register, so the
/// newest write wins wherever it was made). Records still are what they were: each device
/// writes its edits into its own photo's record, and a deletion writes into all of them
/// (`SyncCapture.photos`).
struct SyncPhotoGroups {
    struct Group {
        /// Sorted by source hash.
        let members: [PhotoSyncRecord]
        /// What the members say together, to show. Never stored or sent.
        let merged: PhotoSyncRecord
        /// A member this build cannot read now (a newer version, values out of range, or held
        /// back by the projection), known here by its last readable version: the photo stays as
        /// this device has it, and one not here yet waits.
        let isHeld: Bool
        var names: [String] { members.map { SyncRecord.photoName($0.sourceHash) } }
    }

    private(set) var groups: [Group] = []
    private var bySource: [String: Int] = [:]
    private var byCopy: [String: Int] = [:]

    /// Live records group by the copies they share. A deleted record joins the group of a live
    /// one it shares a copy with when one deletion named both (`SyncTombstone.together`, joined
    /// over every deletion, on either record's tombstone): one record of the photo came back because an edit made
    /// elsewhere had not been seen (§4, "unseen write wins"), and the photo comes back whole, as
    /// one record would, with what the others held (a confirmed day, a favourite). A record
    /// deleted on its own, or in one batch with unrelated photos, does not join; nor does a
    /// deleted one connect two groups.
    init(_ replica: SyncReplica) {
        let all = replica.photos.sorted { $0.sourceHash < $1.sourceHash }
        let live = all.filter { SyncRecord.photo($0).isLive }
        var parent = Array(live.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        var holder: [String: Int] = [:]
        for (i, record) in live.enumerated() {
            for copy in record.copies {
                guard let j = holder[copy.sha256] else { holder[copy.sha256] = i; continue }
                let (a, b) = (root(i), root(j))
                if a != b { parent[max(a, b)] = min(a, b) }
            }
        }
        var slot: [Int: Int] = [:]
        var buckets: [[PhotoSyncRecord]] = []
        for i in live.indices {
            let r = root(i)
            if let k = slot[r] { buckets[k].append(live[i]) } else { slot[r] = buckets.count; buckets.append([live[i]]) }
        }
        var liveNames: [Set<String>] = [], named: [Set<String>] = []
        var liveByCopy: [String: Int] = [:]
        for (k, members) in buckets.enumerated() {
            liveNames.append(Set(members.map { SyncRecord.photoName($0.sourceHash) }))
            named.append(Set(members.flatMap { $0.tomb?.together ?? [] }))
            for member in members { for copy in member.copies where liveByCopy[copy.sha256] == nil { liveByCopy[copy.sha256] = k } }
        }
        for record in all where !SyncRecord.photo(record).isLive {
            let name = SyncRecord.photoName(record.sourceHash)
            let list = Set(record.tomb?.together ?? []).subtracting([name])
            // It shares a copy with the group, and either deletion names the other: its own
            // list names a live member, or a live member's list (the deletion it came back from)
            // names it. Either side is enough, since a build without lists rewrites one side.
            guard let k = record.copies.lazy.compactMap({ liveByCopy[$0.sha256] })
                .first(where: { !list.isDisjoint(with: liveNames[$0]) || named[$0].contains(name) })
            else { continue }
            buckets[k].append(record)
        }
        for bucket in buckets {
            let members = bucket.sorted { $0.sourceHash < $1.sourceHash }
            let index = groups.count
            let isHeld = members.contains { replica.unreadable[SyncRecord.photoName($0.sourceHash)] != nil }
            groups.append(Group(members: members, merged: Self.merged(members), isHeld: isHeld))
            for member in members {
                bySource[member.sourceHash] = index
                guard SyncRecord.photo(member).isLive else { continue }
                for copy in member.copies { byCopy[copy.sha256] = index }
            }
        }
    }

    /// The groups a photo of this library belongs to: its own record's, and the one holding
    /// its stored file (the same group unless its record is deleted or does not list the file).
    func indices(for photo: PhotoRecord) -> Set<Int> {
        Set([bySource[SyncFileInfo(photo).sourceHash], byCopy[photo.sha256]].compactMap { $0 })
    }

    /// The group a photo of this library is shown through: its own record's, else the one
    /// holding its stored file.
    func group(for photo: PhotoRecord) -> (index: Int, group: Group)? {
        guard let index = bySource[SyncFileInfo(photo).sourceHash] ?? byCopy[photo.sha256] else { return nil }
        return (index, groups[index])
    }

    /// The members' join, field by field as one record's versions join (`PhotoSyncRecord.joined`).
    /// A copy two records describe differently keeps the description that knows where it was
    /// made from (a device's guess that its file is a source of its own loses), then the smaller
    /// encoding, so every device picks the same.
    static func merged(_ members: [PhotoSyncRecord]) -> PhotoSyncRecord {
        guard members.count > 1 else { return members[0] }
        var joined = members.dropFirst().reduce(members[0]) { $0.joined($1) }
        var bySha: [String: SyncFileInfo] = [:]
        for copy in members.flatMap(\.copies) {
            guard let kept = bySha[copy.sha256] else { bySha[copy.sha256] = copy; continue }
            if (copy.reducedFrom != nil) != (kept.reducedFrom != nil) {
                if copy.reducedFrom != nil { bySha[copy.sha256] = copy }
            } else if SyncCoding.orderedBefore(copy, kept) {
                bySha[copy.sha256] = copy
            }
        }
        joined.copies = bySha.keys.sorted().map { bySha[$0]! }
        joined.tomb = nil
        // The file's own facts, its name and EXIF day, which no one edits, come from the record
        // its history names (the original's, not a share's "shared.jpg" or its stripped EXIF),
        // unless a device wrote one with sync on (a repair). Offers alone would let the busier
        // library's import name win.
        if let origin = joined.copiesBestFirst.lazy.compactMap({ copy in members.first { $0.sourceHash == copy.sourceHash } }).first {
            if SyncClock.isSeed(joined.filename.stamp), origin.filename.value != nil { joined.filename = origin.filename }
            if SyncClock.isSeed(joined.exifDay.stamp), origin.exifDay.value != nil { joined.exifDay = origin.exifDay }
        }
        return joined
    }
}

extension SyncReplica {
    /// This replica with `names` treated as records this build cannot read: what they describe
    /// stays as the device has it. Only for building a library; never stored.
    func holdingBack(_ names: Set<String>) -> SyncReplica {
        var copy = self
        copy.markUnreadable(names)
        return copy
    }
}
