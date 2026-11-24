import XCTest

/// A photo taken in the app that is in neither Photos nor the library is held until the user
/// confirms it (JOURNEY-NEW-4, owner 2026-11-22). Quitting before confirming keeps it, and the
/// next launch asks once: 继续 reopens the same review, 不要了 deletes it. Nothing is in the
/// library until a confirmation, and clear-all takes the held photo away too. (That the file
/// stays out of device backups, exports and restores is `PendingCaptureTests` in Core.)
final class PendingCaptureUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private static let offerZh = "上次拍的照片还没有保存，要继续吗？"
    private static let offerEn = "The photo you took last time isn’t saved yet. Continue with it?"

    private func launch(_ store: String, reset: Bool = false, english: Bool = false, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (english ? TestLanguage.english : TestLanguage.chinese)
            + ["-MeowverseStore", "pending-capture-" + store, "-MeowverseFakeCamera", "-camera.savesToPhotos", "NO"]
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
        XCTAssertTrue(notice(app).waitForExistence(timeout: 20), "the review")
    }

    /// With saving to Photos off, the review's line that the photo is in neither place yet.
    private func notice(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["capture-not-saved-yet"]
    }

    private func offer(_ app: XCUIApplication, english: Bool = false) -> XCUIElement {
        app.alerts[english ? Self.offerEn : Self.offerZh]
    }

    private func expectNoOffer(_ app: XCUIApplication, english: Bool = false) {
        XCTAssertFalse(offer(app, english: english).waitForExistence(timeout: 6), "a capture was offered again")
    }

    private func libraryPhotoCount(_ app: XCUIApplication) -> Int {
        app.buttons["photo-library"].tap()
        let cell = app.buttons["library-photo"].firstMatch
        _ = cell.waitForExistence(timeout: 8)
        return app.buttons.matching(identifier: "library-photo").count
    }

    /// Quit before confirming: the library is still empty, the next launch offers the photo,
    /// 不要了 deletes it, and the launch after that offers nothing.
    func testQuittingKeepsTheCaptureOutOfTheLibraryAndDiscardDeletesIt() {
        var app = launch("discard", reset: true)
        takeFakePhoto(app)
        app.terminate()

        // The photo is held, not stored.
        app = launch("discard", ["-MeowverseNoCaptureOffer"])
        XCTAssertEqual(libraryPhotoCount(app), 0)
        XCTAssertTrue(app.staticTexts["还没有照片"].exists)
        app.terminate()

        app = launch("discard")
        let question = offer(app)
        XCTAssertTrue(question.waitForExistence(timeout: 15), "the capture is offered back")
        XCTAssertTrue(question.staticTexts["它只暂存在这台设备上，还没有放进喵空间。"].exists)
        XCTAssertEqual(question.buttons.count, 2, "one question, two answers: 继续 and 不要了")
        snap("pending-capture-offer")
        question.buttons["不要了"].tap()
        XCTAssertFalse(notice(app).waitForExistence(timeout: 3), "no review")
        XCTAssertEqual(libraryPhotoCount(app), 0)
        app.terminate()

        app = launch("discard")
        expectNoOffer(app)
    }

    /// Reopened after a relaunch, the review no longer calls it "just taken", and discarding it
    /// there deletes it as 不要了 would: nothing is offered next time.
    func testAReopenedCaptureIsLastTimesAndDiscardingItInTheReviewDeletesIt() {
        var app = launch("review-discard", reset: true)
        takeFakePhoto(app)
        app.terminate()

        app = launch("review-discard")
        let question = offer(app)
        XCTAssertTrue(question.waitForExistence(timeout: 15), "the capture is offered back")
        question.buttons["继续"].tap()
        let line = notice(app)
        XCTAssertTrue(line.waitForExistence(timeout: 20), "the same review")
        XCTAssertTrue(line.label.hasPrefix("上次拍的这张照片"), line.label)
        XCTAssertFalse(line.label.contains("刚拍"), line.label)
        app.buttons["cancel-import"].tap()
        let why = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "上次拍的这张照片没有存进")).firstMatch
        XCTAssertTrue(why.waitForExistence(timeout: 5), "the discard question says when it was taken")
        snap("pending-capture-discard-zh")
        app.buttons["不添加"].firstMatch.tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
        app.terminate()

        app = launch("review-discard")
        expectNoOffer(app)
        XCTAssertEqual(libraryPhotoCount(app), 0)
    }

    /// In English: Continue reopens the review, which still says the photo isn't saved, and
    /// storing it there puts it in the library; nothing is offered after that.
    func testContinueReopensTheReviewInEnglish() {
        var app = launch("continue-en", reset: true, english: true)
        takeFakePhoto(app)
        app.terminate()

        app = launch("continue-en", english: true)
        let question = offer(app, english: true)
        XCTAssertTrue(question.waitForExistence(timeout: 15), "the capture is offered back")
        XCTAssertTrue(question.staticTexts["It’s only held on this device and isn’t in Meowverse yet."].exists)
        snap("pending-capture-offer-en")
        question.buttons["Continue"].tap()
        let notice = notice(app)
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "the same review")
        XCTAssertTrue(notice.label.contains("isn’t saved in Meowverse yet"), notice.label)
        // Reopened after a relaunch: no longer "the photo you just took".
        XCTAssertTrue(notice.label.hasPrefix("The photo you took last time"), notice.label)
        snap("pending-capture-review-en")
        let photoOnly = app.buttons["photo-only"]
        XCTAssertTrue(photoOnly.waitForExistence(timeout: 20))
        photoOnly.tap()
        XCTAssertTrue(app.buttons["library-photo"].firstMatch.waitForExistence(timeout: 15))
        app.terminate()

        app = launch("continue-en", english: true)
        expectNoOffer(app, english: true)
        XCTAssertEqual(libraryPhotoCount(app), 1)
    }

    /// Clear-all erases the held photo with everything else. (Quitting while the question is up
    /// answers nothing: the photo is still held.)
    func testClearAllDeletesTheHeldCapture() {
        var app = launch("clear", reset: true)
        takeFakePhoto(app)
        app.terminate()

        app = launch("clear")
        XCTAssertTrue(offer(app).waitForExistence(timeout: 15), "the capture is offered back")
        app.terminate()

        app = launch("clear", ["-MeowverseNoCaptureOffer"])
        clearAll(app)
        app.terminate()

        app = launch("clear")
        expectNoOffer(app)
        XCTAssertEqual(libraryPhotoCount(app), 0)
    }

    private func clearAll(_ app: XCUIApplication) {
        app.tapSettingsGear()
        let clear = app.descendants(matching: .any)["clear-all"].firstMatch
        _ = clear.waitForExistence(timeout: 3)
        for _ in 0..<8 where !(clear.exists && clear.isHittable) { app.swipeUp(velocity: .slow) }
        usleep(600_000)
        clear.tap()
        let proceed = app.buttons["clear-all-continue"].firstMatch
        XCTAssertTrue(proceed.waitForExistence(timeout: 5))
        proceed.tap()
        let confirm = app.alerts.buttons["全部清除"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let notice = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "已清除全部数据")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "didn't clear")
    }
}
