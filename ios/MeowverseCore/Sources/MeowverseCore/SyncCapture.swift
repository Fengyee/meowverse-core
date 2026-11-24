import Foundation

// Multi-device iCloud sync: from this device's edits to records. See docs/ICLOUD_SYNC.md.
//
// A field becomes an edit only when it differs between `base` (what sync last wrote to, or
// read from, the library) and `current`, and `current` is not simply what the records say
// already. The second test keeps a sync that crashed after writing the library but before
// remembering it from replaying the remote change as this device's own, newer edit.

enum SyncCapture {
    struct Context {
        var replica: SyncReplica
        let stamp: SyncStamp
        /// nil for edits; the clock for data that existed before sync was turned on.
        let seedClock: SyncClock?
        /// How far this library has come (its revision, at least 1): what decides between two
        /// non-default values from before sync, so that a copy of a library that went on being
        /// edited wins over the copy taken earlier, on whichever device each one is.
        let rank: Int
        var changed = Set<String>()

        var seeding: Bool { seedClock != nil }

        func seed(_ date: Date?) -> SyncStamp { seedClock.map { $0.seed(date) } ?? stamp }

        /// The stamp for a value offered without a time of its own (see `SyncClock.seed(rank:)`).
        func offer(isDefault: Bool) -> SyncStamp { SyncClock.seed(rank: isDefault ? 0 : rank) }

        /// Joins a value from before sync (or from an import) into a register: a user's edit
        /// made after sync was on always stays, a default value never replaces another one.
        func offer<V>(_ register: inout SyncRegister<V>, _ mine: V, isDefault: Bool) {
            register = register.joined(SyncRegister(mine, offer(isDefault: isDefault)))
        }

        mutating func store(_ record: SyncRecord) {
            if replica.merge(record) { changed.insert(record.name) }
        }

        /// A version this device made (an edit, an import, a link, a comeback): if it changes
        /// the record, the record's version vector says so, and a deletion elsewhere that never
        /// saw it does not hide it.
        mutating func write(_ record: SyncRecord) {
            guard record != replica[record.name] else { return }
            store(record.written(stamp))
        }

        /// A version of a record this device used without changing it (a photo it just linked
        /// to a piece): a deletion elsewhere that never saw the use does not hide the record.
        mutating func touch(_ name: String) {
            guard let record = replica[name], replica.unreadable[name] == nil else { return }
            store(record.written(stamp))
        }

        /// An observation a link this device just wrote stands on. Observations are never edited
        /// and carry no edit vector, so the use is recorded by re-stamping `created` (the join
        /// keeps the newer stamp): a deletion elsewhere that never saw the link then does not
        /// hide the observation, just as `touch` keeps the photo. Otherwise the photo would come
        /// back and the recognised link would be dropped for want of its observation.
        ///
        /// Like `touch`, this does not ask whether the record is still live: a sync held on the
        /// network may already have pulled the deletion into the replica before the user's undo
        /// is captured, and the photo comes back then too. What keeps it from reviving what was
        /// meant to stay deleted is that it runs only for a link written here, to an observation
        /// this library still holds (`current`; `undoUnlink` puts no link back without it).
        mutating func touchObservation(_ observationId: String, heldIn current: AppState) {
            let name = "obs.\(observationId)"
            guard current.observations.contains(where: { $0.observationId == observationId }),
                  replica.unreadable[name] == nil, case .observation(var record) = replica[name],
                  record.created < stamp else { return }
            record.created = stamp
            store(.observation(record))
        }

        /// A deletion of what this device holds of the record.
        func tomb(_ record: SyncRecord) -> SyncTombstone? {
            SyncTombstone.join(record.tomb, SyncTombstone(seen: record.version, at: stamp))
        }
    }

