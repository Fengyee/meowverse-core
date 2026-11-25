import MeowverseCore
import os
import SwiftUI
import UIKit

// The tour in the running app (docs/onboarding/TECH_DESIGN.md §5). `TourMachine` decides which
// chapter is due; this class tells it what is true in the app, keeps its record, waits for
// whatever else the app shows first, and puts the chapter on screen: the overlay window
// (TourOverlayWindow.swift), the naming page and, for VoiceOver and Switch Control, page mode.

/// The tour's launch switches. The real library always has the tour; a UI-test library only
/// with `-MeowverseTour`, so the other UI tests see the app as before.
///
/// DEBUG only:
/// - `-MeowverseTour auto`: as in the real library. `-MeowverseTour <chapter id>` (`welcome`,
///   `play`): that chapter, opened by hand, as soon as the room is free.
/// - `-MeowverseTourSeedOpens <n>`: the planted record's opens (default 1).
/// - `-MeowverseTourSeed veteran|<id,id>`: with `-MeowverseResetStore`, the record starts as a
///   long-time user's, or with these chapters read.
/// - `-MeowverseTourPage`: page mode without VoiceOver.
/// - `-MeowverseTourBlockedLimit <seconds>`: how long a chapter waits behind something else.
/// - `-MeowverseTourDropsPages`: chapter 12's pages are dismissed from below two seconds after they
///   came, as by the system or by the page under them going: their delegate is not told.
enum TourLaunch {
    static let isEnabled: Bool = {
        #if DEBUG
        if request != nil { return true }
        #endif
        return LaunchOptions.current.storeFolder == "Library"
    }()

    #if DEBUG
    private static let arguments = ProcessInfo.processInfo.arguments

    private static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        let value = arguments[index + 1]
        return value.hasPrefix("-") ? nil : value
    }

    static let request = value(after: "-MeowverseTour")
    static let seed = value(after: "-MeowverseTourSeed")
    /// How many opens the planted record has had (default 1: this launch is the second).
    static let seedOpens = value(after: "-MeowverseTourSeedOpens").flatMap(Int.init)
    static let forcesPage = arguments.contains("-MeowverseTourPage")
    static let blockedLimit = value(after: "-MeowverseTourBlockedLimit").flatMap(Double.init)
    static let dropsPages = arguments.contains("-MeowverseTourDropsPages")
    #endif

    /// VoiceOver or Switch Control is on: the tour is a plain sheet of pages, with no mask.
    static var pageMode: Bool {
        #if DEBUG
        if forcesPage { return true }
        #endif
        return UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
    }
}

/// A link from outside the app arrived (the Dynamic Island, a widget). Polled by the tour.
enum TourOutside {
    private(set) static var count = 0
    static func arrived() { count += 1 }
}

/// What the room page knows about itself, reported by `RoomScreen`.
struct TourRoomFacts: Equatable {
    /// What keeps the room from being free (`RoomScreen.roomBusyWith`), in a word for the log.
    var busy: String? = "not reported yet"
    /// Nothing over the room, nothing in progress.
    var idle: Bool { busy == nil }
    /// The last time the cat was sent to a piece. Not something in progress: it is kept for as
    /// long as the room lives.
    var sentCat: UUID?
    /// 互动 is open (a sheet on iPhone, a column on iPad).
    var panelOpen = false
    var playing = false
    /// A piece is lifted for placing (`edit.isActive`): 7.1 steps aside until it is put down.
    var editing = false
    /// The room is zoomed in (`RoomProjection.isZoomed`): 7.2's answer.
    var zoomed = false
    /// The photo receipt banner is up: chapter 6 waits for it to go (Q-18).
    var receiptShown = false
    /// The photo picker, or the page before it, is open: what 2.3 hands over to.
    var pickingPhotos = false
    /// The tabletop was asked for or is up: what 13.1 hands over to.
    var onTabletop = false
}

@MainActor @Observable
final class TourCoordinator {
    enum Presentation: Equatable { case overlay, page }

    /// The chapter on screen.
    struct Showing: Equatable {
        var run: TourRun
        var presentation: Presentation
        /// The chapter card is up, before the first step.
        var onCard: Bool
        var index = 0
        var naming: TourScript.NamingResult?
        var steps: [TourStep]
        /// The step whose bubble had no room beside its window: it is read as a page.
        var squeezedStep: String?
        /// A chapter opened from Settings with nothing to show it with: only its card, with this
        /// line and 「知道了」 (LINES.md T4.4).
        var placeholderLine: String?
        /// The card's line when it is not the chapter's usual one (chapter 14 with no furniture).
        var cardLine: String?
        /// The page the chapter began on (chapters 9, 10, 11, 13 and 12), nil in the room. Its card
        /// is said over that page, and leaving the page puts the chapter away.
        var beganOn: TourSurface?

        var step: TourStep? { onCard || !steps.indices.contains(index) ? nil : steps[index] }
        var squeezed: Bool { squeezedStep != nil && squeezedStep == step?.id }
        /// The bubbles of this chapter, without the naming page.
        var bubbleCount: Int { steps.filter { $0.kind == .bubble }.count }
        var bubbleNumber: Int { steps.prefix(index + 1).filter { $0.kind == .bubble }.count }
        var isLast: Bool { index == steps.count - 1 }
        /// 【下一步】, or the closing word on a chapter's last step. Chapters 2 and 3 in the opening
        /// go straight on, so theirs still says 【下一步】.
        var nextTitle: String {
            guard isLast && !((run.mode == .auto || TourReplayEntry.replaysOpening) && TourScript.goesOn(run.chapter)) else {
                return TourText.next
            }
            return step?.gotIt == true ? TourText.gotIt : TourText.done
        }
        /// The card's solid button: 「开始」, or 「知道了」 on a card with nothing after it.
        var startTitle: String { placeholderLine == nil ? TourText.start : TourText.gotIt }
    }

    private(set) var showing: Showing? {
        didSet {
            if showing?.run.id != oldValue?.run.id { scrolledTo = nil }
            guard let showing, let step = showing.step, step.id != oldValue?.step?.id || showing.run.id != oldValue?.run.id else { return }
            stepSince = .now
            sentCatAtStep = room.sentCat
            // Chapters 6 and 7 start from the room as it opens (6.1, 7.1, 7.3).
            if TourScript.resetsZoom(before: step, in: showing.run.chapter) { zoomResets += 1 }
        }
    }
    @ObservationIgnored private var stepSince = ContinuousClock.now
    /// `TourRoomFacts.sentCat` as the step came: another one since is 11.1 done.
    @ObservationIgnored private var sentCatAtStep: UUID?
    /// The control the page under the tour has scrolled to and come to rest on (`tourScrolls`).
    @ObservationIgnored private var scrolledTo: String?
    /// Asks the room to set its zoom back (`RoomScreen` watches it).
    private(set) var zoomResets = 0
    /// Chapter 12's pages are up, over whatever is on top.
    @ObservationIgnored private var companyPages: UIViewController?
    @ObservationIgnored private lazy var companyPagesWatcher = SqueezedPageWatcher { [weak self] in self?.companyPagesClosed() }
    /// 7.1: the piece was lifted; the step comes back as 7.2 once it is put down.
    @ObservationIgnored private var lifted = false
    /// 7.2: since when the room has been zoomed with no finger on the screen.
    @ObservationIgnored private var zoomHeldSince: ContinuousClock.Instant?
    /// The receipt banner was up at the last look: when it goes, the room counts as newly arrived at.
    @ObservationIgnored private var receiptWasShown = false
    /// The naming page, a sheet in the main window (the overlay window never has the keyboard).
    var namingShown = false
    /// Page mode's sheet.
    var pageShown = false {
        didSet { if pageShown { pageRun = showing?.run.id } }
    }
    /// The run page mode's sheet was presented for: its dismissal ends that run only (L24-07).
    @ObservationIgnored private var pageRun: TourRunID?
    /// The existing message for a name that could not be saved.
    var renameFailure: String?
    /// The rename is being saved.
    private(set) var renaming = false
    /// 「测试版说明」 (`TourTestBuild`), full screen, once the opening is over.
    var noticeShown = false
    /// The room's old 「房间还是空的」 card stays away while chapter 1 is due or on screen, from
    /// before its card appears (VISUAL §11.1). It comes back 0.2 s after the mask has gone.
    private(set) var holdsRoomGuide = false

