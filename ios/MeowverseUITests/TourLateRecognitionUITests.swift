import XCTest

/// Chapter 8 when the comparison of a batch outlasts its storage receipt (12 s): the room is free
/// all along, so the arrival is spent before the bar offers sorting (TECH_DESIGN §5.3).
/// Found by identifiers only, so each test may run in either language.
final class TourLateRecognitionUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private static let readButEight = ["welcome", "bring-photo", "furnish-first", "play", "top-row", "memories", "move-and-look",
                                       "photo-library", "furniture-library", "send-cat", "company", "tabletop", "reminders",
                                       "backup"].joined(separator: ",")

    /// Long enough for three slowed prints to outlast the receipt.
    private static let receipt: TimeInterval = 12

    private func launch(_ store: String, language: [String], slow: Int = 9, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = language + ["-MeowverseStore", store, "-MeowverseResetStore", "-MeowverseTour", "auto",
                                          "-MeowverseTourSeed", Self.readButEight, "-MeowverseSyntheticPhoto",
                                          "-MeowverseSyntheticBatch", "3", "1", "-MeowverseSlowPrints", String(slow)] + extra
        app.launch()
        return app
    }

    private func status(_ app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any)["tour-status"].firstMatch
        return element.exists ? (element.value as? String ?? "") : ""
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitForCard(_ app: XCUIApplication, _ timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = status(app)
            if value.contains("tour=photo-batch card"), value.contains("show=1") { return true }
            wait(0.3)
        }
        return false
    }

    func testTheCardFollowsARecognitionLongerThanTheReceiptAndComesOnce() {
        let app = launch("tour-late-prints", language: TestLanguage.english)
        app.addSyntheticBatch()
        let stored = Date()
        let progress = app.descendants(matching: .any)["batch-progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 20), "the comparison is on the bar")
        while progress.exists, Date().timeIntervalSince(stored) < 120 {
            XCTAssertFalse(status(app).contains("tour=photo-batch"), "nothing over the comparison")
            wait(1)
        }
        XCTAssertGreaterThan(Date().timeIntervalSince(stored), Self.receipt + 1, "it outlasted the receipt")
        // The user stays in the room and touches nothing.
        XCTAssertTrue(waitForCard(app, 10), "chapter 8 follows the comparison: \(status(app))")
        app.buttons["tour-card-later"].firstMatch.tap()
        XCTAssertFalse(waitForCard(app, 6), "and comes once")
    }

    func testTheCardWaitsForThePanelOpenedDuringRecognition() {
        let app = launch("tour-late-panel", language: TestLanguage.chinese)
        app.addSyntheticBatch()
        XCTAssertTrue(app.descendants(matching: .any)["batch-progress"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["choose-interaction"].firstMatch.tap()
        XCTAssertTrue(app.buttons["choose-toy"].firstMatch.waitForExistence(timeout: 10), "the panel is open")
        XCTAssertFalse(waitForCard(app, 45), "nothing over the panel, also when the comparison ends")
        // The panel's one leading button closes it.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["start-sorting"].firstMatch.waitForExistence(timeout: 30), "the comparison is over")
        XCTAssertTrue(waitForCard(app, 10), "chapter 8 on the way back: \(status(app))")
    }

    /// The cat is sent under the receipt: neither its going nor the comparison's end brings
    /// chapter 8 over her (QA R-3). The next visit has it.
    func testTheCardLeavesTheSentCatItsVisit() {
        let app = launch("tour-late-sent", language: TestLanguage.current, slow: 5, extra: ["-room.soundEffects", "<false/>"])
        for id in ["add-synthetic", "manual-sofa", "next-model", "next-placement", "confirm-placement"] {
            let button = app.buttons[id].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 30), id)
            button.tap()
        }
        let receipt = app.descendants(matching: .any)["photo-storage-receipt"].firstMatch
        if !receipt.waitForExistence(timeout: 10), app.buttons["confirm-placement"].exists { app.buttons["confirm-placement"].tap() }
        _ = receipt.waitForNonExistence(timeout: 20)

        app.addSyntheticBatch()
        let progress = app.descendants(matching: .any)["batch-progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 20), "the comparison is on the bar")
        XCTAssertTrue(receipt.waitForExistence(timeout: 10), "the batch's receipt")
        app.buttons["choose-interaction"].firstMatch.tap()
        let action = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "invite-")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 10), "the piece's actions")
        XCTAssertTrue(receipt.exists, "the receipt is still up")
        action.tap()

        let sorting = app.buttons["start-sorting"].firstMatch
        let deadline = Date().addingTimeInterval(90)
        while progress.exists || receipt.exists, Date() < deadline {
            XCTAssertFalse(status(app).contains("show=1"), "over the cat the user sent: \(status(app))")
            wait(0.5)
        }
        XCTAssertTrue(sorting.waitForExistence(timeout: 10), "the comparison is over")
        XCTAssertFalse(waitForCard(app, 8), "still her visit: \(status(app))")
        app.buttons["choose-interaction"].firstMatch.tap()
        let close = app.navigationBars.buttons["close-interaction"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(waitForCard(app, 15), "chapter 8 on the next visit: \(status(app))")
    }
}
