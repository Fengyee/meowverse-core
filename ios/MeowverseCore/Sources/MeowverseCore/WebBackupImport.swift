import Foundation
import UniformTypeIdentifiers

/// Reads a backup written by the web app (`src/storage/archive.ts`, manifest version 6) and
/// carries over what the iOS app can represent.
///
/// Carried over: every original (byte-identical, SHA-256 checked against both the manifest
/// and the photo record), photo ids, filenames, capture day + its source, import time,
/// favourites, notes, the cat's name, grid-room furniture (ids, model, placement, finish,
/// name, tags, revision) and each furniture source (photo, origin, relation to the cat, and
/// the recognition record it points at).
///
/// Not carried over (reported as `BackupNote`s, never silently): classic-mode furniture,
/// evidence and proposals, imported GLB models and cat, analysis runs and consents,
/// observations no furniture refers to, per-photo annotations and review marks, the room
/// theme, and the web thumbnails/previews (thumbnails are rebuilt from the originals).
enum WebBackup {
    static let format = "meowverse-backup"
    static let supportedVersion = 6

    // MARK: Wire types (only the fields iOS reads; unknown keys are ignored)

    struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }

    struct Manifest: Decodable {
        let version: Int
        let createdAt: String
        let state: BackupArchive.FileEntry
        let media: [Media]
        let assets: [Asset]?
    }

    struct Media: Decodable {
        let path: String
        let byteSize: Int
        let sha256: String
        let blobKey: String
        let photoId: String
        let kind: String
    }

    struct Asset: Decodable { let path: String }

    struct State: Decodable {
        let schemaVersion: Int
        let revision: Int
        let photos: [Photo]
        let observations: [Observation]
        let gridRoom: GridRoom
        let photoDetails: [String: Detail]
        let photoAnnotations: [String: Skipped]
        let cat: Cat
        let furniture: [Skipped]
        let analysisRuns: [Run]
        let consents: [Skipped]
        let assetLibrary: AssetLibrary
        let catAppearance: Skipped?
        let settings: Settings
    }

    struct Photo: Decodable {
        let photoId: String
        let filename: String
        let sha256: String
        let byteSize: Int
        let originalBlobKey: String
        let captureDate: String?
        let captureDateSource: String
        let importedAt: String
        let favorite: Bool
        let revision: Int
    }

    struct Observation: Decodable {
        struct Object: Decodable {
            let kind: String
            let relationToCat: String
            let confidence: String
        }

        let observationId: String
        let photoId: String
        let runId: String
        let origin: String
        let objects: [Object]
    }

    struct GridRoom: Decodable { let items: [Item] }

    struct Item: Decodable {
        let instanceId: String
        let modelId: String
        let x: Int
        let z: Int
        let width: Int
        let depth: Int
        let turn: Int
        let finish: String
        let displayName: String
        let sources: [Source]
        let tags: [String]
        let revision: Int
    }

    struct Source: Decodable {
        let photoId: String
        let observationId: String?
        let objectIndex: Int?
        let origin: String
        let relationToCat: String
    }

    struct Detail: Decodable {
        let note: String
        let reviewedAt: String?
        let excludedTemplates: [String]
    }

    struct Cat: Decodable { let displayName: String }

    struct Run: Decodable {
        let runId: String
        let mode: String
        let createdAt: String
    }

    struct AssetLibrary: Decodable { let assets: [Skipped] }

    struct Settings: Decodable { let roomTheme: String }

    // MARK: Prepare

    static func prepare(_ reader: ZipReader, manifestData: Data, staging: Staging, catalog: FurnitureCatalog,
                        progress: @Sendable (BackupProgress) -> Void) throws -> PreparedLibrary {
        struct VersionProbe: Decodable { let version: Int }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: manifestData) else { throw BackupError.damaged("manifest") }
        guard probe.version <= supportedVersion else { throw BackupError.newerVersion }
        guard probe.version == supportedVersion else { throw BackupError.unsupportedVersion }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
              let createdAt = date(manifest.createdAt),
              manifest.state.path == BackupArchive.statePath, BackupArchive.isHash(manifest.state.sha256)
        else { throw BackupError.damaged("manifest") }

        // Exactly the files the manifest lists, like the web reader requires.
        let listed = [BackupArchive.manifestPath, BackupArchive.statePath] + manifest.media.map(\.path) + (manifest.assets ?? []).map(\.path)
        guard Set(listed).count == listed.count, listed.count == reader.entries.count,
              listed.allSatisfy({ reader.entry($0) != nil }) else { throw BackupError.damaged("entries") }

        let stateData = try BackupArchive.json(reader, BackupArchive.statePath)
        guard stateData.count == manifest.state.byteSize, PhotoIngest.sha256Hex(stateData) == manifest.state.sha256 else {
            throw BackupError.damaged("stateHash")
        }
        guard let web = try? JSONDecoder().decode(State.self, from: stateData), web.schemaVersion == supportedVersion,
              web.revision >= 0 else { throw BackupError.damaged("state") }

        // Photos: unique ids and hashes, each with exactly one original in the manifest.
        guard web.photos.count <= reader.entries.count,
              Set(web.photos.map(\.photoId)).count == web.photos.count,
              Set(web.photos.map(\.sha256)).count == web.photos.count else { throw BackupError.damaged("photos") }
        var originals: [String: Media] = [:]
        for media in manifest.media where media.kind == "original" {
            guard originals.updateValue(media, forKey: media.blobKey) == nil else { throw BackupError.damaged("media") }
        }
        guard originals.count == web.photos.count else { throw BackupError.damaged("media") }

        try staging.create()
        // Clamped before summing: the sizes are untrusted, and an overflowing sum would trap.
        let total = web.photos.reduce(0) { $0 + min(max(0, $1.byteSize), PhotoIngest.maxBytes) }
        var done = 0, unreadable = 0, datesFromFile = 0
        var photos: [PhotoRecord] = []
        progress(BackupProgress(completedBytes: 0, totalBytes: total))
        for photo in web.photos {
            try Task.checkCancellation()
            guard !photo.photoId.isEmpty, photo.photoId.utf8.count <= 200, BackupArchive.isHash(photo.sha256),
                  photo.byteSize > 0, photo.byteSize <= PhotoIngest.maxBytes, photo.revision >= 0,
                  let media = originals[photo.originalBlobKey], media.photoId == photo.photoId,
                  media.sha256 == photo.sha256, media.byteSize == photo.byteSize,
                  let entry = reader.entry(media.path), entry.uncompressedSize == photo.byteSize,
                  let importedAt = date(photo.importedAt),
                  let source = CaptureDateSource(rawValue: photo.captureDateSource)
            else { throw BackupError.damaged("photoRecord") }
            let original = try reader.extract(entry)
            guard original.count == photo.byteSize, PhotoIngest.sha256Hex(original) == photo.sha256 else {
                throw BackupError.damaged("originalHash")
            }
            done += photo.byteSize
            progress(BackupProgress(completedBytes: done, totalBytes: total))
            guard let draft = try? PhotoIngest.makeDraft(data: original, filename: nil, reduce: false) else {
                unreadable += 1
                continue
            }

            // Dates are never invented: the day shown is the web record's, except that
            // "from the photo's own data" must be what this device reads in the file.
            let fileDay = draft.captureDate
            var day: String?, daySource = CaptureDateSource.unknown
            switch source {
            case .user:
                guard let value = photo.captureDate, PhotoLibrary.isValidDay(value) else { throw BackupError.damaged("captureDate") }
                day = value
                daySource = .user
            case .exif:
                if fileDay != photo.captureDate { datesFromFile += 1 }
                day = fileDay
                daySource = fileDay == nil ? .unknown : .exif
            case .unknown:
                guard photo.captureDate == nil else { throw BackupError.damaged("captureDate") }
            }
            let note = web.photoDetails[photo.photoId]?.note ?? ""
            guard note.utf16.count <= LibraryStore.maxNoteLength else { throw BackupError.damaged("note") }

            let ext = UTType(mimeType: draft.mimeType)?.preferredFilenameExtension ?? "bin"
            let originalFile = "\(LibraryStore.originalsDir)/\(photo.sha256).\(ext)"
            // Web photo ids are opaque strings; the hash is always a safe file name.
            let thumbnailFile = "\(LibraryStore.thumbnailsDir)/\(photo.sha256).jpg"
            try staging.write(original, to: originalFile)
            try staging.write(draft.thumbnailJPEG, to: thumbnailFile)
            let filename = String(photo.filename.prefix(255))
            photos.append(PhotoRecord(
                photoId: photo.photoId, filename: filename.isEmpty ? nil : filename, sha256: photo.sha256,
                mimeType: draft.mimeType, byteSize: photo.byteSize, width: draft.width, height: draft.height,
                originalFile: originalFile, thumbnailFile: thumbnailFile,
                captureDate: day, captureDateSource: daySource, exifCaptureDate: fileDay,
                importedAt: importedAt, favorite: photo.favorite, note: note, revision: max(1, photo.revision)))
        }
        // Never drop a photo quietly: if one cannot be shown here, nothing is imported.
        guard unreadable == 0 else { throw BackupError.unreadablePhotos(unreadable) }

        let mapped = try mapRoom(web, photoIds: Set(photos.map(\.photoId)), catalog: catalog, fallbackDate: createdAt)
        var notes = mapped.notes
        var catName = AppState.defaultCatName
        let rawName = web.cat.displayName
        if let name = AppState.normalizedCatName(rawName) {
            catName = name
        } else if let shortened = AppState.normalizedCatName(String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(AppState.maxCatNameLength))) {
            catName = shortened
            notes.append(.catNameShortened)
        }
        if datesFromFile > 0 { notes.append(.datesFromFile(datesFromFile)) }
        if !photos.isEmpty { notes.append(.thumbnailsRebuilt(photos.count)) }

        let state = AppState(revision: web.revision, catName: catName, photos: photos,
                             observations: mapped.observations, items: mapped.items)
        guard LibraryStore.isConsistent(state) else { throw BackupError.damaged("stateLinks") }
        try staging.write(try LibraryStore.encodeState(state), to: BackupArchive.statePath, fullSync: true)
        staging.sync()

        let preview = BackupPreview(
            kind: .webBackup, createdAt: createdAt, appVersion: nil, formatVersion: manifest.version,
            schemaVersion: web.schemaVersion, photoCount: photos.count, furnitureCount: mapped.items.count,
            originalBytes: total, catName: catName, notes: notes)
        return PreparedLibrary(preview: preview, stagingURL: staging.url, state: state)
    }

    // MARK: Room mapping

    struct MappedRoom {
        var items: [PhotoFurniture] = []
        var observations: [PhotoObservation] = []
        var notes: [BackupNote] = []
    }

    static func mapRoom(_ web: State, photoIds: Set<String>, catalog: FurnitureCatalog, fallbackDate: Date) throws -> MappedRoom {
        var room = MappedRoom()
        guard Set(web.observations.map(\.observationId)).count == web.observations.count,
              Set(web.gridRoom.items.map(\.instanceId)).count == web.gridRoom.items.count,
              web.gridRoom.items.count <= 1000 else { throw BackupError.damaged("room") }
        let webObservations = Dictionary(uniqueKeysWithValues: web.observations.map { ($0.observationId, $0) })
        let runs = Dictionary(web.analysisRuns.map { ($0.runId, $0) }, uniquingKeysWith: { first, _ in first })
        /// web observation id -> (iOS observation, web object index -> iOS object index)
        var carried: [String: (observation: PhotoObservation, indexMap: [Int: Int])] = [:]
        var order: [String] = []
        var unknownModels: [String] = [], madeManual = 0

        func carry(_ observation: Observation, origin: SourceOrigin) -> (observation: PhotoObservation, indexMap: [Int: Int]) {
            if let done = carried[observation.observationId] { return done }
            var objects: [ObservedObject] = [], indexMap: [Int: Int] = [:]
            for (index, object) in observation.objects.enumerated() {
                // Only furniture kinds exist on iOS; bedding, rugs, windows etc. are left out
                // and the indexes of the kept objects are remapped.
                guard let kind = FurnitureCategory(rawValue: object.kind) else { continue }
                indexMap[index] = objects.count
                objects.append(ObservedObject(kind: kind, label: "web:\(object.kind)", confidence: confidence(object.confidence)))
            }
            let run = runs[observation.runId]
            let mode: AnalysisMode = switch run?.mode ?? "" {
            case "fixture": .fixture
            case "remote": .remote
            case "manual": .manual
            default: origin == .curatedFixture ? .fixture : origin == .model ? .remote : .manual
            }
            let created = run.flatMap { date($0.createdAt) } ?? fallbackDate
            let result = (PhotoObservation(
                observationId: observation.observationId, photoId: observation.photoId, origin: origin, mode: mode,
                analyzer: "web-\(mode.rawValue)", analyzerRevision: 0, objects: objects, createdAt: created), indexMap)
            carried[observation.observationId] = result
            order.append(observation.observationId)
            return result
        }

        for item in web.gridRoom.items {
            // The web contract has only the four legacy finishes; anything else is not a web backup.
            guard let finish = Finish(rawValue: item.finish), Finish.legacy.contains(finish), !item.sources.isEmpty, item.sources.count <= 1000,
                  Set(item.sources.map(\.photoId)).count == item.sources.count,
                  !item.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw BackupError.damaged("item") }
            guard catalog.model(id: item.modelId) != nil else {
                unknownModels.append(String(item.displayName.prefix(80)))
                continue
            }
            var sources: [PhotoCarrierSource] = []
            for source in item.sources {
                guard photoIds.contains(source.photoId), let origin = SourceOrigin(rawValue: source.origin),
                      let relation = Relation(rawValue: source.relationToCat) else { throw BackupError.damaged("source") }
                guard let observationId = source.observationId else {
                    // A manual link in the web contract: user origin, no object.
                    guard origin == .user, source.objectIndex == nil else { throw BackupError.damaged("source") }
                    sources.append(PhotoCarrierSource(photoId: source.photoId, observationId: nil, objectIndex: nil,
                                                      origin: .user, relationToCat: relation))
                    continue
                }
                if let observation = webObservations[observationId], observation.photoId == source.photoId,
                   observation.origin == source.origin, let webIndex = source.objectIndex,
                   observation.objects.indices.contains(webIndex),
                   let index = carry(observation, origin: origin).indexMap[webIndex] {
                    sources.append(PhotoCarrierSource(photoId: source.photoId, observationId: observationId,
                                                      objectIndex: index, origin: origin, relationToCat: relation))
                } else {
                    // The photo stays linked to this furniture; only the pointer to a
                    // recognition record that cannot be matched is dropped, and that is reported.
                    sources.append(PhotoCarrierSource(photoId: source.photoId, observationId: nil, objectIndex: nil,
                                                      origin: .user, relationToCat: relation))
                    madeManual += 1
                }
            }
            let furniture = PhotoFurniture(
                instanceId: item.instanceId, modelId: item.modelId, x: item.x, z: item.z, width: item.width,
                depth: item.depth, turn: item.turn, finish: finish, displayName: item.displayName, sources: sources,
                tags: item.tags, revision: max(1, item.revision))
            guard BackupArchive.isPlausible(furniture) else { throw BackupError.damaged("item") }
            room.items.append(furniture)
        }
        room.observations = order.compactMap { carried[$0]?.observation }

        if !web.furniture.isEmpty { room.notes.append(.classicFurniture(web.furniture.count)) }
        if !web.assetLibrary.assets.isEmpty { room.notes.append(.customModels(web.assetLibrary.assets.count)) }
        if web.catAppearance != nil { room.notes.append(.customCat) }
        let unused = web.observations.count - carried.count
        if !web.analysisRuns.isEmpty || !web.consents.isEmpty || unused > 0 {
            room.notes.append(.analysisRecords(runs: web.analysisRuns.count, consents: web.consents.count, observations: unused))
        }
        if !web.photoAnnotations.isEmpty { room.notes.append(.photoAnnotations(web.photoAnnotations.count)) }
        let marks = web.photoDetails.values.filter { $0.reviewedAt != nil || !$0.excludedTemplates.isEmpty }.count
        if marks > 0 { room.notes.append(.reviewMarks(marks)) }
        if web.settings.roomTheme != "warm" { room.notes.append(.roomTheme) }
        if !unknownModels.isEmpty { room.notes.append(.unknownModels(unknownModels)) }
        if madeManual > 0 { room.notes.append(.sourcesMadeManual(madeManual)) }
        return room
    }

    /// The web's self-reported high / medium / low, placed inside the bands the app words as
    /// "把握较大 / 有些把握 / 不太确定". Not a measured probability on either side.
    static func confidence(_ value: String) -> Double {
        switch value {
        case "high": 0.9
        case "medium": 0.45
        default: 0.15
        }
    }

    /// ISO-8601 with or without fractional seconds, rounded down to whole seconds (what the
    /// store's JSON keeps).
    static func date(_ text: String) -> Date? {
        guard text.utf8.count <= 40 else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: text) ?? plain.date(from: text) else { return nil }
        return Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}
