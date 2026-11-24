import UIKit
import XCTest

final class PocketCatRotationUITests: XCTestCase {
    func testCompactCatShowsThreeExpressionsWithoutOpeningTheApp() throws {
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        try XCTSkipUnless(["iPhone16,1", "iPhone18,3"].contains(model), "Requires a tested compact Dynamic Island layout.")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "pocket-cat", "-MeowverseFastPocketCat"]
        app.launch()
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 20))
        app.buttons["choose-interaction"].tap()
        app.buttons["choose-pocket-cat"].tap()
        let end = app.buttons["pocket-end"]
        if end.exists { end.tap() }
        app.buttons["pocket-start"].tap()
        XCTAssertTrue(end.waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let portrait = springboard.images["pocket-rotating-cat"].firstMatch
        XCTAssertTrue(portrait.waitForExistence(timeout: 10))
        let count = try countStablePortraits(screenWidth: springboard.frame.width)
        XCTAssertNotEqual(app.state, .runningForeground)
        app.activate()
        end.tap()
        XCTAssertEqual(count, 3, "The background app's compact cat should show three distinct, stable portraits.")
    }

    private func countStablePortraits(screenWidth: CGFloat) throws -> Int {
        var seen = Set<Data>()
        var previous: Data?
        let deadline = Date.now.addingTimeInterval(25)
        while seen.count < 3, Date.now < deadline {
            // The system's accessible frame can move independently of the composited artwork.
            // Sample the leading image inside the black capsule on the two supported simulators.
            let screen = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
            let scale = CGFloat(screen.width) / screenWidth
            let portrait = CGRect(x: screenWidth / 2 - 84, y: 22, width: 23, height: 21)
            let crop = try XCTUnwrap(screen.cropping(to: portrait.applying(.init(scaleX: scale, y: scale)).integral))
            let image = UIImage(cgImage: crop)
            let data = try XCTUnwrap(image.pngData())
            // Ignore transient system animation frames by requiring two successive identical samples.
            if previous == data, seen.insert(data).inserted {
                let attachment = XCTAttachment(image: image)
                attachment.name = "Compact cat expression \(seen.count)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            previous = data
            Thread.sleep(forTimeInterval: 0.65)
        }
        return seen.count
    }
}
