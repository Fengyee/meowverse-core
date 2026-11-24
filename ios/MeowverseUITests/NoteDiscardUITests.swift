import XCTest

/// DATA-7: a typed note is never thrown away without asking. An untouched one closes at once.
final class NoteDiscardUITests: XCTestCase {
    private let typed = "Bella naps by the window"

    override func setUp() { continueAfterFailure = false }

    func testCancelAsksBeforeThrowingANoteAway() {
        let app = launch(store: "note-cancel")
        let note = openNote(app, typing: typed)
        app.buttons["cancel-note"].tap()
        let keep = app.alerts.buttons["继续编辑"]
        XCTAssertTrue(keep.waitForExistence(timeout: 10), "取消 threw the note away without asking")
        keep.tap()
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        XCTAssertEqual(note.value as? String, typed)
        app.buttons["cancel-note"].tap()
        let discard = app.alerts.buttons["不保存"]
        XCTAssertTrue(discard.waitForExistence(timeout: 10))
        discard.tap()
        XCTAssertTrue(note.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["edit-note"].waitForExistence(timeout: 10))
    }

    func testSwipeDownKeepsATypedNote() {
        let app = launch(store: "note-swipe")
        let note = openNote(app, typing: typed)
        swipeSheetDown(app)
        XCTAssertTrue(note.exists, "a swipe threw the note away")
        XCTAssertEqual(note.value as? String, typed)
    }

    func testAnUntouchedNoteClosesWithoutAsking() {
        let app = launch(store: "note-untouched")
        let note = openNote(app, typing: nil)
        app.buttons["cancel-note"].tap()
        XCTAssertTrue(note.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func launch(store: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseResetStore", "-MeowverseSyntheticPhoto"]
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        return app
    }

    private func openNote(_ app: XCUIApplication, typing text: String?) -> XCUIElement {
        app.buttons["add-synthetic"].tap()
        let photoOnly = app.buttons["photo-only"]
        XCTAssertTrue(photoOnly.waitForExistence(timeout: 20))
        photoOnly.tap()
        let cell = app.buttons["library-photo"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        cell.tap()
        let edit = app.buttons["edit-note"]
        for _ in 0..<6 where !(edit.exists && edit.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(edit.isHittable)
        edit.tap()
        let note = app.textViews["note-text"]
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        if let text {
            note.tap()
            note.typeText(text)
            XCTAssertEqual(note.value as? String, text)
        }
        return note
    }

    private func swipeSheetDown(_ app: XCUIApplication) {
        let bar = app.navigationBars["便签"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        bar.press(forDuration: 0.05, thenDragTo: bottom)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    }
}
