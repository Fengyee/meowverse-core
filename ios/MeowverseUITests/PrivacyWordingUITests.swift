import XCTest

/// The privacy promises about the photos hold in every state (round 12 audit PRIVACY-4,
/// PRODUCT-8): the guide, the photo-library explanation and 关于与隐私 say "never uploaded" only
/// while neither Back Up to iCloud Drive nor iCloud sync is on, and name whichever is on. The
/// Settings backup footer speaks only of the exported file. Test folders stand in for iCloud
/// Drive and CloudKit, as in `ICloudBackupUITests` and `ICloudSyncUITests`.
///
/// `TEST_RUNNER_MV_LANG=en` runs the same checks in English. `TEST_RUNNER_MV_SHOT_DIR=<folder>`
/// also writes the guide, the explanation and Settings as `<MV_SHOT_PREFIX>-<name>.png`.
final class PrivacyWordingUITests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var english: Bool { environment["MV_LANG"] == "en" }

    override func setUp() {
        continueAfterFailure = false
        // The explanation is shown only while photo access is unanswered.
        XCUIApplication().resetAuthorizationStatus(for: .photos)
        addTeardownBlock { XCUIApplication().resetAuthorizationStatus(for: .photos) }
    }

    private struct Words {
        var guide: [String]
        var intro: [String]
        var about: [String]
    }

    /// The sentences that only an off-off device may show.
    private var noUpload: Words {
        english
            ? Words(guide: ["never uploaded"], intro: ["never uploads any photo"], about: ["does not send them to any server"])
            : Words(guide: ["不会上传"], intro: ["也不会把任何照片上传"], about: ["不会把它们传到任何服务器"])
    }

    /// What an on state must not say: "never uploaded", and that the originals never leave, since
    /// the copies it uploads are the original files for smaller photos and ones taken in the app
    /// (2026-11-24 audit B24-07).
    private var onForbid: Words {
        var words = noUpload
        words.intro.append(english ? "never uploads the originals" : "不会上传相册里的原图")
        return words
    }

    func testBothOffPromisesNoUpload() {
        check(state: "off", backup: false, sync: false, expect: noUpload, forbid: nil)
    }

    func testBackupOnNamesICloudDrive() {
        let expect = english
            ? Words(guide: ["this device", "backups go only to your own iCloud Drive"],
                    intro: ["Back Up to iCloud Drive", "with each backup", "the original files"],
                    about: ["Back Up to iCloud Drive", "photo copies in each backup"])
            : Words(guide: ["这台设备", "备份只存进你自己的 iCloud 云盘"],
                    intro: ["“备份到 iCloud 云盘”", "随备份存进你自己的 iCloud 云盘", "就是原文件"],
                    about: ["“备份到 iCloud 云盘”", "备份里的照片副本存在你自己的 iCloud 云盘"])
        check(state: "backup", backup: true, sync: false, expect: expect, forbid: onForbid)
    }

    func testSyncOnNamesICloudSync() {
        let expect = english
            ? Words(guide: ["sync only to your own devices"], intro: ["You turned on iCloud Sync, so", "the original files"], about: ["You turned on iCloud Sync, so"])
            : Words(guide: ["只通过你的 iCloud 同步到你自己的设备。"], intro: ["你打开了 iCloud 同步，", "就是原文件"], about: ["你打开了 iCloud 同步，"])
        check(state: "sync", backup: false, sync: true, expect: expect, forbid: onForbid)
    }

    func testBackupAndSyncNameBoth() {
        let expect = english
            ? Words(guide: ["sync only to your own devices", "backups go only to your own iCloud Drive"],
                    intro: ["iCloud Sync and Back Up to iCloud Drive", "the original files"], about: ["iCloud Sync and Back Up to iCloud Drive"])
            : Words(guide: ["同步到你自己的设备，备份也只存进你自己的 iCloud 云盘"],
                    intro: ["iCloud 同步和“备份到 iCloud 云盘”", "就是原文件"], about: ["iCloud 同步和“备份到 iCloud 云盘”"])
        check(state: "both", backup: true, sync: true, expect: expect, forbid: onForbid)
    }

    // MARK: Steps

    private func check(state: String, backup: Bool, sync: Bool, expect: Words, forbid: Words?,
                       file: StaticString = #filePath, line: UInt = #line) {
        let run = String(UUID().uuidString.prefix(8))
        let app = XCUIApplication()
        app.launchArguments = (english ? TestLanguage.english : TestLanguage.chinese)
            + ["-MeowverseStore", "privacy" + state, "-MeowverseResetStore", "-MeowverseLibraryIntro",
               "-photoLibraryLinkWanted", "<false/>", "-MeowverseCloudFolder", "pw" + run]
            + (sync ? ["-MeowverseSyncFolder", "pw" + run] : [])
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25), file: file, line: line)

        if sync { turnOn(app, page: "open-icloud-sync", toggle: "icloud-sync-toggle", sheet: "icloud-sync-consent-contents", confirm: "icloud-sync-consent-confirm") }
        if backup { turnOn(app, page: "open-icloud-backup", toggle: "icloud-backup-toggle", sheet: "icloud-consent-contents", confirm: "icloud-consent-confirm") }

        // Settings: the footer of 备份与恢复 speaks only of the exported file, in every state.
        openSettings(app)
        let footer = reveal(app, "backup-footer")
        assertLabel(footer, has: [english ? "An exported backup file" : "导出的备份文件"], lacks: [])
        snap("\(state)-settings")
        reveal(app, "open-about").tap()
        reveal(app, "about-privacy").tap()
        assertLabel(element(app, "about-photos"), has: expect.about, lacks: forbid?.about ?? [])
        app.navigationBars.buttons.element(boundBy: 0).tap() // 隐私 → 关于与隐私
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["close-settings"].tap()

        // The old guide is no longer opened: 「看看怎么玩」 starts the tour, whose chapter 2 has its
        // own privacy line (tour.bringPhoto.1). `expect.guide` is kept for when that line follows
        // these states too.

        // The explanation before the first photos.
        app.buttons["add-photo"].tap()
        let privacy = element(app, "library-intro-privacy")
        XCTAssertTrue(privacy.waitForExistence(timeout: 15), file: file, line: line)
        assertLabel(privacy, has: expect.intro, lacks: forbid?.intro ?? [])
        sleep(1)
        snap("\(state)-intro")
    }

    private func turnOn(_ app: XCUIApplication, page: String, toggle: String, sheet: String, confirm: String) {
        openSettings(app)
        reveal(app, page).tap()
        let toggleSwitch = app.switches[toggle]
        XCTAssertTrue(toggleSwitch.waitForExistence(timeout: 5))
        toggleSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        // The consent sheet is a list: on a small screen its button starts below the fold.
        XCTAssertTrue(element(app, sheet).waitForExistence(timeout: 5))
        reveal(app, confirm).tap()
        let on = NSPredicate(format: "value == '1'")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: on, object: toggleSwitch)], timeout: 10), .completed,
                       "\(toggle) did not turn on")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["close-settings"].tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
    }

    private func openSettings(_ app: XCUIApplication) {
        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 10))
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @discardableResult
    private func reveal(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(app, id)
        _ = target.waitForExistence(timeout: 3)
        for _ in 0..<6 where !(target.exists && target.isHittable) { app.swipeUp(velocity: .slow) }
        for _ in 0..<8 where !(target.exists && target.isHittable) { app.swipeDown(velocity: .slow) }
        usleep(600_000)
        XCTAssertTrue(target.exists && target.isHittable, "could not reach \(id)", file: file, line: line)
        return target
    }

    private func assertLabel(_ element: XCUIElement, has: [String], lacks: [String],
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), file: file, line: line)
        let label = element.label
        for text in has { XCTAssertTrue(label.contains(text), "expected “\(text)” in “\(label)”", file: file, line: line) }
        for text in lacks { XCTAssertFalse(label.contains(text), "“\(text)” must not be in “\(label)”", file: file, line: line) }
    }

    private func snap(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        if let folder = environment["MV_SHOT_DIR"] {
            let prefix = environment["MV_SHOT_PREFIX"].map { $0 + "-" } ?? ""
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder + "/" + prefix + name + ".png"))
        }
    }
}
