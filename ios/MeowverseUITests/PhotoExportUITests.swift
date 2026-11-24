import XCTest

final class PhotoExportUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ store: String, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseResetStore", "-MeowverseSyntheticPhoto"]
        if large { app.launchArguments.append("-MeowverseLargeSyntheticPhoto") }
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        return app
    }

    private func save(_ app: XCUIApplication, count: Int) {
        app.buttons["confirm-photo-export"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = springboard.alerts.firstMatch
        if permission.waitForExistence(timeout: 3) {
            let allow = permission.buttons.matching(NSPredicate(format: "label IN %@",
                ["Allow", "Allow Access", "允许", "允许访问", "好", "OK"])).firstMatch
            if allow.exists { allow.tap() }
        }
        let result = app.staticTexts["export-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        XCTAssertEqual(result.label, "已保存到系统相册：\(count) 张。")
        app.buttons["close-photo-export"].tap()
    }

    private func openSaveFromDetail(_ app: XCUIApplication) {
        let saveButton = app.buttons["save-photo-to-photos"]
        for _ in 0..<4 where !saveButton.isHittable { app.swipeUp() }
        saveButton.tap()
    }

    func testSingleReducedCopyShowsWarningAndSavesToPhotos() throws {
        let app = launch("export-single-copy", large: true)
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.buttons["photo-only"].waitForExistence(timeout: 20))
        app.buttons["photo-only"].tap()
        let receipt = app.staticTexts["photo-storage-receipt"].firstMatch
        XCTAssertTrue(receipt.waitForExistence(timeout: 10))
        XCTAssertTrue(receipt.label.contains("已保存缩小副本"))
        app.buttons["library-photo"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["photo-storage-status"].label.contains("缩小副本"))
        openSaveFromDetail(app)
        XCTAssertTrue(app.staticTexts["export-copy-warning"].waitForExistence(timeout: 10))
        save(app, count: 1)
        app.buttons["share-photo-file"].tap()
        XCTAssertTrue(app.staticTexts["export-copy-warning"].waitForExistence(timeout: 10))
        app.buttons["close-photo-export"].tap()
        app.buttons["share-photo"].tap()
        XCTAssertTrue(app.staticTexts["export-copy-warning"].waitForExistence(timeout: 10))
        app.buttons["confirm-photo-export"].tap()
        let activities = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label IN %@", "ActivityListView",
            ["Copy", "拷贝", "Save Image", "存储图像", "Save to Files", "存储到“文件”"])).firstMatch
        XCTAssertTrue(activities.waitForExistence(timeout: 10))
    }

    func testReducedCopyUsesTheEditedCaptureDay() {
        let app = launch("export-edited-copy-day", large: true)
        app.buttons["add-synthetic"].tap()
        let photoOnly = app.buttons["photo-only"]
        XCTAssertTrue(photoOnly.waitForExistence(timeout: 20))
        photoOnly.tap()
        let cell = app.buttons["library-photo"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        cell.tap()
        app.buttons["edit-date"].tap()
        let day = app.datePickers.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "3月10日")).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 6))
        day.tap()
        app.buttons["save-date"].tap()
        XCTAssertTrue(app.staticTexts["photo-date-line"].label.contains("2026年3月10日"))
        openSaveFromDetail(app)
        XCTAssertTrue(app.staticTexts["export-copy-warning"].waitForExistence(timeout: 10))
        // An ordinary day: the note names noon and only the cases this copy meets.
        let note = app.staticTexts["export-copy-date-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertEqual(note.label, "缩小副本沿用你在这里看到的拍摄日期。只有日期时，系统相册用当地中午 12 点排列。")
        save(app, count: 1)
    }

    #if !targetEnvironment(simulator)
    /// Set MEOWVERSE_VERIFY_WECHAT=1 in the test runner environment on a device with WeChat installed.
    /// This checks the system Apps list. Verify the recipient picker separately on the device.
    func testCompatibleShareListsInstalledWeChatInSystemApps() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MEOWVERSE_VERIFY_WECHAT"] == "1",
                          "Enable MEOWVERSE_VERIFY_WECHAT for the dedicated installed-device check.")
        let app = launch("export-wechat", large: true)
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.buttons["photo-only"].waitForExistence(timeout: 20))
        app.buttons["photo-only"].tap()
        app.buttons["library-photo"].firstMatch.tap()
        app.buttons["share-photo"].tap()
        app.buttons["confirm-photo-export"].tap()

        func named(_ labels: [String]) -> XCUIElementQuery {
            app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", labels))
        }
        let anchor = named(["AirDrop", "隔空投送", "Messages", "信息", "Mail", "邮件"]).firstMatch
        XCTAssertTrue(anchor.waitForExistence(timeout: 12))
        let bounds = app.frame
        let row = anchor.frame.midY
        let appsTitle = named(["Apps", "App", "应用", "应用程序"]).firstMatch
        for _ in 0..<5 {
            let more = named(["More", "更多", "More Apps", "更多 App"]).allElementsBoundByIndex.first { item in
                let frame = item.frame
                return frame.width > 0 && frame.height > 0 && abs(frame.midY - row) < 46 &&
                    bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
            }
            if let more { more.tap(); break }
            let y = (row - bounds.minY) / bounds.height
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.87, dy: y)).press(forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.13, dy: y)))
        }
        XCTAssertTrue(appsTitle.waitForExistence(timeout: 6), "The full system list of sharing apps should open.")
        let weChat = named(["微信", "WeChat", "Weixin"])
        for _ in 0..<6 {
            if weChat.allElementsBoundByIndex.contains(where: { item in
                let frame = item.frame
                return frame.width > 0 && frame.height > 0 && frame.midY > appsTitle.frame.maxY &&
                    bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
            }) { return }
            app.swipeUp(velocity: .slow)
        }
        XCTFail("WeChat must be available in the full system Apps list for this installed-device test.")
    }
    #endif

    func testSaveMultipleFullOriginals() {
        let app = launch("export-multiple")
        app.addSyntheticBatch()
        let receipt = app.staticTexts["photo-storage-receipt"].firstMatch
        XCTAssertTrue(receipt.waitForExistence(timeout: 30))
        XCTAssertTrue(receipt.label.contains("已保存完整原件：3 张"))
        app.buttons["photo-library"].tap()
        app.buttons["select-photos"].tap()
        app.buttons["select-all-photos"].tap()
        app.buttons["batch-export"].tap()
        app.buttons["保存到系统相册"].tap()
        XCTAssertTrue(app.buttons["confirm-photo-export"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["export-copy-warning"].exists)
        save(app, count: 3)
    }
}
