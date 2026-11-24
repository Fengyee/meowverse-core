import XCTest

/// The room on a table (AR, round 11 trial). The simulator cannot track the world, so these
/// tests only reach the entry in 互动 and the page's "not available here" state. Placing,
/// gestures, the walking cat and furniture taps on a table are checked on a phone.
final class RoomARUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ language: [String], _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = language + ["-MeowverseStore", "ar-tabletop", "-MeowverseResetStore"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 30))
        app.buttons["choose-interaction"].tap()
        XCTAssertTrue(app.buttons["choose-pocket-cat"].waitForExistence(timeout: 10))
        return app
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Where the device cannot track the world (here: the simulator) there is no row at all.
    func testNoRowWithoutWorldTracking() {
        let app = launch(TestLanguage.chinese)
        XCTAssertFalse(app.buttons["open-ar-tabletop"].exists)
        shot("3-ar-row-hidden-zh")
    }

    /// The row sits right under 陪我一会儿 and opens the page; 回到房间 brings the room back.
    func testRowUnderCompanyOpensThePageAndExitReturns() {
        let app = launch(TestLanguage.chinese, ["-MeowverseShowAREntry"])
        let row = app.buttons["open-ar-tabletop"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.hasPrefix("放到桌上看看"), row.label)
        // Directly below: nothing else in between (the next section is the furniture's).
        let company = app.buttons["choose-pocket-cat"]
        XCTAssertGreaterThan(row.frame.minY, company.frame.maxY)
        XCTAssertLessThan(row.frame.minY - company.frame.maxY, 60)
        shot("1-ar-row-zh")
        row.tap()

        let exit = app.buttons["ar-exit"]
        XCTAssertTrue(exit.waitForExistence(timeout: 10))
        XCTAssertEqual(exit.label, "回到房间")
        XCTAssertTrue(app.descendants(matching: .any)["ar-unsupported"].exists)
        XCTAssertTrue(app.staticTexts["这台设备不能用 AR"].exists)
        shot("2-ar-page-unsupported-zh")
        exit.tap()
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["choose-interaction"].isHittable)
        XCTAssertFalse(exit.exists)
    }

    func testEnglishRowAndExit() {
        let app = launch(TestLanguage.english, ["-MeowverseShowAREntry"])
        let row = app.buttons["open-ar-tabletop"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.hasPrefix("See it on a table"), row.label)
        shot("4-ar-row-en")
        row.tap()
        let exit = app.buttons["ar-exit"]
        XCTAssertTrue(exit.waitForExistence(timeout: 10))
        XCTAssertEqual(exit.label, "Back to the room")
        XCTAssertTrue(app.staticTexts["AR isn’t available on this device"].exists)
        shot("5-ar-page-unsupported-en")
        exit.tap()
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 10))
    }

    /// Camera access off: the row stays and says so.
    func testCameraOffRowSaysWhy() {
        let app = launch(TestLanguage.chinese, ["-MeowverseShowAREntry", "-MeowverseFakeCameraDenied"])
        let row = app.buttons["open-ar-tabletop"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("相机权限已关闭"), row.label)
        shot("6-ar-row-camera-off-zh")
    }
}
