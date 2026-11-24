import XCTest

/// A Home Screen "add photos" action closes open pages to get back to the room. A page holding an
/// edit the user has not saved (a photo note, a room's new name) must stay open with the text, and
/// one line says why. A page with nothing changed still closes, as before.
final class RoomQuickAddDraftUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let busy = "先完成或停止正在进行的事，再添加照片。"

    override func setUp() { continueAfterFailure = false }

    private func launch(store: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseResetStore",
                                                      "-MeowverseSyntheticPhoto"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        return app
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Lists are lazy: scroll until the row can be tapped.
    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let target = element(app, id)
        for _ in 0..<5 where !(target.exists && target.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(target.exists && target.isHittable, "could not reach \(id)")
        usleep(600_000)
        return target
    }

    /// 合成照片 → 只存照片 → 图库 → its detail → 便签, with `text` typed and not saved.
    private func openNoteOnAPhotoOnlyPhoto(_ app: XCUIApplication, typing text: String?) -> XCUIElement {
        app.buttons["add-synthetic"].tap()
        let photoOnly = app.buttons["photo-only"]
        XCTAssertTrue(photoOnly.waitForExistence(timeout: 20))
        photoOnly.tap()
        let cell = app.buttons["library-photo"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        cell.tap()
        XCTAssertTrue(element(app, "photo-date-line").waitForExistence(timeout: 10))
        reveal(app, "edit-note").tap()
        let note = app.textViews["note-text"]
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        if let text {
            note.tap()
            note.typeText(text)
            XCTAssertEqual(note.value as? String, text)
        }
        return note
    }

    /// The audit's path: an unsaved photo note, the app sent to the background, then 从相册添加
    /// from the real Home Screen menu. The note editor stays with every character typed.
    func testHomeScreenLibraryActionKeepsAnUnsavedPhotoNote() {
        let app = launch(store: "quick-note", ["-MeowverseLibraryIntro"])
        let text = "Bella naps by the window, half written"
        let note = openNoteOnAPhotoOnlyPhoto(app, typing: text)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended)
        let icon = springboard.icons[app.label]
        XCTAssertTrue(icon.waitForExistence(timeout: 10), "no icon named \(app.label)")
        for _ in 0..<4 where !icon.isHittable { springboard.swipeLeft(); sleep(1) }
        icon.press(forDuration: 1.5)
        let library = springboard.buttons["从相册添加"]
        XCTAssertTrue(library.waitForExistence(timeout: 10), springboard.debugDescription)
        library.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let notice = element(app, "quick-action-notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "the quick action was not held back")
        XCTAssertEqual(notice.label, busy)
        snap("quick-note-kept")
        sleep(3)
        XCTAssertTrue(note.exists, "the note editor is still open")
        XCTAssertEqual(note.value as? String, text, "the whole unsaved note is still there")
        XCTAssertTrue(app.buttons["save-note"].exists)
        XCTAssertFalse(app.buttons["library-intro-continue"].exists, "the photo picker did not open over it")

        // The draft can still be saved.
        app.buttons["save-note"].tap()
        let saved = element(app, "photo-note")
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertTrue(saved.label.contains(text), saved.label)
    }

    /// The second entrance with the same cause: a room's new name typed in 房间管理 and not saved.
    func testLibraryActionKeepsAnUnsavedRoomName() {
        let app = launch(store: "quick-rename", ["-MeowverseQuickAction", "app.meowverse.library",
                                                 "-MeowverseQuickActionDelay", "40", "-MeowverseLibraryIntro"])
        let manager = app.buttons["open-room-manager"]
        XCTAssertTrue(manager.waitForExistence(timeout: 10))
        manager.tap()
        let menu = app.buttons["room-row-menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["rename-room"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Sunroom draft")
        let notice = element(app, "quick-action-notice")
        XCTAssertFalse(notice.exists, "the action arrives after the name is typed")
        XCTAssertTrue(notice.waitForExistence(timeout: 45), "the quick action did not arrive or was not held back")
        XCTAssertEqual(notice.label, busy)
        snap("quick-rename-kept")
        sleep(3)
        XCTAssertTrue(field.exists, "the name prompt is still open")
        XCTAssertEqual(field.value as? String, "Sunroom draft")
        XCTAssertFalse(app.buttons["library-intro-continue"].exists)
    }

    /// Control: a note editor opened but left as it was is not a draft. It closes and the camera
    /// opens, as for any page without unsaved work.
    func testCameraActionClosesAnUnchangedNoteEditor() {
        let app = launch(store: "quick-note-empty", ["-MeowverseFakeCamera", "-MeowverseQuickAction", "app.meowverse.camera",
                                                     "-MeowverseQuickActionDelay", "40"])
        let note = openNoteOnAPhotoOnlyPhoto(app, typing: nil)
        XCTAssertTrue(note.exists)
        XCTAssertFalse(app.buttons["fake-camera-use"].exists, "the action arrives after the editor is open")
        XCTAssertTrue(app.buttons["fake-camera-use"].waitForExistence(timeout: 45))
        XCTAssertFalse(app.textViews["note-text"].exists)
    }
}
