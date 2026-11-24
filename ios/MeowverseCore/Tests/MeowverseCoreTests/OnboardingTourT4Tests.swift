import Foundation
import Testing
@testable import MeowverseCore

// T4: the tour of this build also tells chapters 6 (memories), 7 (move and look) and 12 (company),
// with the catalog the app builds (`TourCatalog.thisBuild`), and 「全部跳过」 still settling every
// chapter of `TourCatalog.current`. PRODUCT_PLAN §3.1 rule 13, §3.2, chapters 6, 7, 12.

/// The chapters the T4 build told. These tests keep to them: the chapters T5 added would come
/// first at some of the moments here (chapter 14 before 12 at the second open), and they have their
/// own tests (OnboardingTourT5Tests.swift).
private let t4Catalog = TourCatalog(chapters: TourCatalog.current.chapters.filter {
    [.welcome, .bringPhoto, .furnishFirst, .play, .topRow, .memories, .moveAndLook, .company].contains($0.id)
})

private func snap(_ change: (inout TourSnapshot) -> Void = { _ in }) -> TourSnapshot {
    var snapshot = TourSnapshot()
    change(&snapshot)
    return snapshot
}

private struct BuildTour {
    var machine: TourMachine
    var saved: [TourRecord] = []
    var started: [TourRun] = []

    init(stored: TourStored = .missing) {
        machine = TourMachine(catalog: t4Catalog, settles: .current, stored: stored)
    }

    @discardableResult mutating func send(_ event: TourEvent) -> TourRun? {
        var run: TourRun?
        for effect in machine.handle(event) {
            switch effect {
            case .save(let record): saved.append(record)
            case .start(let begun): started.append(begun); run = begun
            }
        }
        return run
    }

    @discardableResult mutating func launch(_ snapshot: TourSnapshot) -> TourChapterID? {
        send(.opened(.launch, snapshot))
        return send(.arrived(snapshot))?.chapter
    }

    @discardableResult mutating func arrive(_ snapshot: TourSnapshot) -> TourChapterID? { send(.arrived(snapshot))?.chapter }

    @discardableResult mutating func end(_ exit: TourExit, _ snapshot: TourSnapshot) -> TourChapterID? {
        guard let run = machine.session.run else {
            Issue.record("no chapter is on screen")
            return nil
        }
        return send(.finished(run: run.id, exit, snapshot))?.chapter
    }

    /// The opening, read to its end in the room it starts in.
    mutating func readOpening(_ snapshot: TourSnapshot) {
        #expect(launch(snapshot) == .welcome)
        var turns = 0
        while machine.session.run != nil, turns < 10 {
            end(.completed, snapshot)
            turns += 1
        }
        #expect(TourRules.openingIsOver(catalog: t4Catalog, record: machine.record))
    }

    /// The app closed and opened again on the same library.
    func relaunched() -> BuildTour { BuildTour(stored: saved.last.map(TourStored.record) ?? .missing) }

    var running: TourChapterID? { machine.session.run?.chapter }
    func outcome(_ id: TourChapterID) -> TourOutcome? { machine.record.entry(for: id)?.outcome }
}

private let emptyRoom = snap()
/// One piece with a photo, not locked: chapters 6 and 7 can both be shown.
private let photoPiece = snap {
    $0.roomIsEmpty = false; $0.furnitureCount = 1; $0.photoCount = 1
    $0.hasFurnitureWithPhotos = true; $0.hasMovableFurniture = true
}
/// A piece placed from the catalog, without a photo.
private let barePiece = snap { $0.roomIsEmpty = false; $0.furnitureCount = 1; $0.hasMovableFurniture = true }

@Suite struct OnboardingTourThisBuildTests {
    @Test func aNewUsersFirstPhotoPieceThenMovingThenCompanyAtTheSecondOpen() {
        var tour = BuildTour()
        tour.readOpening(emptyRoom)
        #expect(tour.arrive(emptyRoom) == nil, "nothing to show in an empty room at the first open")

        #expect(tour.arrive(photoPiece) == .memories)
        #expect(tour.end(.completed, photoPiece) == nil)
        // Chapter 7 is not told in the same visit as chapter 6 (§3.2: 不和第 6 章连着出).
        #expect(tour.send(.factsChanged(photoPiece)) == nil)
        #expect(tour.arrive(photoPiece) == .moveAndLook, "the next time the room is free")
        #expect(tour.end(.completed, photoPiece) == nil)
        #expect(tour.arrive(photoPiece) == nil, "company waits for the second open")

        var second = tour.relaunched()
        #expect(second.launch(photoPiece) == .company)
        #expect(second.end(.completed, photoPiece) == nil)
        #expect(second.arrive(photoPiece) == nil, "each told once")
    }

    @Test func aPieceWithoutPhotosHasNoMemoryChapterButCanBeMoved() {
        var tour = BuildTour()
        tour.readOpening(emptyRoom)
        #expect(tour.arrive(barePiece) == .moveAndLook)
        tour.end(.completed, barePiece)
        #expect(tour.arrive(barePiece) == nil)
        // A photo hung on it later: now the memory chapter (§3.3 chapter 6, 「后来手动挂上照片的，也算」).
        #expect(tour.arrive(snap { $0 = barePiece; $0.photoCount = 1; $0.hasFurnitureWithPhotos = true }) == .memories)
    }

