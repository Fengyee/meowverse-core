import XCTest
import zlib

/// 猫咪管理 → 猫咪模型 (in 设置 until round 10): the built-in Bella is chosen by default; an
/// imported `.meowcat` can be chosen, inspected, replaced and deleted, and deleting it brings Bella back.
final class CatPackUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ store: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "catpack-" + store, "-MeowverseResetStore"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 20))
        return app
    }

    /// The cat model is at the bottom of 猫咪管理: scroll until `id` can be tapped.
    @discardableResult
    private func openCats(_ app: XCUIApplication, showing id: String = "import-cat-pack") -> XCUIElement {
        app.openCatManager()
        let target = app.buttons[id]
        XCTAssertTrue(target.waitForExistence(timeout: 10), id)
        for _ in 0..<6 where !target.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(target.isHittable, "could not reach \(id)")
        return target
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 20,
                              file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "expected “\(text)” in “\(element.exists ? element.label : "<missing>")”", file: file, line: line)
    }

    private func waitForSelected(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "selected == true")
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(element.identifier) is not selected", file: file, line: line)
    }

    func testCatModelSectionShowsBellaSelected() throws {
        let app = launch("basic")
        let bella = openCats(app, showing: "cat-pack-bella")
        XCTAssertTrue(bella.isSelected)
        XCTAssertEqual(bella.value as? String, "正在使用")
        XCTAssertTrue(bella.label.contains("贝咪"), bella.label)
        XCTAssertTrue(bella.label.contains("棕色虎斑加白"), bella.label)
        XCTAssertTrue(app.buttons["import-cat-pack"].exists)
        XCTAssertFalse(app.buttons["cat-pack-menu-bella"].exists, "a built-in model cannot be deleted")
        // The cats' names are on the same page.
        XCTAssertTrue(app.firstCatRow.label.hasPrefix("Kitty"), app.firstCatRow.label)
        sleep(1); snap("cat-pack-section")
        // Every issue is listed; the ones on the cat model card fail the test. No `.textClipped`:
        // in a folio sheet it flags every text, the page title included ("may be clipped at
        // larger sizes"); the largest size is checked by its own test below.
        var modelCardIssues: [String] = []
        try app.performAccessibilityAudit(for: [.contrast, .hitRegion, .sufficientElementDescription, .trait]) { issue in
            let id = issue.element?.identifier ?? "", label = issue.element?.label ?? ""
            print("audit issue: \(issue.auditType) \(id) “\(label)” \(issue.detailedDescription)")
            if id.hasPrefix("cat-pack") || ["import-cat-pack", "open-cat-inspect"].contains(id)
                || label.contains("猫咪模型") || label.contains("所有猫咪都用选中的模型") {
                modelCardIssues.append("\(issue.auditType) \(id) \(label)")
            }
            return true
        }
        XCTAssertEqual(modelCardIssues, [], "the cat model card passes the audit")
        app.buttons["close-home"].tap()

        // 设置 no longer has them; one row leads to them: 设置 closes and 猫咪管理 opens.
        app.buttons["open-settings"].tap()
        let row = app.buttons["open-cats-from-settings"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("猫咪的名字和模型"), row.label)
        XCTAssertFalse(app.textFields["cat-name-field"].exists)
        XCTAssertFalse(app.buttons["cat-pack-bella"].exists)
        XCTAssertFalse(app.buttons["import-cat-pack"].exists)
        sleep(1); snap("settings-without-cats")
        row.tap()
        XCTAssertTrue(app.firstCatRow.waitForExistence(timeout: 10), "猫咪管理 opens")
        XCTAssertFalse(row.exists, "设置 has closed")
        app.buttons["close-home"].tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        // Closing 设置 any other way opens nothing.
        app.buttons["open-settings"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        sleep(2)
        XCTAssertFalse(app.firstCatRow.exists, "完成 only closes 设置")
    }

    /// At the largest accessibility size every row of 猫咪管理 can still be reached and read.
    func testCatManagerAtLargestTextSizeReachesEveryRow() {
        let app = launch("xxxl", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.openCatManager()
        XCTAssertTrue(app.firstCatRow.waitForExistence(timeout: 10))
        sleep(1); snap("xxxl-cats-top")
        for id in ["cat-pack-bella", "open-cat-inspect", "import-cat-pack"] {
            let row = app.buttons[id]
            for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(row.isHittable, "\(id) can be reached")
        }
        sleep(1); snap("xxxl-cats-models")
        XCTAssertTrue(app.buttons["cat-pack-bella"].label.contains("贝咪"))
    }

    /// The bundled Bella ships her high-resolution model: the inspect row opens it.
    func testBuiltInBellaOpensHerInspectModel() {
        let app = launch("inspect")
        snap("1-room")
        let open = openCats(app, showing: "open-cat-inspect")
        snap("2-cats")
        open.tap()
        XCTAssertTrue(app.descendants(matching: .any)["cat-inspect-model"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.descendants(matching: .any)["cat-inspect-failed"].exists)
        sleep(2)
        snap("3-inspect")
        app.buttons["close-cat-inspect"].tap()
        XCTAssertTrue(app.buttons["open-cat-inspect"].waitForExistence(timeout: 10), "back on 猫咪管理")
    }

    /// The fixture is built from the bundled Bella files plus a tiny test-only USDZ and read by
    /// the app from a Mac path, which only the simulator allows.
    func testImportedCatPackCanBeChosenInspectedReplacedAndDeleted() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("the fixture path is only readable by the app on the simulator")
        #else
        let fixture = try Self.makeFixturePack()
        let app = launch("import", extra: ["-MeowverseCatPackFile", fixture.path])
        let drill = openCats(app, showing: "drill-import-cat-pack")
        drill.tap()
        waitForLabel(app.descendants(matching: .any)["cat-pack-notice"].firstMatch, containing: "已导入")
        let imported = app.buttons["cat-pack-test-cat"]
        XCTAssertTrue(imported.waitForExistence(timeout: 5))
        waitForSelected(imported)
        XCTAssertFalse(app.buttons["cat-pack-bella"].isSelected)
        snap("cat-pack-imported")

        // The high-resolution model loads only on its own screen.
        let inspect = app.buttons["open-cat-inspect"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 5))
        inspect.tap()
        let model = app.descendants(matching: .any)["cat-inspect-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 20), "the inspect model did not load")
        XCTAssertFalse(app.descendants(matching: .any)["cat-inspect-failed"].exists)
        sleep(2); snap("cat-inspect-initial")
        model.pinch(withScale: 1.6, velocity: 1)
        model.swipeLeft()
        snap("cat-inspect")
        app.buttons["close-cat-inspect"].tap()

        // The same id again asks before replacing.
        XCTAssertTrue(drill.waitForExistence(timeout: 5))
        drill.tap()
        let replace = app.buttons["confirm-replace-cat-pack"].firstMatch
        XCTAssertTrue(replace.waitForExistence(timeout: 20))
        replace.tap()
        waitForLabel(app.descendants(matching: .any)["cat-pack-notice"].firstMatch, containing: "已导入")
        waitForSelected(imported)

        // Choosing Bella back, then the imported pack again, sticks.
        app.chooseBuiltInCat("bella")
        imported.tap()
        waitForSelected(imported)

        // A postcard checks the pack actually committed to the visible room actor.
        app.buttons["close-home"].tap()
        app.buttons["open-room-share"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["room-postcard-ready"].waitForExistence(timeout: 25))
        app.buttons["close-room-share"].tap()
        openCats(app, showing: "cat-pack-menu-test-cat").tap()

        // Deleting the active pack falls back to Bella.
        let delete = app.buttons["delete-cat-pack-test-cat"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["confirm-delete-cat-pack"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        waitForLabel(app.descendants(matching: .any)["cat-pack-notice"].firstMatch, containing: "已删除")
        XCTAssertFalse(app.buttons["cat-pack-test-cat"].exists)
        waitForSelected(app.buttons["cat-pack-bella"])
        snap("cat-pack-deleted")
        #endif
    }

    // MARK: Fixture

    /// A stored ZIP: `cat.json` (Bella's manifest with id `test-cat` and an inspect model) and the files it names.
    /// Also used by PlayLifecycleUITests to switch to a second valid pack mid-play.
    static func makeFixturePack() throws -> URL {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let art = tests.deletingLastPathComponent().appendingPathComponent("Meowverse/Resources/Art")
        let manifestData = try Data(contentsOf: art.appendingPathComponent("bella-cat.json"))
        var manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        manifest["id"] = "test-cat"
        manifest["name"] = "测试猫"
        manifest["inspect"] = "inspect.usdz"
        manifest["preview"] = nil
        // Tiers are optional in a pack (docs/CAT_PACK.md, 画质档) and a pack naming files it lacks
        // is refused whole; the bundled Bella's low-tier files download on demand and aren't
        // copied here, so the fixture is a medium-only pack.
        manifest["tiers"] = nil

        var names: [String] = []
        let poses = try XCTUnwrap(manifest["poses"] as? [String: String])
        names += poses.values.sorted()
        names.append(try XCTUnwrap(manifest["groundGaits"] as? String))
        let materials = try XCTUnwrap(manifest["materials"] as? [String: [String: Any]])
        for material in materials.values {
            if let base = material["baseColor"] as? String { names.append(base) }
            if let sleep = material["sleepBaseColor"] as? String { names.append(sleep) }
        }
        var files: [(String, Data)] = [("cat.json", try JSONSerialization.data(withJSONObject: manifest))]
        for name in Set(names).sorted() {
            files.append((name, try Data(contentsOf: art.appendingPathComponent("bella-" + name))))
        }
        let usdz = try XCTUnwrap(Bundle(for: CatPackUITests.self).url(forResource: "inspect-fixture", withExtension: "usdz"))
        files.append(("inspect.usdz", try Data(contentsOf: usdz)))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-cat.meowcat")
        try Self.storedZip(files).write(to: url)
        return url
    }

    private static func storedZip(_ files: [(String, Data)]) -> Data {
        var out = Data(), directory = Data()
        func le16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff)) }
        func le32(_ v: Int, _ d: inout Data) { le16(v & 0xffff, &d); le16((v >> 16) & 0xffff, &d) }
        for (name, data) in files {
            let offset = out.count
            let crc = data.withUnsafeBytes { Int(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
            let nameBytes = Array(name.utf8)
            func common(_ d: inout Data) {
                le16(20, &d); le16(0, &d); le16(0, &d); le16(0, &d); le16(0x21, &d)
                le32(crc, &d); le32(data.count, &d); le32(data.count, &d); le16(nameBytes.count, &d); le16(0, &d)
            }
            le32(0x0403_4b50, &out); common(&out); out.append(contentsOf: nameBytes); out.append(data)
            le32(0x0201_4b50, &directory); le16(20, &directory); common(&directory)
            le16(0, &directory); le16(0, &directory); le16(0, &directory); le32(0, &directory); le32(offset, &directory)
            directory.append(contentsOf: nameBytes)
        }
        let directoryOffset = out.count
        out.append(directory)
        le32(0x0605_4b50, &out); le16(0, &out); le16(0, &out); le16(files.count, &out); le16(files.count, &out)
        le32(directory.count, &out); le32(directoryOffset, &out); le16(0, &out)
        return out
    }
}
