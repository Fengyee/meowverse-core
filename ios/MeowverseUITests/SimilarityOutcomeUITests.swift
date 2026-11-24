import XCTest

/// IMPORT-2: "nothing in the room looks like it" is said only by a comparison that finished.
/// One that failed, or had nothing to compare with, says so instead and claims no ranking.
/// `-MeowverseFailPrints` and `-MeowverseUnlikePrints` stand in for the two kinds of result.
final class SimilarityOutcomeUITests: XCTestCase {
    private let none = "房间里没有和它相像的家具"
    private let failed = "这次没能完成比对"
    private let ranked = "相像程度排列"

    override func setUp() { continueAfterFailure = false }

    func testFailedComparisonDoesNotSayNothingLooksAlike() {
        var app = launch(store: "compare-failed")
        place(app, category: "sofa")
        // The sofa's print may be in the cache by now or not: the new photo's fails either way.
        app.terminate()
        app = launch(store: "compare-failed", reset: false, ["-MeowverseFailPrints", "-MeowverseLargeSyntheticPhoto"])
        reviewAnotherPhoto(app)
        XCTAssertTrue(text(app, failed).waitForExistence(timeout: 20), "the failure is not said")
        XCTAssertFalse(text(app, none).exists, "a failed comparison said nothing looks alike")
        XCTAssertFalse(text(app, ranked).exists, "a failed comparison claimed a ranking")
        XCTAssertTrue(app.buttons["similar-none"].exists, "choosing by hand is still there")
        snap("compare-failed")
    }

    func testFinishedComparisonStillSaysNothingLooksAlike() {
        let app = launch(store: "compare-none", ["-MeowverseUnlikePrints"])
        place(app, category: "sofa")
        startSorting(app)
        XCTAssertTrue(text(app, none).waitForExistence(timeout: 20))
        XCTAssertFalse(text(app, failed).exists)
        snap("compare-none")
    }

    /// Photos on a board are never compared, so a room with only a board compared nothing.
    func testOnlyABoardMeansNothingWasCompared() {
        let app = launch(store: "compare-board")
        place(app, category: "photoBoard")
        startSorting(app)
        XCTAssertTrue(text(app, "还没有能用来比对的家具照片").waitForExistence(timeout: 20))
        XCTAssertFalse(text(app, none).exists, "nothing was compared")
        XCTAssertFalse(text(app, ranked).exists)
        XCTAssertFalse(text(app, failed).exists, "nothing failed either")
        snap("compare-nothing")
    }

    func testEnglishFailureWords() {
        var app = launch(store: "compare-english", language: TestLanguage.english)
        place(app, category: "sofa")
        app.terminate()
        app = launch(store: "compare-english", reset: false, ["-MeowverseFailPrints", "-MeowverseLargeSyntheticPhoto"], language: TestLanguage.english)
        reviewAnotherPhoto(app)
        XCTAssertTrue(text(app, "Couldn’t finish comparing").waitForExistence(timeout: 20))
        XCTAssertFalse(text(app, "Nothing in the room looks like it").exists)
        snap("compare-failed-english")
    }

    // MARK: Steps

    private func launch(store: String, reset: Bool = true, _ extra: [String] = [], language: [String] = TestLanguage.chinese) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = language + ["-MeowverseStore", store, "-MeowverseSyntheticPhoto", "-MeowverseColorGridSimilarity"]
            + (reset ? ["-MeowverseResetStore"] : []) + extra
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        return app
    }

    private func place(_ app: XCUIApplication, category: String) {
        app.buttons["add-synthetic"].tap()
        let row = app.buttons["manual-" + category]
        XCTAssertTrue(app.buttons["next-model"].waitForExistence(timeout: 20))
        let footer = app.buttons["next-model"].frame.minY
        for _ in 0..<12 where !(row.exists && row.isHittable && row.frame.midY < footer - 10) {
            let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -180)),
                         withVelocity: .slow, thenHoldForDuration: 0.15)
        }
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 15))
    }

    private func startSorting(_ app: XCUIApplication) {
        app.addSyntheticBatch()
        let start = app.buttons["start-sorting"]
        XCTAssertTrue(start.waitForExistence(timeout: 40))
        start.tap()
        XCTAssertTrue(app.buttons["similar-none"].waitForExistence(timeout: 30))
    }

    /// One photo picked by itself, at another size so it is not the one on the sofa.
    private func reviewAnotherPhoto(_ app: XCUIApplication) {
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.buttons["similar-none"].waitForExistence(timeout: 30))
    }

    private func text(_ app: XCUIApplication, _ part: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
