import XCTest

/// QA, round 12 task C, kept for 1.0: what is shipped on a library that already holds two rooms
/// and two cats (as a restored backup would), the furniture sets and their themes, and the photo
/// pre-alert screen when the system will not ask any more.
final class QAReleaseEntriesUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(store: String, reset: Bool, _ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store] + extra
        if reset { app.launchArguments.append("-MeowverseResetStore") }
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func count(_ app: XCUIApplication, _ id: String) -> Int {
        app.descendants(matching: .any).matching(identifier: id).count
    }

    /// Two rooms and two cats made with the test switch, then opened without it, as 1.0 is: every
    /// one of them is listed, can be switched to, renamed and removed, and nothing offers adding.
    func testALibraryWithTwoRoomsAndTwoCatsStaysUsableWhileHidden() {
        var app = launch(store: "qa-release-multi", reset: true, ["-MeowverseSeveralHomes"])
        XCTAssertTrue(app.buttons["room-switcher"].waitForExistence(timeout: 10))
        let firstName = app.buttons["room-switcher"].label
        app.buttons["open-room-manager"].tap()
        XCTAssertTrue(app.buttons["manager-new-room"].waitForExistence(timeout: 10))
        app.buttons["manager-new-room"].tap()
        let roomAlert = app.alerts["新建房间"]
        XCTAssertTrue(roomAlert.waitForExistence(timeout: 10))
        roomAlert.textFields.firstMatch.typeText("书房")
        roomAlert.buttons["新建"].tap()
        // A new room is shown at once and the page closes.
        XCTAssertTrue(app.showsRoom("书房", timeout: 10))

        app.openCatManager()
        app.buttons["manager-new-cat"].tap()
        let catAlert = app.alerts["添加猫咪"]
        XCTAssertTrue(catAlert.waitForExistence(timeout: 10))
        catAlert.textFields.firstMatch.typeText("Mimi")
        catAlert.buttons["添加"].tap()
        let twoCats = NSPredicate(format: "count == 2")
        wait(for: [expectation(for: twoCats, evaluatedWith: app.descendants(matching: .any).matching(identifier: "cat-row"))], timeout: 10)
        app.buttons["close-home"].tap()
        app.terminate()

        app = launch(store: "qa-release-multi", reset: false, [])
        XCTAssertEqual(app.buttons["open-room-manager"].label, "房间管理")
        XCTAssertEqual(app.buttons["open-cat-manager"].label, "猫咪管理")

        // The switcher lists both rooms and switches between them.
        let switcher = app.buttons["room-switcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        let current = switcher.label
        XCTAssertTrue([firstName, "书房"].contains(current), current)
        let target = current == "书房" ? firstName : "书房"
        switcher.tap()
        let item = app.buttons.matching(NSPredicate(format: "label == %@", target)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the other room is in the switcher")
        XCTAssertFalse(app.buttons["new-room"].exists, "no 新建房间")
        snap("qa-release-switcher-two-rooms")
        item.tap()
        XCTAssertTrue(app.showsRoom(target, timeout: 10), "switching still works")

        // Both rooms are in 房间管理, without 新建房间; the second can still be removed.
        app.buttons["open-room-manager"].tap()
        XCTAssertTrue(element(app, "home-manager").waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "room-row").count, 2)
        XCTAssertFalse(app.buttons["manager-new-room"].exists)
        snap("qa-release-room-manager-two-rooms")
        XCTAssertGreaterThan(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "第一个房间不能删除")).count, 0,
                             "with two rooms the page still says what deleting does")
        let menus = app.buttons.matching(identifier: "room-row-menu")
        XCTAssertEqual(menus.count, 2)
        let secondRoom = app.buttons.matching(identifier: "room-row").element(boundBy: 1)
        rename(app, menu: menus.element(boundBy: 1), button: "rename-room", to: "Den")
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS 'Den'"), evaluatedWith: secondRoom)], timeout: 10)
        menus.element(boundBy: 1).tap()
        let remove = app.buttons["remove-room"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "the second room can be removed")
        remove.tap()
        let confirm = app.alerts.buttons["删除房间"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let oneRoom = NSPredicate(format: "count == 1")
        wait(for: [expectation(for: oneRoom, evaluatedWith: app.buttons.matching(identifier: "room-row"))], timeout: 10)
        XCTAssertFalse(app.buttons["manager-new-room"].exists, "still no 新建房间 with one room left")
        app.buttons["close-home"].tap()

        // Both cats are in 猫咪管理, without 添加猫咪; the second can be removed.
        app.openCatManager()
        XCTAssertEqual(count(app, "cat-row"), 2)
        XCTAssertFalse(app.buttons["manager-new-cat"].exists)
        snap("qa-release-cat-manager-two-cats")
        let catMenus = app.buttons.matching(identifier: "cat-row-menu")
        let secondCat = app.descendants(matching: .any).matching(identifier: "cat-row").element(boundBy: 1)
        rename(app, menu: catMenus.element(boundBy: 1), button: "rename-cat", to: "Nori")
        wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH 'Nori'"), evaluatedWith: secondCat)], timeout: 10)
        catMenus.element(boundBy: 1).tap()
        let removeCat = app.buttons["remove-cat"]
        XCTAssertTrue(removeCat.waitForExistence(timeout: 5))
        removeCat.tap()
        let confirmCat = app.alerts.buttons["移除猫咪"]
        XCTAssertTrue(confirmCat.waitForExistence(timeout: 5))
        confirmCat.tap()
        wait(for: [expectation(for: oneRoom, evaluatedWith: app.descendants(matching: .any).matching(identifier: "cat-row"))], timeout: 10)
        XCTAssertFalse(app.buttons["manager-new-cat"].exists)
        app.buttons["close-home"].tap()
    }

    private func rename(_ app: XCUIApplication, menu: XCUIElement, button id: String, to name: String) {
        menu.tap()
        let button = app.buttons[id].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), id)
        button.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), id)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10) + name)
        app.alerts.buttons["保存"].firstMatch.tap()
    }

    /// The three sets are free in 1.0: all 36 pieces can be picked and each set's theme can be
    /// saved, with no lock and nothing asked on the way.
    func testTheFurnitureSetsAndTheirThemesAreFree() {
        let app = launch(store: "qa-free-sets", reset: true, ["-MeowverseReleaseEntries"])
        for theme in ["gilded-palace", "jiangnan-study", "sakura-tatami"] {
            app.buttons["open-room-appearance"].tap()
            XCTAssertTrue(app.buttons["save-room-appearance"].waitForExistence(timeout: 10))
            let chip = app.buttons["room-theme-" + theme]
            app.scrollThemeTray(to: chip)
            XCTAssertTrue(chip.isEnabled, theme)
            chip.tap()
            XCTAssertTrue(chip.isSelected, theme)
            app.buttons["save-room-appearance"].tap()
            XCTAssertTrue(app.buttons["open-room-appearance"].waitForExistence(timeout: 10), "\(theme) is saved at once")
        }

        app.buttons["place-furniture-first"].tap()
        let sets = [("chair", "chair", "fgh"), ("table", "table", "def"), ("bed", "bed", "ghi"), ("scratcher", "scratcher", "def"),
                    ("catTree", "cat-tree", "def"), ("hideout", "hideout", "efg"), ("toy", "toy", "hij"),
                    ("litterBox", "litter-box", "def"), ("water", "water", "efg"), ("bookcase", "bookcase", "def"),
                    ("floorLamp", "floor-lamp", "def"), ("sofa", "sofa", "efg")]
        XCTAssertEqual(sets.map(\.2.count).reduce(0, +), 36)
        for (index, (category, stem, letters)) in sets.enumerated() {
            reveal(app, "manual-" + category).tap()
            app.buttons["next-model"].tap()
            XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10), category)
            for letter in letters {
                let piece = app.buttons["model-mv-\(stem)-\(letter)"]
                XCTAssertTrue(piece.exists && piece.isEnabled, piece.identifier + " \(category) \(letter)")
                XCTAssertFalse(piece.label.contains("完整版"), piece.label)
            }
            if index < sets.count - 1 {
                app.navigationBars.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(app.buttons["next-model"].waitForExistence(timeout: 10))
            }
        }
        // One of them all the way into the room.
        reveal(app, "model-mv-sofa-e").tap()
        app.buttons["next-placement"].tap()
        let confirm = app.buttons["confirm-placement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["place-furniture-first"].waitForNonExistence(timeout: 10), "the set piece is in the room")
    }

    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let target = app.buttons[id]
        _ = target.waitForExistence(timeout: 5)
        for _ in 0..<10 where !(target.exists && target.isHittable) { app.swipeUp(velocity: .slow) }
        for _ in 0..<10 where !(target.exists && target.isHittable) { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(target.exists && target.isHittable, id)
        return target
    }

    /// The user turned 从相册读取大图 on in Settings first and refused the system alert. The first
    /// 添加照片 then still shows the pre-alert screen, whose button says the system will ask.
    /// Records what happens: whether a system alert really follows 继续.
    func testThePreAlertScreenAfterARefusalInSettings() {
        XCUIApplication().resetAuthorizationStatus(for: .photos)
        addTeardownBlock { XCUIApplication().resetAuthorizationStatus(for: .photos) }
        let app = launch(store: "qa-intro-after-settings", reset: true,
                         ["-MeowverseLibraryIntro", "-photoLibraryLinkWanted", "<false/>"])
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 10))
        let toggle = element(app, "library-link-toggle")
        for _ in 0..<8 where !(toggle.exists && toggle.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(toggle.isHittable)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let deny = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow", "不允许"])).firstMatch
        XCTAssertTrue(deny.waitForExistence(timeout: 10), "the switch asks the system")
        deny.tap()
        let refusedAlert = app.alerts["没有拿到相册权限"]
        if refusedAlert.waitForExistence(timeout: 5) { refusedAlert.buttons["好"].tap() }
        app.buttons["close-settings"].tap()

        app.buttons["add-photo"].tap()
        let next = app.buttons["library-intro-continue"]
        let shown = next.waitForExistence(timeout: 10)
        snap("qa-intro-after-settings-refusal")
        XCTAssertFalse(shown, "the pre-alert screen shows although no system alert can follow")
    }

    /// 继续, then 「限制访问…」 in the system alert: the screen says full access was not given and
    /// its one button goes on to the picker.
    func testLimitedAccessIsSaidAndContinueStillPicks() {
        XCUIApplication().resetAuthorizationStatus(for: .photos)
        addTeardownBlock { XCUIApplication().resetAuthorizationStatus(for: .photos) }
        let app = launch(store: "qa-intro-limited", reset: true,
                         ["-MeowverseLibraryIntro", "-photoLibraryLinkWanted", "<false/>"])
        app.buttons["add-photo"].tap()
        let next = app.buttons["library-intro-continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        // iOS 27.2 titles it “Select Photos”; the identifier is stable across languages.
        let limit = springboard.alerts.buttons["kTCCServicePhotos-limited-button"].firstMatch
        XCTAssertTrue(limit.waitForExistence(timeout: 10), springboard.debugDescription)
        limit.tap()
        // iOS then lets the user pick which photos; take whatever is offered and finish.
        // On a fresh simulator the picker loads for minutes; its confirm button is a checkmark.
        let done = NSPredicate(format: "(label IN %@) AND identifier != %@",
                               ["Done", "完成", "Confirm", "确认", "Add", "添加"], "library-intro-continue")
        let deadline = Date().addingTimeInterval(300)
        var tapped = false
        while !tapped, Date() < deadline {
            for source in [app as XCUIApplication, springboard] {
                let button = source.buttons.matching(done).firstMatch
                if button.exists, button.isHittable { snap("qa-limited-picker"); button.tap(); tapped = true; break }
            }
            if !tapped { sleep(3) }
        }
        XCTAssertTrue(tapped, "the limited-library picker could be confirmed")
        XCTAssertTrue(element(app, "library-intro-refused").waitForExistence(timeout: 15), app.debugDescription)
        snap("qa-intro-limited")
        let close = app.buttons["library-intro-done"]
        XCTAssertTrue(close.exists)
        XCTAssertFalse(next.exists, "one button only")
        close.tap()
        XCTAssertFalse(close.waitForExistence(timeout: 3) && close.isHittable, "the explanation closed")
    }

    /// Run with `-configuration Release`: no test switch is read there, so this sees the real
    /// release condition on the device's own library. Rooms and Cats carry no lock, their pages
    /// offer no adding, the switcher offers no 新建房间, and 「导入猫咪模型…」 is gone.
    func testTheReleaseConfigurationItself() {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        // First launch: the tour's welcome card covers the room (Release has the tour, test
        // libraries don't); 全部跳过 puts it away. There is no reminder page at first launch.
        let later = app.buttons["tour-card-later"].firstMatch
        XCTAssertTrue(later.waitForExistence(timeout: 20), "the welcome card")
        later.tap()
        XCTAssertTrue(later.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["open-room-manager"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["open-room-manager"].label, "房间管理")
        XCTAssertEqual(app.buttons["open-cat-manager"].label, "猫咪管理")
        app.buttons["room-switcher"].tap()
        sleep(1)
        XCTAssertFalse(app.buttons["new-room"].exists)
        snap("qa-release-config-switcher")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).tap()
        app.buttons["open-room-manager"].tap()
        XCTAssertTrue(element(app, "home-manager").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["manager-new-room"].exists)
        snap("qa-release-config-rooms")
        app.buttons["close-home"].tap()
        app.openCatManager()
        XCTAssertFalse(app.buttons["manager-new-cat"].exists)
        for _ in 0..<4 { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(app.buttons["cat-pack-bella"].exists, "the model card is there")
        XCTAssertFalse(app.buttons["import-cat-pack"].exists)
        snap("qa-release-config-cats")
        app.buttons["close-home"].tap()

        // 设置 as shipped: 用爱发电 is the first section, and 画质 (merged after 1.0's hiding)
        // offers its four choices and leads nowhere else.
        app.tapSettingsGear()
        let note = element(app, "settings-labour-of-love")
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        XCTAssertLessThan(element(app, "settings-github").frame.maxY, element(app, "open-cats-from-settings").frame.minY,
                          "the first section")
        let quality = app.buttons["open-render-quality"]
        for _ in 0..<12 where !(quality.exists && quality.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(quality.exists && quality.isHittable, "the 画质 row")
        snap("qa-release-config-settings-quality")
        quality.tap()
        for choice in ["auto", "high", "medium", "low"] {
            XCTAssertTrue(app.buttons["render-quality-" + choice].waitForExistence(timeout: 5), choice)
        }
        XCTAssertTrue(app.buttons["render-quality-auto"].isSelected, "自动 by default")
        snap("qa-release-config-quality-page")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["close-settings"].tap()
    }
}
