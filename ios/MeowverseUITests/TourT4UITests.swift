import XCTest

/// The tour's chapters 6, 7 and 12 (T4), one main path each, and chapter 12 with Live Activities
/// switched off. The opening is planted as read (`-MeowverseTourSeed`), so these chapters are what
/// comes. Chapters 6 and 7 get their piece through the app's own synthetic-photo import (DEBUG
/// `-MeowverseSyntheticPhoto`): a sofa with one photo, its source on record.
///
/// `tour-status` (DEBUG) reads `tour=<chapter> <step|card> <overlay|page> show=0|1 why=… hole=x,y,w,h …`.
/// Review shots go to `TEST_RUNNER_MV_SHOT_DIR` as `<MV_SHOT_PREFIX>-<name>.png` when set.
final class TourT4UITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private static let opening = "welcome,bring-photo,furnish-first,play,top-row"

    private func launch(_ store: String, seed: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.current + ["-MeowverseStore", store, "-MeowverseResetStore", "-MeowverseTour", "auto",
                                          "-MeowverseTourSeed", seed] + extra
        app.launch()
        return app
    }

    private func status(_ app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any)["tour-status"].firstMatch
        return element.exists ? (element.value as? String ?? "") : ""
    }

    @discardableResult
    private func waitStatus(_ app: XCUIApplication, _ tour: String, shown: Bool = true, timeout: TimeInterval = 25,
                            file: StaticString = #filePath, line: UInt = #line) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        func ok(_ value: String) -> Bool { value.contains("tour=\(tour) ") && (!shown || value.contains("show=1")) }
        while Date() < deadline {
            last = status(app)
            if ok(last) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(ok(last), "waiting for \(tour): \(last)", file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        return status(app)
    }

    /// The chapter has ended: the probe says none, or the overlay window has gone with it.
    private func waitGone(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(6)
        var last = status(app)
        while Date() < deadline, !(last.isEmpty || last.contains("tour=none")) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            last = status(app)
        }
        XCTAssertTrue(last.isEmpty || last.contains("tour=none"), "the chapter ended: \(last)", file: file, line: line)
    }

    private func hole(_ status: String) -> CGRect? {
        guard let range = status.range(of: #"hole=[-0-9.]+,[-0-9.]+,[0-9.]+,[0-9.]+"#, options: .regularExpression) else { return nil }
        let numbers = status[range].dropFirst(5).split(separator: ",").compactMap { Double($0) }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    private func assertHole(_ status: String, around id: String, in app: XCUIApplication,
                            file: StaticString = #filePath, line: UInt = #line) {
        let target = app.descendants(matching: .any)[id].firstMatch
        XCTAssertTrue(target.exists, id, file: file, line: line)
        guard let hole = hole(status) else { return XCTFail("no hole: \(status)", file: file, line: line) }
        let frame = target.frame
        XCTAssertTrue(hole.contains(CGPoint(x: frame.midX, y: frame.midY)), "\(id) \(frame) not in \(hole)", file: file, line: line)
    }

    private func tap(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[id].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), id, file: file, line: line)
        for _ in 0..<20 where !button.isHittable { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        button.tap()
    }

    private func point(_ app: XCUIApplication, _ at: CGPoint) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: at.x, dy: at.y))
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
    private func addSofa(_ app: XCUIApplication, _ piece: String = "manual-sofa") {
        XCTAssertTrue(app.buttons["add-synthetic"].waitForExistence(timeout: 30))
        app.buttons["add-synthetic"].tap()
        for id in [piece, "next-model", "next-placement", "confirm-placement"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 20), id)
            button.tap()
        }
        let receipt = app.descendants(matching: .any)["photo-storage-receipt"].firstMatch
        if !receipt.waitForExistence(timeout: 10), app.buttons["confirm-placement"].exists { app.buttons["confirm-placement"].tap() }
    }

    // MARK: Chapter 6

    /// The sofa comes in with its photo; once the receipt has gone, chapter 6's card. The window on
    /// the sofa opens its page; 6.2 on 「再添一张照片」, 6.3 on 「更多」 with 「知道了」.
    func testChapterSixOpensThePieceAndPointsAtItsPage() {
        let app = launch("tour-t4-memories", seed: Self.opening + ",company", extra: ["-MeowverseSyntheticPhoto"])
        addSofa(app)
        let receipt = app.descendants(matching: .any)["photo-storage-receipt"].firstMatch
        let card = waitStatus(app, "memories card", timeout: 45)
        XCTAssertFalse(receipt.exists, "the card comes after the receipt has gone (Q-18): \(card)")
        tap(app, "tour-card-start")
        let first = waitStatus(app, "memories 6.1")
        let room = app.descendants(matching: .any)["room-world"].firstMatch.frame
        guard let sofa = hole(first) else { return XCTFail("no window on the sofa: \(first)") }
        XCTAssertTrue(room.contains(sofa) && sofa.width < room.width * 0.6, "a piece-sized window in the room: \(sofa)")
        snap(app, "t4-6.1")
        point(app, CGPoint(x: sofa.midX, y: sofa.midY)).tap()

        let second = waitStatus(app, "memories 6.2")
        assertHole(second, around: "add-source-photo", in: app)
        snap(app, "t4-6.2")
        tap(app, "tour-next")
        let third = waitStatus(app, "memories 6.3")
        assertHole(third, around: "furniture-more", in: app)
        XCTAssertEqual(app.buttons["tour-next"].label, AppText.string("tour.gotIt", table: "Tour"))
        snap(app, "t4-6.3")
        tap(app, "tour-next")
        waitGone(app)

        // Still on the piece page: chapter 7 does not start over it.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            XCTAssertFalse(status(app).contains("tour=move-and-look"), "nothing more while the page is up")
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
    }

    // MARK: Chapter 7

    /// 7.1's window on the sofa; lifting it puts the tour aside, putting it down brings 7.2, whose
    /// window is the whole room. A pinch fades the mask; held zoomed with the fingers off, 7.3 on
    /// the storage box, the room set back.
    func testChapterSevenLiftsThePieceThenZoomsThenTheStorageBox() {
        let english = TestLanguage.isEnglish
        let app = launch("tour-t4-move", seed: Self.opening + ",company,memories",
                         extra: ["-MeowverseSyntheticPhoto"])
        addSofa(app)
        waitStatus(app, "move-and-look card", timeout: 45)
        tap(app, "tour-card-start")
        let lift = waitStatus(app, "move-and-look 7.1")
        guard let sofa = hole(lift) else { return XCTFail("no window on the sofa: \(lift)") }
        print("T4 7.1 status:", lift)
        let first = wholeBubble(app, "7.1")
        assertTowardsWindowOnPad(first, window: sofa, in: app, "7.1")
        snap(app, "t4-7.1")
        let start = point(app, CGPoint(x: sofa.midX, y: sofa.midY))
        start.press(forDuration: 1, thenDragTo: start.withOffset(CGVector(dx: -20, dy: 10)))
        XCTAssertTrue(app.buttons["edit-done"].waitForExistence(timeout: 5), "the sofa was lifted")
        XCTAssertTrue(status(app).contains("show=0"), "the tour stepped aside: \(status(app))")
        app.buttons["edit-done"].tap()

        let stage = waitStatus(app, "move-and-look 7.2")
        let screen = app.windows.firstMatch.frame
        guard let window = hole(stage) else { return XCTFail("no stage window: \(stage)") }
        XCTAssertGreaterThan(window.width, screen.width * 0.8, "the stage window spans the room: \(window)")
        XCTAssertGreaterThan(window.minX, 3, "at least 4 from the screen's side: \(window)")
        let bubble = wholeBubble(app, "7.2")
        XCTAssertFalse(bubble.intersects(window), "the bubble keeps off the stage window: \(bubble) \(window)")
        XCTAssertEqual(bubble.maxY, first.maxY, accuracy: 1, "7.1 and 7.2 in the same place")
        snap(app, english ? "t4-7.2-en" : "t4-7.2-zh")

        app.descendants(matching: .any)["room-world"].firstMatch.pinch(withScale: 2.2, velocity: 2)
        // The fingers are off: 7.3 only once the zoom has held for about a second (QA_T4, 0.96 s).
        let lifted = Date()
        let zoomed = app.descendants(matching: .any)["tour-bubble"].firstMatch.frame
        XCTAssertEqual(zoomed.minY, bubble.minY, accuracy: 1, "the bubble stays put while the room is zoomed: \(zoomed)")
        var after: TimeInterval?
        var zooming = false
        // For a recording of the change to 7.3, nothing queries the app during it.
        let linger = ProcessInfo.processInfo.environment["MV_LINGER"].flatMap(Double.init)
        if let linger { RunLoop.current.run(until: Date().addingTimeInterval(linger)) }
        while Date().timeIntervalSince(lifted) < 10, !(after != nil && status(app).contains("why=ok")) {
            let now = status(app)
            if after == nil, now.contains("tour=move-and-look 7.3 ") { after = Date().timeIntervalSince(lifted) }
            // The old window waits while the room is set back; the probe says so (QA_T4 r2 suggestion 2).
            if now.contains("tour=move-and-look 7.3 "), now.contains("why=zooming") { zooming = true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        guard let after else { return XCTFail("no 7.3: \(status(app))") }
        XCTAssertGreaterThanOrEqual(after, 0.8, "7.3 waits for the zoom to hold")
        // Under Reduce Motion the room is set back at once and 7.3 does not wait on it.
        if !UIAccessibility.isReduceMotionEnabled {
            XCTAssertTrue(zooming, "7.3 waited for the room to be set back, and the probe said why=zooming")
        }
        waitStatus(app, "move-and-look 7.3", timeout: 10)
        assertHole(status(app), around: "room-storage", in: app)
        XCTAssertEqual(app.buttons["tour-next"].label, AppText.string("tour.gotIt", table: "Tour"))
        let last = wholeBubble(app, "7.3")
        XCTAssertEqual(last.maxY, first.maxY, accuracy: 1, "7.3 at the height of 7.1 and 7.2")
        if let chest = hole(status(app)) { assertTowardsWindowOnPad(last, window: chest, in: app, "7.3") }
        snap(app, "t4-7.3")
        tap(app, "tour-next")
        waitGone(app)
    }

    /// Chapter 7's bubble on iPad moves sideways towards its window, 16 pt from the screen's sides
    /// at least (VISUAL §19.3 item 7). On iPhone it stays in the middle.
    private func assertTowardsWindowOnPad(_ bubble: CGRect, window: CGRect, in app: XCUIApplication, _ step: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let screen = app.windows.firstMatch.frame
        var middle = screen.midX
        if UIDevice.current.userInterfaceIdiom == .pad {
            let least = 16 + bubble.width / 2
            middle = min(max(window.midX, least), screen.width - least)
        }
        // The piece may still settle a point or two after the bubble was placed, once per step.
        XCTAssertEqual(bubble.midX, middle, accuracy: 4, "\(step): the bubble towards its window", file: file, line: line)
    }

    /// 7.1 lets through only touches that start in its window: a tap on another piece does not open
    /// it, and pressing it does not lift it (QA_T4 suggestion 4). Two pieces; read again from
    /// Settings so the chapter does not come between them.
    func testChapterSevenSwallowsTouchesOnAnotherPiece() {
        let app = launch("tour-t4-swallow", seed: Self.opening + ",company,memories,move-and-look",
                         extra: ["-MeowverseSyntheticPhoto"])
        addSofa(app)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        addSofa(app, "manual-chair")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        tap(app, "open-settings")
        let row = app.buttons["open-tour"]
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        tap(app, "tour-replay-move-and-look")
        waitStatus(app, "move-and-look card", timeout: 25)
        tap(app, "tour-card-start")
        let lift = waitStatus(app, "move-and-look 7.1")
        guard let window = hole(lift) else { return XCTFail("no window: \(lift)") }
        // A point on a piece's button, outside the window.
        let pieces = app.buttons.allElementsBoundByIndex.filter { ["room-piece-with-photos", "room-piece-without-photos"].contains($0.identifier) }
        var spot: CGPoint?
        for frame in pieces.map(\.frame) where spot == nil {
            for x in stride(from: frame.minX + 3, to: frame.maxX - 3, by: 2) {
                let candidate = CGPoint(x: x, y: frame.midY)
                if !window.insetBy(dx: -3, dy: -3).contains(candidate) { spot = candidate; break }
            }
        }
        guard let spot else { return XCTFail("no piece outside the window \(window): \(pieces.map(\.frame))") }
        func count(_ name: String, _ status: String) -> Int {
            guard let range = status.range(of: "\(name)=[0-9]+", options: .regularExpression) else { return -1 }
            return Int(status[range].dropFirst(name.count + 1)) ?? -1
        }
        let before = status(app)
        point(app, spot).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(app.buttons["add-source-photo"].exists, "the piece under the mask did not open")
        point(app, spot).press(forDuration: 1)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(app.buttons["edit-done"].exists, "the piece under the mask was not lifted")
        let now = status(app)
        XCTAssertTrue(now.contains("move-and-look 7.1") && now.contains("show=1"), now)
        XCTAssertEqual(count("swallowed", now), count("swallowed", before) + 2, "both touches were swallowed: \(before) → \(now)")
        XCTAssertEqual(count("passed", now), count("passed", before), "none let through: \(before) → \(now)")
        tap(app, "tour-skip")
        waitGone(app)
    }

    /// Every piece in the room locked: Settings says chapter 7 waits for one to be unlocked, and read
    /// from there its card says so with only 「知道了」 (lead's ruling on QA_T4 suggestion 2). A
    /// long-time user's record, so the chapter stays 还没看 and does not come by itself.
    func testChapterSevenWithEveryPieceLocked() {
        let app = launch("tour-t4-locked", seed: "veteran", extra: ["-MeowverseSyntheticPhoto"])
        addSofa(app)
        let piece = app.buttons.matching(identifier: "room-piece-with-photos").firstMatch
        XCTAssertTrue(piece.waitForExistence(timeout: 20))
        piece.tap()
        tap(app, "furniture-more")
        tap(app, "toggle-lock")
        XCTAssertTrue(app.descendants(matching: .any)["locked-banner"].firstMatch.waitForExistence(timeout: 10))
        tap(app, "close-detail")
        tap(app, "open-settings")
        let row = app.buttons["open-tour"]
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let chapter = app.buttons["tour-replay-move-and-look"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 5))
        XCTAssertTrue(chapter.label.contains(AppText.string("tour.status.needsUnlocked", table: "Tour")), chapter.label)
        snap(app, "t4-7-locked-row")
        chapter.tap()
        waitStatus(app, "move-and-look card", timeout: 25)
        let words = app.descendants(matching: .any)["tour-card"].firstMatch.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(words.contains { $0.contains(AppText.string("tour.needsUnlocked.line", table: "Tour")) }, "\(words)")
        XCTAssertEqual(app.buttons["tour-card-start"].label, AppText.string("tour.gotIt", table: "Tour"))
        XCTAssertFalse(app.buttons["tour-card-later"].exists, "no 跳过这一段 on the placeholder")
        XCTAssertFalse(app.buttons["tour-card-skip-all"].exists, "no 全部跳过 on the placeholder")
        snap(app, "t4-7-locked-card")
        tap(app, "tour-card-start")
        waitGone(app)
    }

    /// The bubble's frame, once its words are all there above the buttons: no part of them is
    /// left to scroll to (VISUAL §17.10.2, item 1).
    @discardableResult
    private func wholeBubble(_ app: XCUIApplication, _ step: String, file: StaticString = #filePath,
                             line: UInt = #line) -> CGRect {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let words = app.descendants(matching: .any)["tour-words"].firstMatch.frame
        let skip = app.buttons["tour-skip"].firstMatch.frame
        XCTAssertLessThanOrEqual(words.maxY, skip.minY, "\(step): the words are whole, not scrolled: \(words) \(skip)",
                                 file: file, line: line)
        return app.descendants(matching: .any)["tour-bubble"].firstMatch.frame
    }

    // MARK: Chapter 12

    /// The second open: 互动, 陪我一会儿, 开始陪伴, the lock line, then the three pages; 12.7 lists the
    /// shortcuts this device has (no 「看看回忆」 without a piece with photos).
    func testChapterTwelveStartsCompanyThenThePages() {
        let app = launch("tour-t4-company", seed: Self.opening, extra: ["-MeowverseFakeCamera"])
        waitStatus(app, "company card", timeout: 40)
        tap(app, "tour-card-start")
        assertHole(waitStatus(app, "company 12.1"), around: "choose-interaction", in: app)
        tap(app, "choose-interaction")
        assertHole(waitStatus(app, "company 12.2"), around: "choose-pocket-cat", in: app)
        tap(app, "choose-pocket-cat")
        assertHole(waitStatus(app, "company 12.3"), around: "pocket-start", in: app)
        snap(app, "t4-12.3")
        tap(app, "pocket-start")
        let lock = waitStatus(app, "company 12.4")
        XCTAssertTrue(lock.contains("hole=none"), "no window: \(lock)")
        snap(app, "t4-12.4")
        tap(app, "tour-next")

        let line = app.descendants(matching: .any)["tour-company-line"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10), "the pages")
        snap(app, "t4-12.5")
        tap(app, "tour-company-next")
        snap(app, "t4-12.6")
        tap(app, "tour-company-next")
        XCTAssertTrue(app.descendants(matching: .any)["tour-company-shortcut-app.meowverse.camera"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["tour-company-shortcut-app.meowverse.memory"].exists,
                       "no 看看回忆 without a piece with photos")
        snap(app, "t4-12.7")
        tap(app, "tour-company-done")
        XCTAssertTrue(line.waitForNonExistence(timeout: 5))
        waitGone(app)
        tap(app, "pocket-end")
    }

    /// Review shots of 12.5–12.7, each page whole (scrolled once more when it is taller than the
    /// screen). On iPad there are no steps before the pages, the card speaks of the Home Screen, and
    /// 12.5 has no Lock Screen part (LINES.md T4.8, plan A). `TEST_RUNNER_MV_LANG=en` runs it in English.
    func testChapterTwelvePagesForReview() {
        let english = TestLanguage.isEnglish
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let app = launch("tour-t4-pages", seed: Self.opening, extra: ["-MeowverseFakeCamera"])
        waitStatus(app, "company card", timeout: 40)
        func text(_ part: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
        }
        let lockWords = english ? "Lock Screen" : "锁屏"
        if isPad {
            XCTAssertTrue(text(english ? "on your Home Screen" : "在主屏幕上看到").exists, "the iPad card speaks of the Home Screen")
            XCTAssertFalse(text(lockWords).exists, "no Lock Screen on the iPad card")
        }
        tap(app, "tour-card-start")
        if !isPad {
            waitStatus(app, "company 12.1")
            tap(app, "choose-interaction")
            waitStatus(app, "company 12.2")
            tap(app, "choose-pocket-cat")
            waitStatus(app, "company 12.3")
            tap(app, "pocket-start")
            waitStatus(app, "company 12.4")
            tap(app, "tour-next")
        }
        let line = app.descendants(matching: .any)["tour-company-line"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10), "the pages")
        let pages = isPad ? ["12.5", "12.7"] : ["12.5", "12.6", "12.7"]
        for (index, page) in pages.enumerated() {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            if isPad, index == 0 {
                XCTAssertFalse(text(lockWords).exists, "no Lock Screen part on the iPad's 12.5")
            }
            snapWhole(app, "pages-\(page)")
            tap(app, index == pages.count - 1 ? "tour-company-done" : "tour-company-next")
        }
        XCTAssertTrue(line.waitForNonExistence(timeout: 5))
        waitGone(app)
        if !isPad { tap(app, "pocket-end") }
    }

    /// The page as it opens, and once more scrolled to its end when that shows something else.
    private func snapWhole(_ app: XCUIApplication, _ name: String) {
        let first = XCUIScreen.main.screenshot().pngRepresentation
        snap(app, name)
        let window = app.windows.firstMatch
        for _ in 0..<3 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        if XCUIScreen.main.screenshot().pngRepresentation != first { snap(app, name + "-end") }
    }

    /// The first open after the opening, and the user walks into 陪我一会儿 themselves: chapter 12's
    /// card comes over the company page, then 12.3 (PRODUCT_PLAN §3.2; QA_T4 item 1, where the card
    /// never came). Back in the room afterwards nothing more is said at this open.
    func testChapterTwelveBeginsOnTheCompanyPageTheUserOpened() {
        let app = launch("tour-t4-company-page", seed: Self.opening, extra: ["-MeowverseTourSeedOpens", "0"])
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 30))
        // The first open: nothing in the room.
        let quiet = Date().addingTimeInterval(4)
        while Date() < quiet {
            XCTAssertFalse(status(app).contains("show=1"), "nothing in the room at the first open: \(status(app))")
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        tap(app, "choose-interaction")
        tap(app, "choose-pocket-cat")
        XCTAssertTrue(app.buttons["pocket-start"].waitForExistence(timeout: 10))
        waitStatus(app, "company card", timeout: 15)
        snap(app, "t4-12-card-on-company-page")
        tap(app, "tour-card-start")
        assertHole(waitStatus(app, "company 12.3"), around: "pocket-start", in: app)
        tap(app, "pocket-start")
        waitStatus(app, "company 12.4")
        tap(app, "tour-next")
        XCTAssertTrue(app.descendants(matching: .any)["tour-company-line"].firstMatch.waitForExistence(timeout: 10), "the pages")
        tap(app, "tour-company-skip")
        waitGone(app)
        tap(app, "pocket-end")
        // Back to the room: the company page, then the 互动 panel.
        app.navigationBars.buttons.firstMatch.tap()
        tap(app, "close-interaction")
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 10))
        let after = Date().addingTimeInterval(5)
        while Date() < after {
            XCTAssertFalse(status(app).contains("show=1"), "nothing more at this open: \(status(app))")
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
    }

    /// Live Activities off: 12.3 关着 over the company page, no 开始陪伴 step, and page 2 says where
    /// to switch them on.
    func testChapterTwelveWithLiveActivitiesOff() {
        let app = launch("tour-t4-company-off", seed: Self.opening, extra: ["-MeowverseLiveActivitiesOff"])
        waitStatus(app, "company card", timeout: 40)
        tap(app, "tour-card-start")
        waitStatus(app, "company 12.1")
        tap(app, "choose-interaction")
        waitStatus(app, "company 12.2")
        tap(app, "choose-pocket-cat")
        let off = waitStatus(app, "company 12.3off")
        XCTAssertTrue(off.contains("hole=none"), "no window: \(off)")
        XCTAssertFalse(app.buttons["pocket-start"].exists, "nothing to start")
        snap(app, "t4-12.3off")
        tap(app, "tour-next")
        XCTAssertTrue(app.descendants(matching: .any)["tour-company-line"].firstMatch.waitForExistence(timeout: 10))
        tap(app, "tour-company-next")
        let liveWords = AppText.string("tour.company.controls.needsLive", table: "Tour")
        let needsLive = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", liveWords)).firstMatch
        XCTAssertTrue(needsLive.waitForExistence(timeout: 5), "page 2 says Live Activities are needed")
        snap(app, "t4-12.6off")
        tap(app, "tour-company-next")
        tap(app, "tour-company-done")
        waitGone(app)
    }
}
