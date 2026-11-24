import Foundation
import Testing
@testable import MeowverseCore

/// `Resources/legacy-b607-single-checkpoint` was written by the store at b607046, which kept
/// one checkpoint per picker group and wrote no compaction proofs. Recipe: `git archive
/// b607046 ios/MeowverseCore`, then in that package run a test which calls
/// `addPhoto(draft: TestSupport.draft(seed: 120))`, `importPickerPhotos([TestSupport.draft(seed: 121)])`,
/// arms `.pickerSnapshotBackupInstalled` and calls `finishPickerImport()`. The result is the
/// state from the fourth review: `state.json` and `base.json` hold photo A at revision 1;
/// `state.backup.json` and `state.json.tmp` hold A+B at revision 2 and are byte-identical;
/// `00000001.json` is the only checkpoint and no `compaction-*` proof exists.
///
/// `Resources/legacy-b607-single-checkpoint-furniture` comes from the same writer and fault,
/// with a piece of furniture: `commitNewFurniture(draft: TestSupport.draft(seed: 130),
/// placement: kenney-chair at 4,4, displayName: "Chair", decision: .manual)`, then
/// `importPickerPhotos([TestSupport.draft(seed: 131)], to: chair.instanceId)`. Its checkpoint
/// adds photo B and links it to the chair, so the recovered link is checked too.
///
/// Only the store's own files are kept. Media cannot enter Git unreviewed, so the two
/// synthetic photos are drawn again from the same seeds and must hash to the recorded bytes.
struct LegacyPickerFixtureTests {
    enum Variant: CaseIterable, Sendable {
        /// The backup and temp the old writer left. The only checkpoint is unreadable.
        case installed
        /// The same, with an unreadable primary: the baseline is the only source of A.
        case installedDamagedPrimary
        /// The same history re-encoded so the group's revision wraps from the maximum to 1.
        case installedAcrossRevisionWrap
        /// The only checkpoint still decodes but one bit is wrong: photo B's width reads 65, not
        /// 64. The backup and temp agree byte for byte on 64 and must win (fifth review, R5-06).
        case installedWithLegalDamage
        /// The same wrong checkpoint, and the temp is gone. The backup alone says 64, the
        /// checkpoint 65: contradicting evidence is not settled silently. The backup is taken
        /// and the tree is parked (QA after the fifth review).
        case installedWithLegalDamageMissingTemp
        /// Control: the checkpoint is as written (64), the backup and temp agree on 65. The
        /// installed pair still outweighs the checkpoint.
        case installedDisagreesWithIntactCheckpoint
        /// Controls: without corroboration the verified baseline A stays authoritative.
        case missingTemp, foreignAtSameRevision, staleRevision

        var keepsCheckpoint: Bool {
            [.installedWithLegalDamage, .installedWithLegalDamageMissingTemp, .installedDisagreesWithIntactCheckpoint].contains(self)
        }
    }

    enum Fixture: String, CaseIterable, Sendable {
        case photoOnly = "legacy-b607-single-checkpoint"
        case furniture = "legacy-b607-single-checkpoint-furniture"

        var photoSeeds: [Int] { self == .photoOnly ? [120, 121] : [130, 131] }
    }

    static let photoSeeds = Fixture.photoOnly.photoSeeds

    /// Copies the old writer's files to `root` and adds the originals and thumbnails it wrote.
    static func install(at root: URL, fixture: Fixture = .photoOnly) throws {
        let source = try #require(Bundle.module.url(forResource: fixture.rawValue, withExtension: nil))
        try FileManager.default.copyItem(at: source, to: root)
        guard case .valid(let full) = LibraryStore.decodeState(try Data(contentsOf: root.appending(path: LibraryStore.backupFile)))
        else { Issue.record("fixture backup must decode"); return }
        let drafts = try fixture.photoSeeds.map { try TestSupport.draft(seed: $0) }
        try #require(full.photos.map(\.sha256) == drafts.map(\.sha256), "the synthetic photos no longer encode to the fixture's bytes")
        for (photo, draft) in zip(full.photos, drafts) {
            for (path, bytes) in [(photo.originalFile, draft.data), (photo.thumbnailFile, draft.thumbnailJPEG)] {
                let file = root.appending(path: path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: file)
            }
        }
    }

