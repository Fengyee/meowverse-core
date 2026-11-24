import Foundation
import Testing
@testable import MeowverseCore

// T5: this build tells all fifteen chapters (`TourCatalog.thisBuild`). Chapters 8 to 11 and 13 to
// 15, with the conditions of docs/onboarding/LINES.md T5.10 and the lead's rulings in T5.14.

private func snap(_ change: (inout TourSnapshot) -> Void = { _ in }) -> TourSnapshot {
    var snapshot = TourSnapshot()
    change(&snapshot)
    return snapshot
}

private struct BuildTour {
    var machine: TourMachine
    var saved: [TourRecord] = []

    init(stored: TourStored = .missing) {
        machine = TourMachine(catalog: .thisBuild, settles: .current, stored: stored)
    }

    @discardableResult mutating func send(_ event: TourEvent) -> TourRun? {
        var run: TourRun?
        for effect in machine.handle(event) {
            switch effect {
            case .save(let record): saved.append(record)
            case .start(let begun): run = begun
            }
        }
        return run
    }

    @discardableResult mutating func launch(_ snapshot: TourSnapshot) -> TourChapterID? {
        send(.opened(.launch, snapshot))
        return send(.arrived(snapshot))?.chapter
    }

    @discardableResult mutating func arrive(_ snapshot: TourSnapshot) -> TourChapterID? { send(.arrived(snapshot))?.chapter }

    @discardableResult mutating func end(_ exit: TourExit, _ snapshot: TourSnapshot = snap()) -> TourChapterID? {
        guard let run = machine.session.run else {
            Issue.record("no chapter is on screen")
            return nil
        }
        return send(.finished(run: run.id, exit, snapshot))?.chapter
    }

    mutating func readOpening() {
        #expect(launch(snap()) == .welcome)
        var turns = 0
        while machine.session.run != nil, turns < 10 {
            end(.completed)
            turns += 1
        }
        #expect(TourRules.openingIsOver(catalog: .thisBuild, record: machine.record))
    }

    func relaunched() -> BuildTour { BuildTour(stored: saved.last.map(TourStored.record) ?? .missing) }
    func outcome(_ id: TourChapterID) -> TourOutcome? { machine.record.entry(for: id)?.outcome }
}

/// After the opening, the user wandered somewhere: these are where each page chapter begins.
private func on(_ surface: TourSurface, _ change: (inout TourSnapshot) -> Void = { _ in }) -> TourSnapshot {
    snap {
        $0.surface = surface
        $0.roomIsEmpty = false; $0.furnitureCount = 1; $0.photoCount = 1
        $0.hasPerchableFurniture = true
        change(&$0)
    }
}

@Suite struct OnboardingTourT5Tests {
    @Test func thisBuildTellsEveryChapterInCatalogOrder() {
        #expect(TourCatalog.thisBuild == TourCatalog.current)
        #expect(TourCatalog.thisBuild.chapters.count == 15)
    }

    @Test func eachPageChapterBeginsOnItsOwnPageAfterTheOpening() {
        var tour = BuildTour()
        tour.readOpening()
        #expect(tour.arrive(on(.photoLibrary)) == .photoLibrary)
        tour.end(.completed)
        #expect(tour.arrive(on(.furnitureLibrary)) == .furnitureLibrary)
        tour.end(.completed)
        #expect(tour.arrive(on(.interactionPanel)) == nil, "two chapters this open already (rule 13)")
        var second = tour.relaunched()
        second.send(.opened(.launch, on(.room)))
        #expect(second.arrive(on(.interactionPanel)) == .sendCat)
    }

    @Test func somewhereElseStartsNothing() {
        var tour = BuildTour()
        tour.readOpening()
        let everything = on(.elsewhere) {
            $0.unsortedPhotoCount = 3; $0.photoCount = 12; $0.supportsAR = true; $0.hasFurnitureWithPhotos = true
            $0.hasMovableFurniture = true
        }
        #expect(tour.arrive(everything) == nil)
        #expect(tour.send(.factsChanged(everything)) == nil)
    }

    @Test func pageChaptersWaitForTheOpening() {
        var tour = BuildTour()
        #expect(tour.launch(snap()) == .welcome)
        tour.end(.completed)
        tour.end(.handedOff)
        #expect(tour.arrive(on(.photoLibrary)) == nil)
        #expect(tour.arrive(on(.furnitureLibrary)) == nil)
        #expect(tour.arrive(on(.interactionPanel) { $0.supportsAR = true }) == nil)
    }

    @Test func chapterEightWaitsForTheImportAndItsRecognitionToFinish() {
        var tour = BuildTour()
        tour.readOpening()
        let waiting = on(.room) { $0.unsortedPhotoCount = 5; $0.photoCount = 5; $0.hasMovableFurniture = false }
        #expect(tour.arrive(snap { $0 = waiting; $0.importRunning = true }) == nil)
        #expect(tour.arrive(waiting) == .photoBatch)
        tour.end(.handedOff, waiting)
        #expect(tour.outcome(.photoBatch) == .completed, "starting to sort is reading it (rule 6)")
    }

