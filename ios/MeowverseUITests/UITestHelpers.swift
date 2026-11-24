import XCTest

extension XCUIElement {
    /// Replaces what a text field holds with `text`, then presses Return.
    ///
    /// A tap leaves the caret where the tap lands, which may be inside the old text (on an
    /// iPhone 18 Pro simulator it stopped after the second character of 「拉扣软包沙发」).
    /// Deleting from there leaves the rest behind, so the caret goes to the right end first,
    /// and the field must be empty (or show its placeholder) before anything is typed.
    func replaceText(with text: String, file: StaticString = #filePath, line: UInt = #line) {
        tap()
        for _ in 0..<3 {
            let current = value as? String ?? ""
            if current.isEmpty || current == placeholderValue { break }
            coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        let cleared = value as? String ?? ""
        XCTAssertTrue(cleared.isEmpty || cleared == placeholderValue, "the old text stayed: \(cleared)", file: file, line: line)
        typeText(text + "\n")
    }
}

extension XCUIApplication {
    /// Whether the room on screen is `name`, read from the title in the room's top bar. The room
    /// has no system navigation bar, so `navigationBars[name]` no longer finds it.
    func showsRoom(_ name: String, timeout: TimeInterval) -> Bool {
        let named = NSPredicate(format: "label == %@", name)
        let title = buttons["room-switcher"]
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: named, object: title)], timeout: timeout) == .completed
    }
}

extension XCUIApplication {
    /// 猫咪管理 from the room's top band. Since round 10 it holds everything about the cats:
    /// their names and the cat model (设置 only points to it).
    func openCatManager(file: StaticString = #filePath, line: UInt = #line) {
        let button = buttons["open-cat-manager"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), file: file, line: line)
        button.tap()
        XCTAssertTrue(descendants(matching: .any)["home-manager"].waitForExistence(timeout: 10), file: file, line: line)
    }

    /// Chooses a built-in cat model in an open 猫咪管理: her tile opens her character card, and only
    /// its 就选它 chooses her. Waits until her tile is selected and the card has closed.
    func chooseBuiltInCat(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let tile = buttons["cat-pack-" + id]
        XCTAssertTrue(tile.waitForExistence(timeout: 10), id, file: file, line: line)
        for _ in 0..<8 where !tile.isHittable { swipeUp(velocity: .slow) }
        tile.tap()
        let choose = buttons["choose-cat-pack"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10), "\(id)'s character card", file: file, line: line)
        for _ in 0..<6 where !choose.isHittable { descendants(matching: .any)["cat-card"].swipeUp(velocity: .slow) }
        choose.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: tile)
        XCTAssertEqual(XCTWaiter().wait(for: [selected], timeout: 10), .completed, "\(id) selected", file: file, line: line)
    }

    /// The first cat's row in an open 猫咪管理. Its label is the name, then where it lives.
    var firstCatRow: XCUIElement {
        descendants(matching: .any).matching(identifier: "cat-row").firstMatch
    }

    /// Waits until the first cat's row starts with `name`.
    func waitForFirstCat(named name: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let named = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", name), object: firstCatRow)
        XCTAssertEqual(XCTWaiter().wait(for: [named], timeout: timeout), .completed,
                       "the first cat is called \(name), the row says “\(firstCatRow.exists ? firstCatRow.label : "<missing>")”", file: file, line: line)
    }

    /// Renames the first cat through its row menu in an open 猫咪管理, and waits for the row.
    func renameFirstCat(to name: String, file: StaticString = #filePath, line: UInt = #line) {
        let menu = buttons.matching(identifier: "cat-row-menu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), file: file, line: line)
        menu.tap()
        let rename = buttons["rename-cat"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5), file: file, line: line)
        rename.tap()
        let field = alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        // The right end, so the caret is after the old name (see `replaceText`).
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        field.typeText(name)
        // By label in either language: an identifier on an alert's button puts it in the tree twice,
        // and the caller, not the run, decides the app's language.
        alerts.buttons.matching(NSPredicate(format: "label IN %@", ["保存", "Save"])).firstMatch.tap()
        waitForFirstCat(named: name, file: file, line: line)
    }

    /// Settings, from the gear, by its centre: a notice that lets touches through can cover the
    /// gear's middle (the English one is wide enough), and a tap by element then moves to a corner
    /// the notice leaves free, which is outside the gear's round touch area.
    func tapSettingsGear(file: StaticString = #filePath, line: UInt = #line) {
        let gear = buttons["open-settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "the gear", file: file, line: line)
        for _ in 0..<20 where !gear.isHittable { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        gear.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// DEBUG: three synthetic photos as a batch, from the button next to 合成照片.
    func addSyntheticBatch(file: StaticString = #filePath, line: UInt = #line) {
        let batch = buttons["add-synthetic-batch"]
        XCTAssertTrue(batch.waitForExistence(timeout: 20), file: file, line: line)
        batch.tap()
    }

    /// The 互动 panel's 走路方式 rows; the panel closes again.
    func selectGroundGait(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        buttons["choose-interaction"].tap()
        let chip = buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ground-gait-' AND label == %@", title)).firstMatch
        // The rows are the panel's last section, and the list is lazy: scroll until they load.
        XCTAssertTrue(buttons["choose-toy"].waitForExistence(timeout: 10) || buttons["choose-pocket-cat"].exists, file: file, line: line)
        for _ in 0..<10 where !(chip.exists && chip.isHittable) { swipeUp() }
        XCTAssertTrue(chip.isHittable, "the \(title) chip is at the bottom of 互动", file: file, line: line)
        chip.tap()
        XCTAssertTrue(chip.isSelected, "\(title) is chosen", file: file, line: line)
        navigationBars.buttons["close-interaction"].tap()
    }
}

/// The system's Photos prompt, which the one button on the page before the first photos opens
/// (`PhotoLibraryIntro`). The answer stays on the simulator and hides that page from later
/// tests: call `resetAuthorizationStatus(for: .photos)` before the test ends.
enum PhotosPrompt {
    static let deny = ["Don’t Allow", "Don't Allow", "不允许"]
    static let fullAccess = ["Allow Full Access", "允许完全访问", "允许访问所有照片", "Allow Access to All Photos"]

    static func answer(_ labels: [String], file: StaticString = #filePath, line: UInt = #line) {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the system Photos prompt did not appear", file: file, line: line)
        let button = alert.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), alert.debugDescription, file: file, line: line)
        button.tap()
    }
}
