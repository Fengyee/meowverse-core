import XCTest

/// Draft App Store screenshots, one run per language. Skipped unless the runner gets
/// MEOWVERSE_STORE_SHOTS=1 (`./store-shots.sh` passes TEST_RUNNER_MEOWVERSE_STORE_SHOTS=1).
///
/// The room is built with the drawn synthetic photo and catalog pieces only. Every shot except
/// the review step is taken after a relaunch without `-MeowverseSyntheticPhoto`, so no test
/// buttons are on screen; the review step itself shows none.
final class StoreScreenshotsUITests: XCTestCase {
    private struct Language {
        let arguments: [String]
        let folder: String
        let loafing: String
        let playing: String
        let sofa: String
        let blue: String
    }

    private let chinese = Language(arguments: TestLanguage.chinese, folder: "zh-Hans",
                                   loafing: "窝着", playing: "正在玩", sofa: "云朵贵妃沙发", blue: "雾蓝")
    private let english = Language(arguments: TestLanguage.english, folder: "en-US",
                                   loafing: "loafing", playing: "playing with", sofa: "Cloud chaise sofa", blue: "Mist")

    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MEOWVERSE_STORE_SHOTS"] == "1", "store screenshots only")
    }

    func testChineseStoreShots() { shoot(chinese) }
    func testEnglishStoreShots() { shoot(english) }

    // MARK: Helpers

    private func launch(_ language: Language, synthetic: Bool, reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = language.arguments + ["-MeowverseStore", "store-shots-" + language.folder]
        if synthetic { app.launchArguments.append("-MeowverseSyntheticPhoto") }
        if reset { app.launchArguments.append("-MeowverseResetStore") }
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 20))
        return app
    }

    private func snap(_ language: Language, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = language.folder + "-" + name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func tap(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[id].firstMatch
        // Rows below the fold of a list may not exist until scrolled to.
        if !button.waitForExistence(timeout: 10) { for _ in 0..<6 where !button.exists { app.swipeUp() } }
        XCTAssertTrue(button.waitForExistence(timeout: 5), id, file: file, line: line)
        for _ in 0..<6 where !button.isHittable { app.swipeUp() }
        button.tap()
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func waitForCaption(_ app: XCUIApplication, containing word: String, timeout: TimeInterval = 45) {
        let caption = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "bella-caption", word)).firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: timeout), "caption with “\(word)”")
    }

    /// Picks a model in the open add-furniture flow and confirms it at the suggested spot.
    private func choose(_ app: XCUIApplication, model: String, finish: String? = nil) -> String {
        tap(app, "next-model")
        tap(app, "model-" + model)
        XCTAssertTrue(element(app, "model-preview-ready").waitForExistence(timeout: 20))
        tap(app, "next-placement")
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        if let finish {
            let swatch = app.buttons.matching(NSPredicate(format: "label == %@", finish)).firstMatch
            XCTAssertTrue(swatch.waitForExistence(timeout: 5), finish)
            for _ in 0..<4 where !swatch.isHittable { app.swipeUp() }
            swatch.tap()
            sleep(1)
        }
        let name = app.textFields.firstMatch.value as? String ?? ""
        tap(app, "confirm-placement")
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 15))
        return name
    }

    private func addFromCatalog(_ app: XCUIApplication, category: String, model: String) {
        tap(app, "furniture-list")
        tap(app, "add-furniture")
        tap(app, "manual-" + category)
        _ = choose(app, model: model)
    }

    // MARK: The shots

    private func shoot(_ language: Language) {
        // Build the room: a sofa from the drawn photo, then catalog pieces with no photo.
        var app = launch(language, synthetic: true, reset: true)
        tap(app, "add-synthetic")
        tap(app, "manual-sofa")
        sleep(1)
        snap(language, "2-photo-review")
        // The v2 models (mv-furniture.catalog.json) that replaced the legacy ids these shots
        // used; the pickers no longer offer the legacy ids. The sofa's `seat` site still offers loaf.
        _ = choose(app, model: "mv-sofa-c", finish: language.blue) // like the photo
        addFromCatalog(app, category: "catTree", model: "mv-cat-tree-a")
        addFromCatalog(app, category: "water", model: "mv-water-b")
        addFromCatalog(app, category: "bed", model: "mv-bed-c")
        app.terminate()

        // Relaunch without the synthetic-photo switch: no test buttons from here on.
        app = launch(language, synthetic: false, reset: false)
        XCTAssertFalse(app.buttons["add-synthetic"].exists)

        // 1. Bella loafing on the sofa: whole room (alternate) and close-up.
        tap(app, "choose-interaction")
        let row = app.buttons.matching(NSPredicate(format: "label == %@", language.sofa)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "sofa row “\(language.sofa)”")
        row.tap()
        tap(app, "invite-seat-loaf")
        waitForCaption(app, containing: language.loafing)
        sleep(3)
        snap(language, "alt-1-room-whole")
        app.descendants(matching: .any)["room-world"].pinch(withScale: 1.8, velocity: 2)
        sleep(3)
        snap(language, "1-room")
        app.descendants(matching: .any)["room-world"].pinch(withScale: 0.25, velocity: -2)
        sleep(2)

        // 3. The sofa's page with the photo it came from.
        // From the list: in the room a nearer piece's hotspot can cover the sofa's.
        tap(app, "furniture-list")
        let listRow = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                                                       "list-room-item", language.sofa)).firstMatch
        XCTAssertTrue(listRow.waitForExistence(timeout: 10))
        listRow.tap()
        XCTAssertTrue(element(app, "original-photo").waitForExistence(timeout: 10))
        sleep(2)
        snap(language, "3-furniture-photo")
        tap(app, "close-detail")
        if app.buttons["close-furniture-list"].waitForExistence(timeout: 3) { app.buttons["close-furniture-list"].tap() }

        // 4. Play: the interaction sheet, then Bella chasing a feather wand (whole room and close-up).
        tap(app, "choose-interaction")
        XCTAssertTrue(app.buttons["choose-toy"].waitForExistence(timeout: 10))
        sleep(1)
        snap(language, "alt-4-interaction-sheet")
        tap(app, "choose-toy")
        tap(app, "play-item-featherWand")
        tap(app, "place-play-item")
        waitForCaption(app, containing: language.playing)
        sleep(3)
        snap(language, "alt-4-play-whole")
        app.descendants(matching: .any)["room-world"].pinch(withScale: 1.8, velocity: 2)
        sleep(3)
        snap(language, "4-play")
        tap(app, "end-play")

        // 5. About and privacy; the 3D cat model as an alternate (from 猫咪管理).
        app.openCatManager()
        let inspect = app.buttons["open-cat-inspect"]
        for _ in 0..<6 where !inspect.isHittable { app.swipeUp(velocity: .slow) }
        tap(app, "open-cat-inspect")
        XCTAssertTrue(element(app, "cat-inspect-model").waitForExistence(timeout: 30))
        sleep(3)
        snap(language, "alt-5-cat-model")
        tap(app, "close-cat-inspect")
        tap(app, "close-home")
        tap(app, "open-settings")
        tap(app, "open-about")
        sleep(1)
        snap(language, "5-privacy")
    }
}
