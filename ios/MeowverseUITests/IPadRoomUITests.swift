import UIKit
import XCTest

final class IPadRoomUITests: XCTestCase {
    func testSwitchingRoomsClearsInspectorAndZoomAndLocatesFurnitureAcrossRooms() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        continueAfterFailure = false
        let device = XCUIDevice.shared
        device.orientation = .landscapeLeft
        defer { device.orientation = .portrait }

        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "ipad-room-switch",
                                                      "-MeowverseResetStore", "-MeowverseSyntheticPhoto", "-MeowverseSeveralHomes"]
        app.launch()
        let switcher = app.buttons["room-switcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 20))
        let home = switcher.label
        for id in ["add-synthetic", "manual-sofa", "next-model", "next-placement", "confirm-placement"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 15), id)
            button.tap()
        }
        let sofa = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查看照片")).firstMatch
        XCTAssertTrue(sofa.waitForExistence(timeout: 10))
        let receipt = app.descendants(matching: .any)["photo-storage-receipt"].firstMatch
        XCTAssertTrue(receipt.waitForNonExistence(timeout: 20))
        let footprint = sofa.frame.width
        sofa.pinch(withScale: 2, velocity: 2)
        XCTAssertGreaterThan(sofa.frame.width, footprint * 1.2)
        sofa.tap()
        let original = app.images["original-photo"].firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 15))

        switcher.tap()
        app.buttons["new-room"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Study")
        app.alerts.buttons["新建"].tap()
        XCTAssertTrue(app.showsRoom("Study", timeout: 10))
        XCTAssertTrue(app.buttons["place-furniture-first"].isHittable)
        XCTAssertFalse(original.exists)
        XCTAssertFalse(sofa.exists)

        app.buttons["furniture-list"].tap()
        app.buttons.matching(identifier: "piece-menu").firstMatch.tap()
        app.buttons["在房间里定位"].tap()
        XCTAssertTrue(app.showsRoom(home, timeout: 12))
        XCTAssertTrue(sofa.waitForExistence(timeout: 10))
        XCTAssertEqual(sofa.frame.width, footprint, accuracy: 3)
        XCTAssertFalse(original.exists)
    }

    func testPlacementAndPhotoInspectorFollowWindowWidth() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        continueAfterFailure = false
        let device = XCUIDevice.shared
        device.orientation = .landscapeLeft
        defer { device.orientation = .portrait }

        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "ipad-adaptive-room",
                                                       "-MeowverseResetStore", "-MeowverseSyntheticPhoto"]
        app.launch()
        for id in ["add-synthetic", "manual-sofa", "next-model", "next-placement"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 20), id)
            button.tap()
        }

        let preview = app.descendants(matching: .any)["placement-preview"].firstMatch
        let confirm = app.buttons["confirm-placement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(preview.frame.maxX, confirm.frame.minX)
        app.buttons["转四分之一圈"].tap()
        device.orientation = .portrait
        // The compact editor replaces the landscape controls after UIKit's rotation transition.
        let compactEditor = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width < app.frame.height && confirm.isHittable && confirm.frame.width > app.frame.width * 0.8
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [compactEditor], timeout: 8), .completed)
        confirm.tap()

        device.orientation = .landscapeLeft
        let sofa = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查看照片")).firstMatch
        XCTAssertTrue(sofa.waitForExistence(timeout: 10))
        XCTAssertTrue((sofa.value as? String)?.contains("转了 1 次") == true)
        sofa.tap()
        let room = app.descendants(matching: .any)["room-world"].firstMatch
        let original = app.images["original-photo"].firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 15))
        XCTAssertLessThanOrEqual(room.frame.maxX, original.frame.minX + 1)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "ipad-room-with-furniture-photo"
        shot.lifetime = .keepAlways
        add(shot)

        // The import receipt temporarily reduces the room's viewport. Compare the camera at the same size.
        let receipt = app.descendants(matching: .any)["photo-storage-receipt"].firstMatch
        XCTAssertTrue(receipt.waitForNonExistence(timeout: 20))
        let beforePhotoZoom = sofa.frame.width
        device.orientation = .portrait
        original.pinch(withScale: 2.5, velocity: 2)
        device.orientation = .landscapeLeft
        XCTAssertEqual(sofa.frame.width, beforePhotoZoom, accuracy: 3)
        app.buttons["photo-details"].tap()
        XCTAssertTrue(app.navigationBars["照片"].waitForExistence(timeout: 10))
        let date = app.descendants(matching: .any)["photo-date-line"].firstMatch
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        XCTAssertTrue(date.label.contains("2026年3月14日"))
        let photoList = app.collectionViews.firstMatch
        let favorite = app.switches["favorite-toggle"].firstMatch
        // SwiftUI's List creates the favorite row when the photo detail scrolls into that section.
        for _ in 0..<4 where !favorite.exists || !favorite.isHittable { photoList.swipeUp(velocity: .slow) }
        XCTAssertTrue(favorite.isHittable)
        favorite.coordinate(withNormalizedOffset: CGVector(dx: 0.91, dy: 0.5)).tap()
        XCTAssertEqual(favorite.value as? String, "1")
        device.orientation = .portrait
        XCTAssertTrue(favorite.exists)
        XCTAssertFalse(sofa.exists && sofa.isHittable)
        XCTAssertGreaterThan(favorite.frame.width, app.frame.width * 0.65)
        device.orientation = .landscapeLeft
        XCTAssertTrue(favorite.exists)
        XCTAssertEqual(favorite.value as? String, "1")
        XCTAssertTrue(room.exists)

        let interaction = app.buttons["choose-interaction"]
        interaction.tap()
        let toy = app.buttons["choose-toy"]
        XCTAssertTrue(toy.waitForExistence(timeout: 10))
        sofa.tap()
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        XCTAssertFalse(toy.exists)
        interaction.tap()
        XCTAssertTrue(toy.waitForExistence(timeout: 10))
        app.buttons["取消"].tap()
        XCTAssertFalse(original.exists)
        XCTAssertGreaterThan(room.frame.width, app.frame.width * 0.9)

        let footprint = sofa.frame.width
        sofa.pinch(withScale: 2, velocity: 2)
        XCTAssertGreaterThan(sofa.frame.width, footprint * 1.2)
        room.pinch(withScale: 0.2, velocity: -2)
        XCTAssertEqual(sofa.frame.width, footprint, accuracy: 3)
        sofa.press(forDuration: 0.8)
        let tray = app.descendants(matching: .any)["edit-tray"].firstMatch
        XCTAssertTrue(tray.waitForExistence(timeout: 10))
        let surface = app.descendants(matching: .any)["edit-surface"].firstMatch
        let layoutShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        layoutShot.name = "ipad-furniture-edit-controls"
        layoutShot.lifetime = .keepAlways
        add(layoutShot)
        XCTAssertLessThanOrEqual(surface.frame.maxX, tray.frame.minX + 1)
        app.buttons["edit-cancel"].tap()
        app.buttons["open-room-share"].tap()
        let postcard = app.descendants(matching: .any)["room-postcard-ready"].firstMatch
        XCTAssertTrue(postcard.waitForExistence(timeout: 20))
    }
}
