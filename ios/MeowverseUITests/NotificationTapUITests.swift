import XCTest

/// A real, delivered notification tapped from the Home Screen must bring the app to the front and
/// keep it running. Uses the system notification center (no fake), so it needs the simulator's
/// permission prompt; on a second run the permission is already there.
///
/// Regression for 0.1.0 (1): the tap showed the launch snapshot and then the app aborted, because
/// the async delegate method completed off the main thread.
final class NotificationTapUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let arguments = ["-MeowverseStore", "notification-tap", "-MeowverseSystemNotifications"]

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + arguments + extra
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 20))
        return app
    }

    /// A first launch, then the real system prompt from Settings → 提醒: the first launch no
    /// longer opens the reminder page (PRODUCT_PLAN §2.2, Plan A).
    private func setUpFirstLaunch(furniture: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese.filter { $0 != "-MeowverseSkipReminderSetup" }
            + arguments + ["-MeowverseResetStore", "-MeowverseSyntheticPhoto"]
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 30))
        app.buttons["open-settings"].tap()
        let row = app.buttons["open-reminders"]
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        row.tap()
        let calls = app.switches[furniture ? "reminder-furniture" : "reminder-calls"]
        XCTAssertTrue(calls.waitForExistence(timeout: 10))
        let inner = calls.switches.firstMatch
        (inner.exists ? inner : calls).tap()
        let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允许"])).firstMatch
        if allow.waitForExistence(timeout: 8) { allow.tap() }
        let on = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: calls)
        XCTAssertEqual(XCTWaiter().wait(for: [on], timeout: 10), .completed, "notifications were not allowed")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["close-settings"].tap()
        return app
    }

    func testTappingADeliveredReminderOpensTheAppAndItKeepsRunning() {
        var app = setUpFirstLaunch()
        app.terminate()

        // The test reminder is added once the launch reschedule has run with permission granted.
        app = launch(["-MeowverseTestReminderIn", "5"])
        sleep(1)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended)

        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "测试提醒")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "the test reminder was not delivered")
        banner.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "the tap did not open the app")
        // The 0.1.0 (1) crash came a moment after the app came forward; give it time to happen.
        sleep(4)
        XCTAssertEqual(app.state, .runningForeground, "the app did not stay open after the tap")
        XCTAssertTrue(app.buttons["add-photo"].exists)
    }

    private func createReminderTarget() -> XCUIApplication {
        let app = setUpFirstLaunch(furniture: true)
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.buttons["manual-sofa"].waitForExistence(timeout: 20))
        app.buttons["manual-sofa"].tap()
        app.buttons["next-model"].tap()
        app.buttons["next-placement"].tap()
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 15))
        return app
    }

    func testFurnitureTapWaitsForPhotoReviewToFinish() {
        createReminderTarget().terminate()
        let app = launch(["-MeowverseTestReminderIn", "12", "-MeowverseSyntheticPhoto"])
        app.buttons["add-synthetic"].tap()
        let cancel = app.buttons["cancel-import"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "测试提醒")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 25))
        banner.tap()
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        app.buttons["不添加"].tap()
        XCTAssertTrue(app.buttons["close-detail"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["拉扣软包沙发"].exists)
    }

    /// Deliver a real furniture reminder while the first of three queued photos is being reviewed.
    /// Placing that photo returns to the room for 1.1s before automatically advancing.
    private func placeFirstBatchPhotoWithPendingReminder() -> XCUIApplication {
        let setup = createReminderTarget()
        setup.addSyntheticBatch()
        XCTAssertTrue(setup.buttons["start-sorting"].waitForExistence(timeout: 30))
        setup.terminate()

        let app = launch(["-MeowverseTestReminderIn", "12", "-MeowverseColorGridSimilarity"])
        app.buttons["start-sorting"].tap()
        XCTAssertTrue(app.navigationBars["整理照片 1 / 3"].waitForExistence(timeout: 15))
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "测试提醒")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 25))
        banner.tap()

        // Create a board, so only the original sofa can satisfy the eventual detail assertion.
        let board = app.buttons["similar-none"]
        XCTAssertTrue(board.waitForExistence(timeout: 15))
        board.tap()
        app.buttons["next-placement"].tap()
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.navigationBars["整理照片 2 / 3"].waitForExistence(timeout: 20))
        return app
    }

    func testFurnitureTapWaitsAcrossBatchPlacementUntilSortingStops() {
        let app = placeFirstBatchPhotoWithPendingReminder()
        tapSortingToolbarButton("stop-sorting", in: app)
        XCTAssertTrue(app.navigationBars["拉扣软包沙发"].waitForExistence(timeout: 10))
        app.buttons["close-detail"].tap()
        let count = app.staticTexts["pending-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertEqual(count.label, "2 张照片待整理")
        app.buttons["start-sorting"].tap()
        XCTAssertTrue(app.navigationBars["整理照片 1 / 2"].waitForExistence(timeout: 10))
    }

    func testFurnitureTapOpensWhenBatchFinishes() {
        let app = placeFirstBatchPhotoWithPendingReminder()
        tapSortingToolbarButton("skip-batch-photo", in: app)
        XCTAssertTrue(app.navigationBars["整理照片 3 / 3"].waitForExistence(timeout: 10))
        tapSortingToolbarButton("skip-batch-photo", in: app)
        XCTAssertTrue(app.navigationBars["拉扣软包沙发"].waitForExistence(timeout: 10))
        app.buttons["close-detail"].tap()
        XCTAssertFalse(app.buttons["start-sorting"].exists)
    }

    /// A reminder that arrives while the app is open shows as a banner, and tapping it keeps the app running.
    func testAReminderArrivingWhileOpenShowsAndTappingItKeepsTheAppRunning() {
        var app = setUpFirstLaunch()
        app.terminate()

        app = launch(["-MeowverseTestReminderIn", "4"])
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "测试提醒")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "the banner did not show while the app was open")
        XCTAssertEqual(app.state, .runningForeground, "the app stopped when the reminder arrived")
        banner.tap()
        sleep(4)
        XCTAssertEqual(app.state, .runningForeground, "the app did not stay open after the tap")
        XCTAssertTrue(app.buttons["add-photo"].exists)
    }
}
