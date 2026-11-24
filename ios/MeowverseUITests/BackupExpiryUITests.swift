import XCTest

/// STAB-2: when the background time runs out the handler itself ends the task, or the system
/// ends the app. `-MeowverseBackupExpiryDrill` runs the handler as soon as a backup starts and
/// writes whether the task was still live afterwards.
final class BackupExpiryUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testTheExpiryHandlerEndsTheBackgroundTask() throws {
        let store = "backup-expiry"
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseResetStore", "-MeowverseSyntheticPhoto",
                                                      "-MeowverseCloudFolder", "backup-expiry", "-MeowverseBackupExpiryDrill"]
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.buttons["photo-only"].waitForExistence(timeout: 20))
        app.buttons["photo-only"].tap()
        XCTAssertTrue(app.buttons["close-library"].waitForExistence(timeout: 10))
        app.buttons["close-library"].tap()

        app.tapSettingsGear()
        let open = app.descendants(matching: .any)["open-icloud-backup"].firstMatch
        _ = open.waitForExistence(timeout: 5)
        for _ in 0..<6 where !(open.exists && open.isHittable) { app.swipeUp(velocity: .slow) }
        open.tap()
        let toggle = app.switches["icloud-backup-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["icloud-consent-confirm"].waitForExistence(timeout: 5))
        app.buttons["icloud-consent-confirm"].tap()
        let now = app.buttons["icloud-backup-now"]
        XCTAssertTrue(now.waitForExistence(timeout: 10))
        now.tap()
        XCTAssertEqual(try drillResult(store), "ended", "the handler left the task to the cancelled work")

        // The work that was cancelled ends once more by itself: harmless, and it says so.
        let notice = app.descendants(matching: .any)["icloud-backup-notice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 20))
        XCTAssertTrue(notice.label.contains("已取消"), notice.label)
    }

    /// Both containers are in the same folder on the simulator.
    private func drillResult(_ store: String) throws -> String {
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let end = Date().addingTimeInterval(15)
        while Date() < end {
            for app in try FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil) {
                let file = app.appending(path: "Library/Caches/Meowverse/backup-expiry-Test-" + store)
                if let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty {
                    try? FileManager.default.removeItem(at: file)
                    return text
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        return "no result"
    }
}
