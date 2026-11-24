import XCTest

/// Local reminders with a fake notification center (`-MeowverseFakeNotifications`): the fake
/// answers the permission prompt and records the requests instead of scheduling them; the
/// settings page shows what it recorded in a debug-only row. Real delivery is not tested here.
final class ReminderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(store: String, answer: String? = nil, reset: Bool, synthetic: Bool = false, firstLaunch: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store] + extra
        if let answer { app.launchArguments += ["-MeowverseFakeNotifications", answer] }
        if firstLaunch { app.launchArguments.removeAll { $0 == "-MeowverseSkipReminderSetup" } }
        if synthetic { app.launchArguments.append("-MeowverseSyntheticPhoto") }
        if reset { app.launchArguments.append("-MeowverseResetStore") }
        app.launch()
        if !firstLaunch { XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 20)) }
        return app
    }

    private func openReminders(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let row = app.buttons["open-reminders"]
        for _ in 0..<8 where !(row.exists && row.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reminder-permission-state"].firstMatch.waitForExistence(timeout: 5))
    }

    private func toggle(_ app: XCUIApplication, _ id: String) {
        let element = app.switches[id]
        XCTAssertTrue(element.waitForExistence(timeout: 5), id)
        // The inner UISwitch takes the tap; a tap on the row's middle does not flip it.
        let inner = element.switches.firstMatch
        (inner.exists ? inner : element).tap()
    }

    private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    /// The debug row is the last one; lists are lazy, so scroll until it is on screen.
    private func revealPlan(_ app: XCUIApplication) -> XCUIElement {
        let plan = app.staticTexts["reminder-debug-plan"]
        for _ in 0..<6 where !(plan.exists && plan.isHittable) { app.swipeUp() }
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        return plan
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The first launch opens no reminder page and asks nothing (PRODUCT_PLAN §2.2, Plan A). In
    /// Settings the permission is asked when a reminder is first turned on, and only that one is
    /// scheduled.
    func testFirstLaunchAsksNothingAndSettingsSchedulesOnlySelectedCalls() {
        var app = launch(store: "first-reminders-allowed", answer: "granted", reset: true, firstLaunch: true)
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["finish-reminder-setup"].waitForExistence(timeout: 4), "no reminder page at the first launch")
        openReminders(app)
        let state = app.descendants(matching: .any)["reminder-permission-state"].firstMatch
        XCTAssertTrue(state.label.contains("第一次打开提醒时"), "not asked yet: \(state.label)")
        XCTAssertEqual(app.switches["reminder-calls"].value as? String, "0")
        toggle(app, "reminder-calls")
        XCTAssertTrue(waitForValue(app.switches["reminder-calls"], "1"))
        XCTAssertTrue(waitForLabel(state, containing: "已允许"), state.label)
        let plan = app.staticTexts["reminder-debug-plan"]
        for _ in 0..<4 where !plan.isHittable { app.swipeUp() }
        XCTAssertTrue(waitForLabel(plan, containing: "scheduled 7 "), plan.debugDescription)
        app.terminate()
        app = launch(store: "first-reminders-allowed", answer: "granted", reset: false, firstLaunch: true)
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        openReminders(app)
        XCTAssertEqual(app.switches["reminder-calls"].value as? String, "1")
        XCTAssertFalse(app.buttons["finish-reminder-setup"].exists)
    }

    func testPartialNotificationPlanRetriesOnForeground() {
        let app = launch(store: "retry-reminders", reset: true, extra: ["-MeowverseFailReminderAdd"])
        openReminders(app)
        toggle(app, "reminder-calls")
        let plan = app.staticTexts["reminder-debug-plan"]
        for _ in 0..<6 where !plan.isHittable { app.swipeUp() }
        XCTAssertTrue(waitForLabel(plan, containing: "scheduled 2 "))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(waitForLabel(plan, containing: "scheduled 7 "))
    }

    /// Granted: turning calls on schedules one request per weekday, a second time doubles it, and
    /// both the switches and the schedule come back after a relaunch.
    func testGrantedSchedulesCallsAndSettingsSurviveRelaunch() {
        var app = launch(store: "reminders-granted", reset: true)
        openReminders(app)
        let state = app.descendants(matching: .any)["reminder-permission-state"].firstMatch
        XCTAssertTrue(state.label.contains("第一次"), state.label)
        let calls = app.switches["reminder-calls"]
        XCTAssertEqual(calls.value as? String, "0", "off by default")
        XCTAssertEqual(app.switches["reminder-on-this-day"].value as? String, "0")
        XCTAssertEqual(app.switches["reminder-furniture"].value as? String, "0")

        toggle(app, "reminder-calls")
        XCTAssertTrue(waitForValue(calls, "1"))
        XCTAssertTrue(waitForLabel(state, containing: "已允许"), state.label)
        // The debug row is last, below the cat facts: scroll to it.
        let plan = revealPlan(app)
        XCTAssertTrue(waitForLabel(plan, containing: "scheduled 7 "), plan.label)
        XCTAssertTrue(plan.label.contains("meowverse.reminder.call.0.1"), plan.label)
        for _ in 0..<4 where !app.switches["reminder-calls"].isHittable { app.swipeDown() }
        XCTAssertTrue(app.datePickers["reminder-calls-time"].exists || app.descendants(matching: .any)["reminder-calls-time"].exists)

        toggle(app, "reminder-calls-second")
        XCTAssertTrue(waitForLabel(revealPlan(app), containing: "scheduled 14 "), plan.label)
        // The library is empty: turning memories on adds nothing to schedule, and says nothing false.
        for _ in 0..<4 where !app.switches["reminder-on-this-day"].isHittable { app.swipeDown() }
        toggle(app, "reminder-on-this-day")
        XCTAssertTrue(waitForValue(app.switches["reminder-on-this-day"], "1"))
        XCTAssertTrue(waitForLabel(revealPlan(app), containing: "scheduled 14 "), plan.label)
        snap("reminders-granted")

        app.terminate()
        app = launch(store: "reminders-granted", reset: false)
        openReminders(app)
        XCTAssertTrue(waitForValue(app.switches["reminder-calls"], "1"))
        XCTAssertEqual(app.switches["reminder-calls-second"].value as? String, "1")
        XCTAssertEqual(app.switches["reminder-on-this-day"].value as? String, "1")
        XCTAssertEqual(app.switches["reminder-furniture"].value as? String, "0")
        // Planned again at launch, from the saved settings.
        XCTAssertTrue(waitForLabel(revealPlan(app), containing: "scheduled 14 "))

        // Turning everything off clears the schedule.
        for _ in 0..<4 where !app.switches["reminder-calls"].isHittable { app.swipeDown() }
        toggle(app, "reminder-calls")
        toggle(app, "reminder-on-this-day")
        XCTAssertTrue(waitForLabel(revealPlan(app), containing: "scheduled 0 "))
    }

    /// Denied: nothing is switched on, the page says notifications are off and offers the system Settings.
    func testDeniedShowsTheStateAndSchedulesNothing() {
        let app = launch(store: "reminders-denied", answer: "denied", reset: true)
        openReminders(app)
        let calls = app.switches["reminder-calls"]
        toggle(app, "reminder-calls")
        let state = app.descendants(matching: .any)["reminder-permission-state"].firstMatch
        XCTAssertTrue(waitForLabel(state, containing: "关闭"), state.label)
        XCTAssertEqual(calls.value as? String, "0", "never shown as on when it cannot be delivered")
        XCTAssertFalse(calls.isEnabled)
        XCTAssertTrue(app.buttons["reminder-open-system-settings"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["reminder-calls-time"].exists)
        snap("reminders-denied")
        // The last row; the list is lazy, so scroll to it first.
        XCTAssertTrue(revealPlan(app).label.contains("scheduled 0 "))
    }

    /// A piece with a photo is remembered about weekly; the requests carry no attachment (text only).
    func testFurnitureMemoryIsPlannedForAPieceWithAPhoto() {
        let app = launch(store: "reminders-furniture", answer: "granted", reset: true, synthetic: true)
        app.buttons["add-synthetic"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 20))
        sofa.tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 15))

        openReminders(app)
        toggle(app, "reminder-furniture")
        let plan = app.staticTexts["reminder-debug-plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(plan, containing: "meowverse.reminder.furniture."), plan.label)
        XCTAssertFalse(plan.label.contains("call"), plan.label)
        XCTAssertTrue(plan.label.contains("(attachments 0)"), plan.label)
    }

    /// Cat facts: a fourth switch, off by default; on, it plans facts that are text only, silent
    /// and in their own thread, and nothing else.
    func testCatFactsAreOfferedOffAndScheduleSilentTextOnlyFacts() {
        var app = launch(store: "reminders-cat-facts", answer: "granted", reset: true)
        openReminders(app)
        let facts = app.switches["reminder-cat-facts"]
        for _ in 0..<4 where !(facts.exists && facts.isHittable) { app.swipeUp() }
        XCTAssertTrue(facts.waitForExistence(timeout: 5))
        XCTAssertEqual(facts.value as? String, "0", "off by default")
        let footer = app.staticTexts["reminder-cat-facts-footer"]
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
        XCTAssertTrue(footer.label.contains("不是医疗建议"), footer.label)

        toggle(app, "reminder-cat-facts")
        XCTAssertTrue(waitForValue(facts, "1"))
        let plan = app.staticTexts["reminder-debug-plan"]
        for _ in 0..<4 where !(plan.exists && plan.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitForLabel(plan, containing: "meowverse.reminder.catfact."), plan.label)
        let label = plan.label
        // Four are planned ahead; three when this week's has already gone out today.
        XCTAssertNotNil(label.range(of: #"^scheduled [34] "#, options: .regularExpression), label)
        XCTAssertTrue(label.contains("(attachments 0)"), label)
        XCTAssertTrue(label.contains("(sounds 0)"), label)
        XCTAssertTrue(label.contains("[threads cat-facts]"), label)
        XCTAssertFalse(label.contains(".call."), label)
        snap("reminders-cat-facts")

        app.terminate()
        app = launch(store: "reminders-cat-facts", answer: "granted", reset: false)
        openReminders(app)
        let again = app.switches["reminder-cat-facts"]
        for _ in 0..<4 where !(again.exists && again.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitForValue(again, "1"))
        XCTAssertTrue(waitForLabel(app.staticTexts["reminder-debug-plan"], containing: "[threads cat-facts]"))
    }
}
