import XCTest

/// EXTENSIONS-3 and FEATURES-6: company and delivered notifications carry the cat's and the
/// furniture's names outside the app, so clearing all data ends both.
final class ClearAllCompanyUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testClearingAllDataEndsCompany() {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "clear-company", "-MeowverseResetStore",
                                                      "-MeowverseDeliveredDrill"]
        app.launch()
        openCompany(app)
        let start = app.buttons["pocket-start"], end = app.buttons["pocket-end"]
        if end.waitForExistence(timeout: 2) {
            end.tap()
            XCTAssertTrue(start.waitForExistence(timeout: 10))
        }
        start.tap()
        XCTAssertTrue(end.waitForExistence(timeout: 10), "company didn't start")
        app.terminate()

        app.launchArguments.removeAll { $0 == "-MeowverseResetStore" }
        app.launch()
        clearAll(app)
        app.terminate()

        app.launch()
        openCompany(app)
        XCTAssertTrue(start.waitForExistence(timeout: 10) && !end.exists, "company still runs with the cleared cat's name")
    }

    func testClearingAllDataEmptiesNotificationCenter() throws {
        try drillFile("delivered-after-", remove: true)
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "clear-company", "-MeowverseResetStore",
                                                      "-MeowverseDeliveredDrill"]
        app.launch()
        clearAll(app)
        var left = ""
        let deadline = Date().addingTimeInterval(20)
        while left.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            left = try drillFile("delivered-after-")
        }
        XCTAssertNotEqual(try drillFile("delivered-before-"), "0", "nothing was delivered, so nothing was tested")
        XCTAssertEqual(left, "0", "Notification Center keeps what was delivered before clearing")
    }

    @discardableResult
    private func drillFile(_ name: String, remove: Bool = false) throws -> String {
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        for app in try FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil) {
            let file = app.appending(path: "Library/Caches/Meowverse/" + name + "Test-clear-company")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if remove { try FileManager.default.removeItem(at: file) }
            return text
        }
        return ""
    }

    private func clearAll(_ app: XCUIApplication) {
        app.tapSettingsGear()
        let clear = app.descendants(matching: .any)["clear-all"].firstMatch
        _ = clear.waitForExistence(timeout: 3)
        for _ in 0..<8 where !(clear.exists && clear.isHittable) { app.swipeUp(velocity: .slow) }
        usleep(600_000)
        clear.tap()
        let proceed = app.buttons["clear-all-continue"].firstMatch
        XCTAssertTrue(proceed.waitForExistence(timeout: 5))
        proceed.tap()
        let confirm = app.alerts.buttons["全部清除"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let notice = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "已清除全部数据")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "didn't clear")
    }

    private func openCompany(_ app: XCUIApplication) {
        let interactions = app.buttons["choose-interaction"]
        XCTAssertTrue(interactions.waitForExistence(timeout: 30))
        interactions.tap()
        app.buttons["choose-pocket-cat"].tap()
    }
}