    /// Records this device's edits in `replica`. `base` nil means sync is being turned on:
    /// everything here is added to what the cloud has, and nothing is deleted.
    /// Returns the names of the records that changed.
    static func capture(base: AppState?, current: AppState, projected: AppState, catalog: FurnitureCatalog?,
                        into replica: inout SyncReplica, clock: inout SyncClock, now: Date) -> Set<String> {
        var context = Context(replica: replica, stamp: clock.tick(now: now), seedClock: base == nil ? clock : nil,
                              rank: max(current.revision, 0) + 1)
        photos(base: base, current: current, projected: projected, &context)
        observations(base: base, current: current, projected: projected, &context)
        furniture(base: base, current: current, projected: projected, catalog: catalog, &context)
        roomsAndCats(base: base, current: current, projected: projected, &context)
        replica = context.replica
        return context.changed
    }

    /// The triple rule: an edit is a change from `base` that the records do not already hold.
    static func edited<V: Equatable>(_ base: V?, _ current: V, _ projected: V?) -> Bool {
        base != current && projected != current
    }

    // MARK: Photos

    struct PhotoFields: Equatable {
        var filename: String?, exifDay: String?, date: SyncDateChoice, favorite: Bool, note: String, cloud: String?
        init(_ p: PhotoRecord) {
            filename = p.filename
            exifDay = p.exifCaptureDate
            date = SyncDateChoice(p)
            favorite = p.favorite
            note = p.note
            cloud = p.cloudIdentifier
        }
    }

    static func photos(base: AppState?, current: AppState, projected: AppState, _ c: inout Context) {
        func bySource(_ photos: [PhotoRecord]) -> [String: PhotoRecord] {
            Dictionary(photos.map { (SyncFileInfo($0).sourceHash, $0) }, uniquingKeysWith: { a, _ in a })
        }
        let before = bySource(base?.photos ?? []), shown = bySource(projected.photos)
        for photo in current.photos {
            let file = SyncFileInfo(photo), key = file.sourceHash, name = SyncRecord.photoName(key)
            guard c.replica.unreadable[name] == nil else { continue }
            let now = PhotoFields(photo)
            guard case .photo(var record) = c.replica[name] else {
                // New to the records: what the photo has from before sync, or from its import.
                // None of it is a user's edit made with sync on, so every field is offered: it
                // loses to any such edit, and a default never replaces another device's value.
                c.write(.photo(PhotoSyncRecord(
                    sourceHash: key, photoIds: [photo.photoId], importedAt: photo.importedAt, copies: [file],
                    filename: SyncRegister(now.filename, c.offer(isDefault: now.filename == nil)),
                    exifDay: SyncRegister(now.exifDay, c.offer(isDefault: now.exifDay == nil)),
                    date: SyncRegister(now.date, c.offer(isDefault: now.date == .followFile)),
                    favorite: SyncRegister(now.favorite, c.offer(isDefault: !now.favorite)),
                    note: SyncRegister(now.note, c.offer(isDefault: now.note.isEmpty)),
                    cloudIdentifier: SyncRegister(now.cloud, c.offer(isDefault: now.cloud == nil)), tomb: nil)))
                continue
            }
            if !record.photoIds.contains(photo.photoId) { record.photoIds = (record.photoIds + [photo.photoId]).sorted() }
            record.importedAt = min(record.importedAt, photo.importedAt)
            record.addCopy(file)
            let s = c.stamp
            if let old = before[key] {
                let was = PhotoFields(old), shownNow = shown[key].map(PhotoFields.init)
                if edited(was.filename, now.filename, shownNow?.filename) { record.filename = SyncRegister(now.filename, s) }
                if edited(was.exifDay, now.exifDay, shownNow?.exifDay) { record.exifDay = SyncRegister(now.exifDay, s) }
                if edited(was.date, now.date, shownNow?.date) { record.date = SyncRegister(now.date, s) }
                if edited(was.favorite, now.favorite, shownNow?.favorite) { record.favorite = SyncRegister(now.favorite, s) }
                if edited(was.note, now.note, shownNow?.note) { record.note = SyncRegister(now.note, s) }
                if edited(was.cloud, now.cloud, shownNow?.cloud) { record.cloudIdentifier = SyncRegister(now.cloud, s) }
            } else if !SyncRecord.photo(record).isLive {
                // Imported again after it was deleted everywhere, or still here when sync is
                // turned on after another device deleted it: it is back, as this device has it.
                record.filename = SyncRegister(now.filename, s)
                record.exifDay = SyncRegister(now.exifDay, s)
                record.date = SyncRegister(now.date, s)
                record.favorite = SyncRegister(now.favorite, s)
                record.note = SyncRegister(now.note, s)
                record.cloudIdentifier = SyncRegister(now.cloud, s)
            } else {
                // The same photo is already known (another device imported it, or sync is being
                // turned on with a copy of the same library). What this device has is from
                // before sync or from a fresh import, never an edit made with sync on: it is
                // offered, so a value a user chose with sync on stays (even a default one: a
                // favourite taken off, a day cleared), and a default never replaces a value.
                c.offer(&record.filename, now.filename, isDefault: now.filename == nil)
                c.offer(&record.exifDay, now.exifDay, isDefault: now.exifDay == nil)
                c.offer(&record.cloudIdentifier, now.cloud, isDefault: now.cloud == nil)
                c.offer(&record.favorite, now.favorite, isDefault: !now.favorite)
                c.offer(&record.date, now.date, isDefault: now.date == .followFile)
                record.note = Self.firstSyncNote(record.note, mine: now.note, c)
            }
            c.write(.photo(record))
        }
        guard !c.seeding else { return }
        let still = bySource(current.photos)
        // A photo shown here through several records of one stored copy (`SyncPhotoGroups`) is
        // deleted in all of them, or another one would bring it back. A record that another
        // photo still here belongs to is left alone: that photo was not deleted.
        let groups = SyncPhotoGroups(c.replica)
        let kept = current.photos.reduce(into: Set<Int>()) { $0.formUnion(groups.indices(for: $1)) }
        for (key, old) in before where still[key] == nil && shown[key] != nil {
            var names = [SyncRecord.photoName(key)]
            if let found = groups.group(for: old), !kept.contains(found.index) { names += found.group.names }
            // A record this build cannot read now is not written: only its last readable
            // version is here, and this device never sends that record.
            let deleting: [PhotoSyncRecord] = Set(names).sorted().compactMap { name in
                guard c.replica.unreadable[name] == nil, case .photo(let record) = c.replica[name],
                      SyncRecord.photo(record).isLive else { return nil }
                return record
            }
            // Deleted together, each names the others: if one comes back, they all do. A record
            // held back here is named too: it is part of the photo, and if it stays live
            // (written by a newer build) the photo stays whole with it.
            let listed = Set(names).filter { name in
                c.replica.unreadable[name] != nil || deleting.contains { SyncRecord.photoName($0.sourceHash) == name }
            }
            let together = listed.count > 1 ? listed.sorted() : nil
            for var record in deleting {
                var tomb = SyncTombstone(seen: record.version, at: c.stamp, together: together)
                tomb = SyncTombstone.join(record.tomb, tomb) ?? tomb
                record.tomb = tomb
                c.store(.photo(record))
            }
        }
    }

