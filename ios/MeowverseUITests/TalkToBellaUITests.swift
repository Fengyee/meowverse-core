import XCTest

/// Talk to Bella (docs/TALK_TO_BELLA.md). `-TalkToBellaTranscript` stands in for the microphone
/// (DEBUG builds only): a tap on the head sends that sentence down the rest of the pipeline.
/// `-TalkToBellaRulesOnly` keeps the on-device model out, so a simulator with Apple Intelligence
/// answers like one without; the model is checked on a real device.
///
/// `talk-to-bella-probe` (present only with the transcript switch) reads "<source> <plan>", for
/// example "rules invite <piece> <site> loaf", or "<source> refused <reason>".
///
/// Talk to Bella is not in 1.0: these run only against a `MEOWVERSE_TALK_TO_BELLA=YES` build, with
/// `TEST_RUNNER_MV_TALK_TO_BELLA=1`. The default build is `VoiceOffUITests`.
final class TalkToBellaUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MV_TALK_TO_BELLA"] == "1",
                          "Talk to Bella is only in a MEOWVERSE_TALK_TO_BELLA=YES build")
    }

    private func launch(_ store: String, saying sentence: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "talk-to-bella-" + store, "-MeowverseResetStore",
                                                      "-TalkToBellaTranscript", sentence, "-TalkToBellaRulesOnly"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 20))
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func tapHead(_ app: XCUIApplication) {
        let head = app.buttons["talk-to-bella"]
        XCTAssertTrue(head.waitForExistence(timeout: 10), "the Talk to Bella head")
        XCTAssertTrue(head.isHittable, "the head is covered")
        head.tap()
    }

    /// Waits for the pipeline's probe to match, and returns its value. Polls the value itself:
    /// with the head animating, one predicate snapshot can take most of a 10 s wait.
    @discardableResult
    private func expectProbe(_ app: XCUIApplication, _ format: String, _ arguments: CVarArg..., timeout: TimeInterval = 20) -> String {
        let probe = element(app, "talk-to-bella-probe")
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "talk-to-bella-probe")
        let predicate = NSPredicate(format: format, argumentArray: arguments)
        let deadline = Date().addingTimeInterval(timeout)
        var value = probe.value as? String ?? "<none>"
        while !predicate.evaluate(with: ["value": value]), Date() < deadline {
            usleep(300_000)
            value = probe.value as? String ?? "<none>"
        }
        XCTAssertTrue(predicate.evaluate(with: ["value": value]), "probe is “\(value)”, expected \(format) \(arguments)")
        return value
    }

    private func addSofa(_ app: XCUIApplication) {
        app.buttons["add-synthetic"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 20))
        sofa.tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 15))
    }

    /// 「去沙发上躺着」 → a fixed phrase → an invitation to the sofa, as 互动 would send it.
    func testLieOnTheSofaWalksToTheSofa() {
        let app = launch("sofa", saying: "去沙发上躺着", extra: ["-MeowverseSyntheticPhoto"])
        addSofa(app)
        tapHead(app)
        // The sofa offers loaf; without it the resolver falls back to sleep, then sit.
        expectProbe(app, "value BEGINSWITH %@ AND (value ENDSWITH %@ OR value ENDSWITH %@ OR value ENDSWITH %@)",
                    "rules invite ", " loaf", " sleep", " sit")
        let refusal = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (label CONTAINS %@ OR label CONTAINS %@)", "talk-to-bella-hint", "没听懂", "还没有"))
        XCTAssertEqual(refusal.count, 0, "no refusal line")
        let onSofa = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "bella-caption", "沙发")).firstMatch
        XCTAssertTrue(onSofa.waitForExistence(timeout: 30), "the caption names the sofa")
        snap("talk-to-bella-sofa")
    }

    /// 「去沙发上喝水」 with a sofa in the room: the sofa is there but offers no drink, so the line
    /// says so instead of claiming there is no sofa (QA round 12 P2-1).
    func testDrinkOnTheSofaSaysTheSofaCannot() {
        let app = launch("sofa-drink", saying: "去沙发上喝水", extra: ["-MeowverseSyntheticPhoto"])
        addSofa(app)
        tapHead(app)
        // The line first: it stays only a few seconds.
        let hint = element(app, "talk-to-bella-hint")
        XCTAssertTrue(hint.waitForExistence(timeout: 10), "a refusal line")
        let label = hint.label
        snap("talk-to-bella-sofa-drink")
        XCTAssertFalse(label.contains("还没有沙发"), "the room has a sofa, the line says “\(label)”")
        XCTAssertTrue(label.contains("沙发上不能这样做"), "line is “\(label)”")
        expectProbe(app, "value CONTAINS %@", "refused noSuchFurniture")
    }

    /// 「过来」 → walk to the front of the room, where the person is.
    func testComeHereWalksToTheFront() {
        let app = launch("come", saying: "过来", extra: ["-MeowverseCatProbe"])
        tapHead(app)
        let value = expectProbe(app, "value BEGINSWITH %@", "rules come ")
        let parts = value.split(separator: " ").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 2, "come cell in “\(value)”")
        guard parts.count == 2 else { return }
        // Cell (x, z) has its centre at (x − 7, z − 7) in the 15 × 15 room (ArtLibrary.worldPoint).
        let target = (x: Double(parts[0] - 7), z: Double(parts[1] - 7))
        let cat = element(app, "bella-probe")
        XCTAssertTrue(cat.waitForExistence(timeout: 10), "cat probe")
        let deadline = Date().addingTimeInterval(30)
        var arrived = false
        var last = ""
        while Date() < deadline, !arrived {
            last = cat.value as? String ?? ""
            let fields = last.split(separator: " ").compactMap { Double($0) }
            if fields.count >= 2, abs(fields[0] - target.x) < 0.6, abs(fields[1] - target.z) < 0.6 { arrived = true }
            if !arrived { usleep(500_000) }
        }
        XCTAssertTrue(arrived, "the cat should reach \(target), last probe “\(last)”")
        snap("talk-to-bella-come")
    }

    /// 「给我唱首歌」 → nothing the cat can do: she stays put and the head says so in one line.
    func testSingASongIsNotUnderstood() {
        let app = launch("song", saying: "给我唱首歌")
        tapHead(app)
        // The line first: it stays only a few seconds.
        let hint = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "talk-to-bella-hint", "没听懂")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "the not-understood line")
        XCTAssertTrue(app.buttons["choose-interaction"].isHittable, "the hint must not cover 互动")
        snap("talk-to-bella-not-understood")
        expectProbe(app, "value ENDSWITH %@", "refused notUnderstood")
        // The line goes after a few seconds; the head is back to waiting. Polled: with the head
        // animating, one existence snapshot of the room can take about 9 s.
        let deadline = Date().addingTimeInterval(20)
        while hint.exists, Date() < deadline { usleep(500_000) }
        XCTAssertFalse(hint.exists, "the hint should go")
        XCTAssertEqual(app.buttons["talk-to-bella"].value as? String, "等你说话")
    }
}
