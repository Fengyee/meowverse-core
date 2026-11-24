import XCTest

/// The interface language every UI test launches in. The other test classes match Chinese
/// labels, so they pin Chinese whatever the simulator's own language is.
enum TestLanguage {
    static let chinese = ["-MeowverseSkipReminderSetup", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    static let english = ["-MeowverseSkipReminderSetup", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
}

/// The English interface: the main surfaces show no Chinese text, built-in names come out in
/// English, dates follow the locale, and names are stored so that switching back to Chinese
/// shows an untouched default name in Chinese and the user's own name as typed.
final class LocalizationUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func launch(_ language: [String], reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = language + ["-MeowverseStore", "localization", "-MeowverseSyntheticPhoto"]
        if reset { app.launchArguments.append("-MeowverseResetStore") }
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 20))
        return app
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "en-" + name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Every line of the accessibility tree with Chinese characters or full-width punctuation.
    /// The tree covers what is on screen and what VoiceOver reads, labels and values alike.
    private func chineseLines(_ app: XCUIApplication) -> [String] {
        app.debugDescription.split(separator: "\n").map(String.init).filter { line in
            line.unicodeScalars.contains { scalar in
                (0x3400...0x9FFF).contains(scalar.value) || (0x3000...0x303F).contains(scalar.value)
                    || (0xFF00...0xFFEF).contains(scalar.value)
            }
        }
    }

    /// Screenshot first, so a failure still leaves the picture to look at.
    private func check(_ app: XCUIApplication, _ surface: String, file: StaticString = #filePath, line: UInt = #line) {
        sleep(1)
        snap(surface)
        let found = chineseLines(app)
        XCTAssertTrue(found.isEmpty, "\(surface) shows Chinese text:\n" + found.joined(separator: "\n"), file: file, line: line)
    }

