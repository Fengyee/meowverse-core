import Foundation
import Testing
@testable import MeowverseCore

// The tour's record, its store, which chapter is due, and the order they come up in.
// Rules: docs/ONBOARDING_TOUR.md §0, docs/onboarding/PRODUCT_PLAN.md §3, docs/onboarding/TECH_DESIGN.md §4.

// MARK: - Helpers

private func snap(_ change: (inout TourSnapshot) -> Void = { _ in }) -> TourSnapshot {
    var snapshot = TourSnapshot()
    change(&snapshot)
    return snapshot
}

/// A record as an earlier run of the app left it.
private func record(
    opens: Int = 1, opening: TourOutcome? = .completed, _ others: [TourChapterID: TourOutcome] = [:],
    catalog: TourCatalog = .current
) -> TourRecord {
    var record = TourRecord()
    record.opens = opens
    if let opening {
        for chapter in catalog.opening { record.chapters[chapter.id.rawValue] = TourEntry(outcome: opening, revision: chapter.revision) }
    }
    for (id, outcome) in others { record.chapters[id.rawValue] = TourEntry(outcome: outcome, revision: 1) }
    return record
}

/// Drives the machine the way the app will, and keeps what it asked for.
private struct Tour {
    var machine: TourMachine
    var saved: [TourRecord] = []
    var started: [TourRun] = []

    init(catalog: TourCatalog = .current, settles: TourCatalog? = nil, stored: TourStored = .missing) {
        machine = TourMachine(catalog: catalog, settles: settles, stored: stored)
    }

    /// The run this event started, if it started one.
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

    /// A cold launch, then the room with nothing in the way.
    @discardableResult mutating func launch(_ snapshot: TourSnapshot) -> TourChapterID? {
        send(.opened(.launch, snapshot))
        return send(.arrived(snapshot))?.chapter
    }

    @discardableResult mutating func arrive(_ snapshot: TourSnapshot) -> TourChapterID? {
        send(.arrived(snapshot))?.chapter
    }

    /// Ends the chapter on screen. Returns the chapter that follows at once, if one does.
    @discardableResult mutating func end(_ exit: TourExit, _ snapshot: TourSnapshot) -> TourChapterID? {
        guard let run = machine.session.run else {
            Issue.record("no chapter is on screen")
            return nil
        }
        return send(.finished(run: run.id, exit, snapshot))?.chapter
    }

    /// The showing on screen.
    func showing() throws -> TourRun { try #require(machine.session.run, "no chapter is on screen") }

    /// Puts the chapter on screen away without an ending.
    mutating func putAway(_ reason: TourInterruption) {
        guard let run = machine.session.run else {
            Issue.record("no chapter is on screen")
            return
        }
        send(.interrupted(run: run.id, reason))
    }

    /// Reads each chapter to its end for as long as another follows at once. Bounded: a rule
    /// that sends the tour in circles must fail a test, not hang the run.
    mutating func readThrough(_ snapshot: TourSnapshot) {
        var turns = 0
        while machine.session.run != nil {
            guard turns < 20 else {
                Issue.record("the tour does not come to an end")
                return
            }
            end(.completed, snapshot)
            turns += 1
        }
    }

    var running: TourChapterID? { machine.session.run?.chapter }
    var chapters: [TourChapterID] { started.map(\.chapter) }
    func outcome(_ id: TourChapterID) -> TourOutcome? { machine.record.entry(for: id)?.outcome }
    /// What a relaunch would read back.
    var stored: TourStored { saved.last.map(TourStored.record) ?? .missing }
}

private let emptyHome = snap()
private let everyChapter = TourCatalog.current.chapters.map(\.id)
private let newFeature = TourChapter(id: TourChapterID("new-feature"), kind: .onDemand, audience: .everyone, surface: .room)

// MARK: - The record and where it is kept

@Suite struct OnboardingTourRecordTests {
    private func defaults() -> UserDefaults {
        let name = "OnboardingTourTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theCatalogNamesFifteenChaptersByWhatTheyAreAbout() {
        let catalog = TourCatalog.current
        #expect(catalog.chapters.count == 15)
        #expect(catalog.opening.map(\.id) == [.welcome, .bringPhoto, .furnishFirst, .play, .topRow])
        #expect(catalog.onDemand.count == 10)
        #expect(Set(everyChapter).count == 15, "ids are unique")
        for id in everyChapter {
            #expect(id.rawValue.rangeOfCharacter(from: .decimalDigits) == nil, "\(id): a number would tie the id to today's order")
            #expect(!id.rawValue.contains("."), "\(id): the dot separates a chapter from its step in text keys")
        }
        // Who each chapter is for: the opening is for newcomers only. The reminder invitation is
        // not: it depends on whether this device asked about reminders (PRODUCT_PLAN §3.1.1 #11).
        let newcomers = catalog.chapters.filter { $0.audience == .newcomer }.map(\.id)
        #expect(newcomers == [.welcome, .bringPhoto, .furnishFirst, .play, .topRow])
    }

    @Test func aRecordSurvivesTheStore() throws {
        var written = TourRecord()
        written.chapters["welcome"] = TourEntry(outcome: .completed, revision: 1)
        written.chapters["play"] = TourEntry(outcome: .skipped, revision: 2)
        written.chapters["backup"] = TourEntry(outcome: .skippedAll, revision: 1)
        written.chapters["top-row"] = TourEntry(outcome: .grandfathered, revision: 1)
        written.chapters["reminders"] = TourEntry(outcome: .notNeeded, revision: 1)
        written.interruptions["memories"] = 1
        written.opens = 4
        let stores: [any TourRecordStore] = [UserDefaultsTourRecordStore(defaults: defaults()), InMemoryTourRecordStore()]
        for store in stores {
            #expect(store.load(library: "Library") == .missing)
            store.save(written, library: "Library")
            #expect(store.load(library: "Library") == .record(written))
        }
        // The words on disk are part of the format: a later version reads them.
        let object = try #require(try JSONSerialization.jsonObject(with: try written.encoded()) as? [String: Any])
        let chapters = try #require(object["chapters"] as? [String: [String: Any]])
        #expect(chapters["welcome"]?["outcome"] as? String == "completed")
        #expect(chapters["play"]?["outcome"] as? String == "skipped")
        #expect(chapters["backup"]?["outcome"] as? String == "skippedAll")
        #expect(chapters["top-row"]?["outcome"] as? String == "grandfathered")
        #expect(chapters["reminders"]?["outcome"] as? String == "notNeeded")
        #expect(object["format"] as? Int == 1)
    }

    @Test func eachLibraryHasItsOwnRecord() {
        let suite = defaults()
        let store = UserDefaultsTourRecordStore(defaults: suite)
        let seen = record(opens: 3)
        store.save(seen, library: "Library")
        #expect(UserDefaultsTourRecordStore.key(library: "Library") == "tour.record.Library")
        #expect(suite.object(forKey: "tour.record.Library") != nil)
        #expect(store.load(library: "Test-other") == .missing, "a test library starts unseen")
        store.save(TourRecord(), library: "Test-other")
        store.remove(library: "Test-other")
        #expect(store.load(library: "Test-other") == .missing)
        #expect(store.load(library: "Library") == .record(seen), "clearing one library leaves the others")

        let memory = InMemoryTourRecordStore()
        memory.save(seen, library: "a")
        #expect(memory.load(library: "b") == .missing)
        memory.remove(library: "a")
        #expect(memory.load(library: "a") == .missing)
    }

