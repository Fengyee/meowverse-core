import XCTest

/// Round 7 household furniture (art/furniture/TECH_SPEC.md §4): ten categories picked from the
/// catalogue only, decorative pieces the cat walks round, and tall pieces that may not hide a
/// photo board. Screenshots are kept as attachments.
private enum GridRulesSize { static let cells = 15 }

final class HouseholdFurnitureUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ store: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "household-" + store, "-MeowverseResetStore"]
        app.launch()
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 20))
        return app
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func status(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["placement-status"].firstMatch.label
    }

    private func tap(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id]
        _ = button.waitForExistence(timeout: 10)
        for _ in 0..<6 where !(button.exists && button.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        if !(button.exists && button.isHittable) { snap("missing-" + id) }
        XCTAssertTrue(button.exists && button.isHittable, id)
        button.tap()
    }

    /// "先摆家具" in the empty room, else 添加家具 in the furniture list; then the category and
    /// the model, up to the placement editor.
    private func openPlacement(_ app: XCUIApplication, category: String, model: String?) {
        let first = app.buttons["place-furniture-first"]
        if first.exists && first.isHittable {
            first.tap()
        } else {
            tap(app, "furniture-list")
            tap(app, "add-furniture")
        }
        tap(app, "manual-" + category)
        tap(app, "next-model")
        if let model { tap(app, "model-" + model) }
        XCTAssertTrue(app.descendants(matching: .any)["model-preview-ready"].waitForExistence(timeout: 20))
        tap(app, "next-placement")
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
    }

    private func finish(_ app: XCUIApplication, _ name: String, shot: String) {
        let swatch = app.buttons[name]
        for _ in 0..<4 where !(swatch.exists && swatch.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(swatch.waitForExistence(timeout: 5), name)
        swatch.tap()
        XCTAssertTrue(swatch.isSelected, name)
        sleep(8) // let the RealityKit preview draw the recoloured ghost
        snap(shot)
    }

    /// Moves the piece in until it touches the back wall: one step past it is out of the room.
    private func pushToBackWall(_ app: XCUIApplication) {
        for _ in 0..<GridRulesSize.cells {
            app.buttons["向里移一格"].tap()
            if status(app) == "超出了房间范围" {
                app.buttons["向外移一格"].tap()
                return
            }
        }
    }

    private func confirm(_ app: XCUIApplication) {
        XCTAssertEqual(status(app), "这个位置可以摆放")
        tap(app, "confirm-placement")
        XCTAssertTrue(app.buttons["furniture-list"].waitForExistence(timeout: 15))
        sleep(2)
    }

    /// The two representatives next to existing furniture, in two palettes each, against the back
    /// wall beside a photo board; then Bella in the bookcase's reading nook.
    func testBookcaseAndFireplaceInTheRoom() {
        let app = launch("pair")
        openPlacement(app, category: "photoBoard", model: nil)
        confirm(app)
        openPlacement(app, category: "sofa", model: "mv-sofa-a")
        confirm(app)

        openPlacement(app, category: "bookcase", model: "mv-bookcase-a")
        finish(app, "薰衣草", shot: "bookcase-a-lavender")
        finish(app, "鼠尾草", shot: "bookcase-a-sage")
        // Flush against the back wall, under the board: refused, with the reason.
        pushToBackWall(app)
        XCTAssertTrue(status(app).contains("照片板"), status(app))
        snap("bookcase-a-hides-board")
        // Slid along the wall until the board is clear.
        var steps = 0
        while status(app) != "这个位置可以摆放" && steps < 10 {
            app.buttons["向左移一格"].tap()
            steps += 1
        }
        snap("bookcase-a-beside-board")
        confirm(app)

        openPlacement(app, category: "fireplace", model: "mv-fireplace-a")
        finish(app, "燕麦", shot: "fireplace-a-oat")
        finish(app, "杏桃", shot: "fireplace-a-apricot")
        pushToBackWall(app)
        steps = 0
        while status(app) != "这个位置可以摆放" && steps < 10 {
            app.buttons["向右移一格"].tap()
            steps += 1
        }
        confirm(app)
        sleep(3)
        snap("room-bookcase-fireplace-board-sofa")

        // The fireplace is decorative: the picker offers the bookcase, not the hearth.
        tap(app, "choose-interaction")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", "石拱暖炉")).firstMatch.exists)
        let row = app.buttons.matching(NSPredicate(format: "label == %@", "拱门故事书架")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        tap(app, "invite-reading-nook-loaf")
        let caption = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "bella-caption", "阅读窝")).firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 40))
        app.descendants(matching: .any)["room-world"].pinch(withScale: 1.8, velocity: 2)
        sleep(5)
        snap("bookcase-a-reading-nook-loaf")
    }

    /// The three theme sets (round 13) keep their own colours: they place like any other piece,
    /// with no colour to pick.
    func testThemeSetsPlaceWithTheirOwnColours() {
        let app = launch("sets")
        for model in ["mv-sofa-e", "mv-sofa-f", "mv-sofa-g"] {
            openPlacement(app, category: "sofa", model: model)
            sleep(8) // the model can arrive a few seconds after the status line
            app.swipeUp(velocity: .slow)
            for name in ["燕麦", "鼠尾草", "薰衣草", "杏桃"] {
                XCTAssertFalse(app.buttons[name].exists, "\(model) offers \(name)")
            }
            snap("set-placement-" + model)
            confirm(app)
        }
        sleep(4)
        snap("set-sofas-in-the-room")
    }

    /// One piece of every new category goes in from the catalogue at the suggested spot.
    func testEveryHouseholdCategoryIsPlaceable() {
        let app = launch("all")
        for category in ["bookcase", "sideboard", "mediaConsole", "writingDesk", "vanity",
                         "coatRack", "floorLamp", "roomDivider", "plantStand", "fireplace"] {
            openPlacement(app, category: category, model: nil)
            confirm(app)
        }
        sleep(3)
        snap("every-household-category")
    }

    /// Review shots for the creative director (round 7): the bookcase, fireplace, vanity and the
    /// braided rug on three of the room themes by day. Skipped unless the runner gets
    /// MV_HOUSEHOLD_SHOTS=1 (TEST_RUNNER_MV_HOUSEHOLD_SHOTS=1 xcodebuild …); MV_THEMES overrides
    /// the theme ids (comma-separated). Attachments: "household-<theme>".
    func testHouseholdPiecesOnThemes() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MV_HOUSEHOLD_SHOTS"] != nil, "review shots only")
        let themes = environment["MV_THEMES"].map { $0.split(separator: ",").map(String.init) }
            ?? ["mint-conservatory", "sakura-letters", "winter-knit"]
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "household-themes", "-MeowverseResetStore",
                                                      "-room.lightingMode", "constant", "-room.appearance.plainWalls", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 20))
        // Along the back wall: bookcase in the left corner, fireplace three cells in from the right
        // corner (so a zoomed frame keeps it), vanity between; the rug in front at the suggested spot.
        for (category, model, slide, stepBack) in [("bookcase", "mv-bookcase-a", "向左移一格", 1),
                                                   ("fireplace", "mv-fireplace-a", "向右移一格", 4),
                                                   ("vanity", "mv-vanity-a", "", 0), ("bed", "mv-bed-e", "", 0)] {
            openPlacement(app, category: category, model: model)
            if category != "bed" { pushToBackWall(app) }
            if !slide.isEmpty {
                let back = slide == "向左移一格" ? "向右移一格" : "向左移一格"
                for _ in 0..<GridRulesSize.cells where status(app) != "超出了房间范围" { app.buttons[slide].tap() }
                for _ in 0..<stepBack { app.buttons[back].tap() }
            }
            for _ in 0..<6 where status(app) != "这个位置可以摆放" { app.buttons["向左移一格"].tap() }
            confirm(app)
        }
        sleep(4)
        snap("household-default-theme-unzoomed")
        app.descendants(matching: .any)["room-world"].pinch(withScale: 1.25, velocity: 2)
        sleep(4)
        snap("household-default-theme")
        for theme in themes {
            app.buttons["open-room-appearance"].tap()
            XCTAssertTrue(app.buttons["save-room-appearance"].waitForExistence(timeout: 5))
            let chip = app.buttons["room-theme-" + theme]
            app.scrollThemeTray(to: chip)
            chip.tap()
            XCTAssertTrue(chip.isSelected, theme)
            app.buttons["save-room-appearance"].tap()
            XCTAssertTrue(app.buttons["open-room-appearance"].waitForExistence(timeout: 5))
            sleep(4) // past the theme cross-fade
            snap("household-" + theme)
        }
    }
}
