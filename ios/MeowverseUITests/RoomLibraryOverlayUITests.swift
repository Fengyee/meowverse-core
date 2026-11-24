import XCTest

final class RoomLibraryOverlayUITests: XCTestCase {
    func testLibrariesWithLargestText() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.english + ["-MeowverseStore", "room-library-large", "-MeowverseResetStore",
                                                     "-MeowverseLibraryIntro", "-photoLibraryLinkWanted", "NO",
                                                     "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let photos = app.buttons["photo-library"], furniture = app.buttons["furniture-list"]
        XCTAssertTrue(photos.waitForExistence(timeout: 15))
        XCTAssertEqual(photos.label, "Photo library")
        XCTAssertEqual(furniture.label, "Furniture list")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "room-largest-type"
        shot.lifetime = .keepAlways
        add(shot)
        verifyRoomControls(app)
        try app.performAccessibilityAudit(for: .textClipped)
        let chest = app.buttons["room-storage"]
        XCTAssertTrue(chest.isHittable)
        for id in ["choose-interaction", "add-photo"] {
            XCTAssertFalse(app.buttons[id].frame.contains(CGPoint(x: chest.frame.midX, y: chest.frame.midY)))
        }
        chest.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["storage-empty"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["close-furniture-list"].tap()
        let help = app.buttons["empty-room-help"]
        XCTAssertTrue(help.isHittable)
        help.tap()
        XCTAssertTrue(app.buttons["place-furniture-first"].exists)
        XCTAssertTrue(app.buttons["open-guide"].exists)
        help.tap()
        furniture.tap()
        XCTAssertTrue(app.buttons["close-furniture-list"].waitForExistence(timeout: 5))
        app.buttons["close-furniture-list"].tap()
        app.buttons["choose-interaction"].tap()
        XCTAssertTrue(app.buttons["choose-toy"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["add-photo"].tap()
        XCTAssertTrue(app.buttons["library-intro-continue"].waitForExistence(timeout: 5))
    }

    /// The English bookplates read as a matched pair of one-word labels. A label broken over
    /// lines ("Furni- / ture / library" on an iPhone 18 Pro, four lines on the narrowest
    /// phones) makes one plate taller than the other, or both taller than an icon over a line.
    func testEnglishBookplatesKeepWordsWhole() {
        let cases = [(TestLanguage.english, "UICTContentSizeCategoryL", "en-room-bar-default"),
                     (TestLanguage.english, "UICTContentSizeCategoryXXXL", "en-room-bar-xxxl"),
                     (TestLanguage.chinese, "UICTContentSizeCategoryXXXL", "zh-room-bar-xxxl")]
        for (language, size, name) in cases {
            let app = XCUIApplication()
            app.launchArguments = language + ["-MeowverseStore", "room-library-art", "-MeowverseResetStore",
                                              "-UIPreferredContentSizeCategoryName", size]
            app.launch()
            let photos = app.buttons["photo-library"], furniture = app.buttons["furniture-list"]
            XCTAssertTrue(furniture.waitForExistence(timeout: 20))
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
            XCTAssertEqual(photos.frame.height, furniture.frame.height, accuracy: 1, "\(name): plates differ in height")
            if name == "en-room-bar-default" {
                XCTAssertEqual(photos.label, "Photo library")
                XCTAssertEqual(furniture.label, "Furniture list")
                XCTAssertLessThanOrEqual(furniture.frame.height, 60, "\(name): label runs past one line")
            }
            app.terminate()
        }
    }

    func testLibrariesAndRoomPostcard() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "room-library-art", "-MeowverseResetStore"]
        app.launch()
        func snapshot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let photos = app.buttons["photo-library"]
        let furniture = app.buttons["furniture-list"]
        XCTAssertTrue(photos.waitForExistence(timeout: 20))
        verifyRoomControls(app)
        photos.tap()
        XCTAssertTrue(app.buttons["close-library"].waitForExistence(timeout: 10))
        app.buttons["close-library"].tap()
        furniture.tap()
        XCTAssertTrue(app.buttons["close-furniture-list"].waitForExistence(timeout: 10))
        app.buttons["close-furniture-list"].tap()
        XCTAssertTrue(photos.waitForExistence(timeout: 5))
        snapshot("room-libraries")
        app.buttons["open-room-share"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["room-postcard-ready"].waitForExistence(timeout: 25))
        snapshot("room-postcard")
        app.buttons["share-room-png"].tap()
        let sheet = app.descendants(matching: .any)
        let actions = ProcessInfo.processInfo.environment["MEOWVERSE_SAVE_POSTCARD"] == "1"
            ? ["Save Image", "保存图像", "存储图像"] : ["Copy", "拷贝"]
        let export = sheet.matching(NSPredicate(format: "label IN %@", actions)).firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        export.tap()
    }

    #if compiler(>=6.4)
    @MainActor
    func testVoiceOverOpensTheRoomCamera() throws {
        guard #available(iOS 27, *) else { throw XCTSkip("Requires the system VoiceOver service") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "room-overlay-speech",
                "-MeowverseResetStore", "-MeowverseLibraryIntro", "-photoLibraryLinkWanted", "NO"]
        app.launch()
        let camera = app.buttons["add-photo"]
        XCTAssertTrue(camera.waitForExistence(timeout: 15))
        let voiceOver = XCUIDevice.shared.voiceOverService
        let wasEnabled = voiceOver.isEnabled
        if !wasEnabled { try voiceOver.enable() }
        defer { if !wasEnabled { try? voiceOver.disable() } }
        let labels = Set(["照片库", "家具列表", "互动", "添加照片"])
        var heard = Set<String>()
        for _ in 0..<50 {
            let words = try voiceOver.moveForward().utterance
            heard.formUnion(labels.filter { words.contains($0) })
            if heard == labels && words.hasPrefix("添加照片") { break }
        }
        XCTAssertEqual(heard, labels)
        camera.doubleTap()
        XCTAssertTrue(app.buttons["library-intro-continue"].waitForExistence(timeout: 8))
    }
    #endif

    private func verifyRoomControls(_ app: XCUIApplication) {
        let room = app.descendants(matching: .any)["room-world"].firstMatch
        let controls = ["photo-library", "furniture-list", "choose-interaction", "add-photo"].map { app.buttons[$0] }
        for (index, button) in controls.enumerated() {
            XCTAssertTrue(room.frame.contains(button.frame), "Room overlay contains \(button.identifier)")
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            for other in controls.dropFirst(index + 1) {
                XCTAssertFalse(button.frame.intersects(other.frame))
            }
        }
    }
}