    /// Photo B's width 64 → 65 in the only checkpoint: one bit, the same length, still JSON.
    static func damageLegally(_ checkpoint: URL, fixture: Fixture) throws {
        var bytes = try Data(contentsOf: checkpoint)
        let digits = Array(#""width":64"#.utf8)
        let hits = (0...(bytes.count - digits.count)).filter { Array(bytes[$0..<($0 + digits.count)]) == digits }
        try #require(hits.count == 1, "the fixture's width moved")
        let position = hits[0] + digits.count - 1
        // The review's exact byte in the photo-only fixture.
        if fixture == .photoOnly { try #require(position == 535) }
        try #require(bytes[position] == 0x34)
        bytes[position] = 0x35
        try bytes.write(to: checkpoint)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let delta = try decoder.decode(PickerImportDelta.self, from: bytes)
        try #require(delta.photos.map(\.record.width) == [65])
    }

    @Test(arguments: Fixture.allCases, Variant.allCases)
    func singleLegacyCheckpointRecoversTheInstalledBackup(fixture: Fixture, variant: Variant) async throws {
        let parent = TestSupport.tempDir(), root = parent.appending(path: "library")
        defer { try? FileManager.default.removeItem(at: parent) }
        let fm = FileManager.default
        try Self.install(at: root, fixture: fixture)
        let catalog = try TestSupport.catalog()
        let backupURL = root.appending(path: LibraryStore.backupFile), temp = root.appending(path: LibraryStore.tempStateFile)
        let folder = root.appending(path: PickerImportJournal.directory)
        try #require(fm.contentsEqual(atPath: backupURL.path, andPath: temp.path))
        try #require(fm.contentsEqual(atPath: root.appending(path: LibraryStore.stateFile).path,
                                      andPath: folder.appending(path: "base.json").path))
        try #require(try fm.contentsOfDirectory(atPath: folder.path).sorted() == ["00000001.json", "base.json"])
        guard case .valid(var baseline) = LibraryStore.decodeState(try Data(contentsOf: folder.appending(path: "base.json"))),
              case .valid(var full) = LibraryStore.decodeState(try Data(contentsOf: backupURL)) else {
            Issue.record("fixture snapshots must decode"); return
        }
        try #require(baseline.photos.count == 1 && full.photos.count == 2 && full.revision == LibraryStore.nextRevision(baseline.revision))

        switch variant {
        case .installed: break
        case .installedDamagedPrimary: try Data([0]).write(to: root.appending(path: LibraryStore.stateFile))
        case .installedAcrossRevisionWrap:
            baseline.revision = LibraryStore.maxRevision
            full.revision = LibraryStore.nextRevision(baseline.revision)
            #expect(full.revision == 1)
            for (state, files) in [(baseline, [root.appending(path: LibraryStore.stateFile), folder.appending(path: "base.json")]),
                                   (full, [backupURL, temp])] {
                let bytes = try LibraryStore.encodeState(state)
                for file in files { try bytes.write(to: file) }
            }
        case .installedWithLegalDamage:
            try #require(full.photos[1].width == 64)
            try Self.damageLegally(folder.appending(path: "00000001.json"), fixture: fixture)
        case .installedWithLegalDamageMissingTemp:
            try #require(full.photos[1].width == 64)
            try Self.damageLegally(folder.appending(path: "00000001.json"), fixture: fixture)
            try fm.removeItem(at: temp)
        case .installedDisagreesWithIntactCheckpoint:
            full.photos[1].width = 65
            let bytes = try LibraryStore.encodeState(full)
            try bytes.write(to: backupURL)
            try bytes.write(to: temp)
        case .missingTemp: try fm.removeItem(at: temp)
        case .foreignAtSameRevision, .staleRevision:
            var other = full
            other.photos[0].note = "An edit from a different history"
            if variant == .staleRevision { other.revision = LibraryStore.nextRevision(full.revision) }
            let bytes = try LibraryStore.encodeState(other)
            try bytes.write(to: backupURL)
            try bytes.write(to: temp)
        }
        if !variant.keepsCheckpoint { try Data([255]).write(to: folder.appending(path: "00000001.json")) }
        let files = TestSupport.listing(root)
        let originalBytes = files.map { TestSupport.bytes(root.appending(path: $0)) }

        let expected = [.installed, .installedDamagedPrimary, .installedAcrossRevisionWrap, .installedWithLegalDamage,
                        .installedWithLegalDamageMissingTemp, .installedDisagreesWithIntactCheckpoint].contains(variant)
            ? full : baseline
        let reader = LibraryStore(root: root, catalog: catalog)
        let recovered = try await reader.load()
        #expect(recovered.photos.map(\.photoId) == expected.photos.map(\.photoId))
        #expect(recovered == expected)
        #expect(await reader.recoveredFromBackup)
        #expect(await reader.integrityReport().isClean)
        if fixture == .furniture {
            // Both directions of the chair's links: B on it only when the installed group wins.
            let chair = try #require(expected.items.first)
            #expect(expected.items.count == 1 && chair.sources.map(\.photoId) == expected.photos.map(\.photoId))
            let index = await reader.indexedSnapshot().index
            #expect(index.photos(ofFurniture: chair.instanceId).map(\.photoId) == expected.photos.map(\.photoId))
            for photo in expected.photos {
                #expect(index.furniture(ofPhoto: photo.photoId).map(\.instanceId) == [chair.instanceId])
            }
        }
        for photo in expected.photos {
            #expect(TestSupport.bytes(root.appending(path: photo.originalFile))
                    == originalBytes[files.firstIndex(of: photo.originalFile)!])
        }

