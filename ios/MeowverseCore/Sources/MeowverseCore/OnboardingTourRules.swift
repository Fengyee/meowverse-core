import Foundation

// The guided tour: which chapter is due, and the order chapters come up in.
// Rules: docs/ONBOARDING_TOUR.md §0 and §3, docs/onboarding/PRODUCT_PLAN.md §3.1 to §3.3,
// docs/onboarding/TECH_DESIGN.md §4 and §5.
//
// Everything here is a value and a pure function. The app describes what is true now in a
// `TourSnapshot` and reports what happened as a `TourEvent`; `TourMachine` answers with the
// record to save and the chapter to start. Nothing here reads the app's model or the clock.

// MARK: - What is true now

/// The facts a chapter's turn depends on, read by the app when it asks. Counts cover the whole
/// library unless they say "room": those are about the room on screen.
public struct TourSnapshot: Sendable, Equatable {
    /// Where the user is. Report `.room` only when the room is free: nothing presented, no
    /// import, play, editing or AR in progress.
    public var surface: TourSurface = .room
    /// This time in the foreground began from a notification, a quick action, a widget or the
    /// Dynamic Island: the user is on their way somewhere, so nothing comes up on its own.
    public var cameFromOutside = false
    /// The empty-room card still offers to restore from iCloud. The tour waits for the answer.
    public var restoreOfferPending = false

    /// No longer read. It meant `AppState.isEmptyForBackup`, which also counts a renamed cat or
    /// an added room; whether a home is lived in now comes from `furnitureCount` and `photoCount`
    /// alone (Q-04, docs/ONBOARDING_TOUR.md §9). Kept so the app's code still builds.
    @available(*, deprecated, message: "Not read. A home is lived in when furnitureCount or photoCount is above zero (Q-04).")
    public var libraryIsEmpty = true
    /// The room on screen has no furniture placed: the empty-room card is showing.
    public var roomIsEmpty = true
    /// A cat lives in the room on screen.
    public var roomHasCat = true
    /// Pieces in any room or in the storage box, with or without photos.
    public var furnitureCount = 0
    /// The room on screen has a piece that holds at least one photo.
    public var hasFurnitureWithPhotos = false
    /// The room on screen has a piece that is not locked.
    public var hasMovableFurniture = false
    /// The room on screen has a piece the cat can get on and reach: not on a wall, not only for
    /// show, and with a way to it (what the Play panel offers; LINES.md T5.10).
    public var hasPerchableFurniture = false
    public var photoCount = 0
    /// Photos saved but not yet in any piece (the "N photos to sort" bar).
    public var unsortedPhotoCount = 0
    /// An import or its recognition is still running.
    public var importRunning = false

    public var supportsAR = false
    /// Camera access was refused for the app.
    public var cameraDenied = false
    /// Notifications were refused for the app.
    public var notificationsDenied = false
    /// At least one kind of reminder is switched on.
    public var anyReminderOn = false
    /// 「备份到 iCloud 云盘」 is on: the backup chapter does not come up on its own (LINES.md T5.14).
    public var cloudBackupOn = false
    /// This device already answered the old first-launch reminder page for this library: in
    /// the app, `reminders.settings.<library>.setupComplete` is set, or reminder settings were
    /// saved before that flag existed (what `ReminderScheduler.needsFirstLaunchSetup` reads,
    /// without the test-only skip). Then the reminder chapter is not needed. Reminder switches
    /// are kept on the device, not in a backup, so a home restored on a new device was never
    /// asked here and is invited (PRODUCT_PLAN §3.1.1 #11).
    public var answeredReminderSetup = false

    public init() {}

    /// Someone has lived in this home: it has furniture (in a room or the storage box) or
    /// photos. A renamed cat or an added room alone does not count (Q-04).
    public var homeIsLivedIn: Bool { furnitureCount > 0 || photoCount > 0 }
}

