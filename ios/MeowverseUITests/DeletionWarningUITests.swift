import XCTest

/// DATA-1: deleting or clearing promises an original in Photos only when Photos confirms one
/// right now. Otherwise the photo may be the only copy, and the dialog says so. With iCloud sync
/// on it also says the other devices lose the photo; with backup on, that the next backup does.
/// Photos come from the stand-in camera and test folders stand in for iCloud.
final class DeletionWarningUITests: XCTestCase {
    private let promise = "相册里的原片不受影响"
    private let oldPromise = "相册里的原照片不受影响"
    private let onlyCopy = "可能是唯一一份"
    private let otherDevices = "其他设备上也会删除"
    private let nextBackup = "下一次备份里也不会再有"

    override func setUp() {
        continueAfterFailure = false
        XCUIApplication().resetAuthorizationStatus(for: .photos)
        addTeardownBlock { XCUIApplication().resetAuthorizationStatus(for: .photos) }
    }

    func testWithoutPhotosAccessEveryDeleteWarns() {
        let app = launch(store: "lossoff", ["-camera.savesToPhotos", "NO"])
        storeCameraPhoto(app)
        let cell = app.buttons["library-photo"].firstMatch

        // The photo's own page.
        cell.tap()
        reveal(app, "delete-photo").tap()
        var words = dialog(app, containing: "会被删除")
        expect(words, has: [onlyCopy], lacks: [promise, oldPromise, otherDevices, nextBackup])
        snap("delete-detail")
        dismissDialog(app)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // The long-press menu.
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        cell.press(forDuration: 1.2)
        let delete = app.buttons["删除"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(app.buttons["confirm-delete-photo"].firstMatch.waitForExistence(timeout: 5))
        words = dialog(app, containing: "会被删除")
        expect(words, has: [onlyCopy], lacks: [promise, oldPromise])
        snap("delete-menu")
        dismissDialog(app)

        // Several at once.
        app.buttons["select-photos"].tap()
        app.buttons["select-all-photos"].tap()
        app.buttons["batch-delete"].tap()
        XCTAssertTrue(app.buttons["confirm-delete-photos"].firstMatch.waitForExistence(timeout: 5))
        words = dialog(app, containing: "删除的是")
        expect(words, has: [onlyCopy], lacks: [promise, oldPromise, otherDevices, nextBackup])
        snap("delete-batch")
        dismissDialog(app)
        app.terminate()

        // Clear all: the footer and the question.
        let again = launch(store: "lossoff", reset: false)
        openSettings(again)
        reveal(again, "clear-all")
        let footer = dialog(again, containing: "删除喵空间里的全部")
        expect(footer, has: [onlyCopy], lacks: [promise, oldPromise])
        reveal(again, "clear-all").tap()
        XCTAssertTrue(again.buttons["clear-all-continue"].firstMatch.waitForExistence(timeout: 5))
        words = dialog(again, containing: "会删除喵空间")
        expect(words, has: [onlyCopy], lacks: [promise, oldPromise])
        snap("clear-all")
    }

    func testBackupOnSaysTheNextBackupLosesThePhoto() {
        let app = launch(store: "lossbackup", ["-camera.savesToPhotos", "NO", "-MeowverseCloudFolder", folder()])
        turnOnBackup(app)
        storeCameraPhoto(app)
        let words = askToDeleteFirstPhoto(app)
        expect(words, has: [onlyCopy, nextBackup], lacks: [promise, oldPromise, otherDevices, "无法恢复"])
        snap("delete-backup")
    }

    func testSyncOnSaysOtherDevicesLoseThePhoto() {
        let app = launch(store: "losssync", ["-camera.savesToPhotos", "NO", "-MeowverseSyncFolder", folder()])
        turnOnSync(app)
        storeCameraPhoto(app)
        let words = askToDeleteFirstPhoto(app)
        expect(words, has: [onlyCopy, otherDevices], lacks: [promise, oldPromise, nextBackup])
        snap("delete-sync")
        dismissDialog(app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["close-library"].tap()

        // Deleting the home in iCloud empties every device: the last question warns too.
        openSettings(app)
        reveal(app, "clear-all").tap()
        tap(app.buttons["clear-all-continue"].firstMatch)
        tap(app.buttons["clear-all-everywhere"].firstMatch)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        let last = dialog(app, containing: "iCloud 里的家会被删除")
        expect(last, has: [onlyCopy], lacks: [promise, oldPromise])
        snap("clear-everywhere")
    }

    func testBackupAndSyncSayBoth() {
        let name = folder()
        let app = launch(store: "lossboth", ["-camera.savesToPhotos", "NO", "-MeowverseCloudFolder", name, "-MeowverseSyncFolder", name])
        turnOnSync(app)
        turnOnBackup(app)
        storeCameraPhoto(app)
        expect(askToDeleteFirstPhoto(app), has: [onlyCopy, otherDevices, nextBackup], lacks: [promise, oldPromise])
        snap("delete-both")
    }

    /// Full access and a photo Photos took: the promise is true and is made. Access taken away
    /// again: it can no longer be confirmed, so the same photo gets the warning.
    func testPromiseOnlyWhilePhotosConfirmsTheOriginal() {
        var app = launch(store: "lossphotos", ["-MeowverseLibraryIntro", "-photoLibraryLinkWanted", "<false/>"], fakeCamera: false)
        app.buttons["add-photo"].tap()
        tap(app.buttons["library-intro-continue"])
        PhotosPrompt.answer(PhotosPrompt.fullAccess)
        app.terminate()

        app = launch(store: "lossphotos")
        storeCameraPhoto(app)
        expect(askToDeleteFirstPhoto(app), has: [promise], lacks: [onlyCopy])
        snap("delete-confirmed")
        dismissDialog(app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["close-library"].tap()
        openSettings(app)
        reveal(app, "clear-all").tap()
        XCTAssertTrue(app.buttons["clear-all-continue"].firstMatch.waitForExistence(timeout: 5))
        expect(dialog(app, containing: "会删除喵空间"), has: [promise], lacks: [onlyCopy])
        snap("clear-confirmed")
        app.terminate()

        app.resetAuthorizationStatus(for: .photos)
        app = launch(store: "lossphotos", reset: false)
        app.buttons["photo-library"].tap()
        expect(askToDeleteFirstPhoto(app), has: [onlyCopy], lacks: [promise, oldPromise])
        // The question itself must not ask for access.
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.waitForExistence(timeout: 2))
    }

    func testEnglishWarningAndPromiseWords() {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.english + ["-MeowverseStore", "lossenglish", "-MeowverseResetStore", "-MeowverseFakeCamera",
                                                     "-camera.savesToPhotos", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        storeCameraPhoto(app)
        app.buttons["library-photo"].firstMatch.tap()
        reveal(app, "delete-photo").tap()
        expect(dialog(app, containing: "will be deleted"), has: ["may be the only copy"], lacks: ["is not affected", "cannot be recovered"])
        snap("delete-english")
    }

    // MARK: Steps

    private func folder() -> String { "loss" + UUID().uuidString.prefix(8) }

    private func launch(store: String, reset: Bool = true, _ extra: [String] = [], fakeCamera: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store] + (reset ? ["-MeowverseResetStore"] : [])
            + (fakeCamera ? ["-MeowverseFakeCamera"] : []) + extra
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        return app
    }

    private func storeCameraPhoto(_ app: XCUIApplication) {
        app.buttons["add-photo"].tap()
        tap(app.buttons["add-photo-camera"])
        tap(app.buttons["fake-camera-use"])
        tap(app.buttons["photo-only"], timeout: 20)
        XCTAssertTrue(app.buttons["library-photo"].firstMatch.waitForExistence(timeout: 15))
    }

    private func askToDeleteFirstPhoto(_ app: XCUIApplication) -> String {
        tap(app.buttons["library-photo"].firstMatch)
        reveal(app, "delete-photo").tap()
        return dialog(app, containing: "会被删除")
    }

    private func dialog(_ app: XCUIApplication, containing text: String) -> String {
        let message = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10), "no words containing “\(text)”")
        return message.label
    }

