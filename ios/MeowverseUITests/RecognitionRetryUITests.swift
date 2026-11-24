import XCTest

/// A photo whose print cannot be made once kept recognition starting over: the bar flickered
/// over 整理 and the photo was read without end. `-MeowverseFailPrints` makes every print fail
/// and counts the attempts.
final class RecognitionRetryUITests: XCTestCase {
    private let store = "print-retry"

    override func setUp() { continueAfterFailure = false }

    func testFailedPrintsAreTriedOnceAndSortingOpens() throws {
        let app = launch(reset: true)
        app.addSyntheticBatch()
        RunLoop.current.run(until: Date().addingTimeInterval(10))
        let after = try attempts()
        XCTAssertGreaterThan(after, 0, "the failing stand-in was never asked")
        XCTAssertLessThanOrEqual(after, 3, "three photos, one attempt each")

        let start = app.buttons["start-sorting"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), "整理 never came")
        XCTAssertTrue(start.isHittable, "整理 cannot be tapped")
        start.tap()
        XCTAssertTrue(app.buttons["keep-in-library"].waitForExistence(timeout: 20), "整理 did not open the review")
        XCTAssertEqual(try attempts(), after, "opening the review started recognition again")
    }

    func testANewLaunchAndANewImportTryAgain() throws {
        var app = launch(reset: true)
        app.addSyntheticBatch()
        XCTAssertTrue(app.buttons["start-sorting"].waitForExistence(timeout: 30))
        app.terminate()

        app = launch(reset: false)
        XCTAssertTrue(app.buttons["start-sorting"].waitForExistence(timeout: 30))
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(try attempts(), 3, "a launch tries each waiting photo once")
        app.addSyntheticBatch()
        RunLoop.current.run(until: Date().addingTimeInterval(10))
        XCTAssertEqual(try attempts(), 6, "a new import tries each once more")
    }

    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseSyntheticPhoto",
                                                      "-MeowverseColorGridSimilarity", "-MeowverseFailPrints"]
            + (reset ? ["-MeowverseResetStore"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        return app
    }

    /// The app's own count, found from the runner: both containers are in the same folder on the simulator.
    private func attempts() throws -> Int {
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil)
            .map { $0.appending(path: "Library/Caches/Meowverse/print-attempts-Test-" + store) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertEqual(files.count, 1, "one app writes the count")
        return try XCTUnwrap(Int(String(contentsOf: XCTUnwrap(files.first), encoding: .utf8)))
    }
}
