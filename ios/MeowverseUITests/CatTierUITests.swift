import XCTest

/// 猫的网格档 (owner, 2026-11-20): with 画质 on 低 and a cat's 低 meshes on the device the room's
/// cat wears them; while they are not downloaded, or the download fails, she wears 中 and nothing
/// waits for it. Every built-in cat declares a real 低. `-MeowverseCatTiers` says how its download
/// behaves: `live` downloads the real asset pack, the others write a stand-in (the cat's own 中
/// files under the 低 names). `-MeowverseCatProbe` reads back which pack and tier the room shows
/// ("builtIn:bella:bundle#low x z heading").
final class CatTierUITests: XCTestCase {
    private func launch(_ store: String, tiers: String, quality: String = "low") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "cat-tier-" + store, "-MeowverseResetStore",
                                                      "-MeowverseSyntheticPhoto", "-MeowverseCatProbe",
                                                      "-MeowverseCatTiers", tiers, "-MeowverseQuality", quality]
        app.launch()
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 20))
        return app
    }

    private struct CatProbe {
        let key: String
        let x: Double, z: Double, yaw: Double
    }

    /// Repeated reads instead of a predicate wait: one snapshot of the room page can take
    /// seconds while the cat moves (tech-craft).
    private func probe(_ app: XCUIApplication) -> CatProbe {
        let element = app.descendants(matching: .any)["bella-probe"].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "cat probe")
        let parts = (element.value as? String ?? "").split(separator: " ").map(String.init)
        guard parts.count == 4, let x = Double(parts[1]), let z = Double(parts[2]), let yaw = Double(parts[3]) else {
            return CatProbe(key: parts.first ?? "", x: .nan, z: .nan, yaw: .nan)
        }
        return CatProbe(key: parts[0], x: x, z: z, yaw: yaw)
    }

    @discardableResult
    private func waitForCat(_ app: XCUIApplication, tier: String, timeout: TimeInterval = 30,
                            file: StaticString = #filePath, line: UInt = #line) -> CatProbe {
        let deadline = Date().addingTimeInterval(timeout)
        var last = probe(app)
        while Date() < deadline {
            if last.key.contains(":bella:"), last.key.hasSuffix("#" + tier) { return last }
            Thread.sleep(forTimeInterval: 0.5)
            last = probe(app)
        }
        XCTFail("the room must show Bella on \(tier), got \(last.key)", file: file, line: line)
        return last
    }

    /// 分享房间 › the postcard is made › closed; then the cat (`pack#tier`) that went on the card.
    private func postcardCat(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> String {
        tap(app, "open-room-share", file: file, line: line)
        XCTAssertTrue(app.descendants(matching: .any)["room-postcard-ready"].waitForExistence(timeout: 30), "postcard", file: file, line: line)
        snap(app, "cat-tier-postcard")
        tap(app, "close-room-share", file: file, line: line)
        let probe = app.descendants(matching: .any)["postcard-cat-probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "postcard probe", file: file, line: line)
        return probe.value as? String ?? ""
    }

    private func tap(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 15), id, file: file, line: line)
        for _ in 0..<6 where !button.isHittable { app.swipeUp() }
        button.tap()
    }

    /// 设置, scrolled until the 画面 footer (and the cat note under it) is on screen: an
    /// off-screen footer is not in the accessibility tree.
    @discardableResult
    private func openSettingsAtQuality(_ app: XCUIApplication) -> XCUIElement {
        tap(app, "open-settings")
        let row = app.buttons["open-render-quality"], footer = app.staticTexts["render-quality-footer"]
        _ = row.waitForExistence(timeout: 5)
        for _ in 0..<12 where !(row.isHittable && footer.exists && footer.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.isHittable, "could not reach the 画质 row")
        return row
    }

    /// 设置 › 画面 › 画质 › `choice`, then back to the room.
    private func chooseQuality(_ app: XCUIApplication, _ choice: String) {
        tap(app, "open-settings")
        let row = app.buttons["open-render-quality"]
        _ = row.waitForExistence(timeout: 5)
        for _ in 0..<10 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.isHittable, "could not reach the 画质 row")
        row.tap()
        let option = app.buttons["render-quality-" + choice]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        XCTAssertTrue(option.isSelected)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app, "close-settings")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 低 ready → she wears 低. Raising 画质 to 中 while she plays at a toy gives her 中 meshes
    /// where she is: same contact, same heading, still playing (not back at the door).
    /// 互动 › 玩具 › 羽毛逗猫棒, placed; returns once she plays at it (she stays put there).
    @discardableResult
    private func playAtTheWand(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        tap(app, "choose-interaction", file: file, line: line)
        tap(app, "choose-toy", file: file, line: line)
        let picker = app.collectionViews.firstMatch
        let wand = app.buttons["play-item-featherWand"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), file: file, line: line)
        for _ in 0..<5 where !wand.exists || !wand.isHittable { picker.swipeUp() }
        tap(app, "play-item-featherWand", file: file, line: line)
        tap(app, "place-play-item", file: file, line: line)
        let playing = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "bella-caption", "正在玩羽毛逗猫棒")).firstMatch
        XCTAssertTrue(playing.waitForExistence(timeout: 40), "she reaches the toy", file: file, line: line)
        sleep(1)
        return playing
    }

    func testLowTierReadyIsWornAndAQualityChangeSwapsHerInPlace() {
        continueAfterFailure = false
        let app = launch("ready", tiers: "ready")
        waitForCat(app, tier: "low")
        snap(app, "cat-tier-low")

        let playing = playAtTheWand(app)
        let before = probe(app)
        XCTAssertTrue(before.key.hasSuffix("#low"), before.key)

        chooseQuality(app, "medium")
        let after = waitForCat(app, tier: "medium")
        continueAfterFailure = true
        XCTAssertEqual(after.x, before.x, accuracy: 0.01, "x stays at the toy")
        XCTAssertEqual(after.z, before.z, accuracy: 0.01, "z stays at the toy")
        XCTAssertEqual(after.yaw, before.yaw, accuracy: 0.01, "she still faces the toy")
        XCTAssertTrue(playing.exists, "still playing after the swap")
        snap(app, "cat-tier-medium-in-place")
        tap(app, "end-play")
    }

    /// The note under 画质 while 低 is not ready: one quiet line in 设置 and on the 画质 page, the
    /// right one for downloading and for a failure, and none once she wears 低.
    func testQualityNoteSaysTheCatIsOnTheStandardModelUntilLowIsReady() {
        continueAfterFailure = false
        let cases: [(drill: String, note: String?)] = [
            ("hang", "正在准备简化的猫咪模型，准备好之前先用标准模型。"),
            ("fail", "简化的猫咪模型暂时下载不了，先用标准模型。换一次画质或下次打开 App 时会再试。"),
            ("ready", nil),
        ]
        for (drill, expected) in cases {
            let app = launch("note-" + drill, tiers: drill)
            waitForCat(app, tier: expected == nil ? "low" : "medium", timeout: 20)
            if drill == "fail" { sleep(2) }  // the failure arrives half a second in
            let row = openSettingsAtQuality(app)
            let note = app.staticTexts["render-quality-cat-note"]
            if let expected {
                XCTAssertTrue(note.waitForExistence(timeout: 5), "\(drill): note in 设置")
                XCTAssertEqual(note.label, expected, drill)
            } else {
                XCTAssertTrue(app.staticTexts["render-quality-footer"].exists)
                XCTAssertFalse(note.exists, "ready: no note, she wears 低")
            }
            snap(app, "cat-tier-note-settings-" + drill)
            row.tap()
            XCTAssertTrue(app.buttons["render-quality-low"].waitForExistence(timeout: 5))
            if let expected {
                XCTAssertTrue(note.waitForExistence(timeout: 5), "\(drill): note on the 画质 page")
                XCTAssertEqual(note.label, expected, drill)
            } else {
                XCTAssertFalse(note.exists, "ready: no note on the 画质 page")
            }
            snap(app, "cat-tier-note-page-" + drill)
            // 中 asks for no tier: the note goes.
            app.buttons["render-quality-medium"].tap()
            XCTAssertFalse(note.waitForExistence(timeout: 2), "\(drill): no note on 中")
            app.terminate()
        }
    }

    /// `TEST_RUNNER_MV_BA_SERVE` from the harness in ios/README.md "画质" (`ios/ba-local.sh`):
    /// `serving` while `ba-serve` serves the real packs from `ba-local.sh stage`, `stopped` once it
    /// is stopped. Tests that need it are skipped without it.
    private func server() throws -> String {
        let server = ProcessInfo.processInfo.environment["MV_BA_SERVE"]
        guard let server, ["serving", "stopped"].contains(server) else {
            throw XCTSkip("needs ios/ba-local.sh and TEST_RUNNER_MV_BA_SERVE=serving|stopped")
        }
        return server
    }

    /// The real transport (`-MeowverseCatTiers live`: Background Assets, asset pack
    /// `cat-bella-low`) against a local `ba-serve` serving Bella's real 低.
    /// serving: 中 at once, then 低 when the download lands; the postcard made on 低 carries 中,
    /// the finest tier there is; at the wand, a picture on 低 and one after 画质 goes to 中 (she
    /// is swapped in place; the names carry her floor position, for cropping); 低 straight away
    /// on the next launch (the pack stays on the device). stopped: 中, with the failure note.
    func testLiveAssetPackDownloadFromALocalServer() throws {
        let server = try server()
        continueAfterFailure = false
        if server == "serving" {
            let app = launch("live-serving", tiers: "live")
            waitForCat(app, tier: "low", timeout: 90)
            XCTAssertTrue(postcardCat(app).hasSuffix(":bella:bundle#medium"), "the postcard on 低 carries 中")
            XCTAssertTrue(probe(app).key.hasSuffix("#low"), "the room stays on 低: \(probe(app).key)")
            playAtTheWand(app)
            for tier in ["low", "medium"] {
                if tier == "medium" { chooseQuality(app, "medium") }
                let cat = waitForCat(app, tier: tier)
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = String(format: "cat-shot-bella-%@ %.3f %.3f", tier, cat.x, cat.z)
                shot.lifetime = .keepAlways
                add(shot)
            }
            app.terminate()
            let again = launch("live-kept", tiers: "live-kept")
            waitForCat(again, tier: "low", timeout: 20)
            again.terminate()
        } else {
            let app = launch("live-" + server, tiers: "live")
            waitForCat(app, tier: "medium", timeout: 20)
            openSettingsAtQuality(app)
            let note = app.staticTexts["render-quality-cat-note"]
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline, !(note.exists && note.label.hasPrefix("简化的猫咪模型暂时下载不了")) { sleep(1) }
            XCTAssertTrue(note.exists, "the failure note")
            XCTAssertEqual(note.label, "简化的猫咪模型暂时下载不了，先用标准模型。换一次画质或下次打开 App 时会再试。")
            snap(app, "cat-tier-live-stopped")
            tap(app, "close-settings")
            XCTAssertTrue(probe(app).key.hasSuffix("#medium"), probe(app).key)
            app.terminate()
        }
    }

    /// 低 not on the device and its download never finishing, or failing: she wears 中 at once,
    /// and the app answers taps meanwhile.
    func testLowTierNotDownloadedOrFailedShowsMediumWithoutWaiting() {
        continueAfterFailure = false
        for drill in ["hang", "fail"] {
            let app = launch(drill, tiers: drill)
            let start = Date()
            waitForCat(app, tier: "medium", timeout: 20)
            XCTAssertLessThan(Date().timeIntervalSince(start), 20, "\(drill): 中 does not wait for 低")
            // The interface is not held up by the download: 设置 opens and closes.
            tap(app, "open-settings")
            XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 5), "\(drill): settings open")
            tap(app, "close-settings")
            XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 5))
            // Some seconds later (a failure has come in by now) she is still on 中.
            sleep(3)
            XCTAssertTrue(probe(app).key.hasSuffix("#medium"), "\(drill): \(probe(app).key)")
            snap(app, "cat-tier-medium-" + drill)
            app.terminate()
        }
    }
}
