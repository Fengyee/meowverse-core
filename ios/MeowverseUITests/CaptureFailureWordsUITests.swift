import XCTest

/// A read that failed promises an original in Photos only where there is one: not for a photo
/// just taken that Photos doesn't have. `-MeowverseFailImportRead` makes every read fail.
final class CaptureFailureWordsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testACaptureThatCouldNotBeReadPromisesNoOriginal() {
        let app = launch(store: "capture-unread", ["-MeowverseFakeCamera", "-camera.savesToPhotos", "<false/>"])
        app.buttons["add-photo"].tap()
        XCTAssertTrue(app.buttons["add-photo-camera"].waitForExistence(timeout: 5))
        app.buttons["add-photo-camera"].tap()
        XCTAssertTrue(app.buttons["fake-camera-use"].waitForExistence(timeout: 10))
        app.buttons["fake-camera-use"].tap()
        XCTAssertTrue(failure(app, "没能").waitForExistence(timeout: 20), "the failure is not said")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "capture-unread"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertFalse(failure(app, "原照片").exists, "promised an original that doesn't exist")
        XCTAssertTrue(failure(app, "没有存下来").exists)
    }

    func testAPickedPhotoKeepsItsPromise() {
        let app = launch(store: "picked-unread", ["-MeowverseSyntheticPhoto"])
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(failure(app, "原照片没有变化").waitForExistence(timeout: 20))
    }

    private func launch(store: String, _ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseResetStore", "-MeowverseFailImportRead"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        return app
    }

    private func failure(_ app: XCUIApplication, _ words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }
}