    /// A note from before sync meeting the records' note (docs/ICLOUD_SYNC.md §7). Two different
    /// notes are both kept, as "theirs\n\nmine", also next to a note written with sync on (owner
    /// 2026-11-18), unless together they pass the limit. But a note a user emptied or shortened
    /// with sync on stays as the user left it: the older text does not come back.
    static func firstSyncNote(_ theirs: SyncRegister<String>, mine: String, _ c: Context) -> SyncRegister<String> {
        guard !mine.isEmpty, theirs.value != mine, !theirs.value.contains(mine) else { return theirs }
        let edited = !SyncClock.isSeed(theirs.stamp)
        if edited, theirs.value.isEmpty || mine.contains(theirs.value) { return theirs }
        let both = theirs.value.isEmpty || mine.contains(theirs.value) ? mine : "\(theirs.value)\n\n\(mine)"
        guard both.utf16.count <= LibraryStore.maxNoteLength else { return theirs }
        // Next to an edit, the merge is a new edit; between two notes from before sync it stays
        // an offer (above both), so an edit made meanwhile elsewhere still wins over it.
        return SyncRegister(both, edited ? c.stamp : SyncClock.seed(rank: min(max(theirs.stamp.counter, c.rank), SyncStamp.maxCounter - 1) + 1))
    }

    // MARK: Observations

