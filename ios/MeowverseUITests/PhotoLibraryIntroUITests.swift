import XCTest

/// The explanation before the first photos, a pre-alert screen in the HIG's sense (Privacy ›
/// Pre-alert screens): one button, titled 「继续」 and not "Allow", that always goes on to the
/// system alert; no way past the alert, and nothing that says which answer to pick (round 12
/// audit, PRIVACY-2). After a refusal the screen says so once and Settings is the way back.
final class PhotoLibraryIntroUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        continueAfterFailure = false
        // The system alert only comes while the question is unanswered.
        XCUIApplication().resetAuthorizationStatus(for: .photos)
        addTeardownBlock { XCUIApplication().resetAuthorizationStatus(for: .photos) }
    }

    /// The simulator has no camera, so 添加照片 goes straight to the library and its explanation.
    private func openIntro(store: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseResetStore",
                                                     "-MeowverseLibraryIntro", "-photoLibraryLinkWanted", "<false/>"]
        app.launch()
        let add = app.buttons["add-photo"]
        XCTAssertTrue(add.waitForExistence(timeout: 25))
        add.tap()
        XCTAssertTrue(app.buttons["library-intro-continue"].waitForExistence(timeout: 10))
        return app
    }

    private func systemAlertButton(_ labels: [String]) -> XCUIElement {
        springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(store: String, reset: Bool = true, _ language: [String] = TestLanguage.chinese,
                        _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = language + ["-MeowverseStore", store, "-MeowverseLibraryIntro", "-photoLibraryLinkWanted", "<false/>"]
            + (reset ? ["-MeowverseResetStore"] : []) + extra
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        return app
    }

    /// Opens the page from 添加照片 (no camera on the simulator, so the library is the only way).
    private func openIntro(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["add-photo"].tap()
        let go = app.buttons["library-intro-continue"]
        XCTAssertTrue(go.waitForExistence(timeout: 8), "the explanation did not open")
        return go
    }

    /// Everything the page says, read from its text.
    private func pageWords(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["library-intro"].staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
    }

    /// The system picker, out of process: its own search field and cancel button show in the tree.
    private func waitForPicker(_ app: XCUIApplication, timeout: TimeInterval = 15) -> Bool {
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        return cancel.waitForExistence(timeout: timeout)
    }

    private func closePicker(_ app: XCUIApplication) {
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch.tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
        // The sheet is still sliding away for a moment.
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["add-photo"])
        XCTAssertEqual(XCTWaiter().wait(for: [hittable], timeout: 10), .completed)
    }

    private func texts(_ app: XCUIApplication, containing word: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", word))
    }

    func testOneButtonGoesToTheSystemAlertAndARefusalIsSaidOnce() {
        let app = openIntro(store: "library-intro-deny")
        let next = app.buttons["library-intro-continue"]
        XCTAssertEqual(next.label, "继续")
        XCTAssertFalse(app.buttons["library-intro-skip"].exists, "no way past the system alert")
        XCTAssertEqual(texts(app, containing: "允许读取").count, 0, "the button is not an Allow")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "不允许")).count, 0)
        XCTAssertEqual(texts(app, containing: "推荐").count, 0, "nothing recommends an answer")
        XCTAssertEqual(texts(app, containing: "请选").count, 0, "nothing says which answer to pick")
        XCTAssertTrue(texts(app, containing: "不允许也能照常使用").firstMatch.exists, "the explanation stays")
        XCTAssertTrue(texts(app, containing: "系统会询问").firstMatch.exists, "the button says it opens the system alert")
        snap("library-intro")

        next.tap()
        let deny = systemAlertButton(["Don’t Allow", "Don't Allow", "不允许"])
        XCTAssertTrue(deny.waitForExistence(timeout: 10), "继续 opens the system alert")
        deny.tap()
        XCTAssertTrue(app.descendants(matching: .any)["library-intro-refused"].waitForExistence(timeout: 10))
        let done = app.buttons["library-intro-done"]
        XCTAssertTrue(done.exists)
        XCTAssertFalse(app.buttons["library-intro-continue"].exists)
        snap("library-intro-refused")
        done.tap()
        XCTAssertFalse(done.waitForExistence(timeout: 3) && done.isHittable, "the explanation closed")
    }

    func testFullAccessClosesTheExplanation() {
        let app = openIntro(store: "library-intro-allow")
        let next = app.buttons["library-intro-continue"]
        next.tap()
        let allow = systemAlertButton(["Allow Full Access", "允许完全访问", "Allow Access to All Photos", "允许访问所有照片"])
        XCTAssertTrue(allow.waitForExistence(timeout: 10), springboard.debugDescription)
        allow.tap()
        // The system picker opens behind the closing page and can keep the app busy for a while.
        XCTAssertTrue(next.waitForNonExistence(timeout: 60), "full access closes the explanation")
        XCTAssertFalse(app.descendants(matching: .any)["library-intro-refused"].exists)
    }

    /// Full access turns the link on, as the switch in Settings would.
    func testFullAccessTurnsOnTheLibraryLink() {
        let app = launch(store: "library-intro-full")
        openIntro(app).tap()
        PhotosPrompt.answer(PhotosPrompt.fullAccess)
        XCTAssertTrue(waitForPicker(app))
        closePicker(app)
        app.buttons["open-settings"].tap()
        let toggle = app.switches["library-link-toggle"]
        for _ in 0..<6 where !(toggle.exists && toggle.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(toggle.exists, app.debugDescription)
        XCTAssertEqual(toggle.value as? String, "1", "full access turned on 从相册读取大图")
    }

    func testEnglishPage() {
        let app = launch(store: "library-intro-en", TestLanguage.english)
        let go = openIntro(app)
        XCTAssertEqual(go.label, "Continue")
        let words = pageWords(app)
        // The privacy line follows iCloud backup and sync (`PhotoReachWording`); its words are
        // checked in PrivacyWordingUITests.
        for banned in ["recommend", "Recommend", "choose “"] {
            XCTAssertFalse(words.contains(banned), "the page says “\(banned)”: \(words)")
        }
        XCTAssertNil(words.range(of: "\\p{Han}", options: .regularExpression), words)
        snap("intro-en")
    }

    /// At the largest accessibility size the words scroll, the button stays on screen.
    func testLargestTextKeepsTheButtonAndTheWords() throws {
        let app = launch(store: "library-intro-ax", TestLanguage.chinese,
                         ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let go = openIntro(app)
        XCTAssertTrue(go.isHittable)
        try app.performAccessibilityAudit(for: .textClipped)
        snap("intro-zh-ax-top")
        app.descendants(matching: .any)["library-intro"].swipeUp(velocity: .slow)
        XCTAssertTrue(go.isHittable)
        snap("intro-zh-ax-bottom")
    }

    // MARK: Review shots

    /// For the art director: the page in the current appearance. Runs only with
    /// TEST_RUNNER_PERMISSION_SHOTS=<folder>; set the appearance with `simctl ui` first and pass
    /// its name as TEST_RUNNER_PERMISSION_SHOTS_TAG.
    func testReviewShots() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["PERMISSION_SHOTS"], !folder.isEmpty else { throw XCTSkip("review shots only") }
        let tag = environment["PERMISSION_SHOTS_TAG"] ?? "light"
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var cases: [(String, [String], [String])] = [("zh-\(tag)", TestLanguage.chinese, []), ("en-\(tag)", TestLanguage.english, [])]
        if environment["PERMISSION_SHOTS_LARGEST"] == "1" {
            cases.append(("zh-\(tag)-ax-xxxl", TestLanguage.chinese, ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]))
        }
        for (name, language, extra) in cases {
            let app = launch(store: "library-intro-shots", language, extra)
            _ = openIntro(app)
            sleep(1)
            let shot = XCUIScreen.main.screenshot()
            try shot.pngRepresentation.write(to: out.appendingPathComponent("\(name).png"))
            if name.hasSuffix("ax-xxxl") {
                app.descendants(matching: .any)["library-intro"].swipeUp(velocity: .slow)
                sleep(1)
                try XCUIScreen.main.screenshot().pngRepresentation.write(to: out.appendingPathComponent("\(name)-scrolled.png"))
            }
            app.terminate()
        }
    }
}
