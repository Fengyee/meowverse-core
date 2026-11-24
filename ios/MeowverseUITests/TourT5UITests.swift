import XCTest

/// The tour's on-demand chapters 8, 9, 10, 11, 13, 14 and 15 (T5), one main path each, with the
/// variants LINES.md T5.10 and T5.14 name: no AR, sorting taking the chapter over, 「未放进家具」
/// tapped in 9.1's window, the grid of covers, a replay begun in the room, and the 「都讲完啦」 card.
/// Every other chapter is planted as read (`-MeowverseTourSeed`), so the one under test is what
/// comes. Photos come from the app's own synthetic import (DEBUG `-MeowverseSyntheticPhoto`).
///
/// `tour-status` (DEBUG) reads `tour=<chapter> <step|card> <overlay|page> show=0|1 why=… hole=x,y,w,h …`.
/// Review shots go to `TEST_RUNNER_MV_SHOT_DIR` as `<MV_SHOT_PREFIX>-<name>.png` when set.
final class TourT5UITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private static let chapters = ["welcome", "bring-photo", "furnish-first", "play", "top-row", "memories", "move-and-look",
                                   "photo-batch", "photo-library", "furniture-library", "send-cat", "company", "tabletop",
                                   "reminders", "backup"]

    /// Every chapter but these, as read.
    private static func allBut(_ left: String...) -> String {
        chapters.filter { !left.contains($0) }.joined(separator: ",")
    }

    private func launch(_ store: String, seed: String?, tour: String = "auto", reset: Bool = true,
                        extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.current + ["-MeowverseStore", store, "-MeowverseTour", tour]
            + (reset ? ["-MeowverseResetStore"] : []) + (seed.map { ["-MeowverseTourSeed", $0] } ?? []) + extra
        app.launch()
        return app
    }

    private func status(_ app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any)["tour-status"].firstMatch
        guard element.exists else { return "" }
        // It leaves with the tour's window, also between the two looks: `value` then fails the test.
        return (try? element.snapshot())?.value as? String ?? ""
    }

    @discardableResult
    private func waitStatus(_ app: XCUIApplication, _ tour: String, timeout: TimeInterval = 25,
                            file: StaticString = #filePath, line: UInt = #line) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        func ok(_ value: String) -> Bool { value.contains("tour=\(tour) ") && value.contains("show=1") }
        while Date() < deadline {
            last = status(app)
            if ok(last) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(ok(last), "waiting for \(tour): \(last)", file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        return status(app)
    }

    private func waitGone(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(6)
        var last = status(app)
        while Date() < deadline, !(last.isEmpty || last.contains("tour=none")) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            last = status(app)
        }
        XCTAssertTrue(last.isEmpty || last.contains("tour=none"), "the chapter ended: \(last)", file: file, line: line)
    }

    /// For `seconds`, the tour shows nothing.
    private func assertQuiet(_ app: XCUIApplication, _ seconds: TimeInterval, _ why: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            let now = status(app)
            XCTAssertFalse(now.contains("show=1"), "\(why): \(now)", file: file, line: line)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
    }

    private func hole(_ status: String) -> CGRect? { rect("hole", in: status) }

    private func rect(_ key: String, in status: String) -> CGRect? {
        guard let range = status.range(of: key + #"=[-0-9.]+,[-0-9.]+,[0-9.]+,[0-9.]+"#, options: .regularExpression) else { return nil }
        let numbers = status[range].dropFirst(key.count + 1).split(separator: ",").compactMap { Double($0) }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    private func assertHole(_ status: String, around target: XCUIElement, _ name: String, in app: XCUIApplication,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(target.exists, name, file: file, line: line)
        guard let hole = hole(status) else { return XCTFail("no hole: \(status)", file: file, line: line) }
        let frame = target.frame
        XCTAssertTrue(hole.contains(CGPoint(x: frame.midX, y: frame.midY)), "\(name) \(frame) not in \(hole)", file: file, line: line)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(frame), "\(name) is on screen, not cut off: \(frame)",
                      file: file, line: line)
        // The window itself stays on the screen, 4 pt in (VISUAL §18.2 item 2: 9.1 and 9.2 ran off it).
        let screen = app.windows.firstMatch.frame.insetBy(dx: 3.5, dy: 3.5)
        XCTAssertTrue(screen.contains(hole), "\(name): the window \(hole) leaves the screen \(screen)", file: file, line: line)
        // The bubble beside the window, not on it: placed once the row has come to rest (11.2 had
        // its bubble placed before the list scrolled, and the row slid under it).
        let now = self.status(app)
        if let shownHole = self.hole(now), let bubble = rect("bubble", in: now) {
            XCTAssertFalse(shownHole.insetBy(dx: 1, dy: 1).intersects(bubble), "\(name): the bubble \(bubble) covers the window \(shownHole)",
                           file: file, line: line)
        }
    }

    /// A list row's window is the row's card, near the screen's width, not the words alone
    /// (VISUAL §18.2 item 1).
    private func assertRowWindow(_ status: String, _ name: String, in app: XCUIApplication,
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard let hole = hole(status) else { return XCTFail("no hole: \(status)", file: file, line: line) }
        let width = app.windows.firstMatch.frame.width
        XCTAssertGreaterThan(hole.width, width - 60, "\(name): the window \(hole) is the row's card", file: file, line: line)
    }

    private func assertHole(_ status: String, around id: String, in app: XCUIApplication,
                            file: StaticString = #filePath, line: UInt = #line) {
        assertHole(status, around: app.descendants(matching: .any)[id].firstMatch, id, in: app, file: file, line: line)
    }

    private func tap(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[id].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), id, file: file, line: line)
        for _ in 0..<20 where !button.isHittable { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        button.tap()
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["MV_SHOT_DIR"] else { return }
        let prefix = environment["MV_SHOT_PREFIX"].map { $0 + "-" } ?? ""
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(prefix + name + ".png"))
    }

    /// A sofa from the synthetic photo, placed where the app suggests it.
    private func addSofa(_ app: XCUIApplication, _ piece: String = "manual-sofa", waitsForReceipt: Bool = true) {
        XCTAssertTrue(app.buttons["add-synthetic"].waitForExistence(timeout: 30))
        app.buttons["add-synthetic"].tap()
        for id in [piece, "next-model", "next-placement", "confirm-placement"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 20), id)
            button.tap()
        }
        let receipt = app.descendants(matching: .any)["photo-storage-receipt"].firstMatch
        if !receipt.waitForExistence(timeout: 10), app.buttons["confirm-placement"].exists { app.buttons["confirm-placement"].tap() }
        if waitsForReceipt { _ = receipt.waitForNonExistence(timeout: 15) }
    }

    /// The synthetic batch (`-MeowverseSyntheticBatch <count> 1`), stored and waiting to be sorted.
    private func addBatch(_ app: XCUIApplication, _ count: Int) {
        app.addSyntheticBatch()
        let pending = app.descendants(matching: .any)["pending-count"].firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 60), "the batch was stored")
    }

    private func element(_ app: XCUIApplication, beginningWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    // MARK: Replay

    /// Settings › 使用导览, then one of its rows.
    private func replay(_ app: XCUIApplication, _ row: String, file: StaticString = #filePath, line: UInt = #line) {
        app.tapSettingsGear(file: file, line: line)
        let entry = app.buttons["open-tour"]
        for _ in 0..<8 where !(entry.exists && entry.isHittable) { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "open-tour", file: file, line: line)
        entry.tap()
        let button = app.buttons["tour-replay-\(row)"]
        for _ in 0..<6 where !(button.exists && button.isHittable) { app.swipeUp() }
        button.tap()
    }

    /// The cat was sent to a piece from 互动, and she is there or on her way. 「从头看一遍」 and a
    /// single chapter still open: the room is free again once the panel has gone. They did nothing
    /// for the rest of the process (owner's iPhone, 2026-11-21): the last invitation is kept for
    /// as long as the room lives, and the room counted it as something in progress.
    func testReplayAfterTheCatWasSentToAPiece() {
        let app = launch("tour-t5-replay-invited", seed: "veteran", extra: ["-MeowverseSyntheticPhoto"])
        addSofa(app)
        tap(app, "choose-interaction")
        let action = element(app, beginningWith: "invite-")
        XCTAssertTrue(action.waitForExistence(timeout: 10), "the piece's actions")
        action.tap()
        XCTAssertTrue(action.waitForNonExistence(timeout: 10), "the panel closed")

        replay(app, "all")
        waitStatus(app, "welcome card", timeout: 25)
        XCTAssertTrue(app.buttons["tour-card-skip-all"].exists, "chapter 1's replay card")
        tap(app, "tour-card-skip-all")
        waitGone(app)

        replay(app, "top-row")
        waitStatus(app, "top-row card", timeout: 25)
        tap(app, "tour-card-later")
        waitGone(app)
    }

    /// Chapter 12 up to its pages, which are then dismissed under it without the sheet's delegate
    /// being told, as when the page below them is taken away (`-MeowverseTourDropsPages`, DEBUG).
    private func launchAndLoseCompanyPages(_ store: String) -> XCUIApplication {
        let app = launch(store, seed: Self.allBut("company"), extra: ["-MeowverseTourDropsPages"])
        waitStatus(app, "company card", timeout: 40)
        tap(app, "tour-card-start")
        waitStatus(app, "company 12.1")
        tap(app, "tour-next")
        let pages = app.descendants(matching: .any)["tour-company-line"].firstMatch
        XCTAssertTrue(pages.waitForExistence(timeout: 10), "the pages")
        XCTAssertTrue(pages.waitForNonExistence(timeout: 15), "the pages were taken away")
        return app
    }

    /// A chapter with nothing left on screen does not hold a replay back: it was `showing` for the
    /// rest of the process, and the replay queue waited behind it.
    func testReplayWinsOverAChapterLeftBehind() {
        let app = launchAndLoseCompanyPages("tour-t5-replay-left-behind")
        replay(app, "top-row")
        waitStatus(app, "top-row card", timeout: 25)
        tap(app, "tour-card-later")
        waitGone(app)
    }

    /// Left behind off a hand-off step, the chapter ends without being recorded as read or
    /// skipped: it comes again at the next arrival in the room.
    func testChapterLeftBehindIsPutAwayWithoutAnEnding() {
        let app = launchAndLoseCompanyPages("tour-t5-left-behind")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        tap(app, "choose-interaction")
        let cancel = app.navigationBars.buttons["close-interaction"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        waitStatus(app, "company card", timeout: 20)
    }

    // MARK: Left behind, and the sent cat's visit (QA R-1 to R-3)

    /// CoreAudio can hold the main thread for 15 s on a Mac; these tests watch the clock.
    private static let quiet = ["-room.soundEffects", "<false/>"]

    /// 3.1 is pending with its button folded away at this text size. A replay asked for takes the
    /// place at once, with no 30 s of waiting, and chapter 3 is still untold.
    func testReplayOverAHandOffNeverSeenLeavesItUntold() {
        let store = "tour-t5-unseen-hand-off"
        let app = launch(store, seed: "welcome,bring-photo",
                         extra: Self.quiet + ["-MeowverseTourBlockedLimit", "600",
                                              "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 40))
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        let pending = status(app)
        XCTAssertTrue(pending.contains("tour=furnish-first"), "3.1 is pending: \(pending)")
        XCTAssertFalse(pending.contains("show=1"), "and not on screen: \(pending)")
        replay(app, "backup")
        waitStatus(app, "backup card", timeout: 25)
        app.terminate()

        let again = launch(store, seed: nil, reset: false, extra: Self.quiet)
        waitStatus(again, "furnish-first 3.1", timeout: 40)
    }

    /// 13.1 is read as a page at this text size. The Home Screen's camera action takes the pages
    /// away: the tabletop was never opened, so the chapter has no ending and is not all that is told.
    func testQuickActionOverASqueezedHandOffLeavesItUntold() {
        let store = "tour-t5-squeezed-hand-off"
        let extra = Self.quiet + ["-MeowverseShowAREntry", "-MeowverseFakeCamera"]
        let app = launch(store, seed: Self.allBut("tabletop"),
                         extra: extra + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 40))
        tap(app, "choose-interaction")
        waitStatus(app, "tabletop card", timeout: 30)
        tap(app, "tour-card-start")
        XCTAssertTrue(app.descendants(matching: .any)["tour-page-words"].firstMatch.waitForExistence(timeout: 10), "13.1 is a page")

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let name = app.label
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let icon = springboard.icons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 10), "the icon")
        for _ in 0..<4 where !icon.isHittable { springboard.swipeLeft() }
        icon.press(forDuration: 1.5)
        let camera = springboard.buttons[AppText.string("拍照添加")].firstMatch
        XCTAssertTrue(camera.waitForExistence(timeout: 8), "the quick action")
        camera.tap()
        let cancel = app.buttons["fake-camera-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 20), "the camera")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        cancel.tap()
        assertQuiet(app, 6, "no card after the camera")
        app.terminate()

        let again = launch(store, seed: nil, reset: false, extra: extra)
        XCTAssertTrue(again.buttons["choose-interaction"].waitForExistence(timeout: 40))
        assertQuiet(again, 4, "not all told")
        tap(again, "choose-interaction")
        waitStatus(again, "tabletop card", timeout: 25)
    }

    /// Sent while the receipt is up: its going does not bring chapter 6 over her. The next visit has it.
    func testCatSentUnderTheReceiptKeepsTheVisit() {
        let app = launch("tour-t5-sent-receipt", seed: Self.allBut("memories"), extra: Self.quiet + ["-MeowverseSyntheticPhoto"])
        addSofa(app, waitsForReceipt: false)
        tap(app, "choose-interaction")
        let action = element(app, beginningWith: "invite-")
        XCTAssertTrue(action.waitForExistence(timeout: 10), "the piece's actions")
        let receipt = app.descendants(matching: .any)["photo-storage-receipt"].firstMatch
        XCTAssertTrue(receipt.exists, "the receipt is still up")
        action.tap()
        assertQuiet(app, 18, "nothing over the cat the user sent")
        XCTAssertFalse(receipt.exists, "the receipt went while watched")
        tap(app, "choose-interaction")
        tap(app, "close-interaction")
        waitStatus(app, "memories card", timeout: 20)
    }

    // MARK: What hands over (TECH_DESIGN §5.7)

    /// No camera, so no menu: the photo picker's own page is what 2.3 hands over to.
    func testTwoPointThreeHandsOverToThePhotoPicker() {
        let app = launch("tour-t5-picker-hand-off", seed: "welcome", extra: Self.quiet)
        waitStatus(app, "bring-photo 2.1", timeout: 40)
        tap(app, "tour-next")
        waitStatus(app, "bring-photo 2.2")
        tap(app, "tour-next")
        waitStatus(app, "bring-photo 2.3")
        tap(app, "add-photo")
        waitGone(app)
    }

    /// A furnished room: 3.1 hands over to the furniture library.
    func testThreePointOneHandsOverToTheFurnitureLibrary() {
        let app = launch("tour-t5-list-hand-off", seed: "veteran", extra: Self.quiet + ["-MeowverseSyntheticPhoto"])
        addSofa(app)
        replay(app, "furnish-first")
        waitStatus(app, "furnish-first card", timeout: 25)
        tap(app, "tour-card-start")
        waitStatus(app, "furnish-first 3.1")
        tap(app, "furniture-list")
        waitGone(app)
    }

    /// The row itself: the tabletop was asked for, so chapter 13 has its ending and all is told.
    func testThirteenPointOneHandsOverToTheTabletop() {
        let store = "tour-t5-tabletop-hand-off"
        let extra = Self.quiet + ["-MeowverseShowAREntry"]
        let app = launch(store, seed: Self.allBut("tabletop"), extra: extra)
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 40))
        tap(app, "choose-interaction")
        waitStatus(app, "tabletop card", timeout: 20)
        tap(app, "tour-card-start")
        waitStatus(app, "tabletop 13.1")
        tap(app, "open-ar-tabletop")
        waitGone(app)
        app.terminate()
        let again = launch(store, seed: nil, reset: false, extra: extra)
        waitStatus(again, "all-done card", timeout: 40)
    }

    /// The row itself: the reminder settings were opened, so chapter 14 has its ending.
    func testFourteenPointTwoHandsOverToTheReminderSettings() {
        let app = launch("tour-t5-reminders-hand-off", seed: Self.allBut("reminders"),
                         extra: Self.quiet + ["-MeowverseTourSeedOpens", "2"])
        waitStatus(app, "reminders card", timeout: 40)
        tap(app, "tour-card-start")
        waitStatus(app, "reminders 14.1")
        tap(app, "open-settings")
        waitStatus(app, "reminders 14.2", timeout: 15)
        tap(app, "open-reminders")
        waitGone(app)
    }

    // MARK: Chapter 8

    /// A batch comes home: once it is stored, chapter 8's card, then 8.1 on 「整理」. Tapping it
    /// hands the chapter over: sorting has its own words, and no mask comes over it (T5.1).
    func testChapterEightHandsOverToSorting() {
        let app = launch("tour-t5-batch", seed: Self.allBut("photo-batch"),
                         extra: ["-MeowverseSyntheticPhoto", "-MeowverseSyntheticBatch", "3", "1"])
        app.addSyntheticBatch()
        let card = waitStatus(app, "photo-batch card", timeout: 60)
        XCTAssertTrue(app.descendants(matching: .any)["pending-count"].exists, "after the batch was stored: \(card)")
        snap(app, "t5-8-card")
        tap(app, "tour-card-start")
        assertHole(waitStatus(app, "photo-batch 8.1"), around: "start-sorting", in: app)
        snap(app, "t5-8.1")
        // The window lets the tap through: sorting begins and the chapter is handed over.
        tap(app, "start-sorting")
        XCTAssertTrue(app.navigationBars[AppText.string("整理照片 %lld / %lld", 1, 3)].waitForExistence(timeout: 20), "sorting began")
        waitGone(app)
        assertQuiet(app, 4, "no mask over sorting")
        snap(app, "t5-8-sorting")
    }

    // MARK: Chapter 9

    /// The photo library opened by hand: chapter 9's card over it, 9.1 on the filters, 9.2 on the
    /// first photo with 「知道了」. Under 「全部」 there is no 「按建议放进家具」, so no 9.3.
    func testChapterNineOnThePhotoLibrary() {
        let app = launch("tour-t5-library", seed: Self.allBut("photo-library"), extra: ["-MeowverseSyntheticPhoto"])
        addSofa(app)
        assertQuiet(app, 3, "chapter 9 waits for its page")
        tap(app, "photo-library")
        waitStatus(app, "photo-library card", timeout: 20)
        snap(app, "t5-9-card")
        tap(app, "tour-card-start")
        let first = waitStatus(app, "photo-library 9.1")
        assertHole(first, around: "filter-unlinked", in: app)
        snap(app, "t5-9.1")
        tap(app, "tour-next")
        let second = waitStatus(app, "photo-library 9.2")
        assertHole(second, around: "library-photo", in: app)
        XCTAssertEqual(app.buttons["tour-next"].label, AppText.string("tour.gotIt", table: "Tour"), "no 9.3 without 按建议放进家具")
        snap(app, "t5-9.2")
        tap(app, "tour-next")
        waitGone(app)
        XCTAssertTrue(app.buttons["filter-all"].isSelected || app.buttons["filter-all"].exists, "still on the library")
    }

    /// 9.1's window lets 「未放进家具」 through (T5.14): the filter changes, the photos waiting are
    /// listed with 「按建议放进家具」, and 9.3 comes after 9.2. The tour never changes the filter.
    func testChapterNineFilterTapBringsTheSuggestions() {
        let app = launch("tour-t5-library-unlinked", seed: Self.allBut("photo-library"),
                         extra: ["-MeowverseSyntheticPhoto", "-MeowverseSyntheticBatch", "3", "1"])
        addSofa(app)
        addBatch(app, 3)
        tap(app, "photo-library")
        waitStatus(app, "photo-library card", timeout: 20)
        tap(app, "tour-card-start")
        waitStatus(app, "photo-library 9.1")
        XCTAssertFalse(app.buttons["rerun-suggestions"].exists, "under 全部 there is no 按建议放进家具")
        // A tap elsewhere in the window does nothing; on 「未放进家具」 it goes through.
        tap(app, "filter-unlinked")
        XCTAssertTrue(app.buttons["rerun-suggestions"].waitForExistence(timeout: 10), "the filter changed")
        waitStatus(app, "photo-library 9.1")
        XCTAssertEqual(app.buttons["tour-next"].label, AppText.string("tour.next", table: "Tour"))
        tap(app, "tour-next")
        assertHole(waitStatus(app, "photo-library 9.2"), around: "library-photo", in: app)
        tap(app, "tour-next")
        let third = waitStatus(app, "photo-library 9.3")
        assertHole(third, around: "rerun-suggestions", in: app)
        XCTAssertEqual(app.buttons["tour-next"].label, AppText.string("tour.gotIt", table: "Tour"))
        snap(app, "t5-9.3")
        tap(app, "tour-next")
        waitGone(app)
    }

    /// 「未放进家具」 tapped in 9.1 when every photo is in furniture: the page is empty, so 9.1 ends
    /// the chapter with 「知道了」 and there is no 9.2 on a photo that is not there (QA_T5 must-fix 2).
    func testChapterNineEndsAtTheFiltersWhenNoPhotoIsLeft() {
        let app = launch("tour-t5-library-empty", seed: Self.allBut("photo-library"), extra: ["-MeowverseSyntheticPhoto"])
        addSofa(app)
        tap(app, "photo-library")
        waitStatus(app, "photo-library card", timeout: 20)
        tap(app, "tour-card-start")
        waitStatus(app, "photo-library 9.1")
        XCTAssertEqual(app.buttons["tour-next"].label, AppText.string("tour.next", table: "Tour"), "a photo under 全部: 9.2 comes")
        tap(app, "filter-unlinked")
        XCTAssertTrue(app.buttons["filter-unlinked"].isSelected || app.buttons["filter-unlinked"].waitForExistence(timeout: 2))
        let deadline = Date().addingTimeInterval(5)
        let gotIt = AppText.string("tour.gotIt", table: "Tour")
        while Date() < deadline, app.buttons["tour-next"].label != gotIt { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertEqual(app.buttons["tour-next"].label, gotIt, "no photo left on the page: 9.1 is the last step")
        XCTAssertTrue(status(app).contains("tour=photo-library 9.1 "), status(app))
        snap(app, "t5-9.1-empty")
        tap(app, "tour-next")
        let until = Date().addingTimeInterval(3)
        while Date() < until {
            XCTAssertFalse(status(app).contains(" 9.2 "), "no 9.2: \(status(app))")
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        waitGone(app)
    }

    /// Opened from Settings while in the room: a step on 「照片库」 first, and 9.1 once it is open.
    func testChapterNineReplayBeginsInTheRoom() {
        let app = launch("tour-t5-library-replay", seed: "veteran", tour: "photo-library", extra: ["-MeowverseSyntheticPhoto"])
        waitStatus(app, "photo-library card", timeout: 40)
        let needs = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", AppText.string("tour.needsPhoto.line", table: "Tour"))).firstMatch
        XCTAssertTrue(needs.exists, "no photo yet: the placeholder card")
        tap(app, "tour-card-start")
        waitGone(app)
        app.terminate()

        let again = launch("tour-t5-library-replay2", seed: "veteran", extra: ["-MeowverseSyntheticPhoto"])
        addSofa(again)
        again.terminate()
        let third = launch("tour-t5-library-replay2", seed: nil, tour: "photo-library", reset: false)
        waitStatus(third, "photo-library card", timeout: 40)
        tap(third, "tour-card-start")
        assertHole(waitStatus(third, "photo-library 9.0"), around: "photo-library", in: third)
        snap(third, "t5-9.0")
        tap(third, "photo-library")
        assertHole(waitStatus(third, "photo-library 9.1"), around: "filter-unlinked", in: third)
        tap(third, "tour-next")
        waitStatus(third, "photo-library 9.2")
        tap(third, "tour-next")
        waitGone(third)
    }

    /// Page mode, opened from Settings in the room: 9.0 and 10.0 say only where the bookplate is.
    /// "Right here, tap to take a look" pointed at a window a page does not have, whose only button
    /// is 【下一步】 (T5.15, QA_EN).
    func testChaptersNineAndTenAsPagesSayOnlyWhereTheBookplateIs() {
        let setup = launch("tour-t5-lead-in-page", seed: "veteran", extra: ["-MeowverseSyntheticPhoto"])
        addSofa(setup)
        setup.terminate()
        let words = { (app: XCUIApplication) in app.descendants(matching: .any)["tour-page-words"].firstMatch }
        // Two fragments of the line for a window ("right here, tap"): either one alone is wrong on a page.
        let invitation = TestLanguage.isEnglish ? ["Tap to take a look", "right here"] : ["点开看看", "在这里"]
        for (chapter, place, open) in [("photo-library", AppText.string("tour.place.photoLibrary", table: "Tour"),
                                        AppText.string("tour.photoLibrary.open", table: "Tour")),
                                       ("furniture-library", AppText.string("tour.place.furnitureList", table: "Tour"),
                                        AppText.string("tour.furnitureLibrary.open", table: "Tour"))] {
            for part in invitation {
                XCTAssertTrue(open.contains(part), "“\(part)” is no longer in the window's line, so cannot catch it: \(open)")
            }
            let app = launch("tour-t5-lead-in-page", seed: nil, tour: chapter, reset: false, extra: ["-MeowverseTourPage"])
            let start = app.buttons["tour-page-start"]
            XCTAssertTrue(start.waitForExistence(timeout: 40), "\(chapter)'s card as a page")
            start.tap()
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, !words(app).label.contains(place) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            let label = words(app).label
            XCTAssertTrue(label.contains(place), "\(chapter): where it is: \(label)")
            for part in invitation {
                XCTAssertFalse(label.contains(part), "\(chapter): nothing to tap here, “\(part)”: \(label)")
            }
            snap(app, "t5-\(chapter)-lead-in-page")
            app.terminate()
        }
    }

    // MARK: Chapter 10

    /// The furniture library opened by hand: 10.1 on 「添加家具」, 10.2 on the sofa's 「⋯」.
    func testChapterTenOnTheFurnitureLibrary() {
        let app = launch("tour-t5-furniture", seed: Self.allBut("furniture-library"), extra: ["-MeowverseSyntheticPhoto"])
        addSofa(app)
        tap(app, "furniture-list")
        waitStatus(app, "furniture-library card", timeout: 20)
        snap(app, "t5-10-card")
        tap(app, "tour-card-start")
        assertHole(waitStatus(app, "furniture-library 10.1"), around: "add-furniture", in: app)
        snap(app, "t5-10.1")
        tap(app, "tour-next")
        assertHole(waitStatus(app, "furniture-library 10.2"), around: "piece-menu", in: app)
        XCTAssertEqual(app.buttons["tour-next"].label, AppText.string("tour.gotIt", table: "Tour"))
        snap(app, "t5-10.2")
        tap(app, "tour-next")
        waitGone(app)
    }

    /// In the grid of covers there is no 「⋯」: 10.1 alone, with 「知道了」 (T5.14).
    func testChapterTenInTheGridHasNoMenuStep() {
        let app = launch("tour-t5-furniture-grid", seed: Self.allBut("furniture-library"), extra: ["-MeowverseSyntheticPhoto"])
        // Covers chosen while the room is empty, when the chapter cannot begin yet; the card then
        // comes over the grid once there is a piece.
        tap(app, "furniture-list")
        tap(app, "furniture-layout")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        tap(app, "close-furniture-list")
        addSofa(app)
        tap(app, "furniture-list")
        waitStatus(app, "furniture-library card", timeout: 20)
        XCTAssertTrue(app.descendants(matching: .any)["list-room-item"].firstMatch.exists, "the sofa is listed")
        XCTAssertFalse(app.buttons["piece-menu"].exists, "the grid of covers")
        snap(app, "t5-10-grid-card")
        tap(app, "tour-card-start")
        let only = waitStatus(app, "furniture-library 10.1")
        XCTAssertEqual(app.buttons["tour-next"].label, AppText.string("tour.gotIt", table: "Tour"), "no 10.2 in the grid: \(only)")
        tap(app, "tour-next")
        waitGone(app)
    }

    // MARK: Chapter 11

    /// 互动 opened by hand with the sofa in the room: 11.1 on the sofa's first action (one piece),
    /// 11.2 on the first walking style, scrolled into view before its window opens.
    func testChapterElevenThenTheWalkingStyles() {
        let app = launch("tour-t5-send", seed: Self.allBut("send-cat"), extra: ["-MeowverseSyntheticPhoto"])
        addSofa(app)
        tap(app, "choose-interaction")
        waitStatus(app, "send-cat card", timeout: 20)
        snap(app, "t5-11-card")
        tap(app, "tour-card-start")
        let first = waitStatus(app, "send-cat 11.1")
        assertHole(first, around: element(app, beginningWith: "invite-"), "the sofa's first action", in: app)
        assertRowWindow(first, "11.1", in: app)
        snap(app, "t5-11.1")
        tap(app, "tour-next")
        // For a recording of the change to 11.2, nothing queries the app during it.
        if let linger = ProcessInfo.processInfo.environment["MV_LINGER"].flatMap(Double.init) {
            RunLoop.current.run(until: Date().addingTimeInterval(linger))
        }
        let second = waitStatus(app, "send-cat 11.2")
        assertHole(second, around: element(app, beginningWith: "ground-gait-"), "the first walking style", in: app)
        assertRowWindow(second, "11.2", in: app)
        XCTAssertEqual(app.buttons["tour-next"].label, AppText.string("tour.gotIt", table: "Tour"))
        snap(app, "t5-11.2")
        tap(app, "tour-next")
        waitGone(app)
    }

    /// 11.2's words are never cut short beside its row: when they do not all fit (iPhone SE,
    /// Accessibility XL), 11.2 is read as a page over the Play panel, and the page says the panel is
    /// right behind it (VISUAL §17.10.2, LINES.md E.1). The text size comes from
    /// `TEST_RUNNER_MV_TEXT_SIZE` (Accessibility XL when unset).
    func testChapterElevenWalkingStylesWholeOrAPage() {
        let size = ProcessInfo.processInfo.environment["MV_TEXT_SIZE"] ?? "UICTContentSizeCategoryAccessibilityXL"
        let app = launch("tour-t5-send-big", seed: Self.allBut("send-cat"),
                         extra: ["-MeowverseSyntheticPhoto", "-UIPreferredContentSizeCategoryName", size])
        addSofa(app)
        tap(app, "choose-interaction")
        waitStatus(app, "send-cat card", timeout: 20)
        tap(app, "tour-card-start")
        let tag = size.replacingOccurrences(of: "UICTContentSizeCategory", with: "")
        let pageNext = app.descendants(matching: .any)["tour-page-next"].firstMatch
        // 11.1 as a bubble, or already a page at this size.
        if !pageNext.waitForExistence(timeout: 4) {
            waitStatus(app, "send-cat 11.1")
            tap(app, "tour-next")
        } else {
            pageNext.tap()
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !pageNext.exists, !status(app).contains("tour=send-cat 11.2 overlay show=1") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        if pageNext.exists {
            let words = app.descendants(matching: .any)["tour-page-words"].firstMatch
            XCTAssertTrue(words.label.contains(AppText.string("tour.place.gait.onPanel", table: "Tour")), "the page says the panel is behind it: \(words.label)")
            XCTAssertEqual(pageNext.label, AppText.string("tour.gotIt", table: "Tour"))
            snap(app, "t5-11.2-page-\(tag)")
            pageNext.tap()
        } else {
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            let bubble = app.descendants(matching: .any)["tour-bubble"].firstMatch.frame
            let words = app.staticTexts["tour-words"].firstMatch
            XCTAssertTrue(words.exists, "11.2's words")
            // Cut short, the words sit in a scroll view a line and a half tall (`TourNoteWords`);
            // its accessibility frame is clipped to the bubble, so look for the scroll view itself.
            let scrolling = app.scrollViews.allElementsBoundByIndex.filter { bubble.insetBy(dx: -1, dy: -1).contains($0.frame) }
            XCTAssertTrue(scrolling.isEmpty, "all of 11.2's words, none of them scrolled away: \(scrolling.map(\.frame)) in \(bubble)")
            snap(app, "t5-11.2-bubble-\(tag)")
            tap(app, "tour-next")
        }
        waitGone(app)
    }

    /// Choosing the action in 11.1's window closes the panel and the cat goes: the chapter is
    /// handed over, nothing over the room after it.
    func testChapterElevenHandsOverWhenTheCatIsSent() {
        let app = launch("tour-t5-send-go", seed: Self.allBut("send-cat"), extra: ["-MeowverseSyntheticPhoto"])
        addSofa(app)
        tap(app, "choose-interaction")
        waitStatus(app, "send-cat card", timeout: 20)
        tap(app, "tour-card-start")
        waitStatus(app, "send-cat 11.1")
        let action = element(app, beginningWith: "invite-")
        action.tap()
        XCTAssertTrue(action.waitForNonExistence(timeout: 10), "the panel closed")
        waitGone(app)
        assertQuiet(app, 3, "handed over")
        // Handed over is an ending: 互动 opened again does not bring the chapter back (an
        // interruption would).
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        tap(app, "choose-interaction")
        XCTAssertTrue(element(app, beginningWith: "invite-").waitForExistence(timeout: 10))
        assertQuiet(app, 5, "chapter 11 ended when the cat was sent")
        // Only that visit was for watching her go: at the next arrival the room is free again
        // (here the last chapter was just read, so 「都讲完啦」).
        app.navigationBars.buttons["close-interaction"].tap()
        waitStatus(app, "all-done card", timeout: 20)
    }

    /// Two pieces: 11.1 on the first of 「房间里的家具」. Picking it opens its actions inside the
    /// panel: the chapter is handed over there, not put away for later.
    func testChapterElevenWithTwoPiecesHandsOverOnThePiece() {
        let app = launch("tour-t5-send-two", seed: Self.allBut("send-cat"), extra: ["-MeowverseSyntheticPhoto"])
        addSofa(app)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        addSofa(app, "manual-chair")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        tap(app, "choose-interaction")
        waitStatus(app, "send-cat card", timeout: 20)
        tap(app, "tour-card-start")
        let first = waitStatus(app, "send-cat 11.1")
        guard let window = hole(first) else { return XCTFail("no window: \(first)") }
        // The window takes in the whole group, both pieces (VISUAL §18.2 item 1).
        XCTAssertGreaterThan(window.height, 90, "two rows in the window: \(window)")
        assertRowWindow(first, "11.1 with two pieces", in: app)
        XCTAssertFalse(element(app, beginningWith: "invite-").exists, "two pieces: the list of pieces, not one piece's actions")
        snap(app, "t5-11.1-two")
        // The first piece: the window now holds the whole group, and its middle is the line between rows.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.midX, dy: window.minY + window.height / 4)).tap()
        XCTAssertTrue(element(app, beginningWith: "invite-").waitForExistence(timeout: 10), "the piece's actions")
        waitGone(app)
        assertQuiet(app, 3, "handed over on the piece")
    }

    /// The window over two pieces lets a tap through anywhere in it, also on the line between the
    /// two rows (VISUAL §18.4). The list itself does nothing for a tap right on that line, with the
    /// tour or without it (tried on the same build with the tour off); a tap a few points off it
    /// picks the row, and the chapter is handed over.
    func testChapterElevenTapOnTheLineBetweenPiecesGoesThrough() {
        let app = launch("tour-t5-send-line", seed: Self.allBut("send-cat"), extra: ["-MeowverseSyntheticPhoto"])
        addSofa(app)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        addSofa(app, "manual-chair")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        tap(app, "choose-interaction")
        waitStatus(app, "send-cat card", timeout: 20)
        tap(app, "tour-card-start")
        let first = waitStatus(app, "send-cat 11.1")
        guard let window = hole(first) else { return XCTFail("no window: \(first)") }
        let cells = app.cells.allElementsBoundByIndex.map(\.frame).filter { window.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        XCTAssertEqual(cells.count, 2, "both rows in the window: \(cells)")
        let line = cells.map(\.minY).max() ?? window.midY
        func count(_ key: String) -> Int {
            let now = status(app)
            guard let range = now.range(of: key + #"=\d+"#, options: .regularExpression) else { return -1 }
            return Int(now[range].dropFirst(key.count + 1)) ?? -1
        }
        let passed = count("passed"), swallowed = count("swallowed")
        // On the hairline: the window lets it through, it is not swallowed.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.midX, dy: line - 1.0 / 6)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(count("passed"), passed + 1, "the tap on the line went through: \(status(app))")
        XCTAssertEqual(count("swallowed"), swallowed, "nothing swallowed: \(status(app))")
        if !element(app, beginningWith: "invite-").exists {
            // As without the tour: the line itself picks nothing. 6 pt into the lower row does.
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.midX, dy: line + 6)).tap()
        }
        XCTAssertTrue(element(app, beginningWith: "invite-").waitForExistence(timeout: 10), "a piece's actions")
        waitGone(app)
        assertQuiet(app, 3, "handed over on the piece")
    }

    // MARK: Chapter 13

    /// With AR (the simulator's stand-in row): once chapter 11 has been told, 互动 brings chapter
    /// 13, its row scrolled into view first.
    func testChapterThirteenOnThePlayPanel() {
        let app = launch("tour-t5-tabletop", seed: Self.allBut("tabletop"), extra: ["-MeowverseShowAREntry"])
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 30))
        tap(app, "choose-interaction")
        waitStatus(app, "tabletop card", timeout: 20)
        snap(app, "t5-13-card")
        tap(app, "tour-card-start")
        let only = waitStatus(app, "tabletop 13.1")
        assertHole(only, around: "open-ar-tabletop", in: app)
        assertRowWindow(only, "13.1", in: app)
        // The bubble above the row, off the camera footer under it (VISUAL §18.2 item 6).
        if let window = hole(status(app)), let bubble = rect("bubble", in: status(app)) {
            XCTAssertLessThanOrEqual(bubble.maxY, window.minY, "13.1's bubble \(bubble) is above its window \(window)")
        }
        XCTAssertEqual(app.buttons["tour-next"].label, AppText.string("tour.gotIt", table: "Tour"))
        snap(app, "t5-13.1")
        tap(app, "tour-next")
        waitGone(app)
    }

    /// 13.1's bubble never sits on the row's camera footnote (VISUAL §18.2 item 6): above the row
    /// when it fits, or, with no room above (iPhone SE, large text), below a window that takes the
    /// footnote in. The text size comes from `TEST_RUNNER_MV_TEXT_SIZE` (a content size category).
    func testChapterThirteenKeepsTheCameraNoteClear() {
        let size = ProcessInfo.processInfo.environment["MV_TEXT_SIZE"] ?? "UICTContentSizeCategoryL"
        let app = launch("tour-t5-tabletop-note", seed: Self.allBut("tabletop"),
                         extra: ["-MeowverseShowAREntry", "-UIPreferredContentSizeCategoryName", size])
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 30))
        tap(app, "choose-interaction")
        waitStatus(app, "tabletop card", timeout: 20)
        tap(app, "tour-card-start")
        waitStatus(app, "tabletop 13.1")
        let now = status(app)
        let tag = size.replacingOccurrences(of: "UICTContentSizeCategory", with: "")
        if app.descendants(matching: .any)["tour-page-next"].firstMatch.waitForExistence(timeout: 8) {
            // No room beside the row at all (iPhone SE from Accessibility XL): the step is read as
            // a page, which carries its own words; nothing hangs over the footnote.
            XCTAssertTrue(size.hasPrefix("UICTContentSizeCategoryAccessibility"), "a page only for the largest sizes: \(now)")
            let words = app.descendants(matching: .any)["tour-page-words"].firstMatch
            XCTAssertTrue(words.exists)
            // Read over the Play panel: the panel is right behind the page (LINES.md E.1).
            XCTAssertTrue(words.label.contains(AppText.string("tour.place.tabletop.onPanel", table: "Tour")), "the page says the panel is behind it: \(words.label)")
            snap(app, "t5-13.1-\(tag)")
            tap(app, "tour-page-next")
            return waitGone(app)
        }
        guard let window = hole(now), let bubble = rect("bubble", in: now) else { return XCTFail("no window or bubble: \(now)") }
        let note = app.staticTexts["ar-tabletop-note"]
        XCTAssertTrue(note.exists, "the camera footnote is on screen")
        XCTAssertFalse(bubble.intersects(note.frame), "the bubble \(bubble) is off the footnote \(note.frame)")
        if bubble.minY >= window.maxY {
            XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(note.frame), "below: the window \(window) takes in the footnote \(note.frame)")
        } else {
            XCTAssertLessThanOrEqual(bubble.maxY, window.minY, "above the window")
        }
        XCTAssertTrue(app.windows.firstMatch.frame.insetBy(dx: 3.5, dy: 3.5).contains(window), "the window \(window) is on screen")
        snap(app, "t5-13.1-\(tag)")
        tap(app, "tour-next")
        waitGone(app)
    }

    /// Without AR, no chapter 13: 互动 brings nothing, and Settings does not list it.
    func testChapterThirteenAbsentWithoutAR() {
        // Chapter 15 left unread too (it needs ten photos), or every chapter this device tells has
        // been read and 「都讲完啦」 comes.
        let app = launch("tour-t5-no-ar", seed: Self.allBut("tabletop", "backup"))
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 30))
        tap(app, "choose-interaction")
        XCTAssertFalse(app.buttons["open-ar-tabletop"].exists)
        assertQuiet(app, 5, "no chapter 13 without AR")
        app.navigationBars.buttons["close-interaction"].tap()
        tap(app, "open-settings")
        let replay = app.buttons["open-tour"]
        for _ in 0..<8 where !(replay.exists && replay.isHittable) { app.swipeUp() }
        replay.tap()
        XCTAssertTrue(app.buttons["tour-replay-all"].waitForExistence(timeout: 10), "the list is up")
        // The list is lazy: look all the way down, past 12 (company) to 14 (reminders).
        var seen: Set<String> = []
        for _ in 0..<6 {
            for id in ["company", "tabletop", "reminders"] where app.buttons["tour-replay-\(id)"].exists { seen.insert(id) }
            app.swipeUp()
        }
        XCTAssertTrue(seen.isSuperset(of: ["company", "reminders"]), "the chapters around 13 are listed: \(seen)")
        XCTAssertFalse(seen.contains("tabletop"), "chapter 13 is not listed without AR")
        snap(app, "t5-13-replay-list-no-ar")
    }

    // MARK: Chapter 14

    /// From the third open with an empty room (the fallback): the card asks about a daily hello,
    /// 14.1 on the gear, 14.2 on 「提醒」 in Settings, scrolled into view. No permission is asked.
    func testChapterFourteenPointsAtRemindersInSettings() {
        let app = launch("tour-t5-reminders", seed: Self.allBut("reminders"), extra: ["-MeowverseTourSeedOpens", "2"])
        waitStatus(app, "reminders card", timeout: 40)
        let line = "(?s).*" + AppText.pattern("tour.reminders.card.line.fallback", table: "Tour") + ".*"
        let fallback = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", line)).firstMatch
        XCTAssertTrue(fallback.exists, "the line for a home with no furniture")
        snap(app, "t5-14-card")
        tap(app, "tour-card-start")
        assertHole(waitStatus(app, "reminders 14.1"), around: "open-settings", in: app)
        tap(app, "open-settings")
        let second = waitStatus(app, "reminders 14.2", timeout: 15)
        assertHole(second, around: "open-reminders", in: app)
        snap(app, "t5-14.2")
        tap(app, "tour-next")
        waitGone(app)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 2), "the tour asks no permission")
    }

    // MARK: Chapter 15

    /// Ten photos and no iCloud Drive backup: chapter 15's card, 15.1 on the gear (T5.14).
    func testChapterFifteenAfterTenPhotos() {
        let app = launch("tour-t5-backup", seed: Self.allBut("backup", "photo-batch") + ",photo-batch",
                         extra: ["-MeowverseSyntheticPhoto", "-MeowverseSyntheticBatch", "10", "1"])
        XCTAssertTrue(app.buttons["add-synthetic-batch"].waitForExistence(timeout: 30))
        assertQuiet(app, 3, "no backup chapter before ten photos")
        addBatch(app, 10)
        waitStatus(app, "backup card", timeout: 30)
        snap(app, "t5-15-card")
        tap(app, "tour-card-start")
        let only = waitStatus(app, "backup 15.1")
        assertHole(only, around: "open-settings", in: app)
        XCTAssertEqual(app.buttons["tour-next"].label, AppText.string("tour.gotIt", table: "Tour"))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "iCloud")).firstMatch.exists,
                       "the words do not name iCloud Drive")
        snap(app, "t5-15.1")
        tap(app, "tour-next")
        waitGone(app)
    }

    /// Opened from Settings, chapter 15 does not need ten photos.
    func testChapterFifteenReplayWithoutPhotos() {
        let app = launch("tour-t5-backup-replay", seed: "veteran", tour: "backup")
        waitStatus(app, "backup card", timeout: 40)
        tap(app, "tour-card-start")
        assertHole(waitStatus(app, "backup 15.1"), around: "open-settings", in: app)
        tap(app, "tour-next")
        waitGone(app)
    }

    // MARK: 「都讲完啦」

    /// Every chapter read, none skipped: the card comes once, at the next arrival in the room, and
    /// not again at the open after.
    func testAllDoneCardComesOnce() {
        let app = launch("tour-t5-all-done", seed: Self.chapters.joined(separator: ","))
        waitStatus(app, "all-done card", timeout: 40)
        XCTAssertTrue(app.staticTexts[AppText.string("tour.allDone.card.title", table: "Tour")].exists)
        XCTAssertEqual(app.buttons["tour-card-start"].label, AppText.string("tour.gotIt", table: "Tour"))
        XCTAssertFalse(app.buttons["tour-card-later"].exists && app.buttons["tour-card-later"].isHittable, "one button")
        snap(app, "t5-all-done")
        tap(app, "tour-card-start")
        waitGone(app)
        app.terminate()
        let again = launch("tour-t5-all-done", seed: nil, reset: false)
        XCTAssertTrue(again.buttons["choose-interaction"].waitForExistence(timeout: 30))
        assertQuiet(again, 5, "the card came once")
    }

    /// A chapter really skipped (「跳过这一段」 on chapter 14's card, the last one left): no
    /// 「都讲完啦」, then or after a relaunch (QA_T5 suggestion 3; the veteran seed waives chapters,
    /// it does not skip them).
    func testAllDoneCardNotAfterSkipping() {
        let app = launch("tour-t5-all-skipped", seed: Self.allBut("reminders"), extra: ["-MeowverseTourSeedOpens", "2"])
        waitStatus(app, "reminders card", timeout: 40)
        XCTAssertEqual(app.buttons["tour-card-later"].label, AppText.string("tour.skip", table: "Tour"))
        tap(app, "tour-card-later")
        waitGone(app)
        assertQuiet(app, 8, "no card after a skip")
        app.terminate()
        let again = launch("tour-t5-all-skipped", seed: nil, reset: false)
        XCTAssertTrue(again.buttons["choose-interaction"].waitForExistence(timeout: 30))
        assertQuiet(again, 8, "nor after a relaunch")
    }
}
