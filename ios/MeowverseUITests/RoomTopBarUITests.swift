import XCTest

/// The room's top bar: the room title still switches rooms, and each of the six buttons opens
/// its own page. Adding a room or a cat is hidden in 1.0 (`-MeowverseSeveralHomes` brings it
/// back for tests); what is already there keeps working.
final class RoomTopBarUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(store: String, severalHomes: Bool = false, reset: Bool = true, language: [String] = TestLanguage.chinese,
                        extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = language + ["-MeowverseStore", store] + extra
        if severalHomes { app.launchArguments.append("-MeowverseSeveralHomes") }
        if reset { app.launchArguments.append("-MeowverseResetStore") }
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 20))
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func tapBar(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "\(id) is in the top bar")
        XCTAssertTrue(button.isHittable, "\(id) can be tapped")
        button.tap()
    }

    func testTheRoomHasNoSystemNavigationBarAndTheTitleStillSwitchesRooms() {
        let app = launch(store: "top-bar")
        XCTAssertFalse(app.buttons["room-menu"].exists, "the old menu is gone")
        let title = app.buttons["room-switcher"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars.firstMatch.exists, "the room draws its own bar")
        for id in ["open-settings", "open-room-appearance", "open-room-sound", "open-room-share", "open-room-manager", "open-cat-manager"] {
            XCTAssertTrue(app.buttons[id].isHittable, "\(id) is in the top bar")
        }
        XCTAssertLessThan(app.buttons["open-settings"].frame.midX, title.frame.minX, "设置 sits left of the title")
        XCTAssertGreaterThan(app.buttons["open-room-share"].frame.midX, title.frame.maxX, "分享 sits right of it")
        let name = title.label
        title.tap()
        let room = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).element(boundBy: 1)
        XCTAssertTrue(room.waitForExistence(timeout: 5), "the switcher lists the room")
        XCTAssertFalse(app.buttons["open-home"].exists, "the switcher no longer manages rooms and cats")
    }

    func testEachButtonOpensItsPage() {
        let app = launch(store: "top-bar")

        tapBar(app, "open-settings")
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 10))
        app.buttons["close-settings"].tap()

        tapBar(app, "open-room-appearance")
        XCTAssertTrue(app.buttons["save-room-appearance"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["open-settings"].exists, "the band steps aside while the room is dressed")
        app.buttons["cancel-room-appearance"].tap()

        tapBar(app, "open-room-sound")
        XCTAssertTrue(app.switches["room-music"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["room-sound-effects"].exists)
        app.buttons["close-room-sound"].tap()

        tapBar(app, "open-room-share")
        XCTAssertTrue(app.buttons["close-room-share"].waitForExistence(timeout: 15))
        app.buttons["close-room-share"].tap()

        tapBar(app, "open-room-manager")
        XCTAssertTrue(element(app, "home-manager").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["room-row"].exists)
        XCTAssertFalse(element(app, "cat-row").exists, "the rooms page shows only rooms")
        app.buttons["close-home"].tap()

        tapBar(app, "open-cat-manager")
        XCTAssertTrue(element(app, "home-manager").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "cat-row").exists)
        XCTAssertFalse(app.buttons["room-row"].exists, "the cats page shows only cats")
        app.buttons["close-home"].tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
    }

    /// 1.0 hides several rooms and cats in every build, a DEBUG one included: no add rows, no
    /// lock and no word about a full version. The pages stay for names and the cat model.
    func testAddingIsHiddenAndNothingLooksLocked() {
        let app = launch(store: "top-bar-hidden")
        XCTAssertEqual(app.buttons["open-room-manager"].label, "房间管理", "no lock is spoken")
        XCTAssertEqual(app.buttons["open-cat-manager"].label, "猫咪管理")
        snap("hidden-band")

        let title = app.buttons["room-switcher"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let name = title.label
        title.tap()
        // The open menu lists the room under the same name as the title.
        let room = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).element(boundBy: 1)
        XCTAssertTrue(room.waitForExistence(timeout: 5), "the switcher still lists the room")
        XCTAssertFalse(app.buttons["new-room"].exists)
        snap("hidden-room-switcher")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).tap()

        tapBar(app, "open-room-manager")
        XCTAssertTrue(element(app, "home-manager").waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "room-row").count, 1, "the room is still listed")
        XCTAssertTrue(app.buttons["room-row-menu"].exists, "renaming stays")
        XCTAssertFalse(app.buttons["manager-new-room"].exists)
        app.buttons["close-home"].tap()

        tapBar(app, "open-cat-manager")
        XCTAssertTrue(element(app, "home-manager").waitForExistence(timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "cat-row").count, 1)
        XCTAssertFalse(app.buttons["manager-new-cat"].exists)
        app.buttons["close-home"].tap()
    }

    /// Importing a cat model is for test and drill builds only, whatever the several-homes switch
    /// says. `-MeowverseReleaseEntries` gives a DEBUG build the release look.
    func testReleaseBuildHidesCatModelImport() {
        for severalHomes in [false, true] {
            let app = launch(store: "top-bar-release", severalHomes: severalHomes, extra: ["-MeowverseReleaseEntries"])
            tapBar(app, "open-cat-manager")
            let bella = app.buttons["cat-pack-bella"]
            XCTAssertTrue(element(app, "home-manager").waitForExistence(timeout: 10))
            for _ in 0..<4 where !(bella.exists && bella.isHittable) { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(bella.exists, "the cat model card is still there")
            XCTAssertFalse(app.buttons["import-cat-pack"].exists, "no 导入猫咪模型… in a release build")
            app.terminate()
        }
    }

    func testSeveralHomesAddingOpensNormally() {
        let app = launch(store: "top-bar-several", severalHomes: true)
        XCTAssertEqual(app.buttons["open-room-manager"].label, "房间管理")
        XCTAssertEqual(app.buttons["open-cat-manager"].label, "猫咪管理")

        tapBar(app, "open-room-manager")
        app.buttons["manager-new-room"].tap()
        XCTAssertTrue(app.alerts["新建房间"].waitForExistence(timeout: 10))
        app.alerts.buttons["取消"].tap()
        app.buttons["close-home"].tap()

        app.buttons["room-switcher"].tap()
        let newRoom = app.buttons["new-room"]
        XCTAssertTrue(newRoom.waitForExistence(timeout: 5))
        newRoom.tap()
        XCTAssertTrue(app.alerts["新建房间"].waitForExistence(timeout: 10))
        app.alerts.buttons["取消"].tap()

        tapBar(app, "open-cat-manager")
        app.buttons["manager-new-cat"].tap()
        XCTAssertTrue(app.alerts["添加猫咪"].waitForExistence(timeout: 10))
        app.alerts.buttons["取消"].tap()
        app.buttons["close-home"].tap()
    }

    /// 音乐音效 is the one place for the two switches (Settings no longer has them). Each switches
    /// on its own, and both keep their values when the panel reopens and across launches.
    func testSoundTogglesPersistAcrossLaunches() {
        // Values an earlier build stored, both the opposite of the defaults, passed in the argument
        // domain: the panel shows them only if it still reads `room.music` and `room.soundEffects`.
        // Plist booleans: `@AppStorage` reads a bare YES as a string and falls back to the default.
        var app = launch(store: "top-bar-sound", extra: ["-room.music", "<true/>", "-room.soundEffects", "<false/>"])
        tapBar(app, "open-room-sound")
        XCTAssertTrue(app.switches["room-music"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.switches["room-music"].value as? String, "1", "music is read from room.music")
        XCTAssertEqual(app.switches["room-sound-effects"].value as? String, "0", "effects are read from room.soundEffects")
        app.terminate()

        app = launch(store: "top-bar-sound", reset: false)
        tapBar(app, "open-room-sound")
        var music = app.switches["room-music"], effects = app.switches["room-sound-effects"]
        XCTAssertTrue(music.waitForExistence(timeout: 10))
        let wasMusic = music.value as? String, wasEffects = effects.value as? String
        XCTAssertNotNil(wasMusic)
        XCTAssertNotNil(wasEffects)
        music.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertNotEqual(music.value as? String, wasMusic)
        XCTAssertEqual(effects.value as? String, wasEffects, "music switches on its own")
        effects.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertNotEqual(effects.value as? String, wasEffects)
        app.buttons["close-room-sound"].tap()

        // Reopened, the panel shows what was chosen.
        tapBar(app, "open-room-sound")
        XCTAssertTrue(music.waitForExistence(timeout: 10))
        XCTAssertNotEqual(music.value as? String, wasMusic, "music kept when the panel reopens")
        XCTAssertNotEqual(effects.value as? String, wasEffects, "effects kept when the panel reopens")
        app.buttons["close-room-sound"].tap()

        app.terminate()
        app = launch(store: "top-bar-sound", reset: false)
        tapBar(app, "open-room-sound")
        music = app.switches["room-music"]
        effects = app.switches["room-sound-effects"]
        XCTAssertTrue(music.waitForExistence(timeout: 10))
        XCTAssertNotEqual(music.value as? String, wasMusic, "music kept across launches")
        XCTAssertNotEqual(effects.value as? String, wasEffects, "effects kept across launches")

        // Leave them as they were for the next run.
        music.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        effects.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(music.value as? String, wasMusic)
        XCTAssertEqual(effects.value as? String, wasEffects)
        app.buttons["close-room-sound"].tap()

        // Settings has no second copy of the switches. Its list is lazy: scroll to 提醒, where
        // the old section sat, before looking.
        tapBar(app, "open-settings")
        let reminders = app.buttons["open-reminders"]
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 10))
        for _ in 0..<8 where !(reminders.exists && reminders.isHittable) { app.swipeUp() }
        XCTAssertTrue(reminders.isHittable)
        XCTAssertFalse(app.switches["room-music"].exists, "the music switch is only in 音乐音效")
        XCTAssertFalse(app.switches["room-sound-effects"].exists, "the effects switch is only in 音乐音效")
        app.buttons["close-settings"].tap()
    }

    func testTheBandStepsAsideWhileAPieceIsBeingEdited() {
        let app = launch(store: "top-bar-edit")
        let start = app.buttons["place-furniture-first"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        app.buttons["manual-sofa"].tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        let confirm = app.buttons["confirm-placement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 15))
        let world = element(app, "room-world")
        let placed = NSPredicate(format: "label CONTAINS %@", "1 件家具")
        wait(for: [expectation(for: placed, evaluatedWith: world)], timeout: 15)

        let piece = world.buttons.matching(NSPredicate(format: "label CONTAINS %@", "还没有照片")).firstMatch
        XCTAssertTrue(piece.waitForExistence(timeout: 10))
        piece.press(forDuration: 1.2)
        XCTAssertTrue(element(app, "edit-tray").waitForExistence(timeout: 10))
        for id in ["open-settings", "open-room-share", "open-room-manager", "room-switcher"] {
            XCTAssertFalse(app.buttons[id].exists, "\(id) steps aside until the edit ends")
        }
        app.buttons["edit-cancel"].tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["open-settings"].isEnabled)
    }

    /// While playing, the band stays; what would change the room or its cats waits.
    func testDuringPlayOnlyTheRoomChangingTokensWait() {
        let app = launch(store: "top-bar-play", severalHomes: true)
        app.buttons["choose-interaction"].tap()
        app.buttons["choose-toy"].tap()
        let picker = app.collectionViews.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let option = app.buttons["play-item-toyBall"]
        for _ in 0..<5 where !option.exists || !option.isHittable { picker.swipeUp() }
        option.tap()
        XCTAssertTrue(app.buttons["place-play-item"].waitForExistence(timeout: 10))
        for id in ["open-room-appearance", "open-room-manager", "room-switcher"] {
            XCTAssertTrue(app.buttons[id].exists, id)
            XCTAssertFalse(app.buttons[id].isEnabled, "\(id) waits until play ends")
        }
        for id in ["open-settings", "open-room-sound", "open-room-share", "open-cat-manager"] {
            XCTAssertTrue(app.buttons[id].isEnabled, "\(id) still works while playing")
        }
        // 猫咪管理 opens for names and the cat model (which 设置 offered mid-play before round
        // 10); adding a cat waits.
        app.buttons["open-cat-manager"].tap()
        XCTAssertTrue(element(app, "cats-wait-for-play").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["manager-new-cat"].isEnabled, "adding a cat waits until play ends")
        XCTAssertTrue(app.buttons.matching(identifier: "cat-row-menu").firstMatch.isEnabled, "renaming does not wait")
        sleep(1)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "cats-during-play"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["close-home"].tap()
        app.buttons["end-play"].tap()
        XCTAssertTrue(app.buttons["open-room-manager"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["open-room-manager"].isEnabled)
    }

    /// 走路方式 moved from the old menu to the bottom of the 互动 panel; the choice is kept.
    func testWalkingStyleIsChosenInTheInteractionPanelAndKept() {
        var app = launch(store: "top-bar-gait", language: TestLanguage.current)
        app.selectGroundGait(AppText.string("蹦跳"))
        app.terminate()
        app = launch(store: "top-bar-gait", reset: false, language: TestLanguage.current)
        app.buttons["choose-interaction"].tap()
        let chip = app.buttons["ground-gait-ground_jump"]
        XCTAssertTrue(app.buttons["choose-toy"].waitForExistence(timeout: 10))
        for _ in 0..<10 where !(chip.exists && chip.isHittable) { app.swipeUp() }
        XCTAssertTrue(chip.isSelected, "the walking style is kept across launches")
        // One row per gait, each across the list: four chips in one row squeezed the names into
        // columns of single characters (build 4).
        let rows = ["ground_walk", "graceful_walk", "ground_run", "ground_jump"].map { app.buttons["ground-gait-\($0)"] }
        let width = app.windows.firstMatch.frame.width
        for (above, below) in zip(rows, rows.dropFirst()) {
            XCTAssertGreaterThanOrEqual(below.frame.minY, above.frame.maxY - 1, "\(below.identifier) is a row of its own")
        }
        for row in rows { XCTAssertGreaterThan(row.frame.width, width * 0.6, "\(row.identifier) spans the list") }
        XCTAssertEqual(rows.filter(\.isSelected).count, 1, "one walking style is chosen")
        app.navigationBars.buttons["close-interaction"].tap()
        app.selectGroundGait(AppText.string("散步"))
    }
}

// MARK: - QA round 10: 猫咪管理 during play with two cats and two rooms

extension RoomTopBarUITests {
    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testQADuringPlayCatManagerLocksMovesAndRemovals() {
        let app = launch(store: "qa-cats-play", severalHomes: true)
        // A second room, then back to the first; a second cat.
        let firstRoom = app.buttons["room-switcher"].label
        app.buttons["room-switcher"].tap()
        app.buttons["new-room"].tap()
        let roomField = app.alerts.textFields.firstMatch
        XCTAssertTrue(roomField.waitForExistence(timeout: 10))
        roomField.typeText("书房")
        app.alerts.buttons["新建"].tap()
        XCTAssertTrue(app.showsRoom("书房", timeout: 10))
        app.openCatManager()
        app.buttons["manager-new-cat"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("团子")
        app.alerts.buttons["添加"].tap()
        let cats = app.descendants(matching: .any).matching(identifier: "cat-row")
        wait(for: [expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: cats)], timeout: 10)
        app.buttons["close-home"].tap()
        print("QA first room: \(firstRoom)")

        // Play.
        app.buttons["choose-interaction"].tap()
        app.buttons["choose-toy"].tap()
        let picker = app.collectionViews.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let option = app.buttons["play-item-toyBall"]
        for _ in 0..<5 where !option.exists || !option.isHittable { picker.swipeUp() }
        option.tap()
        XCTAssertTrue(app.buttons["place-play-item"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["open-room-manager"].isEnabled)

        app.buttons["open-cat-manager"].tap()
        XCTAssertTrue(element(app, "cats-wait-for-play").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["manager-new-cat"].isEnabled)
        app.buttons.matching(identifier: "cat-row-menu").element(boundBy: 1).tap()
        let remove = app.buttons["remove-cat"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        let study = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == ''", "书房")).firstMatch
        let follow = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == ''", "跟着你")).firstMatch
        sleep(1); snap("QA6-cat-menu-during-play")
        print("QA during play: remove.enabled=\(remove.isEnabled) study.exists=\(study.exists) study.enabled=\(study.isEnabled) follow.enabled=\(follow.isEnabled)")
        XCTAssertFalse(remove.isEnabled, "removing a cat waits")
        XCTAssertTrue(study.exists)
        XCTAssertFalse(study.isEnabled, "moving a cat waits")
        // Try it anyway: nothing may change.
        if study.isHittable { study.tap() }
        sleep(1)
        if remove.exists, remove.isHittable { remove.tap() }
        sleep(1)
        XCTAssertFalse(app.alerts.buttons["移除猫咪"].exists, "no removal dialog during play")
        if app.alerts.count > 0 { app.alerts.buttons["取消"].firstMatch.tap() }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        sleep(1)
        XCTAssertTrue(cats.element(boundBy: 1).label.contains("跟着你"), cats.element(boundBy: 1).label)

        // Renaming mid-play works and play goes on.
        let menu = app.buttons.matching(identifier: "cat-row-menu").element(boundBy: 1)
        menu.tap()
        app.buttons["rename-cat"].firstMatch.tap()
        let nameField = app.alerts.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        nameField.typeText("麻薯")
        app.alerts.buttons["保存"].firstMatch.tap()
        wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH '麻薯'"), evaluatedWith: cats.element(boundBy: 1))], timeout: 10)
        app.buttons["close-home"].tap()
        XCTAssertTrue(app.buttons["place-play-item"].waitForExistence(timeout: 5) || app.buttons["end-play"].exists, "still playing after the rename")
        XCTAssertFalse(app.buttons["open-room-manager"].isEnabled, "still playing")
        sleep(1); snap("QA7-still-playing")

        // After play, they are back.
        app.buttons["end-play"].tap()
        XCTAssertTrue(app.buttons["open-room-manager"].waitForExistence(timeout: 5))
        app.openCatManager()
        XCTAssertFalse(element(app, "cats-wait-for-play").exists)
        XCTAssertTrue(app.buttons["manager-new-cat"].isEnabled)
        app.buttons.matching(identifier: "cat-row-menu").element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["remove-cat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["remove-cat"].isEnabled)
    }
}

// MARK: - QA round 2: 设置's cats row during play, and 完成 afterwards opens nothing

extension RoomTopBarUITests {
    func testQASettingsCatsRowDuringPlay() {
        let app = launch(store: "qa-settings-row-play")
        app.buttons["choose-interaction"].tap()
        app.buttons["choose-toy"].tap()
        let picker = app.collectionViews.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let option = app.buttons["play-item-toyBall"]
        for _ in 0..<5 where !option.exists || !option.isHittable { picker.swipeUp() }
        option.tap()
        XCTAssertTrue(app.buttons["place-play-item"].waitForExistence(timeout: 10))
        app.buttons["open-settings"].tap()
        let row = app.buttons["open-cats-from-settings"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(element(app, "home-manager").waitForExistence(timeout: 10), "猫咪管理 opens mid-play")
        XCTAssertFalse(element(app, "cats-wait-for-play").exists, "one room and one cat: nothing in it waits for play")
        app.buttons["close-home"].tap()
        XCTAssertFalse(app.buttons["open-room-manager"].isEnabled, "still playing")
        app.buttons["open-settings"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        app.buttons["close-settings"].tap()
        sleep(2)
        XCTAssertFalse(element(app, "home-manager").exists, "完成 opens nothing")
        // Swipe the sheet down this time.
        app.buttons["open-settings"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        app.swipeDown(velocity: .fast)
        sleep(2)
        XCTAssertFalse(element(app, "home-manager").exists, "swiping 设置 away opens nothing")
    }
}
