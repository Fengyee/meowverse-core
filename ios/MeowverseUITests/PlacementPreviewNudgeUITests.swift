import XCTest

/// 摆放 preview (1.0, art director's report 2026-11-24): after an arrow press the preview shows
/// the piece where it now stands, even when nothing else on screen changes afterwards.
/// `-MeowverseGhostProbe` reads the draft as drawn: "x z turn t models n state".
final class PlacementPreviewNudgeUITests: XCTestCase {
    private func openPlacement(_ store: String, quality: String = "auto") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseResetStore", "-MeowverseGhostProbe",
                                                      "-MeowverseQuality", quality]
        app.launch()
        let place = app.buttons["place-furniture-first"]
        XCTAssertTrue(place.waitForExistence(timeout: 25))
        place.tap()
        app.buttons["manual-sofa"].tap()
        app.buttons["next-model"].tap()
        let sofa = app.buttons["model-mv-sofa-e"].firstMatch
        _ = sofa.waitForExistence(timeout: 5)
        for _ in 0..<8 where !(sofa.exists && sofa.isHittable) { app.swipeUp(velocity: .slow) }
        sofa.tap()
        XCTAssertTrue(app.descendants(matching: .any)["model-preview-ready"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 15))
        return app
    }

    private func probe(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["placement-ghost-probe"].firstMatch
    }

    /// Waits until the probe reads `x z` with the model in the draft layer and the preview ready.
    private func expectDrawn(_ app: XCUIApplication, x: Int, z: Int, timeout: TimeInterval = 15,
                             file: StaticString = #filePath, line: UInt = #line) {
        let probe = probe(app)
        let wanted = "\(x) \(z) turn 0 models 1 ready"
        let deadline = Date().addingTimeInterval(timeout)
        var value = ""
        while Date() < deadline {
            value = probe.exists ? (probe.value as? String ?? "") : "no probe"
            if value == wanted { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTFail("preview reads \(value), expected \(wanted)", file: file, line: line)
    }

    private func start(_ app: XCUIApplication) -> (x: Int, z: Int) {
        let probe = probe(app)
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "no ghost probe")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !(probe.value as? String ?? "").hasSuffix("models 1 ready") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        let parts = (probe.value as? String ?? "").split(separator: " ")
        return (Int(parts.first ?? "") ?? -99, Int(parts.dropFirst().first ?? "") ?? -99)
    }

    private func attach(_ shot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// RGBA bytes of `rect` (points) of a screenshot.
    private func pixels(_ shot: XCUIScreenshot, _ rect: CGRect, screenWidth: CGFloat) throws -> (bytes: [UInt8], columns: Int) {
        let image = try XCTUnwrap(shot.image.cgImage)
        let scale = CGFloat(image.width) / screenWidth
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                                           width: rect.width * scale, height: rect.height * scale).integral))
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                              bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return (bytes, crop.width)
    }

    /// Where the sofa's crimson velvet shows in a screenshot of the preview: the centre of
    /// those pixels in points from the preview's corner, and how many there are.
    private func sofa(_ shot: XCUIScreenshot, in rect: CGRect, screenWidth: CGFloat) throws -> (centre: CGPoint, count: Int) {
        let (bytes, columns) = try pixels(shot, rect, screenWidth: screenWidth)
        var sum = CGPoint.zero, count = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
            guard r > 120, r - g > 70, r - b > 40 else { continue }
            let pixel = index / 4
            sum.x += CGFloat(pixel % columns)
            sum.y += CGFloat(pixel / columns)
            count += 1
        }
        guard count > 0 else { return (.zero, 0) }
        let scale = CGFloat(columns) / rect.width
        return (CGPoint(x: sum.x / CGFloat(count) / scale, y: sum.y / CGFloat(count) / scale), count)
    }

    /// The takes are shot the way a person looks: press, then nothing asks the app anything.
    /// A second and a half later the screen must show the sofa, one cell further in each time.
    func testTheIdleScreenShowsEachMove() throws {
        continueAfterFailure = false
        let app = openPlacement("nudge-preview-idle", quality: "high") // as the takes are shot
        let origin = start(app)
        let preview = app.descendants(matching: .any)["placement-preview"].firstMatch.frame
        let screenWidth = app.frame.width
        let back = app.buttons["向里移一格"]
        XCTAssertTrue(back.isHittable)
        sleep(1)
        let first = XCUIScreen.main.screenshot()
        attach(first, "idle-0")
        var last = try sofa(first, in: preview, screenWidth: screenWidth)
        XCTAssertGreaterThan(last.count, 400, "the sofa before any press")
        for step in 1...4 {
            back.tap()
            sleep(2) // no queries: the app is left alone, as while recording
            let idle = XCUIScreen.main.screenshot()
            attach(idle, "idle-\(step)")
            let seen = try sofa(idle, in: preview, screenWidth: screenWidth)
            XCTAssertGreaterThan(seen.count, 400, "after press \(step) the sofa is not on screen")
            let moved = hypot(seen.centre.x - last.centre.x, seen.centre.y - last.centre.y)
            XCTAssertGreaterThan(moved, 6, "after press \(step) the sofa on screen moved \(moved) pt")
            XCTAssertLessThan(seen.centre.y, last.centre.y, "after press \(step) the sofa on screen did not go further in")
            last = seen
        }
        expectDrawn(app, x: origin.x, z: origin.z - 4)
        XCTAssertTrue(app.buttons["confirm-placement"].isEnabled)
    }

    /// Presses 0.4 s apart: each one moves exactly one cell, and the piece ends up drawn.
    func testQuickArrowPressesMoveOneCellEach() {
        continueAfterFailure = false
        let app = openPlacement("nudge-preview-quick")
        let origin = start(app)
        let back = app.buttons["向里移一格"]
        let frame = back.frame
        let point = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))
        for _ in 1...4 {
            point.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        expectDrawn(app, x: origin.x, z: origin.z - 4)
        attach(XCUIScreen.main.screenshot(), "quick-4")
    }

    /// The draft's model loads once: moving it reuses that model, so 「正在载入 3D 模型…」 does not
    /// come back and 「确认摆放」 stays available between presses (l-placement-preview).
    func testMovingTheDraftKeepsItsLoadedModel() {
        continueAfterFailure = false
        let app = openPlacement("nudge-preview-reuse")
        let origin = start(app)
        let loads = app.descendants(matching: .any)["placement-ghost-loads-probe"].firstMatch
        XCTAssertTrue(loads.waitForExistence(timeout: 5), "no loads probe")
        let before = loads.value as? String ?? ""
        XCTAssertTrue(before.hasPrefix("loads 1 "), "after opening: \(before)")
        let confirm = app.buttons["confirm-placement"]
        XCTAssertTrue(confirm.isEnabled)
        let back = app.buttons["向里移一格"]
        let frame = back.frame
        let point = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))
        for step in 1...4 {
            point.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            XCTAssertTrue(confirm.isEnabled, "confirm disabled after press \(step)")
        }
        expectDrawn(app, x: origin.x, z: origin.z - 4)
        XCTAssertEqual(loads.value as? String, before, "the draft's model was loaded again or showed loading")
        XCTAssertTrue(confirm.isEnabled)
    }
}