        // The damaged tree is parked unchanged until Clear All.
        let archive = try #require(try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("library.damaged-") })
        #expect(TestSupport.listing(archive) == files)
        #expect(files.map { TestSupport.bytes(archive.appending(path: $0)) } == originalBytes)

        let reopened = LibraryStore(root: root, catalog: catalog)
        #expect(try await reopened.load() == expected)
        #expect(!(await reopened.recoveredFromBackup))

        let zip = parent.appending(path: "backup.zip")
        _ = try await reopened.exportBackup(to: zip, appVersion: "test")
        let prepared = try BackupArchive.prepare(file: zip, stagingURL: reopened.makeStagingURL(), catalog: catalog)
        #expect(prepared.state == expected)
        #expect(try await reopened.replaceLibrary(with: prepared) == expected)
        #expect(try await LibraryStore(root: root, catalog: catalog).load() == expected)
        #expect(fm.fileExists(atPath: archive.path))
        _ = try await reopened.clearAll()
        #expect(!fm.fileExists(atPath: archive.path))
    }

    /// Control: the old writer's checkpoint as it wrote it agrees with the installed backup, so
    /// nothing is damaged, nothing is parked, and the group finishes as an ordinary import. With
    /// the temp gone too: a lone backup that agrees with the checkpoint is no contradiction.
    @Test(arguments: Fixture.allCases, [false, true])
    func intactLegacyCheckpointFinishesWithoutQuarantine(fixture: Fixture, withoutTemp: Bool) async throws {
        let parent = TestSupport.tempDir(), root = parent.appending(path: "library")
        defer { try? FileManager.default.removeItem(at: parent) }
        try Self.install(at: root, fixture: fixture)
        if withoutTemp { try FileManager.default.removeItem(at: root.appending(path: LibraryStore.tempStateFile)) }
        guard case .valid(let full) = LibraryStore.decodeState(try Data(contentsOf: root.appending(path: LibraryStore.backupFile)))
        else { Issue.record("fixture backup must decode"); return }
        let catalog = try TestSupport.catalog()
        let reader = LibraryStore(root: root, catalog: catalog)
        #expect(try await reader.load() == full)
        #expect(!(await reader.recoveredFromBackup))
        #expect(await reader.integrityReport().isClean)
        let parked = try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix("library.damaged-") }
        #expect(parked.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: PickerImportJournal.directory).path))
        #expect(try await LibraryStore(root: root, catalog: catalog).load() == full)
    }
}
