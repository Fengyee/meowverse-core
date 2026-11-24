import XCTest

/// VISUAL-1: the primary buttons' words keep 4.5:1 in dark mode, measured on the pixels.
/// `XCUIDevice.appearance` does not reach the app, so switch first and say so:
///
///     xcrun simctl ui <udid> appearance dark
///     TEST_RUNNER_MV_APPEARANCE=dark xcodebuild … -only-testing:MeowverseUITests/PrimaryButtonContrastUITests
///
/// `TEST_RUNNER_MV_SHOT_DIR=<absolute folder>` keeps the screenshots. AR always draws dark, and
/// `-MeowverseARDrill` shows the two states the simulator cannot reach.
final class PrimaryButtonContrastUITests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(environment["MV_APPEARANCE"] != nil, "switch the simulator's appearance and set TEST_RUNNER_MV_APPEARANCE")
    }

    func testEditDone() {
        let app = launch(store: "ink-edit", ["-MeowverseSyntheticPhoto"])
        app.buttons["add-synthetic"].tap()
        tap(app.buttons["manual-sofa"], timeout: 20)
        app.buttons["next-model"].tap()
        tap(app.buttons["next-placement"])
        tap(app.buttons["confirm-placement"])
        let sofa = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查看照片")).firstMatch
        XCTAssertTrue(sofa.waitForExistence(timeout: 15))
        sleep(1)
        sofa.press(forDuration: 1)
        assertReadable(app.buttons["edit-done"], "edit-done")
    }

    func testShareBackup() {
        let app = launch(store: "ink-backup")
        app.tapSettingsGear()
        let export = app.descendants(matching: .any)["export-backup"].firstMatch
        for _ in 0..<8 where !(export.exists && export.isHittable) { app.swipeUp(velocity: .slow) }
        export.tap()
        let share = app.descendants(matching: .any)["share-backup"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 30))
        for _ in 0..<4 where !share.isHittable { app.swipeUp(velocity: .slow) }
        assertReadable(share, "share-backup")
    }

    func testARPlaceHere() {
        assertReadable(openAR(drill: "controls").buttons["ar-place"], "ar-place")
    }

    func testAROpenSystemSettings() {
        assertReadable(openAR(drill: "camera-off").buttons["ar-open-settings"], "ar-open-settings")
    }

    /// The two pages of a room that didn't open, made on disk: a library that can't be read...
    func testRetryOpening() throws {
        let library = try madeLibrary("ink-closed")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: library.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path) }
        let app = relaunch("ink-closed")
        assertReadable(app.buttons["重试"], "retry-opening")
    }

    /// ...and one whose records are damaged.
    func testRestoreFromBackup() throws {
        let library = try madeLibrary("ink-corrupt")
        for name in ["state.json", "state.backup.json"] {
            try Data("not a library".utf8).write(to: library.appending(path: name))
        }
        assertReadable(relaunch("ink-corrupt").buttons["restore-backup"], "restore-backup")
    }

    // MARK: Steps

    /// Saved once, then found from the runner: both containers are in one folder on the simulator.
    private func madeLibrary(_ store: String) throws -> URL {
        let app = launch(store: store, ["-MeowverseSyntheticPhoto"])
        app.buttons["add-synthetic"].tap()
        tap(app.buttons["photo-only"], timeout: 20)
        XCTAssertTrue(app.buttons["close-library"].waitForExistence(timeout: 10))
        app.terminate()
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let found = try FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil)
            .map { $0.appending(path: "Library/Application Support/Meowverse/Test-" + store) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        return try XCTUnwrap(found, "no library on disk")
    }

    private func relaunch(_ store: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store]
        app.launch()
        return app
    }

    private func launch(store: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseResetStore"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30))
        return app
    }

    private func openAR(drill: String) -> XCUIApplication {
        let app = launch(store: "ink-ar", ["-MeowverseShowAREntry", "-MeowverseARDrill", drill])
        app.buttons["choose-interaction"].tap()
        tap(app.buttons["open-ar-tabletop"])
        return app
    }

    private func tap(_ element: XCUIElement, timeout: TimeInterval = 10) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element)")
        element.tap()
    }

    /// The fill is the commonest colour inside the button; the words are the colour furthest
    /// from it that covers at least half a percent of those pixels, which edges do not.
    private func assertReadable(_ button: XCUIElement, _ name: String) {
        XCTAssertTrue(button.waitForExistence(timeout: 15), name)
        sleep(1)
        let screen = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screen)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        if let folder = environment["MV_SHOT_DIR"] {
            let prefix = environment["MV_SHOT_PREFIX"].map { $0 + "-" } ?? ""
            try? screen.pngRepresentation.write(to: URL(fileURLWithPath: "\(folder)/\(prefix)\(name).png"))
        }
        guard let image = screen.image.cgImage else { return XCTFail("no screenshot") }
        let scale = CGFloat(image.width) / XCUIApplication().windows.firstMatch.frame.width
        let frame = button.frame
        // Inside the rounded ends, so nothing behind the button is counted.
        let inside = frame.insetBy(dx: frame.height * 0.4, dy: frame.height * 0.18)
        let pixels = CGRect(x: inside.minX * scale, y: inside.minY * scale, width: inside.width * scale, height: inside.height * scale).integral
        guard let crop = image.cropping(to: pixels) else { return XCTFail("\(name) is off the screen: \(frame)") }
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                    bytesPerRow: crop.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        var counts: [UInt32: Int] = [:]
        for index in stride(from: 0, to: bytes.count, by: 4) {
            // Within 4 levels is the same colour.
            let key = UInt32(bytes[index] & 0xFC) << 16 | UInt32(bytes[index + 1] & 0xFC) << 8 | UInt32(bytes[index + 2] & 0xFC)
            counts[key, default: 0] += 1
        }
        guard let fill = counts.max(by: { $0.value < $1.value })?.key else { return XCTFail("empty crop") }
        let least = crop.width * crop.height / 200
        let words = counts.filter { $0.value >= least }.map(\.key).max { contrast($0, fill) < contrast($1, fill) } ?? fill
        let ratio = contrast(words, fill)
        let line = String(format: "CONTRAST %@ %@ #%06X on #%06X %.2f:1", environment["MV_APPEARANCE"] ?? "", name, words, fill, ratio)
        print(line)
        XCTAssertGreaterThanOrEqual(ratio, 4.5, line)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func luminance(_ colour: UInt32) -> Double {
        func linear(_ shift: UInt32) -> Double {
            let value = Double((colour >> shift) & 0xFF) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }
}
