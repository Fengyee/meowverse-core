import XCTest

/// The room's music and sounds, read from the `-MeowverseAudioProbe` element (a UI test cannot
/// hear): which tune plays, the cross-fade at night, the cat sounds and the button sounds.
final class RoomAudioUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// A time zone where it is now deep in the night phase (22:00–04:59), so the test never runs
    /// across 21:00 or 06:00.
    private static var nightZone: String {
        let now = Date()
        return TimeZone.knownTimeZoneIdentifiers.first { id in
            guard let zone = TimeZone(identifier: id) else { return false }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            return [22, 23, 0, 1, 2, 3, 4].contains(cal.component(.hour, from: now))
        } ?? "UTC"
    }

    /// `defaults` go in as launch arguments, which win over anything the app writes: only for
    /// settings the test never changes. The rest is set through the app (`setSwitch`, `saveLighting`).
    private func launch(_ store: String, defaults: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "audio-" + store, "-MeowverseResetStore",
                                                      "-MeowverseAudioProbe", "-MeowverseSyntheticPhoto"] + defaults
        app.launchEnvironment["TZ"] = Self.nightZone
        app.launch()
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 20))
        return app
    }

    private func probe(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["room-audio-probe"]
    }

    private func tokens(_ app: XCUIApplication) -> Set<String> {
        Set(probe(app).label.split(separator: " ").map(String.init))
    }

    /// Waits until the probe shows every token in `expected` (and none of `absent`).
    private func expectProbe(_ app: XCUIApplication, _ expected: [String], absent: [String] = [],
                             timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(probe(app).waitForExistence(timeout: 10), "the audio probe is on screen", file: file, line: line)
        let deadline = Date().addingTimeInterval(timeout)
        var seen = tokens(app)
        while Date() < deadline {
            if Set(expected).isSubset(of: seen) && seen.isDisjoint(with: absent) { return }
            usleep(200_000)
            seen = tokens(app)
        }
        XCTFail("probe \(seen.sorted()) lacks \(expected) or still has \(absent)", file: file, line: line)
    }

    private func tap(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id]
        if !button.exists { _ = button.waitForExistence(timeout: 5) }
        for _ in 0..<6 where !(button.exists && button.isHittable) { app.swipeUp() }
        XCTAssertTrue(button.exists && button.isHittable, id)
        button.tap()
    }

    private func caption(_ app: XCUIApplication, contains word: String, timeout: TimeInterval = 40) {
        let match = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "bella-caption", word)).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: timeout), word)
    }

    /// Sets a switch of 音乐音效 and closes the panel.
    private func setSwitch(_ app: XCUIApplication, _ id: String, on: Bool, file: StaticString = #filePath, line: UInt = #line) {
        tap(app, "open-room-sound")
        let toggle = app.switches[id]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), file: file, line: line)
        if (toggle.value as? String == "1") != on {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0", id, file: file, line: line)
        app.buttons["close-room-sound"].tap()
    }

    private func saveLighting(_ app: XCUIApplication, _ title: String) {
        tap(app, "open-room-appearance")
        let picker = app.buttons["room-lighting-mode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        app.buttons[title].tap()
        XCTAssertEqual(picker.value as? String, title)
        app.buttons["save-room-appearance"].tap()
    }

    func testMusicFollowsTheLightSettingAndCrossfadesIntoTheNightTune() {
        let app = launch("music")
        saveLighting(app, "恒定柔光")
        setSwitch(app, "room-music", on: true)
        // Steady light: the day tune, even though it is night where the device is.
        expectProbe(app, ["music=room-music"])

        expectProbe(app, ["music=room-music", "crossfades=0"])
        saveLighting(app, "跟随当地时间")
        expectProbe(app, ["music=room-music-night", "crossfades=1"], timeout: 10)
        // Both tunes overlap for the short cross-fade; then the day tune is paused.
        expectProbe(app, ["music=room-music-night"], absent: ["fading=room-music"], timeout: 6)

        saveLighting(app, "恒定柔光")
        expectProbe(app, ["music=room-music", "crossfades=2"], absent: ["fading=room-music-night"], timeout: 10)

        // The switch in 音乐音效 still turns it off (and leaves the default for other tests).
        setSwitch(app, "room-music", on: false)
        expectProbe(app, ["music=off"])
    }

    /// The notes under the two switches describe the sounds that ship now, in both languages.
    func testSoundPanelNotesDescribeTheNewSounds() {
        for (language, notes) in [(TestLanguage.chinese, ["轻柔的钢琴曲", "呼噜"]), (TestLanguage.english, ["Soft piano", "purrs"])] {
            let app = XCUIApplication()
            app.launchArguments = language + ["-MeowverseStore", "audio-panel", "-MeowverseResetStore"]
            app.launch()
            tap(app, "open-room-sound")
            XCTAssertTrue(app.switches["room-music"].waitForExistence(timeout: 10))
            for note in notes {
                let text = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", note)).firstMatch
                XCTAssertTrue(text.waitForExistence(timeout: 5), note)
            }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "sound-panel-" + (language == TestLanguage.chinese ? "zh" : "en")
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    func testANightLaunchStartsOnTheNightTune() {
        let app = launch("night-launch", defaults: ["-room.lightingMode", "localTime", "-room.music", "YES"])
        expectProbe(app, ["music=room-music-night", "crossfades=0"])
        sleep(3)
        XCTAssertTrue(tokens(app).contains("crossfades=0"), "the night tune is the first tune, not faded into: \(tokens(app).sorted())")
    }

    func testCatAndButtonSoundsPlayOnTheirEventsAndStopWithTheSwitch() {
        let app = launch("effects")
        setSwitch(app, "room-music", on: false)
        setSwitch(app, "room-sound-effects", on: true)
        expectProbe(app, ["music=off"])

        // Placing a piece: the confirm sound.
        tap(app, "add-synthetic")
        tap(app, "manual-windowPerch")
        tap(app, "next-model")
        tap(app, "model-mv-window-perch-a")
        XCTAssertTrue(app.descendants(matching: .any)["model-preview-ready"].waitForExistence(timeout: 15))
        tap(app, "next-placement")
        tap(app, "confirm-placement")
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 15))
        expectProbe(app, ["chime=ui-confirm#1"])

        // Inviting her to loaf: a tap sound now, a purr once she has settled.
        tap(app, "choose-interaction")
        tap(app, "invite-nap-loaf")
        expectProbe(app, ["chime=ui-tap-02#1"])
        caption(app, contains: "窝着")
        expectProbe(app, ["effect=purr#1"])

        // A treat: the eating sound.
        tap(app, "choose-interaction")
        tap(app, "choose-treat")
        tap(app, "play-item-treatSalmon")
        tap(app, "place-play-item")
        caption(app, contains: "正在吃")
        expectProbe(app, ["effect=nibble#1", "chime=ui-tap-02#2"])
        if app.buttons["end-play"].exists { app.buttons["end-play"].tap() }

        // Sound effects off: no button sound, no purr. (She may have settled on her own before
        // the switch, so compare with what the probe showed right after it.)
        setSwitch(app, "room-sound-effects", on: false)
        let before = tokens(app)
        tap(app, "choose-interaction")
        tap(app, "invite-nap-sleep")
        caption(app, contains: "睡觉")
        sleep(2)
        XCTAssertEqual(tokens(app), before, "nothing new plays with the switch off")
        setSwitch(app, "room-sound-effects", on: true)
    }
}
