import UIKit
import XCTest

/// Measures the on-screen frame of every control the onboarding tour (docs/onboarding) wants to
/// highlight, on the device the test runs on. Nothing is asserted about the app: a control that
/// is missing is recorded as `found: false`. The result is one JSON file, attached to the test
/// and also written to `$TOUR_FRAMES_OUT` (pass it as `TEST_RUNNER_TOUR_FRAMES_OUT`), together
/// with one screenshot per page so the frames can be drawn back onto the picture.
///
/// The synthetic photo and batch only provide a sofa and pending photos to measure; nothing
/// from here appears in a product screen. Run one device at a time, only this class.
final class TourTargetFramesUITests: XCTestCase {
    private struct Record: Encodable {
        var id: String
        var found: Bool
        var frame: [Double]?
        var hittable: Bool?
        var type: String?
        var label: String?
    }

    private struct Page: Encodable {
        var page: String
        var screenshot: String?
        var targets: [Record]
    }

    private var pages: [Page] = []
    private var outFolder: URL = URL(fileURLWithPath: NSTemporaryDirectory())
    private var tag = "device"

    override func setUp() {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["TOUR_FRAMES_OUT"], !path.isEmpty { outFolder = URL(fileURLWithPath: path, isDirectory: true) }
        tag = environment["TOUR_FRAMES_TAG"] ?? environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "device"
        try? FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
    }

    // MARK: Helpers

    private func launch(store: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.current + ["-MeowverseStore", store, "-MeowverseSyntheticPhoto"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 30), "the room did not open")
        sleep(2)
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func record(_ element: XCUIElement, id: String, wait: TimeInterval = 2) -> Record {
        guard element.waitForExistence(timeout: wait) else { return Record(id: id, found: false) }
        let f = element.frame
        func r(_ v: CGFloat) -> Double { (Double(v) * 100).rounded() / 100 }
        return Record(id: id, found: true, frame: [r(f.minX), r(f.minY), r(f.width), r(f.height)],
                      hittable: element.isHittable, type: "\(element.elementType.rawValue)", label: element.label)
    }