    private func dismissDialog(_ app: XCUIApplication) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        usleep(700_000)
    }

    private func openSettings(_ app: XCUIApplication) {
        app.tapSettingsGear()
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 10))
    }

    private func turnOnBackup(_ app: XCUIApplication) {
        turnOn(app, page: "open-icloud-backup", toggle: "icloud-backup-toggle", sheet: "icloud-consent-contents", confirm: "icloud-consent-confirm")
    }

    private func turnOnSync(_ app: XCUIApplication) {
        turnOn(app, page: "open-icloud-sync", toggle: "icloud-sync-toggle", sheet: "icloud-sync-consent-contents", confirm: "icloud-sync-consent-confirm")
    }

    private func turnOn(_ app: XCUIApplication, page: String, toggle id: String, sheet: String, confirm: String) {
        openSettings(app)
        reveal(app, page).tap()
        let toggle = app.switches[id]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(app.descendants(matching: .any)[sheet].firstMatch.waitForExistence(timeout: 5))
        reveal(app, confirm).tap()
        let on = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)
        XCTAssertEqual(XCTWaiter().wait(for: [on], timeout: 15), .completed, "\(id) did not turn on")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["close-settings"].tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
    }

    private func tap(_ element: XCUIElement, timeout: TimeInterval = 10) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element)")
        element.tap()
    }

    @discardableResult
    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let target = app.descendants(matching: .any)[id].firstMatch
        _ = target.waitForExistence(timeout: 3)
        for _ in 0..<8 where !(target.exists && target.isHittable) { app.swipeUp(velocity: .slow) }
        for _ in 0..<8 where !(target.exists && target.isHittable) { app.swipeDown(velocity: .slow) }
        usleep(500_000)
        XCTAssertTrue(target.exists && target.isHittable, "could not reach \(id)")
        return target
    }

    private func expect(_ words: String, has: [String], lacks: [String], file: StaticString = #filePath, line: UInt = #line) {
        for text in has { XCTAssertTrue(words.contains(text), "expected “\(text)” in “\(words)”", file: file, line: line) }
        for text in lacks { XCTAssertFalse(words.contains(text), "“\(text)” must not be in “\(words)”", file: file, line: line) }
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