    @ObservationIgnored var room = TourRoomFacts()
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private weak var reminders: ReminderScheduler?
    @ObservationIgnored private var machine: TourMachine?
    @ObservationIgnored private let store: TourRecordStore
    @ObservationIgnored private let library: String
    @ObservationIgnored private let catalog: TourCatalog
    @ObservationIgnored private(set) weak var mainWindow: UIWindow?
    @ObservationIgnored private var overlay: TourOverlayWindow?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var activeSince: ContinuousClock.Instant?
    @ObservationIgnored private var blockedSince: ContinuousClock.Instant?
    /// When a chapter is looked for on its own: the arrivals, the wait for an import (chapter 8)
    /// and the visit left to the cat the user sent.
    @ObservationIgnored private var visit = TourVisit()
    /// Since when a replay could begin where the user is, and where that is.
    @ObservationIgnored private var replayFree: (place: TourSurface, since: ContinuousClock.Instant)?
    /// Why the replay asked for has not begun, as last logged.
    @ObservationIgnored private var replayHeld: String?
    /// Since when none of the chapter's own pages has been on screen though it should be.
    @ObservationIgnored private var lostSince: ContinuousClock.Instant?
    @ObservationIgnored private var cameFromOutside = false
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var wasActive = false
    @ObservationIgnored private var outsideSeen = TourOutside.count
    @ObservationIgnored private var companionSeen: UUID?
    @ObservationIgnored private var guideReleaseSince: ContinuousClock.Instant?
    /// The naming page is due: it comes once the mask and the window have left (VISUAL §2.6,
    /// §12.3), not over them.
    @ObservationIgnored private var namingDueSince: ContinuousClock.Instant?
    /// The test build page waits until then: after 「全部跳过」, long enough to read its line.
    @ObservationIgnored private var noticeNotBefore: ContinuousClock.Instant?
    @ObservationIgnored private var noticeIdleSince: ContinuousClock.Instant?
    /// The page was answered, or is not for this build: not again in this run.
    @ObservationIgnored private var noticeDone = false
    /// The page a squeezed step is read on, over whatever is on top.
    @ObservationIgnored private var squeezedPage: UIViewController?
    @ObservationIgnored private lazy var squeezedPageWatcher = SqueezedPageWatcher { [weak self] in self?.squeezedPageClosed() }
    #if DEBUG
    @ObservationIgnored private var replayAsked = TourLaunch.request.flatMap { $0 == "auto" ? nil : TourChapterID($0) }
    #endif
    @ObservationIgnored let log = Logger(subsystem: "app.meowverse", category: "tour")

    /// The chapters this build tells: since T5, every chapter of `TourCatalog.current`.
    static let shippedChapters: Set<TourChapterID> = TourCatalog.toldInThisBuild

    init(options: LaunchOptions, store: TourRecordStore = UserDefaultsTourRecordStore()) {
        self.store = store
        library = options.storeFolder
        catalog = .thisBuild
        // A reset test library forgets the tour too.
        if options.resetStore {
            store.remove(library: library)
            UserDefaults.standard.removeObject(forKey: Self.finaleKey(library: library))
            TourTestBuild.forget(library: library)
            TourReplayEntry.forgetReadAgain(library: library)
        }
        noticeDone = !TourTestBuild.showsNotice || TourTestBuild.seen(library: library)
        #if DEBUG
        if options.resetStore, let seed = TourLaunch.seed { plant(seed) }
        #endif
        if TourLaunch.isEnabled, case .record(let record) = store.load(library: library) {
            holdsRoomGuide = record.entry(for: .welcome) == nil
        } else {
            holdsRoomGuide = TourLaunch.isEnabled
        }
    }

    // MARK: Start