    @Test func aFileFromBeforeANewerKeyStillReads() throws {
        // Every key but the chapters removed, and the entry without its revision.
        let old = Data(#"{"chapters":{"welcome":{"outcome":"completed"}}}"#.utf8)
        let read = try #require(TourRecord.decode(old))
        #expect(read.entry(for: .welcome) == TourEntry(outcome: .completed, revision: 1))
        #expect(read.format == 1)
        #expect(read.interruptions.isEmpty)
        #expect(read.opens == 0)
        #expect(TourRecord.decode(Data("{}".utf8)) == TourRecord(), "an empty object is an empty record")
    }

    @Test func chaptersAndOutcomesFromALaterVersionAreKeptAndWrittenBack() throws {
        let later = Data(#"""
        {"format":2,"opens":7,"chapters":{"hologram":{"outcome":"teleported","revision":3},"welcome":{"outcome":"completed","revision":1}}}
        """#.utf8)
        let store = InMemoryTourRecordStore()
        store.plant(later, library: "Library")
        guard case .record(let read) = store.load(library: "Library") else {
            Issue.record("a later version's record should still read")
            return
        }
        #expect(read.entry(for: TourChapterID("hologram")) == TourEntry(outcome: .other("teleported"), revision: 3))

        // This version goes on using it: the user skips a chapter here.
        var tour = Tour(stored: .record(read))
        tour.launch(snap { $0.hasFurnitureWithPhotos = true; $0.furnitureCount = 1; $0.roomIsEmpty = false })
        tour.end(.skipped, emptyHome)
        store.save(try #require(tour.saved.last), library: "Library")

        let bytes = try #require(store.raw(library: "Library"))
        let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let chapters = try #require(object["chapters"] as? [String: [String: Any]])
        #expect(chapters["hologram"]?["outcome"] as? String == "teleported")
        #expect(chapters["hologram"]?["revision"] as? Int == 3)
        #expect(chapters["welcome"]?["outcome"] as? String == "completed")
        #expect(object["format"] as? Int == 2, "the format it was written in is not lowered")
        #expect(object["opens"] as? Int == 8)
    }

    struct Damage: Sendable, CustomTestStringConvertible {
        var testDescription: String
        /// nil: nothing under the key.
        var value: (@Sendable () -> Any)?
        var reads: TourStored
    }

    static let damage: [Damage] = [
        Damage(testDescription: "no key at all", value: nil, reads: .missing),
        Damage(testDescription: "bytes that are not JSON", value: { Data([0xFF, 0x00, 0x13, 0x37]) }, reads: .unreadable),
        Damage(testDescription: "half a file", value: { Data(#"{"chapters":{"welcome":{"outco"#.utf8) }, reads: .unreadable),
        Damage(testDescription: "JSON of another shape", value: { Data("[1,2,3]".utf8) }, reads: .unreadable),
        Damage(testDescription: "an outcome that is not a word", value: { Data(#"{"chapters":{"welcome":{"outcome":7}}}"#.utf8) }, reads: .unreadable),
        Damage(testDescription: "a string where the data should be", value: { "completed" }, reads: .unreadable),
        Damage(testDescription: "a dictionary where the data should be", value: { ["welcome": true] }, reads: .unreadable),
        Damage(testDescription: "an empty record", value: { Data("{}".utf8) }, reads: .record(TourRecord())),
    ]

    @Test(arguments: damage)
    func aMissingOrDamagedRecordMeansNothingWasSeen(_ damage: Damage) {
        let suite = defaults()
        let key = UserDefaultsTourRecordStore.key(library: "Library")
        if let value = damage.value { suite.set(value(), forKey: key) }
        let store = UserDefaultsTourRecordStore(defaults: suite)
        let stored = store.load(library: "Library")
        #expect(stored == damage.reads)

        // Whatever was there, a newcomer in an empty home is greeted from the first chapter.
        var tour = Tour(stored: stored)
        #expect(tour.launch(emptyHome) == .welcome)
        for id in everyChapter { #expect(tour.outcome(id) == nil, "\(id) counts as not seen") }
    }

    @Test func whatCannotBeReadIsLeftAloneUntilThereIsAnOutcomeToWrite() {
        var tour = Tour(stored: .unreadable)
        #expect(tour.launch(emptyHome) == .welcome)
        #expect(tour.saved.isEmpty, "opening the app does not write over what a later version may still read")
        tour.end(.completed, emptyHome)
        #expect(tour.saved.last?.entry(for: .welcome)?.outcome == .completed)
        #expect(tour.saved.last?.opens == 1)

        // A missing record is simply started.
        var fresh = Tour(stored: .missing)
        fresh.send(.opened(.launch, emptyHome))
        #expect(fresh.saved.last?.opens == 1)
    }

    @Test func aDamagedRecordInAHomeThatIsNotEmptyReadsAsALongTimeUser() {
        var tour = Tour(stored: .unreadable)
        // Upgraded on the device that asked about reminders at the old first launch.
        let home = snap { $0.roomIsEmpty = false; $0.furnitureCount = 3; $0.answeredReminderSetup = true }
        #expect(tour.launch(home) == nil)
        #expect(tour.machine.record.isVeteran)
    }
}

// MARK: - The opening, for someone new

@Suite struct OnboardingTourOpeningTests {
    struct Walk: Sendable, CustomTestStringConvertible {
        var testDescription: String
        /// How the user leaves each chapter; `.completed` when not listed.
        var exits: [TourChapterID: TourExit] = [:]
        var roomHasCat = true
        /// The chapters that come up one after another without the user leaving the room.
        var comesUp: [TourChapterID]
    }

    static let walks: [Walk] = [
        Walk(testDescription: "reads every part", comesUp: [.welcome, .bringPhoto, .furnishFirst, .play, .topRow]),
        Walk(testDescription: "skips the greeting: the next part still follows", exits: [.welcome: .skipped],
             comesUp: [.welcome, .bringPhoto, .furnishFirst, .play, .topRow]),
        Walk(testDescription: "skips the photo part: no photo was picked, so furnishing first follows", exits: [.bringPhoto: .skipped],
             comesUp: [.welcome, .bringPhoto, .furnishFirst, .play, .topRow]),
        Walk(testDescription: "goes to pick a photo: the tour steps aside", exits: [.bringPhoto: .handedOff],
             comesUp: [.welcome, .bringPhoto]),
        Walk(testDescription: "goes to place a piece first: the tour steps aside", exits: [.furnishFirst: .handedOff],
             comesUp: [.welcome, .bringPhoto, .furnishFirst]),
        Walk(testDescription: "throws the toy: the rest waits for the room", exits: [.play: .handedOff],
             comesUp: [.welcome, .bringPhoto, .furnishFirst, .play]),
        Walk(testDescription: "no cat lives in this room: playing is passed over", roomHasCat: false,
             comesUp: [.welcome, .bringPhoto, .furnishFirst, .topRow]),
        Walk(testDescription: "skips everything on the first card", exits: [.welcome: .skippedAll], comesUp: [.welcome]),
        Walk(testDescription: "skips everything from a later part", exits: [.furnishFirst: .skippedAll],
             comesUp: [.welcome, .bringPhoto, .furnishFirst]),
    ]

    @Test(arguments: walks)
    func theOpeningRunsInOrder(_ walk: Walk) {
        let room = snap { $0.roomHasCat = walk.roomHasCat }
        var tour = Tour()
        tour.launch(room)
        var steps = 0
        while let chapter = tour.running, steps < 10 {
            tour.end(walk.exits[chapter] ?? .completed, room)
            steps += 1
        }
        #expect(tour.chapters == walk.comesUp)
        #expect(tour.started.allSatisfy { $0.mode == .auto })
    }

    @Test func whenEveryPartWasReadTheOpeningIsOverAndStaysOver() {
        var tour = Tour()
        tour.launch(emptyHome)
        tour.readThrough(emptyHome)
        for chapter in TourCatalog.current.opening { #expect(tour.outcome(chapter.id) == .completed) }
        #expect(TourRules.openingIsOver(catalog: .current, record: tour.machine.record))
        #expect(tour.arrive(emptyHome) == nil)

        // At the next launch the opening does not come back; the second open has its own chapter.
        var again = Tour(stored: tour.stored)
        #expect(again.launch(emptyHome) == .company)
        again.end(.completed, emptyHome)
        #expect(again.arrive(emptyHome) == nil)
        #expect(again.chapters == [.company])
    }

    @Test func skippingOnePartIsRememberedAsSkippedNotCompleted() {
        var tour = Tour()
        tour.launch(emptyHome)
        tour.end(.completed, emptyHome)
        tour.end(.skipped, emptyHome)
        #expect(tour.outcome(.welcome) == .completed)
        #expect(tour.outcome(.bringPhoto) == .skipped)
        #expect(tour.running == .furnishFirst)
    }

    @Test func comingBackWithAPhotoPieceTheMemoryChapterComesBeforeTheRestOfTheOpening() {
        var tour = Tour()
        tour.launch(emptyHome)
        tour.end(.completed, emptyHome)
        #expect(tour.end(.handedOff, emptyHome) == nil)
        #expect(tour.outcome(.bringPhoto) == .completed, "going to pick a photo is doing what the chapter asked")
        #expect(tour.outcome(.furnishFirst) == nil, "whether it still applies is seen when the user is back")

        let furnished = snap {
            $0.roomIsEmpty = false; $0.furnitureCount = 1
            $0.hasFurnitureWithPhotos = true; $0.hasMovableFurniture = true; $0.photoCount = 1
        }
        #expect(tour.arrive(furnished) == .memories)
        #expect(tour.end(.completed, furnished) == nil, "the rest of the opening waits for the next time the room is free")
        #expect(tour.arrive(furnished) == .play)
        #expect(tour.end(.completed, furnished) == .topRow)
        #expect(tour.end(.completed, furnished) == nil)
        #expect(tour.arrive(furnished) == .moveAndLook, "only now the other chapters")
        #expect(!tour.chapters.contains(.furnishFirst))
    }

    @Test func goingToPickAPhotoAndComingBackEmptyHandedLeadsToFurnishingFirst() {
        // PRODUCT_PLAN §3.1.1 #2: whoever cancels the picker most likely has no photo handy,
        // which is who "furnish first" was written for.
        var tour = Tour()
        tour.launch(emptyHome)
        tour.end(.completed, emptyHome)
        tour.end(.handedOff, emptyHome)
        // The picker was cancelled: the room is as empty as before, and there are no photos.
        #expect(tour.arrive(emptyHome) == .furnishFirst)
        #expect(tour.end(.completed, emptyHome) == .play)

        // Quit while the picker was up: the same after a relaunch.
        var quit = Tour()
        quit.launch(emptyHome)
        quit.end(.completed, emptyHome)
        quit.end(.handedOff, emptyHome)
        var relaunched = Tour(stored: quit.stored)
        #expect(relaunched.launch(emptyHome) == .furnishFirst)
    }

    @Test func comingBackWithPhotosNotYetPlacedPassesFurnishingFirstOverForGood() {
        var tour = Tour()
        tour.launch(emptyHome)
        tour.end(.completed, emptyHome)
        tour.end(.handedOff, emptyHome)
        // Photos came home and wait to be sorted; nothing is placed. "No good photo handy?" is
        // the wrong thing to say: the bar of photos to sort is theirs to see.
        let photosWaiting = snap { $0.photoCount = 2; $0.unsortedPhotoCount = 2 }
        #expect(tour.arrive(photosWaiting) == .play)
        #expect(tour.outcome(.furnishFirst) == nil, "passed over, not recorded")
        tour.end(.completed, photosWaiting)
        // Every photo deleted again: the opening does not turn back.
        tour.putAway(.blocked)
        #expect(tour.arrive(emptyHome) == .topRow)
    }

    @Test func someoneWhoBroughtPhotosBeforeMeetingBellaIsGreetedButNotAskedForAPhoto() {
        // PRODUCT_PLAN §3.1.1 #5: came in from outside the first time and added photos on their
        // own. They still meet Bella; the parts that ask for a first photo are passed over.
        var first = Tour()
        first.send(.opened(.launch, emptyHome))
        #expect(first.arrive(snap { $0.cameFromOutside = true }) == nil)
        let photos = snap { $0.photoCount = 3; $0.unsortedPhotoCount = 3 }
        var second = Tour(stored: first.stored)
        #expect(second.launch(photos) == .welcome)
        #expect(!second.machine.record.isVeteran, "the tour met this library while it was empty")
        #expect(second.end(.completed, photos) == .play)
        #expect(second.end(.completed, photos) == .topRow)
        #expect(second.outcome(.bringPhoto) == nil)
        #expect(second.outcome(.furnishFirst) == nil)
    }

    @Test func afterPlacingAPieceWithoutAPhotoTheOpeningGoesOnAtTheNextFreeRoom() {
        var tour = Tour()
        tour.launch(emptyHome)
        tour.end(.completed, emptyHome)
        tour.end(.completed, emptyHome)
        #expect(tour.end(.handedOff, emptyHome) == nil)
        let furnished = snap { $0.roomIsEmpty = false; $0.furnitureCount = 1; $0.hasMovableFurniture = true }
        #expect(tour.arrive(furnished) == .play, "a piece without photos has no memory to show")
        #expect(tour.end(.completed, furnished) == .topRow)
    }

    @Test func aPartThatEndsOnAnotherPageWaitsForTheRoomBeforeTheNextPart() {
        var tour = Tour()
        tour.launch(emptyHome)
        for _ in 0..<3 { tour.end(.completed, emptyHome) }
        #expect(tour.running == .play)
        // Its last step was read inside the interactions panel, which is still open.
        let panel = snap { $0.surface = .interactionPanel }
        #expect(tour.end(.completed, panel) == nil)
        #expect(tour.arrive(panel) == nil)
        #expect(tour.arrive(emptyHome) == .topRow)
    }

    @Test func pagesReachedDuringTheOpeningKeepTheirChaptersUntilItIsOver() {
        // A "do" step took the user to a page with its own chapter before the opening was over.
        let photos = snap { $0.photoCount = 2; $0.furnitureCount = 1; $0.roomIsEmpty = false }
        var tour = Tour()
        tour.launch(emptyHome)
        tour.end(.completed, emptyHome)
        tour.end(.handedOff, emptyHome)
        for surface in [TourSurface.photoLibrary, .furnitureLibrary, .companyPage] {
            #expect(tour.arrive(snap { $0 = photos; $0.surface = surface }) == nil, "\(surface)")
        }
        // Back in the room the opening goes on; once it is over the pages have their turn.
        #expect(tour.arrive(photos) == .play)
        tour.readThrough(photos)
        #expect(TourRules.openingIsOver(catalog: .current, record: tour.machine.record))
        #expect(tour.arrive(snap { $0 = photos; $0.surface = .photoLibrary }) == .photoLibrary)
        tour.end(.completed, photos)
        #expect(tour.arrive(snap { $0 = photos; $0.surface = .companyPage }) == .company)
    }

    @Test func aChapterCutShortByQuittingStartsAgainFromItsTop() {
        var tour = Tour()
        tour.launch(emptyHome)
        tour.end(.completed, emptyHome)
        #expect(tour.running == .bringPhoto)
        // The app is closed here. Only outcomes were kept.
        var relaunched = Tour(stored: tour.stored)
        #expect(relaunched.launch(emptyHome) == .bringPhoto)
        #expect(relaunched.outcome(.welcome) == .completed)
    }

    @Test func aPartThatDoesNotApplyWhenItsTurnComesIsNotBroughtBackLater() {
        // No cat in the room during the opening, a cat there afterwards.
        let noCat = snap { $0.roomHasCat = false }
        var tour = Tour()
        tour.launch(noCat)
        tour.readThrough(noCat)
        // Written down as not needed once the opening is over (QA_T5 must-fix 1), not left blank.
        #expect(tour.outcome(.play) == .notNeeded)
        #expect(TourRules.openingIsOver(catalog: .current, record: tour.machine.record))
        #expect(tour.arrive(emptyHome) == nil)
        var relaunched = Tour(stored: tour.stored)
        #expect(relaunched.launch(emptyHome) == .company, "the second open's own chapter, not the part that was passed over")
        relaunched.end(.completed, emptyHome)
        #expect(relaunched.arrive(emptyHome) == nil)
    }

    struct Wait: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var change: @Sendable (inout TourSnapshot) -> Void
    }

    static let waits: [Wait] = [
        Wait(testDescription: "the restore-from-iCloud offer is still on the card") { $0.restoreOfferPending = true },
        Wait(testDescription: "the user came in from a notification, quick action or widget") { $0.cameFromOutside = true },
        Wait(testDescription: "another page is open") { $0.surface = .furnitureLibrary },
    ]

    @Test(arguments: waits)
    func theOpeningWaits(_ wait: Wait) {
        var tour = Tour(stored: .missing)
        #expect(tour.launch(snap(wait.change)) == nil)
        #expect(tour.started.isEmpty)
        for chapter in TourCatalog.current.opening { #expect(tour.outcome(chapter.id) == nil, "waiting is not an outcome") }
        // Once it is out of the way the greeting comes.
        #expect(tour.send(.factsChanged(emptyHome))?.chapter == .welcome)
    }

    @Test func aRestoreOfferThatTurnsUpDuringTheGreetingHoldsTheRestBack() {
        var tour = Tour()
        #expect(tour.launch(emptyHome) == .welcome)
        // The iCloud listing came in late: the card now offers to restore.
        let offering = snap { $0.restoreOfferPending = true }
        #expect(tour.end(.completed, offering) == nil)
        #expect(tour.arrive(offering) == nil)
        // "No thanks": the room is the user's again.
        #expect(tour.arrive(emptyHome) == .bringPhoto)
    }

    @Test func skippingEverythingClosesEveryChapterOfToday() {
        var tour = Tour()
        tour.launch(emptyHome)
        tour.end(.skippedAll, emptyHome)
        for id in everyChapter { #expect(tour.outcome(id) == .skippedAll, "\(id)") }
        #expect(!tour.machine.record.isVeteran)

        // Nothing comes up on its own afterwards, whatever the home grows into.
        let full = snap {
            $0.roomIsEmpty = false; $0.furnitureCount = 5; $0.hasFurnitureWithPhotos = true
            $0.hasMovableFurniture = true; $0.hasPerchableFurniture = true; $0.photoCount = 40; $0.unsortedPhotoCount = 6
            $0.supportsAR = true
        }
        var later = Tour(stored: tour.stored)
        for _ in 0..<4 {
            #expect(later.launch(full) == nil)
            for surface in [TourSurface.interactionPanel, .companyPage, .photoLibrary, .furnitureLibrary] {
                #expect(later.arrive(snap { $0 = full; $0.surface = surface }) == nil)
            }
        }
    }

    @Test func aChapterAlreadySeenKeepsItsOutcomeWhenTheRestIsSkipped() {
        var tour = Tour()
        tour.launch(emptyHome)
        tour.end(.completed, emptyHome)
        tour.end(.skipped, emptyHome)
        tour.end(.skippedAll, emptyHome)
        #expect(tour.outcome(.welcome) == .completed)
        #expect(tour.outcome(.bringPhoto) == .skipped)
        #expect(tour.outcome(.furnishFirst) == .skippedAll)
        #expect(tour.outcome(.backup) == .skippedAll)
    }
}

// MARK: - Someone who had a home before the tour existed

@Suite struct OnboardingTourVeteranTests {
    private let home = snap {
        $0.roomIsEmpty = false; $0.furnitureCount = 4; $0.photoCount = 3
        $0.hasMovableFurniture = true
    }

    @Test func theOpeningIsWaivedTheFirstTimeTheTourMeetsAHomeThatIsNotEmpty() {
        var tour = Tour(stored: .missing)
        tour.send(.opened(.launch, home))
        #expect(tour.machine.record.isVeteran)
        for chapter in TourCatalog.current.opening { #expect(tour.outcome(chapter.id) == .grandfathered) }
        #expect(tour.outcome(.reminders) == nil, "whether they were asked about reminders is this device's to tell")
        for chapter in TourCatalog.current.chapters where chapter.audience == .everyone {
            #expect(tour.outcome(chapter.id) == nil, "\(chapter.id) is still to come")
        }
        #expect(tour.saved.last?.isVeteran == true, "kept: at the next launch the home alone would not tell")
        #expect(TourRules.openingIsOver(catalog: .current, record: tour.machine.record))
    }

    struct Library: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var change: @Sendable (inout TourSnapshot) -> Void
        var livedIn: Bool
    }

    /// Q-04 (docs/ONBOARDING_TOUR.md §9): a home is lived in when it has furniture or photos.
    /// A renamed cat or an extra room alone does not make one. `libraryIsEmpty` (the backup's
    /// notion of empty, which counts the cat's name) is set false in each to show it is not read.
    static let libraries: [Library] = [
        Library(testDescription: "pieces, no photos", change: { $0.furnitureCount = 2; $0.roomIsEmpty = false }, livedIn: true),
        Library(testDescription: "pieces only in the storage box", change: { $0.furnitureCount = 1 }, livedIn: true),
        Library(testDescription: "photos, no pieces", change: { $0.photoCount = 4; $0.unsortedPhotoCount = 4 }, livedIn: true),
        Library(testDescription: "only the cat's name or a room was changed", change: { _ in }, livedIn: false),
    ]

    @available(*, deprecated, message: "sets the field it shows is ignored")
    private static func asTheAppWouldReport(_ library: Library) -> TourSnapshot {
        snap { $0.libraryIsEmpty = false; library.change(&$0) }
    }

    @Test(arguments: libraries)
    @available(*, deprecated, message: "sets the field it shows is ignored")
    func aLongTimeUserIsOneWhoseLibraryHasFurnitureOrPhotos(_ library: Library) {
        let now = Self.asTheAppWouldReport(library)
        var tour = Tour(stored: .missing)
        let first = tour.launch(now)
        #expect(tour.machine.record.isVeteran == library.livedIn)
        #expect((first == .welcome) == !library.livedIn)

        // The same home restored from a backup while the opening is still to come.
        var restoring = Tour()
        restoring.launch(emptyHome)
        restoring.end(.completed, emptyHome)
        restoring.send(.libraryReplaced(now))
        #expect(restoring.machine.record.isVeteran == library.livedIn)
        #expect(restoring.outcome(.bringPhoto) == (library.livedIn ? .grandfathered : nil))
    }

    @Test func nothingComesUpBeforeTheOpenWasReported() {
        // The room is reported free before anyone looked at what the library holds.
        var tour = Tour(stored: .missing)
        #expect(tour.arrive(home) == nil)
        #expect(tour.arrive(emptyHome) == nil)
        #expect(tour.started.isEmpty)
        tour.send(.opened(.launch, home))
        #expect(tour.arrive(home) == .moveAndLook, "recognised as lived in: no greeting")
    }

    @Test func chaptersForFeaturesStillComeUpOnceEach() {
        var tour = Tour(stored: .missing)
        #expect(tour.launch(home) == .moveAndLook)
        tour.end(.completed, home)
        let withMemory = snap { $0 = home; $0.hasFurnitureWithPhotos = true }
        #expect(tour.arrive(withMemory) == .memories)
        tour.end(.completed, withMemory)

        // Upgraded on the device that asked about reminders at the old first launch.
        var relaunched = Tour(stored: tour.stored)
        #expect(relaunched.launch(snap { $0 = withMemory; $0.answeredReminderSetup = true }) == .company,
                "second open: the company chapter, not the two already seen")
        relaunched.end(.completed, withMemory)
        #expect(relaunched.arrive(snap { $0 = withMemory; $0.surface = .photoLibrary }) == .photoLibrary)
    }

    @Test(arguments: TourCatalog.current.chapters.filter { $0.audience == .newcomer }.map(\.id))
    func noChapterForNewcomersEverComesUp(_ id: TourChapterID) {
        let chapter = TourCatalog.current[id]!
        var tour = Tour(stored: .missing)
        for open in 1...5 {
            tour.send(.opened(.launch, home))
            #expect(tour.machine.record.opens == open)
            // With their pieces out, and with everything put away.
            for now in [home, snap { $0 = home; $0.roomIsEmpty = true; $0.furnitureCount = 0 }] {
                #expect(!TourRules.isDue(chapter, catalog: .current, record: tour.machine.record, session: tour.machine.session, snapshot: now))
                #expect(tour.arrive(now) != id)
                if tour.running != nil { tour.end(.completed, now) }
            }
        }
        #expect(!tour.chapters.contains(id))
    }

    @Test func someoneNewWhoseHomeFilledUpIsNotMistakenForALongTimeUser() {
        var first = Tour(stored: .missing)
        first.send(.opened(.launch, emptyHome))
        // They came in from outside this time, added a photo on their own, and left. No chapter was told.
        #expect(first.arrive(snap { $0.cameFromOutside = true }) == nil)
        var second = Tour(stored: first.stored)
        #expect(second.launch(home) == .welcome)
        #expect(!second.machine.record.isVeteran)
        // Photos are there and the room is not empty: the two parts that ask for a first photo
        // or a first piece have nothing to say when their turn comes.
        #expect(second.end(.completed, home) == .play)
        #expect(second.end(.completed, home) == .topRow)
        #expect(second.outcome(.bringPhoto) == nil)
        #expect(second.outcome(.furnishFirst) == nil)
    }

    @Test func restoringAHomeWhileTheOpeningIsStillToComeWaivesWhatIsLeftOfIt() throws {
        var tour = Tour()
        tour.launch(emptyHome)
        tour.end(.completed, emptyHome)
        let stale = try tour.showing()
        #expect(stale.chapter == .bringPhoto)

        tour.send(.libraryReplaced(home))
        #expect(tour.running == nil)
        #expect(tour.outcome(.welcome) == .completed, "what was seen stays as it was")
        for id in [TourChapterID.bringPhoto, .furnishFirst, .play, .topRow] {
            #expect(tour.outcome(id) == .grandfathered, "\(id)")
        }
        #expect(tour.saved.last?.entry(for: .topRow)?.outcome == .grandfathered)
        #expect(tour.outcome(.reminders) == nil, "PRODUCT_PLAN §3.1.1 #11: not waived with the opening")

        // The chapter that was on screen reports late: it changes nothing.
        let before = tour.machine.record
        #expect(tour.send(.finished(run: stale.id, .skipped, home)) == nil)
        #expect(tour.machine.record == before)
        #expect(tour.arrive(home) == .moveAndLook)
    }

    @Test func aHomeRestoredOnADeviceThatNeverAskedAboutRemindersIsStillInvited() {
        // A new device: the opening began, then a backup came back. Reminder switches live on
        // the device, not in the backup, so nobody here has asked yet (PRODUCT_PLAN §3.1.1 #11).
        var tour = Tour()
        tour.launch(emptyHome)
        tour.end(.completed, emptyHome)
        tour.send(.libraryReplaced(home))
        tour.arrive(home)
        tour.readThrough(home)

        var next = Tour(stored: tour.stored)
        #expect(next.launch(home) == .reminders)

        // The same, on the device where the old first launch already asked.
        var asked = Tour(stored: tour.stored)
        let answered = snap { $0 = home; $0.answeredReminderSetup = true }
        #expect(asked.launch(answered) != .reminders)
        #expect(asked.outcome(.reminders) == .notNeeded)
    }

    @Test func clearingTheHomeDoesNotTouchTheRecord() {
        var tour = Tour()
        tour.launch(emptyHome)
        tour.end(.completed, emptyHome)
        let before = tour.machine.record
        tour.send(.libraryReplaced(emptyHome))
        #expect(tour.machine.record == before)
        #expect(tour.running == nil)
        #expect(tour.arrive(emptyHome) == .bringPhoto, "the opening goes on where it was")
    }
}

// MARK: - Skipped everything, then a version with a new chapter

@Suite struct OnboardingTourNewChapterTests {
    struct Reader: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var kept: TourRecord
    }

    static let readers: [Reader] = {
        var skippedAll = TourRecord()
        skippedAll.opens = 1
        for id in everyChapter { skippedAll.chapters[id.rawValue] = TourEntry(outcome: .skippedAll, revision: 1) }
        var readAll = TourRecord()
        readAll.opens = 9
        for id in everyChapter { readAll.chapters[id.rawValue] = TourEntry(outcome: .completed, revision: 1) }
        var veteran = TourRecord()
        veteran.opens = 9
        for chapter in TourCatalog.current.chapters {
            veteran.chapters[chapter.id.rawValue] = TourEntry(outcome: chapter.audience == .newcomer ? .grandfathered : .completed, revision: 1)
        }
        return [
            Reader(testDescription: "skipped everything", kept: skippedAll),
            Reader(testDescription: "read everything", kept: readAll),
            Reader(testDescription: "long-time user", kept: veteran),
        ]
    }()

    private let home = snap {
        $0.roomIsEmpty = false; $0.furnitureCount = 5; $0.hasFurnitureWithPhotos = true
        $0.hasMovableFurniture = true; $0.hasPerchableFurniture = true; $0.photoCount = 40; $0.unsortedPhotoCount = 6
    }

    @Test(arguments: readers)
    func onlyTheNewChapterComesUpAndOnlyOnce(_ reader: Reader) {
        // The same version: nothing.
        var same = Tour(stored: .record(reader.kept))
        #expect(same.launch(home) == nil)

        // The next version adds one chapter.
        let next = TourCatalog.current.adding(newFeature)
        var tour = Tour(catalog: next, stored: .record(reader.kept))
        #expect(tour.launch(home) == newFeature.id)
        tour.end(.completed, home)
        #expect(tour.outcome(newFeature.id) == .completed)
        for id in everyChapter { #expect(tour.outcome(id) == reader.kept.entry(for: id)?.outcome, "\(id) is untouched") }

        var later = Tour(catalog: next, stored: tour.stored)
        for _ in 0..<3 { #expect(later.launch(home) == nil) }
        #expect(tour.chapters == [newFeature.id])
    }

    @Test(arguments: readers)
    func aNewChapterIsSkippedLikeAnyOther(_ reader: Reader) {
        let next = TourCatalog.current.adding(newFeature)
        var tour = Tour(catalog: next, stored: .record(reader.kept))
        tour.launch(home)
        tour.end(.skipped, home)
        var later = Tour(catalog: next, stored: tour.stored)
        #expect(later.launch(home) == nil)
        #expect(later.outcome(newFeature.id) == .skipped)
    }

    @Test func aChapterThatWasRevisedComesUpOnceMoreForThoseWhoSawTheOldOne() {
        var revised = TourCatalog.current
        let index = revised.chapters.firstIndex { $0.id == .backup }!
        revised.chapters[index].revision = 2
        for reader in Self.readers {
            var tour = Tour(catalog: revised, stored: .record(reader.kept))
            #expect(tour.launch(home) == .backup, "\(reader.testDescription)")
            tour.end(.completed, home)
            #expect(tour.machine.record.entry(for: .backup) == TourEntry(outcome: .completed, revision: 2))
            var later = Tour(catalog: revised, stored: tour.stored)
            #expect(later.launch(home) == nil)
        }
    }

    @Test func aRevisedOpeningChapterIsNotShownAgain() {
        var revised = TourCatalog.current
        revised.chapters[0].revision = 2
        revised.chapters[4].revision = 2
        for reader in Self.readers {
            var tour = Tour(catalog: revised, stored: .record(reader.kept))
            #expect(tour.launch(home) == nil, "\(reader.testDescription): the opening is told once")
        }
    }

    @Test func aNewChapterMeantForNewcomersPassesLongTimeUsersBy() {
        let forNewcomers = TourChapter(id: TourChapterID("first-steps"), kind: .onDemand, audience: .newcomer, surface: .room)
        let next = TourCatalog.current.adding(forNewcomers)
        for reader in Self.readers {
            var tour = Tour(catalog: next, stored: .record(reader.kept))
            let comesUp = tour.launch(home)
            #expect(comesUp == (reader.kept.isVeteran ? nil : forNewcomers.id), "\(reader.testDescription)")
        }
    }

    @Test func aPartAddedToTheOpeningLaterIsToldToNewcomersOnly() {
        let added = TourChapter(id: TourChapterID("house-rules"), kind: .opening, audience: .newcomer, surface: .room)
        let next = TourCatalog.current.adding(added)
        for reader in Self.readers {
            var tour = Tour(catalog: next, stored: .record(reader.kept))
            let comesUp = tour.launch(home)
            if reader.kept.isVeteran {
                #expect(comesUp == nil)
                #expect(TourRules.openingIsOver(catalog: next, record: tour.machine.record), "for them the opening stays over")
            } else {
                #expect(comesUp == added.id, "\(reader.testDescription)")
                tour.end(.completed, home)
                #expect(TourRules.openingIsOver(catalog: next, record: tour.machine.record))
            }
        }
    }

    @Test func skippingEverythingLeavesAnOpeningPartAsItWasSeenEvenIfItWasRevisedSince() {
        var revised = TourCatalog.current
        revised.chapters[0].revision = 2
        // Read the whole opening in the old version; skips everything from a feature chapter's card now.
        var tour = Tour(catalog: revised, stored: .record(record(opens: 3)))
        #expect(tour.launch(home) == .memories)
        tour.end(.skippedAll, home)
        #expect(tour.machine.record.entry(for: .welcome) == TourEntry(outcome: .completed, revision: 1))
        #expect(tour.outcome(.memories) == .skippedAll)
        #expect(tour.outcome(.backup) == .skippedAll)
    }

    @Test func anOldRecordThatSaysQuietNoLongerKeepsChaptersAway() throws {
        // Earlier builds wrote a `quiet` key that nothing ever set. It is no longer a switch
        // (PRODUCT_PLAN §3.1.1 #8): a mute nobody can see or undo would only hide the tour when a
        // record goes wrong. The record still reads, and the key is not written back.
        for quiet in [true, false] {
            // Someone who skipped everything, as an earlier build wrote it.
            var object = try #require(try JSONSerialization.jsonObject(with: try Self.readers[0].kept.encoded()) as? [String: Any])
            object["quiet"] = quiet
            let old = try JSONSerialization.data(withJSONObject: object)
            let read = try #require(TourRecord.decode(old), "quiet: \(quiet)")
            #expect(read == Self.readers[0].kept)
            var tour = Tour(catalog: TourCatalog.current.adding(newFeature), stored: .record(read))
            #expect(tour.launch(home) == newFeature.id, "quiet: \(quiet)")
            let written = String(decoding: try tour.machine.record.encoded(), as: UTF8.self)
            #expect(!written.contains("quiet"), "\(written)")
        }
    }
}

// MARK: - Which feature chapter is due

@Suite struct OnboardingTourEligibilityTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var chapter: TourChapterID
        var note: String
        var opens = 1
        var opening: TourOutcome? = .completed
        var seen: [TourChapterID: TourOutcome] = [:]
        var change: @Sendable (inout TourSnapshot) -> Void
        var due: Bool
        var testDescription: String { "\(chapter): \(note) → \(due ? "due" : "not due")" }
    }

    static let cases: [Case] = [
        Case(chapter: .memories, note: "a piece with photos", change: { $0.hasFurnitureWithPhotos = true }, due: true),
        Case(chapter: .memories, note: "only pieces without photos", change: { $0.furnitureCount = 2 }, due: false),
        Case(chapter: .memories, note: "a piece with photos, another page open", change: { $0.hasFurnitureWithPhotos = true; $0.surface = .photoLibrary }, due: false),
        Case(chapter: .memories, note: "a piece with photos, before the greeting", opening: nil, change: { $0.hasFurnitureWithPhotos = true }, due: false),

        Case(chapter: .moveAndLook, note: "a piece that can move", change: { $0.hasMovableFurniture = true }, due: true),
        Case(chapter: .moveAndLook, note: "every piece locked", change: { $0.furnitureCount = 2 }, due: false),

        Case(chapter: .photoBatch, note: "photos waiting to be sorted", change: { $0.unsortedPhotoCount = 3 }, due: true),
        Case(chapter: .photoBatch, note: "the import still running", change: { $0.unsortedPhotoCount = 3; $0.importRunning = true }, due: false),
        Case(chapter: .photoBatch, note: "nothing waiting", change: { $0.photoCount = 20 }, due: false),

        Case(chapter: .photoLibrary, note: "the library opened, one photo", change: { $0.surface = .photoLibrary; $0.photoCount = 1 }, due: true),
        Case(chapter: .photoLibrary, note: "the library opened, empty", change: { $0.surface = .photoLibrary }, due: false),
        Case(chapter: .photoLibrary, note: "in the room", change: { $0.photoCount = 1 }, due: false),

        Case(chapter: .furnitureLibrary, note: "the list opened, one piece", change: { $0.surface = .furnitureLibrary; $0.furnitureCount = 1 }, due: true),
        Case(chapter: .furnitureLibrary, note: "the list opened, empty", change: { $0.surface = .furnitureLibrary }, due: false),
        Case(chapter: .furnitureLibrary, note: "in the room", change: { $0.furnitureCount = 1 }, due: false),

        Case(chapter: .sendCat, note: "the panel opened, a piece the cat can get on", change: { $0.surface = .interactionPanel; $0.hasPerchableFurniture = true }, due: true),
        Case(chapter: .sendCat, note: "the panel opened, nothing to get on", change: { $0.surface = .interactionPanel }, due: false),
        Case(chapter: .sendCat, note: "the panel opened during the opening", opening: nil, change: { $0.surface = .interactionPanel; $0.hasPerchableFurniture = true }, due: false),
        Case(chapter: .sendCat, note: "in the room", change: { $0.hasPerchableFurniture = true }, due: false),

        Case(chapter: .tabletop, note: "the panel opened again after the furniture chapter", seen: [.sendCat: .completed],
             change: { $0.surface = .interactionPanel; $0.supportsAR = true; $0.hasPerchableFurniture = true }, due: true),
        Case(chapter: .tabletop, note: "the furniture chapter still to come",
             change: { $0.surface = .interactionPanel; $0.supportsAR = true; $0.hasPerchableFurniture = true }, due: false),
        Case(chapter: .tabletop, note: "the furniture chapter cannot be told here",
             change: { $0.surface = .interactionPanel; $0.supportsAR = true }, due: true),
        Case(chapter: .tabletop, note: "no AR on this device", seen: [.sendCat: .completed],
             change: { $0.surface = .interactionPanel }, due: false),
        Case(chapter: .tabletop, note: "the camera was turned off for the app", seen: [.sendCat: .completed],
             change: { $0.surface = .interactionPanel; $0.supportsAR = true; $0.cameraDenied = true }, due: false),
        Case(chapter: .tabletop, note: "the panel opened during the opening", opening: nil,
             change: { $0.surface = .interactionPanel; $0.supportsAR = true }, due: false),

        Case(chapter: .company, note: "first open, in the room", opens: 1, change: { _ in }, due: false),
        Case(chapter: .company, note: "second open, in the room", opens: 2, change: { _ in }, due: true),
        Case(chapter: .company, note: "second open, the opening not over", opens: 2, opening: nil, change: { _ in }, due: false),
        Case(chapter: .company, note: "first open, the user found the company page", opens: 1, change: { $0.surface = .companyPage }, due: true),

        // PRODUCT_PLAN §3.1.1 #4: until the opening is over only the first memory may come up,
        // wherever the user went in a "do" step. Mid-opening: the greeting was read, the rest is to come.
        Case(chapter: .memories, note: "a piece with photos, mid-opening", opening: nil, seen: [.welcome: .completed],
             change: { $0.hasFurnitureWithPhotos = true }, due: true),
        Case(chapter: .photoLibrary, note: "the library opened mid-opening", opening: nil, seen: [.welcome: .completed],
             change: { $0.surface = .photoLibrary; $0.photoCount = 1 }, due: false),
        Case(chapter: .furnitureLibrary, note: "the list opened mid-opening", opening: nil, seen: [.welcome: .completed],
             change: { $0.surface = .furnitureLibrary; $0.furnitureCount = 1 }, due: false),
        Case(chapter: .company, note: "the user found the company page mid-opening", opens: 1, opening: nil, seen: [.welcome: .completed],
             change: { $0.surface = .companyPage }, due: false),
        Case(chapter: .company, note: "the user found the company page before the greeting", opens: 1, opening: nil,
             change: { $0.surface = .companyPage }, due: false),
        Case(chapter: .moveAndLook, note: "a piece that can move, mid-opening", opening: nil, seen: [.welcome: .completed],
             change: { $0.hasMovableFurniture = true }, due: false),
        Case(chapter: .photoBatch, note: "photos waiting, mid-opening", opening: nil, seen: [.welcome: .completed],
             change: { $0.unsortedPhotoCount = 3 }, due: false),
        Case(chapter: .backup, note: "ten photos, mid-opening", opening: nil, seen: [.welcome: .completed],
             change: { $0.photoCount = 10 }, due: false),

        Case(chapter: .backup, note: "ten photos", change: { $0.photoCount = 10 }, due: true),
        Case(chapter: .backup, note: "nine photos", change: { $0.photoCount = 9 }, due: false),

        Case(chapter: .backup, note: "ten photos, already read", seen: [.backup: .completed], change: { $0.photoCount = 10 }, due: false),
        Case(chapter: .backup, note: "ten photos, already skipped", seen: [.backup: .skipped], change: { $0.photoCount = 10 }, due: false),
        Case(chapter: .backup, note: "ten photos, an outcome this version does not know", seen: [.backup: .other("teleported")], change: { $0.photoCount = 10 }, due: false),
    ]

    @Test(arguments: cases)
    func aFeatureChapterIsDueOnlyWhenThereIsSomethingToShow(_ test: Case) {
        let chapter = TourCatalog.current[test.chapter]!
        let kept = record(opens: test.opens, opening: test.opening, test.seen)
        let now = snap(test.change)
        let due = TourRules.isDue(chapter, catalog: .current, record: kept, session: TourSession(), snapshot: now)
        #expect(due == test.due)
    }

    @Test func whatCanBeShownByHandDependsOnlyOnTheHomeAndTheDevice() {
        let catalog = TourCatalog.current
        let empty = snap { $0.roomHasCat = false }
        let canShow = catalog.chapters.filter { TourRules.canDemonstrate($0, snapshot: empty) }.map(\.id)
        // Chapter 15 only points at the gear: opened by hand it needs no photos (LINES.md T5.14).
        #expect(canShow == [.welcome, .bringPhoto, .furnishFirst, .topRow, .company, .reminders, .backup])
        // A replay shows the "once you have furniture" card exactly when this says no.
        for chapter in catalog.chapters where TourRules.isOnThisDevice(chapter, snapshot: empty) {
            var tour = Tour()
            let run = tour.send(.replay(chapter.id, empty))
            #expect(run?.demonstrates == canShow.contains(chapter.id), "\(chapter.id)")
        }
        #expect(!TourRules.isOnThisDevice(catalog[.tabletop]!, snapshot: empty), "no AR: the chapter is not even listed")
        let full = snap {
            $0.furnitureCount = 2; $0.hasFurnitureWithPhotos = true; $0.hasMovableFurniture = true; $0.hasPerchableFurniture = true
            $0.photoCount = 10; $0.unsortedPhotoCount = 1; $0.supportsAR = true
        }
        #expect(catalog.chapters.allSatisfy { TourRules.canDemonstrate($0, snapshot: full) && TourRules.isOnThisDevice($0, snapshot: full) })
    }
}

// MARK: - The reminder invitation (chapter 14)

@Suite struct OnboardingTourReminderTimingTests {
    enum Reader: Sendable { case openingOver, midOpening, veteran, alreadyTold }

    struct Case: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var reader = Reader.openingOver
        /// Each time the app comes to the front after the first open, and how many pieces the home had then.
        var opens: [(TourOpening, pieces: Int)]
        /// The home when the room is next free.
        var pieces: Int
        var change: @Sendable (inout TourSnapshot) -> Void = { _ in }
        var due: Bool
    }

    static let halfHour: TimeInterval = 30 * 60

    static let cases: [Case] = [
        Case(testDescription: "the first piece has just been placed: not on the spot",
             opens: [], pieces: 1, due: false),
        Case(testDescription: "the first piece was placed, the app restarted",
             opens: [(.launch, 1)], pieces: 1, due: true),
        Case(testDescription: "the first piece was placed, back after 30 minutes away",
             opens: [(.returned(awayFor: halfHour), 1)], pieces: 1, due: true),
        Case(testDescription: "the first piece was placed, back after 29 minutes 59 seconds",
             opens: [(.returned(awayFor: halfHour - 1), 1)], pieces: 1, due: false),
        Case(testDescription: "the piece is in the storage box, the room empty",
             opens: [(.launch, 1)], pieces: 1, change: { $0.roomIsEmpty = true }, due: true),
        Case(testDescription: "restarted, and the first piece placed only after that",
             opens: [(.launch, 0)], pieces: 1, due: false),
        Case(testDescription: "restarted, the first piece placed after that, then a short trip away",
             opens: [(.launch, 0), (.returned(awayFor: 60), 1)], pieces: 1, due: false),
        Case(testDescription: "never a piece, second open",
             opens: [(.launch, 0)], pieces: 0, due: false),
        Case(testDescription: "never a piece, third open",
             opens: [(.launch, 0), (.launch, 0)], pieces: 0, due: true),
        Case(testDescription: "never a piece, third open reached by coming back after an hour",
             opens: [(.launch, 0), (.returned(awayFor: 3600), 0)], pieces: 0, due: true),
        Case(testDescription: "never a piece, short trips away are not opens",
             opens: [(.launch, 0), (.returned(awayFor: 60), 0), (.returned(awayFor: 600), 0)], pieces: 0, due: false),
        Case(testDescription: "third open, and the first piece placed only now: still not on the spot",
             opens: [(.launch, 0), (.launch, 0)], pieces: 1, due: false),
        Case(testDescription: "never a piece, fourth open",
             opens: [(.launch, 0), (.launch, 0), (.launch, 0)], pieces: 0, due: true),
        Case(testDescription: "notifications were turned off in the system settings",
             opens: [(.launch, 1)], pieces: 1, change: { $0.notificationsDenied = true }, due: false),
        Case(testDescription: "a reminder is already on",
             opens: [(.launch, 1)], pieces: 1, change: { $0.anyReminderOn = true }, due: false),
        Case(testDescription: "another page is open",
             opens: [(.launch, 1)], pieces: 1, change: { $0.surface = .furnitureLibrary }, due: false),
        Case(testDescription: "the opening is not over, a piece from last time",
             reader: .midOpening, opens: [(.launch, 1)], pieces: 1, due: false),
        Case(testDescription: "the opening is not over, never a piece, third open",
             reader: .midOpening, opens: [(.launch, 0), (.launch, 0)], pieces: 0, due: false),
        // PRODUCT_PLAN §3.1.1 #11 and chapter 14 condition 5: what counts is whether this device
        // answered the old reminder setup page, not whether the home is an old one.
        Case(testDescription: "this device answered the old reminder page",
             opens: [(.launch, 1)], pieces: 1, change: { $0.answeredReminderSetup = true }, due: false),
        Case(testDescription: "this device answered the old reminder page, never a piece, third open",
             opens: [(.launch, 0), (.launch, 0)], pieces: 0, change: { $0.answeredReminderSetup = true }, due: false),
        Case(testDescription: "a long-time user upgraded on the device that asked them",
             reader: .veteran, opens: [(.launch, 3), (.launch, 3)], pieces: 3, change: { $0.answeredReminderSetup = true }, due: false),
        Case(testDescription: "a long-time user's home on a device that never asked",
             reader: .veteran, opens: [(.launch, 3)], pieces: 3, due: true),
        Case(testDescription: "a long-time user who put everything away, on a device that never asked, third open",
             reader: .veteran, opens: [(.launch, 0), (.launch, 0)], pieces: 0, due: true),
        Case(testDescription: "already told",
             reader: .alreadyTold, opens: [(.launch, 1)], pieces: 1, due: false),
    ]

    private func kept(_ reader: Reader) -> TourRecord {
        switch reader {
        case .openingOver: return record(opens: 1)
        case .midOpening:
            var kept = record(opens: 1, opening: nil)
            kept.chapters["welcome"] = TourEntry(outcome: .completed, revision: 1)
            return kept
        case .veteran:
            return record(opens: 1, opening: .grandfathered)
        case .alreadyTold: return record(opens: 1, [.reminders: .completed])
        }
    }

    @Test(arguments: cases)
    func theInvitationComesWhenTheAppIsOpenedAgainAfterTheFirstPiece(_ test: Case) {
        // Still in the first open, where the opening was read in an empty home.
        var tour = Tour(stored: .record(kept(test.reader)))
        #expect(tour.machine.record.opens == 1)
        for (opening, pieces) in test.opens {
            tour.send(.opened(opening, snap { $0.furnitureCount = pieces; $0.roomIsEmpty = pieces == 0 }))
        }
        let now = snap {
            $0.furnitureCount = test.pieces; $0.roomIsEmpty = test.pieces == 0
            test.change(&$0)
        }
        let chapter = TourCatalog.current[.reminders]!
        let due = TourRules.isDue(chapter, catalog: .current, record: tour.machine.record, session: tour.machine.session, snapshot: now)
        #expect(due == test.due)
    }

    @Test func theInvitationIsOfferedThroughTheMachineAndOnlyOnce() {
        var first = Tour()
        first.launch(emptyHome)
        first.readThrough(emptyHome)
        // A piece without photos is placed in the same sitting.
        let furnished = snap { $0.roomIsEmpty = false; $0.furnitureCount = 1 }
        #expect(first.arrive(furnished) == nil, "not on the spot")

        var second = Tour(stored: first.stored)
        #expect(second.launch(furnished) == .reminders, "ahead of the company chapter, which is also due at a second open")
        second.end(.handedOff, furnished)
        #expect(second.outcome(.reminders) == .completed)

        var third = Tour(stored: second.stored)
        #expect(third.launch(furnished) == .company)
        #expect(!third.chapters.contains(.reminders))
    }

    @Test func afterTheHomeWasClearedAPiecePlacedInTheSameSittingIsAFirstPieceAgain() throws {
        let furnished = snap { $0.roomIsEmpty = false; $0.furnitureCount = 1 }
        let chapter = try #require(TourCatalog.current[.reminders])
        var tour = Tour(stored: .record(record(opens: 1)))
        tour.send(.opened(.launch, furnished))
        #expect(TourRules.isDue(chapter, catalog: .current, record: tour.machine.record, session: tour.machine.session, snapshot: furnished))
        tour.send(.libraryReplaced(emptyHome))
        #expect(!TourRules.isDue(chapter, catalog: .current, record: tour.machine.record, session: tour.machine.session, snapshot: furnished))
    }

    @Test func comingInFromOutsidePutsTheInvitationOffToTheNextOpen() {
        let furnished = snap { $0.roomIsEmpty = false; $0.furnitureCount = 1 }
        var tour = Tour(stored: .record(record(opens: 1)))
        #expect(tour.launch(snap { $0 = furnished; $0.cameFromOutside = true }) == nil)
        tour.send(.opened(.returned(awayFor: 3600), furnished))
        #expect(tour.arrive(furnished) == .reminders)
    }

    @Test func someoneWhoTurnedARemindOnThemselvesIsNeverAsked() {
        let furnished = snap { $0.roomIsEmpty = false; $0.furnitureCount = 1 }
        var tour = Tour(stored: .record(record(opens: 1)))
        #expect(tour.launch(snap { $0 = furnished; $0.anyReminderOn = true }) == .company)
        #expect(tour.outcome(.reminders) == .notNeeded)
        #expect(tour.saved.last?.entry(for: .reminders)?.outcome == .notNeeded)
        tour.end(.completed, furnished)

        // They turn every reminder off again later: still not asked.
        var later = Tour(stored: tour.stored)
        #expect(later.launch(furnished) == nil)
    }

    @Test func aDeviceThatAnsweredTheOldReminderPageRecordsTheInvitationAsNotNeeded() {
        // An upgrade: the home is an old one and this device asked at the old first launch.
        let upgraded = snap { $0.roomIsEmpty = false; $0.furnitureCount = 2; $0.answeredReminderSetup = true }
        var tour = Tour(stored: .missing)
        tour.launch(upgraded)
        #expect(tour.outcome(.reminders) == .notNeeded)
        #expect(tour.saved.last?.entry(for: .reminders)?.outcome == .notNeeded, "kept")

        // An ending the user chose is not overwritten when the flag turns up later.
        let furnished = snap { $0.roomIsEmpty = false; $0.furnitureCount = 1 }
        var skipped = Tour(stored: .record(record(opens: 1)))
        #expect(skipped.launch(furnished) == .reminders)
        skipped.end(.skipped, furnished)
        skipped.arrive(snap { $0 = furnished; $0.answeredReminderSetup = true })
        #expect(skipped.outcome(.reminders) == .skipped)
    }
}

// MARK: - One chapter at a time

@Suite struct OnboardingTourOneAtATimeTests {
    /// Every room chapter is due at once.
    private let home = snap {
        $0.roomIsEmpty = false; $0.furnitureCount = 5; $0.hasFurnitureWithPhotos = true
        $0.hasMovableFurniture = true; $0.photoCount = 40; $0.unsortedPhotoCount = 6
    }

    @Test func chaptersComeUpInTheAgreedOrderOnePerVisitTwoPerOpen() {
        var tour = Tour(stored: .record(record(opens: 1)))
        var order: [[TourChapterID]] = []
        for open in 0..<4 {
            tour.send(.opened(open == 0 ? .launch : .returned(awayFor: 45 * 60), home))
            var told: [TourChapterID] = []
            // The room becomes free five times during this open.
            for _ in 0..<5 {
                guard let chapter = tour.arrive(home) else { continue }
                told.append(chapter)
                #expect(tour.send(.factsChanged(home)) == nil, "nothing else while one is on screen")
                #expect(tour.arrive(home) == nil, "not even after leaving and coming back")
                tour.end(.completed, home)
                #expect(tour.send(.factsChanged(home)) == nil, "the next one waits for another visit")
            }
            order.append(told)
        }
        #expect(order == [[.memories, .moveAndLook], [.reminders, .company], [.photoBatch, .backup], []])
        #expect(tour.started.count == 6)
    }

    @Test func aShortTripAwayDoesNotBringAThirdChapter() {
        var tour = Tour(stored: .record(record(opens: 1)))
        #expect(tour.launch(home) == .memories)
        tour.end(.completed, home)
        #expect(tour.arrive(home) == .moveAndLook)
        tour.end(.completed, home)
        #expect(tour.arrive(home) == nil)
        tour.send(.opened(.returned(awayFor: 29 * 60), home))
        #expect(tour.arrive(home) == nil, "the same open")
        tour.send(.opened(.returned(awayFor: 30 * 60), home))
        #expect(tour.arrive(home) == .reminders, "a new open")
    }

    @Test func chaptersOpenedOnTheirOwnPagesCountTowardsTheSameTwo() {
        var tour = Tour(stored: .record(record(opens: 1)))
        #expect(tour.launch(home) == .memories)
        tour.end(.completed, home)
        let library = snap { $0 = home; $0.surface = .photoLibrary }
        #expect(tour.arrive(library) == .photoLibrary)
        tour.end(.completed, library)
        #expect(tour.arrive(snap { $0 = home; $0.surface = .furnitureLibrary }) == nil)
        #expect(tour.arrive(home) == nil)
    }

    @Test func aChapterThatWasPutAwayAndComesBackDoesNotUseASecondTurn() {
        var tour = Tour(stored: .record(record(opens: 1)))
        #expect(tour.launch(home) == .memories)
        tour.end(.completed, home)
        #expect(tour.arrive(home) == .moveAndLook)
        // A sheet stayed in the way too long: the chapter is put away without an outcome.
        tour.putAway(.blocked)
        #expect(tour.running == nil)
        #expect(tour.outcome(.moveAndLook) == nil)
        #expect(tour.arrive(home) == .moveAndLook, "it already was this open's second chapter, so it may come back")
        tour.end(.completed, home)
        #expect(tour.arrive(home) == nil, "but not a third one")
    }

    @Test func theRuleItselfRefusesASecondChapterWhileOneIsOnScreen() {
        var tour = Tour(stored: .record(record(opens: 1)))
        #expect(tour.launch(home) == .memories)
        // Whatever the visit says, a chapter on screen is enough to refuse.
        var session = tour.machine.session
        session.toldThisVisit = false
        #expect(TourRules.offer(catalog: .current, record: tour.machine.record, session: session, snapshot: home) == nil)
        session.run = nil
        #expect(TourRules.offer(catalog: .current, record: tour.machine.record, session: session, snapshot: home) == .memories)
    }

    @Test func theOpeningDoesNotUseUpTheTwoTurns() {
        var tour = Tour()
        tour.launch(emptyHome)
        tour.readThrough(emptyHome)
        #expect(tour.chapters.count == 5)
        #expect(tour.arrive(home) == .memories)
        tour.end(.completed, home)
        #expect(tour.arrive(home) == .moveAndLook)
    }

    @Test func aLateCallbackFromAChapterThatIsOverChangesNothing() throws {
        var tour = Tour()
        tour.launch(emptyHome)
        let greeting = try tour.showing()
        tour.end(.skipped, emptyHome)
        #expect(tour.running == .bringPhoto)
        let before = tour.machine
        let saves = tour.saved.count

        // The greeting's last step reports "finished" after the user had already skipped it.
        #expect(tour.send(.finished(run: greeting.id, .completed, emptyHome)) == nil)
        #expect(tour.send(.finished(run: greeting.id, .skippedAll, emptyHome)) == nil)
        #expect(tour.send(.interrupted(run: greeting.id, .outsideRequest)) == nil)
        #expect(tour.machine == before)
        #expect(tour.saved.count == saves)
        #expect(tour.outcome(.welcome) == .skipped, "the user's choice stands")
        #expect(tour.running == .bringPhoto)
        #expect(tour.machine.session.run?.id != greeting.id, "each run has its own token")
    }

    @Test func beingCalledAwayTwiceClosesTheChapter() {
        var tour = Tour(stored: .record(record(opens: 1)))
        #expect(tour.launch(home) == .memories)
        tour.putAway(.outsideRequest)
        #expect(tour.outcome(.memories) == nil, "once is not an outcome")
        #expect(tour.machine.record.interruptions["memories"] == 1)
        #expect(tour.saved.last?.interruptions["memories"] == 1)

        var again = Tour(stored: tour.stored)
        #expect(again.launch(home) == .memories, "it comes up again")
        again.putAway(.outsideRequest)
        #expect(again.outcome(.memories) == .skipped)
        #expect(again.machine.record.interruptions["memories"] == nil)

        var after = Tour(stored: again.stored)
        #expect(after.launch(home) == .moveAndLook)
        #expect(!after.chapters.contains(.memories))
    }

    @Test(arguments: [TourInterruption.blocked, .accessibilityChanged])
    func beingPutAwayForOtherReasonsNeverClosesAChapter(_ reason: TourInterruption) {
        var tour = Tour(stored: .record(record(opens: 1)))
        tour.send(.opened(.launch, home))
        for _ in 0..<4 {
            #expect(tour.arrive(home) == .memories)
            tour.putAway(reason)
        }
        #expect(tour.outcome(.memories) == nil)
        #expect(tour.machine.record.interruptions.isEmpty)
    }

    @Test func aNewOpenPutsAwayAChapterLeftOnScreen() throws {
        var tour = Tour(stored: .record(record(opens: 1)))
        #expect(tour.launch(home) == .memories)
        let left = try tour.showing()
        tour.send(.opened(.returned(awayFor: 2 * 3600), home))
        #expect(tour.running == nil)
        #expect(tour.send(.finished(run: left.id, .completed, home)) == nil)
        #expect(tour.outcome(.memories) == nil)
        #expect(tour.arrive(home) == .memories)
    }
}

@Suite struct OnboardingTourOpenCountTests {
    @Test(arguments: [
        (TourOpening.launch, true),
        (.returned(awayFor: 30 * 60), true),
        (.returned(awayFor: 30 * 60 - 1), false),
        (.returned(awayFor: 0), false),
        (.returned(awayFor: 86_400), true),
    ])
    func anOpenIsALaunchOrAReturnAfterHalfAnHour(_ opening: TourOpening, _ counts: Bool) {
        #expect(TourRules.isNewOpen(opening) == counts)
        var tour = Tour(stored: .record(record(opens: 4)))
        tour.send(.opened(.launch, emptyHome))
        let saves = tour.saved.count
        tour.send(.opened(opening, emptyHome))
        #expect(tour.machine.record.opens == (counts ? 6 : 5))
        #expect(tour.saved.count == (counts ? saves + 1 : saves), "the count is kept: the third open may be days later")
        #expect(tour.saved.last?.opens == tour.machine.record.opens)
    }
}

// MARK: - Looking again by hand

@Suite struct OnboardingTourReplayTests {
    private let home = snap {
        $0.roomIsEmpty = false; $0.furnitureCount = 5; $0.hasFurnitureWithPhotos = true
        $0.photoCount = 12
    }

    @Test(arguments: [TourExit.completed, .handedOff, .skipped, .skippedAll])
    func lookingAgainNeverChangesAnOutcomeThatIsThere(_ exit: TourExit) {
        let kept = record(opens: 3, [.memories: .skipped, .backup: .completed])
        var tour = Tour(stored: .record(kept))
        tour.send(.opened(.launch, home))
        let saves = tour.saved.count
        for id in [TourChapterID.welcome, .memories, .backup] {
            let run = tour.send(.replay(id, home))
            #expect(run?.mode == .replay)
            #expect(run?.chapter == id)
            #expect(tour.end(exit, home) == nil, "one chapter, nothing chained")
        }
        #expect(tour.machine.record.chapters == kept.chapters)
        #expect(tour.saved.count == saves)
    }

    @Test func aFeatureChapterReadToTheEndByHandCountsAsRead() {
        var tour = Tour(stored: .record(record(opens: 3)))
        tour.send(.opened(.launch, emptyHome))
        tour.send(.replay(.photoLibrary, home))
        tour.end(.skipped, emptyHome)
        #expect(tour.outcome(.photoLibrary) == nil, "leaving half way is not a skip")
        tour.send(.replay(.photoLibrary, home))
        tour.end(.completed, emptyHome)
        #expect(tour.outcome(.photoLibrary) == .completed)
        #expect(tour.saved.last?.entry(for: .photoLibrary)?.outcome == .completed)
    }

    /// Feature chapters that need something the empty home does not have.
    static let needSomething: [TourChapterID] = [.memories, .moveAndLook, .photoBatch, .photoLibrary, .furnitureLibrary, .sendCat]

    @Test(arguments: needSomething, [TourExit.completed, .handedOff])
    func readingThePlaceholderCardByHandIsNotReadingTheChapter(_ id: TourChapterID, _ exit: TourExit) {
        // PRODUCT_PLAN §3.1.1 #10: the "once you have furniture" card shows nothing real.
        var tour = Tour(stored: .record(record(opens: 3)))
        tour.send(.opened(.launch, emptyHome))
        let saves = tour.saved.count
        let run = tour.send(.replay(id, emptyHome))
        #expect(run?.demonstrates == false, "the app shows the placeholder card")
        tour.end(exit, emptyHome)
        #expect(tour.outcome(id) == nil)
        #expect(tour.saved.count == saves)
    }

    @Test func whetherAShowingIsRealIsDecidedWhenItBegins() throws {
        // The user did what the chapter asked: they sorted the waiting photos, so none wait now.
        var tour = Tour(stored: .record(record(opens: 3)))
        tour.send(.opened(.launch, emptyHome))
        let waiting = snap { $0.photoCount = 3; $0.unsortedPhotoCount = 3 }
        let begun = tour.send(.replay(.photoBatch, waiting))
        let run = try #require(begun)
        #expect(run.demonstrates)
        tour.end(.handedOff, snap { $0.photoCount = 3 })
        #expect(tour.outcome(.photoBatch) == .completed)

        // And the other way: photos arrive while the placeholder card is up.
        let again = tour.send(.replay(.photoLibrary, emptyHome))
        let placeholder = try #require(again)
        #expect(!placeholder.demonstrates)
        tour.end(.completed, waiting)
        #expect(tour.outcome(.photoLibrary) == nil)
    }

    @Test func aChapterThatComesUpOnItsOwnAlwaysShowsTheRealThing() {
        var tour = Tour(stored: .record(record(opens: 1)))
        tour.launch(home)
        tour.readThrough(home)
        tour.send(.opened(.launch, home))
        tour.arrive(home)
        #expect(tour.started.count >= 2)
        #expect(tour.started.allSatisfy { $0.mode == .auto && $0.demonstrates })
    }

    @Test func aChapterForAFeatureThisDeviceDoesNotHaveCannotBeOpened() {
        var tour = Tour(stored: .record(record(opens: 3)))
        tour.send(.opened(.launch, emptyHome))
        #expect(tour.send(.replay(.tabletop, emptyHome)) == nil, "no AR here: the chapter is not even listed")
        #expect(tour.send(.replay(.tabletop, snap { $0.supportsAR = true; $0.cameraDenied = true }))?.demonstrates == false)
    }

    @Test func lookingAgainAtAnOpeningPartHalfWayThroughTheOpeningDoesNotEndTheOpening() {
        var tour = Tour()
        tour.launch(emptyHome)
        tour.end(.completed, emptyHome)
        tour.putAway(.blocked)
        tour.send(.replay(.topRow, emptyHome))
        tour.end(.completed, emptyHome)
        #expect(tour.outcome(.topRow) == nil)
        #expect(tour.arrive(emptyHome) == .bringPhoto)
    }

    @Test func lookingAgainDoesNotUseTheTurnsOfThisOpenButNothingFollowsItAtOnce() {
        var tour = Tour(stored: .record(record(opens: 1)))
        tour.send(.opened(.launch, home))
        tour.send(.replay(.photoLibrary, home))
        tour.end(.completed, home)
        tour.send(.replay(.furnitureLibrary, home))
        tour.end(.completed, home)
        #expect(tour.send(.factsChanged(home)) == nil)
        #expect(tour.arrive(home) == .memories)
        tour.end(.completed, home)
        #expect(tour.arrive(home) == .reminders, "both turns of this open were still free")
        tour.end(.completed, home)
        #expect(tour.arrive(home) == nil)
    }

    @Test func aChapterThisVersionDoesNotHaveCannotBeOpened() {
        var tour = Tour()
        #expect(tour.send(.replay(TourChapterID("hologram"), emptyHome)) == nil)
        #expect(tour.running == nil)
    }
}

// MARK: - A build that tells only some chapters (T2 tells chapters 1 and 4)

@Suite struct OnboardingTourPartialBuildTests {
    private let told = TourCatalog(chapters: TourCatalog.current.chapters.filter { [.welcome, .play].contains($0.id) })

    /// 「全部跳过」 in a build with two chapters must hold in the build that tells all fifteen
    /// (PRODUCT_PLAN §3.1 rule 5; QA_T2 F6): the opening's chapter 5 never comes up afterwards.
    @Test func skippingEverythingInAPartialBuildHoldsInTheFullOne() {
        var partial = Tour(catalog: told, settles: .current)
        #expect(partial.launch(emptyHome) == .welcome)
        partial.end(.skippedAll, emptyHome)
        for id in everyChapter { #expect(partial.outcome(id) == .skippedAll, "\(id)") }

        var full = Tour(stored: partial.stored)
        #expect(full.launch(emptyHome) == nil)
        #expect(full.arrive(snap { $0.roomIsEmpty = false; $0.furnitureCount = 1 }) == nil)
    }

    /// Without the wider catalog the record names only what this build tells, and the full build
    /// opens the rest of the opening on its own: the reason `settles` exists.
    @Test func withoutTheWholeCatalogALaterBuildWouldStartTheRest() {
        var partial = Tour(catalog: told)
        partial.launch(emptyHome)
        partial.end(.skippedAll, emptyHome)
        #expect(partial.outcome(.topRow) == nil)
        var full = Tour(stored: partial.stored)
        #expect(full.launch(emptyHome) != nil)
    }

    /// A home lived in before the tour: the waiver covers the chapters a later build tells too.
    @Test func aLivedInHomeIsWaivedForEveryNewcomerChapter() {
        let home = snap { $0.roomIsEmpty = false; $0.furnitureCount = 2; $0.photoCount = 3 }
        var partial = Tour(catalog: told, settles: .current)
        #expect(partial.launch(home) == nil)
        for chapter in TourCatalog.current.chapters where chapter.audience == .newcomer {
            #expect(partial.outcome(chapter.id) == .grandfathered, "\(chapter.id)")
        }
        var full = Tour(stored: partial.stored)
        let started = full.launch(home)
        #expect(started.flatMap { TourCatalog.current[$0]?.audience } != .newcomer, "\(String(describing: started))")
    }

    /// Only what the build tells is ever started: the wider catalog settles, it does not offer.
    @Test func theWiderCatalogStartsNothingOfItsOwn() {
        var partial = Tour(catalog: told, settles: .current)
        #expect(partial.launch(emptyHome) == .welcome)
        #expect(partial.end(.completed, emptyHome) == .play)
        #expect(partial.end(.completed, emptyHome) == nil)
        #expect(Set(partial.chapters) == [.welcome, .play])
    }
}
