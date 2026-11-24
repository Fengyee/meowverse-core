import UIKit
import XCTest

/// 设置 › 画质 (2026-11-20): 自动 by default, a choice that survives a relaunch and takes effect
/// in the room at once, and the one-step drop when the device runs hot on 自动.
/// `-MeowverseQualityMemory 8` stands in for an 8 GB device (自动 = 高), and
/// `-MeowverseQualityProbe` reads back what the room view really draws with.
final class RenderQualityUITests: XCTestCase {
    private func arguments(reset: Bool, _ extra: [String] = []) -> [String] {
        TestLanguage.chinese + ["-MeowverseStore", "render-quality", "-MeowverseQualityProbe", "-MeowverseQualityMemory", "8"]
            + (reset ? ["-MeowverseResetStore"] : []) + extra
    }

    private func probe(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["room-quality-probe"].firstMatch
    }

    private func expectProbe(_ app: XCUIApplication, _ value: String, timeout: TimeInterval = 10,
                             file: StaticString = #filePath, line: UInt = #line) {
        let probe = probe(app)
        XCTAssertTrue(probe.waitForExistence(timeout: 20), "no quality probe", file: file, line: line)
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout), .completed,
                       "probe says \(probe.value as? String ?? "nothing"), expected \(value)", file: file, line: line)
    }

    /// Opens 设置 and scrolls to the 画质 row, the last one.
    private func openRow(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20), file: file, line: line)
        settings.tap()
        let row = app.buttons["open-render-quality"]
        _ = row.waitForExistence(timeout: 3)
        for _ in 0..<10 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.exists && row.isHittable, "could not reach the 画质 row", file: file, line: line)
        // The footer under it is only in the tree once it is on screen.
        let footer = app.staticTexts["render-quality-footer"]
        for _ in 0..<3 where !footer.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(footer.waitForExistence(timeout: 3), "no 画质 footer", file: file, line: line)
        return row
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor private var highProbe: String {
        String(format: "scale %.2f shadows on", Double(min(3, UIScreen.main.scale)))
    }

    @MainActor func testPlacedSofaChangesGraphicsTierAndRebuildsShadowAfterRotation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = arguments(reset: true, ["-MeowverseFurnitureTextureProbe", "-MeowverseQuality", "high"])
        app.launch()
        let place = app.buttons["place-furniture-first"]
        XCTAssertTrue(place.waitForExistence(timeout: 25))
        place.tap()
        app.buttons["manual-sofa"].tap()
        app.buttons["next-model"].tap()
        let sofa = app.buttons["model-mv-sofa-e"].firstMatch
        _ = sofa.waitForExistence(timeout: 5)
        for _ in 0..<8 where !(sofa.exists && sofa.isHittable) { app.swipeUp(velocity: .slow) }
        if !sofa.isHittable { snap(app, "sofa-catalog") }
        XCTAssertTrue(sofa.isHittable, app.debugDescription)
        sofa.tap()
        XCTAssertTrue(app.descendants(matching: .any)["model-preview-ready"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["next-placement"].tap()
        let confirm = app.buttons["confirm-placement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        confirm.tap()
        let allDetails = highProbe + " albedos 256,256 occlusion 4 hdr on floor on maps 4,4"
        expectProbe(app, allDetails)
        snap(app, "high-sofa")

        for (tier, value) in [
            ("medium", "scale 1.75 shadows on albedos 128,128 occlusion 4 hdr off floor off maps 0,0"),
            ("low", "scale 1.50 shadows off albedos none occlusion 4 hdr off floor off maps 0,0"),
            ("high", allDetails),
        ] {
            openRow(app).tap()
            let choice = app.buttons["render-quality-" + tier]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.buttons["close-settings"].tap()
            expectProbe(app, value)
            snap(app, "\(tier)-sofa")
        }

        let piece = app.buttons["room-piece-without-photos"].firstMatch
        XCTAssertTrue(piece.waitForExistence(timeout: 10))
        let room = app.descendants(matching: .any)["room-world"].firstMatch
        piece.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1, thenDragTo: room.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58)))
        let rotate = app.buttons["edit-rotate"]
        XCTAssertTrue(rotate.waitForExistence(timeout: 10))
        rotate.tap()
        let done = app.buttons["edit-done"]
        XCTAssertTrue(done.isEnabled, app.staticTexts["edit-status"].label)
        done.tap()
        expectProbe(app, allDetails)
        snap(app, "high-sofa-turned")
    }

    @MainActor func testDefaultIsAutoAndLowSurvivesARelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = arguments(reset: true)
        app.launch()
        // 自动 on an 8 GB device is 高: the room as it always was (at most 2× pixels, sun shadows).
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20))
        expectProbe(app, highProbe)
        snap(app, "room-quality-high")

        var row = openRow(app)
        XCTAssertTrue(row.label.contains("自动"), "row reads \(row.label)")
        XCTAssertEqual(app.staticTexts["render-quality-footer"].label, "自动：按这台设备的内存用「高」。")
        snap(app, "settings-quality-row")
        row.tap()
        let auto = app.buttons["render-quality-auto"], low = app.buttons["render-quality-low"]
        XCTAssertTrue(auto.waitForExistence(timeout: 5))
        XCTAssertTrue(auto.isSelected)
        XCTAssertFalse(low.isSelected)
        snap(app, "settings-quality-page")
        low.tap()
        XCTAssertTrue(low.isSelected)
        XCTAssertFalse(auto.isSelected)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("低"), "row reads \(row.label)")
        app.buttons["close-settings"].tap()
        // At once, without a relaunch.
        expectProbe(app, "scale 1.50 shadows off")
        snap(app, "room-quality-low")

        app.terminate()
        app.launchArguments = arguments(reset: false)
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20))
        expectProbe(app, "scale 1.50 shadows off")
        row = openRow(app)
        XCTAssertTrue(row.label.contains("低"), "row reads \(row.label)")
        row.tap()
        XCTAssertTrue(low.waitForExistence(timeout: 5))
        XCTAssertTrue(low.isSelected)
    }

    /// On 自动 the device running hot drops one step (高 → 中) with a short notice; the user's
    /// own choice then wins again.
    @MainActor func testRunningHotOnAutoDropsOneStepWithANotice() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = arguments(reset: true, ["-MeowverseQualityThermal", "serious", "-MeowverseQualityThermalAfter", "25"])
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20))
        // Not hot yet.
        expectProbe(app, highProbe, timeout: 3)
        let notice = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "设备有点热")).firstMatch
        XCTAssertFalse(notice.exists)
        XCTAssertTrue(notice.waitForExistence(timeout: 45), "no notice for the heat")
        XCTAssertEqual(notice.label, "设备有点热，画质先降到「中」，下次打开 App 时恢复。")
        snap(app, "room-quality-hot-notice")
        expectProbe(app, "scale 1.75 shadows on")

        let row = openRow(app)
        XCTAssertTrue(row.label.contains("自动"), "row reads \(row.label)")
        XCTAssertEqual(app.staticTexts["render-quality-footer"].label, "自动：设备刚才发热，这次先用「中」，下次打开 App 时恢复「高」。")
        row.tap()
        let high = app.buttons["render-quality-high"]
        XCTAssertTrue(high.waitForExistence(timeout: 5))
        high.tap()
        XCTAssertTrue(high.isSelected)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["close-settings"].tap()
        expectProbe(app, highProbe)
    }
}
