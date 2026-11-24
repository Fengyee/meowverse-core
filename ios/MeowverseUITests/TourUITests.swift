import XCTest

/// The onboarding tour's opening, chapters 1 to 5, at a first launch (docs/onboarding/TECH_DESIGN.md §8).
/// A test library has the tour only with `-MeowverseTour`. Every launch carries
/// `-MeowverseFakeCamera`, so 「添加照片」 is the menu it is on a phone with a camera (Q-06).
///
/// `tour-status` (DEBUG) reads `tour=<chapter> <step|card> <overlay|page> show=0|1 why=… hole=x,y,w,h …`.
/// It is in the overlay window, which is hidden when nothing is on it.
///
/// Review shots go to `TEST_RUNNER_MV_SHOT_DIR` as `<MV_SHOT_PREFIX>-<name>.png` when set.
final class TourUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    // MARK: Launch and read

    private func launch(_ store: String, reset: Bool = true, tour: String = "auto", firstLaunch: Bool = false,
                        language: [String] = TestLanguage.current, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = language + ["-MeowverseStore", store, "-MeowverseFakeCamera"] + extra
        if !tour.isEmpty { app.launchArguments += ["-MeowverseTour", tour] }
        if firstLaunch {
            app.launchArguments.removeAll { $0 == "-MeowverseSkipReminderSetup" }
            app.launchArguments += ["-MeowverseFakeNotifications", "granted"]
        }
        if reset { app.launchArguments.append("-MeowverseResetStore") }
        app.launch()
        return app
    }

    private func status(_ app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any)["tour-status"].firstMatch
        return element.exists ? (element.value as? String ?? "") : ""
    }

    /// Waits until the probe shows `tour` (e.g. "welcome 1.1") on screen and settled.
    @discardableResult
    private func waitShown(_ app: XCUIApplication, _ tour: String, timeout: TimeInterval = 25,
                           file: StaticString = #filePath, line: UInt = #line) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            last = status(app)
            if last.contains("tour=\(tour) ") && last.contains("show=1") { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(last.contains("tour=\(tour) ") && last.contains("show=1"), "waiting for \(tour): \(last)", file: file, line: line)
        // Let the entrance and the bubble's move finish before a screenshot or a tap.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        return status(app)
    }

    /// Nothing of the tour is on screen for `seconds`.
    private func assertNoTour(_ app: XCUIApplication, for seconds: TimeInterval, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let now = status(app)
            XCTAssertFalse(now.contains("show=1"), "\(message): \(now)", file: file, line: line)
            XCTAssertFalse(app.otherElements["tour-card"].exists || app.otherElements["tour-bubble"].exists,
                           message, file: file, line: line)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
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
        // A list row's accessibility frame takes in the row's inset, where the probe (on the
        // row's content) does not reach: the window must hold the middle and most of the control.
        let frame = target.frame
        let covered = hole.intersection(frame)
        XCTAssertTrue(hole.contains(CGPoint(x: frame.midX, y: frame.midY)) && covered.width >= frame.width * 0.9
                      && covered.height >= frame.height * 0.9, "\(id) \(frame) not in \(hole)", file: file, line: line)
    }

    /// 1.1 and 1.4: a round window on the cat, of a cat's size, inside the room; or, while she is
    /// not drawn yet, the floor.
    private func assertCatHole(_ status: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        guard let hole = hole(status) else { return XCTFail("no hole: \(status)", file: file, line: line) }
        let room = app.descendants(matching: .any)["room-world"].firstMatch.frame
        XCTAssertTrue(room.insetBy(dx: -2, dy: -2).contains(hole), "\(hole) not in the room \(room)", file: file, line: line)
        let round = abs(hole.width - hole.height) < 1
        if round {
            XCTAssertTrue((72...260).contains(hole.width), "a cat-sized window: \(hole)", file: file, line: line)
        } else {
            XCTAssertGreaterThan(hole.width, room.width * 0.5, "the floor: \(hole)", file: file, line: line)
        }
    }

    private func tap(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[id].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), id, file: file, line: line)
        for _ in 0..<20 where !button.isHittable { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        button.tap()
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        // For the review shots, let sheets and the bubble finish moving first.
        if ProcessInfo.processInfo.environment["MV_SHOT_DIR"] != nil { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
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

    /// For a screen recording: `TEST_RUNNER_MV_LINGER` seconds on the steps where the cat walks.
    private func linger() {
        guard let seconds = ProcessInfo.processInfo.environment["MV_LINGER"].flatMap(Double.init), seconds > 0 else { return }
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: The opening, start to end

    /// A new user: the card, the cat, a name, the nameplate, the look; Add photos; Place furniture
    /// first; then playing, where the toy hands the chapter to the game. Chapter 5 comes at the next
    /// launch and ends the opening. Started again, nothing comes back.
    func testNewUserNamesTheCatAndPlays() {
        var app = launch("tour-new")
        XCTAssertTrue(app.otherElements["tour-card"].waitForExistence(timeout: 30))
        waitShown(app, "welcome card")
        XCTAssertTrue(app.descendants(matching: .any)["tour-card-speaker"].exists, "Bella is read first on the card")
        snap(app, "1-0-card")
        tap(app, "tour-card-start")
        var now = waitShown(app, "welcome 1.1")
        assertCatHole(now, in: app)
        snap(app, "1-1-cat")
        linger()
        tap(app, "tour-next")

        let field = app.textFields["tour-naming-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the naming page")
        XCTAssertFalse(status(app).contains("show=1"), "no mask over the naming page")
        snap(app, "1-2-naming")
        field.tap()
        field.typeText("团子")
        tap(app, "tour-naming-use")

        now = waitShown(app, "welcome 1.3a")
        assertHole(now, around: "room-switcher", in: app)
        XCTAssertTrue(app.buttons["room-switcher"].label.contains("团子"), app.buttons["room-switcher"].label)
        XCTAssertTrue(app.staticTexts["tour-words"].label.contains("团子"))
        // Where 1.1's and 1.4's bubbles are, on iPad too, whose plate is off the middle (VISUAL §19.3 item 3).
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(app.descendants(matching: .any)["tour-bubble"].firstMatch.frame.midX,
                       app.windows.firstMatch.frame.midX, accuracy: 1, "1.3a's bubble in the middle")
        snap(app, "1-3a-plate")
        tap(app, "tour-next")
        now = waitShown(app, "welcome 1.4")
        assertCatHole(now, in: app)
        XCTAssertEqual(app.buttons["tour-next"].label, AppText.string("tour.done", table: "Tour"), "the last step's closing word")
        snap(app, "1-4-looks")
        linger()
        tap(app, "tour-next")

        // Chapters 2 and 3 follow at once, without a card; their last steps go on with 【下一步】.
        now = waitShown(app, "bring-photo 2.1")
        XCTAssertFalse(app.otherElements["tour-card"].exists)
        assertHole(now, around: "add-photo", in: app)
        snap(app, "2-1-photos")
        tap(app, "tour-next")
        waitShown(app, "bring-photo 2.2")
        tap(app, "tour-next")
        now = waitShown(app, "bring-photo 2.3")
        assertHole(now, around: "add-photo", in: app)
        XCTAssertEqual(app.buttons["tour-next"].label, AppText.string("tour.next", table: "Tour"), "chapter 2 goes on to chapter 3")
        tap(app, "tour-next")
        now = waitShown(app, "furnish-first 3.1")
        assertHole(now, around: "place-furniture-first", in: app)
        XCTAssertEqual(app.buttons["tour-next"].label, AppText.string("tour.next", table: "Tour"), "chapter 3 goes on to chapter 4")
        snap(app, "3-1-first")
        tap(app, "tour-next")

        now = waitShown(app, "play 4.1")
        XCTAssertFalse(app.otherElements["tour-card"].exists)
        assertHole(now, around: "choose-interaction", in: app)
        snap(app, "4-1-play")
        // A touch outside the window is swallowed: nothing opens.
        app.buttons["room-switcher"].tap()
        XCTAssertTrue(status(app).contains("tour=play 4.1 "))
        // The real control inside the window opens 互动; the tour moves on by itself.
        app.buttons["choose-interaction"].tap()
        now = waitShown(app, "play 4.2")
        assertHole(now, around: "choose-toy", in: app)
        snap(app, "4-2-toy")
        app.buttons["choose-toy"].tap()
        let toy = app.buttons["play-item-toyBall"]
        XCTAssertTrue(toy.waitForExistence(timeout: 10))
        toy.tap()
        XCTAssertTrue(app.buttons["place-play-item"].waitForExistence(timeout: 10))
        assertNoTour(app, for: 3, "the toy handed the chapter to the game")

        // The rest of the opening waits for the room to be free: here, the next launch.
        app.terminate()
        app = launch("tour-new", reset: false)
        now = waitShown(app, "top-row 5.1", timeout: 30)
        // The one window holds every token of the row, and not much of the room below it.
        for id in ["open-settings", "open-room-appearance", "open-room-sound", "room-switcher",
                   "open-room-manager", "open-cat-manager", "open-room-share"] {
            assertHole(now, around: id, in: app)
        }
        if let row = hole(now) {
            XCTAssertLessThan(row.height, app.windows.firstMatch.frame.height * 0.3, "the row's window: \(row)")
            // All four sides on screen, at least 4 pt in: its line and corners show (VISUAL §19.2 item 1).
            XCTAssertTrue(app.windows.firstMatch.frame.insetBy(dx: 4, dy: 4).contains(row), "the row's window on screen: \(row)")
        } else {
            XCTFail("no window on the row: \(now)")
        }
        snap(app, "5-1-row")
        tap(app, "tour-next")
        now = waitShown(app, "top-row 5.2")
        assertHole(now, around: "open-room-sound", in: app)
        tap(app, "tour-next")
        now = waitShown(app, "top-row 5.3")
        assertHole(now, around: "open-settings", in: app)
        XCTAssertEqual(app.buttons["tour-next"].label, AppText.string("tour.done", table: "Tour"), "the opening's last word")
        snap(app, "5-3-settings")
        tap(app, "tour-next")
        assertNoTour(app, for: 3, "the opening is over")

        app.terminate()
        app = launch("tour-new", reset: false)
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        // The opening is told once. What comes at this open is chapter 14: opened again after the
        // first piece, and ahead of chapter 12 (rule 13, T5); one chapter a visit, so after it,
        // nothing.
        waitShown(app, "reminders card", timeout: 30)
        tap(app, "tour-card-later")
        assertNoTour(app, for: 4, "the opening is told once")
        XCTAssertTrue(app.buttons["room-switcher"].label.contains("团子"), "the name was saved")
    }

    /// No name: the line points at 「猫咪」. 【跳过这一段】 goes on to the next part each time; 【下一步】
    /// on 4.1 ends chapter 4 and goes on to chapter 5.
    func testNoNameThenSkipThisPart() {
        let app = launch("tour-noname")
        waitShown(app, "welcome card")
        tap(app, "tour-card-start")
        waitShown(app, "welcome 1.1")
        tap(app, "tour-next")
        XCTAssertTrue(app.textFields["tour-naming-field"].waitForExistence(timeout: 10))
        tap(app, "tour-naming-later")
        let now = waitShown(app, "welcome 1.3b")
        assertHole(now, around: "open-cat-manager", in: app)
        XCTAssertTrue(app.staticTexts["tour-words"].label.contains("Kitty"), app.staticTexts["tour-words"].label)
        snap(app, "1-3b-cats")
        tap(app, "tour-next")
        waitShown(app, "welcome 1.4")
        tap(app, "tour-skip")
        waitShown(app, "bring-photo 2.1")
        tap(app, "tour-skip")
        waitShown(app, "furnish-first 3.1")
        tap(app, "tour-skip")
        waitShown(app, "play 4.1")
        tap(app, "tour-next")
        waitShown(app, "top-row 5.1")
        tap(app, "tour-skip")
        assertNoTour(app, for: 4, "【跳过这一段】 on chapter 5 ends the opening")
        XCTAssertTrue(app.buttons["room-switcher"].label.contains("Kitty"), "nothing was renamed")
    }

    /// Rule 6: the real control in 2.3's window hands the chapter over. The menu closed with
    /// nothing picked, the room still empty and no photo: chapter 3 (§3.1.1 #2). Its own button
    /// hands over to the furniture page; a sofa placed, chapter 4 waits for the room to be free.
    func testChaptersTwoAndThreeHandOverToTheirPages() {
        let app = launch("tour-handoff", extra: ["-MeowverseTourSeed", "welcome"])
        waitShown(app, "bring-photo 2.1", timeout: 30)
        tap(app, "tour-next")
        waitShown(app, "bring-photo 2.2")
        tap(app, "tour-next")
        waitShown(app, "bring-photo 2.3")
        // Inside the window: the real Add photos, a menu here (-MeowverseFakeCamera).
        app.buttons["add-photo"].tap()
        assertNoTour(app, for: 2, "Add photos handed chapter 2 over")
        // Closed with nothing picked.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        let now = waitShown(app, "furnish-first 3.1", timeout: 20)
        assertHole(now, around: "place-furniture-first", in: app)
        app.buttons["place-furniture-first"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 15), "the furniture page")
        XCTAssertFalse(status(app).contains("show=1"), "no mask over the furniture page")
        sofa.tap()
        for id in ["next-model", "next-placement", "confirm-placement"] { tap(app, id) }
        XCTAssertTrue(app.buttons["confirm-placement"].waitForNonExistence(timeout: 10))
        waitShown(app, "play 4.1", timeout: 30)
    }

    /// From xxxL the empty room's card is folded and Place furniture first is not on screen: 3.1
    /// points at the Furniture button, and that hands over too.
    func testChapterThreeWhenTheEmptyRoomCardIsFolded() {
        let app = launch("tour-folded-3", extra: ["-MeowverseTourSeed", "welcome,bring-photo",
                                                  "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
        let now = waitShown(app, "furnish-first 3.1", timeout: 30)
        assertHole(now, around: "furniture-list", in: app)
        snap(app, "3-1-folded")
        app.buttons["furniture-list"].tap()
        XCTAssertTrue(app.buttons["close-furniture-list"].waitForExistence(timeout: 15), "the furniture library")
        XCTAssertFalse(status(app).contains("show=1"), "no mask over the library")
    }

    /// Page mode at 3.1: the Home Screen's camera action opens the camera, and the page it took
    /// away is not recorded as skipped.
    func testQuickActionOverAPageLeavesChapterThreeUntold() {
        let store = "tour-page-quick-action"
        let app = launch(store, extra: ["-MeowverseTourSeed", "welcome,bring-photo", "-MeowverseTourPage"])
        let words = app.descendants(matching: .any)["tour-page-words"].firstMatch
        let third = AppText.string("tour.furnishFirst.1", table: "Tour")
        XCTAssertTrue(words.waitForExistence(timeout: 30), "3.1's page")
        XCTAssertTrue(waitLabel(words, contains: third), "3.1: \(words.label)")

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
        cancel.tap()
        app.terminate()

        let again = launch(store, reset: false, extra: ["-MeowverseTourPage"])
        let wordsAgain = again.descendants(matching: .any)["tour-page-words"].firstMatch
        XCTAssertTrue(wordsAgain.waitForExistence(timeout: 30), "a page again")
        XCTAssertTrue(waitLabel(wordsAgain, contains: third), "chapter 3 has no ending: \(wordsAgain.label)")
    }

    /// 「全部跳过」 on the card: nothing more, now or at the next launch.
    func testSkipAllOnTheCard() {
        var app = launch("tour-skipall")
        waitShown(app, "welcome card")
        XCTAssertEqual(app.buttons["tour-card-later"].label, AppText.string("tour.skipAll", table: "Tour"))
        tap(app, "tour-card-later")
        assertNoTour(app, for: 4, "skip all")
        app.terminate()
        app = launch("tour-skipall", reset: false)
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        assertNoTour(app, for: 5, "skip all holds at the next launch")
    }

    // MARK: The test build page

    private static let fakeTestFlight = ["-MeowverseFakeTestFlight"]

    private func testBuildWords(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["tour-test-build-words"].firstMatch
    }

    /// No test build page for `seconds`.
    private func assertNoTestBuildPage(_ app: XCUIApplication, for seconds: TimeInterval, _ message: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            XCTAssertFalse(testBuildWords(app).exists, message, file: file, line: line)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
    }

    /// TestFlight: not between the chapters, then once the opening is over, here by
    /// 【跳过这一段】 on chapter 5. 「去反馈」 opens 「反馈问题」, and its 【关闭】 leaves the room clear.
    func testTestBuildPageAfterTheOpening() {
        let app = launch("tour-tb-done", extra: Self.fakeTestFlight + ["-MeowverseTourSeed", "welcome,bring-photo,furnish-first"])
        waitShown(app, "play 4.1", timeout: 30)
        XCTAssertFalse(testBuildWords(app).exists, "not in the opening")
        tap(app, "tour-next")
        waitShown(app, "top-row 5.1")
        XCTAssertFalse(testBuildWords(app).exists, "not between chapter 4 and chapter 5")
        tap(app, "tour-skip")

        XCTAssertTrue(testBuildWords(app).waitForExistence(timeout: 10), "the page after the opening")
        let title = AppText.string("tour.testBuild.title", table: "Tour"), line = AppText.string("tour.testBuild.line", table: "Tour")
        XCTAssertTrue(testBuildWords(app).label.contains(title) && testBuildWords(app).label.contains(line),
                      testBuildWords(app).label)
        XCTAssertFalse(status(app).contains("show=1"), "no mask under the page: \(status(app))")
        XCTAssertEqual(app.buttons["tour-test-build-report"].label, AppText.string("tour.testBuild.report", table: "Tour"))
        XCTAssertEqual(app.buttons["tour-test-build-ok"].label, AppText.string("tour.testBuild.gotIt", table: "Tour"))
        tap(app, "tour-test-build-report")
        XCTAssertTrue(app.descendants(matching: .any)["feedback-description"].waitForExistence(timeout: 10),
                      "「去反馈」 opens 反馈问题")
        tap(app, "tour-test-build-close")
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["feedback-description"].exists)
        assertNoTestBuildPage(app, for: 3, "answered: not again")
    }

    /// TestFlight, 「全部跳过」 on the card: 「好，不打扰你了。…」, then the page.
    func testTestBuildPageAfterSkipAll() {
        let app = launch("tour-tb-skipall", extra: Self.fakeTestFlight)
        waitShown(app, "welcome card")
        tap(app, "tour-card-later")
        XCTAssertTrue(testBuildWords(app).waitForExistence(timeout: 10), "the page after skip all")
        assertNoTour(app, for: 1, "no chapter under the page")
    }

    /// TestFlight, a library that had the opening behind it (grandfathered): the page once. 「知道了」
    /// closes it, and the next launch does not show it again.
    func testTestBuildPageOnceForAnExistingUser() {
        var app = launch("tour-tb-veteran", extra: Self.fakeTestFlight + ["-MeowverseTourSeed", "veteran"])
        XCTAssertTrue(testBuildWords(app).waitForExistence(timeout: 30), "a grandfathered library sees the page once")
        tap(app, "tour-test-build-ok")
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
        assertNoTestBuildPage(app, for: 2, "「知道了」 closed it")
        app.terminate()
        app = launch("tour-tb-veteran", reset: false, extra: Self.fakeTestFlight)
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        assertNoTestBuildPage(app, for: 6, "read once, not again")
        assertNoTour(app, for: 1, "nothing else either")
    }

    /// Not TestFlight: never, after skip all nor for a grandfathered library.
    func testNoTestBuildPageOutsideTestFlight() {
        var app = launch("tour-tb-store")
        waitShown(app, "welcome card")
        tap(app, "tour-card-later")
        assertNoTestBuildPage(app, for: 5, "not a TestFlight build")
        app.terminate()
        app = launch("tour-tb-store", extra: ["-MeowverseTourSeed", "veteran"])
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        assertNoTestBuildPage(app, for: 5, "not a TestFlight build")
    }

    /// Closed in the middle of chapter 1: the next launch starts it again from the card.
    func testRelaunchMidChapterStartsItAgain() {
        var app = launch("tour-relaunch")
        waitShown(app, "welcome card")
        tap(app, "tour-card-start")
        waitShown(app, "welcome 1.1")
        app.terminate()
        app = launch("tour-relaunch", reset: false)
        waitShown(app, "welcome card", timeout: 30)
    }

    /// A library that already had photos when the tour first met it: no opening (Q-04).
    func testExistingUserSkipsTheOpening() {
        var app = launch("tour-veteran", tour: "", extra: ["-MeowverseSyntheticPhoto"])
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        app.addSyntheticBatch()
        XCTAssertTrue(app.buttons["start-sorting"].waitForExistence(timeout: 30), "the photos are saved")
        app.terminate()
        app = launch("tour-veteran", reset: false, extra: ["-MeowverseSyntheticPhoto"])
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        // No chapter of the opening. Since T5 the photos waiting to be sorted bring chapter 8, which
        // is for everyone (T5.1): that one may come.
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            let now = status(app)
            for opening in ["welcome", "bring-photo", "furnish-first", "play", "top-row"] {
                XCTAssertFalse(now.contains("tour=\(opening) "), "a lived-in home skips the opening: \(now)")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
    }

    /// A real first launch: the greeting comes first. The reminder page no longer opens on its
    /// own (PRODUCT_PLAN §2.2, Plan A); chapter 14 offers reminders later.
    func testTheGreetingComesFirstWithNoReminderPage() {
        let app = launch("tour-reminders", firstLaunch: true)
        waitShown(app, "welcome card", timeout: 30)
        XCTAssertFalse(app.buttons["finish-reminder-setup"].exists, "no reminder page at the first launch")
    }

    /// Page mode (VoiceOver, Switch Control): a plain sheet with the same lines, no overlay, the
    /// whole opening in one sheet.
    func testPageModeReadsTheOpening() {
        let app = launch("tour-page", extra: ["-MeowverseTourPage"])
        let words = app.descendants(matching: .any)["tour-page-words"].firstMatch
        XCTAssertTrue(words.waitForExistence(timeout: 30))
        XCTAssertFalse(status(app).contains("show=1"), "no overlay in page mode")
        snap(app, "page-card")
        tap(app, "tour-page-start")
        XCTAssertTrue(waitLabel(words, contains: AppText.string("tour.welcome.1", table: "Tour")))
        snap(app, "page-1-1")
        tap(app, "tour-page-next")
        XCTAssertTrue(app.textFields["tour-naming-field"].waitForExistence(timeout: 10))
        tap(app, "tour-naming-later")
        XCTAssertTrue(waitLabel(words, matches: AppText.pattern("tour.welcome.3b", table: "Tour")))
        XCTAssertTrue(app.buttons["tour-page-back"].exists)
        tap(app, "tour-page-next")
        XCTAssertTrue(waitLabel(words, contains: AppText.string("tour.welcome.4", table: "Tour")))
        tap(app, "tour-page-next")
        XCTAssertTrue(waitLabel(words, contains: AppText.string("tour.bringPhoto.1", table: "Tour")))
        XCTAssertTrue(waitLabel(words, contains: AppText.string("tour.place.addPhoto", table: "Tour")), "where it is: \(words.label)")
        tap(app, "tour-page-next")
        XCTAssertTrue(waitLabel(words, contains: AppText.string("tour.bringPhoto.2", table: "Tour"))
                      || waitLabel(words, contains: AppText.string("tour.bringPhoto.2.pad", table: "Tour")))
        tap(app, "tour-page-next")
        XCTAssertTrue(waitLabel(words, matches: AppText.pattern("tour.bringPhoto.3", table: "Tour")))
        XCTAssertEqual(app.buttons["tour-page-next"].label, AppText.string("tour.next", table: "Tour"), "chapter 2 goes on")
        tap(app, "tour-page-next")
        XCTAssertTrue(waitLabel(words, contains: AppText.string("tour.furnishFirst.1", table: "Tour")))
        tap(app, "tour-page-next")
        XCTAssertTrue(waitLabel(words, matches: AppText.pattern("tour.play.1", table: "Tour")))
        snap(app, "page-4-1")
        tap(app, "tour-page-next")
        XCTAssertTrue(waitLabel(words, matches: AppText.pattern("tour.play.2", table: "Tour")))
        tap(app, "tour-page-next")
        XCTAssertTrue(waitLabel(words, contains: AppText.string("tour.topRow.1", table: "Tour")))
        tap(app, "tour-page-next")
        XCTAssertTrue(waitLabel(words, contains: AppText.string("tour.topRow.2", table: "Tour")))
        tap(app, "tour-page-next")
        XCTAssertTrue(waitLabel(words, contains: AppText.string("tour.topRow.3", table: "Tour")))
        XCTAssertEqual(app.buttons["tour-page-next"].label, AppText.string("tour.done", table: "Tour"), "the opening's last word")
        tap(app, "tour-page-next")
        XCTAssertFalse(words.waitForExistence(timeout: 1) && words.isHittable, "the page closed")
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
    }

    /// Page mode at the largest text, in English and in Chinese (VISUAL §12.2 a): the buttons stop
    /// growing at AX3 and leave most of the screen to the words, which scroll.
    func testPageModeAtTheLargestTextLeavesTheScreenToTheWords() {
        for (language, tag) in [(TestLanguage.english, "en"), (TestLanguage.chinese, "zh")] {
            let app = launch("tour-page-ax5-" + tag, tour: "play", language: language,
                             extra: ["-MeowverseTourPage", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
            let start = app.buttons["tour-page-start"]
            XCTAssertTrue(start.waitForExistence(timeout: 40))
            start.tap()
            let next = app.buttons["tour-page-next"], skip = app.buttons["tour-page-skip"]
            XCTAssertTrue(next.waitForExistence(timeout: 10))
            for step in ["4-1", "4-2"] {
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                let screen = app.windows.firstMatch.frame
                // The buttons alone, top of the first to bottom of the last: on iPad the page is a
                // sheet, so the screen's bottom edge is not the bar's.
                let buttons = skip.frame.maxY - next.frame.minY
                XCTAssertTrue(next.isHittable && skip.isHittable, "\(tag) \(step): the buttons")
                XCTAssertLessThan(buttons / screen.height, 0.2, "\(tag) \(step): the buttons take \(buttons) pt of \(screen.height)")
                // On a phone the bar runs to the bottom of the screen: from its edge (8 pt above the
                // first button) down, at most a fifth (VISUAL §14.1), also on an iPhone SE.
                if UIDevice.current.userInterfaceIdiom == .phone {
                    let bar = screen.maxY - next.frame.minY + 8
                    XCTAssertLessThanOrEqual(bar / screen.height, 0.2, "\(tag) \(step): the bar takes \(bar) pt of \(screen.height)")
                }
                XCTAssertGreaterThanOrEqual(skip.frame.height, 43.5)
                let back = app.buttons["tour-page-back"]
                if back.exists {
                    XCTAssertGreaterThanOrEqual(back.frame.height, 43.5)
                    XCTAssertFalse(back.frame.intersects(skip.frame), "\(tag) \(step): back \(back.frame) on skip \(skip.frame)")
                    XCTAssertTrue(back.isHittable, "\(tag) \(step): back")
                }
                snap(app, "ax5-page-\(tag)-\(step)")
                if step == "4-1" { next.tap() }
            }
            app.terminate()
        }
    }

    // MARK: A backup listed late (QA_T2 F1, F2)

    /// iCloud Drive's first listing on a new phone often comes back empty. Here the test folder is
    /// empty at launch; the backup is copied in while chapter 1 is on screen, and the app lists the
    /// folder again when it comes back to the front. The name given on the naming page must not
    /// hide the restore offer, and is written at once.
    func testABackupListedAfterNamingIsStillOffered() throws {
        let target = try lateBackup(named: "团子")
        let app = target.app
        tap(app, "tour-skip")
        let offer = app.descendants(matching: .any)["icloud-restore-offer"].firstMatch
        XCTAssertTrue(offer.waitForExistence(timeout: 15), "the backup that came late is offered")
        snap(app, "late-offer")
        XCTAssertTrue(app.buttons["room-switcher"].label.contains("团子"), "the name was written at once: \(app.buttons["room-switcher"].label)")
        assertNoTour(app, for: 3, "the opening waits for the answer to the restore offer")
        app.buttons["icloud-restore-dismiss"].tap()
        waitShown(app, "bring-photo 2.1", timeout: 20)
    }

    /// After the naming page the user renames the cat in 猫咪管理. Nothing the tour kept writes
    /// over it, then or after the restore offer is answered.
    func testTheUsersOwnRenameAfterNamingStays() throws {
        let target = try lateBackup(named: "团子")
        var app = target.app
        tap(app, "tour-skip")
        XCTAssertTrue(app.descendants(matching: .any)["icloud-restore-offer"].firstMatch.waitForExistence(timeout: 15))
        app.openCatManager()
        app.renameFirstCat(to: "咪咪")
        app.waitForFirstCat(named: "咪咪")
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        XCTAssertTrue(app.firstCatRow.label.hasPrefix("咪咪"), "5 s later: \(app.firstCatRow.label)")
        app.buttons["close-home"].tap()
        XCTAssertTrue(app.buttons["room-switcher"].label.contains("咪咪"), app.buttons["room-switcher"].label)
        app.buttons["icloud-restore-dismiss"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertTrue(app.buttons["room-switcher"].label.contains("咪咪"), "answering the offer changes no name")
        app.terminate()
        app = launch(target.store, reset: false, extra: ["-MeowverseCloudFolder", target.folder])
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["room-switcher"].label.contains("咪咪"), "the user's name at the next launch: \(app.buttons["room-switcher"].label)")
    }

    /// QA_T2 R2-1: an empty room whose cat was only renamed backs itself up. At the next launch it
    /// is not offered its own backup back, and a new library on the same folder (another device, as
    /// far as backups go) is not offered a backup with no photos and no furniture in it.
    func testANameOnlyBackupIsNotOfferedBack() {
        let folder = "tno" + UUID().uuidString.prefix(6)
        let offer = { (app: XCUIApplication) in app.descendants(matching: .any)["icloud-restore-offer"].firstMatch }
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.current + ["-MeowverseStore", "tour-own", "-MeowverseResetStore", "-MeowverseCloudFolder", folder]
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        app.openCatManager()
        app.renameFirstCat(to: "团子")
        app.waitForFirstCat(named: "团子")
        app.buttons["close-home"].tap()
        backUpNow(app)
        app.terminate()

        app.launchArguments = TestLanguage.current + ["-MeowverseStore", "tour-own", "-MeowverseCloudFolder", folder]
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["room-switcher"].label.contains("团子"), "the same library: \(app.buttons["room-switcher"].label)")
        XCTAssertFalse(offer(app).waitForExistence(timeout: 10), "this device's own backup of a name only is offered back")
        app.terminate()

        app.launchArguments = TestLanguage.current + ["-MeowverseStore", "tour-own-new", "-MeowverseResetStore", "-MeowverseCloudFolder", folder]
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        XCTAssertFalse(offer(app).waitForExistence(timeout: 10), "a backup with nothing to bring back is offered")
    }

    /// Makes a backup in a library of its own, starts a new library on an empty test folder, names
    /// the cat on the naming page, then lets the backup turn up and brings the app back to the front.
    private func lateBackup(named name: String) throws -> (app: XCUIApplication, store: String, folder: String) {
        let source = "tls" + UUID().uuidString.prefix(6), folder = "tlt" + UUID().uuidString.prefix(6)
        var app = XCUIApplication()
        app.launchArguments = TestLanguage.current + ["-MeowverseStore", "tour-late-src", "-MeowverseResetStore",
                                                      "-MeowverseSyntheticPhoto", "-MeowverseCloudFolder", source]
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        backUpASofa(app)
        app.terminate()

        app = launch("tour-late", extra: ["-MeowverseCloudFolder", folder])
        waitShown(app, "welcome card", timeout: 40)
        XCTAssertFalse(app.descendants(matching: .any)["icloud-restore-offer"].exists, "nothing to offer yet")
        tap(app, "tour-card-start")
        waitShown(app, "welcome 1.1")
        tap(app, "tour-next")
        let field = app.textFields["tour-naming-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(name)
        tap(app, "tour-naming-use")
        waitShown(app, "welcome 1.3a")

        // The backup turns up in iCloud Drive while the app is in the background.
        let from = try XCTUnwrap(cloudFolder(source), "the source backup folder")
        let to = from.deletingLastPathComponent().appending(path: "TestCloud-" + folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        for item in try FileManager.default.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) {
            try FileManager.default.copyItem(at: item, to: to.appending(path: item.lastPathComponent))
        }
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.activate()
        waitShown(app, "welcome 1.3a", timeout: 20)
        return (app, "tour-late", folder)
    }

    /// The app's test iCloud folder, found from the test runner: both apps' data containers are in
    /// the same folder on the simulator.
    private func cloudFolder(_ name: String) -> URL? {
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let manager = FileManager.default
        for container in (try? manager.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil)) ?? [] {
            let folder = container.appending(path: "Library/Application Support/Meowverse/TestCloud-" + name, directoryHint: .isDirectory)
            if manager.fileExists(atPath: folder.path) { return folder }
        }
        return nil
    }

    /// A sofa from a synthetic photo, iCloud backup switched on, one backup written.
    private func backUpASofa(_ app: XCUIApplication) {
        app.buttons["add-synthetic"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 20))
        sofa.tap()
        app.buttons["next-model"].tap()
        tap(app, "next-placement")
        tap(app, "confirm-placement")
        XCTAssertTrue(app.buttons.matching(identifier: "room-piece-with-photos").firstMatch.waitForExistence(timeout: 10))
        backUpNow(app)
    }

    /// iCloud backup switched on from Settings, and one backup written now.
    private func backUpNow(_ app: XCUIApplication) {
        tap(app, "open-settings")
        // A lazy list: the row is in the tree only once it is scrolled to.
        let row = app.descendants(matching: .any)["open-icloud-backup"].firstMatch
        _ = row.waitForExistence(timeout: 3)
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.exists && row.isHittable, "the iCloud backup row")
        row.tap()
        let toggle = app.switches["icloud-backup-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        tap(app, "icloud-consent-confirm")
        tap(app, "icloud-backup-now")
        let notice = app.descendants(matching: .any)["icloud-backup-notice"].firstMatch
        let words = AppText.string("备份完成并通过核对，已放进 iCloud 云盘，由系统上传。")
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", words), object: notice)
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 60), .completed, "the backup was written")
    }

    // MARK: The largest text

    /// English at the largest accessibility size, where the bubble is tallest (QA_T2 F3): while the
    /// mask is up, a way out is on screen and can be tapped, beside the window or on a page.
    func testEnglishLargestTextKeepsAWayOut() {
        let app = launch("tour-ax5", tour: "play", language: TestLanguage.english,
                         extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        waitShown(app, "play card", timeout: 40)
        tap(app, "tour-card-start")
        assertWayOut(app, "4.1")
        snap(app, "ax5-4-1")
        if status(app).contains("show=1") {
            app.buttons["choose-interaction"].tap()
            assertWayOut(app, "4.2")
            snap(app, "ax5-4-2")
        }
        let skip = app.buttons["tour-skip"].exists ? app.buttons["tour-skip"] : app.buttons["tour-page-skip"]
        skip.tap()
        assertNoTour(app, for: 3, "skipped")
    }

    /// The step is on screen with its 【跳过这一段】 inside the screen and hittable: in its bubble,
    /// or on the page the step is read on when the bubble has no room.
    private func assertWayOut(_ app: XCUIApplication, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(20)
        let bubbleSkip = app.buttons["tour-skip"], pageSkip = app.buttons["tour-page-skip"]
        // The bubble of this step is up and settled, or its page has slid all the way up.
        let screen = app.windows.firstMatch.frame
        func reachable(_ skip: XCUIElement) -> Bool { skip.exists && screen.contains(skip.frame) && skip.isHittable }
        while Date() < deadline {
            let now = status(app)
            if now.contains("tour=play \(step) ") && ((now.contains("show=1") && reachable(bubbleSkip)) || reachable(pageSkip)) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        let skip = bubbleSkip.exists ? bubbleSkip : pageSkip
        if skip.exists, !skip.isHittable {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "tree-\(step)"
            tree.lifetime = .keepAlways
            add(tree)
        }
        XCTAssertTrue(skip.exists, "\(step): no way out, \(status(app))", file: file, line: line)
        XCTAssertTrue(screen.contains(skip.frame), "\(step): skip at \(skip.frame) is off \(screen)", file: file, line: line)
        XCTAssertTrue(skip.isHittable, "\(step): skip at \(skip.frame) is not hittable", file: file, line: line)
        XCTAssertGreaterThanOrEqual(skip.frame.height, 43.5, file: file, line: line)
        // A bubble with no room beside the window must not sit on it: the step is a page instead
        // (QA_T2 R2-3). A reachable skip alone passed with the bubble over the whole window.
        let shown = status(app)
        if shown.contains("show=1") {
            let hole = rect(after: "hole=", in: shown), bubble = rect(after: "bubble=", in: shown)
            XCTAssertNotNil(hole, "\(step): no window in \(shown)", file: file, line: line)
            if let hole, let bubble {
                XCTAssertFalse(hole.insetBy(dx: 1, dy: 1).intersects(bubble),
                               "\(step): the bubble \(bubble) covers the window \(hole)", file: file, line: line)
            }
        }
    }

    /// "x,y,w,h" after `key` in the status probe's value.
    private func rect(after key: String, in status: String) -> CGRect? {
        guard let start = status.range(of: key)?.upperBound else { return nil }
        let numbers = status[start...].prefix { $0 != " " }.split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    private func waitLabel(_ element: XCUIElement, contains text: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 10) == .completed
    }

    /// For a line with the cat's name in it (`AppText.pattern`): all its fixed words, in their order.
    private func waitLabel(_ element: XCUIElement, matches pattern: String) -> Bool {
        let predicate = NSPredicate(format: "label MATCHES %@", "(?s).*" + pattern + ".*")
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 10) == .completed
    }
}