    @Test func everyPieceLockedLeavesChapterSevenForLater() {
        var tour = BuildTour()
        tour.readOpening(emptyRoom)
        let locked = snap { $0 = photoPiece; $0.hasMovableFurniture = false }
        #expect(tour.arrive(locked) == .memories)
        tour.end(.completed, locked)
        #expect(tour.arrive(locked) == nil)
        #expect(tour.outcome(.moveAndLook) == nil, "not settled: it comes once a piece is unlocked")
        #expect(tour.arrive(photoPiece) == .moveAndLook)
    }

    @Test func secondOpenWithAllThreeDueTellsSixAndSevenThenTwelveAtTheThird() {
        var first = BuildTour()
        first.readOpening(emptyRoom)
        var second = first.relaunched()
        // Rule 13: 6, 7 ahead of 12; two on-demand chapters per open.
        #expect(second.launch(photoPiece) == .memories)
        second.end(.completed, photoPiece)
        #expect(second.arrive(photoPiece) == .moveAndLook)
        second.end(.completed, photoPiece)
        #expect(second.arrive(photoPiece) == nil, "two chapters this open already")
        var third = second.relaunched()
        #expect(third.launch(photoPiece) == .company)
    }

    @Test func openingTheCompanyPageAfterTheOpeningTellsChapterTwelveAtTheFirstOpen() {
        var tour = BuildTour()
        tour.readOpening(emptyRoom)
        #expect(tour.arrive(snap { $0.surface = .interactionPanel }) == nil)
        #expect(tour.arrive(snap { $0.surface = .companyPage }) == .company)
    }

    @Test func theCompanyPageMidOpeningTellsNothing() {
        var tour = BuildTour()
        #expect(tour.launch(emptyRoom) == .welcome)
        tour.end(.completed, emptyRoom)
        // 2.3 handed over; the user wandered to the company page.
        tour.end(.handedOff, emptyRoom)
        #expect(tour.arrive(snap { $0.surface = .companyPage }) == nil)
    }

    @Test func theMemoryChapterMayComeBetweenTwoPartsOfTheOpeningButNotChapterSevenOrTwelve() {
        var tour = BuildTour()
        #expect(tour.launch(emptyRoom) == .welcome)
        tour.end(.completed, emptyRoom)
        #expect(tour.running == .bringPhoto)
        tour.end(.handedOff, emptyRoom)
        #expect(tour.arrive(photoPiece) == .memories)
        tour.end(.completed, photoPiece)
        #expect(tour.arrive(photoPiece) == .play, "the opening goes on")
        #expect(tour.machine.session.toldThisOpen == [.memories])
    }

    @Test func aHomeLivedInBeforeTheTourGetsChapterSixAtOnceAndNoGreeting() {
        var tour = BuildTour()
        #expect(tour.launch(photoPiece) == .memories)
        #expect(tour.outcome(.welcome) == .grandfathered)
        #expect(tour.outcome(.company) == nil, "on-demand chapters are for everyone")
    }

    @Test func skipAllOnChapterSixSettlesEveryChapterIncludingThoseNotToldYet() {
        var tour = BuildTour()
        tour.readOpening(emptyRoom)
        #expect(tour.arrive(photoPiece) == .memories)
        tour.end(.skippedAll, photoPiece)
        for chapter in TourCatalog.current.chapters where chapter.kind == .onDemand {
            #expect(tour.outcome(chapter.id) == .skippedAll, "\(chapter.id)")
        }
        #expect(tour.arrive(photoPiece) == nil)
        var second = tour.relaunched()
        #expect(second.launch(photoPiece) == nil, "nothing at the second open either")
    }

    @Test func replayingChapterSixWithoutAPhotoPieceIsThePlaceholderAndChangesNothing() throws {
        var tour = BuildTour()
        tour.readOpening(emptyRoom)
        let runSent = tour.send(.replay(.memories, barePiece))
        let run = try #require(runSent)
        #expect(!run.demonstrates)
        tour.end(.completed, barePiece)
        #expect(tour.outcome(.memories) == nil, "the placeholder card is not the chapter (§3.1.1 #10)")

        let realSent = tour.send(.replay(.memories, photoPiece))
        let real = try #require(realSent)
        #expect(real.demonstrates)
        tour.end(.completed, photoPiece)
        #expect(tour.outcome(.memories) == .completed, "read to its end by hand")
    }

    @Test func replayingChapterTwelveAlwaysDemonstrates() throws {
        var tour = BuildTour()
        tour.readOpening(emptyRoom)
        let runSent = tour.send(.replay(.company, emptyRoom))
        let run = try #require(runSent)
        #expect(run.demonstrates, "nothing is needed to start company")
    }

    @Test func theReplayListHasTheThreeNewChaptersInOrder() {
        let menu = TourMenu(catalog: t4Catalog, stored: .missing, snapshot: snap())
        #expect(menu.opening.map(\.id) == [.welcome, .bringPhoto, .furnishFirst, .play, .topRow])
        #expect(menu.onDemand.map(\.id) == [.memories, .moveAndLook, .company])
        #expect(menu.onDemand.allSatisfy { $0.status == .notYet })
    }

    @Test func aChapterLeftForTheCompanyPageCountsAsSeenInTheList() {
        var tour = BuildTour()
        tour.readOpening(emptyRoom)
        #expect(tour.arrive(snap { $0.surface = .companyPage }) == .company)
        tour.end(.completed, emptyRoom)
        let menu = TourMenu(catalog: t4Catalog, stored: .record(tour.machine.record), snapshot: snap())
        #expect(menu.onDemand.first { $0.id == .company }?.status == .seen)
        #expect(menu.onDemand.first { $0.id == .memories }?.status == .notYet)
    }
}
