import XCTest

final class RoomAppearanceUITests: XCTestCase {
    func testPreviewCancelAndSaveWallpaperInRoomAndPostcard() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "seasons", "-MeowverseResetStore"]
        app.launch()
        func openEditor() {
            XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20))
            app.buttons["open-room-appearance"].tap()
            XCTAssertTrue(app.buttons["save-room-appearance"].waitForExistence(timeout: 5))
        }
        func choose(_ id: String) {
            let option = app.buttons["room-theme-" + id]
            app.scrollThemeTray(to: option)
            option.tap()
        }
        func snapshot(_ title: String) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = title
            shot.lifetime = .keepAlways
            add(shot)
        }

        openEditor()
        choose("sea-salt")
        app.buttons["save-room-appearance"].tap()
        openEditor()
        choose("winter-knit")
        app.buttons["cancel-room-appearance"].tap()
        openEditor()
        XCTAssertTrue(app.buttons["room-theme-sea-salt"].isSelected)
        choose("winter-knit")
        let plain = app.switches["plain-room-walls"]
        let wallSwitch = plain.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5))
        if plain.value as? String == "1" { wallSwitch.tap() }
        snapshot("winter-wallpaper")
        wallSwitch.tap()
        XCTAssertEqual(plain.value as? String, "1")
        snapshot("winter-plain")
        app.buttons["save-room-appearance"].tap()

        app.terminate()
        app.launch()
        openEditor()
        XCTAssertTrue(app.buttons["room-theme-winter-knit"].isSelected)
        XCTAssertEqual(plain.value as? String, "1")
        wallSwitch.tap()
        app.buttons["save-room-appearance"].tap()
        app.buttons["open-room-share"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["room-postcard-ready"].waitForExistence(timeout: 25))
        snapshot("winter-room-postcard")
    }
}

extension XCUIApplication {
    /// The paper chips scroll sideways; one may sit wholly off screen, where XCTest cannot even ask
    /// whether it is hittable. A swipe carries on past a middle chip of the thirteen, in either
    /// direction, so drag toward it by the distance left and hold before letting go.
    func scrollThemeTray(to chip: XCUIElement) {
        let screen = windows.firstMatch.frame
        for _ in 0..<24 where !screen.contains(chip.frame) {
            let reach = screen.width * 0.35
            let step = min(max(screen.midX - chip.frame.midX, -reach), reach)
            let origin = coordinate(withNormalizedOffset: .zero)
            let from = origin.withOffset(CGVector(dx: screen.midX, dy: chip.frame.midY))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: step, dy: 0)),
                       withVelocity: .fast, thenHoldForDuration: 0.15)
        }
    }
}
