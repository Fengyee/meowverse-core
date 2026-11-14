import Foundation
import Synchronization
import Testing
@testable import MeowverseCore

/// Automatic backup into a destination folder (iCloud Drive in the app, a plain folder here):
/// when to write, how files are named, what is pruned, which backup is offered for restore.
struct CloudBackupTests {
    let fm = FileManager.default
    let catalog: FurnitureCatalog
    let chairAt44 = Placement(modelId: "kenney-chair", x: 4, z: 4, width: 2, depth: 2)
    let stoolAt00 = Placement(modelId: "kenney-stoolBar", x: 0, z: 0, width: 1, depth: 1)
    let device = "0123456789ab"
    let otherDevice = "ba9876543210"
    let day: TimeInterval = 24 * 60 * 60
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        catalog = try TestSupport.catalog()
    }

    // MARK: Helpers

    private func openStore() async throws -> LibraryStore {
        let store = LibraryStore(root: TestSupport.tempDir().appendingPathComponent("Library", isDirectory: true), catalog: catalog)
        _ = try await store.load()
        return store
    }

    private func seededStore() async throws -> LibraryStore {
        let store = try await openStore()
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 1), placement: chairAt44, displayName: "窗边的椅子", decision: .manual)
        try await store.setCatName("团子")
        return store
    }

    private func context(keep: Int = 3) -> CloudBackupEngine.Context {
        CloudBackupEngine.Context(deviceID: device, deviceKind: "iPhone", appVersion: "9.9",
                                  workDirectory: TestSupport.tempDir(), catalog: catalog, keepCount: keep)
    }

    private func settings(enabled: Bool = true) -> CloudBackupSettings {
        var settings = CloudBackupSettings()
        settings.enabled = enabled
        return settings
    }

    /// Runs one trigger and folds the outcome into the settings the way the app does.
    @discardableResult
    private func run(_ store: LibraryStore, _ destination: any BackupDestination, _ settings: inout CloudBackupSettings,
                     trigger: CloudBackupPolicy.Trigger, now: Date, keep: Int = 3) async throws -> CloudBackupEngine.Outcome {
        let outcome = try await CloudBackupEngine.backUpIfNeeded(
            store: store, destination: destination, settings: settings, trigger: trigger, context: context(keep: keep), now: now)
        if case .completed(let record) = outcome { settings.lastSuccess = record }
        return outcome
    }

    private func contents(_ folder: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
            result[name] = TestSupport.bytes(folder.appendingPathComponent(name))
        }
        return result
    }

    private func archives(_ folder: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".zip") }.sorted()
    }

    private func entry(_ id: String, at date: Date, revision: Int = 1, _ condition: CloudBackupEntry.Condition = .verified,
                       upload: CloudUploadState = .notApplicable) -> CloudBackupEntry {
        let name = CloudBackupName(deviceID: id, createdAt: date, revision: revision)!
        return CloudBackupEntry(name: name, info: nil, byteSize: 100, isDownloaded: true, upload: upload,
                                condition: condition, isFromThisDevice: id == device)
    }

    // MARK: Names

    @Test func fileNamesCarryDeviceIdDateAndRevisionOnly() throws {
        let name = try #require(CloudBackupName(deviceID: device, createdAt: t0, revision: 42))
        #expect(name.archiveName == "Meowverse-backup-0123456789ab-20270115T080000Z-r42.zip")
        #expect(name.infoName == "Meowverse-backup-0123456789ab-20270115T080000Z-r42.json")
        #expect(CloudBackupName(archiveName: name.archiveName) == name)
        #expect(CloudBackupName(infoName: name.infoName) == name)
        // Nothing the user typed (the cat's name, the device's name) can get into a file name.
        #expect(name.archiveName.unicodeScalars.allSatisfy { $0.isASCII })
        let fresh = CloudBackupName.newDeviceID()
        #expect(fresh.count == 12 && fresh.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(CloudBackupName.newDeviceID() != fresh)
    }

    @Test func foreignFileNamesAreIgnored() {
        for bad in ["Meowverse-备份-2026-11-11.zip", "Meowverse-backup-XYZ-20270115T080000Z-r1.zip", "../x.zip",
                    "Meowverse-backup-0123456789ab-20270115T080000Z-r-1.zip", "Meowverse-backup-0123456789ab-20271315T080000Z-r1.zip",
                    "Meowverse-backup-0123456789ab-20270115T080000Z-r1.zip.icloud", ""] {
            #expect(CloudBackupName(archiveName: bad) == nil, "\(bad)")
        }
        #expect(CloudBackupName(deviceID: "not hex", createdAt: t0, revision: 1) == nil)
    }

    // MARK: When to back up

    @Test func policyDecidesWhenToWrite() {
        let last = CloudBackupRecord(archiveName: "a.zip", fingerprint: "same", revision: 3, date: t0, photoCount: 1, furnitureCount: 1, byteSize: 10)
        func decide(enabled: Bool = true, _ trigger: CloudBackupPolicy.Trigger, empty: Bool = false, fingerprint: String = "new",
                    last: CloudBackupRecord? = last, present: Bool = true, failure: Date? = nil, after: TimeInterval) -> CloudBackupPolicy.Decision {
            CloudBackupPolicy.decide(enabled: enabled, trigger: trigger, libraryIsEmpty: empty, fingerprint: fingerprint,
                                     lastSuccess: last, lastSuccessStillPresent: present, lastFailure: failure, now: t0 + after)
        }
        #expect(decide(enabled: false, .manual, after: 2 * day) == .skip(.disabled))
        #expect(decide(.manual, empty: true, last: nil, after: 0) == .skip(.emptyLibrary))
        #expect(decide(.automatic, last: nil, after: 0) == .backUp)
        // Nothing changed: no rewrite, however long ago and whoever asks.
        #expect(decide(.automatic, fingerprint: "same", after: 30 * day) == .skip(.unchanged))
        #expect(decide(.manual, fingerprint: "same", after: 30 * day) == .skip(.unchanged))
        // ...unless the file it refers to is gone from the destination.
        #expect(decide(.automatic, fingerprint: "same", present: false, after: 60) == .backUp)
        // Changed: automatically at most once a day, at once when asked.
        #expect(decide(.automatic, after: day - 1) == .skip(.tooSoon(until: t0 + day)))
        #expect(decide(.automatic, after: day) == .backUp)
        #expect(decide(.manual, after: 60) == .backUp)
        // A clock that went backwards does not block backups for ever.
        #expect(decide(.automatic, after: -5 * day) == .backUp)
        // A failed attempt is not repeated on every app switch.
        #expect(decide(.automatic, failure: t0 + 2 * day, after: 2 * day + 600)
                == .skip(.tooSoon(until: t0 + 2 * day + CloudBackupPolicy.retryInterval)))
        #expect(decide(.manual, failure: t0 + 2 * day, after: 2 * day + 600) == .backUp)
    }

    @Test func firstBackupWritesAVerifiedArchiveAndItsInfo() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        let destination = FolderBackupDestination(folder: folder)
        var settings = settings()
        let outcome = try await run(store, destination, &settings, trigger: .automatic, now: t0)
        guard case .completed(let record) = outcome else { Issue.record("expected a backup, got \(outcome)"); return }
        let state = await store.snapshot()
        #expect(record.revision == state.revision && record.photoCount == 1 && record.furnitureCount == 1 && record.date == t0)
        #expect(record.fingerprint == (try await store.backupFingerprint()))
        let name = try #require(CloudBackupName(archiveName: record.archiveName))
        #expect(name.deviceID == device && name.createdAt == t0 && name.revision == state.revision)
        #expect(Set(contents(folder).keys) == [name.archiveName, name.infoName])
        #expect(!record.archiveName.contains("团子"))

        let listing = try CloudBackupCatalog.load(from: destination, deviceID: device)
        #expect(listing.entries.count == 1)
        let entry = try #require(listing.entries.first)
        #expect(entry.condition == .verified && entry.isFromThisDevice && entry.byteSize == record.byteSize)
        #expect(entry.info?.photoCount == 1 && entry.info?.furnitureCount == 1 && entry.info?.deviceKind == "iPhone")
        #expect(entry.info?.sha256 == LibraryStore.hashFile(folder.appendingPathComponent(name.archiveName)))
    }

    @Test func disabledOrEmptyLibraryWritesNothing() async throws {
        let folder = TestSupport.tempDir()
        let destination = FolderBackupDestination(folder: folder)
        var off = settings(enabled: false)
        #expect(try await run(try await seededStore(), destination, &off, trigger: .manual, now: t0) == .skipped(.disabled))
        var on = settings()
        #expect(try await run(try await openStore(), destination, &on, trigger: .manual, now: t0) == .skipped(.emptyLibrary))
        #expect(contents(folder).isEmpty)
    }

    enum HomeChange: CaseIterable {
        case nameFirstRoom, addRoom, nameFirstCat, addCat, assignCat
    }

    @Test(arguments: HomeChange.allCases)
    func backsUpAnEditedHomeWithoutPhotosOrFurniture(_ change: HomeChange) async throws {
        let source = try await openStore()
        switch change {
        case .nameFirstRoom: _ = try await source.renameRoom(roomId: AppState.primaryRoomId, name: "书房")
        case .addRoom: _ = try await source.addRoom()
        case .nameFirstCat: _ = try await source.setCatName("团子")
        case .addCat: _ = try await source.addCat(name: "糯米")
        case .assignCat: _ = try await source.setCatRoom(catId: AppState.primaryCatId, roomId: AppState.primaryRoomId)
        }
        let destination = FolderBackupDestination(folder: TestSupport.tempDir())
        var on = settings()
        let outcome = try await run(source, destination, &on, trigger: .automatic, now: t0)
        guard case .completed(let record) = outcome else {
            Issue.record("Expected a backup of the edited home, got \(outcome)")
            return
        }
        let file = try await destination.download(record.archiveName) { _ in }
        let target = try await openStore()
        let prepared = try BackupArchive.prepare(file: file, stagingURL: target.makeStagingURL(), catalog: catalog)
        let restored = try await target.replaceLibrary(with: prepared)
        let expected = await source.snapshot()
        #expect(restored.allRooms == expected.allRooms)
        #expect(restored.allCats == expected.allCats)
    }

    @Test func unchangedLibraryIsNotWrittenAgain() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        let destination = FolderBackupDestination(folder: folder)
        var settings = settings()
        try await run(store, destination, &settings, trigger: .automatic, now: t0)
        let before = contents(folder)

        #expect(try await run(store, destination, &settings, trigger: .automatic, now: t0 + 3 * day) == .skipped(.unchanged))
        #expect(try await run(store, destination, &settings, trigger: .manual, now: t0 + 3 * day) == .skipped(.unchanged))
        // Reopening the same library is still "unchanged".
        #expect(contents(folder) == before)

        // A change within the day waits; after a day it is written as a second file.
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 2), placement: stoolAt00, displayName: "小凳子", decision: .manual)
        #expect(try await run(store, destination, &settings, trigger: .automatic, now: t0 + 3600) == .skipped(.tooSoon(until: t0 + day)))
        #expect(contents(folder) == before)
        guard case .completed = try await run(store, destination, &settings, trigger: .automatic, now: t0 + day) else {
            Issue.record("expected the changed library to be backed up"); return
        }
        #expect(archives(folder).count == 2)
        #expect(before.allSatisfy { contents(folder)[$0.key] == $0.value }, "the earlier backup is untouched")
    }

    @Test func deletedBackupIsWrittenAgainEvenIfUnchanged() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        let destination = FolderBackupDestination(folder: folder)
        var settings = settings()
        try await run(store, destination, &settings, trigger: .automatic, now: t0)
        for name in try fm.contentsOfDirectory(atPath: folder.path) { try fm.removeItem(at: folder.appendingPathComponent(name)) }
        guard case .completed = try await run(store, destination, &settings, trigger: .automatic, now: t0 + 60) else {
            Issue.record("expected a new backup after the old one was deleted"); return
        }
        #expect(archives(folder).count == 1)
    }

    // MARK: Failures never cost a good backup

    @Test func interruptedWriteLeavesPreviousBackupsIntact() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        let plain = FolderBackupDestination(folder: folder)
        var settings = settings()
        try await run(store, plain, &settings, trigger: .manual, now: t0)
        let good = contents(folder)
        let goodRecord = settings.lastSuccess
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 2), placement: stoolAt00, displayName: "小凳子", decision: .manual)

        for step in FailingDestination.Step.allCases {
            let failing = FailingDestination(base: plain, failAt: step)
            await #expect(throws: (any Error).self, "\(step)") {
                try await run(store, failing, &settings, trigger: .manual, now: t0 + day)
            }
            #expect(settings.lastSuccess == goodRecord, "\(step): no success is recorded")
            let now = contents(folder)
            #expect(good.allSatisfy { now[$0.key] == $0.value }, "\(step): the good backup is byte for byte as before")
            let listing = try CloudBackupCatalog.load(from: plain, deviceID: device)
            #expect(CloudBackupPolicy.recommended(listing.entries)?.name.archiveName == goodRecord?.archiveName, "\(step)")
            #expect(listing.entries.filter { $0.condition == .verified }.count == 1, "\(step): a half-written backup is never listed as verified")
        }

        // The next successful run succeeds, and clears what the interrupted ones left behind.
        guard case .completed(let record) = try await run(store, plain, &settings, trigger: .manual, now: t0 + 2 * day) else {
            Issue.record("expected the retry to succeed"); return
        }
        let listing = try CloudBackupCatalog.load(from: plain, deviceID: device)
        #expect(listing.entries.map(\.condition) == [.verified, .verified])
        #expect(listing.entries.first?.name.archiveName == record.archiveName)
        #expect(listing.orphanInfoNames.isEmpty)
        #expect(good.allSatisfy { contents(folder)[$0.key] == $0.value })
    }

    @Test func damagedLibraryIsNotBackedUpAndTouchesNothing() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        let destination = FolderBackupDestination(folder: folder)
        var settings = settings()
        try await run(store, destination, &settings, trigger: .manual, now: t0)
        let good = contents(folder)
        let added = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 2), placement: stoolAt00, displayName: "小凳子", decision: .manual)
        let original = try #require(await store.originalURL(photoId: added.sources[0].photoId))
        try Data("not the photo".utf8).write(to: original)

        await #expect(throws: BackupError.libraryDamaged(1)) {
            try await run(store, destination, &settings, trigger: .manual, now: t0 + day)
        }
        #expect(contents(folder) == good)
    }

    @Test func unavailableDestinationFailsBeforeAnyWork() async throws {
        let store = try await seededStore()
        var settings = settings()
        for availability in [CloudAvailability.signedOut, .containerUnavailable] {
            let destination = FolderBackupDestination(folder: TestSupport.tempDir(), availability: availability)
            await #expect(throws: CloudBackupError.unavailable(availability)) {
                try await run(store, destination, &settings, trigger: .manual, now: t0)
            }
        }
    }

    // MARK: Pruning

    @Test func pruningKeepsTheNewestVerifiedBackupsOfThisDevice() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        let destination = FolderBackupDestination(folder: folder)
        var settings = settings()
        // Another phone's backup, older than everything: never ours to delete.
        let foreign = CloudBackupName(deviceID: otherDevice, createdAt: t0 - 30 * day, revision: 9)!
        try Data("another phone".utf8).write(to: folder.appendingPathComponent(foreign.archiveName))
        try Data("my own notes".utf8).write(to: folder.appendingPathComponent("笔记.txt"))

        var written: [String] = []
        for index in 0..<5 {
            _ = try await store.rename(instanceId: (await store.snapshot()).items[0].instanceId, displayName: "椅子 \(index)")
            guard case .completed(let record) = try await run(store, destination, &settings, trigger: .manual, now: t0 + Double(index) * day) else {
                Issue.record("backup \(index) did not run"); return
            }
            written.append(record.archiveName)
        }
        let kept = Set(archives(folder))
        #expect(kept == Set(written.suffix(3) + [foreign.archiveName]))
        #expect(fm.fileExists(atPath: folder.appendingPathComponent("笔记.txt").path))
        let listing = try CloudBackupCatalog.load(from: destination, deviceID: device)
        #expect(listing.entries.filter(\.isFromThisDevice).map(\.name.archiveName) == written.suffix(3).reversed())
        #expect(listing.entries.filter(\.isFromThisDevice).allSatisfy { $0.condition == .verified })
        #expect(listing.orphanInfoNames.isEmpty, "infos of pruned backups go with them")
    }

    @Test func pruningNeverDeletesTheOnlyVerifiedBackup() {
        let only = entry(device, at: t0)
        let newerJunk = [entry(device, at: t0 + day, .unverified), entry(device, at: t0 + 2 * day, .damaged), entry(device, at: t0 + 3 * day, .unverified)]
        let olderJunk = [entry(device, at: t0 - day, .unverified), entry(device, at: t0 - 2 * day, .damaged)]
        let foreign = [entry(otherDevice, at: t0 - 9 * day), entry(otherDevice, at: t0 + 9 * day, .damaged)]

        for keep in [-1, 0, 1, 3] {
            let doomed = CloudBackupPolicy.prune(newerJunk + [only] + olderJunk + foreign, keep: keep)
            #expect(!doomed.contains(only.name.archiveName) && !doomed.contains(only.name.infoName), "keep \(keep)")
            // Only this device's leftovers older than the kept backup go; newer ones and other devices' stay.
            #expect(Set(doomed) == Set(olderJunk.flatMap { [$0.name.archiveName, $0.name.infoName] }), "keep \(keep)")
        }
        // No verified backup at all: nothing is deleted, whatever state the rest is in.
        #expect(CloudBackupPolicy.prune(newerJunk + olderJunk + foreign, keep: 3).isEmpty)
        #expect(CloudBackupPolicy.prune([], keep: 3).isEmpty)
        // With several verified ones, exactly the oldest beyond `keep` go.
        let four = (0..<4).map { entry(device, at: t0 + Double($0) * day, revision: $0 + 1) }
        #expect(Set(CloudBackupPolicy.prune(four, keep: 3)) == [four[0].name.archiveName, four[0].name.infoName])
        #expect(CloudBackupPolicy.prune(four, keep: 4).isEmpty)
    }

    @Test func pruningKeepsTheNewestUploadedBackupWhileUploadsAreStuck() {
        // iCloud is full: the three newest were written but never uploaded.
        let stuck = (1...3).map { entry(device, at: t0 + Double($0) * day, revision: 10 + $0, upload: .failed(quotaExceeded: true)) }
        let uploaded = (0..<3).map { entry(device, at: t0 - Double($0) * day, revision: 9 - $0, upload: .uploaded) }
        let doomed = Set(CloudBackupPolicy.prune(stuck + uploaded, keep: 3))
        #expect(!doomed.contains(uploaded[0].name.archiveName), "the newest backup that is really in iCloud stays")
        #expect(doomed == Set(uploaded.dropFirst().flatMap { [$0.name.archiveName, $0.name.infoName] }))
        #expect(stuck.allSatisfy { !doomed.contains($0.name.archiveName) })
        // Uploads caught up: ordinary rotation again.
        let caughtUp = stuck.map { var e = $0; e.upload = .uploaded; return e }
        #expect(Set(CloudBackupPolicy.prune(caughtUp + uploaded, keep: 3)) == Set(uploaded.flatMap { [$0.name.archiveName, $0.name.infoName] }))
    }

    @Test func backupWhoseInfoIsNotDownloadedIsNeverTreatedAsJunk() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        let plain = FolderBackupDestination(folder: folder)
        var settings = settings()
        guard case .completed(let first) = try await run(store, plain, &settings, trigger: .manual, now: t0) else { return }
        let firstName = try #require(CloudBackupName(archiveName: first.archiveName))
        // The system evicted the first backup's small info file.
        let evicted = UnreadableInfoDestination(base: plain, unreadable: [firstName.infoName])

        var listing = try CloudBackupCatalog.load(from: evicted, deviceID: device)
        #expect(listing.entries.map(\.condition) == [.pending])
        #expect(listing.orphanInfoNames.isEmpty, "an info that is merely not local is not an orphan")
        #expect(CloudBackupPolicy.recommended(listing.entries)?.name == firstName)
        // Unchanged library + its last backup still there: no duplicate is written.
        #expect(try await run(store, evicted, &settings, trigger: .automatic, now: t0 + 3 * day) == .skipped(.unchanged))

        // Four more backups: the pending one is never rotated out, its info never deleted.
        for index in 1...4 {
            _ = try await store.rename(instanceId: (await store.snapshot()).items[0].instanceId, displayName: "椅子 \(index)")
            guard case .completed = try await run(store, evicted, &settings, trigger: .manual, now: t0 + Double(index) * day) else {
                Issue.record("backup \(index) did not run"); return
            }
        }
        #expect(fm.fileExists(atPath: folder.appendingPathComponent(firstName.archiveName).path))
        #expect(fm.fileExists(atPath: folder.appendingPathComponent(firstName.infoName).path))
        listing = try CloudBackupCatalog.load(from: evicted, deviceID: device)
        #expect(listing.entries.map(\.condition) == [.verified, .verified, .verified, .pending])
    }

    @Test func noRoomForTheWorkFilesRefusesBeforeWriting() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        let destination = FolderBackupDestination(folder: folder)
        var settings = settings()
        let work = TestSupport.tempDir()
        let tight = CloudBackupEngine.Context(deviceID: device, deviceKind: "iPhone", appVersion: "9.9", workDirectory: work,
                                              catalog: catalog, availableSpace: 10 * 1024 * 1024)
        await #expect(throws: CloudBackupError.io("space")) {
            _ = try await CloudBackupEngine.backUpIfNeeded(store: store, destination: destination, settings: settings,
                                                           trigger: .manual, context: tight, now: t0)
        }
        #expect(contents(folder).isEmpty)
        #expect(!fm.fileExists(atPath: work.path), "the work folder is cleaned up")
        let state = await store.snapshot()
        #expect(CloudBackupEngine.localSpaceNeeded(for: state) > 2 * state.photos[0].byteSize)
        // Enough room: the same library backs up.
        guard case .completed = try await run(store, destination, &settings, trigger: .manual, now: t0) else {
            Issue.record("expected a backup with enough room"); return
        }
    }

    // MARK: Which backup to restore

    @Test func corruptNewestBackupIsLabelledAndThePreviousOneIsOffered() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        let destination = FolderBackupDestination(folder: folder)
        var settings = settings()
        guard case .completed(let first) = try await run(store, destination, &settings, trigger: .manual, now: t0) else { return }
        _ = try await store.commitNewFurniture(draft: try TestSupport.draft(seed: 2), placement: stoolAt00, displayName: "小凳子", decision: .manual)
        guard case .completed(let second) = try await run(store, destination, &settings, trigger: .manual, now: t0 + day) else { return }

        var listing = try CloudBackupCatalog.load(from: destination, deviceID: device)
        #expect(listing.entries.map(\.name.archiveName) == [second.archiveName, first.archiveName], "newest first")
        #expect(CloudBackupPolicy.recommended(listing.entries)?.name.archiveName == second.archiveName)

        // Truncated (a sync that stopped half-way): caught by the listing itself.
        let newest = folder.appendingPathComponent(second.archiveName)
        let whole = try Data(contentsOf: newest)
        try whole.prefix(whole.count / 2).write(to: newest)
        listing = try CloudBackupCatalog.load(from: destination, deviceID: device)
        #expect(listing.entries.map(\.condition) == [.damaged, .verified])
        #expect(CloudBackupPolicy.recommended(listing.entries)?.name.archiveName == first.archiveName)

        // Same size, different bytes: only the full verification on restore can tell. Once it
        // has, the entry is remembered as damaged and the previous backup is offered.
        // (Entries are stored uncompressed, so an original's bytes sit in the archive as they are.)
        let photo = (await store.snapshot()).photos[0]
        let original = try Data(contentsOf: try #require(await store.originalURL(photoId: photo.photoId)))
        let range = try #require(whole.range(of: original))
        var flipped = whole
        flipped[range.lowerBound + original.count / 2] ^= 0xFF
        try flipped.write(to: newest)
        listing = try CloudBackupCatalog.load(from: destination, deviceID: device)
        #expect(listing.entries.first?.condition == .verified)
        let file = try await destination.download(second.archiveName) { _ in }
        let target = try await openStore()
        #expect(throws: BackupError.self) {
            _ = try BackupArchive.prepare(file: file, stagingURL: target.makeStagingURL(), catalog: catalog)
        }
        listing = try CloudBackupCatalog.load(from: destination, deviceID: device, knownDamaged: [second.archiveName])
        #expect(listing.entries.map(\.condition) == [.damaged, .verified])
        #expect(CloudBackupPolicy.recommended(listing.entries)?.name.archiveName == first.archiveName)
        // Nothing but damaged ones: nothing is recommended.
        #expect(CloudBackupPolicy.recommended(listing.entries.filter { $0.condition == .damaged }) == nil)
    }

    @Test func archiveWithoutInfoIsListedAsUnverifiedAndStillRestorable() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        let destination = FolderBackupDestination(folder: folder)
        var settings = settings()
        guard case .completed(let record) = try await run(store, destination, &settings, trigger: .manual, now: t0) else { return }
        let name = try #require(CloudBackupName(archiveName: record.archiveName))
        try fm.removeItem(at: folder.appendingPathComponent(name.infoName))
        // An info file that lies about its archive is ignored, not trusted.
        let stray = CloudBackupName(deviceID: device, createdAt: t0 - day, revision: 1)!
        try Data("{}".utf8).write(to: folder.appendingPathComponent(stray.infoName))

        let listing = try CloudBackupCatalog.load(from: destination, deviceID: device)
        #expect(listing.entries.map(\.condition) == [.unverified])
        #expect(listing.orphanInfoNames == [stray.infoName])
        #expect(CloudBackupPolicy.recommended(listing.entries)?.name == name)
    }

    @Test func restoreGoesThroughTheExistingVerificationAndSwap() async throws {
        let source = try await seededStore()
        let expected = await source.snapshot()
        let folder = TestSupport.tempDir()
        let destination = FolderBackupDestination(folder: folder)
        var settings = settings()
        try await run(source, destination, &settings, trigger: .manual, now: t0)

        // "New phone": another device id, an empty library, the same destination.
        let listing = try CloudBackupCatalog.load(from: destination, deviceID: otherDevice)
        let entry = try #require(CloudBackupPolicy.recommended(listing.entries))
        #expect(!entry.isFromThisDevice)
        let file = try await destination.download(entry.name.archiveName) { _ in }
        let target = try await openStore()
        let prepared = try BackupArchive.prepare(file: file, stagingURL: target.makeStagingURL(), catalog: catalog)
        #expect(prepared.preview.kind == .iosBackup && prepared.preview.photoCount == 1 && prepared.preview.furnitureCount == 1)
        #expect(prepared.preview.catName == "团子")
        #expect((await target.snapshot()).photos.isEmpty, "nothing is replaced before the user confirms")
        let restored = try await target.replaceLibrary(with: prepared)
        #expect(restored.photos == expected.photos && restored.items == expected.items && restored.catName == "团子")
        #expect(try await target.verifyOriginal(photoId: expected.photos[0].photoId))
        // Restoring wrote nothing to the destination.
        #expect(archives(folder).count == 1)
    }

    @Test func turningOffDeletesOnlyTheConfirmedBackupsOfThisDevice() async throws {
        let store = try await seededStore()
        let folder = TestSupport.tempDir()
        let destination = FolderBackupDestination(folder: folder)
        var settings = settings()
        guard case .completed(let first) = try await run(store, destination, &settings, trigger: .manual, now: t0) else { return }
        let foreign = CloudBackupName(deviceID: otherDevice, createdAt: t0, revision: 9)!
        try Data("another phone".utf8).write(to: folder.appendingPathComponent(foreign.archiveName))
        // What the user was shown and confirmed: this device's one backup (and, wrongly, the other phone's).
        let shown = try CloudBackupCatalog.load(from: destination, deviceID: device).entries.map(\.name)
        // A backup written after the question was asked is not part of what was confirmed.
        _ = try await store.rename(instanceId: (await store.snapshot()).items[0].instanceId, displayName: "新名字")
        guard case .completed(let later) = try await run(store, destination, &settings, trigger: .manual, now: t0 + day) else { return }

        #expect(try CloudBackupEngine.deleteBackups(shown, deviceID: device, in: destination) == 1)
        #expect(Set(archives(folder)) == [foreign.archiveName, later.archiveName])
        #expect(!fm.fileExists(atPath: folder.appendingPathComponent(CloudBackupName(archiveName: first.archiveName)!.infoName).path))
    }

    @Test func downloadOfAMissingBackupFails() async throws {
        let destination = FolderBackupDestination(folder: TestSupport.tempDir())
        let name = CloudBackupName(deviceID: device, createdAt: t0, revision: 1)!
        await #expect(throws: CloudBackupError.notFound) {
            _ = try await destination.download(name.archiveName) { _ in }
        }
    }

    @Test func settingsRoundTripAndRememberDamagedNames() throws {
        var settings = CloudBackupSettings()
        #expect(!settings.enabled && settings.lastSuccess == nil, "off until the user turns it on")
        settings.enabled = true
        for index in 0..<40 { settings.rememberDamaged("file-\(index).zip") }
        settings.rememberDamaged("file-39.zip")
        #expect(settings.damagedNames.count == CloudBackupSettings.maxDamagedNames && settings.damagedNames.last == "file-39.zip")
        let decoded = try JSONDecoder().decode(CloudBackupSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        // Settings saved by a build that knew fewer fields still load.
        #expect(try JSONDecoder().decode(CloudBackupSettings.self, from: Data(#"{"enabled":true}"#.utf8)).enabled)
    }
}

