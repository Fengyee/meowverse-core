import XCTest

/// The room scene's side of wall pieces and the storage box, with a drawn, non-private photo:
/// a photo board hangs on a wall, keeps its place across a relaunch, opens its details, slides
/// and changes wall in edit mode; a floor piece leaves the room through the edit tray's 收起.
final class WallAndStorageSceneUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(reset: Bool, store: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseSyntheticPhoto"]
        if reset { app.launchArguments.append("-MeowverseResetStore") }
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 20))
        return app
    }

    /// Synthetic photo → manual category → model → the placement editor.
    private func walkToPlacement(_ app: XCUIApplication, category: String) {
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.buttons["manual-sofa"].waitForExistence(timeout: 20))
        // The category grid is lazy: rows further down exist only once scrolled to.
        let choice = app.buttons["manual-\(category)"]
        for _ in 0..<6 where !choice.exists { app.swipeUp() }
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "model-preview-ready").waitForExistence(timeout: 10), "the model has a preview")
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        sleep(2)
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func hotspot(_ app: XCUIApplication, named name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", name, "查看照片")).firstMatch
    }

    private func value(_ element: XCUIElement) -> String { element.value as? String ?? "" }

    /// Long press, then keep the finger down and move it by `offset` points (or to `target`).
    private func pressAndDrag(_ element: XCUIElement, by offset: CGVector = .zero, to target: XCUICoordinate? = nil) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 1, thenDragTo: target ?? start.withOffset(offset))
    }

    private func finishEdit(_ app: XCUIApplication) {
        let done = app.buttons["edit-done"]
        XCTAssertTrue(done.isEnabled, "the draft is allowed: \(element(app, "edit-status").label)")
        done.tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
        sleep(1)
    }

    func testPhotoBoardHangsSlidesChangesWallAndSurvivesRelaunch() {
        var app = launch(reset: true, store: "wall-board")
        walkToPlacement(app, category: "photoBoard")

        // The editor offers wall controls, not floor ones.
        let wallPicker = element(app, "wall-side")
        XCTAssertTrue(wallPicker.exists)
        XCTAssertTrue(app.buttons["wall-slide-left"].exists)
        XCTAssertFalse(app.buttons["转四分之一圈"].exists, "a wall piece cannot be turned")
        XCTAssertEqual(element(app, "placement-status").label, "这个位置可以摆放")
        snap("W1-wall-placement-editor")
        // Past the end of the wall is refused with a reason, and one step back is fine again.
        for _ in 0..<8 { app.buttons["wall-slide-right"].tap() }
        XCTAssertEqual(element(app, "placement-status").label, "超出了房间范围")
        XCTAssertFalse(app.buttons["confirm-placement"].isEnabled)
        for _ in 0..<8 { app.buttons["wall-slide-left"].tap() }
        XCTAssertEqual(element(app, "placement-status").label, "这个位置可以摆放")
        app.buttons["confirm-placement"].tap()

        var board = hotspot(app, named: "照片板")
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        sleep(1)
        let hung = value(board)
        XCTAssertTrue(hung.contains("后墙"), "the suggestion is the back wall: \(hung)")
        snap("W2-board-on-back-wall")
        // A point on the back wall, for dragging the board back there later.
        let backWall = board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let backWallPoint = backWall.screenPoint
        let originalMidY = element(app, "room-world").frame.midY

        app.terminate()
        app = launch(reset: false, store: "wall-board")
        board = hotspot(app, named: "照片板")
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        XCTAssertEqual(value(board), hung, "the board hangs where it was after a relaunch")

        // A tap opens its details, like any other piece.
        board.tap()
        XCTAssertTrue(element(app, "original-photo").waitForExistence(timeout: 10))
        app.buttons["close-detail"].tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))

        // Edit mode: no turning, a button for the other wall.
        let tray = element(app, "edit-tray")
        board.press(forDuration: 1)
        XCTAssertTrue(tray.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["edit-rotate"].exists)
        XCTAssertTrue(app.buttons["edit-stow"].exists)
        app.buttons["edit-switch-wall"].tap()
        sleep(1); snap("W3-edit-on-left-wall")
        finishEdit(app)
        let onLeft = value(board)
        XCTAssertTrue(onLeft.contains("左墙"), "the button moved it to the left wall: \(onLeft)")
        snap("W4-board-on-left-wall")

        // Dragging along the left wall (down-left on screen) slides it without leaving the wall.
        pressAndDrag(board, by: CGVector(dx: -40, dy: 24))
        XCTAssertTrue(tray.waitForExistence(timeout: 5))
        finishEdit(app)
        let slid = value(board)
        XCTAssertTrue(slid.contains("左墙"), "still on the left wall: \(slid)")
        XCTAssertNotEqual(slid, onLeft, "the drag slid it along the wall")

        // Dragging onto the back wall moves it there.
        let leftPoint = CGPoint(x: board.frame.midX, y: board.frame.midY)
        board.press(forDuration: 1)
        XCTAssertTrue(tray.waitForExistence(timeout: 5))
        // The taller edit tray moves the room vertically. Both wall points follow its centre.
        let dy = element(app, "room-world").frame.midY - originalMidY
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: leftPoint.x, dy: leftPoint.y + dy))
        let target = origin.withOffset(CGVector(dx: backWallPoint.x, dy: backWallPoint.y + dy))
        start.press(forDuration: 0.1, thenDragTo: target)
        sleep(1); snap("W5-dragged-to-back-wall")
        finishEdit(app)
        let back = value(board)
        XCTAssertTrue(back.contains("后墙"), "the drag took it to the back wall: \(back)")

        app.terminate()
        app = launch(reset: false, store: "wall-board")
        board = hotspot(app, named: "照片板")
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        XCTAssertEqual(value(board), back, "the edited wall placement survives a relaunch")

        // A room with a board still renders completely, so its postcard can be made.
        app.buttons["open-room-share"].tap()
        XCTAssertTrue(element(app, "room-postcard-ready").waitForExistence(timeout: 20))
        snap("W6-postcard-with-board")
    }

    /// Tap the projected scene position with a touch, as a sighted player would.
    private func openSceneChest(_ app: XCUIApplication) {
        let room = element(app, "room-world")
        let chest = app.buttons["room-storage"]
        XCTAssertTrue(chest.waitForExistence(timeout: 10))
        XCTAssertEqual(chest.label, "收纳箱")
        let center = CGPoint(x: chest.frame.midX, y: chest.frame.midY)
        XCTAssertTrue(room.frame.contains(center), "the chest is inside the rendered scene")
        room.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: center.x - room.frame.minX, dy: center.y - room.frame.minY)).tap()
        XCTAssertTrue(app.navigationBars["收纳箱"].waitForExistence(timeout: 5))
    }

    func testChestOpensTheEmptyStorageBox() {
        let app = launch(reset: true, store: "chest-empty")
        let chest = app.buttons["room-storage"]
        XCTAssertTrue(chest.waitForExistence(timeout: 10))
        snap("chest-overview")
        openSceneChest(app)
        XCTAssertTrue(element(app, "storage-empty").exists)
        app.buttons["close-furniture-list"].tap()
        let room = element(app, "room-world")
        XCTAssertTrue(chest.waitForExistence(timeout: 5))
        let overview = chest.frame
        room.pinch(withScale: 1.2, velocity: 1)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            chest.exists && hypot(chest.frame.midX - overview.midX, chest.frame.midY - overview.midY) > 2
        }, object: chest)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
        snap("chest-zoomed")
        openSceneChest(app)
        app.buttons["close-furniture-list"].tap()
        room.pinch(withScale: 0.5, velocity: -2)
        openSceneChest(app)
        XCTAssertTrue(element(app, "storage-empty").exists)
        XCTAssertFalse(app.buttons["add-furniture"].exists)
    }

    func testStowFromEditTrayTakesAFloorPieceOutOfTheRoom() {
        var app = launch(reset: true, store: "edit-stow")
        walkToPlacement(app, category: "sofa")
        app.buttons["confirm-placement"].tap()
        let sofa = hotspot(app, named: "沙发")
        XCTAssertTrue(sofa.waitForExistence(timeout: 10))
        sleep(1)

        sofa.press(forDuration: 1)
        XCTAssertTrue(element(app, "edit-tray").waitForExistence(timeout: 5))
        let stow = app.buttons["edit-stow"]
        XCTAssertTrue(stow.exists)
        XCTAssertTrue(app.buttons["edit-rotate"].exists, "a floor piece can still be turned")
        XCTAssertFalse(app.buttons["edit-switch-wall"].exists)
        XCTAssertTrue(app.staticTexts["虚线格是房间入口和猫咪上下家具的位置"].exists)
        for id in ["edit-rotate", "edit-stow", "edit-more", "edit-remove"] {
            XCTAssertTrue(app.buttons[id].isHittable, "\(id) is on screen")
        }
        sleep(1); snap("S1-edit-tray-with-stow")
        app.buttons["edit-rotate"].tap()
        snap("S1b-access-guide-after-rotation")
        stow.tap()

        // No question asked: edit mode ends and the sofa is out of the room.
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "edit-tray").exists)
        XCTAssertFalse(sofa.exists, "the sofa left the room")
        snap("S2-room-after-stow")
        app.terminate()
        app = launch(reset: false, store: "edit-stow")
        XCTAssertFalse(hotspot(app, named: "沙发").exists, "it stays put away after a relaunch")
        openSceneChest(app)
        let stored = app.buttons["list-stored-item"].firstMatch
        XCTAssertTrue(stored.waitForExistence(timeout: 5))
        stored.tap()
        XCTAssertTrue(element(app, "original-photo").waitForExistence(timeout: 10))
        app.buttons["restore-furniture"].tap()
        let confirm = app.buttons["confirm-placement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(hotspot(app, named: "沙发").waitForExistence(timeout: 10))
        openSceneChest(app)
        XCTAssertTrue(element(app, "storage-empty").exists)
    }

    func testAccessGuidesWhilePlacingCatalogFurniture() {
        let app = launch(reset: true, store: "catalog-floor-guides")
        app.buttons["place-furniture-first"].tap()
        app.buttons["manual-sofa"].tap()
        app.buttons["next-model"].tap()
        app.buttons["next-placement"].tap()
        let confirm = app.buttons["confirm-placement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        let outward = app.buttons["向外移一格"]
        XCTAssertTrue(confirm.isEnabled)
        // Allow RealityKit to present the first frame of the new editor before capturing its fill.
        sleep(5)
        snap("new-floor-access-valid")
        for _ in 0..<15 where confirm.isEnabled { outward.tap() }
        XCTAssertFalse(confirm.isEnabled)
        XCTAssertTrue(element(app, "placement-status").label.contains("门口这一格"))
        sleep(1)
        snap("new-floor-access-invalid")
    }
}