/// How the app came to the front.
public enum TourOpening: Sendable, Equatable {
    case launch
    /// Back from the background without having been closed.
    case returned(awayFor: TimeInterval)
}

// MARK: - A chapter on screen

/// One showing of a chapter. Everything that reports back later carries it, so a report from a
/// showing that is over cannot move the tour.
public struct TourRunID: Hashable, Sendable {
    let value: Int

    /// The 「都讲完啦」 card (`TourRules.everythingSeen`): the app shows it on its own, outside the
    /// machine, which knows no run with this id.
    public static let finale = TourRunID(value: -1)
}

public struct TourRun: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// Came up on its own.
        case auto
        /// Opened by hand from Settings or the empty-room card. Does not change an ending that
        /// is already recorded.
        case replay
    }

    public var id: TourRunID
    public var chapter: TourChapterID
    public var mode: Mode
    /// The user has what the chapter points at (`TourRules.canDemonstrate`, decided when the
    /// showing begins). Always true for a chapter that came up on its own. False only for a
    /// replay: show the "once you have furniture" card instead of the steps. Reading that card
    /// does not count as having read the chapter (PRODUCT_PLAN §3.1.1 #10).
    public var demonstrates: Bool

    public init(id: TourRunID, chapter: TourChapterID, mode: Mode, demonstrates: Bool) {
        self.id = id
        self.chapter = chapter
        self.mode = mode
        self.demonstrates = demonstrates
    }
}

/// How the user left a chapter.
public enum TourExit: Sendable, Equatable {
    /// Read to the last step.
    case completed
    /// Did what the chapter asked with the real control, which took the screen (the photo
    /// picker opened, the toy was thrown). Counts as completed; nothing follows at once.
    case handedOff
    /// "Skip this part".
    case skipped
    /// "Skip all".
    case skippedAll
}

/// Why a chapter was put away without the user ending it.
public enum TourInterruption: Sendable, Equatable {
    /// A notification, quick action, widget or link took the user elsewhere. The only reason
    /// that counts against the chapter.
    case outsideRequest
    /// Something stayed in the way too long, or the user left the page.
    case blocked
    /// VoiceOver or the text size changed: the chapter starts again in the other presentation.
    case accessibilityChanged
}

/// What the tour keeps in memory while the app runs. Nothing here is stored.
public struct TourSession: Sendable, Equatable {
    /// The chapter on screen. At most one.
    public var run: TourRun?
    /// The home already had furniture when this open began. A reminder invitation waits for
    /// that: it is not made on the spot where the first piece was placed.
    public var openedWithFurniture = false
    /// Feature chapters that came up on their own during this open.
    public var toldThisOpen: Set<TourChapterID> = []
    /// A chapter was shown since the user last arrived where they are.
    public var toldThisVisit = false
    var lastRun = 0

    public init() {}
}

// MARK: - Rules

public enum TourRules {
    /// Away this long, coming back counts as opening the app again.
    public static let awayThreshold: TimeInterval = 30 * 60
    /// Feature chapters that may come up on their own during one open.
    public static let chaptersPerOpen = 2
    /// Cut short by an outside request this many times, a chapter stops coming up.
    public static let interruptionLimit = 2
    /// The company chapter comes up in the room from this open on.
    public static let opensForCompany = 2
    /// Someone who never placed a piece is invited to reminders from this open on.
    public static let opensForReminderFallback = 3
    /// The backup chapter comes up once the library holds this many photos.
    public static let photosForBackup = 10

    /// The order when several room chapters are due at once (PRODUCT_PLAN §3.1 rule 13).
    /// Chapters not named here follow in catalog order.
    static let precedence: [TourChapterID] = [.memories, .moveAndLook, .reminders, .company, .photoBatch, .backup]

    public static func isNewOpen(_ opening: TourOpening) -> Bool {
        switch opening {
        case .launch: true
        case .returned(let away): away >= awayThreshold
        }
    }

    // MARK: Endings