    @Test func chapterElevenNeedsACatInTheRoomAndAPieceItCanReach() {
        var tour = BuildTour()
        tour.readOpening()
        #expect(tour.arrive(on(.interactionPanel) { $0.roomHasCat = false }) == nil)
        #expect(tour.arrive(on(.interactionPanel) { $0.hasPerchableFurniture = false }) == nil)
        #expect(tour.arrive(on(.interactionPanel)) == .sendCat)
    }

    @Test func chapterThirteenComesAtTheNextPanelVisitAfterChapterEleven() {
        var tour = BuildTour()
        tour.readOpening()
        let panel = on(.interactionPanel) { $0.supportsAR = true }
        #expect(tour.arrive(panel) == .sendCat)
        tour.end(.completed)
        #expect(tour.send(.factsChanged(panel)) == nil, "one chapter a visit")
        #expect(tour.arrive(panel) == .tabletop)
    }

    @Test func chapterThirteenIsNotOnADeviceWithoutARNorWithTheCameraOff() throws {
        var tour = BuildTour()
        tour.readOpening()
        let noAR = on(.interactionPanel) { $0.hasPerchableFurniture = false }
        #expect(tour.arrive(noAR) == nil)
        #expect(tour.send(.replay(.tabletop, noAR)) == nil, "not opened by hand either")
        #expect(TourMenu(catalog: .thisBuild, stored: .missing, snapshot: noAR).onDemand.map(\.id).contains(.tabletop) == false)

        let cameraOff = on(.interactionPanel) { $0.hasPerchableFurniture = false; $0.supportsAR = true; $0.cameraDenied = true }
        #expect(tour.arrive(cameraOff) == nil, "Bella does not ask for the camera")
        let sent = tour.send(.replay(.tabletop, cameraOff))
        let replayed = try #require(sent)
        #expect(!replayed.demonstrates, "the card says the camera is off")
    }

    @Test func chapterFifteenAtTenPhotosUnlessICloudDriveBacksUp() {
        var tour = BuildTour()
        tour.readOpening()
        let nine = on(.room) { $0.photoCount = 9; $0.hasPerchableFurniture = false }
        #expect(tour.arrive(nine) == nil)
        #expect(tour.arrive(snap { $0 = nine; $0.photoCount = 10; $0.cloudBackupOn = true }) == nil)
        #expect(tour.arrive(snap { $0 = nine; $0.photoCount = 10 }) == .backup)
    }

    @Test func chapterFifteenOpenedByHandNeedsNoPhotos() throws {
        var tour = BuildTour()
        tour.readOpening()
        let sent = tour.send(.replay(.backup, snap()))
        let run = try #require(sent)
        #expect(run.demonstrates)
    }

    @Test func roomChaptersComeInTheRuleThirteenOrderTwoAnOpen() {
        // A home with all of 6, 7, 8, 12, 14 and 15 due at the second open.
        var first = BuildTour()
        first.readOpening()
        let home = on(.room) {
            $0.hasFurnitureWithPhotos = true; $0.hasMovableFurniture = true; $0.unsortedPhotoCount = 4; $0.photoCount = 14
            $0.hasPerchableFurniture = false
        }
        var order: [[TourChapterID]] = []
        var tour = first.relaunched()
        for _ in 0..<4 {
            var told: [TourChapterID] = []
            if let chapter = tour.launch(home) { told.append(chapter); tour.end(.completed, home) }
            while let chapter = tour.arrive(home) { told.append(chapter); tour.end(.completed, home) }
            order.append(told)
            tour = tour.relaunched()
        }
        #expect(order == [[.memories, .moveAndLook], [.reminders, .company], [.photoBatch, .backup], []])
    }

