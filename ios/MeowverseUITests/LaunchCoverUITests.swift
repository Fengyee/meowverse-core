import XCTest

/// The launch cover hides the room while it loads, then lifts by itself (owner request,
/// 2026-11-20: furniture should not pop in one piece at a time at launch).
final class LaunchCoverUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// An empty room loads before XCUITest's first look, so the test reads what lifted the
    /// cover: the room reporting ready, not the 4 s limit.
    func testCoverLiftsWhenTheRoomIsReady() {
        let app = XCUIApplication()
        app.launchArguments = ["-MeowverseStore", "LaunchCover", "-MeowverseResetStore", "-MeowverseSkipReminderSetup", "-MeowverseLaunchCover"]
        app.launch()
        let probe = app.descendants(matching: .any)["launch-cover-probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 12), "the cover never lifted")
        XCTAssertEqual(probe.label, "ready")
        XCTAssertFalse(app.descendants(matching: .any)["launch-cover"].exists)
        // The cover fades for under half a second; then the room takes taps.
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"),
                                                 object: app.buttons["room-switcher"])
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 3), .completed, "the room is not usable after the cover")
    }

    func testTestLaunchesSkipTheCover() {
        let app = XCUIApplication()
        app.launchArguments = ["-MeowverseStore", "LaunchCover", "-MeowverseResetStore", "-MeowverseSkipReminderSetup"]
        app.launch()
        XCTAssertTrue(app.buttons["room-switcher"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["launch-cover"].exists)
    }
}