    /// The chapter has its ending. An opening chapter is told once, whatever its revision; a
    /// waiver holds for every revision; otherwise the ending must be for the current revision.
    public static func isSettled(_ chapter: TourChapter, in record: TourRecord) -> Bool {
        guard let entry = record.entry(for: chapter.id) else { return false }
        return chapter.kind == .opening || entry.outcome == .grandfathered || entry.revision >= chapter.revision
    }

    /// What is left of the opening: the chapters after the last one that has an ending. The
    /// opening only moves forward, so a part that did not apply when its turn came (no cat in
    /// the room, the room no longer empty) is not brought back later.
    public static func openingRemainder(catalog: TourCatalog, record: TourRecord) -> [TourChapter] {
        guard !record.isVeteran else { return [] }
        let opening = catalog.opening
        guard let last = opening.lastIndex(where: { record.entry(for: $0.id) != nil }) else { return opening }
        return Array(opening[(last + 1)...])
    }

    public static func openingIsOver(catalog: TourCatalog, record: TourRecord) -> Bool {
        openingRemainder(catalog: catalog, record: record).isEmpty
    }

    /// The greeting is behind the user, or was never meant for them.
    static func openingHasBegun(catalog: TourCatalog, record: TourRecord) -> Bool {
        record.isVeteran || catalog.opening.isEmpty || catalog.opening.contains { record.entry(for: $0.id) != nil }
    }

    // MARK: What a chapter needs

    /// The feature exists on this device. A chapter that fails this is not listed at all.
    public static func isOnThisDevice(_ chapter: TourChapter, snapshot: TourSnapshot) -> Bool {
        chapter.id == .tabletop ? snapshot.supportsAR : true
    }

    /// The user has what the chapter points at. The tour never makes sample furniture or
    /// photos, so without it the chapter does not come up; opened by hand it shows the
    /// "once you have furniture" card instead.
    public static func canDemonstrate(_ chapter: TourChapter, snapshot: TourSnapshot) -> Bool {
        switch chapter.id {
        case .play: snapshot.roomHasCat
        case .memories: snapshot.hasFurnitureWithPhotos
        case .moveAndLook: snapshot.hasMovableFurniture
        case .photoBatch: snapshot.unsortedPhotoCount > 0
        case .photoLibrary: snapshot.photoCount > 0
        case .furnitureLibrary: snapshot.furnitureCount > 0
        // The panel lists pieces only when a cat lives in the room (LINES.md T5.10).
        case .sendCat: snapshot.roomHasCat && snapshot.hasPerchableFurniture
        case .tabletop: snapshot.supportsAR && !snapshot.cameraDenied
        // Pointing at the gear needs nothing: opened by hand it is shown with any number of photos
        // (LINES.md T5.14). Ten photos are when it comes up on its own (`isTheMoment`).
        default: true
        }
    }

    // MARK: Whose turn

    /// The next part of the opening, when the user is in the free room. Parts that do not apply
    /// right now are passed over without a record, and the opening does not turn back for them
    /// (PRODUCT_PLAN §3.1.1, notes under the table).
    static func nextOpening(catalog: TourCatalog, record: TourRecord, snapshot: TourSnapshot) -> TourChapter? {
        openingRemainder(catalog: catalog, record: record).first { chapter in
            snapshot.surface == chapter.surface && canDemonstrate(chapter, snapshot: snapshot)
                && appliesNow(chapter, snapshot: snapshot)
        }
    }

    /// An opening part still says something true to this user. Unlike `canDemonstrate`, this
    /// is not asked when a part is opened by hand.
    static func appliesNow(_ chapter: TourChapter, snapshot: TourSnapshot) -> Bool {
        switch chapter.id {
        // "Pick a photo" is not said to someone who already brought photos home (§3.1.1 #5).
        case .bringPhoto: snapshot.photoCount == 0
        // "No good photo handy? Place a piece first" is for the room still empty and no photo
        // brought in, also after the picker was cancelled (§3.1.1 #2). Someone with photos
        // waiting has the bar of photos to sort instead.
        case .furnishFirst: snapshot.roomIsEmpty && snapshot.photoCount == 0
        default: true
        }
    }