    static func observations(base: AppState?, current: AppState, projected: AppState, _ c: inout Context) {
        let before = Set((base?.observations ?? []).map(\.observationId))
        for o in current.observations {
            let name = "obs.\(o.observationId)"
            guard c.replica.unreadable[name] == nil else { continue }
            if case .observation(let record) = c.replica[name] {
                // Kept by a first sync while the cloud had deleted it: it comes back with its photo.
                guard c.seeding, !SyncRecord.observation(record).isLive else { continue }
                c.store(.observation(ObservationSyncRecord(observation: o, created: c.stamp, tomb: nil)))
                continue
            }
            c.store(.observation(ObservationSyncRecord(observation: o, created: c.seeding ? c.seed(o.createdAt) : c.stamp, tomb: nil)))
        }
        guard !c.seeding else { return }
        let still = Set(current.observations.map(\.observationId)), shown = Set(projected.observations.map(\.observationId))
        for id in before where !still.contains(id) && shown.contains(id) {
            guard case .observation(var record) = c.replica["obs.\(id)"], SyncRecord.observation(record).isLive else { continue }
            record.tomb = c.tomb(.observation(record))
            c.store(.observation(record))
        }
    }

    // MARK: Furniture

    static func furniture(base: AppState?, current: AppState, projected: AppState, catalog: FurnitureCatalog?,
                          _ c: inout Context) {
        func index(_ state: AppState?) -> [String: (piece: PhotoFurniture, stored: Bool)] {
            guard let state else { return [:] }
            var out: [String: (PhotoFurniture, Bool)] = [:]
            for piece in state.items { out[piece.instanceId] = (piece, false) }
            for piece in state.storage { out[piece.instanceId] = (piece, true) }
            return out
        }
        let before = index(base), shown = index(projected), now = index(current)
        let aliases = SyncAliases(c.replica)
        for (id, entry) in now {
            let name = "furniture.\(id)"
            guard c.replica.unreadable[name] == nil else { continue }
            let piece = entry.piece
            let place = SyncPlace(piece, stored: entry.stored)
            guard case .furniture(var record) = c.replica[name] else {
                let s = c.seeding ? c.seed(piece.updatedAt ?? piece.createdAt) : c.stamp
                var links: [String: SyncRegister<PhotoCarrierSource?>] = [:]
                for source in piece.sources { links[source.photoId] = SyncRegister(source, s) }
                c.write(.furniture(FurnitureSyncRecord(
                    instanceId: id, place: SyncRegister(place, s), name: SyncRegister(piece.displayName, s),
                    tags: SyncRegister(piece.tags, s), locked: SyncRegister(piece.locked, s),
                    cover: SyncRegister(piece.coverPhotoId, s), order: SyncRegister(piece.sources.map(\.photoId), s),
                    links: links, createdAt: piece.createdAt, updatedAt: piece.updatedAt, tomb: nil)))
                continue
            }
            // A model this build doesn't have: what stands here is the piece as it was before
            // (`SyncProjection` holds the record back), so its place, which carries the model,
            // is never sent. The piece's other fields still are.
            let holdsPlace = catalog.map { $0.model(id: record.place.value.modelId) == nil } ?? false
            if c.seeding {
                // The same piece on both sides (a library restored from one backup): the version
                // that changed last wins, field by field, links joined. A piece the cloud had
                // deleted but this device still has comes back.
                let s = SyncRecord.furniture(record).isLive ? c.seed(piece.updatedAt ?? piece.createdAt) : c.stamp
                var mine = record
                if !holdsPlace { mine.place = SyncRegister(place, s) }
                mine.name = SyncRegister(piece.displayName, s)
                mine.tags = SyncRegister(piece.tags, s)
                mine.locked = SyncRegister(piece.locked, s)
                mine.cover = SyncRegister(piece.coverPhotoId, s)
                mine.order = SyncRegister(piece.sources.map(\.photoId), s)
                mine.links = [:]
                for source in piece.sources { mine.links[source.photoId] = SyncRegister(source, s) }
                mine.tomb = nil
                record = record.joined(mine)
                record.createdAt = minDate(record.createdAt, piece.createdAt)
                record.updatedAt = maxDate(record.updatedAt, piece.updatedAt)
                c.write(.furniture(record))
                continue
            }
            // A piece new here but already in the records can only be a replay: compare with them.
            let was = before[id] ?? shown[id] ?? entry
            let seen = shown[id]
            let s = c.stamp
            if !holdsPlace,
               edited(SyncPlace(was.piece, stored: was.stored), place, seen.map { SyncPlace($0.piece, stored: $0.stored) }) {
                record.place = SyncRegister(place, s)
            }
            if edited(was.piece.displayName, piece.displayName, seen?.piece.displayName) { record.name = SyncRegister(piece.displayName, s) }
            if edited(was.piece.tags, piece.tags, seen?.piece.tags) { record.tags = SyncRegister(piece.tags, s) }
            if edited(was.piece.locked, piece.locked, seen?.piece.locked) { record.locked = SyncRegister(piece.locked, s) }
            if edited(was.piece.coverPhotoId, piece.coverPhotoId, seen?.piece.coverPhotoId) { record.cover = SyncRegister(piece.coverPhotoId, s) }
            let order = piece.sources.map(\.photoId)
            if edited(was.piece.sources.map(\.photoId), order, seen?.piece.sources.map(\.photoId)) { record.order = SyncRegister(order, s) }
            let oldLinks = Dictionary(was.piece.sources.map { ($0.photoId, $0) }, uniquingKeysWith: { a, _ in a })
            let newLinks = Dictionary(piece.sources.map { ($0.photoId, $0) }, uniquingKeysWith: { a, _ in a })
            let shownLinks = Dictionary((seen?.piece.sources ?? []).map { ($0.photoId, $0) }, uniquingKeysWith: { a, _ in a })
            for photoId in Set(oldLinks.keys).union(newLinks.keys) {
                let old = oldLinks[photoId], new = newLinks[photoId]
                guard old != new, shownLinks[photoId] != new || seen == nil else { continue }
                if let new {
                    record.links[photoId] = SyncRegister(new, s)
                    // The photo was in use here: a deletion that never saw the link keeps it.
                    if let photo = current.photos.first(where: { $0.photoId == photoId }) {
                        c.touch(SyncRecord.photoName(SyncFileInfo(photo).sourceHash))
                    }
                    // So was the observation a recognised link names (an undone take-off).
                    if let observationId = new.observationId { c.touchObservation(observationId, heldIn: current) }
                } else {
                    // Off the piece under every id the photo has had.
                    for key in aliases.all(photoId) where record.links[key] != nil || key == photoId {
                        record.links[key] = SyncRegister(nil, s)
                    }
                }
            }
            record.createdAt = minDate(record.createdAt, piece.createdAt)
            record.updatedAt = maxDate(record.updatedAt, piece.updatedAt)
            c.write(.furniture(record))
        }
        guard !c.seeding else { return }
        for (id, _) in before where now[id] == nil && shown[id] != nil {
            guard case .furniture(var record) = c.replica["furniture.\(id)"], SyncRecord.furniture(record).isLive else { continue }
            record.tomb = c.tomb(.furniture(record))
            c.store(.furniture(record))
        }
    }

