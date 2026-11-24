import XCTest

/// The first launch after the tour (Plan A, PRODUCT_PLAN §2.2): no reminder page and no permission
/// prompt, the Home Screen items registered anyway (Q-05), the first icon change after the opening,
/// and the tour seen again from Settings → 使用导览 or the empty room's 「看看怎么玩」 (§4.1, §4.2).
///
/// `tour-status` (DEBUG) reads `tour=<chapter> <step|card> <overlay|page> show=0|1 …`.
final class TourFirstLaunchUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() { continueAfterFailure = false }

    /// `firstLaunch` drops `-MeowverseSkipReminderSetup`, as a real first launch has no such switch.
    private func launch(_ store: String, reset: Bool = true, tour: Bool = true, firstLaunch: Bool = true,
                        extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.current + ["-MeowverseStore", store, "-MeowverseFakeNotifications", "granted"] + extra
        if tour { app.launchArguments += ["-MeowverseTour", "auto"] }
        if firstLaunch { app.launchArguments.removeAll { $0 == "-MeowverseSkipReminderSetup" } }
        if reset { app.launchArguments.append("-MeowverseResetStore") }
        app.launch()
        return app
    }

    private func status(_ app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any)["tour-status"].firstMatch
        return element.exists ? (element.value as? String ?? "") : ""
    }

    @discardableResult
    private func waitShown(_ app: XCUIApplication, _ tour: String, timeout: TimeInterval = 40,
                           file: StaticString = #filePath, line: UInt = #line) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            last = status(app)
            if last.contains("tour=\(tour) ") && last.contains("show=1") { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(last.contains("tour=\(tour) ") && last.contains("show=1"), "waiting for \(tour): \(last)", file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        return status(app)
    }

    private func tap(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[id].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), id, file: file, line: line)
        for _ in 0..<20 where !button.isHittable { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        button.tap()
    }

    /// Settings is a lazy list: scroll until the row is on screen, then tap it.
    private func openSettingsRow(_ app: XCUIApplication, _ id: String) {
        app.tapSettingsGear()
        let row = app.buttons[id]
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), id)
        row.tap()
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: First launch

    /// The greeting comes first: no reminder page, and no permission prompt until the user turns
    /// a reminder on in Settings.
    func testFirstLaunchHasNoReminderPage() {
        let app = launch("first-launch-order")
        waitShown(app, "welcome card")
        XCTAssertFalse(app.buttons["finish-reminder-setup"].exists, "no reminder page at the first launch")
        tap(app, "tour-card-later")
        // The fake center remembers what it was asked; nothing is asked yet.
        openSettingsRow(app, "open-reminders")
        let state = app.descendants(matching: .any)["reminder-permission-state"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(state.label.contains(AppText.string("第一次打开提醒时，会询问能否发送通知。")), state.label)
        XCTAssertFalse(app.buttons["finish-reminder-setup"].exists)
    }

    /// Q-05: the Home Screen items no longer wait for the first reminder page.
    func testFirstLaunchRegistersTheHomeScreenItems() {
        let app = launch("first-launch-quick", tour: false)
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        sleep(2)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended)
        // iPad also keeps the app among the dock's recent apps: either icon has the items.
        let icon = springboard.icons.matching(NSPredicate(format: "label == %@", app.label)).firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 10), "no icon named \(app.label)")
        for _ in 0..<4 where !icon.isHittable { springboard.swipeLeft(); sleep(1) }
        icon.press(forDuration: 1.5)
        XCTAssertTrue(springboard.buttons[AppText.string("从相册添加")].waitForExistence(timeout: 10), springboard.debugDescription)
        XCTAssertTrue(springboard.buttons[AppText.string("陪我一会儿")].exists)
        snap("first-launch-home-screen-items")
        // Close the menu without opening anything.
        XCUIDevice.shared.press(.home)
    }

    /// The icon's system alert does not land on the greeting. It comes once the opening is over,
    /// the next time the app comes to the front. The test ends on the primary icon.
    func testTheFirstIconChangeWaitsForTheOpening() {
        let app = launch("first-launch-icon", firstLaunch: false, extra: ["-MeowverseIconSwitching", "-MeowverseIconReset",
                                                      "-MeowverseIconDate", "2026-12-25"])
        waitShown(app, "welcome card")
        // Look before touching anything: XCUITest dismisses an alert that blocks a tap.
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 5), "no icon alert over the greeting")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        tap(app, "tour-card-later")
        // Still the same time in the foreground: nothing comes.
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 4))

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended)
        app.activate()
        acceptIconAlert(app)

        // Back to the primary icon for the next test.
        tap(app, "open-settings")
        let toggle = app.switches["app-icon-follows"]
        for _ in 0..<6 where !(toggle.exists && toggle.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        acceptIconAlert(app)
    }

    private func acceptIconAlert(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(20)
        var alert: XCUIElement?
        while alert == nil, Date() < deadline {
            if springboard.alerts.firstMatch.exists { alert = springboard.alerts.firstMatch }
            else if app.alerts.firstMatch.exists { alert = app.alerts.firstMatch }
            else { usleep(250_000) }
        }
        guard let alert else { return XCTFail("no icon-change alert", file: file, line: line) }
        alert.buttons.firstMatch.tap()
    }

    // MARK: Seeing it again

    /// Settings → 使用导览 lists the opening's chapters with how each ended; a row replays that
    /// chapter from its card, and 「从头看一遍」 starts again at chapter 1, then tells the rest as the
    /// opening does: no card before chapters 2 to 5.
    func testSettingsReplaysOneChapterOrTheWholeOpening() {
        let app = launch("tour-replay-settings", firstLaunch: false)
        waitShown(app, "welcome card")
        tap(app, "tour-card-later")
        openSettingsRow(app, "open-tour")
        let welcome = app.buttons["tour-replay-welcome"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 5))
        XCTAssertTrue(welcome.label.contains(AppText.string("tour.welcome.card.title", table: "Tour")), welcome.label)
        XCTAssertTrue(welcome.label.contains(AppText.string("tour.status.skipped")), welcome.label)
        let play = app.buttons["tour-replay-play"]
        let playTitle = AppText.pattern("tour.play.card.title", table: "Tour")
        XCTAssertNotNil(play.label.range(of: playTitle, options: .regularExpression), play.label)
        XCTAssertTrue(play.label.contains(AppText.string("tour.status.skipped")), play.label)
        XCTAssertTrue(app.staticTexts[AppText.string("tour.settings.group.opening")].exists, "the group's title")
        // T4: chapters 6, 7 and 12 in their own group. 「以后再说」 on the greeting skipped them too.
        XCTAssertTrue(app.staticTexts[AppText.string("tour.settings.group.onDemand")].exists, "the feature chapters' group")
        snap("settings-tour")
        // Since T5 the group holds ten chapters and 12 (company) is below the fold: a List row off
        // screen is not in the accessibility tree, so scroll to it, then back for 「玩一会儿」.
        let list = app.collectionViews.firstMatch
        var scrolled = 0
        for id in ["memories", "move-and-look", "company"] {
            let row = app.buttons["tour-replay-\(id)"]
            while !row.exists, scrolled < 4 {
                list.swipeUp()
                scrolled += 1
            }
            XCTAssertTrue(row.exists, id)
            XCTAssertTrue(row.label.contains(AppText.string("tour.status.skipped")), row.label)
        }
        // As many swipes back: an off-screen row can still read as hittable.
        for _ in 0..<scrolled { list.swipeDown() }
        XCTAssertTrue(app.buttons["tour-replay-welcome"].waitForExistence(timeout: 3), "back at the top")

        play.tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10), "Settings closed")
        waitShown(app, "play card")
        tap(app, "tour-card-later")

        openSettingsRow(app, "open-tour")
        tap(app, "tour-replay-all")
        waitShown(app, "welcome card")
        tap(app, "tour-card-start")
        waitShown(app, "welcome 1.1")
        tap(app, "tour-skip")
        for part in ["bring-photo 2.1", "furnish-first 3.1", "play 4.1", "top-row 5.1"] {
            waitShown(app, part)
            XCTAssertFalse(app.otherElements["tour-card"].exists, "\(part): no card inside 从头看一遍")
            tap(app, "tour-skip")
        }
    }

    /// An existing user's opening was waived (还没看). Chapter 1 opened alone from Settings and read
    /// to its end shows 看过 there; the parts not read stay 还没看, and a later skip takes nothing
    /// away (the lead's ruling, T3 r8). The tour's record is not changed (PRODUCT_PLAN §3.1.1 #10):
    /// relaunched, the list still reads 看过 and no part of the opening comes up.
    func testAChapterReadAgainFromSettingsIsSeen() {
        let app = launch("tour-replay-seen", firstLaunch: false, extra: ["-MeowverseTourSeed", "veteran"])
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        openSettingsRow(app, "open-tour")
        let welcome = app.buttons["tour-replay-welcome"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 5))
        XCTAssertTrue(welcome.label.contains(AppText.string("tour.status.notYet")), welcome.label)
        welcome.tap()
        waitShown(app, "welcome card")
        tap(app, "tour-card-start")
        waitShown(app, "welcome 1.1")
        tap(app, "tour-next")
        XCTAssertTrue(app.textFields["tour-naming-field"].waitForExistence(timeout: 10))
        tap(app, "tour-naming-later")
        waitShown(app, "welcome 1.3b")
        tap(app, "tour-next")
        waitShown(app, "welcome 1.4")
        tap(app, "tour-next")

        openSettingsRow(app, "open-tour")
        XCTAssertTrue(welcome.waitForExistence(timeout: 5))
        XCTAssertTrue(welcome.label.contains(AppText.string("tour.status.seen")), "read to its end: \(welcome.label)")
        let play = app.buttons["tour-replay-play"]
        XCTAssertTrue(play.label.contains(AppText.string("tour.status.notYet")), "not read again: \(play.label)")
        snap("settings-tour-after-ch1-alone")

        // Opened again and skipped: still 看过.
        welcome.tap()
        waitShown(app, "welcome card")
        tap(app, "tour-card-start")
        waitShown(app, "welcome 1.1")
        tap(app, "tour-skip")
        openSettingsRow(app, "open-tour")
        XCTAssertTrue(welcome.waitForExistence(timeout: 5))
        XCTAssertTrue(welcome.label.contains(AppText.string("tour.status.seen")), "a skip takes nothing away: \(welcome.label)")

        app.terminate()
        let again = launch("tour-replay-seen", reset: false, firstLaunch: false)
        XCTAssertTrue(again.buttons["add-photo"].waitForExistence(timeout: 30))
        XCTAssertFalse(status(again).contains("show=1"), "the opening does not come back")
        openSettingsRow(again, "open-tour")
        let kept = again.buttons["tour-replay-welcome"]
        XCTAssertTrue(kept.waitForExistence(timeout: 5))
        XCTAssertTrue(kept.label.contains(AppText.string("tour.status.seen")), "kept across launches: \(kept.label)")
    }

    /// 「看看怎么玩」 on the empty room's card opens the tour, not the old three-step guide.
    func testTheEmptyRoomCardStartsTheTour() {
        let app = launch("tour-replay-card", firstLaunch: false)
        waitShown(app, "welcome card")
        tap(app, "tour-card-later")
        if app.buttons["empty-room-help"].exists { app.buttons["empty-room-help"].tap() }
        tap(app, "open-guide")
        waitShown(app, "welcome card")
        XCTAssertFalse(app.buttons["guide-next"].exists, "not the old guide")
    }
}