    /// This chapter, looked at alone, may come up on its own now. `offer` adds what holds for
    /// every chapter (one at a time, the limit per open) and picks among those that are due.
    public static func isDue(
        _ chapter: TourChapter, catalog: TourCatalog, record: TourRecord, session: TourSession, snapshot: TourSnapshot
    ) -> Bool {
        if chapter.audience == .newcomer, record.isVeteran { return false }
        switch chapter.kind {
        case .opening:
            return nextOpening(catalog: catalog, record: record, snapshot: snapshot)?.id == chapter.id
        case .onDemand:
            guard !isSettled(chapter, in: record), isOnThisDevice(chapter, snapshot: snapshot),
                  canDemonstrate(chapter, snapshot: snapshot) else { return false }
            return isTheMoment(for: chapter, catalog: catalog, record: record, session: session, snapshot: snapshot)
        }
    }

    private static func isTheMoment(
        for chapter: TourChapter, catalog: TourCatalog, record: TourRecord, session: TourSession, snapshot: TourSnapshot
    ) -> Bool {
        // The first memory may come between two parts of the opening (the user comes back with
        // their first piece), but not before the greeting.
        if chapter.id == .memories {
            return snapshot.surface == .room && openingHasBegun(catalog: catalog, record: record)
        }
        // Every other feature chapter waits for the opening to be over, also on its own page: a
        // "do" step can take the user there mid-opening, and the room still has the rest of the
        // opening waiting (PRODUCT_PLAN §3.1.1 #4).
        guard openingIsOver(catalog: catalog, record: record) else { return false }
        switch chapter.id {
        case .company:
            // Either the user found the company page themselves, or it is the second open.
            return snapshot.surface == .companyPage || (snapshot.surface == .room && record.opens >= opensForCompany)
        case .tabletop:
            // After the furniture chapter was told, or when it cannot be told here.
            let furnitureChapterOutOfTheWay = catalog[.sendCat].map {
                isSettled($0, in: record) || !canDemonstrate($0, snapshot: snapshot)
            } ?? true
            return snapshot.surface == .interactionPanel && furnitureChapterOutOfTheWay
        case .reminders:
            guard snapshot.surface == .room, !snapshot.notificationsDenied, !snapshot.anyReminderOn,
                  !snapshot.answeredReminderSetup else { return false }
            // With furniture: when the app is opened again after the first piece, not on the
            // spot. Without any: once, from the third open, so these users hear of reminders too.
            return snapshot.furnitureCount > 0 ? session.openedWithFurniture : record.opens >= opensForReminderFallback
        case .photoBatch:
            return snapshot.surface == .room && !snapshot.importRunning
        case .backup:
            // Someone already backing up to iCloud Drive is not invited (LINES.md T5.14).
            return snapshot.surface == .room && snapshot.photoCount >= photosForBackup && !snapshot.cloudBackupOn
        default:
            return snapshot.surface == chapter.surface
        }
    }

    /// 「都讲完啦」 is true: every chapter of `catalog` this device has was read to its end, none
    /// skipped (LINES.md T5.14). A reminder chapter this device did not need counts as read; a
    /// chapter waived for a home lived in before the tour was not read.
    public static func everythingSeen(catalog: TourCatalog, record: TourRecord, snapshot: TourSnapshot) -> Bool {
        let listed = catalog.chapters.filter { isOnThisDevice($0, snapshot: snapshot) }
        return !listed.isEmpty && listed.allSatisfy { chapter in
            switch record.entry(for: chapter.id)?.outcome {
            case .completed, .notNeeded: true
            default: false
            }
        }
    }

