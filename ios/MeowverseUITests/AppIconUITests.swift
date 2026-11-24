import XCTest

/// Settings → App icon: the switch is on by default, today's icon follows the date rule, the
/// real icon change goes through the system (its alert is captured once), and turning the
/// switch off goes back to the primary icon. `-MeowverseIconDate` stands in for today.
final class AppIconUITests: XCTestCase {
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "app-icon", "-MeowverseIconReset"] + extra
        app.launch()
        return app
    }

    private func openSettings(_ app: XCUIApplication) -> XCUIElement {
        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let toggle = app.switches["app-icon-follows"]
        for _ in 0..<6 where !(toggle.exists && toggle.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        return toggle
    }

    private func probe(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["app-icon-probe"].firstMatch
    }

    /// Waits for the system's "You have changed the icon" alert, keeps a screenshot, and
    /// dismisses it. Looks in SpringBoard and in the app, since iOS versions differ.
    private func acceptIconAlert(_ app: XCUIApplication, name: String) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(10)
        var alert: XCUIElement?
        while alert == nil, Date() < deadline {
            if springboard.alerts.firstMatch.exists { alert = springboard.alerts.firstMatch }
            else if app.alerts.firstMatch.exists { alert = app.alerts.firstMatch }
            else { usleep(250_000) }
        }
        // Run from a clean state (the test ends on the primary icon); a leftover holiday icon
        // from an interrupted run means no change and no alert.
        guard let alert else { return XCTFail("no icon-change alert") }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        alert.buttons.firstMatch.tap()
    }

    func testSwitchFollowsTheDateAndTurnsOff() {
        continueAfterFailure = false
        let app = launch(["-MeowverseIconSwitching", "-MeowverseIconDate", "2026-12-25"])
        // The change runs about a second after the app becomes active.
        acceptIconAlert(app, name: "icon-changed-christmas")
        // The Home Screen shows the new icon.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        sleep(1)
        let home = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        home.name = "home-screen-christmas-icon"
        home.lifetime = .keepAlways
        add(home)
        app.activate()
        let toggle = openSettings(app)
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertEqual(app.staticTexts["app-icon-today"].label, "今天：圣诞冬青")
        let probe = probe(app)
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        XCTAssertEqual(probe.value as? String, "AppIcon-christmas-holly AppIcon-christmas-holly")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "settings-app-icon"
        shot.lifetime = .keepAlways
        add(shot)

        // Tap the switch itself; the middle of the row is the label and does not flip it.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        acceptIconAlert(app, name: "icon-changed-primary")
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(app.staticTexts["app-icon-today"].exists)
        let primary = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "primary primary"), object: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [primary], timeout: 5), .completed)

        // Coming back to the foreground does not change it again while the switch is off.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.waitForExistence(timeout: 4))
        XCTAssertEqual(probe.value as? String, "primary primary")
    }

    /// A southern-hemisphere region gets the winter icon in July, and an ordinary test launch
    /// (no `-MeowverseIconSwitching`) never changes the icon, so no alert interrupts other tests.
    func testRegionPicksTheSeasonAndTestLaunchesDoNotSwitch() {
        continueAfterFailure = false
        let app = launch(["-MeowverseIconDate", "2026-07-15", "-MeowverseIconRegion", "AU"])
        // Look before touching anything: XCUITest's own interruption handler dismisses a
        // system alert that blocks a tap, which would hide a change.
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 4))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        _ = openSettings(app)
        XCTAssertEqual(app.staticTexts["app-icon-today"].label, "今天：冬日围巾")
        let probe = probe(app)
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let parts = (probe.value as? String ?? "").split(separator: " ").map(String.init)
        XCTAssertEqual(parts.first, "AppIcon-winter-knit")
        // Not switched: the current icon is still whatever it was, not today's.
        XCTAssertNotEqual(parts.last, "AppIcon-winter-knit")
    }
}
