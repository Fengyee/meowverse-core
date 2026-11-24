import XCTest

/// A newly presented sorting sheet already exposes its toolbar while it is sliding up.
/// Wait for the button to settle before XCTest synthesizes the touch at its coordinates.
func tapSortingToolbarButton(_ id: String, in app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
    let button = app.navigationBars.buttons[id].firstMatch
    let midline = app.frame.midY
    var lastFrame = CGRect.null
    let ready = NSPredicate { _, _ in
        guard button.exists, button.isHittable else { return false }
        let frame = button.frame.integral
        defer { lastFrame = frame }
        return !frame.isEmpty && frame.midY < midline && frame == lastFrame
    }
    let expectation = XCTNSPredicateExpectation(predicate: ready, object: nil)
    guard XCTWaiter().wait(for: [expectation], timeout: 10) == .completed else {
        XCTFail("Sorting toolbar button did not settle: \(id)", file: file, line: line)
        return
    }
    button.tap()
}

final class BatchSkipUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ store: String, reset: Bool, failNextSave: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseSyntheticPhoto"]
        if reset { app.launchArguments.append("-MeowverseResetStore") }
        if failNextSave { app.launchArguments.append("-MeowverseFailNextSave") }
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        return app
    }

    private func pickThree(_ app: XCUIApplication) {
        app.addSyntheticBatch()
        XCTAssertTrue(app.buttons["start-sorting"].waitForExistence(timeout: 30))
        app.buttons["start-sorting"].tap()
        XCTAssertTrue(app.navigationBars["整理照片 1 / 3"].waitForExistence(timeout: 20))
    }

    private func skip(_ app: XCUIApplication, next: String? = nil) {
        tapSortingToolbarButton("skip-batch-photo", in: app)
        if let next {
            XCTAssertTrue(app.navigationBars[next].waitForExistence(timeout: 20))
        } else {
            XCTAssertTrue(app.buttons["skip-batch-photo"].waitForNonExistence(timeout: 10))
            XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["start-sorting"].exists)
        }
    }

    private func assertPhotoCount(_ count: Int, in app: XCUIApplication) {
        app.buttons["photo-library"].tap()
        let all = app.buttons["filter-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        XCTAssertTrue(all.label.hasSuffix("，\(count) 张"), all.label)
        XCTAssertEqual(app.buttons.matching(identifier: "library-photo").count, count)
        app.buttons["close-library"].tap()
    }

    func testSkipAllResumesAfterRelaunchAndFailedWriteCanRetry() {
        let store = "batch-skip-restart"
        var app = launch(store, reset: true)
        pickThree(app)
        skip(app, next: "整理照片 2 / 3")
        tapSortingToolbarButton("stop-sorting", in: app)
        assertPhotoCount(2, in: app)
        app.terminate()

        app = launch(store, reset: false, failNextSave: true)
        app.buttons["start-sorting"].tap()
        XCTAssertTrue(app.navigationBars["整理照片 1 / 2"].waitForExistence(timeout: 20))
        tapSortingToolbarButton("skip-batch-photo", in: app)
        let retry = app.alerts.buttons["重试"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        retry.tap()
        XCTAssertTrue(app.navigationBars["整理照片 2 / 2"].waitForExistence(timeout: 20))
        skip(app)
        assertPhotoCount(0, in: app)
    }

    func testSkippingARepeatedBatchKeepsOnlyThePreviouslyKeptPhoto() {
        let app = launch("batch-skip-existing", reset: true)
        pickThree(app)
        skip(app, next: "整理照片 2 / 3")
        skip(app, next: "整理照片 3 / 3")
        let keep = app.buttons["keep-in-library"]
        for _ in 0..<12 where !keep.isHittable { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(keep.isHittable)
        keep.tap()
        assertPhotoCount(1, in: app)

        pickThree(app)
        skip(app, next: "整理照片 2 / 3")
        skip(app, next: "整理照片 3 / 3")
        XCTAssertTrue(app.staticTexts["这张照片已在照片库中，跳过会保留原有记录。"].exists)
        skip(app)
        assertPhotoCount(1, in: app)
    }

    func testRepickingAnUnfinishedBatchStillLetsItsNewPhotosBeSkipped() {
        let app = launch("batch-skip-repicked", reset: true)
        pickThree(app)
        tapSortingToolbarButton("stop-sorting", in: app)
        pickThree(app)
        skip(app, next: "整理照片 2 / 3")
        skip(app, next: "整理照片 3 / 3")
        skip(app)
        assertPhotoCount(0, in: app)
    }

    func testSkipResetsTheCategoryForTheNextPhotoInPlace() {
        let app = launch("batch-skip-next-review", reset: true)
        pickThree(app)
        let sofa = app.buttons["manual-sofa"]
        for _ in 0..<8 where !sofa.isHittable { app.swipeUp() }
        XCTAssertTrue(sofa.isHittable)
        sofa.tap()
        XCTAssertTrue(sofa.isSelected)
        XCTAssertTrue(app.buttons["next-model"].isEnabled)
        let skipButton = app.buttons["skip-batch-photo"]
        let position = skipButton.frame.midY
        skip(app, next: "整理照片 2 / 3")
        XCTAssertEqual(skipButton.frame.midY, position, accuracy: 1)
        XCTAssertTrue(app.images["你选的照片"].isHittable)
        for _ in 0..<8 where !sofa.isHittable { app.swipeUp() }
        XCTAssertTrue(sofa.isHittable)
        XCTAssertFalse(sofa.isSelected)
        skip(app, next: "整理照片 3 / 3")
        skip(app)
        assertPhotoCount(0, in: app)
    }
}
