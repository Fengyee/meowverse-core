import XCTest

/// Round 11: the cat's name on the Lock Screen's companion, and the Control Center buttons.
///
/// The Live Activity and Control Center follow the simulator's system language, not the app's
/// `-AppleLanguages`, so the springboard labels are matched in both languages.
/// SpringBoard's control gallery lists a newly installed extension's controls only after the
/// simulator restarts (`xcrun simctl shutdown` / `boot`): a fresh simulator needs one reboot after
/// the first install before `testControlCenterButtons` can find them.
final class PocketCatWatchControlsUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() { continueAfterFailure = false }

    /// Also written to `TEST_RUNNER_MV_SHOT_DIR` as `<MV_SHOT_PREFIX>-<name>.png` when set.
    private func snap(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let environment = ProcessInfo.processInfo.environment
        if let folder = environment["MV_SHOT_DIR"] {
            let prefix = environment["MV_SHOT_PREFIX"].map { $0 + "-" } ?? ""
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder + "/" + prefix + name + ".png"))
        }
    }

    private func launch(store: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseResetStore"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        return app
    }

    /// Ends any companion left over from an earlier test, from the app's companion page.
    private func endCompany(_ app: XCUIApplication) {
        app.buttons["choose-interaction"].tap()
        app.buttons["choose-pocket-cat"].tap()
        let end = app.buttons["pocket-end"]
        if end.waitForExistence(timeout: 3) { end.tap() }
        XCTAssertTrue(app.buttons["pocket-start"].waitForExistence(timeout: 10))
    }

    /// A fresh simulator asks once, on the Lock Screen or over the Home Screen.
    private func allowLiveActivities() {
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "Always Allow", "允许", "始终允许"])).firstMatch
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
            sleep(1)
        }
    }

    private func label(_ english: String, _ chinese: String) -> NSPredicate {
        NSPredicate(format: "label IN %@", [english, chinese])
    }

    // MARK: The name on the Lock Screen

    /// The cat's name replaces "Keep me company" on the Lock Screen, with an emoji kept whole,
    /// and is read out with the pixel cat.
    func testLockScreenShowsTheCatsName() throws {
        let name = "🍊小橘子"
        let app = launch(store: "pocket-name")
        app.buttons["open-settings"].tap()
        let field = app.textFields["cat-name-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.replaceText(with: name)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", name), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [saved], timeout: 10), .completed)
        app.buttons["close-settings"].tap()

        app.buttons["choose-interaction"].tap()
        app.buttons["choose-pocket-cat"].tap()
        let start = app.buttons["pocket-start"], end = app.buttons["pocket-end"]
        if end.waitForExistence(timeout: 3) { end.tap() }
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        app.buttons["pocket-select"].tap()
        app.buttons["在观察"].tap()
        start.tap()
        XCTAssertTrue(end.waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        XCUIDevice.shared.press(.home)
        allowLiveActivities()
        let named = springboard.images.matching(identifier: "pocket-rotating-cat")
            .matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(named.waitForExistence(timeout: 10), springboard.debugDescription)
        sleep(1)
        snap("lock-name")

        XCUIDevice.shared.press(.home)
        app.activate()
        if end.waitForExistence(timeout: 10) { end.tap() }
    }

    // MARK: The watch layout

    /// No watchOS 11 simulator here, so the `.small` layout is shot from the DEBUG gallery:
    /// short, emoji, long and missing names at the 40 mm and 49 mm Smart Stack sizes.
    func testWatchLayoutGallery() {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseOverlayGallery", "watch"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["pocket-watch-gallery"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Professor Whiskerton"].exists || app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Professor'")).firstMatch.exists)
        snap("watch-layout")
    }

    // MARK: Control Center

    private func openControlCenter() {
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.005))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.7)))
        XCTAssertTrue(addControls.waitForExistence(timeout: 10))
    }

    /// The "+" at the top left of Control Center.
    private var addControls: XCUIElement {
        springboard.buttons.matching(label("Add Controls", "添加控制")).firstMatch
    }

    /// "Add a Control" below the controls while editing. Found by place as well as by name: in
    /// Chinese the "+" at the top and this button can read alike.
    private func addAControl() -> XCUIElement? {
        let names = NSPredicate(format: "label == 'Add a Control' OR label BEGINSWITH '添加'")
        let half = springboard.frame.height / 2
        for _ in 0..<10 {
            if let button = springboard.buttons.matching(names).allElementsBoundByIndex.first(where: { $0.frame.minY > half }) {
                return button
            }
            sleep(1)
        }
        return nil
    }

    private func closeControlCenter() {
        XCUIDevice.shared.press(.home)
        sleep(1)
    }

    /// By name, or by name and the chosen expression ("陪我一会儿 · 在玩", round 11).
    private func controlButton(_ english: String, _ chinese: String) -> XCUIElement {
        let titled = NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", english + " · ", chinese + " · ")
        return springboard.buttons.matching(NSCompoundPredicate(orPredicateWithSubpredicates: [label(english, chinese), titled])).firstMatch
    }

    private let controls = [("Keep Me Company", "陪我一会儿"), ("Take Photo", "拍照添加"), ("Add from Photos", "从相册添加")]

    /// Puts the three controls in Control Center once; later runs find them already there.
    private func addControlsIfNeeded() throws {
        openControlCenter()
        let missing = controls.filter { !controlButton($0.0, $0.1).exists }
        guard !missing.isEmpty else { return }
        addControls.tap()
        for (index, control) in missing.enumerated() {
            let add = try XCTUnwrap(addAControl(), springboard.debugDescription)
            add.tap()
            let search = springboard.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            let clear = search.buttons.firstMatch
            if clear.exists { clear.tap() }
            let close = springboard.buttons.matching(label("Close", "关闭")).firstMatch
            if close.exists { close.tap() }
            let inGallery = controlButton(control.0, control.1)
            for _ in 0..<4 where !inGallery.isHittable { springboard.swipeUp() }
            XCTAssertTrue(inGallery.waitForExistence(timeout: 5),
                          "Not in the gallery; after a first install the simulator needs a reboot.")
            if index == 0 {
                sleep(1)
                snap("control-gallery")
            }
            inGallery.tap()
            // Adding closes the gallery and returns to editing.
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: search)
            XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 5), .completed, "the gallery stayed open")
            sleep(1)
        }
        // Leave editing with a tap on empty space in the middle. Not lower down: "Add a Control"
        // sits at about 0.9 of the height, and a tap there opens the gallery again.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        sleep(1)
        XCTAssertFalse(springboard.searchFields.firstMatch.exists)
    }

    /// "Keep Me Company" starts the companion without opening the app; "Add from Photos" and
    /// "Take Photo" open the app on the Home Screen quick actions' path.
    func testControlCenterButtons() throws {
        let app = launch(store: "pocket-controls", ["-MeowverseLibraryIntro", "-MeowverseFakeCamera"])
        endCompany(app)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))

        try addControlsIfNeeded()
        for control in controls { XCTAssertTrue(controlButton(control.0, control.1).exists, control.0) }
        snap("control-center")

        controlButton("Keep Me Company", "陪我一会儿").tap()
        sleep(2)
        XCTAssertNotEqual(app.state, .runningForeground, "the control opened the app")
        closeControlCenter()
        allowLiveActivities()
        XCTAssertTrue(springboard.images["pocket-rotating-cat"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertNotEqual(app.state, .runningForeground)
        snap("control-started-company")

        openControlCenter()
        controlButton("Add from Photos", "从相册添加").tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        // The explanation has one button, which goes on to the system alert (round 12, PRIVACY-2).
        XCTAssertTrue(app.buttons["library-intro-continue"].waitForExistence(timeout: 15))
        app.buttons["library-intro-continue"].tap()
        let deny = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow", "不允许"])).firstMatch
        if deny.waitForExistence(timeout: 10) { deny.tap() }
        if app.buttons["library-intro-done"].waitForExistence(timeout: 5) { app.buttons["library-intro-done"].tap() }
        // Resetting ends the app, so only once the test is over; a refusal left behind would
        // skip the system alert in the next test.
        addTeardownBlock { XCUIApplication().resetAuthorizationStatus(for: .photos) }

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        openControlCenter()
        controlButton("Take Photo", "拍照添加").tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let use = app.buttons["fake-camera-use"]
        if !use.waitForExistence(timeout: 15) {
            // The picker from the step before may still be closing.
            XCTAssertTrue(use.waitForExistence(timeout: 10), app.debugDescription)
        }
        app.buttons["fake-camera-cancel"].tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
        endCompany(app)
    }

    /// A system control beside ours, for the art director's size and weight check (C3). The
    /// simulator's gallery has no Flashlight or Camera (a search for "Flashlight" finds
    /// nothing), so the neighbour is the system Code Scanner. Best effort: a miss doesn't fail.
    private var systemNeighbour: NSPredicate {
        NSPredicate(format: "label IN %@", ["Code Scanner", "Scan Code", "扫描条码", "扫码"])
    }

    private func addSystemNeighbourIfNeeded() {
        openControlCenter()
        guard !springboard.buttons.matching(systemNeighbour).firstMatch.exists else { return }
        addControls.tap()
        if let add = addAControl() {
            add.tap()
            let inGallery = springboard.buttons.matching(systemNeighbour).firstMatch
            if inGallery.waitForExistence(timeout: 5) {
                inGallery.tap()
                sleep(2)
            } else {
                // Leave the gallery: swipe it down.
                springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
                    .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
                sleep(1)
            }
        }
        // Leave editing as `addControlsIfNeeded` does.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        sleep(1)
        closeControlCenter()
    }

    // MARK: The company toggle

    private var companyControl: XCUIElement { controlButton("Keep Me Company", "陪我一会儿") }

    /// What the toggle says about itself: its value text, or 1/0 if SpringBoard reports a switch.
    private func controlIsOn() -> Bool? {
        let value = (companyControl.value as? String) ?? String(describing: companyControl.value ?? "")
        if ["Keeping company", "陪伴中", "1"].contains(where: value.contains) { return true }
        if ["Not keeping company", "未陪伴", "0"].contains(where: value.contains) { return false }
        return nil
    }

    private func waitForControl(on: Bool, _ message: String) {
        for _ in 0..<15 where controlIsOn() != on { sleep(1) }
        XCTAssertEqual(controlIsOn(), on, "\(message): value \(String(describing: companyControl.value)), label \(companyControl.label)")
    }

    private var liveActivity: XCUIElement { springboard.images["pocket-rotating-cat"].firstMatch }

    /// Writes the springboard's tree next to the shots (and as an attachment), for finding
    /// the system's configuration sheet when it changes.
    private func dumpTree(_ name: String) {
        let tree = springboard.debugDescription
        let attachment = XCTAttachment(string: tree)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let environment = ProcessInfo.processInfo.environment
        if let folder = environment["MV_SHOT_DIR"] {
            let prefix = environment["MV_SHOT_PREFIX"].map { $0 + "-" } ?? ""
            try? tree.write(toFile: folder + "/" + prefix + name + ".txt", atomically: true, encoding: .utf8)
        }
    }

    private func controlNames(_ chinese: String, _ english: String) -> Bool {
        companyControl.label.hasSuffix(" · " + chinese) || companyControl.label.hasSuffix(" · " + english)
    }

    private static let moodWords = ["Sleeping", "Playing", "Zoomies", "Thinking", "Eating", "Watching",
                                    "睡觉中", "在玩", "在疯", "在思考", "在吃饭", "在观察"]

    /// Edit Control Center, open the control's settings, pick an expression, close the settings
    /// and leave editing. While editing, SpringBoard lists each control as an icon named by its
    /// display name; a tap opens the settings sheet (it shows a spinner first). The setting's
    /// value is a button named after the current choice, which opens a menu of the six.
    /// The sheet is found only after the simulator restarted once since the control became
    /// configurable: before that the tap does nothing.
    private func chooseExpression(_ chinese: String, _ english: String, shots: Bool = false) {
        addControls.tap()
        sleep(2)
        if shots { snap("control-editing") }
        let editing = springboard.icons.matching(NSPredicate(format: "identifier IN %@", ["Keep Me Company", "陪我一会儿"])).firstMatch
        XCTAssertTrue(editing.waitForExistence(timeout: 5), springboard.debugDescription)
        editing.tap()
        let current = springboard.buttons.matching(NSPredicate(format: "label IN %@", Self.moodWords)).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 15), "no settings sheet; restart the simulator once. \(springboard.debugDescription)")
        sleep(1)
        if shots { snap("control-configuration") }
        current.tap()
        sleep(1)
        if shots { snap("control-configuration-moods"); dumpTree("control-configuration-moods") }
        let choice = springboard.descendants(matching: .any).matching(label(english, chinese)).allElementsBoundByIndex
            .last(where: \.isHittable)
        XCTAssertNotNil(choice, springboard.debugDescription)
        choice?.tap()
        let chosen = springboard.buttons.matching(label(english, chinese)).firstMatch
        XCTAssertTrue(chosen.waitForExistence(timeout: 5), springboard.debugDescription)
        sleep(1)
        if shots { snap("control-configuration-chosen") }
        // Close the sheet with a tap above it, then leave editing as `addControlsIfNeeded` does.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        sleep(2)
        if springboard.buttons.matching(NSPredicate(format: "label IN %@", Self.moodWords)).firstMatch.exists {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
            sleep(2)
        }
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        sleep(2)
    }

    /// Owner, round 11: "Keep Me Company" works like the flashlight. It shows whether company is
    /// on, a tap turns it on without opening the app, and another tap ends the companion: the
    /// Live Activity goes, and the app's companion page offers to start again.
    func testCompanyControlIsAToggle() throws {
        let app = launch(store: "pocket-toggle")
        endCompany(app)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))

        try addControlsIfNeeded()
        closeControlCenter()
        addSystemNeighbourIfNeeded()
        openControlCenter()
        XCTAssertTrue(companyControl.exists)
        waitForControl(on: false, "no company yet")
        sleep(1)
        snap("control-off")

        // On: company starts, the app stays in the background.
        companyControl.tap()
        sleep(2)
        XCTAssertNotEqual(app.state, .runningForeground, "the control opened the app")
        closeControlCenter()
        allowLiveActivities()
        XCTAssertTrue(liveActivity.waitForExistence(timeout: 10), "no Live Activity after turning the control on")
        openControlCenter()
        waitForControl(on: true, "after turning it on")
        sleep(1)
        snap("control-on")

        // Off: the companion ends everywhere.
        companyControl.tap()
        waitForControl(on: false, "after turning it off")
        closeControlCenter()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: liveActivity)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "the Live Activity stayed after turning the control off")
        // Any Home Screen widget offers to start again.
        let change = springboard.buttons.matching(label("Change expression", "换个表情")).firstMatch
        XCTAssertFalse(change.exists, "a widget still shows company")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        // The companion page may still be open from the start of the test.
        let start = app.buttons["pocket-start"], end = app.buttons["pocket-end"]
        if !start.waitForExistence(timeout: 3) && !end.exists {
            app.buttons["choose-interaction"].tap()
            app.buttons["choose-pocket-cat"].tap()
        }
        XCTAssertTrue(start.waitForExistence(timeout: 10), "the companion page still shows company")
        XCTAssertFalse(end.exists)
    }

    /// Owner, round 11: the control can be set to start with a chosen expression, and says
    /// which in its title. A control placed before it had the setting starts on the default
    /// (asleep); set to 在玩, turning it on starts company on 在玩 without opening the app.
    /// Leaves the control as it found it: 1×1, on the default.
    ///
    /// At 1×1 Control Center draws only the icon, though VoiceOver reads the title; the test
    /// widens the control once to see the title drawn. With `MV_SHOT_DIR` set it writes the
    /// settings sheet, its menu and the wide control.
    func testCompanyControlStartsWithTheChosenExpression() throws {
        let app = launch(store: "pocket-toggle-mood")
        endCompany(app)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))

        try addControlsIfNeeded()
        closeControlCenter()
        openControlCenter()
        waitForControl(on: false, "no company yet")
        XCTAssertTrue(controlNames("睡觉中", "Sleeping"), "a control without a setting: \(companyControl.label)")

        chooseExpression("在玩", "Playing", shots: true)
        for _ in 0..<10 where !controlNames("在玩", "Playing") { sleep(1) }
        XCTAssertTrue(controlNames("在玩", "Playing"), companyControl.label)
        resizeCompanyControl(wide: true)
        let titled = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["陪我一会儿 · 在玩", "Keep Me Company · Playing"])).firstMatch
        XCTAssertTrue(titled.waitForExistence(timeout: 10), "label \(companyControl.label)")
        sleep(1)
        snap("control-wide-chosen")
        resizeCompanyControl(wide: false)
        waitForControl(on: false, "after choosing")

        // On: company starts on 在玩, the app stays in the background.
        companyControl.tap()
        sleep(2)
        XCTAssertNotEqual(app.state, .runningForeground, "the control opened the app")
        closeControlCenter()
        allowLiveActivities()
        XCTAssertTrue(liveActivity.waitForExistence(timeout: 10), "no Live Activity after turning the control on")
        app.activate()
        XCTAssertTrue(app.staticTexts.matching(identifier: "pocket-expression")
            .matching(NSPredicate(format: "label == %@", "在玩")).firstMatch.waitForExistence(timeout: 10),
                      "company didn't start on the chosen expression")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))

        // Off, and back to the default.
        openControlCenter()
        waitForControl(on: true, "after turning it on")
        companyControl.tap()
        waitForControl(on: false, "after turning it off")
        chooseExpression("睡觉中", "Sleeping")
        for _ in 0..<10 where !controlNames("睡觉中", "Sleeping") { sleep(1) }
        XCTAssertTrue(controlNames("睡觉中", "Sleeping"), companyControl.label)
        closeControlCenter()
    }

    /// While editing, drags the control's corner handle: one cell wider, or back to 1×1.
    private func resizeCompanyControl(wide: Bool) {
        addControls.tap()
        sleep(2)
        let editing = springboard.icons.matching(NSPredicate(format: "identifier IN %@", ["Keep Me Company", "陪我一会儿"])).firstMatch
        XCTAssertTrue(editing.waitForExistence(timeout: 5), springboard.debugDescription)
        let frame = editing.frame
        let origin = springboard.coordinate(withNormalizedOffset: .zero)
        let handle = origin.withOffset(CGVector(dx: frame.maxX - 6, dy: frame.maxY - 6))
        let to = wide ? frame.maxX + 160 : frame.minX + frame.height - 6
        handle.press(forDuration: 0.6, thenDragTo: origin.withOffset(CGVector(dx: to, dy: frame.maxY - 6)))
        sleep(2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        sleep(2)
        // A 1×1 control is about as wide as it is tall; the wide one about twice.
        let shape = companyControl.frame.width / max(companyControl.frame.height, 1)
        XCTAssertEqual(shape > 1.5, wide, "the control is \(companyControl.frame.size)")
    }
}
