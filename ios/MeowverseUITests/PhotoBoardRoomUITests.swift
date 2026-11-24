import XCTest

final class PhotoBoardRoomUITests: XCTestCase {
    func testBoardPhotosNeverSuggestFurnitureAndLocalBoardIsTheFallback() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + [
            "-MeowverseStore", "photo-board-rooms", "-MeowverseSyntheticPhoto", "-MeowverseResetStore",
            "-MeowverseSeveralHomes", "-MeowverseColorGridSimilarity"
        ]
        app.launch()
        let switcher = app.buttons["room-switcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 20))
        let firstRoom = switcher.label

        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.buttons["manual-sofa"].waitForExistence(timeout: 20))
        let category = app.buttons["manual-photoBoard"]
        revealAndTap(category, in: app)
        app.buttons["next-model"].tap()
        app.buttons["next-placement"].tap()
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(switcher.waitForExistence(timeout: 15))
        switcher.tap()
        app.buttons["new-room"].tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.typeText("书房")
        app.alerts.buttons["新建"].tap()
        XCTAssertTrue(app.showsRoom("书房", timeout: 15))
        app.addSyntheticBatch()
        let start = app.buttons["start-sorting"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        start.tap()
        let unrecognised = app.buttons["similar-none"]
        XCTAssertTrue(unrecognised.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["similar-0"].exists)
        XCTAssertTrue(unrecognised.label.contains("新挂一块照片板"), unrecognised.label)
        revealAndTap(unrecognised, in: app)
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.navigationBars["整理照片 2 / 3"].waitForExistence(timeout: 20))

        XCTAssertTrue(unrecognised.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["similar-0"].exists)
        revealAndTap(app.buttons["attach-existing"], in: app)
        XCTAssertTrue(app.buttons["attach-0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["attach-0"].label.contains(firstRoom))
        XCTAssertTrue(app.buttons["attach-1"].label.contains("书房"))
        app.buttons["attach-0"].tap()
        XCTAssertTrue(app.navigationBars["整理照片 3 / 3"].waitForExistence(timeout: 15))
    }

    private func revealAndTap(_ row: XCUIElement, in app: XCUIApplication,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(row.waitForExistence(timeout: 10), file: file, line: line)
        let bar = app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH '整理照片' OR identifier == '照片里的家具'")).firstMatch
        XCTAssertTrue(bar.exists, file: file, line: line)
        let top = bar.frame.maxY
        let bottom = app.buttons["next-model"].frame.minY
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for _ in 0..<12 {
            let y = row.frame.midY
            if y > top + 10, y < bottom - 10, row.isHittable {
                row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return
            }
            let distance = min(max(abs(y - (top + bottom) / 2), 70), 240)
            center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 0, dy: y > bottom - 10 ? -distance : distance)),
                         withVelocity: .slow, thenHoldForDuration: 0.15)
        }
        XCTFail("Could not bring the center of \(row.identifier) between the navigation bar and footer", file: file, line: line)
    }
}
