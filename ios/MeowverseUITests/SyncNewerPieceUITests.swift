import XCTest

/// A device on an older version and a piece in a model only the newer one has. The "older
/// version" is this build syncing without the sofas (`-MeowverseSyncOlderCatalog`, DEBUG).
final class SyncNewerPieceUITests: XCTestCase {
    private let source = NSPredicate(format: "label CONTAINS %@", "查看照片")

    override func setUp() { continueAfterFailure = false }

    /// COMPAT-2: its place can't be sent from here, so the edit is refused and says why.
    func testAPieceFromANewerVersionIsNotPutAwayHere() {
        let folder = "newer" + UUID().uuidString.prefix(8)
        sendSofa(folder: folder)
        var app = launch("newer-old", reset: true, folder: folder)
        turnSyncOn(app)
        app.terminate()

        app = launch("newer-old", reset: false, folder: folder, older: true)
        let sofa = app.buttons.matching(source).firstMatch
        XCTAssertTrue(sofa.waitForExistence(timeout: 20), "the sofa it had stays")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        sofa.press(forDuration: 1)
        let stow = app.buttons["edit-stow"]
        XCTAssertTrue(stow.waitForExistence(timeout: 10))
        stow.tap()
        let why = app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "更新版本")).firstMatch
        XCTAssertTrue(why.waitForExistence(timeout: 10), "put away as if it would sync")
    }

    /// COMPAT-2 for a move to another room (QA, launch 1.0): it is a place edit too, so it is
    /// refused here with the same reason instead of seeming to work and never syncing.
    func testAPieceFromANewerVersionIsNotMovedToAnotherRoomHere() {
        let folder = "newer" + UUID().uuidString.prefix(8)
        sendSofa(folder: folder)
        var app = launch("newer-room", reset: true, folder: folder)
        turnSyncOn(app)
        app.terminate()

        app = launch("newer-room", reset: false, folder: folder, older: true, extra: ["-MeowverseSeveralHomes"])
        let sofa = app.buttons.matching(source).firstMatch
        XCTAssertTrue(sofa.waitForExistence(timeout: 20), "the sofa it had stays")
        app.buttons["room-switcher"].tap()
        app.buttons["new-room"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("书房")
        app.alerts.buttons["新建"].tap()
        XCTAssertTrue(app.showsRoom("书房", timeout: 10))

        app.buttons["furniture-list"].tap()
        let row = app.buttons.matching(identifier: "list-room-item").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.buttons["furniture-more"].waitForExistence(timeout: 10))
        app.buttons["furniture-more"].tap()
        app.buttons["搬到另一个房间"].tap()
        let study = app.buttons.matching(NSPredicate(format: "label == '书房' AND identifier != 'room-switcher'")).firstMatch
        XCTAssertTrue(study.waitForExistence(timeout: 5))
        study.tap()
        let why = app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "更新版本")).firstMatch
        XCTAssertTrue(why.waitForExistence(timeout: 10), "moved to another room as if it would sync")
    }

    /// JOURNEY-FAMILY-6: the photo of a piece this version can't show is not "on no furniture".
    func testPhotosOfAPieceFromANewerVersionAreNotUnfiled() {
        let folder = "newer" + UUID().uuidString.prefix(8)
        sendSofa(folder: folder)
        let app = launch("newer-fresh", reset: true, folder: folder, older: true)
        turnSyncOn(app)
        XCTAssertFalse(app.buttons.matching(source).firstMatch.exists, "this version can't show the sofa")
        app.buttons["photo-library"].tap()
        let photo = app.buttons["library-photo"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 20), "the photo arrived")
        XCTAssertFalse((photo.value as? String ?? "").contains("还没放进家具"), "\(String(describing: photo.value))")
        app.buttons["filter-unlinked"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "newer-piece-unfiled"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertFalse(app.buttons["library-photo"].exists, "shown as on no furniture")
    }

    // MARK: Steps

    private func sendSofa(folder: String) {
        let app = launch("newer-new", reset: true, folder: folder)
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.buttons["manual-sofa"].waitForExistence(timeout: 20))
        app.buttons["manual-sofa"].tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons.matching(source).firstMatch.waitForExistence(timeout: 15))
        turnSyncOn(app)
        app.terminate()
    }

    private func launch(_ store: String, reset: Bool, folder: String, older: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseSyntheticPhoto", "-MeowverseSyncFolder", folder]
            + (reset ? ["-MeowverseResetStore"] : []) + (older ? ["-MeowverseSyncOlderCatalog"] : []) + extra
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        return app
    }

    private func turnSyncOn(_ app: XCUIApplication) {
        app.tapSettingsGear()
        let row = app.descendants(matching: .any)["open-icloud-sync"].firstMatch
        _ = row.waitForExistence(timeout: 3)
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
        usleep(600_000)
        row.tap()
        let toggle = app.switches["icloud-sync-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["icloud-sync-consent-confirm"].waitForExistence(timeout: 5))
        app.buttons["icloud-sync-consent-confirm"].tap()
        let synced = NSPredicate(format: "label CONTAINS %@", "上次同步")
        let status = app.descendants(matching: .any)["icloud-sync-status"].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: synced, object: status)], timeout: 30), .completed)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["close-settings"].tap()
    }
}
