import XCTest

/// Review shots of the room themes (art/ui/THEMES.md): the same furnished
/// room with the cat, each theme by day and by night. Skipped unless the runner gets
/// MV_THEME_SHOTS=1. Set the appearance from the Mac and say which it is, as in
/// RoomReviewShotsUITests:
///
///     xcrun simctl ui <udid> appearance dark
///     TEST_RUNNER_MV_THEME_SHOTS=1 TEST_RUNNER_MV_APPEARANCE=dark xcodebuild … \
///       -only-testing:MeowverseUITests/RoomThemeShotsUITests test
///
/// MV_THEME_SHOTS=build only builds the room (store "room-themes") and stops, so another build of
/// the app can be launched on the same store for "before" shots. MV_THEMES limits the themes
/// (comma-separated ids), MV_PHASES the phases ("day", "night"), MV_ORIENTATION=landscape turns the
/// device. Attachments are named "theme-<id>-<day|night>" plus "-landscape" and "-dark".
///
/// Review M5/M6 (light cats, oat upholstery): MV_THEME_SHOTS=build-oat builds store "room-oat"
/// (two oat beds and an oat sofa), MV_STORE picks the store to shoot, MV_CAT_PACK=<Mac path to a
/// .meowcat> imports that cat first through the DEBUG drill in Settings (simulator only; "bella"
/// chooses the built-in cat again), and
/// MV_FRAMES=<n> takes n frames three seconds apart ("-2", "-3" …), to catch the cat on the floor.
///
/// Round 13: MV_THEME_SHOTS=sets gives each furniture set's theme a room furnished from its own set
/// (store "room-<theme>"), then shoots it by day and by night.
final class RoomThemeShotsUITests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var dark: Bool { environment["MV_APPEARANCE"] == "dark" }
    private var store: String { environment["MV_STORE"] ?? "room-themes" }
    private let themes = ["cream-oak", "mint-conservatory", "sea-salt", "peach-bakery", "sakura-letters",
                          "mushroom-rain", "honey-picnic", "lilac-moon", "winter-knit", "forest-library",
                          "gilded-palace", "jiangnan-study", "sakura-tatami"]

    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipUnless(environment["MV_THEME_SHOTS"] != nil, "theme review shots only")
    }

    func testThemeShots() throws {
        switch environment["MV_THEME_SHOTS"] {
        case "build":
            buildRoom("room-themes", [("table", "mv-table-a", nil), ("chair", "mv-chair-a", nil), ("stool", "mv-stool-a", nil),
                                      ("bench", "mv-bench-a", nil), ("catTree", "mv-cat-tree-a", nil), ("sofa", "mv-sofa-c", nil)])
            return
        case "build-oat":
            buildRoom("room-oat", [("bed", "mv-bed-c", nil), ("bed", "mv-bed-e", nil), ("sofa", "mv-sofa-a", "燕麦")])
            return
        case "sets":
            shootSets()
            return
        default: break
        }
        if let pack = environment["MV_CAT_PACK"] { importCat(pack) }
        let chosen = environment["MV_THEMES"].map { $0.split(separator: ",").map(String.init) } ?? themes
        let frames = Int(environment["MV_FRAMES"] ?? "") ?? 1
        let tag = environment["MV_TAG"].map { "-" + $0 } ?? ""
        for phase in ["day", "night"] where environment["MV_PHASES"]?.contains(phase) ?? true {
            let app = launch(night: phase == "night")
            for theme in chosen {
                choose(app, theme)
                sleep(2)
                for frame in 1...frames {
                    if frame > 1 { sleep(3) }
                    snap("theme-\(theme)-\(phase)\(tag)" + (frame > 1 ? "-\(frame)" : ""))
                }
            }
            app.terminate()
        }
    }

    /// The three sets' models are lettered one after the other in each category.
    private func shootSets() {
        let sets = [("gilded-palace", ["e", "g", "d", "e"]), ("jiangnan-study", ["f", "h", "e", "f"]),
                    ("sakura-tatami", ["g", "i", "f", "g"])]
        for (theme, letters) in sets where environment["MV_THEMES"]?.contains(theme) ?? true {
            let store = "room-" + theme
            if environment["MV_KEEP_ROOMS"] == nil {
                buildRoom(store, [("sofa", "mv-sofa-" + letters[0], nil), ("bed", "mv-bed-" + letters[1], nil),
                                  ("catTree", "mv-cat-tree-" + letters[2], nil), ("hideout", "mv-hideout-" + letters[3], nil)])
            }
            for phase in ["day", "night"] where environment["MV_PHASES"]?.contains(phase) ?? true {
                let app = launch(night: phase == "night", store: store)
                choose(app, theme)
                sleep(3)
                snap("set-\(theme)-\(phase)")
                if phase == "day" {
                    app.buttons["open-room-appearance"].tap()
                    XCTAssertTrue(app.buttons["save-room-appearance"].waitForExistence(timeout: 5))
                    sleep(2)
                    snap("set-\(theme)-tray")
                }
                app.terminate()
            }
        }
    }

    // MARK: Helpers

    private func importCat(_ path: String) {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseCatPackFile", path]
        app.launch()
        XCTAssertTrue(app.buttons["open-cat-manager"].waitForExistence(timeout: 25))
        app.openCatManager()
        if path == "bella" {
            app.chooseBuiltInCat("bella")
            app.terminate()
            return
        }
        // Imported on an earlier run: choose it (importing the same id again asks to replace).
        let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let existing = app.buttons["cat-pack-" + id]
        if existing.waitForExistence(timeout: 5) {
            for _ in 0..<8 where !existing.isHittable { app.swipeUp() }
            existing.tap()
            let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: existing)
            XCTAssertEqual(XCTWaiter().wait(for: [chosen], timeout: 10), .completed, "\(id) not chosen")
            app.terminate()
            return
        }
        let drill = app.buttons["drill-import-cat-pack"]
        for _ in 0..<8 where !drill.isHittable { app.swipeUp() }
        XCTAssertTrue(drill.waitForExistence(timeout: 10))
        drill.tap()
        let notice = app.descendants(matching: .any)["cat-pack-notice"].firstMatch
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已导入"), object: notice)
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 30), .completed, "cat pack not imported")
        app.terminate()
    }

    private func launch(night: Bool, store named: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", named ?? store,
                                                      "-room.lightingMode", night ? "localTime" : "constant",
                                                      "-room.appearance.plainWalls", "NO"]
        if night { app.launchEnvironment["TZ"] = Self.nightZone() }
        XCUIDevice.shared.orientation = environment["MV_ORIENTATION"] == "landscape" ? .landscapeLeft : .portrait
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        return app
    }

    /// A time zone where it is now between 23:00 and 03:59, well inside the night phase.
    private static func nightZone() -> String {
        let now = Date()
        for id in TimeZone.knownTimeZoneIdentifiers {
            guard let zone = TimeZone(identifier: id) else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let hour = calendar.component(.hour, from: now)
            if hour == 23 || hour < 4 { return id }
        }
        return "UTC"
    }

    private func choose(_ app: XCUIApplication, _ theme: String) {
        app.buttons["open-room-appearance"].tap()
        XCTAssertTrue(app.buttons["save-room-appearance"].waitForExistence(timeout: 5))
        let chip = app.buttons["room-theme-" + theme]
        app.scrollThemeTray(to: chip)
        chip.tap()
        XCTAssertTrue(chip.isSelected, theme)
        app.buttons["save-room-appearance"].tap()
        XCTAssertTrue(app.buttons["open-room-appearance"].waitForExistence(timeout: 5))
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name + (environment["MV_ORIENTATION"] == "landscape" ? "-landscape" : "") + (dark ? "-dark" : "")
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tap(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id].firstMatch
        if !button.waitForExistence(timeout: 10) { for _ in 0..<6 where !button.exists { app.swipeUp() } }
        XCTAssertTrue(button.waitForExistence(timeout: 5), id)
        for _ in 0..<6 where !button.isHittable { app.swipeUp() }
        button.tap()
    }

    /// Catalog pieces placed in a fresh store; a swatch label picks a palette preset ("燕麦" is oat).
    private func buildRoom(_ store: String, _ pieces: [(category: String, model: String, swatch: String?)]) {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseResetStore"]
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        for piece in pieces {
            tap(app, "furniture-list")
            tap(app, "add-furniture")
            tap(app, "manual-" + piece.category)
            tap(app, "next-model")
            tap(app, "model-" + piece.model)
            XCTAssertTrue(app.descendants(matching: .any)["model-preview-ready"].firstMatch.waitForExistence(timeout: 20))
            tap(app, "next-placement")
            XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
            if let swatch = piece.swatch {
                let button = app.buttons[swatch].firstMatch
                XCTAssertTrue(button.waitForExistence(timeout: 5), swatch)
                button.tap()
                XCTAssertTrue(button.isSelected, swatch)
            }
            tap(app, "confirm-placement")
            XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 15))
        }
        app.terminate()
    }
}