/// A destination whose named small files are listed but cannot be read, like iCloud files
/// that are not downloaded.
struct UnreadableInfoDestination: BackupDestination {
    let base: FolderBackupDestination
    let unreadable: Set<String>

    func availability() -> CloudAvailability { base.availability() }
    func list() throws -> [CloudBackupFile] { try base.list() }
    func readSmallFile(_ name: String) throws -> Data {
        if unreadable.contains(name) { throw CloudBackupError.notFound }
        return try base.readSmallFile(name)
    }
    func place(_ local: URL, as name: String) throws { try base.place(local, as: name) }
    func writeSmallFile(_ data: Data, as name: String) throws { try base.writeSmallFile(data, as: name) }
    func remove(_ name: String) throws { try base.remove(name) }
    func localURL(for name: String) -> URL? { base.localURL(for: name) }
    func download(_ name: String, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        try await base.download(name, progress: progress)
    }
}

/// A destination that fails once at a chosen step, like a write that was interrupted.
final class FailingDestination: BackupDestination {
    enum Step: CaseIterable, Sendable { case place, placeAfterWriting, writeInfo, hashAfterPlacing }
    struct Interrupted: Error {}

    let base: FolderBackupDestination
    let failAt: Step

    init(base: FolderBackupDestination, failAt: Step) {
        self.base = base
        self.failAt = failAt
    }

    func availability() -> CloudAvailability { base.availability() }
    func list() throws -> [CloudBackupFile] { try base.list() }
    func readSmallFile(_ name: String) throws -> Data { try base.readSmallFile(name) }
    func remove(_ name: String) throws { try base.remove(name) }
    func download(_ name: String, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        try await base.download(name, progress: progress)
    }

    func place(_ local: URL, as name: String) throws {
        if failAt == .place { throw Interrupted() }
        try base.place(local, as: name)
        if failAt == .placeAfterWriting { throw Interrupted() }
    }

    func writeSmallFile(_ data: Data, as name: String) throws {
        if failAt == .writeInfo { throw Interrupted() }
        try base.writeSmallFile(data, as: name)
    }

    func localURL(for name: String) -> URL? {
        // The archive cannot be read back after the move: it must not count as a backup.
        failAt == .hashAfterPlacing ? nil : base.localURL(for: name)
    }
}
