import XCTest

/// JOURNEY-NEW-4, the words: a photo just taken that Photos doesn't have is said to be unsaved
/// before any discard, and only a refusal is blamed on permission.
final class CaptureSaveWordsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testARefusalKeepsTheSettingsAdvice() {
        let app = takePhoto(store: "capture-refused", ["-MeowversePhotosSave", "refused"])
        let line = notice(app, "capture-not-in-photos")
        XCTAssertTrue(line.contains("系统设置"), line)
        XCTAssertTrue(line.contains("还没有存进喵空间"), line)
    }

    func testAFailureDoesNotBlamePermission() {
        let app = takePhoto(store: "capture-failed", ["-MeowversePhotosSave", "failed"])
        let line = notice(app, "capture-not-in-photos")
        XCTAssertFalse(line.contains("系统设置"), "a failure was blamed on permission: \(line)")
        XCTAssertFalse(line.contains("允许"), line)
        XCTAssertTrue(line.contains("储存空间"), line)
        XCTAssertTrue(line.contains("还没有存进喵空间"), line)
        snap("capture-failed")
    }

    func testAFailureInEnglish() {
        let app = takePhoto(store: "capture-failed-en", ["-MeowversePhotosSave", "failed"], language: TestLanguage.english)
        let line = notice(app, "capture-not-in-photos")
        XCTAssertFalse(line.contains("Settings"), "a failure was blamed on permission: \(line)")
        XCTAssertTrue(line.contains("storage"), line)
        snap("capture-failed-en")
    }

    func testWithSavingOffTheReviewSaysItIsNotSavedYet() {
        let app = takePhoto(store: "capture-off", ["-camera.savesToPhotos", "<false/>"])
        let line = notice(app, "capture-not-saved-yet")
        XCTAssertTrue(line.contains("还没有存进喵空间"), line)
        XCTAssertFalse(line.contains("系统设置"), "nothing failed: \(line)")
        snap("capture-off")
    }

    private func takePhoto(store: String, _ extra: [String], language: [String] = TestLanguage.chinese) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = language + ["-MeowverseStore", store, "-MeowverseResetStore", "-MeowverseFakeCamera"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        app.buttons["add-photo"].tap()
        let camera = app.buttons["add-photo-camera"]
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
        camera.tap()
        let use = app.buttons["fake-camera-use"]
        XCTAssertTrue(use.waitForExistence(timeout: 10))
        use.tap()
        XCTAssertTrue(app.buttons["cancel-import"].waitForExistence(timeout: 20))
        return app
    }

    private func notice(_ app: XCUIApplication, _ id: String) -> String {
        let element = app.descendants(matching: .any)[id].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 15), "the review never said it: \(id)")
        return element.exists ? element.label : ""
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