    // MARK: Rooms, cats, order

    static func roomsAndCats(base: AppState?, current: AppState, projected: AppState, _ c: inout Context) {
        let beforeRooms = Dictionary((base?.allRooms ?? []).map { ($0.roomId, $0) }, uniquingKeysWith: { a, _ in a })
        let shownRooms = Dictionary(projected.allRooms.map { ($0.roomId, $0) }, uniquingKeysWith: { a, _ in a })
        // Names and orders have no time of their own: from before sync they are offered (a
        // name beats no name or the default cat name, then the library with more saves wins,
        // then the name's bytes), never ordered by device id.
        for room in current.allRooms {
            let name = "room.\(room.roomId)"
            guard c.replica.unreadable[name] == nil else { continue }
            let s = c.seeding ? c.offer(isDefault: room.name == nil) : c.stamp
            guard case .room(var record) = c.replica[name] else {
                c.write(.room(RoomSyncRecord(roomId: room.roomId, name: SyncRegister(room.name, s), createdAt: room.createdAt, tomb: nil)))
                continue
            }
            if c.seeding, !SyncRecord.room(record).isLive {
                // Still here when sync is turned on after another device deleted it: back, as
                // this device has it (a first sync never deletes).
                record.name = SyncRegister(room.name, c.stamp)
            } else if c.seeding {
                record.name = record.name.joined(SyncRegister(room.name, s))
            } else if edited(beforeRooms[room.roomId]?.name ?? shownRooms[room.roomId]?.name, room.name, shownRooms[room.roomId]?.name) {
                record.name = SyncRegister(room.name, s)
            }
            record.createdAt = minDate(record.createdAt, room.createdAt)
            c.write(.room(record))
        }
        let beforeCats = Dictionary((base?.allCats ?? []).map { ($0.catId, $0) }, uniquingKeysWith: { a, _ in a })
        let shownCats = Dictionary(projected.allCats.map { ($0.catId, $0) }, uniquingKeysWith: { a, _ in a })
        for cat in current.allCats {
            let name = "cat.\(cat.catId)"
            guard c.replica.unreadable[name] == nil else { continue }
            let named = c.seeding ? c.offer(isDefault: cat.name == AppState.defaultCatName) : c.stamp
            let placed = c.seeding ? c.offer(isDefault: cat.roomId == nil) : c.stamp
            guard case .cat(var record) = c.replica[name] else {
                c.write(.cat(CatSyncRecord(catId: cat.catId, name: SyncRegister(cat.name, named), roomId: SyncRegister(cat.roomId, placed), tomb: nil)))
                continue
            }
            if c.seeding, !SyncRecord.cat(record).isLive {
                record.name = SyncRegister(cat.name, c.stamp)
                record.roomId = SyncRegister(cat.roomId, c.stamp)
            } else if c.seeding {
                record.name = record.name.joined(SyncRegister(cat.name, named))
                record.roomId = record.roomId.joined(SyncRegister(cat.roomId, placed))
            } else {
                let was = beforeCats[cat.catId] ?? shownCats[cat.catId], seen = shownCats[cat.catId]
                if edited(was?.name, cat.name, seen?.name) { record.name = SyncRegister(cat.name, c.stamp) }
                if edited(was?.roomId, cat.roomId, seen?.roomId) { record.roomId = SyncRegister(cat.roomId, c.stamp) }
            }
            c.write(.cat(record))
        }

        var home = c.replica.home
        let roomOrder = current.allRooms.dropFirst().map(\.roomId), catOrder = current.allCats.dropFirst().map(\.catId)
        if c.seeding {
            c.offer(&home.roomOrder, roomOrder, isDefault: roomOrder.isEmpty)
            c.offer(&home.catOrder, catOrder, isDefault: catOrder.isEmpty)
        } else {
            if edited(base?.allRooms.dropFirst().map(\.roomId), roomOrder, projected.allRooms.dropFirst().map(\.roomId)) {
                home.roomOrder = SyncRegister(roomOrder, c.stamp)
            }
            if edited(base?.allCats.dropFirst().map(\.catId), catOrder, projected.allCats.dropFirst().map(\.catId)) {
                home.catOrder = SyncRegister(catOrder, c.stamp)
            }
        }
        if c.replica["home"] == nil || home != c.replica.home { c.store(.home(home)) }

        guard let base, !c.seeding else { return }
        let roomsNow = Set(current.allRooms.map(\.roomId)), catsNow = Set(current.allCats.map(\.catId))
        for room in base.allRooms where room.roomId != AppState.primaryRoomId && !roomsNow.contains(room.roomId) && shownRooms[room.roomId] != nil {
            guard case .room(var record) = c.replica["room.\(room.roomId)"], SyncRecord.room(record).isLive else { continue }
            record.tomb = c.tomb(.room(record))
            c.store(.room(record))
        }
        for cat in base.allCats where cat.catId != AppState.primaryCatId && !catsNow.contains(cat.catId) && shownCats[cat.catId] != nil {
            guard case .cat(var record) = c.replica["cat.\(cat.catId)"], SyncRecord.cat(record).isLive else { continue }
            record.tomb = c.tomb(.cat(record))
            c.store(.cat(record))
        }
    }
}