    /// Called once the main window exists. The tour stays in the first window while that window
    /// is in a scene. The system may disconnect the scene of an app in the background and connect
    /// a new one to the same process: the tour then moves to the new window.
    func attach(window: UIWindow, model: AppModel, reminders: ReminderScheduler) {
        guard TourLaunch.isEnabled, window !== mainWindow, !(window is TourOverlayWindow) else { return }
        if let mainWindow, let scene = mainWindow.windowScene, scene.activationState != .unattached { return }
        mainWindow = window
        self.model = model
        self.reminders = reminders
        guard loop == nil else { return leaveOldWindow() }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    /// What was drawn in the old window's scene went with it.
    private func leaveOldWindow() {
        log.notice("[tour] the main window was replaced")
        overlay?.isHidden = true
        overlay = nil
        touchWatcher = nil
        TourTouchWatcher.forget()
        squeezedPage = nil
        companyPages = nil
        replayFree = nil
        endLeftBehind("its window went")
    }

    // MARK: Every 0.1 s

    private func tick() {
        guard let model, let reminders, model.phase == .ready else { return }
        let clock = ContinuousClock.now
        let state = UIApplication.shared.applicationState
        if state == .background, backgroundedAt == nil {
            backgroundedAt = .now
            cameFromOutside = false
        }
        guard state == .active else {
            wasActive = false
            visit.interrupted()
            replayFree = nil
            lostSince = nil
            noteHeldReplay("app not active")
            return
        }
        if !wasActive {
            wasActive = true
            activeSince = clock
            blockedSince = nil
        }

        if machine == nil {
            // 「全部跳过」 and the waiver settle every chapter, also those this build does not tell
            // yet, so a later build does not open them as new (QA_T2 F6).
            machine = TourMachine(catalog: catalog, settles: .current, stored: store.load(library: library))
            generation = model.libraryGeneration
            backgroundedAt = nil
            noteOutsideRequests(reminders)
            send(.opened(.launch, snapshot()))
        } else if let left = backgroundedAt {
            backgroundedAt = nil
            send(.opened(.returned(awayFor: Date.now.timeIntervalSince(left)), snapshot()))
            // A long absence put the chapter away (`TourMachine`).
            if let showing, machine?.session.run?.id != showing.run.id { putAway() }
        }
        if generation != model.libraryGeneration {
            generation = model.libraryGeneration
            putAway()
            send(.libraryReplaced(snapshot()))
        }
        if noteOutsideRequests(reminders), let run = showing?.run {
            putAway()
            send(.interrupted(run: run.id, .outsideRequest))
        }

        let idle = isIdle(model, reminders, now: clock)
        holdRoomGuide(model, now: clock)
        endIfLeftBehind(now: clock)
        syncSqueezedPage()
        syncCompanyPages()
        openNamingWhenClear(now: clock)
        // The receipt went: the room is arrived at again, for chapter 6 (Q-18).
        if receiptWasShown, !room.receiptShown, showing == nil { visit.receiptWent() }
        receiptWasShown = room.receiptShown
        if tellReplay(model, reminders, now: clock) { return }
        guard let showing else {
            blockedSince = nil
            setTouchWatch(false)
            if openNoticeIfDue(idle: idle, now: clock) { return }
            // A chapter may also begin on the page the user opened: chapter 12 on the company page
            // (§3.2), 9 on the photo library, 10 on the furniture library, 11 and 13 on the Play panel.
            // A photo just filed: its receipt goes first, and then chapter 6 rather than another (Q-18).
            let receiptFirst = room.receiptShown && model.roomFurniture.contains { !$0.sources.isEmpty }
            // From one page straight to another (互动, then 陪我一会儿 pushed inside it, with no
            // presentation in between) is a new arrival.
            // The panel closed because the cat was sent to a piece: this visit is for watching her
            // go, not for another chapter over her, whatever ends meanwhile (`TourVisit`). The next
            // visit is an ordinary one.
            let sight = TourVisit.Sight(place: idle ? .room : freePage(reminders, now: clock), sentCat: room.sentCat,
                                        receiptFirst: receiptFirst, importRunning: TourReplayEntry.importRunning(model))
            switch visit.look(sight, now: clock) {
            case .none:
                break
            case .arrive:
                arrive()
            case .lookAgain:
                // Comparing is over and the user is still here: chapter 8 may be due now.
                // Not a new visit, so a visit that had its chapter gets no second one.
                log.notice("[tour] the import ended: looking again")
                send(.factsChanged(snapshot()))
            }
            return
        }
        watch(showing, idle: idle, now: clock)
    }

    // MARK: Asked for again by hand

    /// 「从头看一遍」 or one chapter (`TourReplayQueue`). It waits only for a place it can be seen
    /// in: not for the receipt banner, the iCloud listing or the other things that hold back a
    /// chapter coming up on its own. True when it took this look.
    private func tellReplay(_ model: AppModel, _ reminders: ReminderScheduler, now: ContinuousClock.Instant) -> Bool {
        let queue = TourReplayEntry.queue
        guard !queue.chapters.isEmpty else {
            replayFree = nil
            replayHeld = nil
            return false
        }
        let held = roomHold(model, reminders, now: now)
        var place: TourSurface?
        if held == nil {
            place = .room
        } else if let page = freePage(reminders, now: now), !TourLaunch.pageMode || page == .companyPage {
            place = page
        }
        if let place {
            if replayFree?.place != place { replayFree = (place, now) }
        } else {
            replayFree = nil
        }
        switch queue.step(catalog: catalog, chapterShowing: showing != nil, place: place,
                          freeFor: replayFree.map { now - $0.since } ?? .zero) {
        case .none:
            if let showing { noteHeldReplay("\(showing.run.chapter.rawValue) is on screen") }
            return false
        case .endShowing:
            endLeftBehind("a replay was asked for")
            return true
        case .wait:
            if let held {
                noteHeldReplay(place.map { "on \($0), \(held)" } ?? held)
            }
            // Nothing comes up on its own in front of it: that would be cut off at the next look.
            blockedSince = nil
            visit.interrupted()
            setTouchWatch(false)
            return true
        case .take:
            guard let chapter = TourReplayEntry.take() else { return false }
            log.notice("[tour] replay begins: \(chapter.rawValue, privacy: .public)")
            replayFree = nil
            replayHeld = nil
            visit.replayBegan(on: place)
            send(.replay(chapter, snapshot()))
            if showing == nil { log.notice("[tour] replay of \(chapter.rawValue, privacy: .public) showed nothing") }
            return true
        }
    }

    /// Once per cause, for the device's log: why the replay asked for has not begun.
    private func noteHeldReplay(_ why: String) {
        let queue = TourReplayEntry.queue
        guard let next = queue.chapters.first, replayHeld != why else { return }
        replayHeld = why
        log.notice("[tour] replay of \(next.rawValue, privacy: .public) waits: \(why, privacy: .public)")
    }

    /// Why a chapter asked for by hand cannot be seen in the room now; nil: it can.
    private func roomHold(_ model: AppModel, _ reminders: ReminderScheduler, now: ContinuousClock.Instant) -> String? {
        guard let root = mainWindow?.rootViewController else { return "no main window" }
        var over = ""
        if let presented = root.presentedViewController {
            var top = presented
            while let next = top.presentedViewController { top = next }
            over = " under \(type(of: top))"
        }
        if let busy = room.busy { return "room busy with \(busy)\(over)" }
        if !over.isEmpty { return "room\(over)" }
        if reminders.pendingTap != nil { return "a reminder tap is pending" }
        if QuickActionCenter.shared.pending != nil { return "a quick action is pending" }
        // The card with the offer is answered first (PRODUCT_PLAN rule 10).
        if model.cloudRestoreOffered { return "the restore offer is up" }
        guard let activeSince, now - activeSince >= .milliseconds(1500) else { return "just came to the front" }
        return nil
    }

    // MARK: Left behind

    /// A page of the chapter's own was taken away without its delegate or binding being told (a
    /// page below it was dismissed, or the system closed it), or never came up. The chapter then
    /// has nothing on screen and nothing would ever end it. A moment's grace for a presentation.
    private func endIfLeftBehind(now: ContinuousClock.Instant) {
        guard showing != nil, ownPageIsLost else {
            lostSince = nil
            return
        }
        let since = lostSince ?? now
        lostSince = since
        guard now - since >= .seconds(1) else { return }
        endLeftBehind("its page is not on screen")
    }

    private var ownPageIsLost: Bool {
        // A page that is up, or under another, has who presented it.
        if [companyPages, squeezedPage].contains(where: { $0 != nil && $0?.presentingViewController == nil }) { return true }
        // The naming page and page mode's sheet are in the chain from the root.
        guard namingShown || pageShown, let root = mainWindow?.rootViewController else { return false }
        return root.presentedViewController == nil
    }

    /// Takes away the chapter the tour takes to be on screen. No ending, on a hand-off step too:
    /// being gone from a step is no evidence of what the user did (`TourRules.handOffEnding`).
    private func endLeftBehind(_ why: String) {
        lostSince = nil
        guard let current = showing else { return }
        log.notice("[tour] \(current.run.chapter.rawValue, privacy: .public) \(current.step?.id ?? "card", privacy: .public) left behind: \(why, privacy: .public)")
        blockedSince = nil
        putAway()
        send(.interrupted(run: current.run.id, .blocked))
    }

    private func arrive() {
        #if DEBUG
        if let chapter = replayAsked {
            replayAsked = nil
            send(.replay(chapter, snapshot()))
            return
        }
        #endif
        let found = snapshot()
        visit.arrived(with: found)
        send(.arrived(found))
        if showing == nil { showFinaleIfDue() }
    }

    // MARK: 「都讲完啦」

    /// Shown once on this device, after every chapter was read and none skipped (LINES.md T5.14),
    /// at the next arrival in the free room. Not a chapter: the machine knows nothing of it, and it
    /// counts against no limit. Beside the record in UserDefaults, as 「看过」 is.
    static func finaleKey(library: String) -> String { "tour.allDone.\(library)" }

    private func showFinaleIfDue() {
        guard let machine, room.idle, !UserDefaults.standard.bool(forKey: Self.finaleKey(library: library)),
              TourRules.everythingSeen(catalog: catalog, record: machine.record, snapshot: snapshot()),
              let card = TourScript.card(.allDone, catName: catName) else { return }
        // Marked once it has been answered (`finish`), not here: put away before it was seen,
        // it comes at the next arrival instead (L24-09).
        let run = TourRun(id: .finale, chapter: .allDone, mode: .replay, demonstrates: false)
        let presentation: Presentation = TourLaunch.pageMode ? .page : .overlay
        // Its one button is 「知道了」, as on a placeholder card, and it has no 「全部跳过」.
        showing = Showing(run: run, presentation: presentation, onCard: true, steps: [], placeholderLine: card.line)
        log.notice("tour: everything seen")
        if presentation == .page { pageShown = true } else { showOverlay() }
    }

    /// While a chapter is up.
    private func watch(_ current: Showing, idle: Bool, now: ContinuousClock.Instant) {
        // VoiceOver came or went: the chapter starts again in the other presentation.
        if (current.presentation == .page) != TourLaunch.pageMode {
            putAway()
            visit.chapterPutAway()
            send(.interrupted(run: current.run.id, .accessibilityChanged))
            return
        }
        if current.run.chapter == .play {
            // The toy was picked: the chapter handed over to the real game.
            if room.playing { return finish(.handedOff) }
            // The panel was closed without a toy: back to 「互动」 once the room is free again.
            if current.step?.id == "4.2", !room.panelOpen, idle {
                self.showing?.index = 0
                return
            }
        }
        // 8.1: sorting began (the bar's 「整理」, or the library's): handed over (rule 6). The sorting
        // flow has its own words and no mask (LINES.md T5.1).
        // Not any import: a photo from the camera is no sorting.
        if current.run.chapter == .photoBatch, model?.batch.sortingTotal != nil {
            return finish(.handedOff)
        }
        guard current.presentation == .overlay else { return }
        if leftThePage(current, now: now) { return }
        if current.run.chapter == .photoLibrary { followSuggestEntry(current) }
        if current.run.chapter == .moveAndLook, watchGestures(current, now: now) { return }
        let waiting = namingShown || namingDueSince != nil || renaming || renameFailure != nil
            || overlay?.controller.isShowing == true || squeezedPage != nil || companyPages != nil
        if waiting {
            blockedSince = nil
            return
        }
        let since = blockedSince ?? now
        blockedSince = since
        var limit = 30.0
        #if DEBUG
        limit = TourLaunch.blockedLimit ?? limit
        #endif
        if now - since >= .seconds(limit) {
            putAway()
            send(.interrupted(run: current.run.id, .blocked))
        }
    }

    // MARK: Chapter 7's gestures

    /// 7.1: lifting the piece puts the tour aside (VISUAL §17.6, 13.3 b); once it is put down, 7.2.
    /// 7.2: done when the room stays zoomed in for a second with no finger on the screen; the
    /// room is set back before 7.3 (`zoomResets`). True while the step waits on the user's hands,
    /// which is not "blocked".
    private func watchGestures(_ current: Showing, now: ContinuousClock.Instant) -> Bool {
        setTouchWatch(true)
        switch current.step?.id {
        case "7.1":
            if room.editing {
                lifted = true
                blockedSince = nil
                return true
            }
            if lifted {
                lifted = false
                go(to: "7.2")
                return true
            }
        case "7.2":
            guard room.zoomed, TourTouchWatcher.down == 0 else {
                zoomHeldSince = nil
                return false
            }
            let since = zoomHeldSince ?? now
            zoomHeldSince = since
            if now - since >= .seconds(1) {
                zoomHeldSince = nil
                go(to: "7.3")
            }
            return true
        default:
            break
        }
        return false
    }

    /// The overlay keeps out of the way: the piece is lifted in 7.1.
    var stepsAside: Bool { showing?.step?.id == "7.1" && room.editing }

    /// A step that sets the zoom back (6.1, 7.1, 7.3) waits until the room is back, so its window
    /// and bubble are placed once, on the room as it settles (VISUAL §17.10.2; QA_T4 item 3).
    var waitsForZoom: Bool {
        guard let showing, let step = showing.step, room.zoomed else { return false }
        return TourScript.resetsZoom(before: step, in: showing.run.chapter)
    }

    /// A step whose control is scrolled into view first (11.2, 13.1, 14.2) waits until the list
    /// has come to rest, so its window and bubble are placed once, on the row where it stays
    /// (LINES.md T5.14). At most two seconds: a list that never reports back does not hold the step.
    var waitsForScroll: Bool {
        guard let showing, !showing.onCard, let step = showing.step, step.scrolls,
              case .control(let id) = step.target, scrolledTo != id else { return false }
        return ContinuousClock.now - stepSince < .seconds(2)
    }

    /// The list has scrolled `id` into view and stopped.
    func scrolled(to id: String) { scrolledTo = id }

    /// The card of a chapter that began on a page: it is said over that page (chapter 12 on the
    /// company page, 9, 10, 11 and 13 on theirs).
    var cardOverPage: Bool {
        guard let showing, showing.onCard, let page = showing.beganOn else { return false }
        return page == .companyPage ? TourCompanyPageSeen.shown : TourPages.isUp(page, in: mainWindow)
    }

    /// The control the page under the tour should scroll into view: the step's own target when
    /// it says so (11.2, 13.1, 14.2), or, on 14.1, the target its control leads to, so Settings
    /// opens already scrolled to 「提醒」 (Q-05).
    var scrollTarget: String? {
        guard let showing, showing.presentation == .overlay, !showing.onCard, let step = showing.step else { return nil }
        if step.scrolls, case .control(let id) = step.target { return id }
        if case .control(let id)? = step.doneWhen, showing.steps.indices.contains(showing.index + 1),
           showing.steps[showing.index + 1].scrolls {
            return id
        }
        return nil
    }

    /// Since when the page the chapter began on has been gone.
    @ObservationIgnored private var pageGoneSince: ContinuousClock.Instant?

    /// The user closed the page the chapter began on, or went further in (a photo, a piece): the
    /// chapter is put away without an ending and comes again on a later visit (TECH_DESIGN §3.5,
    /// "用户离开了这一层"). A moment's grace for the sheet settling.
    private func leftThePage(_ current: Showing, now: ContinuousClock.Instant) -> Bool {
        // A squeezed step's own page sits over the one the chapter began on: that page is still
        // there (13.1 on an iPhone SE from Accessibility XL was ended as handed off a second after
        // its page came, and the page went with it).
        guard let page = current.beganOn, page != .companyPage, squeezedPage == nil,
              !TourPages.isUp(page, in: mainWindow) else {
            pageGoneSince = nil
            return false
        }
        let since = pageGoneSince ?? now
        pageGoneSince = since
        guard now - since >= .seconds(1) else { return false }
        pageGoneSince = nil
        // Also on a step that hands over (11.1, 13.1): the page can go without the user's touch
        // (a quick action). What the user did with the control was recorded by `handOff` already.
        log.notice("tour: \(current.run.chapter.rawValue, privacy: .public) put away: its page went")
        putAway()
        visit.chapterPutAway()
        send(.interrupted(run: current.run.id, .blocked))
        return true
    }

    /// 9.3 is said only while 「按建议放进家具」 is on the page (LINES.md T5.14): it turns up when the
    /// user taps 「未放进家具」 in 9.1's window. Decided until 9.2 is on screen.
    private func followSuggestEntry(_ current: Showing) {
        guard !current.onCard, let step = current.step, step.id == "9.1" || step.id == "9.2", let mainWindow else { return }
        var context = context(for: .photoLibrary)
        context.onPage = current.beganOn
        context.hasSuggestEntry = model?.batchSuggestionsAvailable == true
            && TourAnchorRegistry.shared.probe("rerun-suggestions", in: mainWindow) != nil
        // A photo under the filter now shown, and its cell on the page. 「未放进家具」 tapped in 9.1 may
        // leave none (QA_T5 must-fix 2): then 9.1 is the last step, never a window on no photo.
        // Before the page is up (9.0, from the room) there is nothing to read yet.
        if TourPages.isUp(.photoLibrary, in: mainWindow), let model {
            context.libraryHasPhoto = PhotoLibrary.count(in: model.shownState, filter: model.photos.filter,
                                                         linkedElsewhere: model.sync.photosOnNewerPieces) > 0
                && TourAnchorRegistry.shared.probe("library-photo", in: mainWindow) != nil
        } else {
            context.libraryHasPhoto = true
        }
        let steps = TourScript.steps(.photoLibrary, context: context, naming: nil)
        guard steps.map(\.id) != current.steps.map(\.id) else { return }
        var changed = current
        changed.steps = steps
        changed.index = steps.firstIndex { $0.id == step.id } ?? current.index
        showing = changed
    }

    /// 7.2's mask and window fade while two fingers are on the room or it is zoomed in; the
    /// bubble stays (VISUAL §17.6).
    var gestureFades: Bool { showing?.step?.id == "7.2" && (TourTouchWatcher.down >= 2 || room.zoomed) }

    private func go(to id: String) {
        guard var current = showing, let index = current.steps.firstIndex(where: { $0.id == id }) else { return }
        current.index = index
        showing = current
    }

    @ObservationIgnored private var touchWatcher: TourTouchWatcher?

    /// Counts the fingers on the main window, for 7.2. Only while chapter 7 is up.
    private func setTouchWatch(_ on: Bool) {
        if on, touchWatcher == nil, let mainWindow {
            let watcher = TourTouchWatcher()
            mainWindow.addGestureRecognizer(watcher)
            touchWatcher = watcher
        } else if !on, let watcher = touchWatcher {
            watcher.view?.removeGestureRecognizer(watcher)
            touchWatcher = nil
            TourTouchWatcher.forget()
        }
    }

    /// Chapter 1 is on screen, or due and about to come: the old empty-room card stays away. Not
    /// while the restore offer, which is on that card, is up; not on a visit that came from outside,
    /// which tells nothing.
    private func holdRoomGuide(_ model: AppModel, now: ContinuousClock.Instant) {
        let welcomeUp = showing?.run.chapter == .welcome
        let due = machine.map { $0.record.entry(for: .welcome) == nil } ?? holdsRoomGuide
        let wanted = welcomeUp || (due && !cameFromOutside && !model.cloudRestoreOffered)
        if wanted {
            guideReleaseSince = nil
            if !holdsRoomGuide { holdsRoomGuide = true }
            return
        }
        guard holdsRoomGuide else { return }
        // After the mask has gone. When chapter 4 follows at once the mask stays and the card comes
        // back under it, after 4.1's words have come in: the eye goes to the words first (VISUAL
        // §12.2 c). Its words fade in once the bubble has moved: 0.12 + 0.35 + 0.18 s.
        let since = guideReleaseSince ?? now
        guideReleaseSince = since
        let wait = showing == nil ? TourNoteMotion.maskOutDuration : TourNoteMotion.wordsOut + TourNoteMotion.moveSettle + 0.2
        if now - since >= .milliseconds(Int(wait * 1000)) { holdsRoomGuide = false }
    }

    // MARK: What is true now

    /// Whatever else the app shows on its first launch comes first (TECH_DESIGN §5.1): the
    /// reminder setup page, the app-icon alert, the iCloud restore offer. Then the room has to
    /// be free.
    private func isIdle(_ model: AppModel, _ reminders: ReminderScheduler, now: ContinuousClock.Instant) -> Bool {
        guard room.idle, reminders.pendingTap == nil, !AppIconSwitcher.isSwitching,
              QuickActionCenter.shared.pending == nil, !restorePending(model) else { return false }
        // The icon is changed a second after the app comes to the front; its alert is the system's.
        guard let activeSince, now - activeSince >= .milliseconds(1500) else { return false }
        guard let root = mainWindow?.rootViewController, root.presentedViewController == nil else { return false }
        return true
    }

    /// The page a chapter may begin on that is on top now, with nothing over it and nothing on its
    /// way: the company page, the photo library, the furniture library or the Play panel.
    private func freePage(_ reminders: ReminderScheduler, now: ContinuousClock.Instant) -> TourSurface? {
        guard !room.idle, reminders.pendingTap == nil, QuickActionCenter.shared.pending == nil,
              let activeSince, now - activeSince >= .milliseconds(1500), let root = mainWindow?.rootViewController else { return nil }
        var top = root
        while let next = top.presentedViewController { top = next }
        guard !top.isBeingPresented, !top.isBeingDismissed, top.transitionCoordinator == nil else { return nil }
        if TourCompanyPageSeen.shown { return .companyPage }
        return TourPages.all.first { TourPages.isUp($0, in: mainWindow) }
    }

    /// The iCloud listing has not answered yet, or the empty-room card offers a restore. The
    /// opening waits with no time limit (Q-04): `cloud.loaded` turns true before the listing is
    /// back, so the listing's answer is `availability`.
    private func restorePending(_ model: AppModel) -> Bool {
        guard model.options.cloudBackupFeature else { return false }
        return model.cloud.availability == nil || model.cloudRestoreOffered
    }

    private func snapshot() -> TourSnapshot {
        guard let model else { return TourSnapshot() }
        var snapshot = TourReplayEntry.listSnapshot(model)
        snapshot.surface = surface()
        snapshot.cameFromOutside = cameFromOutside
        snapshot.restoreOfferPending = restorePending(model)
        snapshot.answeredReminderSetup = reminders?.answeredFirstLaunchSetup ?? false
        snapshot.notificationsDenied = reminders?.authorization == .denied
        snapshot.anyReminderOn = reminders?.settings.anyEnabled ?? false
        return snapshot
    }

    /// Where the user is. A page chapters begin on counts only while it is on top and settled. In
    /// page mode (VoiceOver) a chapter does not begin on a page: its sheet would have to come over
    /// the page's own (`pageShown` is presented from the root); those chapters are told when opened
    /// from Settings.
    private func surface() -> TourSurface {
        if room.idle { return .room }
        guard let reminders, let page = freePage(reminders, now: .now) else { return .elsewhere }
        return TourLaunch.pageMode && page != .companyPage ? .elsewhere : page
    }

    /// True when a notification, a quick action, a widget or a link asked for something since
    /// the last look. The rest of this time in the foreground starts nothing on its own.
    @discardableResult
    private func noteOutsideRequests(_ reminders: ReminderScheduler) -> Bool {
        var asked = reminders.pendingTap != nil || QuickActionCenter.shared.pending != nil
        if QuickActionCenter.shared.companionRequest != companionSeen {
            companionSeen = QuickActionCenter.shared.companionRequest
            asked = asked || companionSeen != nil
        }
        if TourOutside.count != outsideSeen {
            outsideSeen = TourOutside.count
            asked = true
        }
        if asked { cameFromOutside = true }
        return asked
    }

    // MARK: The machine

    private func send(_ event: TourEvent) {
        guard var machine else { return }
        let effects = machine.handle(event)
        self.machine = machine
        for effect in effects {
            switch effect {
            case .save(let record): store.save(record, library: library)
            case .start(let run): begin(run)
            }
        }
    }

    private func begin(_ run: TourRun) {
        let page = page(for: run.chapter)
        let steps = TourScript.steps(run.chapter, context: context(for: run.chapter), naming: nil)
        lifted = false
        zoomHeldSince = nil
        let presentation: Presentation = TourLaunch.pageMode ? .page : .overlay
        // Opened from Settings with nothing to show it with (no furniture, no photos): its card
        // says so, and that is all (PRODUCT_PLAN §3.4 item 2).
        if run.mode == .replay, !run.demonstrates || steps.isEmpty,
           let placeholder = TourScript.placeholder(run.chapter, catName: catName,
                                                     roomHasFurniture: model?.roomFurniture.isEmpty == false) {
            showing = Showing(run: run, presentation: presentation, onCard: true, steps: [], placeholderLine: placeholder.line,
                              beganOn: page)
            log.notice("tour: \(run.chapter.rawValue, privacy: .public) has nothing to show, its card says so")
            if presentation == .page { pageShown = true } else { showOverlay() }
            return
        }
        // A chapter opened by hand that cannot be shown here (no cat in this room) ends at once;
        // ending a replay changes no record.
        guard !steps.isEmpty, run.demonstrates else {
            log.notice("tour: \(run.chapter.rawValue, privacy: .public) has nothing to show")
            showing = Showing(run: run, presentation: .overlay, onCard: false, steps: [])
            return finish(.skipped)
        }
        showing = Showing(run: run, presentation: presentation, onCard: hasCard(run), steps: steps,
                          cardLine: TourScript.cardLine(run.chapter, catName: catName, hasFurniture: (model?.state.items.count ?? 0) > 0),
                          beganOn: page)
        pageGoneSince = nil
        log.notice("tour: \(run.chapter.rawValue, privacy: .public) begins, \(presentation == .page ? "page" : "overlay", privacy: .public)")
        if presentation == .page {
            pageShown = true
        } else {
            showOverlay()
        }
    }

    private func finish(_ exit: TourExit) {
        guard let current = showing else { return }
        log.notice("tour: \(current.run.chapter.rawValue, privacy: .public) ends: \(String(describing: exit), privacy: .public)")
        showing = nil
        lifted = false
        namingShown = false
        namingDueSince = nil
        send(.finished(run: current.run.id, exit, snapshot()))
        if current.run.id == .finale { UserDefaults.standard.set(true, forKey: Self.finaleKey(library: library)) }
        if current.run.mode == .replay {
            TourReplayEntry.ended(exit)
            // Shown for real (not the placeholder card) and read to its end: 看过 in Settings.
            if current.run.demonstrates, current.placeholderLine == nil, exit == .completed || exit == .handedOff {
                TourReplayEntry.markReadAgain(current.run.chapter, library: library)
            }
        }
        // The opening may go straight on to the next chapter, in the same presentation.
        if showing?.presentation != .page { pageShown = false }
        if exit == .skippedAll {
            TransientNotice.show(TourText.skippedAll)
            noticeNotBefore = .now + Self.noticeAfterSkippedAll
        }
    }

    // MARK: The test build page

    /// 「好，不打扰你了。…」 is read first; the page then takes its place.
    static let noticeAfterSkippedAll: Duration = .milliseconds(1500)

    /// TestFlight, not read yet in this library, and every chapter of the opening has an ending
    /// in the record (done, skipped, skipped all, or grandfathered). Not on a visit that came from
    /// outside, and not over anything else: the room must have been free for half a second, which
    /// also lets the mask finish leaving.
    private func openNoticeIfDue(idle: Bool, now: ContinuousClock.Instant) -> Bool {
        guard !noticeDone, !noticeShown, let machine else { return false }
        guard TestBuildNotice.openingIsOver(catalog, record: machine.record), !cameFromOutside,
              !namingShown, !pageShown, squeezedPage == nil, overlay?.controller.isShowing != true else {
            noticeIdleSince = nil
            return false
        }
        if let noticeNotBefore, now < noticeNotBefore { return true }
        guard idle else {
            noticeIdleSince = nil
            return false
        }
        let since = noticeIdleSince ?? now
        noticeIdleSince = since
        guard now - since >= .milliseconds(500) else { return true }
        noticeNotBefore = nil
        noticeShown = true
        TransientNotice.hide()
        log.notice("tour: test build page")
        return true
    }

    /// 「知道了」 or 「去反馈」: read, not again.
    func noticeAnswered() {
        guard !noticeDone else { return }
        noticeDone = true
        TourTestBuild.markSeen(library: library)
    }

    /// The page went away. Closed by something else before it was answered (a quick action), it
    /// comes back at a later launch.
    func noticeClosed() {
        noticeShown = false
        noticeIdleSince = nil
    }

    /// Takes the chapter off the screen without an ending; the caller tells the machine why.
    private func putAway() {
        guard showing != nil else { return }
        showing = nil
        lifted = false
        namingShown = false
        namingDueSince = nil
        pageShown = false
    }

    private var catName: String { model?.leadCatName ?? "" }

    /// The page `chapter` begins on, when the user is on it now.
    private func page(for chapter: TourChapterID) -> TourSurface? {
        guard !room.idle else { return nil }
        let here = surface()
        return here == TourCatalog.current[chapter]?.surface || (here == .companyPage && chapter == .company) ? here : nil
    }

    private func context(for chapter: TourChapterID) -> TourScript.Context {
        let model = model
        let name = catName
        let plate = model.map { $0.currentRoom.name == nil && $0.roomName($0.currentRoom).contains(name) } ?? false
        return TourScript.Context(
            catName: name, plateShowsName: plate,
            looksLikeBella: model.map { CatPackLibrary.builtInIDs.contains($0.catPacks.activeID) } ?? false,
            reduceMotion: UIAccessibility.isReduceMotionEnabled,
            roomIsEmpty: model?.roomFurniture.isEmpty ?? true,
            emptyCardFolded: (mainWindow?.traitCollection.preferredContentSizeCategory)
                .flatMap { DynamicTypeSize($0) }.map(RoomScreen.foldsEmptyHint) ?? false,
            musicOn: UserDefaults.standard.bool(forKey: RoomSoundKeys.music),
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            memoryPiece: Self.memoryPiece(in: model?.roomFurniture ?? []),
            movablePiece: Self.movablePiece(in: model?.roomFurniture ?? []),
            liveActivitiesOn: TourDevice.liveActivitiesOn,
            companyRunning: PocketCatActivity.activities.contains(where: \.isOngoing),
            hasIsland: TourDevice.hasIsland(in: mainWindow),
            onCompanyPage: TourCompanyPageSeen.shown && !room.idle,
            onPage: page(for: chapter),
            hasSuggestEntry: model?.batchSuggestionsAvailable == true && mainWindow.map {
                TourAnchorRegistry.shared.probe("rerun-suggestions", in: $0) != nil
            } == true,
            pieceMenu: model.map(TourFacts.pieceMenu) ?? .none,
            oneCatPiece: model.map { TourFacts.catPieces($0).count == 1 } ?? false,
            anyReminderOn: reminders?.settings.anyEnabled ?? false)
    }

    /// 6.1's piece: one with photos, not locked if there is one (LINES.md T4.8), the largest on
    /// screen of those, so the window is easy to see and to touch.
    static func memoryPiece(in pieces: [PhotoFurniture]) -> String? {
        let withPhotos = pieces.filter { !$0.sources.isEmpty }
        let pool = withPhotos.contains { !$0.isLocked } ? withPhotos.filter { !$0.isLocked } : withPhotos
        return pool.max { $0.width * $0.depth < $1.width * $1.depth }?.instanceId
    }

    /// 7.1's piece: one that is not locked, on the floor (a wall piece is not dragged across the
    /// floor), the largest.
    static func movablePiece(in pieces: [PhotoFurniture]) -> String? {
        let free = pieces.filter { !$0.isLocked }
        let pool = free.contains { $0.wall == nil } ? free.filter { $0.wall == nil } : free
        return pool.max { $0.width * $0.depth < $1.width * $1.depth }?.instanceId
    }

    // MARK: The user's answers

    /// 「开始」 on the card, or 【下一步】 on a bubble.
    func next() {
        guard var current = showing else { return }
        if current.onCard {
            // The card of a chapter with nothing to show: 「知道了」 is its end.
            if current.placeholderLine != nil { return finish(.skipped) }
            current.onCard = false
            current.index = 0
            showing = current
            openNamingIfDue()
            return
        }
        guard let step = current.step else { return }
        // Page mode reads 4.2 too: there is no real control to hand over to.
        if (step.nextEnds && current.presentation == .overlay) || current.isLast { return finish(.completed) }
        // 12.1 to 12.3: 【下一步】 goes straight to the pages, not to a step whose control is not up.
        if current.presentation == .overlay, let goes = step.nextGoesTo,
           let target = current.steps.firstIndex(where: { $0.id == goes }) {
            current.index = target
            showing = current
            return
        }
        current.index += 1
        showing = current
        openNamingIfDue()
    }

    /// 【上一步】 in page mode.
    func back() {
        guard var current = showing, !current.onCard else { return }
        if current.index == 0 {
            current.onCard = hasCard(current.run)
        } else {
            current.index -= 1
            // The name is asked once: going back past it returns to the step before it.
            if current.step?.kind == .naming, current.naming != nil, current.index > 0 { current.index -= 1 }
        }
        showing = current
    }

    /// The overlay found no room for this step's bubble: the step is read as a page.
    func squeeze(_ key: TourOverlayScene.Key) {
        guard var current = showing, current.presentation == .overlay, sceneKey(current) == key,
              let step = current.step, !current.squeezed else { return }
        log.notice("tour: \(step.id, privacy: .public) has no room for its bubble, read as a page")
        current.squeezedStep = step.id
        showing = current
        syncSqueezedPage()
    }

    /// Presented by UIKit over whatever is on top (the 互动 panel on iPhone is a sheet already), and
    /// taken away when the step changes.
    private func syncSqueezedPage() {
        let wanted = showing?.squeezed == true
        if wanted, squeezedPage == nil, let root = mainWindow?.rootViewController {
            var top = root
            while let next = top.presentedViewController { top = next }
            guard !top.isBeingPresented, !top.isBeingDismissed else { return }
            let page = UIHostingController(rootView: TourPageView(coordinator: self, catName: catName))
            page.sheetPresentationController?.detents = [.large()]
            page.presentationController?.delegate = squeezedPageWatcher
            squeezedPage = page
            top.present(page, animated: true)
        } else if !wanted, let page = squeezedPage {
            squeezedPage = nil
            if page.presentingViewController != nil, !page.isBeingDismissed { page.dismiss(animated: true) }
        }
    }

    /// Chapter 12's pages (12.5 to 12.7), presented by UIKit over whatever is on top once the mask
    /// has gone, as a squeezed step's page is. Page mode shows them in its own sheet.
    private func syncCompanyPages() {
        let wanted = showing.map { $0.presentation == .overlay && !$0.onCard && $0.step?.kind == .companyPages } ?? false
        if wanted, companyPages == nil, overlay?.controller.isShowing != true, let root = mainWindow?.rootViewController {
            var top = root
            while let next = top.presentedViewController { top = next }
            guard !top.isBeingPresented, !top.isBeingDismissed else { return }
            let page = UIHostingController(rootView: companyPagesView())
            page.sheetPresentationController?.detents = [.large()]
            page.presentationController?.delegate = companyPagesWatcher
            companyPages = page
            log.notice("tour: company pages")
            top.present(page, animated: true)
            #if DEBUG
            if TourLaunch.dropsPages, !pagesDropped {
                pagesDropped = true
                Task { @MainActor [weak root] in
                    try? await Task.sleep(for: .seconds(2))
                    root?.dismiss(animated: true)
                }
            }
            #endif
        } else if !wanted, let page = companyPages {
            companyPages = nil
            if page.presentingViewController != nil, !page.isBeingDismissed { page.dismiss(animated: true) }
        }
    }

    func companyPagesView() -> TourCompanyPagesView {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let conditions = model.map(TourCompanyConditions.current) ?? TourCompanyConditions(hasCamera: false, hasPhotoFurniture: false)
        return TourCompanyPagesView(pages: TourScript.companyPages(isPad: isPad), conditions: conditions,
                                    liveActivitiesOn: TourDevice.liveActivitiesOn, isPad: isPad,
                                    skip: { [weak self] in self?.finish(.skipped) },
                                    done: { [weak self] in self?.finish(.completed) })
    }

    /// Swiped away: the same as 【跳过这一段】.
    private func companyPagesClosed() {
        companyPages = nil
        if showing?.step?.kind == .companyPages { finish(.skipped) }
    }

    /// Swiped away: the same as 【跳过这一段】.
    private func squeezedPageClosed() {
        squeezedPage = nil
        if showing?.squeezed == true { finish(.skipped) }
    }

    /// A chapter opened by hand shows its card; inside 「从头看一遍」 only chapter 1 does, as in the
    /// opening itself.
    private func hasCard(_ run: TourRun) -> Bool {
        guard run.mode == .replay, !TourReplayEntry.replaysOpening else { return TourScript.hasCard(run.chapter) }
        return TourScript.card(run.chapter, catName: catName) != nil
    }

    func skip() { finish(.skipped) }

    /// Page mode's sheet was swiped away: the same as 【跳过这一段】.
    /// A sheet of an older run closing late (a new run's page is wanted, or was not asked for
    /// yet) ends nothing.
    func pageClosed() {
        guard let current = showing, current.presentation == .page, !pageShown, current.run.id == pageRun else { return }
        finish(.skipped)
    }
    func skipAll() { finish(.skippedAll) }

    /// The overlay's report on a hand-off step, at each frame: whether the user's touch went
    /// through to the control, and whether something is over it. The chapter is handed over
    /// (rule 6) only when what the control opens is open by that touch (`TourRules.handOffEnding`).
    /// What comes next waits for the room to be free.
    func handOff(_ key: TourOverlayScene.Key, touched: Bool, covered: Bool) {
        guard let current = showing, current.presentation == .overlay, sceneKey(current) == key, let step = current.step,
              let exit = TourRules.handOffEnding(onHandOffStep: step.handsOff, userTouched: touched,
                                                 destinationOpened: destinationOpened(step, covered: covered))
        else { return }
        finish(exit)
    }

    /// What each hand-off step's control opens. A step not named here never hands over.
    private func destinationOpened(_ step: TourStep, covered: Bool) -> Bool {
        guard let mainWindow else { return false }
        let anchors = TourAnchorRegistry.shared
        return switch step.id {
        // With a camera the control is a menu. No state says it is up: it covers a room with
        // nothing in progress.
        case "2.3": room.pickingPhotos || (covered && room.idle)
        case "3.1": model?.addFurnitureShown == true || TourPages.isUp(.furnitureLibrary, in: mainWindow)
        // One piece: she is sent, or the piece's toy begins. Several: the piece's choices.
        case "11.1": (room.sentCat != nil && room.sentCat != sentCatAtStep) || room.playing
            || anchors.probe("send-cat-choices", in: mainWindow) != nil
        case "13.1": room.onTabletop
        case "14.2": anchors.probe("reminder-settings", in: mainWindow) != nil
        default: false
        }
    }

    /// The overlay's "do" step was done with the real control: the next target turned up.
    func didStep(_ key: TourOverlayScene.Key) {
        guard var current = showing, current.presentation == .overlay, sceneKey(current) == key,
              current.steps.indices.contains(current.index + 1) else { return }
        // On to the step the control opened; not 【下一步】, which may end the chapter (4.1).
        current.index += 1
        showing = current
    }

    private func openNamingIfDue() {
        guard let current = showing, current.step?.kind == .naming else { return }
        if current.naming != nil {
            // Asked already (page mode, going forward again): straight on.
            return next()
        }
        if current.presentation == .overlay, !namingShown, namingDueSince == nil {
            let due = ContinuousClock.now
            namingDueSince = due
            // Asked for at its time rather than at the next 100 ms tick: polled, the page came
            // 0.45 s after the mask had gone, and the bright room read as the tour's end (VISUAL
            // §13.3 a). The 100 ms tick is still there if the mask has not left by then.
            Task { @MainActor [weak self] in
                try? await Task.sleep(until: due + Self.namingAfterMask, clock: .continuous)
                self?.openNamingWhenClear(now: .now)
            }
        }
    }

    /// The page starts coming up in the mask's last 0.1 s: by then the mask is faint and the page
    /// rises from the bottom edge, away from where the bubble was (VISUAL §13.3 a).
    private static let namingAfterMask = Duration.milliseconds(Int((TourNoteMotion.maskOutDuration - 0.1) * 1000))

    /// The bubble fades (0.15 s) and the window opens outwards as the mask fades (0.3 s); then the
    /// page comes up on a room with no mask over it. A squeezed step's page goes first too.
    private func openNamingWhenClear(now: ContinuousClock.Instant) {
        guard let since = namingDueSince else { return }
        guard showing?.step?.kind == .naming else {
            namingDueSince = nil
            return
        }
        let clear = overlay?.controller.isShowing != true && squeezedPage == nil
        guard clear, now - since >= Self.namingAfterMask else { return }
        namingDueSince = nil
        namingShown = true
    }

    /// The naming page closed. nil: 「先不起名」, an empty field or a swipe down.
    func named(_ typed: String?) {
        namingShown = false
        guard !renaming, let current = showing, current.step?.kind == .naming, current.naming == nil, let model else { return }
        let run = current.run.id
        guard let typed, let name = AppState.normalizedCatName(typed), name != model.leadCatName, let cat = model.leadCat else {
            return continueAfterNaming(.notNamed, run: run)
        }
        // Written at once. A name does not hide the iCloud restore offer
        // (`AppState.isEmptyForRestoreOffer`), and restoring replaces it with the backup's.
        // Bound to the library it was typed for: a restore or clear meanwhile refuses the write,
        // and a late answer shows no error over another run or library (D24-10).
        let library = model.libraryGeneration
        renaming = true
        Task {
            let failure = await model.renameCat(cat.catId, to: name, generation: library)
            renaming = false
            guard showing?.run.id == run, model.libraryGeneration == library else { return }
            if let failure { renameFailure = failure.message }
            continueAfterNaming(failure == nil ? .named(name) : .notNamed, run: run)
        }
    }

    private func continueAfterNaming(_ result: TourScript.NamingResult, run: TourRunID) {
        // A late answer for a chapter that is no longer on screen moves nothing.
        guard var current = showing, current.run.id == run, current.step?.kind == .naming else { return }
        current.naming = result
        current.steps = TourScript.steps(current.run.chapter, context: context(for: current.run.chapter), naming: result)
        current.index += 1
        showing = current
    }

    // MARK: The overlay

    /// What the overlay window shows now. Read by it every frame.
    var overlayScene: TourOverlayScene {
        guard let current = showing, current.presentation == .overlay, !current.squeezed, !namingShown, !renaming,
              renameFailure == nil else {
            return .nothing
        }
        if current.onCard, let card = TourScript.card(current.run.chapter, catName: catName) {
            return .card(key: sceneKey(current), title: card.title, line: current.placeholderLine ?? current.cardLine ?? card.line, art: card.art,
                         firstChapter: current.run.chapter == .welcome && current.run.mode == .auto,
                         startTitle: current.startTitle, placeholder: current.placeholderLine != nil)
        }
        guard let step = current.step, step.kind == .bubble else { return .nothing }
        return .step(key: sceneKey(current), step: step, number: current.bubbleNumber, count: current.bubbleCount,
                     nextTitle: current.nextTitle)
    }

    private func sceneKey(_ showing: Showing) -> TourOverlayScene.Key {
        TourOverlayScene.Key(run: showing.run.id, card: showing.onCard, step: showing.step?.id ?? "")
    }

    private func showOverlay() {
        guard let window = mainWindow, let scene = window.windowScene else { return }
        if overlay == nil {
            let overlay = TourOverlayWindow(windowScene: scene, coordinator: self, main: window)
            self.overlay = overlay
        }
        // Never `makeKeyAndVisible`: the room finds its root controller through the key window.
        overlay?.isHidden = false
    }

    /// Called by the overlay when it has nothing left to show.
    func overlayIdle() {
        guard showing == nil || showing?.presentation == .page else { return }
        overlay?.isHidden = true
    }

    // MARK: DEBUG

    #if DEBUG
    @ObservationIgnored private var pagesDropped = false

    private func plant(_ seed: String) {
        var record = TourRecord()
        record.opens = TourLaunch.seedOpens ?? 1
        let ids: [TourChapterID] = seed == "veteran" ? catalog.chapters.map(\.id) : seed.split(separator: ",").map { TourChapterID(String($0)) }
        for id in ids {
            record.chapters[id.rawValue] = TourEntry(outcome: seed == "veteran" ? .grandfathered : .completed, revision: 1)
        }
        store.save(record, library: library)
    }

    /// For the probe: what the tour is doing.
    var probe: String {
        guard let showing else { return "none" }
        return "\(showing.run.chapter.rawValue) \(showing.onCard ? "card" : showing.step?.id ?? "-")"
            + " \(showing.presentation == .page ? "page" : "overlay")"
    }
    #endif
}

/// Tells the tour when the page of a squeezed step was swiped away.
private final class SqueezedPageWatcher: NSObject, UIAdaptivePresentationControllerDelegate {
    private let closed: () -> Void
    init(closed: @escaping () -> Void) { self.closed = closed }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { closed() }
}
