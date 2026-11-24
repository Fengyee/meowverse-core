import UIKit
import XCTest

final class PlacementDismissalUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testPhotoPlacementClearsTheBottomOfTheRoom() throws {
        try checkPlacement(entry: "add-synthetic", savedLabel: "查看照片")
    }

    func testCatalogPlacementClearsTheBottomOfTheRoom() throws {
        try checkPlacement(entry: "place-furniture-first", savedLabel: "还没有照片")
    }

    private func checkPlacement(entry: String, savedLabel: String) throws {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "dismiss-\(entry)",
                                                       "-MeowverseResetStore", "-MeowverseSyntheticPhoto"]
        app.launch()
        let start = app.buttons[entry]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        let screenWidth = app.frame.width
        let baseline = try bottomCorner(XCUIScreen.main.screenshot().image, screenWidth: screenWidth)
        start.tap()
        for id in ["manual-sofa", "next-model", "next-placement", "confirm-placement"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 15), id)
            button.tap()
        }
        let sofa = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "沙发", savedLabel)).firstMatch
        XCTAssertTrue(sofa.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["confirm-placement"].waitForNonExistence(timeout: 10))

        // UIKit can keep drawing a dismissed navigation bar after it leaves the accessibility tree.
        let deadline = Date.now.addingTimeInterval(4)
        var shot: XCUIScreenshot
        var changed: Double
        var consecutiveCleanFrames = 0
        repeat {
            shot = XCUIScreen.main.screenshot()
            let current = try bottomCorner(shot.image, screenWidth: screenWidth)
            let different = zip(baseline, current).filter { abs(Int($0.0) - Int($0.1)) > 48 }.count
            changed = Double(different) / Double(baseline.count)
            consecutiveCleanFrames = changed <= 0.01 ? consecutiveCleanFrames + 1 : 0
            if consecutiveCleanFrames == 2 { break }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date.now < deadline
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "room-after-\(entry)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(consecutiveCleanFrames, 2, "Placement did not clear the bottom safe area (changed fraction: \(changed))")
    }

    private func bottomCorner(_ image: UIImage, screenWidth: CGFloat) throws -> [UInt8] {
        let pixels = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(pixels.width) / screenWidth
        // Sample the back chevron, outside both the room buttons and the system home indicator.
        let rect = CGRect(x: 13 * scale, y: CGFloat(pixels.height) - 17 * scale, width: 40 * scale, height: 17 * scale)
        let crop = try XCTUnwrap(pixels.cropping(to: rect.integral))
        let context = try XCTUnwrap(CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                              bytesPerRow: crop.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: crop.width * crop.height))
    }
}
