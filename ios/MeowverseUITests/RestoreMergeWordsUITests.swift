import XCTest

/// JOURNEY-FAMILY-2: with sync on a restore is a merge, and the preview says so before it happens.
final class RestoreMergeWordsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testThePreviewSaysMergeWhileSyncIsOn() {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "restore-merge", "-MeowverseResetStore", "-MeowverseSyntheticPhoto",
                                                      "-MeowverseBackupDrill", "-MeowverseSyncFolder", "merge" + UUID().uuidString.prefix(8)]
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.buttons["photo-only"].waitForExistence(timeout: 20))
        app.buttons["photo-only"].tap()
        XCTAssertTrue(app.buttons["close-library"].waitForExistence(timeout: 10))
        app.buttons["close-library"].tap()

        app.tapSettingsGear()
        reveal(app, "open-icloud-sync").tap()
        let toggle = app.switches["icloud-sync-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["icloud-sync-consent-confirm"].waitForExistence(timeout: 5))
        app.buttons["icloud-sync-consent-confirm"].tap()
        let synced = NSPredicate(format: "label CONTAINS %@", "上次同步")
        let status = app.descendants(matching: .any)["icloud-sync-status"].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: synced, object: status)], timeout: 30), .completed)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        reveal(app, "export-backup").tap()
        XCTAssertTrue(app.descendants(matching: .any)["export-result"].firstMatch.waitForExistence(timeout: 20))
        reveal(app, "drill-restore-last-export").tap()
        XCTAssertTrue(app.descendants(matching: .any)["preview-kind"].firstMatch.waitForExistence(timeout: 30))
        let warning = reveal(app, "preview-warning").label
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "restore-merge"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(warning.contains("合并"), warning)
        XCTAssertFalse(warning.contains("替换你已有的所有"), warning)
        XCTAssertEqual(reveal(app, "confirm-restore").label, "恢复并合并")
    }

    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let target = app.descendants(matching: .any)[id].firstMatch
        _ = target.waitForExistence(timeout: 3)
        for _ in 0..<6 where !(target.exists && target.isHittable) { app.swipeUp(velocity: .slow) }
        for _ in 0..<8 where !(target.exists && target.isHittable) { app.swipeDown(velocity: .slow) }
        usleep(600_000)
        XCTAssertTrue(target.exists && target.isHittable, "could not reach \(id)")
        return target
    }
}