    /// The one chapter to start on its own now, if any.
    public static func offer(
        catalog: TourCatalog, record: TourRecord, session: TourSession, snapshot: TourSnapshot
    ) -> TourChapterID? {
        // Until the first open was reported, nobody has looked whether this home was already
        // lived in: starting now could greet a long-time user as a newcomer.
        guard record.opens > 0, !snapshot.cameFromOutside, !snapshot.restoreOfferPending,
              session.run == nil, !session.toldThisVisit else { return nil }
        func due(_ chapter: TourChapter) -> Bool {
            isDue(chapter, catalog: catalog, record: record, session: session, snapshot: snapshot)
        }
        func hasATurn(_ chapter: TourChapter) -> Bool {
            session.toldThisOpen.contains(chapter.id) || session.toldThisOpen.count < chaptersPerOpen
        }
        // The first memory goes ahead of what is left of the opening. Every other feature
        // chapter waits for the opening to be over (`isDue`).
        if let memories = catalog[.memories], due(memories), hasATurn(memories) { return memories.id }
        if let next = catalog.opening.first(where: due) { return next.id }
        let others = catalog.onDemand.filter { !precedence.contains($0.id) }
        let ordered = precedence.compactMap { catalog[$0] }.filter { $0.kind == .onDemand } + others
        return ordered.first { due($0) && hasATurn($0) }?.id
    }
}

// MARK: - The machine

public enum TourEvent: Sendable, Equatable {
    /// The app came to the front and the library is loaded. Send it for every launch and every
    /// return from the background; the machine decides whether it counts as a new open. Nothing
    /// comes up before the first one: it is where a home that is already lived in is recognised.
    case opened(TourOpening, TourSnapshot)
    /// The user has just arrived somewhere a chapter could begin: the room became free again
    /// (also: the restore offer on the empty-room card was answered), or a page a chapter starts
    /// on was opened. Each arrival is one visit, and a visit brings at most one chapter.
    case arrived(TourSnapshot)
    /// Look again without it being a new visit: something changed while the user stayed where
    /// they were. Starts nothing when this visit already had its chapter.
    case factsChanged(TourSnapshot)
    /// The user left the chapter on screen.
    case finished(run: TourRunID, TourExit, TourSnapshot)
    /// The chapter on screen was put away without the user ending it.
    case interrupted(run: TourRunID, TourInterruption)
    /// The home on screen was replaced by one from elsewhere, or cleared: a restore, an import
    /// of a backup, a first sync that brought a home. Not for edits to the user's own home.
    case libraryReplaced(TourSnapshot)
    /// The user asked to see a chapter again, with what is true now: it decides whether the
    /// showing can be real (`TourRun.demonstrates`). A chapter for a feature this device does
    /// not have is not opened.
    case replay(TourChapterID, TourSnapshot)
}

public enum TourEffect: Sendable, Equatable {
    /// Write this record now, before any closing animation.
    case save(TourRecord)
    /// Show this chapter from its first step.
    case start(TourRun)
}

/// The tour for one library: the record, what is on screen, and what each event leads to.
/// A value: `handle` on a copy leaves the original as it was.
public struct TourMachine: Sendable, Equatable {
    public let catalog: TourCatalog
    /// What 「全部跳过」 and a lived-in home's waiver settle: `catalog`, or more. A build that tells
    /// only some chapters passes the whole catalog here, so a later version that tells the rest
    /// finds them settled (PRODUCT_PLAN §3.1 rule 5) instead of opening them as new.
    public let settles: TourCatalog
    public private(set) var record: TourRecord
    public private(set) var session = TourSession()
    /// What was stored could not be read. It is left as it is until an ending has to be kept.
    private var holdsBackSaves: Bool

    public init(catalog: TourCatalog = .current, settles: TourCatalog? = nil, stored: TourStored) {
        self.catalog = catalog
        self.settles = settles ?? catalog
        switch stored {
        case .record(let record):
            self.record = record
            holdsBackSaves = false
        case .missing:
            record = TourRecord()
            holdsBackSaves = false
        case .unreadable:
            record = TourRecord()
            holdsBackSaves = true
        }
    }

