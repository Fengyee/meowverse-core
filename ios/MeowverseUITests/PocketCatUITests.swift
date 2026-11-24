import XCTest

final class PocketCatUITests: XCTestCase {
    private func openCompany(fastRotation: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "pocket-cat"]
        if fastRotation { app.launchArguments.append("-MeowverseFastPocketCat") }
        app.launch()
        let interactions = app.buttons["choose-interaction"]
        XCTAssertTrue(interactions.waitForExistence(timeout: 20))
        interactions.tap()
        app.buttons["choose-pocket-cat"].tap()
        return app
    }

    func testExpressionRotatesWithoutLeavingTheCompanionScreen() {
        continueAfterFailure = false
        let app = openCompany(fastRotation: true)
        let start = app.buttons["pocket-start"], end = app.buttons["pocket-end"]
        if end.exists { end.tap() }
        app.buttons["pocket-select"].tap()
        app.buttons["在观察"].tap()
        start.tap()
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        let expression = app.staticTexts["pocket-expression"]
        XCTAssertEqual(expression.label, "在观察")
        let different = NSPredicate(format: "label != %@ AND label != %@", "在观察", "")
        let rotates = XCTNSPredicateExpectation(predicate: different, object: expression)
        XCTAssertEqual(XCTWaiter.wait(for: [rotates], timeout: 12), .completed)
        end.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
    }

    private func requireIslandTestSimulator() throws {
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        // The SpringBoard layout and coordinate assertions below target iPhone 15 Pro and iPhone 17.
        try XCTSkipUnless(["iPhone16,1", "iPhone18,3"].contains(model),
                          "Run the Dynamic Island scenarios on an iPhone 15 Pro or iPhone 17 simulator.")
    }

    private func expandIsland(in springboard: XCUIApplication) {
        let island = springboard.otherElements.matching(identifier: "regular.view").firstMatch
        XCTAssertTrue(island.waitForExistence(timeout: 10))
        springboard.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: island.frame.midX, dy: island.frame.midY))
            .press(forDuration: 1.2)
    }

    func testCompanyStartsChangesAndEndsInApp() {
        continueAfterFailure = false
        let app = openCompany()
        let start = app.buttons["pocket-start"], end = app.buttons["pocket-end"]
        if end.exists { end.tap() }
        start.tap()
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        app.buttons["pocket-select"].tap()
        app.buttons["在观察"].tap()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertEqual(app.staticTexts["pocket-expression"].label, "在观察")
        end.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
    }

    func testExpandedIslandChangesAndEndsCompany() throws {
        try requireIslandTestSimulator()
        continueAfterFailure = false
        let app = openCompany()
        let start = app.buttons["pocket-start"]
        let end = app.buttons["pocket-end"]
        if end.exists { end.tap() }
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(start.label, "开始陪伴")
        start.tap()
        XCTAssertTrue(end.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["pocket-select"].tap()
        let thinking = app.buttons["在思考"]
        XCTAssertTrue(thinking.waitForExistence(timeout: 5))
        thinking.tap()
        XCTAssertEqual(app.staticTexts["pocket-expression"].label, "在思考")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.images["pocket-rotating-cat"].firstMatch.waitForExistence(timeout: 10))
        let systemScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        systemScreenshot.name = "pixel-cat-home"
        systemScreenshot.lifetime = .keepAlways
        add(systemScreenshot)
        expandIsland(in: springboard)
        let change = springboard.buttons["pocket-change"]
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        let expanded = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        expanded.name = "pixel-cat-expanded"
        expanded.lifetime = .keepAlways
        add(expanded)
        change.tap()
        app.activate()
        XCTAssertTrue(app.staticTexts.matching(identifier: "pocket-expression")
            .matching(NSPredicate(format: "label == %@", "在吃饭")).firstMatch.waitForExistence(timeout: 8))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        let endOnIsland = springboard.buttons["pocket-end"]
        if !endOnIsland.exists { expandIsland(in: springboard) }
        XCTAssertTrue(endOnIsland.waitForExistence(timeout: 8))
        endOnIsland.tap()
        app.activate()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertFalse(end.exists)
    }

    func testTappingCompactCatReturnsFromAnotherSheetToCompany() throws {
        try requireIslandTestSimulator()
        continueAfterFailure = false
        let app = openCompany()
        if !app.buttons["pocket-end"].exists { app.buttons["pocket-start"].tap() }
        XCTAssertTrue(app.buttons["pocket-end"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["choose-toy"].tap()
        XCTAssertTrue(app.buttons["play-item-toyMouse"].waitForExistence(timeout: 6))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let island = springboard.otherElements.matching(identifier: "regular.view").firstMatch
        XCTAssertTrue(island.waitForExistence(timeout: 10))
        let midpoint = springboard.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: island.frame.midX, dy: island.frame.midY))
        midpoint.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let end = app.buttons["pocket-end"]
        XCTAssertTrue(end.waitForExistence(timeout: 8), app.debugDescription)
        end.tap()
        let done = app.buttons["pocket-close-return"]
        XCTAssertTrue(done.exists)
        done.tap()
        XCTAssertTrue(app.buttons["play-item-toyMouse"].waitForExistence(timeout: 6))
    }
}
