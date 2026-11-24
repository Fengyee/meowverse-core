import XCTest

/// "None" is said only by a comparison that finished. One that couldn't finish says so and can be
/// asked again; and photos kept in the library keep their prints long enough to be compared.
final class SuggestionHonestyUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testKeptPhotosAreOfferedFromTheLibraryAfterARelaunch() {
        let app = relaunchWithKeptPhotos(store: "honest-offers", failing: false)
        openUnfiled(app)
        app.buttons["rerun-suggestions"].tap()
        XCTAssertTrue(app.navigationBars["按建议放进家具"].waitForExistence(timeout: 30), "look-alike photos were not offered")
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'suggestion-photo-'"))
        XCTAssertEqual(tiles.count, 3)
    }

    func testAFailedRerunDoesNotSayNoneWereFound() {
        let app = relaunchWithKeptPhotos(store: "honest-rerun", failing: true)
        openUnfiled(app)
        let rerun = app.buttons["rerun-suggestions"]
        rerun.tap()
        XCTAssertTrue(text(app, "没能完成比对").waitForExistence(timeout: 30), "the failure is not said")
        XCTAssertFalse(text(app, "没有找到").exists, "a failed comparison said none were found")
        XCTAssertTrue(rerun.waitForExistence(timeout: 5), "it can be asked again")
    }

    func testAFailedComparisonDoesNotShowNoneOnTheStrip() {
        let app = relaunchWithKeptPhotos(store: "honest-strip", failing: true)
        openUnfiled(app)
        app.buttons["sort-unlinked"].tap()
        let strip = app.buttons["filing-suggestions-entry"]
        XCTAssertTrue(strip.waitForExistence(timeout: 30), "the strip is shown while comparing")
        let end = Date().addingTimeInterval(20)
        while Date() < end, strip.label.contains("还在比对") { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "strip-failed"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(strip.label.contains("没能完成比对"), strip.label)
        XCTAssertFalse(strip.label.contains("暂无"), strip.label)
    }

    // MARK: Steps

    /// A sofa with two photos, three look-alikes kept in the library, then a new launch.
    private func relaunchWithKeptPhotos(store: String, failing: Bool) -> XCUIApplication {
        var app = launch(store, ["-MeowverseResetStore"])
        app.buttons["add-synthetic"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 20))
        sofa.tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        let piece = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查看照片")).firstMatch
        XCTAssertTrue(piece.waitForExistence(timeout: 15))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        piece.tap()
        XCTAssertTrue(app.buttons["furniture-more"].waitForExistence(timeout: 10))
        app.buttons["furniture-more"].tap()
        let another = app.buttons["再添一张合成照片"]
        XCTAssertTrue(another.waitForExistence(timeout: 5))
        another.tap()
        let album = app.descendants(matching: .any).matching(identifier: "furniture-album").firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 20))
        app.buttons["close-detail"].tap()

        app.addSyntheticBatch()
        let start = app.buttons["start-sorting"]
        XCTAssertTrue(start.waitForExistence(timeout: 60))
        start.tap()
        for number in 1...3 {
            XCTAssertTrue(app.navigationBars["整理照片 \(number) / 3"].waitForExistence(timeout: 20))
            let keep = app.buttons["keep-in-library"]
            XCTAssertTrue(keep.waitForExistence(timeout: 20))
            for _ in 0..<5 where !keep.isHittable { app.swipeUp(velocity: .slow) }
            keep.tap()
        }
        XCTAssertTrue(app.buttons["photo-library"].waitForExistence(timeout: 20))
        app.terminate()

        app = launch(store, failing ? ["-MeowverseFailPrints"] : [])
        return app
    }

    private func launch(_ store: String, _ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseSyntheticPhoto",
                                                      "-MeowverseColorGridSimilarity"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        return app
    }

    private func openUnfiled(_ app: XCUIApplication) {
        app.buttons["photo-library"].tap()
        XCTAssertTrue(app.buttons["filter-unlinked"].waitForExistence(timeout: 10))
        app.buttons["filter-unlinked"].tap()
        XCTAssertTrue(app.buttons["rerun-suggestions"].waitForExistence(timeout: 10))
    }

    private func text(_ app: XCUIApplication, _ part: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
    }
}
