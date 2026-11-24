import XCTest

/// iCloud backup with the test switch: a plain folder inside the app's container stands in
/// for iCloud Drive (real iCloud cannot be exercised on the simulator). Turn it on with
/// consent → back up now → the status says so → a fresh library is offered the backup →
/// preview → confirmed → the room has the sofa and its original photo.
/// All of it is free: these launches need no switch such as `-MeowverseSeveralHomes`.
/// A test library without the switch leaves iCloud alone; `-MeowverseRealICloud` reaches the
/// real iCloud Drive path, as a shipped build does.
final class ICloudBackupUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(store: String, reset: Bool, cloudFolder: String?, account: String? = nil, realICloud: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseSyntheticPhoto"]
        if reset { app.launchArguments.append("-MeowverseResetStore") }
        if let cloudFolder { app.launchArguments += ["-MeowverseCloudFolder", cloudFolder] }
        // Signed in to that account: it has a folder of its own, as each account has its own iCloud Drive.
        if let account { app.launchArguments += ["-MeowverseCloudAccount", account] }
        if realICloud { app.launchArguments.append("-MeowverseRealICloud") }
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 20))
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 10,
                              file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "expected “\(text)” in “\(element.exists ? element.label : "<missing>")”", file: file, line: line)
    }

    /// Lists are lazy: scroll until the row exists and can be tapped.
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(app, id)
        _ = target.waitForExistence(timeout: 3)
        for _ in 0..<5 where !(target.exists && target.isHittable) { app.swipeUp(velocity: .slow) }
        for _ in 0..<8 where !(target.exists && target.isHittable) { app.swipeDown(velocity: .slow) }
        usleep(600_000)
        XCTAssertTrue(target.exists && target.isHittable, "could not reach \(id)", file: file, line: line)
        return target
    }

    private func openSettings(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        let item = app.buttons["open-settings"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var sourceButton: NSPredicate { NSPredicate(format: "label CONTAINS %@", "查看照片") }

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
        XCTAssertTrue(app.buttons.matching(sourceButton).firstMatch.waitForExistence(timeout: 10))
    }

    func testEnableBackUpThenRestoreIntoAFreshLibrary() {
        // A folder of its own per run: earlier runs' backups never leak in.
        let folder = "ui" + UUID().uuidString.prefix(8)
        var app = launch(store: "cloudsrc", reset: true, cloudFolder: folder)
        XCTAssertFalse(element(app, "icloud-restore-offer").waitForExistence(timeout: 3), "no backup yet, so nothing is offered")
        placeSofaFromSyntheticPhoto(app)

        openSettings(app)
        reveal(app, "open-icloud-backup").tap()
        let status = element(app, "icloud-backup-status")
        waitForLabel(status, containing: "已关闭")
        XCTAssertFalse(app.buttons["icloud-backup-now"].isEnabled, "nothing can be written before consent")
        snap("cloud-1-off")

        // Consent: what is stored, how big, and where, before anything is written.
        let toggle = app.switches["icloud-backup-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let contents = element(app, "icloud-consent-contents")
        XCTAssertTrue(contents.waitForExistence(timeout: 5))
        waitForLabel(contents, containing: "1 张照片、1 件家具")
        waitForLabel(element(app, "icloud-consent-size"), containing: "一份备份约")
        snap("cloud-2-consent")
        app.buttons["icloud-consent-confirm"].tap()
        waitForLabel(status, containing: "还没有备份")

        // Back up now: built, verified, moved in; the status says what is true.
        app.buttons["icloud-backup-now"].tap()
        waitForLabel(element(app, "icloud-backup-notice"), containing: "备份完成", timeout: 60)
        waitForLabel(status, containing: "上次备份")
        waitForLabel(status, containing: "1 张照片、1 件家具")
        waitForLabel(status, containing: "已写入备份文件夹")
        snap("cloud-3-backed-up")
        // Nothing changed: no second archive.
        app.buttons["icloud-backup-now"].tap()
        waitForLabel(element(app, "icloud-backup-notice"), containing: "没有改动", timeout: 30)
        app.terminate()

        // "A new phone": a fresh, empty library that sees the same folder.
        app = launch(store: "clouddst", reset: true, cloudFolder: folder)
        XCTAssertEqual(app.buttons.matching(sourceButton).count, 0)
        let offer = element(app, "icloud-restore-offer")
        XCTAssertTrue(offer.waitForExistence(timeout: 15), "an empty room with a backup in the folder offers it")
        snap("cloud-4-offer")
        app.buttons["icloud-restore"].tap()
        let row = app.buttons["icloud-backup-row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "icloud-backup-row").count, 1, "one backup, not a duplicate")
        waitForLabel(row, containing: "1 张照片、1 件家具")
        waitForLabel(row, containing: "最新的完好备份")
        snap("cloud-5-list")
        XCTAssertEqual(app.buttons.matching(sourceButton).count, 0, "nothing is restored by listing")
        row.tap()

        // The existing preview, unchanged; nothing is replaced until it is confirmed.
        XCTAssertTrue(element(app, "preview-kind").waitForExistence(timeout: 30))
        waitForLabel(element(app, "preview-kind"), containing: "App 备份")
        waitForLabel(element(app, "preview-photos"), containing: "1 张照片")
        waitForLabel(element(app, "preview-furniture"), containing: "1 件家具")
        snap("cloud-6-preview")
        reveal(app, "confirm-restore").tap()
        waitForLabel(element(app, "backup-notice"), containing: "已从备份恢复：1 张照片、1 件家具", timeout: 30)
        app.buttons["close-icloud-restore"].tap()

        let restored = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(sourceButton).count, 1)
        XCTAssertFalse(offer.exists, "a room with furniture is not offered a restore")
        sleep(1); snap("cloud-7-restored-room")
        restored.tap()
        XCTAssertTrue(app.descendants(matching: .any)["original-photo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["photo-caption"].label.contains("2026"), "the original came back with its capture day")
    }

    /// Audit FAMILY-4: backup turned on under one Apple Account, the app opened under another
    /// (an account switch, or a phone restored under someone else's account). Neither launch nor
    /// leaving the app writes into the other account; the page asks, and only "keep backing up"
    /// lets a backup through.
    func testAnotherAppleAccountGetsNothingUntilTheUserAnswers() {
        let folder = "ui" + UUID().uuidString.prefix(8)
        var app = launch(store: "cloudacct", reset: true, cloudFolder: folder, account: "first")
        placeSofaFromSyntheticPhoto(app)
        openSettings(app)
        reveal(app, "open-icloud-backup").tap()
        let toggle = app.switches["icloud-backup-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["icloud-consent-confirm"].waitForExistence(timeout: 5))
        app.buttons["icloud-consent-confirm"].tap()
        app.buttons["icloud-backup-now"].tap()
        waitForLabel(element(app, "icloud-backup-notice"), containing: "备份完成", timeout: 60)
        app.terminate()

        // The same library, signed in to another account. Launch is an automatic trigger, and so
        // is going to the background.
        app = launch(store: "cloudacct", reset: false, cloudFolder: folder, account: "second")
        sleep(4)
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        sleep(2)
        openSettings(app)
        reveal(app, "open-icloud-backup").tap()
        let status = element(app, "icloud-backup-status")
        waitForLabel(status, containing: "另一个 Apple 账户")
        XCTAssertTrue(app.buttons["icloud-backup-account-keep"].waitForExistence(timeout: 5), "the page asks")
        XCTAssertTrue(app.buttons["icloud-backup-account-off"].exists)
        XCTAssertFalse(app.buttons["icloud-backup-now"].isEnabled, "no backup into this account before the answer")
        snap("cloud-account-asks")
        reveal(app, "icloud-restore").tap()
        waitForLabel(element(app, "icloud-restore-empty"), containing: "还没有喵空间的备份")
        XCTAssertEqual(app.buttons.matching(identifier: "icloud-backup-row").count, 0, "nothing reached the second account")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // The answer: keep backing up, to this account. Then a backup goes through.
        reveal(app, "icloud-backup-account-keep").tap()
        waitForLabel(element(app, "icloud-backup-notice"), containing: "现在登录的 Apple 账户")
        XCTAssertFalse(app.buttons["icloud-backup-account-keep"].exists, "answered: no longer asked")
        reveal(app, "icloud-backup-now").tap()
        waitForLabel(element(app, "icloud-backup-notice"), containing: "备份完成", timeout: 60)
        waitForLabel(status, containing: "上次备份")
        app.terminate()

        // Back under the first account, which is no longer the one backups belong to: asked
        // again, and turning it off is the other answer.
        app = launch(store: "cloudacct", reset: false, cloudFolder: folder, account: "first")
        openSettings(app)
        reveal(app, "open-icloud-backup").tap()
        waitForLabel(element(app, "icloud-backup-status"), containing: "另一个 Apple 账户")
        reveal(app, "icloud-backup-account-off").tap()
        let offToggle = app.switches["icloud-backup-toggle"]
        XCTAssertTrue(offToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(offToggle.value as? String, "0")
        waitForLabel(element(app, "icloud-backup-status"), containing: "已关闭")
        XCTAssertFalse(app.buttons["icloud-backup-account-keep"].exists)
    }

    /// The shipped path: the real iCloud Drive destination, free for everyone. The
    /// simulator is not signed in to iCloud, so the page says so honestly; the switch still asks
    /// for consent first and nothing is turned on by declining.
    func testShippedICloudPathIsHonestWhenSignedOut() {
        let app = launch(store: "cloudreal", reset: true, cloudFolder: nil, realICloud: true)
        XCTAssertFalse(element(app, "icloud-restore-offer").waitForExistence(timeout: 3), "no iCloud account, so nothing is offered")
        placeSofaFromSyntheticPhoto(app)
        openSettings(app)
        reveal(app, "open-icloud-backup").tap()
        let status = element(app, "icloud-backup-status")
        waitForLabel(status, containing: "没有登录 iCloud")
        XCTAssertFalse(app.buttons["icloud-backup-now"].isEnabled, "nothing can be written without iCloud Drive")
        snap("cloud-real-signed-out")
        let toggle = app.switches["icloud-backup-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(element(app, "icloud-consent-contents").waitForExistence(timeout: 5), "the switch asks for consent and nothing else")
        app.buttons["icloud-consent-cancel"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "declining leaves it off")
        waitForLabel(status, containing: "已关闭")
    }

    /// A test library without either switch stays away from iCloud: on a phone signed in to
    /// iCloud, UI tests would otherwise see (and be offered) the real backups.
    func testTestLibraryWithoutTheSwitchLeavesICloudAlone() {
        let app = launch(store: "cloudoff", reset: true, cloudFolder: nil)
        XCTAssertFalse(element(app, "icloud-restore-offer").waitForExistence(timeout: 3))
        openSettings(app)
        reveal(app, "import-web-backup")
        XCTAssertFalse(element(app, "open-icloud-backup").exists, "no iCloud row in a test library without a switch")
    }
}
