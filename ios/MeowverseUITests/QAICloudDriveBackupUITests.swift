import XCTest

/// Round 12 QA of task D: Back Up to iCloud Drive (audit FAMILY-4, PRIVACY-3, COPY-6). A plain
/// folder stands in for iCloud Drive (`-MeowverseCloudFolder`), one per account
/// (`-MeowverseCloudAccount`). `-cloudBackup.deviceID <id>` in the argument domain makes a launch
/// another device for backup purposes (the id is read from UserDefaults; the argument domain wins).
final class QAICloudDriveBackupUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ language: [String] = TestLanguage.chinese, store: String, reset: Bool, cloudFolder: String,
                        account: String? = nil, deviceID: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = language + ["-MeowverseStore", store, "-MeowverseSyntheticPhoto", "-MeowverseCloudFolder", cloudFolder]
        if reset { app.launchArguments.append("-MeowverseResetStore") }
        if let account { app.launchArguments += ["-MeowverseCloudAccount", account] }
        if let deviceID { app.launchArguments += ["-cloudBackup.deviceID", deviceID] }
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

    private func openSettings(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        app.buttons["open-settings"].tap()
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "查看照片", "photo")).firstMatch
            .waitForExistence(timeout: 10))
    }

    private func turnOnAndBackUp(_ app: XCUIApplication, done: String) {
        openSettings(app)
        reveal(app, "open-icloud-backup").tap()
        let toggle = app.switches["icloud-backup-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["icloud-consent-confirm"].waitForExistence(timeout: 5))
        app.buttons["icloud-consent-confirm"].tap()
        reveal(app, "icloud-backup-now").tap()
        waitForLabel(element(app, "icloud-backup-notice"), containing: done, timeout: 60)
    }

    /// PRIVACY-3: the backup in iCloud Drive was written under another device id (another iPhone,
    /// or this phone before its data moved over by a device backup: the id is remade then). It
    /// can restore everything, and the empty room offers it right after the clear, yet the
    /// clear-all dialog says only an exported backup can.
    func testQAClearAllDoesNotSayOnlyExportsRestoreWhenAnotherDevicesBackupIsThere() {
        let folder = "qa" + UUID().uuidString.prefix(8)
        var app = launch(store: "qaclear", reset: true, cloudFolder: folder, deviceID: "aaaaaaaaaaaa")
        placeSofaFromSyntheticPhoto(app)
        turnOnAndBackUp(app, done: "备份完成")
        app.terminate()

        // This iPhone under its own id: the same library and folder.
        app = launch(store: "qaclear", reset: false, cloudFolder: folder)
        sleep(2)
        openSettings(app)
        reveal(app, "clear-all").tap()
        let proceed = app.buttons["clear-all-continue"].firstMatch
        XCTAssertTrue(proceed.waitForExistence(timeout: 5))
        proceed.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        snap("qa-clear-all-message")
        let claimsOnlyExports = message.contains("只有导出过的备份能恢复")
        app.alerts.buttons["clear-all-confirm"].firstMatch.tap()
        // What the room says right after: the iCloud Drive backup is offered.
        let offer = element(app, "icloud-restore-offer")
        let offered = offer.waitForExistence(timeout: 15)
        snap("qa-clear-all-then-offer")
        XCTAssertTrue(offered, "the empty room offers the iCloud Drive backup")
        XCTAssertFalse(claimsOnlyExports, "the dialog said only exported backups restore: “\(message)”")
    }

    /// COPY-6 in English on the narrowest phone: the settings row, the page title, the switch,
    /// the account question and the consent sheet. Screenshots for review; asserts only that
    /// each is reachable and the words are the new name.
    func testQAEnglishNamesOnTheBackupPage() {
        let folder = "qa" + UUID().uuidString.prefix(8)
        var app = launch(TestLanguage.english, store: "qaen", reset: true, cloudFolder: folder, account: "first")
        placeSofaFromSyntheticPhoto(app)
        openSettings(app)
        let row = reveal(app, "open-icloud-backup")
        XCTAssertTrue(row.label.contains("Back Up to iCloud Drive"), row.label)
        snap("qa-en-settings-row")
        row.tap()
        let toggle = app.switches["icloud-backup-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "Back Up to iCloud Drive")
        snap("qa-en-page-off")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(element(app, "icloud-consent-contents").waitForExistence(timeout: 5))
        snap("qa-en-consent-top")
        // On a 375 pt phone the button is below the fold of the consent sheet.
        let agree = reveal(app, "icloud-consent-confirm")
        XCTAssertEqual(agree.label, "Start Backing Up to iCloud Drive")
        snap("qa-en-consent")
        agree.tap()
        reveal(app, "icloud-backup-now").tap()
        sleep(8)
        app.terminate()

        app = launch(TestLanguage.english, store: "qaen", reset: false, cloudFolder: folder, account: "second")
        openSettings(app)
        reveal(app, "open-icloud-backup").tap()
        waitForLabel(element(app, "icloud-backup-status"), containing: "different Apple Account")
        let keep = reveal(app, "icloud-backup-account-keep")
        XCTAssertEqual(keep.label, "Keep Backing Up to This Account")
        snap("qa-en-account-question")
        reveal(app, "icloud-backup-toggle").coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        sleep(1)
        snap("qa-en-stop-dialog")
    }
}
