import XCTest

/// The room's review shots (art/ui/reviews/r6-overlay-app/) and the system contrast audit over
/// the share folio, in whichever appearance the simulator is in. Setting `XCUIDevice.appearance`
/// from the test did not reach the app (iPhone 17 Pro, iOS 26.4), so set it from the Mac and say
/// which one it is, with a clean status bar:
///
///     xcrun simctl ui <udid> appearance dark
///     xcrun simctl status_bar <udid> override --time 9:41 …
///     TEST_RUNNER_MV_APPEARANCE=dark xcodebuild … -only-testing:MeowverseUITests/RoomReviewShotsUITests test
///
/// Attachments are named "r6-<shot>" with "-dark" added in Dark Mode.
final class RoomReviewShotsUITests: XCTestCase {
    private var dark: Bool { ProcessInfo.processInfo.environment["MV_APPEARANCE"] == "dark" }

    override func setUp() { continueAfterFailure = true }

    private func launch(store: String) -> XCUIApplication {
        let app = XCUIApplication()
        // The theme and light are app-wide settings that other tests change: pin the defaults
        // (cream oak, constant light) in the arguments domain for this launch.
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseResetStore",
                                                      "-room.appearance.theme", "cream-oak", "-room.appearance.plainWalls", "NO",
                                                      "-room.lightingMode", "constant"]
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        return app
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "r6-" + name + (dark ? "-dark" : "")
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 分享房间: the title count, the stats note and "只会分享这张明信片" pass the contrast audit.
    /// They inherited `.secondary` from the folio's ink, about 2.6:1 in light and 4.4:1 in dark.
    func testShareFolioPassesTheContrastAudit() throws {
        let app = launch(store: "review-share")
        app.buttons["open-room-share"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["room-postcard-ready"].waitForExistence(timeout: 25))
        sleep(2)
        snap("iphone-17-pro-zh-share-panel")
        try app.performAccessibilityAudit(for: .contrast) { issue in
            // Name the element, so a failure says which text.
            print("contrast issue (\(self.dark ? "dark" : "light")): \(issue.element?.identifier ?? "") “\(issue.element?.label ?? "")” \(issue.compactDescription)")
            return false
        }
    }

    /// With a synthetic photo on a sofa the folio also shows 显示回忆统计 and its note (it used
    /// `.secondary` too). The panel is scrolled so the note is on screen for the shot.
    func testShareFolioWithStatsPassesTheContrastAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "review-share-stats", "-MeowverseResetStore",
                                                      "-MeowverseSyntheticPhoto", "-room.appearance.theme", "cream-oak",
                                                      "-room.appearance.plainWalls", "NO", "-room.lightingMode", "constant"]
        app.launch()
        XCTAssertTrue(app.buttons["add-synthetic"].waitForExistence(timeout: 25))
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.buttons["manual-sofa"].waitForExistence(timeout: 20))
        app.buttons["manual-sofa"].tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons["open-room-share"].waitForExistence(timeout: 15))
        app.buttons["open-room-share"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["room-postcard-ready"].waitForExistence(timeout: 25))
        let summary = app.descendants(matching: .any)["room-share-stats-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        for _ in 0..<3 where !summary.isHittable { app.swipeUp(velocity: .slow) }
        sleep(2)
        snap("iphone-17-pro-zh-share-panel-stats")
        try app.performAccessibilityAudit(for: .contrast) { issue in
            print("contrast issue (\(self.dark ? "dark" : "light"), stats): \(issue.element?.identifier ?? "") “\(issue.element?.label ?? "")” \(issue.compactDescription)")
            return false
        }
    }

    /// The default room (for the status bar) and the 主题 tray.
    func testRoomAndThemeTrayShots() {
        let app = launch(store: "review-room")
        sleep(3)
        snap("iphone-17-pro-zh-default")
        app.buttons["open-room-appearance"].tap()
        XCTAssertTrue(app.buttons["save-room-appearance"].waitForExistence(timeout: 5))
        sleep(2)
        snap("iphone-17-pro-zh-theme-tray")
        app.buttons["cancel-room-appearance"].tap()
    }
}
