import simd
import XCTest

final class PlayLifecycleUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ store: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "play-lifecycle-" + store,
                               "-MeowverseSyntheticPhoto", "-MeowverseResetStore"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 20))
        return app
    }

    private func tap(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 15), id)
        for _ in 0..<6 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable, id)
        button.tap()
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func caption(_ app: XCUIApplication, contains word: String, timeout: TimeInterval = 40) {
        let match = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "bella-caption", word)).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: timeout), word)
    }

    private func choose(_ app: XCUIApplication, item: String, treat: Bool = false, change: Bool = false) {
        tap(app, change ? "change-play-item" : "choose-interaction")
        tap(app, treat ? "choose-treat" : "choose-toy")
        let picker = app.collectionViews.firstMatch
        let option = app.buttons["play-item-" + item]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        for _ in 0..<5 where !option.exists || !option.isHittable { picker.swipeUp() }
        tap(app, "play-item-" + item)
        XCTAssertTrue(app.buttons["place-play-item"].waitForExistence(timeout: 10))
    }

    private func expectTarget(_ app: XCUIApplication, x: Int, z: Int) {
        let target = "第 \(x + 1) 列，第 \(z + 1) 行"
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", target),
                                                     object: app.buttons["place-play-item"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, target)
    }

    private func settingsRow(_ settings: XCUIApplication, names: [String]) -> XCUIElement {
        let predicate = NSPredicate(format: "label IN %@", names)
        for query in [settings.cells, settings.buttons, settings.staticTexts] {
            let candidate = query.matching(predicate).firstMatch
            if candidate.exists { return candidate }
        }
        return settings.staticTexts.matching(predicate).firstMatch
    }

    private func openSettingsRow(_ settings: XCUIApplication, names: [String]) {
        var row = settingsRow(settings, names: names)
        for _ in 0..<4 where !row.exists {
            settings.swipeDown()
            row = settingsRow(settings, names: names)
        }
        for _ in 0..<7 where !row.exists || !row.isHittable {
            settings.swipeUp()
            row = settingsRow(settings, names: names)
        }
        XCTAssertTrue(row.exists && row.isHittable, "Settings row \(names)")
        row.tap()
    }

    private func systemReduceMotionSwitch(_ settings: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@",
                                    "Reduce Motion", "减弱动态效果")
        var toggle = settings.switches.matching(predicate).firstMatch
        if toggle.exists { return toggle }
        for _ in 0..<8 {
            if settings.navigationBars["Settings"].exists || settings.navigationBars["设置"].exists { break }
            let back = settings.navigationBars.buttons.firstMatch
            if !back.exists { break }
            back.tap()
        }
        openSettingsRow(settings, names: ["Accessibility", "辅助功能"])
        openSettingsRow(settings, names: ["Motion", "动态效果"])
        toggle = settings.switches.matching(predicate).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "system Reduce Motion switch")
        return toggle
    }

    private func waitForSwitch(_ toggle: XCUIElement, enabled: Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", enabled ? "1" : "0"),
                                                     object: toggle)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    private func reopenSystemSettings(_ settings: XCUIApplication) {
        settings.terminate()
        settings.launch()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        sleep(1)
    }

    private func setSystemReduceMotion(_ settings: XCUIApplication, enabled: Bool) {
        let desired = enabled ? "1" : "0"
        for attempt in 0..<3 {
            XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
            let toggle = systemReduceMotionSwitch(settings)
            if toggle.value as? String == desired { return }
            tapSystemSwitchThumb(toggle)
            if waitForSwitch(toggle, enabled: enabled) { return }
            if attempt < 2 { sleep(1) }
        }
        XCTAssertEqual(systemReduceMotionSwitch(settings).value as? String, desired,
                       "the actual system preference must reach the requested value")
    }

    private func tapSystemSwitchThumb(_ toggle: XCUIElement) {
        // Settings exposes the label and thumb as one wide switch accessibility frame.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.91, dy: 0.5)).tap()
    }

    private func expectRoomAbovePlayTray(_ app: XCUIApplication) {
        let room = app.descendants(matching: .any)["room-world"]
        let tray = app.descendants(matching: .any)["play-tray"]
        XCTAssertTrue(room.waitForExistence(timeout: 5))
        XCTAssertTrue(tray.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(room.frame.height, 220,
                                    "the room must retain enough height to show the cat")
        XCTAssertLessThanOrEqual(room.frame.maxY, tray.frame.minY + 1,
                                 "the play tray must occupy its own space below the room")
    }

    /// Project actual ground cells into the live full-room container, independent of phone size.
    private func floorPoint(_ app: XCUIApplication, x: Int, z: Int) -> XCUICoordinate {
        let room = app.descendants(matching: .any)["room-world"]
        XCTAssertTrue(room.waitForExistence(timeout: 10))
        let rect = room.frame
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
        let eye = SIMD3<Double>(14, 14.35, 17), center = SIMD3<Double>(0, 1.55, 0)
        let forward = simd_normalize(center - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3<Double>(0, 1, 0)))
        let up = simd_cross(right, forward)
        let horizontal = 1.5 * max(15.45, 11.4 * Double(rect.width / rect.height))
        let vertical = horizontal * Double(rect.height / rect.width)
        let offset = SIMD3<Double>(Double(x) - 7, 0, Double(z) - 7) - eye
        let screen = CGPoint(x: rect.minX + CGFloat(simd_dot(offset, right) / horizontal + 0.5) * rect.width,
                             y: rect.minY + CGFloat(0.5 - simd_dot(offset, up) / vertical) * rect.height)
        XCTAssertTrue(rect.contains(screen), "ground target must lie inside the room")
        return app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: screen.x - app.frame.minX, dy: screen.y - app.frame.minY))
    }

    func testChangingGaitTakesEffectDuringTheTripAndAtRest() {
        let app = launch("change-gait")
        tap(app, "add-synthetic")
        tap(app, "manual-sofa")
        tap(app, "next-model")
        tap(app, "next-placement")
        // Leave enough floor after the menu closes to observe the new running clip.
        let inward = app.buttons["向里移一格"]
        XCTAssertTrue(inward.waitForExistence(timeout: 10))
        for _ in 0..<5 { inward.tap() }
        for _ in 0..<3 { app.buttons["向左移一格"].tap() }
        tap(app, "confirm-placement")
        // The walking style is at the bottom of the 互动 panel.
        func selectGait(_ label: String) { app.selectGroundGait(label) }
        defer { selectGait("散步") }
        selectGait("慢步")
        app.terminate()
        app.launchArguments.removeAll { $0 == "-MeowverseResetStore" }
        app.launch()
        // The cat starts at the entrance with a long trip ahead of her to the sofa.
        caption(app, contains: "迈着慢步走向")
        selectGait("奔跑")
        caption(app, contains: "正跑向", timeout: 2)
        let settled = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (label ENDSWITH %@ OR label ENDSWITH %@ OR label ENDSWITH %@)",
            "bella-caption", "窝着", "坐着", "睡觉")).firstMatch
        XCTAssertTrue(settled.waitForExistence(timeout: 30))
        selectGait("慢步")
        caption(app, contains: "正迈着慢步", timeout: 4)
    }

    func testPhysicalTapAndDragMoveTheToyTarget() {
        let app = launch("touch")
        choose(app, item: "toyMouse")
        floorPoint(app, x: 3, z: 4).tap()
        expectTarget(app, x: 3, z: 4)
        caption(app, contains: "正在玩毛毡小鼠")
        snap("play-physical-tap")

        floorPoint(app, x: 3, z: 4).press(forDuration: 0.15,
                                         thenDragTo: floorPoint(app, x: 6, z: 5))
        expectTarget(app, x: 6, z: 5)
        caption(app, contains: "正在玩毛毡小鼠")
        snap("play-physical-drag")
        tap(app, "end-play")
        XCTAssertFalse(app.buttons["place-play-item"].exists)
        caption(app, contains: "在地上坐着", timeout: 10)
    }

    func testOccupiedFurnitureCellRejectsTheToyAndPreservesThePreviousTarget() {
        let app = launch("obstacle")
        tap(app, "add-synthetic")
        tap(app, "manual-chair")
        tap(app, "next-model")
        tap(app, "model-mv-chair-a") // replaced kenney-chair; also 2 × 2 by default
        tap(app, "next-placement")
        tap(app, "confirm-placement")
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 15))
        choose(app, item: "toyBall")
        floorPoint(app, x: 2, z: 6).tap()
        expectTarget(app, x: 2, z: 6)

        // The default 2×2 chair is centred at x=6, z=6 in the empty room.
        floorPoint(app, x: 6, z: 6).tap()
        expectTarget(app, x: 2, z: 6)
        let rejected = app.staticTexts.matching(NSPredicate(format:
            "identifier == %@ AND label CONTAINS %@", "play-feedback", "暂时到不了")).firstMatch
        XCTAssertTrue(rejected.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["original-photo"].exists)
        snap("play-rejects-occupied-furniture")

        floorPoint(app, x: 4, z: 2).tap()
        expectTarget(app, x: 4, z: 2)
        caption(app, contains: "正在玩拼色小球")
        snap("play-arrives-around-obstacle")
    }

    func testReplacingAnEatingTreatKeepsTheNewTreatUntilItsOwnConsumption() {
        let app = launch("replace-treat")
        choose(app, item: "treatSalmon", treat: true)
        tap(app, "place-play-item")
        caption(app, contains: "正在吃三文鱼小片")
        sleep(2)
        choose(app, item: "treatChicken", treat: true, change: true)
        XCTAssertEqual(app.buttons["place-play-item"].value as? String, "尚未放下")
        tap(app, "place-play-item")
        caption(app, contains: "正在吃鸡肉小块")
        sleep(2)
        XCTAssertNotEqual(app.buttons["place-play-item"].value as? String, "尚未放下")
        XCTAssertFalse(app.staticTexts["play-feedback"].label.contains("吃完了"))
        snap("replacement-treat-still-present")

        let finished = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "吃完了")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["place-play-item"].value as? String, "尚未放下")
        tap(app, "end-play")
        choose(app, item: "toyBall")
        tap(app, "place-play-item")
        caption(app, contains: "正在玩拼色小球")
        tap(app, "end-play")
        XCTAssertFalse(app.buttons["place-play-item"].exists)
    }

    func testBackgroundingPausesTreatConsumption() {
        let app = launch("background-treat")
        choose(app, item: "treatBiscuit", treat: true)
        tap(app, "place-play-item")
        caption(app, contains: "正在吃小鱼饼干")
        let target = app.buttons["place-play-item"].value as? String
        XCUIDevice.shared.press(.home)
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            [XCUIApplication.State.runningBackground, .runningBackgroundSuspended].contains(app.state)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 5), .completed)
        sleep(6)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertEqual(app.buttons["place-play-item"].value as? String, target)
        XCTAssertFalse(app.staticTexts["play-feedback"].label.contains("吃完了"))
        snap("treat-paused-after-background")
        let finished = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "吃完了")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["place-play-item"].value as? String, "尚未放下")
    }

    func testLargestRequestedTextSizeKeepsPlayControlsReachable() {
        let app = launch("large-text", extra: ["-UIPreferredContentSizeCategoryName",
                                               "UICTContentSizeCategoryAccessibilityXXXL"])
        choose(app, item: "featherWand")
        XCTAssertTrue(app.buttons["place-play-item"].isHittable)
        expectRoomAbovePlayTray(app)
        tap(app, "place-play-item")
        caption(app, contains: "正在玩羽毛逗猫棒")
        XCTAssertTrue(app.buttons["end-play"].isHittable)
        expectRoomAbovePlayTray(app)
        snap("play-largest-requested-text")
        tap(app, "end-play")
        choose(app, item: "treatChicken", treat: true)
        XCTAssertTrue(app.buttons["place-play-item"].isHittable)
        XCTAssertTrue(app.buttons["end-play"].isHittable)
        expectRoomAbovePlayTray(app)
        tap(app, "place-play-item")
        caption(app, contains: "正在吃鸡肉小块")
        expectRoomAbovePlayTray(app)
        snap("treat-largest-requested-text")
    }

    func testRealSystemReduceMotionIsObservedByTheRoomAndKeepsPlayOperable() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        reopenSystemSettings(settings)
        let toggle = systemReduceMotionSwitch(settings)
        let original = toggle.value as? String
        XCTAssertTrue(original == "0" || original == "1", "system switch must expose its actual state")
        addTeardownBlock { [self] in
            reopenSystemSettings(settings)
            setSystemReduceMotion(settings, enabled: original == "1")
            XCTAssertEqual(systemReduceMotionSwitch(settings).value as? String, original)
            snap("system-reduce-motion-restored")
        }
        setSystemReduceMotion(settings, enabled: true)
        snap("system-reduce-motion-enabled")

        let app = launch("reduce-motion")
        let room = app.descendants(matching: .any)["room-world"]
        let observed = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "value CONTAINS %@", "减弱动态效果已开启"), object: room)
        XCTAssertEqual(XCTWaiter.wait(for: [observed], timeout: 10), .completed,
                       "the live SwiftUI environment must observe the real system preference")
        choose(app, item: "featherWand")
        tap(app, "place-play-item")
        caption(app, contains: "正在玩羽毛逗猫棒")
        snap("play-real-system-reduce-motion")
        tap(app, "end-play")
        choose(app, item: "treatChicken", treat: true)
        tap(app, "place-play-item")
        caption(app, contains: "正在吃鸡肉小块")
        tap(app, "end-play")
        XCTAssertFalse(app.buttons["place-play-item"].exists)

        tap(app, "add-synthetic")
        XCTAssertTrue(app.buttons["manual-sofa"].waitForExistence(timeout: 10))
        for _ in 0..<5 where !app.buttons["manual-toy"].isHittable { app.swipeUp() }
        for id in ["manual-toy", "next-model", "model-mv-toy-d", "next-placement", "confirm-placement"] {
            tap(app, id)
        }
        let mouse = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查看照片")).firstMatch
        XCTAssertTrue(mouse.waitForExistence(timeout: 10))
        let home = try XCTUnwrap(mouse.value as? String)
        tap(app, "choose-interaction")
        tap(app, "invite-tail-play")
        caption(app, contains: "正在玩发条小鼠")
        let chasing = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "bella-caption", "正靠近发条小鼠")).firstMatch
        XCTAssertFalse(chasing.waitForExistence(timeout: 3))
        snap("wind-up-reduce-motion-contact")
        tap(app, "end-play")
        XCTAssertTrue(mouse.waitForExistence(timeout: 10))
        XCTAssertEqual(mouse.value as? String, home)
        snap("wind-up-reduce-motion-back-home")
    }


    // MARK: Cat pack switch during play

    /// The lead cat's pack key and exact floor position and heading (`-MeowverseCatProbe`).
    private struct CatProbe {
        let pack: String
        let x: Double, z: Double, yaw: Double
    }

    private func probe(_ app: XCUIApplication) -> CatProbe {
        let element = app.descendants(matching: .any)["bella-probe"]
        XCTAssertTrue(element.waitForExistence(timeout: 10), "cat probe")
        let parts = (element.value as? String ?? "").split(separator: " ").map(String.init)
        XCTAssertEqual(parts.count, 4, "cat probe value")
        guard parts.count == 4, let x = Double(parts[1]), let z = Double(parts[2]), let yaw = Double(parts[3]) else {
            return CatProbe(pack: "", x: .nan, z: .nan, yaw: .nan)
        }
        return CatProbe(pack: parts[0], x: x, z: z, yaw: yaw)
    }

    private func waitForCat(_ app: XCUIApplication, pack id: String, timeout: TimeInterval = 20) {
        let element = app.descendants(matching: .any)["bella-probe"]
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", ":\(id):"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout), .completed,
                       "the room must show the \(id) pack, got \(element.value as? String ?? "<none>")")
    }

    private func chooseCatPack(_ app: XCUIApplication, _ id: String) {
        // A built-in cat is chosen on her character card.
        if id == "bella" { app.chooseBuiltInCat(id); return }
        let row = app.buttons["cat-pack-" + id]
        tapCatModelRow(app, "cat-pack-" + id)
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed, "\(id) selected")
    }

    /// The cat model is in 猫咪管理 (in 设置 until round 10).
    private func openCatModels(_ app: XCUIApplication) {
        app.openCatManager()
    }

    /// The row may sit below the cats card: scroll until it can be tapped.
    private func tapCatModelRow(_ app: XCUIApplication, _ id: String) {
        let row = app.buttons[id]
        XCTAssertTrue(row.waitForExistence(timeout: 10), id)
        for _ in 0..<6 where !row.isHittable { app.swipeUp(velocity: .slow) }
        row.tap()
    }

    /// Imports a second valid pack (the bundled Bella files under another id), then goes back
    /// to the built-in Bella, so a later switch to `test-cat` reloads the cat in the room.
    private func launchWithSecondPack(_ store: String) throws -> XCUIApplication {
        let fixture = try CatPackUITests.makeFixturePack()
        let app = launch(store, extra: ["-MeowverseCatPackFile", fixture.path, "-MeowverseCatProbe"])
        openCatModels(app)
        tapCatModelRow(app, "drill-import-cat-pack")
        let notice = app.descendants(matching: .any)["cat-pack-notice"].firstMatch
        let imported = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已导入"), object: notice)
        XCTAssertEqual(XCTWaiter.wait(for: [imported], timeout: 20), .completed, "pack imported")
        chooseCatPack(app, "bella")
        tap(app, "close-home")
        waitForCat(app, pack: "bella")
        return app
    }

    /// Switches the pack through 猫咪管理 while she is at the play target, optionally
    /// staying on that page a while, and returns to the room.
    private func switchPack(_ app: XCUIApplication, to id: String, linger: UInt32) {
        openCatModels(app)
        chooseCatPack(app, id)
        if linger > 0 { sleep(linger) }
        tap(app, "close-home")
        waitForCat(app, pack: id)
    }

    private func expectSameContact(_ after: CatProbe, as before: CatProbe, _ context: String) {
        XCTAssertEqual(after.x, before.x, accuracy: 0.01, "\(context): x stays at the play contact")
        XCTAssertEqual(after.z, before.z, accuracy: 0.01, "\(context): z stays at the play contact")
        XCTAssertEqual(after.yaw, before.yaw, accuracy: 0.01, "\(context): she still faces the target")
    }

    /// R4-04: a treat being eaten survives a cat pack switch: she stays at the exact muzzle
    /// contact and finishes it, instead of standing on the cell centre and wandering off.
    private func treatSurvivesPackSwitch(_ app: XCUIApplication, linger: UInt32, context: String) {
        choose(app, item: "treatChicken", treat: true)
        tap(app, "place-play-item")
        caption(app, contains: "正在吃鸡肉小块")
        let before = probe(app)
        XCTAssertTrue(before.pack.contains(":bella:"), before.pack)
        // The switch must start part-way through the 4.8 s treat: what is left is eaten after it.
        XCTAssertFalse(app.staticTexts["play-feedback"].label.contains("吃完了"), "\(context): switched mid-treat")
        switchPack(app, to: "test-cat", linger: linger)
        let after = probe(app)
        snap("treat-after-pack-switch-" + context)
        continueAfterFailure = true
        let finished = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "吃完了")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 15), "\(context): the treat is finished after the switch")
        XCTAssertEqual(app.buttons["place-play-item"].value as? String, "尚未放下", "\(context): the treat is gone")
        expectSameContact(after, as: before, context)
    }

    func testSwitchingCatPackWhileEatingFinishesTheTreatAtItsContact() throws {
        let app = try launchWithSecondPack("pack-switch-treat")
        treatSurvivesPackSwitch(app, linger: 6, context: "linger")
        continueAfterFailure = false
        // Straight back, without staying in Settings.
        tap(app, "end-play")
        switchPack(app, to: "bella", linger: 0)
        treatSurvivesPackSwitch(app, linger: 0, context: "immediate")
    }

    func testSwitchingCatPackWhilePlayingKeepsTheToyInteraction() throws {
        let app = try launchWithSecondPack("pack-switch-toy")
        choose(app, item: "featherWand")
        tap(app, "place-play-item")
        caption(app, contains: "正在玩羽毛逗猫棒")
        sleep(1)
        let before = probe(app)
        switchPack(app, to: "test-cat", linger: 2)
        let after = probe(app)
        // An ordinary rest is 4.5 s; she must still be playing well after that.
        sleep(7)
        continueAfterFailure = true
        caption(app, contains: "正在玩羽毛逗猫棒", timeout: 1)
        expectSameContact(after, as: before, "toy")
        expectSameContact(probe(app), as: before, "toy later")
        snap("toy-after-pack-switch")
        continueAfterFailure = false
        tap(app, "end-play")
        XCTAssertFalse(app.buttons["place-play-item"].exists)
    }

    func testSwitchingCatPackWhileEatingWithReduceMotionFinishesTheTreat() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        reopenSystemSettings(settings)
        let original = systemReduceMotionSwitch(settings).value as? String
        XCTAssertTrue(original == "0" || original == "1", "system switch must expose its actual state")
        addTeardownBlock { [self] in
            reopenSystemSettings(settings)
            setSystemReduceMotion(settings, enabled: original == "1")
        }
        setSystemReduceMotion(settings, enabled: true)
        let app = try launchWithSecondPack("pack-switch-reduce-motion")
        let room = app.descendants(matching: .any)["room-world"]
        let observed = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "value CONTAINS %@", "减弱动态效果已开启"), object: room)
        XCTAssertEqual(XCTWaiter.wait(for: [observed], timeout: 10), .completed)
        treatSurvivesPackSwitch(app, linger: 3, context: "reduce-motion")
    }

}
