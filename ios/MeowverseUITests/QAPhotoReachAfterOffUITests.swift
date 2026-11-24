import XCTest

/// QA, round 12 task E: the photo privacy wording in states `PrivacyWordingUITests` does not
/// reach. Its four tests turn switches on in an empty room; these put a photo in iCloud first.
///
/// - Back Up to iCloud Drive paused for another Apple Account (task D): still on, a backup with
///   the photo already in iCloud Drive. 关于与隐私 must name the backup, not promise "never".
/// - A switch turned off after copies went up: stopping the backup with "keep" leaves the
///   backups in iCloud Drive, turning sync off leaves the home in iCloud (the app's own notices
///   say so). Both switches are off, `photoReach` is `.thisDeviceOnly`, and 关于与隐私 says only
///   "照片保存在这台设备上，Meowverse 不会把它们传到任何服务器": nothing tells the user that copies
///   of these photos are still in their iCloud. These two fail on 7195174 (the omission is
///   reported to the lead; the wording is the owner's call).
///
/// The guide's first stop is only reachable from an empty room, so About is what is read here.
final class QAPhotoReachAfterOffUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private let offOnly = "不会把它们传到任何服务器"

    func testAboutWhileBackupIsPausedForAnotherAccount() {
        let folder = "qa" + UUID().uuidString.prefix(8)
        var app = launch(store: "qareachacct", reset: true, extra: ["-MeowverseCloudFolder", folder, "-MeowverseCloudAccount", "first"])
        placeSofaFromSyntheticPhoto(app)
        openSettings(app)
        turnBackupOnAndBackUp(app)
        app.terminate()

        // Another Apple Account signed in: paused, still on, the backup is in the first account.
        app = launch(store: "qareachacct", reset: false, extra: ["-MeowverseCloudFolder", folder, "-MeowverseCloudAccount", "second"])
        openSettings(app)
        // Read straight away, before the backup page was ever opened in this launch.
        let early = aboutWords(app)
        reveal(app, "open-icloud-backup").tap()
        waitForLabel(element(app, "icloud-backup-status"), containing: "另一个 Apple 账户")
        snap("qa-paused")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let paused = aboutWords(app)
        snap("qa-paused-about")
        for (when, words) in [("at launch", early), ("paused", paused)] {
            XCTAssertTrue(words.contains("“备份到 iCloud 云盘”"), "\(when): “\(words)”")
            XCTAssertFalse(words.contains(offOnly), "\(when): “\(words)”")
        }
    }

    func testAboutAfterStoppingBackupAndKeepingTheBackups() {
        let folder = "qa" + UUID().uuidString.prefix(8)
        let app = launch(store: "qareachbk", reset: true, extra: ["-MeowverseCloudFolder", folder])
        placeSofaFromSyntheticPhoto(app)
        openSettings(app)
        turnBackupOnAndBackUp(app)

        // Stop, keeping what is already in iCloud Drive.
        app.switches["icloud-backup-toggle"].coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let keep = app.buttons["icloud-disable-keep"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.tap()
        waitForLabel(element(app, "icloud-backup-notice"), containing: "已有的备份还在 iCloud 云盘里")
        snap("qa-backup-stopped-kept")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let words = aboutWords(app)
        snap("qa-backup-stopped-about")
        XCTAssertTrue(words.contains("iCloud 云盘"),
                      "this device's backup with the photo is still in iCloud Drive, yet 关于与隐私 says only: “\(words)”")
    }

    func testAboutAfterTurningSyncOff() {
        let folder = "qa" + UUID().uuidString.prefix(8)
        let app = launch(store: "qareachsync", reset: true, extra: ["-MeowverseSyncFolder", folder])
        placeSofaFromSyntheticPhoto(app)

        openSettings(app)
        reveal(app, "open-icloud-sync").tap()
        let toggle = app.switches["icloud-sync-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(element(app, "icloud-sync-consent-contents").waitForExistence(timeout: 5))
        reveal(app, "icloud-sync-consent-confirm").tap()
        waitForLabel(element(app, "icloud-sync-status"), containing: "上次同步", timeout: 30)

        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let off = app.buttons["icloud-sync-disable-confirm"].firstMatch
        XCTAssertTrue(off.waitForExistence(timeout: 5))
        off.tap()
        waitForLabel(element(app, "icloud-sync-notice"), containing: "iCloud 里的数据都还在")
        snap("qa-sync-off")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let words = aboutWords(app)
        snap("qa-sync-off-about")
        XCTAssertTrue(words.contains("iCloud 里"),
                      "the photo copy is still in iCloud (sync's own notice says so), yet 关于与隐私 says only: “\(words)”")
    }

    // MARK: Steps

    private func launch(store: String, reset: Bool, extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseSyntheticPhoto"]
            + (reset ? ["-MeowverseResetStore"] : []) + extra
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        return app
    }

    /// From the Settings list: 关于与隐私 › 隐私, then back to the list.
    private func aboutWords(_ app: XCUIApplication) -> String {
        reveal(app, "open-about").tap()
        reveal(app, "about-privacy").tap()
        let photos = element(app, "about-photos")
        XCTAssertTrue(photos.waitForExistence(timeout: 10))
        let words = photos.label
        app.navigationBars.buttons.element(boundBy: 0).tap() // 隐私 → 关于与隐私
        app.navigationBars.buttons.element(boundBy: 0).tap()
        return words
    }

    /// From the Settings list: consent, then one backup with the room's photo in it.
    private func turnBackupOnAndBackUp(_ app: XCUIApplication) {
        reveal(app, "open-icloud-backup").tap()
        let toggle = app.switches["icloud-backup-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(element(app, "icloud-consent-contents").waitForExistence(timeout: 5))
        reveal(app, "icloud-consent-confirm").tap()
        app.buttons["icloud-backup-now"].tap()
        waitForLabel(element(app, "icloud-backup-notice"), containing: "备份完成", timeout: 60)
    }

    private func placeSofaFromSyntheticPhoto(_ app: XCUIApplication) {
        app.buttons["add-synthetic"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 20))
        sofa.tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        let source = NSPredicate(format: "label CONTAINS %@", "查看照片")
        XCTAssertTrue(app.buttons.matching(source).firstMatch.waitForExistence(timeout: 10))
    }

    private func openSettings(_ app: XCUIApplication) {
        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 10))
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @discardableResult
    private func reveal(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(app, id)
        _ = target.waitForExistence(timeout: 3)
        for _ in 0..<6 where !(target.exists && target.isHittable) { app.swipeUp(velocity: .slow) }
        for _ in 0..<8 where !(target.exists && target.isHittable) { app.swipeDown(velocity: .slow) }
        usleep(600_000)
        XCTAssertTrue(target.exists && target.isHittable, "could not reach \(id)", file: file, line: line)
        return target
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 15,
                              file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "expected “\(text)” in “\(element.exists ? element.label : "<missing>")”", file: file, line: line)
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