    public mutating func handle(_ event: TourEvent) -> [TourEffect] {
        switch event {
        case .opened(let opening, let snapshot):
            return open(opening, snapshot)
        case .arrived(let snapshot):
            // A chapter that is still on screen has used this visit too.
            session.toldThisVisit = session.run != nil
            return look(snapshot)
        case .factsChanged(let snapshot):
            return look(snapshot)
        case .finished(let run, let exit, let snapshot):
            return finish(run, exit, snapshot)
        case .interrupted(let run, let reason):
            return interrupt(run, reason)
        case .libraryReplaced(let snapshot):
            return replaceLibrary(snapshot)
        case .replay(let id, let snapshot):
            guard let chapter = catalog[id], TourRules.isOnThisDevice(chapter, snapshot: snapshot) else { return [] }
            return start(id, .replay, demonstrates: TourRules.canDemonstrate(chapter, snapshot: snapshot))
        }
    }

    // MARK: Events

    private mutating func open(_ opening: TourOpening, _ snapshot: TourSnapshot) -> [TourEffect] {
        guard TourRules.isNewOpen(opening) else { return [] }
        // The first time the tour meets this library: furniture or photos already there belong
        // to someone who used the app before the tour existed.
        if record.opens == 0, snapshot.homeIsLivedIn { waiveNewcomerChapters() }
        // A record from a build that did not write passed-over parts down yet.
        notePassedOverOpening()
        record.opens += 1
        // A chapter left on screen before a long absence is put away without an ending.
        session.run = nil
        session.toldThisOpen = []
        session.toldThisVisit = false
        session.openedWithFurniture = snapshot.furnitureCount > 0
        return save(keepsAnEnding: false)
    }

    private mutating func look(_ snapshot: TourSnapshot) -> [TourEffect] {
        var effects: [TourEffect] = []
        // Someone who switched a reminder on themselves, or whom this device already asked at
        // the old first launch, is never invited to. An ending already there stays.
        if snapshot.anyReminderOn || snapshot.answeredReminderSetup, let reminders = catalog[.reminders],
           !TourRules.isSettled(reminders, in: record) {
            settle(reminders, as: .notNeeded)
            effects += save(keepsAnEnding: true)
        }
        if let chapter = TourRules.offer(catalog: catalog, record: record, session: session, snapshot: snapshot) {
            effects += start(chapter, .auto)
        }
        return effects
    }

    private mutating func finish(_ id: TourRunID, _ exit: TourExit, _ snapshot: TourSnapshot) -> [TourEffect] {
        // A report from a showing that is over: the user's later choice stands.
        guard let run = session.run, run.id == id, let chapter = catalog[run.chapter] else { return [] }
        session.run = nil

        if run.mode == .replay {
            // Looking again changes no ending. Only a feature chapter never seen before, shown
            // for real and read to its end by hand, counts as read; the placeholder card does
            // not, and leaving half way is not a skip.
            guard chapter.kind == .onDemand, run.demonstrates, record.entry(for: chapter.id) == nil,
                  exit == .completed || exit == .handedOff else { return [] }
            settle(chapter, as: .completed)
            return save(keepsAnEnding: true)
        }

        switch exit {
        case .completed:
            settle(chapter, as: .completed)
        case .handedOff:
            // Nothing after it is passed over here: whether the next part still applies is
            // seen when the user is back in the room (PRODUCT_PLAN §3.1.1 #2).
            settle(chapter, as: .completed)
        case .skipped:
            settle(chapter, as: .skipped)
        case .skippedAll:
            // Every chapter of this version that has no ending yet, this one included, also those
            // this build does not tell yet (`settles`). Chapters a later version adds are not in
            // the catalog, so they still come up once.
            for open in settles.chapters where !TourRules.isSettled(open, in: record) {
                settle(open, as: .skippedAll)
            }
        }
        if chapter.kind == .opening { notePassedOverOpening() }
        var effects = save(keepsAnEnding: true)

        // The opening runs on without a pause while the user stays in the room. After a hand-off
        // the screen belongs to the app's own flow; the rest waits for the room to be free again.
        // The restore offer can turn up after the greeting began (the iCloud listing is slow):
        // the rest then waits for the answer.
        if chapter.kind == .opening, exit == .completed || exit == .skipped, !snapshot.restoreOfferPending,
           let next = TourRules.nextOpening(catalog: catalog, record: record, snapshot: snapshot) {
            effects += start(next.id, .auto)
        }
        return effects
    }

