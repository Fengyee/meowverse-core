import XCTest

/// IMPORT-1: for a photo already stored, 整理 and 「用它添一件新家具」 show the record's capture
/// day, not a day read again from the stored file (a reduced copy has none) or from a file
/// picked again. A day the user entered stays, and an unknown day stays unknown.
final class ReviewCaptureDayUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testStoredDayThenTheUsersDayAreWhatTheReviewShows() {
        let app = launch(store: "review-day")
        app.buttons["add-synthetic"].tap()
        tap(app.buttons["photo-only"], timeout: 30)
        tap(app.buttons["library-photo"].firstMatch)

        // Stored as a reduced copy, so the stored file has no EXIF; the record has the day.
        reveal(app, "make-furniture").tap()
        XCTAssertTrue(app.descendants(matching: .any)["stored-notice"].waitForExistence(timeout: 20))
        XCTAssertEqual(dayShown(app), "拍摄于 2026年3月14日（来自照片信息）")
        snap("review-stored-day")
        cancelReview(app)

        openStoredPhoto(app)
        reveal(app, "edit-date").tap()
        let picker = app.datePickers.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        tap(picker.descendants(matching: .button).matching(NSPredicate(format: "label CONTAINS %@", "3月10日")).firstMatch)
        app.buttons["save-date"].tap()
        let line = app.staticTexts["photo-date-line"]
        let edited = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "你填写的"), object: line)
        XCTAssertEqual(XCTWaiter().wait(for: [edited], timeout: 10), .completed)
        let usersDay = line.label
        XCTAssertTrue(usersDay.contains("2026年3月10日"), usersDay)

        reveal(app, "make-furniture").tap()
        XCTAssertTrue(app.descendants(matching: .any)["stored-notice"].waitForExistence(timeout: 20))
        let shown = dayShown(app)
        XCTAssertTrue(shown.contains("2026年3月10日") && shown.contains("你填写的"), shown)
        snap("review-user-day")
        cancelReview(app)

        // The same file picked again still has its EXIF day: the user's day wins.
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["stored-notice"].waitForExistence(timeout: 30))
        let again = dayShown(app)
        XCTAssertTrue(again.contains("2026年3月10日") && again.contains("你填写的"), again)
    }

    func testSortingKeepsAnUnknownDayUnknown() {
        let app = launch(store: "review-unknown")
        app.addSyntheticBatch()
        XCTAssertTrue(app.buttons["start-sorting"].waitForExistence(timeout: 40))
        app.buttons["start-sorting"].tap()
        XCTAssertTrue(app.navigationBars["整理照片 1 / 3"].waitForExistence(timeout: 20))
        XCTAssertEqual(dayShown(app), "拍摄日期未知")
    }

    // MARK: Steps

    private func launch(store: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseResetStore",
                                                     "-MeowverseSyntheticPhoto", "-MeowverseLargeSyntheticPhoto"]
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        return app
    }

    private func dayShown(_ app: XCUIApplication) -> String {
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "拍摄")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10), "no date line in the review")
        return line.label
    }

    private func openStoredPhoto(_ app: XCUIApplication) {
        tap(app.buttons["photo-library"])
        tap(app.buttons["library-photo"].firstMatch)
        XCTAssertTrue(app.staticTexts["photo-date-line"].waitForExistence(timeout: 10))
    }

    private func cancelReview(_ app: XCUIApplication) {
        app.buttons["cancel-import"].tap()
        tap(app.buttons["不添加"].firstMatch)
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
    }

    private func tap(_ element: XCUIElement, timeout: TimeInterval = 10) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element)")
        element.tap()
    }

    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let target = app.descendants(matching: .any)[id].firstMatch
        _ = target.waitForExistence(timeout: 5)
        for _ in 0..<8 where !(target.exists && target.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(target.exists && target.isHittable, "could not reach \(id)")
        return target
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