    @Test func theReplayListHasEveryFeatureChapter() {
        let menu = TourMenu(catalog: .thisBuild, stored: .missing, snapshot: snap { $0.supportsAR = true })
        #expect(menu.onDemand.map(\.id) == [.memories, .moveAndLook, .photoBatch, .photoLibrary, .furnitureLibrary, .sendCat,
                                            .company, .tabletop, .reminders, .backup])
    }

    @Test func everythingSeenOnlyWhenEveryChapterWasReadAndNoneSkipped() {
        var record = TourRecord()
        let device = snap { $0.supportsAR = false }
        for chapter in TourCatalog.thisBuild.chapters where chapter.id != .tabletop {
            record.chapters[chapter.id.rawValue] = TourEntry(outcome: .completed, revision: chapter.revision)
        }
        #expect(TourRules.everythingSeen(catalog: .thisBuild, record: record, snapshot: device), "no AR: chapter 13 is not on this device")
        #expect(!TourRules.everythingSeen(catalog: .thisBuild, record: record, snapshot: snap { $0.supportsAR = true }))

        record.chapters["reminders"] = TourEntry(outcome: .notNeeded, revision: 1)
        #expect(TourRules.everythingSeen(catalog: .thisBuild, record: record, snapshot: device), "reminders not needed here")
        record.chapters["backup"] = TourEntry(outcome: .skipped, revision: 1)
        #expect(!TourRules.everythingSeen(catalog: .thisBuild, record: record, snapshot: device))
        record.chapters["backup"] = TourEntry(outcome: .skippedAll, revision: 1)
        #expect(!TourRules.everythingSeen(catalog: .thisBuild, record: record, snapshot: device))
        record.chapters["backup"] = TourEntry(outcome: .completed, revision: 1)
        record.chapters["welcome"] = TourEntry(outcome: .grandfathered, revision: 1)
        #expect(!TourRules.everythingSeen(catalog: .thisBuild, record: record, snapshot: device), "a waived opening was not read")
    }

    // QA_T5 must-fix 1: an opening walked for real, from an empty room, with a part passed over.

    /// The photo comes home in chapter 2 (a piece with it, the room no longer empty): chapter 3
    /// does not apply and is passed over. When the opening is over it is written down as not
    /// needed, so reading every other chapter brings 「都讲完啦」.
    private func walkTheOpeningWithAPhotoBroughtHome() -> BuildTour {
        var tour = BuildTour()
        #expect(tour.launch(snap()) == .welcome)
        #expect(tour.end(.completed) == .bringPhoto)
        let home = snap { $0.photoCount = 1; $0.furnitureCount = 1; $0.roomIsEmpty = false }
        var turns = 0
        while tour.machine.session.run != nil, turns < 10 {
            tour.end(.completed, home)
            turns += 1
        }
        #expect(TourRules.openingIsOver(catalog: .thisBuild, record: tour.machine.record))
        return tour
    }

    private func everyFeatureChapterRead(_ record: TourRecord, but left: TourChapterID? = nil,
                                         as outcome: TourOutcome = .skipped) -> TourRecord {
        var record = record
        for chapter in TourCatalog.thisBuild.chapters where chapter.kind == .onDemand && chapter.id != .tabletop {
            record.chapters[chapter.id.rawValue] = TourEntry(outcome: chapter.id == left ? outcome : .completed,
                                                             revision: chapter.revision)
        }
        return record
    }

    @Test func anOpeningPartPassedOverIsWrittenDownAsNotNeeded() {
        let tour = walkTheOpeningWithAPhotoBroughtHome()
        #expect(tour.outcome(.welcome) == .completed)
        #expect(tour.outcome(.bringPhoto) == .completed)
        #expect(tour.outcome(.furnishFirst) == .notNeeded, "passed over: the room was no longer empty")
        #expect(tour.saved.last?.entry(for: .furnishFirst)?.outcome == .notNeeded, "and saved")
        let device = snap { $0.supportsAR = false }
        #expect(TourRules.everythingSeen(catalog: .thisBuild, record: everyFeatureChapterRead(tour.machine.record),
                                         snapshot: device))
        // Still in the replay list, shown as a not-needed chapter is.
        let menu = TourMenu(catalog: .thisBuild, stored: .record(tour.machine.record), snapshot: device)
        #expect(menu.opening.first { $0.id == .furnishFirst }?.status == .notYet, "as before: not seen here, can be opened")
    }

    @Test func withARealOpeningAChapterSkippedStillHoldsBackTheAllDoneCard() {
        let tour = walkTheOpeningWithAPhotoBroughtHome()
        let device = snap { $0.supportsAR = false }
        for skipped in [TourChapterID.reminders, .backup, .memories] {
            let record = everyFeatureChapterRead(tour.machine.record, but: skipped)
            #expect(!TourRules.everythingSeen(catalog: .thisBuild, record: record, snapshot: device), "\(skipped) skipped")
        }
        let skippedAll = everyFeatureChapterRead(tour.machine.record, but: .company, as: .skippedAll)
        #expect(!TourRules.everythingSeen(catalog: .thisBuild, record: skippedAll, snapshot: device))
    }

    /// A record saved before this was written down (the opening over, a part with no record): the
    /// next open writes it, so those users are not kept from the card for ever.
    @Test func anOpeningFinishedBeforeTheFixIsWrittenDownOnTheNextOpen() {
        var old = TourRecord()
        old.opens = 2
        for id in [TourChapterID.welcome, .bringPhoto, .play, .topRow] {
            old.chapters[id.rawValue] = TourEntry(outcome: .completed, revision: 1)
        }
        var tour = BuildTour(stored: .record(old))
        tour.launch(snap { $0.photoCount = 1; $0.furnitureCount = 1; $0.roomIsEmpty = false })
        #expect(tour.outcome(.furnishFirst) == .notNeeded)
        #expect(tour.outcome(.welcome) == .completed, "the parts that were told keep their ending")
    }

    @Test func anOpeningNotOverYetWritesNothing() {
        var tour = BuildTour()
        #expect(tour.launch(snap()) == .welcome)
        #expect(tour.end(.completed) == .bringPhoto)
        #expect(tour.outcome(.furnishFirst) == nil, "chapter 3 may still come")
        #expect(tour.outcome(.play) == nil)
    }
}