    private mutating func interrupt(_ id: TourRunID, _ reason: TourInterruption) -> [TourEffect] {
        guard let run = session.run, run.id == id else { return [] }
        session.run = nil
        guard run.mode == .auto, reason == .outsideRequest, let chapter = catalog[run.chapter] else { return [] }
        let count = (record.interruptions[chapter.id.rawValue] ?? 0) + 1
        guard count >= TourRules.interruptionLimit else {
            record.interruptions[chapter.id.rawValue] = count
            return save(keepsAnEnding: false)
        }
        settle(chapter, as: .skipped)
        return save(keepsAnEnding: true)
    }

    private mutating func replaceLibrary(_ snapshot: TourSnapshot) -> [TourEffect] {
        session.run = nil
        // Whatever is there now was not placed during this open.
        session.openedWithFurniture = false
        // A home that came back from a backup belongs to someone who knows the app.
        guard snapshot.homeIsLivedIn, waiveNewcomerChapters() else { return [] }
        return save(keepsAnEnding: true)
    }

    // MARK: Pieces

    /// A chapter that comes up on its own was due, so it can always be shown for real.
    private mutating func start(_ chapter: TourChapterID, _ mode: TourRun.Mode, demonstrates: Bool = true) -> [TourEffect] {
        session.lastRun += 1
        let run = TourRun(id: TourRunID(value: session.lastRun), chapter: chapter, mode: mode, demonstrates: demonstrates)
        session.run = run
        session.toldThisVisit = true
        if mode == .auto, catalog[chapter]?.kind == .onDemand { session.toldThisOpen.insert(chapter) }
        return [.start(run)]
    }

    private mutating func settle(_ chapter: TourChapter, as outcome: TourOutcome) {
        record.chapters[chapter.id.rawValue] = TourEntry(outcome: outcome, revision: chapter.revision)
        record.interruptions[chapter.id.rawValue] = nil
    }

    /// Once the opening is over, a part of it that did not apply when its turn came (chapter 3
    /// after a photo came home in chapter 2) is written down as not needed: it will not come
    /// any more, and like a reminder chapter this device did not need it counts as read for
    /// 「都讲完啦」 (QA_T5 must-fix 1, lead ruling). Written when the opening ends, not guessed when
    /// asked. It stays in the replay list as any not-needed chapter does.
    private mutating func notePassedOverOpening() {
        guard !record.isVeteran, TourRules.openingIsOver(catalog: catalog, record: record) else { return }
        for part in catalog.opening where record.entry(for: part.id) == nil {
            settle(part, as: .notNeeded)
        }
    }

    /// Waives every chapter for newcomers that has no ending. True when it changed anything.
    @discardableResult private mutating func waiveNewcomerChapters() -> Bool {
        let waived = settles.chapters.filter { $0.audience == .newcomer && record.entry(for: $0.id) == nil }
        for chapter in waived { settle(chapter, as: .grandfathered) }
        return !waived.isEmpty
    }

    private mutating func save(keepsAnEnding: Bool) -> [TourEffect] {
        if keepsAnEnding { holdsBackSaves = false }
        return holdsBackSaves ? [] : [.save(record)]
    }
}
