import UIKit
import XCTest

/// 公告: the token is whole on screen and opens the panel. Plans show only while there are any.
final class RoomNewsUITests: XCTestCase {
    @MainActor
    func testNewsOpensFromTheTopBand() {
        check(extra: [])
    }

    /// The largest ordinary size is where five tagged tokens stop fitting on a narrow phone.
    @MainActor
    func testNewsFitsAtTheLargestOrdinarySize() {
        check(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
    }

    /// Whole on screen is not enough: five tokens once ran into each other in English at large type,
    /// the lock badge of one over the paper of the next. Every size, and a screenshot of each.
    @MainActor
    func testTokensKeepApartAtEveryOrdinarySize() {
        continueAfterFailure = true
        let ids = ["open-room-appearance", "open-room-sound", "open-room-manager", "open-cat-manager", "open-room-news"]
        let cases = [("en", "L"), ("en", "XL"), ("en", "XXL"), ("en", "XXXL"), ("zh-Hans", "L"), ("zh-Hans", "XXXL")]
        for (language, size) in cases {
            let app = XCUIApplication()
            app.launchArguments = ["-MeowverseStore", "RoomNewsApart", "-MeowverseResetStore",
                                   "-AppleLanguages", "(\(language))",
                                   "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategory\(size)"]
            app.launch()
            guard app.buttons["open-room-news"].waitForExistence(timeout: 30) else {
                XCTFail("no top band: \(language) \(size)")
                continue
            }
            let frames = ids.map { app.buttons[$0].firstMatch.frame }
            for (index, frame) in frames.enumerated() {
                XCTAssertTrue(app.frame.contains(frame), "\(language) \(size): \(ids[index]) runs off screen")
                guard index > 0 else { continue }
                let gap = frame.minX - frames[index - 1].maxX
                // Untagged tokens are solid circles and need more air than icons over tags.
                let needed: CGFloat = frame.width <= 48 ? 8 : 4
                XCTAssertGreaterThanOrEqual(gap, needed - 0.5, "\(language) \(size): \(gap) pt before \(ids[index])")
            }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "band-\(language)-\(size)"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    /// English at xxL read "Place furniture…" and "See how it wor…" on the empty room's card.
    @MainActor
    func testEmptyRoomActionsAreNotCutOffInEnglish() {
        continueAfterFailure = true
        let sizes: [(String, UIContentSizeCategory)] = [("L", .large), ("XL", .extraLarge), ("XXL", .extraExtraLarge)]
        for (name, category) in sizes {
            let app = XCUIApplication()
            app.launchArguments = ["-MeowverseStore", "RoomHintFits", "-MeowverseResetStore", "-AppleLanguages", "(en)",
                                   "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategory\(name)"]
            app.launch()
            let traits = UITraitCollection(preferredContentSizeCategory: category)
            let size = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).pointSize
            let font = UIFont.systemFont(ofSize: size, weight: .medium)
            for id in ["place-furniture-first", "open-guide"] {
                let button = app.buttons[id].firstMatch
                guard button.waitForExistence(timeout: 30) else { XCTFail("no \(id): \(name)"); continue }
                let needed = (button.label as NSString).size(withAttributes: [.font: font]).width
                XCTAssertGreaterThanOrEqual(button.frame.width, needed - 2, "\(name): \(button.label) is cut off")
            }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "hint-en-\(name)"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    @MainActor
    private func check(extra: [String]) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-MeowverseStore", "RoomNews", "-MeowverseResetStore"] + extra
        app.launch()
        let token = app.buttons["open-room-news"].firstMatch
        XCTAssertTrue(token.waitForExistence(timeout: 30))
        for id in ["open-room-appearance", "open-room-sound", "open-room-manager", "open-cat-manager", "open-room-news"] {
            let frame = app.buttons[id].firstMatch.frame
            XCTAssertTrue(app.frame.contains(frame), "\(id) runs off screen: \(frame)")
        }
        token.tap()
        for id in ["news-features", "news-thanks"] {
            XCTAssertTrue(app.staticTexts[id].waitForExistence(timeout: 20), id)
        }
        // The owner, 2026-11-24: 公告 says which version it is about and when it was last updated.
        let line = app.staticTexts["news-version"]
        XCTAssertTrue(line.waitForExistence(timeout: 20), "no version line")
        XCTAssertNotNil(line.label.range(of: #"\d+\.\d+"#, options: .regularExpression), line.label)
        XCTAssertTrue(line.label.contains("2026"), line.label)
        app.buttons["close-room-news"].firstMatch.tap()
        XCTAssertTrue(app.buttons["close-room-news"].waitForNonExistence(timeout: 20))
    }
}
