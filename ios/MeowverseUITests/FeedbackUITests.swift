import XCTest

/// 「反馈问题」 in Settings. The simulator has no mail account, so this covers the fallback path
/// (mail link, copy) and the diagnostics the user is shown; the real composer is not exercised.
final class FeedbackUITests: XCTestCase {
    private let catName = "Quokkacat"
    private let furnitureName = "Zebracouch"

    override func setUp() { continueAfterFailure = false }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Lists are lazy: scroll until the row exists and can be tapped.
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(app, id)
        for _ in 0..<5 where !(target.exists && target.isHittable) { app.swipeUp(velocity: .slow) }
        for _ in 0..<8 where !(target.exists && target.isHittable) { app.swipeDown(velocity: .slow) }
        usleep(600_000)
        XCTAssertTrue(target.exists && target.isHittable, "could not reach \(id)", file: file, line: line)
        return target
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testDiagnosticsShowCountsButNoNamesAndTheFallbackOffersCopy() {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.current + ["-MeowverseStore", "feedback", "-MeowverseResetStore", "-MeowverseSyntheticPhoto"]
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 20))

        // One sofa with a name only this test uses.
        app.buttons["add-synthetic"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 20))
        sofa.tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        let nameField = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", AppText.string("家具的名字"))).firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.replaceText(with: furnitureName)
        XCTAssertEqual(nameField.value as? String, furnitureName)
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 15))

        // Name the cat (in 猫咪管理).
        app.openCatManager()
        app.renameFirstCat(to: catName)
        app.buttons["close-home"].tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let usage = element(app, "storage-usage")
        XCTAssertTrue(usage.waitForExistence(timeout: 10))

        // The sheet opens with diagnostics on by default.
        reveal(app, "open-feedback").tap()
        let toggle = app.switches["feedback-include-diagnostics"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1")
        let description = element(app, "feedback-description")
        XCTAssertTrue(description.exists)
        description.tap()
        description.typeText("The sofa vanished after a restore.")
        let doneTyping = app.buttons["feedback-done-typing"]
        XCTAssertTrue(doneTyping.waitForExistence(timeout: 5))
        doneTyping.tap()
        let keyboardGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [keyboardGone], timeout: 5), .completed, "the keyboard stayed up")

        // The full diagnostics, verbatim: version and counts, no names.
        reveal(app, "feedback-show-diagnostics").tap()
        let diagnostics = app.staticTexts["feedback-diagnostics-text"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 20))
        let text = diagnostics.label
        for expected in ["App: Meowverse ", " (build ", "iOS: ", "Device: ", "Photos: 1", "Furniture in room: 1",
                         "Furniture in storage: 0", "Library schema: ", "Free disk: "] {
            XCTAssertTrue(text.contains(expected), "missing “\(expected)” in diagnostics:\n\(text)")
        }
        XCTAssertFalse(text.localizedCaseInsensitiveContains(catName), "the cat's name leaked:\n\(text)")
        XCTAssertFalse(text.localizedCaseInsensitiveContains(furnitureName), "the furniture name leaked:\n\(text)")
        XCTAssertFalse(text.contains("synthetic"), "a photo file name leaked:\n\(text)")
        let log = XCTAttachment(string: text)
        log.name = "diagnostics"
        log.lifetime = .keepAlways
        add(log)
        snap("feedback-1-diagnostics")

        // The compose button is always there. Below it, a device without a Mail account (the simulator)
        // gets the address and Copy; one with an account gets neither, and the test never opens the
        // real composer, so nothing can be sent from a test phone.
        let compose = reveal(app, "feedback-compose")
        XCTAssertTrue(compose.isEnabled)
        app.swipeUp(velocity: .slow)
        let hasMail = !element(app, "feedback-address").waitForExistence(timeout: 2)
        if hasMail {
            XCTAssertFalse(element(app, "feedback-copy").exists)
        } else {
            XCTAssertTrue(reveal(app, "feedback-address").label.contains("bella.meowverse@gmail.com"))
            reveal(app, "feedback-copy").tap()
            XCTAssertTrue(element(app, "feedback-copied").waitForExistence(timeout: 5))
            reveal(app, "feedback-compose").tap()
            // Either the mail link opened something or it is said that it did not; never silence.
            let outcome = element(app, "feedback-outcome")
            if outcome.waitForExistence(timeout: 5) {
                XCTAssertFalse(outcome.label.isEmpty)
                snap("feedback-2-outcome")
            } else {
                XCTAssertNotEqual(app.state, .runningForeground, "the mail link neither opened nor reported failing")
                app.activate()
            }
        }

        // Turning the toggle off removes the diagnostics; copy then takes only the description, and compose stays.
        // Mid-scroll the row can sit under the navigation bar, which then takes the tap: scroll it clear
        // (slowly; a fast swipe at the top closes the Settings sheet).
        let toggleRow = reveal(app, "feedback-include-diagnostics")
        let bar = app.navigationBars.firstMatch
        for _ in 0..<4 where bar.exists && toggleRow.frame.minY < bar.frame.maxY + 8 {
            app.swipeDown(velocity: .slow)
            usleep(400_000)
        }
        // Aim at the switch, at the part of the row the navigation bar does not cover; one retry.
        for _ in 0..<2 where (toggle.value as? String) != "0" {
            let row = toggleRow.frame, top = bar.exists ? bar.frame.maxY + 6 : row.minY
            let y = min(max(row.midY, top), row.maxY - 4)
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: row.maxX - 32, dy: y)).tap()
            let off = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: toggle)
            _ = XCTWaiter().wait(for: [off], timeout: 3)
        }
        XCTAssertEqual(toggle.value as? String, "0", "the diagnostics switch did not turn off")
        XCTAssertFalse(app.staticTexts["feedback-diagnostics-text"].exists)
        XCTAssertFalse(element(app, "feedback-show-diagnostics").exists)
        if !hasMail { XCTAssertEqual(reveal(app, "feedback-copy").label, AppText.string("拷贝问题描述")) }
        XCTAssertTrue(reveal(app, "feedback-compose").isEnabled)
        snap("feedback-3-without-diagnostics")
    }

    /// 「我想要这个」: nothing to send until the first answer is written; the fallback copies only
    /// the two answers and the version line. The real composer is not exercised.
    func testSuggestAFeatureNeedsAnIdeaAndCopiesOnlyWhatWasWritten() {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.current + ["-MeowverseStore", "wish", "-MeowverseResetStore"]
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 20))

        // Name the cat (in 猫咪管理), so a leak would show.
        app.openCatManager()
        app.renameFirstCat(to: catName)
        app.buttons["close-home"].tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        let row = reveal(app, "open-wish")
        XCTAssertEqual(row.label, AppText.string("我想要这个"))
        row.tap()
        let compose = element(app, "wish-compose")
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        XCTAssertFalse(compose.isEnabled, "an empty idea cannot be sent")
        let copy = element(app, "wish-copy")
        if copy.exists { XCTAssertFalse(copy.isEnabled) }
        snap("wish-1-empty")

        let what = element(app, "wish-what")
        what.tap()
        what.typeText("A cat bed by the window")
        let when = element(app, "wish-when")
        when.tap()
        when.typeText("Sunny afternoons")
        let doneTyping = app.buttons["wish-done-typing"]
        XCTAssertTrue(doneTyping.waitForExistence(timeout: 5))
        doneTyping.tap()
        XCTAssertTrue(reveal(app, "wish-compose").isEnabled)
        snap("wish-2-written")

        let hasMail = !element(app, "wish-address").waitForExistence(timeout: 2)
        if hasMail {
            XCTAssertFalse(copy.exists)
            return
        }
        XCTAssertTrue(reveal(app, "wish-address").label.contains("bella.meowverse@gmail.com"))
        reveal(app, "wish-copy").tap()
        let copiedLabel = element(app, "wish-copied")
        XCTAssertTrue(copiedLabel.waitForExistence(timeout: 5))
        // The runner is not allowed to read another app's pasteboard; debug builds read it back in the app.
        let copied = copiedLabel.value as? String ?? ""
        let text = XCTAttachment(string: copied)
        text.name = "wish-copied-text"
        text.lifetime = .keepAlways
        add(text)
        XCTAssertTrue(copied.hasPrefix("A cat bed by the window\n\n\(AppText.string("会在什么时候用到："))\nSunny afternoons\n\nApp "), copied)
        XCTAssertNotNil(copied.range(of: #"\nApp [^\n]+ \([^\n]+\) · iOS [0-9.]+$"#, options: .regularExpression), copied)
        XCTAssertFalse(copied.localizedCaseInsensitiveContains(catName), "the cat's name leaked:\n\(copied)")
        for marker in ["Diagnostics", "Device:", "Locale:", "Photos:", "Log"] {
            XCTAssertFalse(copied.contains(marker), "diagnostics in the mail:\n\(copied)")
        }

        reveal(app, "wish-compose").tap()
        let outcome = element(app, "wish-outcome")
        if outcome.waitForExistence(timeout: 5) {
            XCTAssertFalse(outcome.label.isEmpty)
            snap("wish-3-outcome")
        } else {
            XCTAssertNotEqual(app.state, .runningForeground, "the mail link neither opened nor reported failing")
            app.activate()
        }
    }
}
