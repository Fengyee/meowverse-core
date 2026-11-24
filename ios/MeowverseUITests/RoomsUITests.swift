import XCTest

/// Several rooms and cats are hidden in 1.0 and refused at the action. With
/// `-MeowverseSeveralHomes` rooms are made, switched, kept across launches, furniture moves
/// between them, and removing a room puts its furniture away.
final class RoomsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(reset: Bool, store: String, severalHomes: Bool, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseSyntheticPhoto"] + extra
        if severalHomes { app.launchArguments.append("-MeowverseSeveralHomes") }
        if reset { app.launchArguments.append("-MeowverseResetStore") }
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 20))
        return app
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Catalog flow without a photo, from the empty room, saved at the first free spot.
    private func placeSofa(_ app: XCUIApplication) {
        let start = app.buttons["place-furniture-first"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 10))
        sofa.tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 15))
    }

    private var hotspots: NSPredicate { NSPredicate(format: "label CONTAINS %@", "打开这件家具") }

    func testAddingRoomsAndCatsIsHidden() {
        let app = launch(reset: true, store: "rooms-hidden", severalHomes: false)
        let switcher = app.buttons["room-switcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        let room = switcher.label
        switcher.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", room)).element(boundBy: 1).waitForExistence(timeout: 5),
                      "the menu is open and lists the room")
        XCTAssertFalse(app.buttons["new-room"].exists)
        XCTAssertFalse(app.buttons["open-home"].exists, "managing rooms and cats moved to the top band")
        sleep(1); snap("K1-switcher")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).tap()

        app.buttons["open-room-manager"].tap()
        XCTAssertTrue(app.buttons["room-row"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "room-row").count, 1)
        XCTAssertFalse(app.buttons["manager-new-room"].exists)
        assertNoPromise(app)
        sleep(1); snap("K2-rooms-page")
        app.buttons["close-home"].tap()

        openCats(app)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "cat-row").count, 1)
        XCTAssertFalse(app.buttons["manager-new-cat"].exists)
        assertNoPromise(app)
        sleep(1); snap("K3-cats-page")
        app.buttons["close-home"].tap()
    }

    /// Whoever calls `addRoom` or `addCat` is refused, not only the pages that hide their rows:
    /// the drill calls both as a quick action, an intent or a link would. With the switch the
    /// same drill makes both, so the refusal is the guard's; without it again, nothing is added
    /// to a library that already has two.
    func testAddingIsRefusedAtTheActionWhileHidden() {
        let drill = ["-MeowverseAddHomesDrill"]
        for (reset, severalHomes, homes) in [(true, false, 1), (false, true, 2), (false, false, 2)] {
            let app = launch(reset: reset, store: "rooms-refused", severalHomes: severalHomes, extra: drill)
            let report = app.alerts.firstMatch
            XCTAssertTrue(report.waitForExistence(timeout: 20), "the drill ran")
            let words = report.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
            for refusal in ["这个版本不能新建房间。", "这个版本不能添加猫咪。"] {
                XCTAssertEqual(words.contains(refusal), !severalHomes, words)
            }
            report.buttons.firstMatch.tap()
            XCTAssertTrue(report.waitForNonExistence(timeout: 10))

            app.buttons["open-room-manager"].tap()
            XCTAssertTrue(app.buttons["room-row"].firstMatch.waitForExistence(timeout: 10))
            XCTAssertEqual(app.buttons.matching(identifier: "room-row").count, homes, "rooms, switch: \(severalHomes)")
            app.buttons["close-home"].tap()
            openCats(app)
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "cat-row").count, homes, "cats, switch: \(severalHomes)")
            app.terminate()
        }
    }

    /// No lock, no paid wording, no count of rooms or cats to look forward to.
    private func assertNoPromise(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for words in ["完整版", "个房间，", "只猫咪。", "住在一个房间"] {
            let said = NSPredicate(format: "label CONTAINS %@", words)
            XCTAssertEqual(app.staticTexts.matching(said).count + app.buttons.matching(said).count, 0, words, file: file, line: line)
        }
    }

    private func openCats(_ app: XCUIApplication) {
        let button = app.buttons["open-cat-manager"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        XCTAssertTrue(app.staticTexts["猫咪管理"].waitForExistence(timeout: 10))
    }

    /// A menu item found by what it says (menu items do not always carry identifiers).
    private func menuItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == ''", label)).firstMatch
    }

    func testSecondCatSharesTheRoomCanLiveElsewhereAndBeRemoved() {
        let app = launch(reset: true, store: "cats", severalHomes: true)
        placeSofa(app)
        let firstRoom = app.buttons["room-switcher"].label
        let world = element(app, "room-world")

        // A second cat joins the room on screen.
        openCats(app)
        app.buttons["manager-new-cat"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("团子")
        app.alerts.buttons["添加"].tap()
        let cats = app.descendants(matching: .any).matching(identifier: "cat-row")
        wait(for: [expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: cats)], timeout: 10)
        XCTAssertTrue(cats.element(boundBy: 1).label.contains("团子"), cats.element(boundBy: 1).label)
        XCTAssertTrue(cats.element(boundBy: 1).label.contains("跟着你"), cats.element(boundBy: 1).label)
        sleep(1); snap("C1-two-cats-listed")
        app.buttons["close-home"].tap()
        XCTAssertTrue(world.waitForExistence(timeout: 10))
        XCTAssertTrue((world.value as? String)?.contains("团子") == true, "\(String(describing: world.value))")
        sleep(8); snap("C2-two-cats-in-the-room")
        sleep(8); snap("C3-two-cats-later")

        // A second room: both cats keep you company there until one is told where to live.
        app.buttons["room-switcher"].tap()
        app.buttons["new-room"].tap()
        let roomField = app.alerts.textFields.firstMatch
        XCTAssertTrue(roomField.waitForExistence(timeout: 10))
        roomField.typeText("书房")
        app.alerts.buttons["新建"].tap()
        XCTAssertTrue(app.showsRoom("书房", timeout: 10))
        XCTAssertTrue((world.value as? String)?.contains("团子") == true)
        openCats(app)
        app.buttons.matching(identifier: "cat-row-menu").element(boundBy: 1).tap()
        let first = menuItem(app, firstRoom)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS '住在'"), evaluatedWith: cats.element(boundBy: 1))], timeout: 10)
        sleep(1); snap("C4-cat-lives-in-first-room")
        app.buttons["close-home"].tap()
        XCTAssertFalse((world.value as? String)?.contains("团子") == true, "the second cat stays in the first room")

        // The first cat too: nobody is in the study, and there is nobody to play with.
        openCats(app)
        app.buttons.matching(identifier: "cat-row-menu").element(boundBy: 0).tap()
        let again = menuItem(app, firstRoom)
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        again.tap()
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS '住在'"), evaluatedWith: cats.element(boundBy: 0))], timeout: 10)
        app.buttons["close-home"].tap()
        XCTAssertTrue(app.staticTexts["这个房间里现在没有猫咪"].waitForExistence(timeout: 10))
        sleep(2); snap("C5-room-without-cats")
        // With no cat here, 互动 offers only keeping you company, and says what comes later.
        XCTAssertTrue(app.buttons["choose-interaction"].isEnabled)
        app.buttons["choose-interaction"].tap()
        XCTAssertTrue(app.buttons["choose-pocket-cat"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["猫咪搬进来以后，这里还能玩玩具、喂零食。"].exists)
        XCTAssertFalse(app.buttons["choose-toy"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ground-gait-'")).firstMatch.exists)
        app.buttons["choose-pocket-cat"].tap()
        let pocket = app.navigationBars["陪我一会儿"]
        XCTAssertTrue(pocket.waitForExistence(timeout: 10))
        pocket.buttons.firstMatch.tap()
        app.navigationBars.buttons["取消"].tap()

        // Back in the first room both are there; removing the second leaves one.
        app.buttons["room-switcher"].tap()
        let home = menuItem(app, firstRoom)
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        XCTAssertTrue(app.showsRoom(firstRoom, timeout: 10))
        XCTAssertTrue((world.value as? String)?.contains("团子") == true)
        XCTAssertTrue(app.buttons["choose-interaction"].isEnabled)
        openCats(app)
        app.buttons.matching(identifier: "cat-row-menu").element(boundBy: 1).tap()
        app.buttons["remove-cat"].tap()
        let confirm = app.alerts.buttons["移除猫咪"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        wait(for: [expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: cats)], timeout: 10)
        app.buttons["close-home"].tap()
        XCTAssertFalse((world.value as? String)?.contains("团子") == true)
    }

    func testRoomsSwitchMoveFurnitureAndRemoveARoom() {
        var app = launch(reset: true, store: "rooms", severalHomes: true)
        placeSofa(app)
        let firstTitle = app.buttons["room-switcher"].label

        // A second room starts empty and has its own floor.
        app.buttons["room-switcher"].tap()
        app.buttons["new-room"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("书房")
        app.alerts.buttons["新建"].tap()
        XCTAssertTrue(app.showsRoom("书房", timeout: 10))
        XCTAssertTrue(app.buttons["place-furniture-first"].waitForExistence(timeout: 10))
        sleep(2); snap("R1-new-room-empty")
        placeSofa(app)
        sleep(2); snap("R2-new-room-sofa")

        // The library lists both pieces and says which room each is in.
        app.buttons["furniture-list"].tap()
        let rows = app.buttons.matching(identifier: "list-room-item")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(app.staticTexts["各个房间里共 2 件"].exists)
        let inStudy = rows.matching(NSPredicate(format: "label CONTAINS %@", "书房"))
        XCTAssertEqual(inStudy.count, 1)
        sleep(1); snap("R3-library-two-rooms")

        // The piece in the study moves to the first room, and the screen follows it.
        inStudy.firstMatch.tap()
        XCTAssertTrue(app.buttons["furniture-more"].waitForExistence(timeout: 10))
        app.buttons["furniture-more"].tap()
        // A submenu and its items do not carry identifiers: found by what they say.
        app.buttons["搬到另一个房间"].tap()
        let option = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != 'room-switcher'", firstTitle)).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        XCTAssertTrue(app.showsRoom(firstTitle, timeout: 15))
        // (The "it is here" notice lasts three seconds while the new room's scene loads; not asserted.)
        snap("R4-moved-and-located")
        XCTAssertTrue(app.descendants(matching: .any)["room-world"].label.contains("2 件家具"))
        app.buttons["furniture-list"].tap()
        XCTAssertTrue(app.staticTexts["各个房间里共 2 件"].waitForExistence(timeout: 10))
        XCTAssertEqual(rows.matching(NSPredicate(format: "label CONTAINS %@", "书房")).count, 0)
        app.buttons["close-furniture-list"].tap()

        // The room on screen is remembered across launches.
        app.buttons["room-switcher"].tap()
        let study = app.buttons.matching(NSPredicate(format: "label == '书房' AND identifier != 'room-switcher'")).firstMatch
        XCTAssertTrue(study.waitForExistence(timeout: 5))
        study.tap()
        XCTAssertTrue(app.showsRoom("书房", timeout: 10))
        XCTAssertTrue(app.buttons["place-furniture-first"].waitForExistence(timeout: 10))
        placeSofa(app)
        app.terminate()
        app = launch(reset: false, store: "rooms", severalHomes: true)
        XCTAssertTrue(app.showsRoom("书房", timeout: 10))

        // Removing the room puts its piece in the storage box and shows the first room.
        app.buttons["open-room-manager"].tap()
        let roomRows = app.buttons.matching(identifier: "room-row")
        XCTAssertTrue(roomRows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(roomRows.count, 2)
        XCTAssertTrue(roomRows.element(boundBy: 0).label.contains("2 件家具"), roomRows.element(boundBy: 0).label)
        XCTAssertTrue(roomRows.element(boundBy: 1).label.contains("1 件家具"), roomRows.element(boundBy: 1).label)
        sleep(1); snap("R5-home")
        app.buttons.matching(identifier: "room-row-menu").element(boundBy: 1).tap()
        app.buttons["remove-room"].tap()
        let confirm = app.alerts.buttons["删除房间"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        sleep(1); snap("R6-remove-room")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["房间管理"].waitForExistence(timeout: 10))
        let gone = NSPredicate(format: "count == 1")
        wait(for: [expectation(for: gone, evaluatedWith: roomRows)], timeout: 10)
        app.buttons["close-home"].tap()
        XCTAssertTrue(app.showsRoom(firstTitle, timeout: 10))
        app.buttons["furniture-list"].tap()
        XCTAssertTrue(app.staticTexts["房间里 2 / 20"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "list-stored-item").count, 1)
        sleep(1); snap("R7-after-remove")
    }
}
