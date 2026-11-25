import XCTest

/// 猫咪管理 → 猫咪模型 (owner, 2026-11-20): tapping a built-in cat opens her character card; only its
/// 就选它 changes the cat in the room, and closing the card changes nothing.
///
/// Review shots: `testCardShots` runs only with `TEST_RUNNER_MV_SHOT_DIR=<folder>` and writes
/// `<MV_SHOT_PREFIX>-grid-top.png`, `-grid.png` and `<MV_SHOT_PREFIX>-card.png`. `TEST_RUNNER_MV_TEXT_SIZE=<category>`
/// sets the text size, `TEST_RUNNER_MV_LANDSCAPE=1` turns the device first. Light or dark is the
/// simulator's own (`simctl ui <udid> appearance`).
final class CatProfileCardUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ store: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "catcard-" + store, "-MeowverseResetStore"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 60))
        return app
    }

    private func tile(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let tile = app.buttons["cat-pack-" + id]
        XCTAssertTrue(tile.waitForExistence(timeout: 10), id)
        for _ in 0..<8 where !tile.isHittable { manager(app).swipeUp(velocity: .slow) }
        XCTAssertTrue(tile.isHittable, "could not reach \(id)")
        return tile
    }

    /// 猫咪管理 itself: swiping inside it scrolls it, where a swipe on the iPad's room would close the popover.
    private func manager(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["home-manager"]
    }

    private func card(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["cat-card"]
    }

    func testACatsCardComesFirstAndOnlyChooseChoosesHer() {
        let app = launch("choose")
        app.openCatManager()
        let bella = tile(app, "bella"), luna = tile(app, "black")
        XCTAssertTrue(bella.isSelected, "Bella is the default")
        XCTAssertFalse(luna.isSelected)
        XCTAssertTrue(luna.label.contains("露娜"), luna.label)

        // Her card: names, gender, breed, who sponsored her and her 小趣事.
        luna.tap()
        XCTAssertTrue(card(app).waitForExistence(timeout: 10), "the character card opens")
        XCTAssertEqual(app.staticTexts["cat-card-name"].label, "露娜")
        XCTAssertEqual(app.staticTexts["cat-card-other-name"].label, "Luna")
        XCTAssertTrue(app.descendants(matching: .any)["cat-card-gender"].label.contains("女孩"))
        XCTAssertTrue(app.descendants(matching: .any)["cat-card-breed"].label.contains("黑猫"))
        XCTAssertEqual(app.descendants(matching: .any)["cat-card-bio"].label, "露娜的铲屎官赞助了我们的喵空间！")
        XCTAssertTrue(app.buttons["cat-card-inspect"].exists, "the 3D model is one tap away")
        let fact = app.descendants(matching: .any)["cat-card-fun-fact"]
        XCTAssertTrue(fact.label.contains("小趣事") && fact.label.contains("手表"), fact.label)
        let standIn = NSPredicate(format: "label CONTAINS '待补充' OR label CONTAINS '示例'")
        XCTAssertFalse(app.descendants(matching: .any).matching(standIn).firstMatch.exists, "no stand-in text")
        XCTAssertFalse(app.descendants(matching: .any)["cat-card-sponsor"].exists, "no separate thanks line")
        XCTAssertFalse(luna.isSelected, "opening the card chooses nothing")

        // Closing it changes nothing.
        app.buttons["close-cat-card"].tap()
        XCTAssertTrue(card(app).waitForNonExistence(timeout: 10))
        XCTAssertTrue(bella.isSelected, "closing the card keeps Bella")
        XCTAssertFalse(luna.isSelected)

        // 就选它 does.
        app.chooseBuiltInCat("black")
        XCTAssertTrue(card(app).waitForNonExistence(timeout: 10), "choosing closes the card")
        XCTAssertFalse(bella.isSelected)
        XCTAssertEqual(luna.value as? String, "正在使用")

        // Her card now says she is in use and offers no second choice.
        luna.tap()
        XCTAssertTrue(card(app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["cat-card-in-use"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["choose-cat-pack"].exists)
        app.buttons["close-cat-card"].tap()
        XCTAssertTrue(card(app).waitForNonExistence(timeout: 10))
        XCTAssertTrue(luna.isSelected)
    }

    /// The newest built-in cat (Zhaocai, 2026-11-23): her card, her 3D model, and the room takes her.
    func testTheNewestBuiltInCatHasACardAModelAndCanBeChosen() {
        let app = launch("zhaocai")
        app.openCatManager()
        let cat = tile(app, "zhaocai")
        XCTAssertTrue(cat.label.contains("招财"), cat.label)
        cat.tap()
        XCTAssertTrue(card(app).waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["cat-card-name"].label, "招财")
        XCTAssertTrue(app.descendants(matching: .any)["cat-card-breed"].label.contains("金渐层"))
        app.buttons["cat-card-inspect"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["cat-inspect-model"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.descendants(matching: .any)["cat-inspect-failed"].exists)
        app.buttons["close-cat-inspect"].tap()
        XCTAssertTrue(card(app).waitForExistence(timeout: 10))
        app.buttons["close-cat-card"].tap()
        XCTAssertTrue(card(app).waitForNonExistence(timeout: 10))
        app.chooseBuiltInCat("zhaocai")
        XCTAssertTrue(card(app).waitForNonExistence(timeout: 10))
        XCTAssertEqual(cat.value as? String, "正在使用")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "zhaocai-chosen"; shot.lifetime = .keepAlways; add(shot)
    }

    /// The 3D model opens from the card and comes back to it.
    func testTheCardOpensTheThreeDModel() {
        let app = launch("inspect")
        app.openCatManager()
        tile(app, "zhumi").tap()
        let inspect = app.buttons["cat-card-inspect"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 10))
        inspect.tap()
        XCTAssertTrue(app.descendants(matching: .any)["cat-inspect-model"].waitForExistence(timeout: 30))
        // How the cats were made is said once, under 关于 (launch design §3), not on each cat.
        XCTAssertFalse(app.descendants(matching: .any)["cat-inspect-credit"].exists, "a credit on this cat's model")
        app.buttons["close-cat-inspect"].tap()
        XCTAssertTrue(card(app).waitForExistence(timeout: 10), "back on the card")
        XCTAssertFalse(app.buttons["cat-pack-zhumi"].isSelected)
    }

    func testEnglishBio() {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.english + ["-MeowverseStore", "catcard-english", "-MeowverseResetStore"]
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 60))
        app.openCatManager()
        tile(app, "black").tap()
        XCTAssertTrue(card(app).waitForExistence(timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any)["cat-card-bio"].label, "Luna’s human sponsored our Meowverse!")
        let fact = app.descendants(matching: .any)["cat-card-fun-fact"]
        XCTAssertTrue(fact.label.contains("Fun fact") && fact.label.contains("watch"), fact.label)
        let standIn = NSPredicate(format: "label CONTAINS[c] '(sample)' OR label CONTAINS '待补充'")
        XCTAssertFalse(app.descendants(matching: .any).matching(standIn).firstMatch.exists, "no stand-in text")
    }

    /// The DEBUG gallery draws the card as it ships: Bella's, or the cat `-MeowverseGalleryCat` names.
    func testTheGalleryShowsTheShippedCard() {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseOverlayGallery", "cat-card"]
        app.launch()
        let fact = app.descendants(matching: .any)["cat-card-fun-fact"].firstMatch
        XCTAssertTrue(fact.waitForExistence(timeout: 60))
        XCTAssertTrue(fact.label.contains("小趣事") && fact.label.contains("拍屁屁"), fact.label)
        app.terminate()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseOverlayGallery", "cat-card", "-MeowverseGalleryCat", "zhumi"]
        app.launch()
        XCTAssertTrue(fact.waitForExistence(timeout: 60))
        XCTAssertTrue(fact.label.contains("自助餐"), fact.label)
        XCTAssertTrue(app.descendants(matching: .any)["cat-card-traits"].label.contains("埋伏高手"))
    }

    func testCardShots() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["MV_SHOT_DIR"] else { throw XCTSkip("review shots only") }
        let prefix = environment["MV_SHOT_PREFIX"] ?? "card"
        var extra: [String] = []
        if let size = environment["MV_TEXT_SIZE"] { extra += ["-UIPreferredContentSizeCategoryName", size] }
        if environment["MV_LANDSCAPE"] == "1" { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = launch("shots", extra: extra)
        app.openCatManager()
        let bella = tile(app, "bella")
        // Before any swipe: the top of the grid, with 正在使用 on the cat the room shows.
        XCTAssertTrue(bella.waitForExistence(timeout: 10))
        sleep(1)
        write(folder, prefix + "-grid-top")
        if app.windows.firstMatch.frame.width < 700 { for _ in 0..<2 { manager(app).swipeUp(velocity: .slow) } }
        sleep(1)
        write(folder, prefix + "-grid")
        // The iPad's popover shows the grid's width; its card is the iPhone's card in a sheet.
        if app.windows.firstMatch.frame.width >= 700 { return }
        for _ in 0..<8 where !bella.isHittable { manager(app).swipeDown(velocity: .slow) }
        tile(app, "ragdoll").tap()
        XCTAssertTrue(card(app).waitForExistence(timeout: 10))
        sleep(2)
        write(folder, prefix + "-card")
        if environment["MV_TEXT_SIZE"] != nil {
            // The largest sizes: the rest of the card, down to 就选它, scrolled into view.
            for _ in 0..<6 { card(app).swipeUp(velocity: .slow) }
            sleep(1)
            write(folder, prefix + "-card-end")
            XCTAssertTrue(app.buttons["choose-cat-pack"].isHittable, "就选它 can be reached")
        }
    }

    /// Review shots of the shipped cards from the DEBUG gallery, top to 就选它: `<prefix>-<id>-1.png`,
    /// `-2.png`, … for each cat in `TEST_RUNNER_MV_SHOT_CATS` (comma-separated, default all eight).
    /// Language from `TEST_RUNNER_MV_LANG`, text size from `TEST_RUNNER_MV_TEXT_SIZE`.
    func testGalleryCardShots() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["MV_SHOT_DIR"] else { throw XCTSkip("review shots only") }
        let prefix = environment["MV_SHOT_PREFIX"] ?? "gallery"
        let cats = (environment["MV_SHOT_CATS"] ?? "bella,airou,zhumi,siamese,ragdoll,black,white,sphynx")
            .split(separator: ",").map(String.init)
        for id in cats {
            let app = XCUIApplication()
            app.launchArguments = TestLanguage.current + ["-MeowverseOverlayGallery", "cat-card", "-MeowverseGalleryCat", id]
            if let size = environment["MV_TEXT_SIZE"] { app.launchArguments += ["-UIPreferredContentSizeCategoryName", size] }
            app.launch()
            XCTAssertTrue(card(app).waitForExistence(timeout: 60), id)
            sleep(1)
            let choose = app.buttons["choose-cat-pack"]
            var page = 1
            write(folder, "\(prefix)-\(id)-\(page)")
            while !(choose.exists && choose.isHittable), page < 6 {
                card(app).swipeUp(velocity: .slow)
                sleep(1)
                page += 1
                write(folder, "\(prefix)-\(id)-\(page)")
            }
            XCTAssertTrue(choose.isHittable, "\(id): 就选它 can be reached")
            app.terminate()
        }
    }

    private func write(_ folder: String, _ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder + "/" + name + ".png"))
    }
}
