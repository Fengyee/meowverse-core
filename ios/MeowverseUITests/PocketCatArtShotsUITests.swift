import XCTest

/// Real screenshots of the pixel cat in the Dynamic Island (compact and expanded) and on the
/// Lock Screen, for art review. Needs a Dynamic Island simulator (iPhone 15 Pro or later).
/// With the fast rotation the Lock Screen shots step through all six expressions.
final class PocketCatArtShotsUITests: XCTestCase {
    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testPixelCatOnIslandAndLockScreen() throws {
        continueAfterFailure = false
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        try XCTSkipUnless(model.hasPrefix("iPhone1") && model >= "iPhone16,1", "Needs a Dynamic Island simulator.")
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "pocket-art"]
        app.launch()
        let interactions = app.buttons["choose-interaction"]
        XCTAssertTrue(interactions.waitForExistence(timeout: 20))
        interactions.tap()
        app.buttons["choose-pocket-cat"].tap()
        let start = app.buttons["pocket-start"], end = app.buttons["pocket-end"]
        if end.waitForExistence(timeout: 3) { end.tap() }
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        app.buttons["pocket-select"].tap()
        app.buttons["在观察"].tap()
        start.tap()
        XCTAssertTrue(end.waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.images["pocket-rotating-cat"].firstMatch.waitForExistence(timeout: 10))
        let island = springboard.otherElements.matching(identifier: "regular.view").firstMatch
        XCTAssertTrue(island.waitForExistence(timeout: 10))
        sleep(1)
        shoot("island-compact")
        springboard.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: island.frame.midX, dy: island.frame.midY))
            .press(forDuration: 1.2)
        XCTAssertTrue(springboard.buttons["pocket-change"].waitForExistence(timeout: 10))
        shoot("island-expanded")

        // Lock, wake to the Lock Screen, and step through the expressions with the
        // activity's own "change expression" button.
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        XCUIDevice.shared.press(.home)
        let change = springboard.buttons["pocket-change"].firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        // A fresh simulator asks once whether to allow Live Activities.
        let allow = springboard.buttons["Allow"].firstMatch
        if allow.exists { allow.tap() }
        sleep(1)
        shoot("lock-0")
        // The first tap on a just-woken Lock Screen is sometimes swallowed; one extra step
        // makes sure all six expressions appear.
        for index in 1..<8 {
            change.tap()
            sleep(2)
            shoot("lock-\(index)")
        }
        XCUIDevice.shared.press(.home)
        app.activate()
        if end.waitForExistence(timeout: 10) { end.tap() }
    }
}
