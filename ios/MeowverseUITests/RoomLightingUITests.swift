import XCTest

final class RoomLightingUITests: XCTestCase {
    func testCancelOrSaveRoomLightingAndReopen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "lighting-ui", "-MeowverseResetStore"]
        app.launch()

        func openEditor() {
            XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20))
            app.buttons["open-room-appearance"].tap()
        }
        let picker = app.buttons["room-lighting-mode"]
        func select(_ title: String) {
            picker.tap()
            app.buttons[title].tap()
            XCTAssertEqual(picker.value as? String, title)
        }
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }

        openEditor()
        select("恒定柔光")
        app.buttons["save-room-appearance"].tap()
        openEditor()
        capture("room-steady-light")
        select("跟随当地时间")
        capture("room-local-light")
        app.buttons["cancel-room-appearance"].tap()
        openEditor()
        XCTAssertEqual(picker.value as? String, "恒定柔光")
        select("跟随当地时间")
        app.buttons["save-room-appearance"].tap()
        app.terminate()
        app.launch()
        openEditor()
        XCTAssertEqual(picker.value as? String, "跟随当地时间")
        select("恒定柔光")
        app.buttons["save-room-appearance"].tap()
    }
}
