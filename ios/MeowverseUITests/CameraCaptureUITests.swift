import XCTest

/// "添加照片 → 拍照" and the Home Screen quick actions. The simulator has no camera:
/// `-MeowverseFakeCamera` stands a drawn photo in for it, handed over the way the camera does
/// (sensor pixels, metadata with a capture time of 2026-05-20 and a location).
/// `-MeowverseQuickAction` delivers a quick action at launch, as a tap on the Home Screen does.
final class CameraCaptureUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() { continueAfterFailure = false }

    private func launch(store: String, reset: Bool = true, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store] + (reset ? ["-MeowverseResetStore"] : []) + extra
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
        XCTAssertTrue(app.buttons["add-photo-library"].exists)
        snap("camera-1-menu")
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

    private var reviewDate: NSPredicate { NSPredicate(format: "label CONTAINS %@", "2026年5月20日") }

    /// The camera's photo goes through the same review as a picked one, keeps its EXIF day,
    /// and ends up in the new piece's album. Not saved to Photos here: discarding would lose it,
    /// and the confirmation says so.
    func testCameraPhotoIsReviewedAndOpensFromItsFurniture() {
        let app = launch(store: "camera-shot", ["-MeowverseFakeCamera", "-camera.savesToPhotos", "NO"])
        takeFakePhoto(app)
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.matching(reviewDate).firstMatch.exists, "the camera's EXIF day is shown in review")
        XCTAssertFalse(app.descendants(matching: .any)["capture-not-in-photos"].exists)
        snap("camera-2-review")

        app.buttons["cancel-import"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "刚拍的照片没有存进")).firstMatch
            .waitForExistence(timeout: 5))
        app.buttons["不添加"].tap()
        XCTAssertTrue(app.buttons["place-furniture-first"].waitForExistence(timeout: 10), "discarding leaves the room empty")

        takeFakePhoto(app)
        XCTAssertTrue(sofa.waitForExistence(timeout: 20))
        sofa.tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()

        let piece = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查看照片")).firstMatch
        XCTAssertTrue(piece.waitForExistence(timeout: 15))
        piece.tap()
        XCTAssertTrue(app.descendants(matching: .any)["original-photo"].waitForExistence(timeout: 10))
        let caption = app.descendants(matching: .any)["photo-caption"]
        XCTAssertTrue(caption.label.contains("2026年5月20日"), caption.label)
        snap("camera-3-album")
    }

    /// With saving on and add access refused, the photo is imported anyway and the review says
    /// in one line that it is not in Photos. Allowing it removes the line.
    func testSavingToPhotosAsksForAddAccessAndAFailureIsOneLine() {
        var app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app = launch(store: "camera-denied-photos", ["-MeowverseFakeCamera"])
        takeFakePhoto(app)
        answerPhotosPrompt(allow: false)
        let notice = app.descendants(matching: .any)["capture-not-in-photos"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["manual-sofa"].exists)
        snap("camera-4-not-in-photos")
        app.terminate()

        app.resetAuthorizationStatus(for: .photos)
        app = launch(store: "camera-allowed-photos", ["-MeowverseFakeCamera"])
        takeFakePhoto(app)
        answerPhotosPrompt(allow: true)
        XCTAssertTrue(app.buttons["manual-sofa"].waitForExistence(timeout: 20))
        XCTAssertFalse(notice.exists)
        app.buttons["cancel-import"].tap()
        // In Photos now, so discarding it here loses nothing.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "相册里的原照片不受影响")).firstMatch
            .waitForExistence(timeout: 5))
    }

    func testDeniedCameraOffersSettingsOrThePhotoLibrary() {
        let app = launch(store: "camera-denied", ["-MeowverseFakeCameraDenied", "-MeowverseLibraryIntro"])
        app.buttons["add-photo"].tap()
        app.buttons["add-photo-camera"].tap()
        let alert = app.alerts["无法打开相机"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.buttons["打开系统设置"].exists)
        alert.buttons["从相册选择"].tap()
        XCTAssertTrue(app.buttons["library-intro-continue"].waitForExistence(timeout: 5))
    }

    /// Without a camera nothing changes: one tap opens the library, and there is no camera item.
    func testWithoutACameraAddPhotoOpensTheLibraryDirectly() {
        let app = launch(store: "camera-none", ["-MeowverseLibraryIntro"])
        app.buttons["add-photo"].tap()
        XCTAssertTrue(app.buttons["library-intro-continue"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["add-photo-camera"].exists)
    }

    func testEnglishMenuAndNotice() {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.english + ["-MeowverseStore", "camera-english", "-MeowverseResetStore",
                                                     "-MeowverseSyntheticPhoto", "-MeowverseFakeCamera",
                                                     "-MeowverseQuickAction", "app.meowverse.library", "-MeowverseQuickActionDelay", "25"]
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        app.buttons["add-photo"].tap()
        XCTAssertEqual(app.buttons["add-photo-library"].label, "Choose from Photos")
        XCTAssertEqual(app.buttons["add-photo-camera"].label, "Take Photo")
        app.buttons["add-photo-camera"].tap()
        app.buttons["fake-camera-cancel"].tap()
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.buttons["cancel-import"].waitForExistence(timeout: 10))
        let notice = app.descendants(matching: .any)["quick-action-notice"]
        XCTAssertFalse(notice.exists, "the action arrives once the review is open")
        XCTAssertTrue(notice.waitForExistence(timeout: 30))
        XCTAssertEqual(notice.label, "Finish or stop what you’re doing first, then add photos.")
    }

    // MARK: Quick actions

    func testColdLaunchFromCameraActionOpensTheCameraOverTheRoom() {
        let app = launch(store: "quick-camera", ["-MeowverseFakeCamera", "-MeowverseQuickAction", "app.meowverse.camera"])
        XCTAssertTrue(app.buttons["fake-camera-use"].waitForExistence(timeout: 10))
    }

    func testColdLaunchFromLibraryActionOpensThePicker() {
        let app = launch(store: "quick-library", ["-MeowverseLibraryIntro", "-MeowverseQuickAction", "app.meowverse.library"])
        XCTAssertTrue(app.buttons["library-intro-continue"].waitForExistence(timeout: 10))
    }

    func testColdLaunchFromCompanionActionShowsCompanyOverTheRoom() {
        let app = launch(store: "quick-companion", ["-MeowverseQuickAction", "app.meowverse.companion"])
        let done = app.buttons["pocket-close-return"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        snap("quick-companion")
        done.tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["add-photo"].isHittable)
    }

    /// "看看回忆" opens a piece that has a photo, chosen when tapped (here the only one).
    func testColdLaunchFromMemoryActionOpensAPieceWithPhotos() {
        var app = launch(store: "quick-memory", ["-MeowverseSyntheticPhoto"])
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.buttons["manual-sofa"].waitForExistence(timeout: 20))
        app.buttons["manual-sofa"].tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查看照片")).firstMatch.waitForExistence(timeout: 15))
        app.terminate()

        app = launch(store: "quick-memory", reset: false, ["-MeowverseQuickAction", "app.meowverse.memory"])
        XCTAssertTrue(app.buttons["close-detail"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["original-photo"].waitForExistence(timeout: 10))
    }

    /// A quick action to add photos while a review is open leaves the review where it is,
    /// says why in one line, and does not open the camera later.
    func testCameraActionDuringAReviewIsHeldBackWithOneLine() {
        let app = launch(store: "quick-busy", ["-MeowverseSyntheticPhoto", "-MeowverseFakeCamera",
                                               "-MeowverseQuickAction", "app.meowverse.camera", "-MeowverseQuickActionDelay", "6"])
        app.buttons["add-synthetic"].tap()
        let cancel = app.buttons["cancel-import"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        let notice = app.descendants(matching: .any)["quick-action-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertEqual(notice.label, "先完成或停止正在进行的事，再添加照片。")
        snap("quick-busy")
        XCTAssertTrue(cancel.isHittable, "the review stays in front")
        XCTAssertFalse(app.buttons["fake-camera-use"].exists)
        XCTAssertTrue(notice.waitForNonExistence(timeout: 8))
        cancel.tap()
        app.buttons["不添加"].tap()
        XCTAssertFalse(app.buttons["fake-camera-use"].waitForExistence(timeout: 2), "nothing was queued for later")
    }

    /// The real Home Screen: the registered items (no "看看回忆" without a piece that has a
    /// photo), and an item tapped while the app is in the background reaches it.
    func testHomeScreenMenuShowsTheItemsAndBringsCompanyFromTheBackground() {
        let app = launch(store: "quick-home", ["-MeowverseFakeCamera"])
        sleep(1)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended)
        let name = app.label
        let icon = springboard.icons[name]
        XCTAssertTrue(icon.waitForExistence(timeout: 10), "no icon named \(name)")
        for _ in 0..<4 where !icon.isHittable { springboard.swipeLeft(); sleep(1) }
        XCTAssertTrue(icon.isHittable)
        icon.press(forDuration: 1.5)
        let company = springboard.buttons["陪我一会儿"]
        XCTAssertTrue(company.waitForExistence(timeout: 5), springboard.debugDescription)
        XCTAssertTrue(springboard.buttons["拍照添加"].exists)
        XCTAssertTrue(springboard.buttons["从相册添加"].exists)
        XCTAssertFalse(springboard.buttons["看看回忆"].exists)
        // The first item sits closest to the icon.
        let distances = ["拍照添加", "从相册添加", "陪我一会儿"].map { abs(springboard.buttons[$0].frame.midY - icon.frame.midY) }
        XCTAssertEqual(distances, distances.sorted(), "\(distances)")
        snap("home-screen-menu")
        company.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.buttons["pocket-close-return"].waitForExistence(timeout: 10))
    }

    /// In English the four Home Screen titles are all title case; the companion screen's own
    /// title ("Keep me company") is a different key and is left as it is.
    func testHomeScreenTitlesInEnglish() {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.english + ["-MeowverseStore", "quick-home-en", "-MeowverseResetStore", "-MeowverseFakeCamera"]
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        sleep(1)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended)
        let icon = springboard.icons[app.label]
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        for _ in 0..<4 where !icon.isHittable { springboard.swipeLeft(); sleep(1) }
        icon.press(forDuration: 1.5)
        let company = springboard.buttons["Keep Me Company"]
        XCTAssertTrue(company.waitForExistence(timeout: 5), springboard.debugDescription)
        XCTAssertTrue(springboard.buttons["Take Photo"].exists)
        XCTAssertTrue(springboard.buttons["Add from Photos"].exists)
        snap("home-screen-menu-en")
        company.tap()
        XCTAssertTrue(app.buttons["pocket-close-return"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Keep me company"].exists, "the companion screen keeps its own title")
    }

    /// The scene delegate added for quick actions leaves the companion link working: it still
    /// opens company over an open sheet, and "完成" returns to that sheet.
    func testCompanionLinkStillOpensOverASheet() throws {
        let app = launch(store: "quick-link")
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 5))
        let host = try XCTUnwrap(Bundle(for: Self.self).bundleIdentifier?.replacingOccurrences(of: ".uitests", with: ""))
        XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: host + "://companion")))
        let open = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
        if open.waitForExistence(timeout: 5) { open.tap() }
        let done = app.buttons["pocket-close-return"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 5))
    }

    /// Settings rows are in a lazy list: scroll until the row can be tapped.
    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let target = app.descendants(matching: .any)[id].firstMatch
        for _ in 0..<6 where !(target.exists && target.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(target.exists && target.isHittable, "could not reach \(id)")
        return target
    }

    /// Settings → `row`, type `text` into `field`, then wait for the delayed quick action. It
    /// must not close Settings and lose the text: nothing moves, and one line says why.
    private func assertDraftIsKept(action: String, row: String, field: String, extra: [String] = []) -> XCUIApplication {
        let app = launch(store: "draft-guard", ["-MeowverseFakeCamera", "-MeowverseQuickAction", action,
                                                "-MeowverseQuickActionDelay", "40"] + extra)
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 5))
        reveal(app, row).tap()
        let input = app.descendants(matching: .any)[field].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Half-written draft")
        XCTAssertFalse(app.descendants(matching: .any)["quick-action-notice"].exists, "the action arrives after the draft is written")
        let notice = app.descendants(matching: .any)["quick-action-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 45), "the quick action did not arrive or was not held back")
        XCTAssertEqual(notice.label, "先完成或停止正在进行的事，再添加照片。")
        snap("draft-kept-\(row)")
        sleep(3)
        XCTAssertTrue(input.exists, "the page with the draft is still open")
        XCTAssertTrue((input.value as? String ?? "").contains("Half-written draft"), "\(input.value ?? "")")
        XCTAssertFalse(app.buttons["fake-camera-use"].exists)
        XCTAssertFalse(app.buttons["library-intro-continue"].exists)
        return app
    }

    func testCameraActionKeepsAHalfWrittenFeedback() {
        _ = assertDraftIsKept(action: "app.meowverse.camera", row: "open-feedback", field: "feedback-description")
    }

    func testLibraryActionKeepsAHalfWrittenWish() {
        _ = assertDraftIsKept(action: "app.meowverse.library", row: "open-wish", field: "wish-what", extra: ["-MeowverseLibraryIntro"])
    }

    /// An idea field left empty is not a draft: Settings closes and the camera opens as before.
    func testCameraActionClosesAnEmptyWishPage() {
        let app = launch(store: "draft-empty", ["-MeowverseFakeCamera", "-MeowverseQuickAction", "app.meowverse.camera",
                                                "-MeowverseQuickActionDelay", "35"])
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 5))
        reveal(app, "open-wish").tap()
        XCTAssertTrue(app.descendants(matching: .any)["wish-what"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["fake-camera-use"].exists, "the action arrives after the page is open")
        XCTAssertTrue(app.buttons["fake-camera-use"].waitForExistence(timeout: 45))
    }

    /// A page with nothing unsaved (settings) is closed to get back to the room first.
    func testCameraActionClosesSettingsAndOpensTheCamera() {
        let app = launch(store: "quick-settings", ["-MeowverseFakeCamera",
                                                   "-MeowverseQuickAction", "app.meowverse.camera", "-MeowverseQuickActionDelay", "12"])
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["camera-saves-to-photos"].exists, "the setting shows where a camera exists")
        XCTAssertFalse(app.buttons["fake-camera-use"].exists)
        XCTAssertTrue(app.buttons["fake-camera-use"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["close-settings"].exists)
        app.buttons["fake-camera-cancel"].tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 5))
    }
}
