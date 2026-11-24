import XCTest

/// 1.0 ships without Talk to Bella (launch design §2): the default build has no head in the room,
/// no news item about it, and the News button's hint promises only what the panel shows. The
/// binary side (no Speech or Foundation Models, no usage descriptions) is `ios/check-voice-build.py`.
/// A `MEOWVERSE_TALK_TO_BELLA=YES` build runs `TalkToBellaUITests` instead
/// (`TEST_RUNNER_MV_TALK_TO_BELLA=1`), and these skip.
final class VoiceOffUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(ProcessInfo.processInfo.environment["MV_TALK_TO_BELLA"] == "1", "a build with Talk to Bella")
    }

    private func launch(_ store: String, _ language: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = language + ["-MeowverseStore", "voice-off-" + store, "-MeowverseResetStore"]
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 60))
        return app
    }

    func testTheRoomHasNoHead() {
        let app = launch("room", TestLanguage.chinese)
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["talk-to-bella"].exists, "no Talk to Bella head")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "voice-off-room"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The button's hint (`News.hint`) is not in XCUITest's tree: it is checked by reading only.
    func testNewsDoesNotListTheVoice() {
        for (language, talk) in [(TestLanguage.chinese, "和猫咪说话"), (TestLanguage.english, "Talk to your cat")] {
            let app = launch(language == TestLanguage.chinese ? "news-zh" : "news-en", language)
            let news = app.buttons["open-room-news"]
            XCTAssertTrue(news.waitForExistence(timeout: 25))
            news.tap()
            XCTAssertTrue(app.descendants(matching: .any)["room-news-panel"].waitForExistence(timeout: 15))
            let item = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", talk)).firstMatch
            XCTAssertFalse(item.exists, "no news item about talking to the cat")
            app.terminate()
        }
    }
}