    private func tap(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[id].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), id, file: file, line: line)
        for _ in 0..<6 where !button.isHittable { app.swipeUp() }
        button.tap()
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// A phone in a language we have no translation for (Japanese here) gets English, not
    /// Chinese: English is the development region (owner decision, 2026-11-12).
    func testAnUnsupportedLanguageFallsBackToEnglish() {
        let app = launch(["-MeowverseSkipReminderSetup", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"], reset: true)
        check(app, "fallback-ja-room")
    }

    private func openMenuItem(_ app: XCUIApplication, _ id: String) {
        tap(app, id)
    }

    func testCatSuppliesUseTheSameColumnsAsFurniture() {
        for language in [TestLanguage.chinese, TestLanguage.english] {
            let app = launch(language, reset: true)
            tap(app, "place-furniture-first")
            let sofa = app.buttons["manual-sofa"], chair = app.buttons["manual-chair"]
            let scratcher = app.buttons["manual-scratcher"], tree = app.buttons["manual-catTree"]
            XCTAssertTrue(tree.waitForExistence(timeout: 10))
            XCTAssertEqual(scratcher.frame.minX, sofa.frame.minX, accuracy: 1)
            XCTAssertEqual(tree.frame.minX, chair.frame.minX, accuracy: 1)
            XCTAssertEqual(scratcher.frame.midY, tree.frame.midY, accuracy: 1)
            XCTAssertGreaterThan(tree.frame.minX, scratcher.frame.maxX)
            tap(app, "manual-scratcher")
            XCTAssertTrue(app.buttons["next-model"].isEnabled)
            snap("category-columns")
            app.terminate()
        }
    }

    /// Replaces what the placement editor's name field holds.
    private func rename(_ app: XCUIApplication, to name: String) {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        for _ in 0..<6 where !field.isHittable { app.swipeUp() }
        field.replaceText(with: name)
    }

    func testEnglishInterfaceShowsNoChineseOnTheMainSurfaces() {
        var app = launch(TestLanguage.english, reset: true)
        XCTAssertTrue(app.showsRoom("Kitty’s room", timeout: 10), "English room title")
        check(app, "01-empty-room")

        // A piece straight from the catalog, keeping its default name.
        tap(app, "place-furniture-first")
        XCTAssertTrue(app.buttons["manual-sofa"].waitForExistence(timeout: 15))
        check(app, "02-add-furniture-categories")
        tap(app, "manual-sofa")
        tap(app, "next-model")
        XCTAssertTrue(element(app, "model-preview-ready").waitForExistence(timeout: 20))
        check(app, "03-add-furniture-styles")
        tap(app, "next-placement")
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        check(app, "04-placement-editor")
        let sofaName = app.textFields.firstMatch.value as? String ?? ""
        XCTAssertFalse(sofaName.isEmpty)
        tap(app, "confirm-placement")
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 15))

        // A piece from a photo, renamed by the user.
        tap(app, "add-synthetic")
        XCTAssertTrue(app.buttons["manual-chair"].waitForExistence(timeout: 20))
        check(app, "05-photo-review")
        tap(app, "manual-chair")
        tap(app, "next-model")
        tap(app, "next-placement")
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        rename(app, to: "Grandpa’s chair")
        tap(app, "confirm-placement")
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 15))
        check(app, "06-room-with-furniture")

        tap(app, "choose-interaction")
        XCTAssertTrue(app.buttons["choose-toy"].waitForExistence(timeout: 10))
        check(app, "07-interactions")
        tap(app, "choose-toy")
        sleep(1)
        check(app, "08-toys")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons["Cancel"].firstMatch.tap()

        tap(app, "furniture-list")
        let sofaRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", sofaName, "No photos yet")).firstMatch
        XCTAssertTrue(sofaRow.waitForExistence(timeout: 10), "the catalog piece shows its English name and no photos")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Grandpa’s chair", "1 photo")).firstMatch.exists)
        check(app, "09-furniture-list")
        tap(app, "close-furniture-list")

        tap(app, "photo-library")
        let cell = app.buttons["library-photo"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        check(app, "10-photo-library")
        cell.tap()
        let dateLine = element(app, "photo-date-line")
        XCTAssertTrue(dateLine.waitForExistence(timeout: 10))
        XCTAssertTrue(dateLine.label.contains("Mar 14, 2026") && dateLine.label.contains("from the photo’s info"), dateLine.label)
        check(app, "11-photo-detail")
        app.swipeUp()
        check(app, "12-photo-detail-lower")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app, "close-library")

        openMenuItem(app, "open-settings")
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 10))
        check(app, "13-settings")
        app.swipeUp()
        check(app, "14-settings-backup")
        app.swipeUp()
        check(app, "15-settings-lower")
        tap(app, "open-about")
        sleep(1)
        check(app, "16-about")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app, "close-settings")

        openMenuItem(app, "open-room-share")
        let preview = element(app, "room-postcard-ready")
        XCTAssertTrue(preview.waitForExistence(timeout: 20))
        let summary = element(app, "room-share-stats-summary")
        XCTAssertTrue(summary.label.contains("1 photo") && summary.label.contains("2026"), summary.label)
        check(app, "17-share-sheet")
        tap(app, "close-room-share")

        // Back in Chinese: the untouched catalog name follows the language, the user's name does not.
        app.terminate()
        app = launch(TestLanguage.chinese, reset: false)
        tap(app, "furniture-list")
        let rows = app.buttons.matching(identifier: "list-room-item")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let labels = rows.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains { $0.contains("Grandpa’s chair") }, "\(labels)")
        XCTAssertTrue(labels.contains { $0.contains("沙发") && !$0.contains(sofaName) }, "\(labels)")
        sleep(1)
        snap("18-chinese-furniture-list-after-english")
    }

    /// Settings rows near the bottom exist only once scrolled to: scroll, then wait.
    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let row = app.buttons[id].firstMatch
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), id)
        return row
    }

    /// The Reminders page down to Cat Facts, and Suggest a Feature, in English.
    func testEnglishRemindersAndSuggestAFeatureShowNoChinese() {
        let app = launch(TestLanguage.english, reset: true)
        openMenuItem(app, "open-settings")
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 10))
        reveal(app, "open-reminders").tap()
        let facts = app.switches["reminder-cat-facts"]
        for _ in 0..<6 where !(facts.exists && facts.isHittable) { app.swipeUp() }
        XCTAssertTrue(facts.waitForExistence(timeout: 10))
        XCTAssertEqual(facts.label, "Cat Facts")
        XCTAssertTrue(element(app, "reminder-cat-facts-footer").label.contains("not veterinary advice"))
        check(app, "19-reminders-cat-facts")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        reveal(app, "open-wish").tap()
        XCTAssertTrue(app.navigationBars["Suggest a Feature"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["wish-compose"].isEnabled)
        check(app, "20-suggest-a-feature")
        app.swipeUp()
        check(app, "21-suggest-a-feature-lower")
    }
}
