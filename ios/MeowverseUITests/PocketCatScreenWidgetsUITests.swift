import XCTest

/// Round 11: the Home Screen and Lock Screen widgets (`PocketCatWidget/PocketCatScreenWidgets.swift`).
///
/// The widgets are put on the simulator's Home Screen and Lock Screen once, through SpringBoard,
/// and stay there for later runs. Widgets follow the simulator's system language, not the app's
/// `-AppleLanguages`, so SpringBoard labels are matched in both languages.
///
/// Review shots: `testWidgetShots` runs only with `TEST_RUNNER_MV_SHOT_DIR=<folder>` and writes
/// `<MV_SHOT_PREFIX>-home.png` and `-lock.png` there; the host sets language, appearance and
/// text size with `simctl` before each run.
final class PocketCatScreenWidgetsUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() { continueAfterFailure = false }

    private func named(_ labels: [String]) -> NSPredicate { NSPredicate(format: "label IN %@", labels) }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = environment["MV_SHOT_DIR"] {
            let prefix = environment["MV_SHOT_PREFIX"].map { $0 + "-" } ?? ""
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder + "/" + prefix + name + ".png"))
        }
    }

    // MARK: The app

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "pocket-widgets", "-MeowverseResetStore"]
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        return app
    }

    private func openCompanion(_ app: XCUIApplication) {
        let start = app.buttons["pocket-start"], end = app.buttons["pocket-end"]
        if start.exists || end.exists { return }
        app.buttons["choose-interaction"].tap()
        let choose = app.buttons["choose-pocket-cat"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5), app.debugDescription)
        choose.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5) || end.exists)
    }

    private func endCompany(_ app: XCUIApplication) {
        openCompanion(app)
        let end = app.buttons["pocket-end"]
        if end.waitForExistence(timeout: 3) { end.tap() }
        XCTAssertTrue(app.buttons["pocket-start"].waitForExistence(timeout: 10))
    }

    private func startCompany(_ app: XCUIApplication, mood: String) {
        endCompany(app)
        app.buttons["pocket-select"].tap()
        app.buttons[mood].tap()
        app.buttons["pocket-start"].tap()
        XCTAssertTrue(app.buttons["pocket-end"].waitForExistence(timeout: 10))
    }

    private func allowLiveActivities() {
        let allow = springboard.buttons.matching(named(["Allow", "Always Allow", "允许", "始终允许"])).firstMatch
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
            sleep(1)
        }
    }

    // MARK: Home Screen

    /// The first Home Screen page, where the widgets go.
    private func showHome() {
        XCUIDevice.shared.press(.home)
        sleep(1)
        XCUIDevice.shared.press(.home)
        sleep(1)
    }

    /// Our widgets on the Home Screen, on every page: SpringBoard lists each as an icon named
    /// after the app (喵空间 on a Chinese system) with the value "Widget" (「小组件」).
    private var homeWidgets: [XCUIElement] {
        springboard.icons.matching(NSPredicate(format: "identifier IN {'Meowverse', '喵空间'} AND value IN {'Widget', '小组件'}")).allElementsBoundByIndex
    }

    private func enterHomeEditing() {
        showHome()
        let edit = springboard.buttons.matching(named(["Edit", "编辑"])).firstMatch
        for point in [CGVector(dx: 0.5, dy: 0.80), CGVector(dx: 0.9, dy: 0.80), CGVector(dx: 0.5, dy: 0.62)] {
            springboard.coordinate(withNormalizedOffset: point).press(forDuration: 1.5)
            if edit.waitForExistence(timeout: 3) { break }
            // A press on an icon opens its menu instead.
            let editHome = springboard.buttons.matching(named(["Edit Home Screen", "编辑主屏幕"])).firstMatch
            if editHome.exists {
                editHome.tap()
                if edit.waitForExistence(timeout: 3) { break }
            }
            XCUIDevice.shared.press(.home)
        }
        XCTAssertTrue(edit.exists, springboard.debugDescription)
        edit.tap()
    }

    private func leaveHomeEditing() {
        let done = springboard.buttons.matching(named(["Done", "完成"])).firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }
        sleep(1)
    }

    /// Adds the app's widget at `page` of its sizes in the gallery (0 small, 1 medium).
    private func addHomeWidget(page: Int) {
        enterHomeEditing()
        let add = springboard.buttons.matching(named(["Add Widget", "添加小组件"])).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let search = springboard.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Meowverse")
        let row = springboard.cells.matching(named(["Meowverse"])).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the widget gallery doesn't list the app")
        row.tap()
        let addWidget = springboard.buttons.matching(NSPredicate(format: "label ENDSWITH 'Add Widget' OR label ENDSWITH '添加小组件'")).firstMatch
        XCTAssertTrue(addWidget.waitForExistence(timeout: 5))
        for _ in 0..<page {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.6)))
            sleep(1)
        }
        addWidget.tap()
        sleep(2)
        leaveHomeEditing()
    }

    /// Medium or small, by shape: at the accessibility text sizes SpringBoard draws the Home
    /// Screen smaller, and a size in points mistook the medium widget for a small one.
    private func isWide(_ widget: XCUIElement) -> Bool { widget.frame.width > widget.frame.height * 1.4 }

    /// Removes one widget through its long-press menu, turning to its page first.
    private func removeHomeWidget(_ widget: XCUIElement) {
        let width = springboard.frame.width
        for _ in 0..<4 where widget.frame.minX >= width {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
            sleep(1)
        }
        widget.press(forDuration: 1.5)
        let remove = springboard.buttons.matching(named(["Remove Widget", "移除小组件"])).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5), springboard.debugDescription)
        remove.tap()
        let confirm = springboard.alerts.buttons.matching(named(["Remove", "移除"])).firstMatch
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        sleep(2)
        showHome()
    }

    private func ensureHomeWidgets() {
        showHome()
        // An earlier run that retried an add can leave a second copy of a size.
        for wide in [false, true] {
            // Keep the first page's copy: remove the one furthest along.
            while case let same = homeWidgets.filter({ isWide($0) == wide }), same.count > 1,
                  let extra = same.max(by: { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }) {
                removeHomeWidget(extra)
            }
        }
        if !homeWidgets.contains(where: { !isWide($0) }) { addHomeWidget(page: 0) }
        showHome()
        if !homeWidgets.contains(where: isWide) { addHomeWidget(page: 1) }
        showHome()
        XCTAssertEqual(homeWidgets.count, 2, springboard.debugDescription)
    }

    /// The Home Screen's icon and widget style (Edit → Customize): "Default" or "Tinted".
    private func setHomeStyle(_ english: String, _ chinese: String) {
        enterHomeEditing()
        let customize = springboard.buttons.matching(named(["Customize", "自定", "自定义"])).firstMatch
        XCTAssertTrue(customize.waitForExistence(timeout: 5), springboard.debugDescription)
        customize.tap()
        // The four styles are not buttons in the tree; on a Chinese system Tinted is 「色调」.
        let style = springboard.descendants(matching: .any).matching(named([english, chinese])).firstMatch
        XCTAssertTrue(style.waitForExistence(timeout: 5), springboard.debugDescription)
        style.tap()
        sleep(2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        sleep(1)
        leaveHomeEditing()
    }

    private func homeButtons(_ english: String, _ chinese: String) -> XCUIElementQuery {
        springboard.buttons.matching(named([english, chinese]))
    }

    // MARK: Lock Screen

    private func showLockScreen() {
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(2)
    }

    /// No passcode on the simulator: the Home button opens the Home Screen.
    private func unlock() {
        XCUIDevice.shared.press(.home)
        sleep(1)
        XCUIDevice.shared.press(.home)
        sleep(1)
    }

    private var lockCircular: XCUIElement {
        springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Pixel cat, ' OR label BEGINSWITH '像素猫，'")).firstMatch
    }

    /// Adds the circular and rectangular widgets to the Lock Screen's widget row. The poster
    /// editor shows no accessibility elements, so its "Add Widgets" row and "Done" are tapped
    /// by place (iPhone 15 Pro, iOS 27.2).
    private func ensureLockWidgets() {
        showLockScreen()
        if lockCircular.waitForExistence(timeout: 3) { return }
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 2)
        let customize = springboard.buttons.matching(named(["Customize", "自定", "自定义"])).firstMatch
        XCTAssertTrue(customize.waitForExistence(timeout: 5), springboard.debugDescription)
        customize.tap()
        sleep(2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.783)).tap()
        sleep(2)
        let cells = springboard.cells.matching(named(["Meowverse"]))
        for _ in 0..<6 where !cells.firstMatch.exists { springboard.swipeUp(); sleep(1) }
        XCTAssertTrue(cells.firstMatch.exists, "the Lock Screen gallery doesn't list the app")
        cells.firstMatch.tap()
        sleep(1)
        let tiles = springboard.buttons.matching(NSPredicate(format: "label ENDSWITH 'Pixel Cat' OR label ENDSWITH '像素猫'"))
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 5), springboard.debugDescription)
        let count = tiles.count
        for index in (0..<count).reversed() {
            tiles.element(boundBy: index).tap()
            sleep(1)
        }
        let close = springboard.buttons.matching(named(["close", "Close", "关闭"])).firstMatch
        if close.exists { close.tap() }
        sleep(2)
        // "Done" at the top right; the first tap after the gallery closes can be lost.
        for _ in 0..<3 where !lockCircular.exists {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.035)).tap()
            sleep(3)
        }
        showLockScreen()
        XCTAssertTrue(lockCircular.waitForExistence(timeout: 10), springboard.debugDescription)
    }

    // MARK: Tests

    /// While a companion runs, the widgets say "Change expression" and show the Live Activity's
    /// expression (E1, E2); the button changes it on both; after company ends they offer "Keep
    /// me company" again, which starts company without opening the app.
    func testWidgetsFollowTheCompanion() throws {
        let app = launchApp()
        endCompany(app)
        ensureLockWidgets()
        unlock()
        ensureHomeWidgets()

        let keep = homeButtons("Keep me company", "陪我一会儿")
        let change = homeButtons("Change expression", "换个表情")
        XCTAssertTrue(keep.firstMatch.waitForExistence(timeout: 15), springboard.debugDescription)
        XCTAssertEqual(keep.count, 2)
        XCTAssertFalse(change.firstMatch.exists)

        // Company begins in the app, on 在观察.
        app.activate()
        startCompany(app, mood: "在观察")
        showHome()
        allowLiveActivities()
        showHome()
        XCTAssertTrue(change.firstMatch.waitForExistence(timeout: 15), springboard.debugDescription)
        XCTAssertEqual(change.count, 2)
        XCTAssertFalse(keep.firstMatch.exists)
        let watching = springboard.staticTexts.matching(named(["Watching", "在观察"]))
        XCTAssertEqual(watching.count, 2, springboard.debugDescription)
        snap("company-home")

        // The widget's button: the next expression, on the widget and in the Live Activity.
        change.firstMatch.tap()
        let sleeping = springboard.staticTexts.matching(named(["Sleeping", "睡觉中"]))
        XCTAssertTrue(sleeping.firstMatch.waitForExistence(timeout: 15), springboard.debugDescription)
        XCTAssertEqual(sleeping.count, 2)
        XCTAssertNotEqual(app.state, .runningForeground, "the button opened the app")

        // The Lock Screen follows too.
        showLockScreen()
        XCTAssertTrue(lockCircular.waitForExistence(timeout: 10))
        XCTAssertTrue(["Pixel cat, Sleeping", "像素猫，睡觉中"].contains(lockCircular.label), lockCircular.label)
        let keeping = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Keeping you company' OR label CONTAINS '正在陪伴你'")).firstMatch
        XCTAssertTrue(keeping.waitForExistence(timeout: 10), springboard.debugDescription)
        snap("company-lock")
        unlock()

        // The app's companion page shows the same expression as the widgets.
        app.activate()
        XCTAssertEqual(app.staticTexts["pocket-expression"].label, "睡觉中")

        // Ended in the app: back to "Keep me company".
        endCompany(app)
        showHome()
        XCTAssertTrue(keep.firstMatch.waitForExistence(timeout: 15), springboard.debugDescription)
        XCTAssertFalse(change.firstMatch.exists)

        // "Keep me company" on the widget starts company without opening the app.
        keep.firstMatch.tap()
        XCTAssertTrue(change.firstMatch.waitForExistence(timeout: 15), springboard.debugDescription)
        XCTAssertNotEqual(app.state, .runningForeground, "the button opened the app")
        XCTAssertTrue(springboard.staticTexts.matching(named(["Sleeping", "睡觉中"])).firstMatch.exists)
        app.activate()
        endCompany(app)
    }

    /// Round 11: "Change expression" on the Live Activity itself, on the Lock Screen and in the
    /// expanded Dynamic Island, changes the expression in place, without opening the app, and
    /// the widgets follow it (here the Lock Screen's circular one, which names the expression).
    /// With `MV_SHOT_DIR` set it also writes the review shots `lock-activity` and
    /// `island-expanded`; the host sets the appearance.
    func testLiveActivityChangeReachesTheWidgets() throws {
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        try XCTSkipUnless(model.hasPrefix("iPhone1") && model >= "iPhone16,1", "Needs a Dynamic Island simulator.")
        let app = launchApp()
        endCompany(app)
        ensureLockWidgets()
        unlock()
        app.activate()
        startCompany(app, mood: "在观察")

        // The Lock Screen: watching, then the activity's own button.
        showLockScreen()
        allowLiveActivities()
        let change = springboard.buttons["pocket-change"].firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 10), springboard.debugDescription)
        XCTAssertTrue(lockCircularSays("在观察"), lockCircular.label)
        sleep(1)
        snap("lock-activity")
        // The first tap on a just-woken Lock Screen is sometimes lost: tap again only if
        // nothing changed (a second change would skip to 在玩 and fail below).
        change.tap()
        if !lockCircularSays("睡觉中", within: 8) { change.tap() }
        XCTAssertTrue(lockCircularSays("睡觉中"), lockCircular.label)
        XCTAssertTrue(springboard.staticTexts.matching(named(["Sleeping", "睡觉中"])).firstMatch.exists, "the Live Activity didn't change")
        XCTAssertNotEqual(app.state, .runningForeground, "the button opened the app")

        // The expanded island: the next one again.
        unlock()
        let island = springboard.otherElements.matching(identifier: "regular.view").firstMatch
        XCTAssertTrue(island.waitForExistence(timeout: 10), springboard.debugDescription)
        springboard.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: island.frame.midX, dy: island.frame.midY))
            .press(forDuration: 1.2)
        let changeOnIsland = springboard.buttons["pocket-change"].firstMatch
        XCTAssertTrue(changeOnIsland.waitForExistence(timeout: 10), springboard.debugDescription)
        sleep(1)
        snap("island-expanded")
        changeOnIsland.tap()
        sleep(2)
        XCTAssertNotEqual(app.state, .runningForeground, "the button opened the app")
        showLockScreen()
        XCTAssertTrue(lockCircularSays("在玩"), lockCircular.label)
        unlock()

        app.activate()
        XCTAssertTrue(app.staticTexts.matching(identifier: "pocket-expression")
            .matching(NSPredicate(format: "label == %@", "在玩")).firstMatch.waitForExistence(timeout: 8))
        endCompany(app)
    }

    /// The circular Lock Screen widget reads 「像素猫，<expression>」.
    private func lockCircularSays(_ mood: String, within seconds: TimeInterval = 15) -> Bool {
        let says = NSPredicate(format: "label == %@", "像素猫，" + mood)
        let english = ["睡觉中": "Sleeping", "在玩": "Playing", "在观察": "Watching"][mood].map { "Pixel cat, " + $0 } ?? ""
        let either = NSCompoundPredicate(orPredicateWithSubpredicates: [says, NSPredicate(format: "label == %@", english)])
        let found = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"),
                                              object: springboard.descendants(matching: .any).matching(either).firstMatch)
        return XCTWaiter().wait(for: [found], timeout: seconds) == .completed
    }

    private static let moodWords = ["Sleeping", "Playing", "Zoomies", "Thinking", "Eating", "Watching",
                                    "睡觉中", "在玩", "在疯", "在思考", "在吃饭", "在观察"]

    /// A tap on the widget away from its buttons opens the companion page (E5).
    func testTappingTheWidgetOpensTheCompanion() throws {
        let cancel = springboard.alerts.buttons.matching(named(["Cancel", "取消"])).firstMatch
        if cancel.exists { cancel.tap() }
        let app = launchApp()
        endCompany(app)
        app.terminate()
        ensureHomeWidgets()
        let small = try XCTUnwrap(homeWidgets.first { !isWide($0) })
        // Tap the widget's own content (its expression word), not a point on SpringBoard's icon
        // element, after the Home Screen has settled.
        sleep(2)
        let word = small.descendants(matching: .staticText).matching(named(PocketCatScreenWidgetsUITests.moodWords)).firstMatch
        if word.waitForExistence(timeout: 5) {
            word.tap()
        } else {
            small.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.buttons["pocket-start"].waitForExistence(timeout: 20), app.debugDescription)
    }

    /// Review shots of the widgets as they are, in whatever language, appearance and text size
    /// the host set; `MV_SHOT_COMPANY=1` starts company first, `MV_SHOT_LOCK=0` skips the Lock
    /// Screen.
    func testWidgetShots() throws {
        try XCTSkipUnless(environment["MV_SHOT_DIR"] != nil, "review shots only")
        // `MV_SHOT_COMPANY=keep` leaves the app alone: for text sizes where the app's own
        // companion page is not the subject (start company at Large, then change the size).
        if environment["MV_SHOT_COMPANY"] != "keep" {
            let app = launchApp()
            if environment["MV_SHOT_COMPANY"] == "1" {
                startCompany(app, mood: environment["MV_SHOT_MOOD"] ?? "在观察")
            } else {
                endCompany(app)
            }
            app.terminate()
        }
        let lock = environment["MV_SHOT_LOCK"] != "0"
        if lock {
            ensureLockWidgets()
            unlock()
        }
        ensureHomeWidgets()
        allowLiveActivities()
        let tinted = environment["MV_SHOT_STYLE"] == "tinted"
        if tinted { setHomeStyle("Tinted", "色调") }
        showHome()
        sleep(3)
        snap("home")
        if tinted { setHomeStyle("Default", "默认") }
        if lock {
            showLockScreen()
            allowLiveActivities()
            XCTAssertTrue(lockCircular.waitForExistence(timeout: 10))
            sleep(2)
            snap("lock")
            unlock()
        }
    }
}
