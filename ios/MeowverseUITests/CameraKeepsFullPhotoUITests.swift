import XCTest

/// A photo taken in the app is the only full-size file unless Photos took it. With
/// `-MeowverseLargeSyntheticPhoto` the stand-in camera hands over 3600x2700 px, more than the
/// 2048 px the app keeps of a picked photo: saving off or refused, the app keeps the whole
/// file; saved to Photos, it keeps a reduced copy as before. Before the user confirms, the
/// review must not call the photo saved. Quitting there keeps the photo out of the library and
/// held for the next launch (JOURNEY-NEW-4, `PendingCaptureUITests`).
final class CameraKeepsFullPhotoUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() { continueAfterFailure = false }

    private func launch(store: String, reset: Bool, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseFakeCamera", "-MeowverseLargeSyntheticPhoto"]
            + (reset ? ["-MeowverseResetStore"] : []) + extra
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        return app
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func takeFakePhoto(_ app: XCUIApplication) {
        app.buttons["add-photo"].tap()
        let camera = app.buttons["add-photo-camera"]
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
        camera.tap()
        let use = app.buttons["fake-camera-use"]
        XCTAssertTrue(use.waitForExistence(timeout: 10))
        use.tap()
    }

    private func answerPhotosPrompt(allow: Bool) {
        let labels = allow ? ["Allow", "允许", "Allow Access"] : ["Don’t Allow", "Don't Allow", "不允许"]
        let button = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the add-only Photos prompt did not appear")
        button.tap()
    }

    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let target = app.descendants(matching: .any)[id].firstMatch
        for _ in 0..<6 where !(target.exists && target.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(target.exists && target.isHittable, "could not reach \(id)")
        return target
    }

    private func storePhotoOnly(_ app: XCUIApplication) {
        let photoOnly = app.buttons["photo-only"]
        XCTAssertTrue(photoOnly.waitForExistence(timeout: 20))
        photoOnly.tap()
    }

    /// Opens the only photo of a relaunched library and checks what the app kept of it.
    private func expectStoredPhoto(_ app: XCUIApplication, whole: Bool) {
        app.buttons["photo-library"].tap()
        let cell = app.buttons["library-photo"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "library-photo").count, 1)
        cell.tap()
        let status = reveal(app, "photo-storage-status")
        if whole {
            XCTAssertEqual(status.label, "已保存完整原件")
            let size = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "3600×2700")).firstMatch
            for _ in 0..<6 where !(size.exists && size.isHittable) { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(size.exists, "the detail shows the camera's full 3600×2700 file")
            XCTAssertFalse(app.descendants(matching: .any)["reduced-copy-note"].exists)
        } else {
            XCTAssertEqual(status.label, "已保存缩小副本，请保留系统相册里的原件。")
            let note = reveal(app, "reduced-copy-note")
            XCTAssertTrue(note.label.contains("3600×2700"), note.label)
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "2048×1536")).firstMatch.exists)
        }
    }

    /// Saving to Photos switched off: confirmed with "只存照片", the full camera file is what
    /// the app has after a relaunch.
    func testCameraPhotoWithSavingOffKeepsItsFullFile() {
        var app = launch(store: "camera-full-off", reset: true, ["-camera.savesToPhotos", "NO"])
        takeFakePhoto(app)
        XCTAssertFalse(app.descendants(matching: .any)["capture-not-in-photos"].waitForExistence(timeout: 2))
        storePhotoOnly(app)
        XCTAssertTrue(app.buttons["library-photo"].firstMatch.waitForExistence(timeout: 10))
        app.terminate()

        app = launch(store: "camera-full-off", reset: false, ["-camera.savesToPhotos", "NO"])
        expectStoredPhoto(app, whole: true)
        snap("camera-full-off-detail")
    }

    /// Add access refused. The review says the photo is in neither place yet. Quitting there
    /// keeps the photo, but not in the library: the next launch offers it back, and the reopened
    /// review still says it was refused. A failed save keeps saying so, and the retry stores the
    /// whole file, which a relaunch still shows; nothing is offered after that.
    func testRefusedPhotosSaveIsNotCalledSavedAndTheConfirmedPhotoIsWhole() {
        var app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        // The refusal outlives the app: later tests on this simulator would be refused too.
        addTeardownBlock { XCUIApplication().resetAuthorizationStatus(for: .photos) }
        app = launch(store: "camera-full-refused", reset: true)
        takeFakePhoto(app)
        answerPhotosPrompt(allow: false)
        let notice = app.descendants(matching: .any)["capture-not-in-photos"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertTrue(notice.label.contains("也还没有存进喵空间"), notice.label)
        XCTAssertFalse(notice.label.contains("只保存在喵空间里"), "not stored anywhere yet: \(notice.label)")
        snap("camera-refused-review")

        // Not confirmed: quitting here stores nothing in the library, as the line said...
        app.terminate()
        app = launch(store: "camera-full-refused", reset: false, ["-MeowverseNoCaptureOffer"])
        app.buttons["photo-library"].tap()
        XCTAssertTrue(app.staticTexts["还没有照片"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["library-photo"].exists)
        app.terminate()

        // ...but keeps the photo: the next launch offers it, and the same review comes back.
        // The first save fails: the review stays and still says nothing is saved.
        app = launch(store: "camera-full-refused", reset: false, ["-MeowverseFailNextSave"])
        let offer = app.alerts["上次拍的照片还没有保存，要继续吗？"]
        XCTAssertTrue(offer.waitForExistence(timeout: 15), "the unconfirmed photo is offered back")
        offer.buttons["继续"].tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertTrue(notice.label.contains("可以在系统设置里允许"), "still the refusal: \(notice.label)")
        storePhotoOnly(app)
        let alert = app.alerts["没能保存"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.buttons["取消"].tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.label.contains("也还没有存进喵空间"), "the failed save stored nothing: \(notice.label)")
        storePhotoOnly(app)
        XCTAssertTrue(app.buttons["library-photo"].firstMatch.waitForExistence(timeout: 15))
        app.terminate()

        app = launch(store: "camera-full-refused", reset: false)
        XCTAssertFalse(app.alerts["上次拍的照片还没有保存，要继续吗？"].waitForExistence(timeout: 6), "offered after it was stored")
        expectStoredPhoto(app, whole: true)
        snap("camera-refused-detail")
    }

    /// Control: with the save to Photos confirmed, the app keeps the reduced copy as before.
    func testCameraPhotoSavedToPhotosKeepsTheReducedCopy() {
        var app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app = launch(store: "camera-full-saved", reset: true)
        takeFakePhoto(app)
        answerPhotosPrompt(allow: true)
        storePhotoOnly(app)
        XCTAssertFalse(app.descendants(matching: .any)["capture-not-in-photos"].exists)
        XCTAssertTrue(app.buttons["library-photo"].firstMatch.waitForExistence(timeout: 10))
        app.terminate()

        app = launch(store: "camera-full-saved", reset: false)
        expectStoredPhoto(app, whole: false)
    }
}