    /// Records `ids` (and optional predicate-found extras) as one page, with a screenshot.
    private func measure(_ app: XCUIApplication, page: String, ids: [String], extras: [(String, XCUIElement)] = [], wait: TimeInterval = 2) {
        sleep(1)
        let name = "\(tag)-\(page)"
        let shot = XCUIScreen.main.screenshot()
        try? shot.pngRepresentation.write(to: outFolder.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        var targets = ids.map { record(element(app, $0), id: $0, wait: wait) }
        targets += extras.map { record($0.1, id: $0.0, wait: wait) }
        pages.append(Page(page: page, screenshot: "\(name).png", targets: targets))
    }

    private func tapIfThere(_ element: XCUIElement, wait: TimeInterval = 5) -> Bool {
        guard element.waitForExistence(timeout: wait) else { return false }
        element.tap()
        return true
    }

    private func writeResult(app: XCUIApplication) throws {
        struct Output: Encodable {
            var tag: String
            var model: String
            var idiom: String
            var os: String
            var screen: [Double]
            var window: [Double]
            var pages: [Page]
        }
        let screen = XCUIScreen.main.screenshot().image
        let window = app.windows.firstMatch.frame
        let output = Output(
            tag: tag,
            model: ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "",
            idiom: UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone",
            os: UIDevice.current.systemVersion,
            screen: [Double(screen.size.width), Double(screen.size.height), Double(screen.scale)],
            window: [Double(window.minX), Double(window.minY), Double(window.width), Double(window.height)],
            pages: pages)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(output)
        try data.write(to: outFolder.appendingPathComponent("\(tag).json"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "\(tag).json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private let topBar = ["room-switcher", "open-settings", "open-room-appearance", "open-room-sound",
                          "open-room-share", "open-room-manager", "open-cat-manager"]
    private let roomBase = ["room-world", "bella-caption", "add-photo", "choose-interaction", "photo-library",
                            "furniture-list", "room-storage"]

    // MARK: The walk

    func testMeasureTourTargets() throws {
        let app = launch(store: "tour-frames", extra: ["-MeowverseResetStore"])

        // 1. Empty room (chapters 1 to 5).
        measure(app, page: "room-empty", ids: roomBase + topBar + ["place-furniture-first", "open-guide", "empty-room-help",
                                                                    "add-synthetic", "restore-backup"])

        // 2. 互动 with no furniture (chapter 4; chapter 13 on a device that can track the world).
        if tapIfThere(app.buttons["choose-interaction"]) {
            _ = element(app, "choose-toy").waitForExistence(timeout: 10)
            measure(app, page: "interaction-empty", ids: ["choose-toy", "choose-treat", "choose-pocket-cat", "open-ar-tabletop"],
                    extras: [("ground-gait-first", app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ground-gait-'")).firstMatch),
                             ("navigation-bar", app.navigationBars.firstMatch),
                             ("cancel", app.navigationBars.buttons["close-interaction"])])
            _ = tapIfThere(app.navigationBars.buttons["close-interaction"])
            _ = app.buttons["add-photo"].waitForExistence(timeout: 10)
        }

        // 3. 设置 and 猫咪管理 (chapters 5, 14, 15).
        if tapIfThere(app.buttons["open-settings"]) {
            _ = element(app, "close-settings").waitForExistence(timeout: 10)
            measure(app, page: "settings", ids: ["close-settings", "open-cats-from-settings", "storage-usage", "export-backup",
                                                 "open-icloud-backup", "open-reminders", "open-feedback", "open-about"])
            _ = tapIfThere(app.buttons["close-settings"])
            _ = app.buttons["add-photo"].waitForExistence(timeout: 10)
        }
        if tapIfThere(app.buttons["open-cat-manager"]) {
            _ = element(app, "home-manager").waitForExistence(timeout: 10)
            measure(app, page: "cat-manager", ids: ["home-manager", "close-home", "cat-row", "cat-row-menu"])
            _ = tapIfThere(app.buttons["close-home"])
            _ = app.buttons["add-photo"].waitForExistence(timeout: 10)
        }

        // 4. One synthetic sofa (chapters 6, 7, 10, 11).
        app.buttons["add-synthetic"].tap()
        for id in ["manual-sofa", "next-model", "next-placement", "confirm-placement"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 20), id)
            button.tap()
        }
        let sofa = app.buttons.matching(identifier: "room-piece-with-photos").firstMatch
        // A small screen can need a second tap on 确认摆放 before the room is back.
        if !sofa.waitForExistence(timeout: 20), app.buttons["confirm-placement"].exists {
            app.buttons["confirm-placement"].tap()
        }
        guard sofa.waitForExistence(timeout: 40) else {
            XCTFail("the sofa is not in the room")
            measure(app, page: "room-after-placement-failed", ids: roomBase)
            try writeResult(app: app)
            return
        }
        _ = element(app, "photo-storage-receipt").waitForNonExistence(timeout: 20)
        measure(app, page: "room-furniture", ids: roomBase + topBar + ["pending-count", "start-sorting"],
                extras: [("furniture-hotspot-sofa", sofa)])

        // 5. Long press: the placement tray (chapter 7 step 2).
        sofa.press(forDuration: 1)
        if element(app, "edit-tray").waitForExistence(timeout: 5) {
            measure(app, page: "room-edit", ids: ["edit-tray", "edit-rotate", "edit-done", "edit-cancel", "edit-status", "room-world"],
                    extras: [("furniture-hotspot-sofa", sofa)])
            _ = tapIfThere(app.buttons["edit-cancel"])
            _ = app.buttons["add-photo"].waitForExistence(timeout: 10)
        }

        // 6. The furniture's detail (chapter 6 step 2).
        sofa.tap()
        if element(app, "original-photo").waitForExistence(timeout: 15) {
            measure(app, page: "furniture-detail", ids: ["add-source-photo", "furniture-more", "original-photo", "close-detail"])
            _ = tapIfThere(app.buttons["close-detail"])
            _ = app.buttons["add-photo"].waitForExistence(timeout: 10)
        }

        // 7. 互动 with a sofa (chapter 11).
        if tapIfThere(app.buttons["choose-interaction"]) {
            _ = element(app, "choose-toy").waitForExistence(timeout: 10)
            let invite = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'invite-'")).firstMatch
            measure(app, page: "interaction-furniture", ids: ["choose-toy", "choose-treat", "choose-pocket-cat", "open-ar-tabletop"],
                    extras: [("invite-first", invite),
                             ("ground-gait-first", app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ground-gait-'")).firstMatch),
                             ("navigation-bar", app.navigationBars.firstMatch)])
            _ = tapIfThere(app.navigationBars.buttons["close-interaction"])
            _ = app.buttons["add-photo"].waitForExistence(timeout: 10)
        }

        // 8. 照片库 (chapter 9).
        if tapIfThere(app.buttons["photo-library"]) {
            _ = element(app, "close-library").waitForExistence(timeout: 10)
            let filters = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'filter-' AND NOT identifier BEGINSWITH 'filter-furniture'"))
            measure(app, page: "photo-library", ids: ["close-library", "select-photos", "filter-furniture", "sort-unlinked", "library-photo"],
                    extras: [("filter-first", filters.element(boundBy: 0)), ("filter-second", filters.element(boundBy: 1)),
                             ("filter-third", filters.element(boundBy: 2))])
            _ = tapIfThere(app.buttons["close-library"])
            _ = app.buttons["add-photo"].waitForExistence(timeout: 10)
        }

        // 9. 家具库 (chapter 10).
        if tapIfThere(app.buttons["furniture-list"]) {
            _ = element(app, "close-furniture-list").waitForExistence(timeout: 10)
            measure(app, page: "furniture-list", ids: ["close-furniture-list", "add-furniture", "place-all", "place-room", "place-stored",
                                                        "furniture-filter", "furniture-sort", "furniture-layout", "select-furniture", "piece-menu"])
            // Stow the sofa, so that 收纳箱 has something and the room's chest can be measured with contents.
            if tapIfThere(app.buttons["piece-menu"]), tapIfThere(app.buttons[AppText.string("收进收纳箱")]) {
                sleep(1)
                _ = tapIfThere(app.buttons["place-stored"])
                measure(app, page: "furniture-list-stored", ids: ["close-furniture-list", "add-furniture", "place-all", "place-room", "place-stored",
                                                                   "list-stored-item"])
            }
            _ = tapIfThere(app.buttons["close-furniture-list"])
            _ = app.buttons["add-photo"].waitForExistence(timeout: 10)
            measure(app, page: "room-stowed", ids: roomBase + ["place-furniture-first"])
        }

        // 10. A batch waiting to be sorted (chapter 8).
        app.terminate()
        let batch = XCUIApplication()
        batch.launchArguments = TestLanguage.current + ["-MeowverseStore", "tour-frames-batch", "-MeowverseResetStore", "-MeowverseSyntheticPhoto",
                                                        "-MeowverseSyntheticBatch", "3", "2", "-MeowverseColorGridSimilarity"]
        batch.launch()
        XCTAssertTrue(batch.buttons["add-synthetic-batch"].waitForExistence(timeout: 30))
        batch.buttons["add-synthetic-batch"].tap()
        if batch.buttons["start-sorting"].waitForExistence(timeout: 60) {
            _ = element(batch, "pending-count").waitForExistence(timeout: 10)
            sleep(2)
            measure(batch, page: "room-pending", ids: roomBase + ["pending-count", "start-sorting", "place-furniture-first"])
        }

        // 11. The 陪我一会儿 page (chapter 12). Last: it is a UIKit-hosted page we do not close.
        batch.terminate()
        let pocket = XCUIApplication()
        pocket.launchArguments = TestLanguage.current + ["-MeowverseStore", "tour-frames-pocket", "-MeowverseResetStore"]
        pocket.launch()
        if tapIfThere(pocket.buttons["choose-interaction"], wait: 30), tapIfThere(pocket.buttons["choose-pocket-cat"], wait: 10) {
            _ = element(pocket, "pocket-select").waitForExistence(timeout: 10)
            measure(pocket, page: "pocket-cat", ids: ["pocket-start", "pocket-end", "pocket-select", "pocket-expression"],
                    extras: [("navigation-bar", pocket.navigationBars.firstMatch)])
        }

        try writeResult(app: pocket)
    }
}
