import XCTest

/// 关于与隐私: who makes it (出品) first, then sponsors when there are any, then thanks, open source and art, privacy and the
/// version; every second-level page opens. Thanks only: nothing here asks for money (App Review
/// 3.1.1), and the one link out is the privacy policy on 隐私 (App Review 5.1.1(i)).
///
/// `TEST_RUNNER_MV_LANG=en` runs the walk in English and also checks that no Chinese shows.
/// `TEST_RUNNER_MV_SHOT_DIR=<folder>` writes each page as `<MV_SHOT_PREFIX>-<name>.png`;
/// `TEST_RUNNER_MV_TEXT_SIZE=<category>` sets the text size of `testEveryAboutPageOpens`.
final class AboutPageUITests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var english: Bool { environment["MV_LANG"] == "en" }
    private let notices = ["about-model-license", "about-notice-hunyuan3D", "about-notice-zcoolKuaiLe", "about-notice-kenneyFurniture",
                           "about-notice-threeDAssets", "about-notice-fripouille"]

    override func setUp() {
        continueAfterFailure = false
    }

    func testEveryAboutPageOpens() {
        let app = XCUIApplication()
        app.launchArguments = (english ? TestLanguage.english : TestLanguage.chinese)
            + ["-MeowverseStore", "aboutpages", "-MeowverseResetStore"]
        if let size = environment["MV_TEXT_SIZE"] { app.launchArguments += ["-UIPreferredContentSizeCategoryName", size] }
        app.launch()
        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 25))
        settings.tap()
        reveal(app, "open-about").tap()

        // Who makes it, then the sponsors (each is SponsorCreditsUITests'). No testers: no such
        // group and no stand-in.
        let intro = element(app, "about-sponsors-intro")
        XCTAssertTrue(intro.waitForExistence(timeout: 10))
        let studio = element(app, "about-studio")
        XCTAssertTrue(studio.exists && studio.isHittable, "seen on opening")
        // On a LabeledContent in a List the identifier lands on the value only; the title is its own text.
        XCTAssertEqual(studio.label, english ? "Fengxue Studio" : "枫雪工作室")
        let title = app.staticTexts[english ? "Made by" : "出品"]
        XCTAssertTrue(title.exists)
        XCTAssertLessThan(title.frame.maxY, intro.frame.minY, "the title is in the first section")
        XCTAssertLessThan(studio.frame.maxY, intro.frame.minY, "first on the page")
        snap("about-0-sponsors")
        let idea = reveal(app, "about-thanks-idea")
        XCTAssertTrue(idea.label.contains("Omucat"), idea.label)
        for id in ["about-sponsor-placeholder", "about-thanks-testing"] {
            XCTAssertFalse(element(app, id).exists, id)
        }
        noStandIn(app)
        // No way out of the app to pay: these pages have no links.
        XCTAssertEqual(app.links.count, 0)
        noChinese(app, "main")
        snap("about-1-top")
        app.swipeUp(velocity: .slow)
        snap("about-2-bottom")

        for (index, id) in notices.enumerated() {
            // After scrolling, a row can sit under the navigation bar and still count as hittable:
            // a tap there lands on the bar. Scroll it out first (the list is not at its top then).
            let row = reveal(app, id)
            let bar = app.navigationBars.firstMatch
            for _ in 0..<3 where row.frame.minY < bar.frame.maxY { app.swipeDown(velocity: .slow) }
            row.tap()
            XCTAssertTrue(element(app, "about-notice-page").waitForExistence(timeout: 15), id)
            if id == "about-model-license" || id == "about-notice-zcoolKuaiLe" {
                // The licence text that ships with the work.
                XCTAssertTrue(element(app, "about-license-text").exists, id)
            }
            // Launch design §3: one short line for the cats' generator, no account of each cat,
            // and the Fripouille credit is about Fripouille only.
            let texts = app.staticTexts
            if id == "about-notice-hunyuan3D" {
                let perCat = texts.matching(NSPredicate(format: "label CONTAINS '2mv' OR label CONTAINS 'Bella'")).firstMatch
                XCTAssertFalse(perCat.exists, "a note on each cat: \(perCat.exists ? perCat.label : "")")
            }
            if id == "about-notice-fripouille" {
                let hunyuan = texts.matching(NSPredicate(format: "label CONTAINS[c] 'hunyuan' OR label CONTAINS '混元'")).firstMatch
                XCTAssertFalse(hunyuan.exists, "Fripouille's credit points at Hunyuan: \(hunyuan.exists ? hunyuan.label : "")")
            }
            noChinese(app, id)
            snap("about-notice-\(index + 1)")
            back(app)
        }

        reveal(app, "about-art-credits").tap()
        let credits = element(app, "about-art-credits-text")
        XCTAssertTrue(credits.waitForExistence(timeout: 5))
        XCTAssertTrue(credits.label.contains("Kenney"), credits.label)
        XCTAssertTrue(credits.label.contains("ZCOOL KuaiLe"), credits.label)
        snap("about-art-credits")
        back(app)

        reveal(app, "about-privacy").tap()
        XCTAssertTrue(element(app, "about-photos").waitForExistence(timeout: 5))
        noChinese(app, "privacy")
        snap("about-privacy")
        // The last row; in English it starts below the fold, and List rows off screen are not in the tree.
        let network = reveal(app, "about-network")
        XCTAssertTrue(network.label.contains(english ? "no server of its own" : "没有自己的服务器"), network.label)
        XCTAssertFalse(element(app, "about-sync").exists, "sync is off: no sync line")
        noChinese(app, "privacy-lower")
        let policy = reveal(app, "about-privacy-policy")
        XCTAssertTrue(app.links["about-privacy-policy"].exists, "it reads as a link")
        XCTAssertGreaterThanOrEqual(policy.frame.height, 44)
        XCTAssertTrue(policy.label.contains(english ? "Privacy Policy" : "隐私政策"), policy.label)
        noChinese(app, "privacy-link")
        snap("about-privacy-lower")
        back(app)
    }

    /// 公告 thanks the same people by the same rule.
    func testNewsShowsNoEmptyGroup() {
        let app = XCUIApplication()
        app.launchArguments = (english ? TestLanguage.english : TestLanguage.chinese)
            + ["-MeowverseStore", "aboutnews", "-MeowverseResetStore"]
        app.launch()
        let news = app.buttons["open-room-news"]
        XCTAssertTrue(news.waitForExistence(timeout: 25))
        news.tap()
        let idea = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Omucat'")).firstMatch
        XCTAssertTrue(idea.waitForExistence(timeout: 15))
        for title in english ? ["Testing"] : ["测试"] {
            let group = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ","))
            XCTAssertEqual(group.count, 0, "\(title) has no names and is not shown")
        }
        noStandIn(app)
        for _ in 0..<3 { app.swipeUp() }
        snap("news-thanks")
    }

    /// 隐私政策 asks the system to open the published page at the section in the interface language.
    /// `-MeowverseLinkDrill` keeps the request in the app: a test run loads no page.
    func testThePrivacyPolicyLinkNamesTheSectionInTheInterfaceLanguage() {
        let app = XCUIApplication()
        app.launchArguments = (english ? TestLanguage.english : TestLanguage.chinese)
            + ["-MeowverseStore", "aboutpolicy", "-MeowverseResetStore", "-MeowverseLinkDrill"]
        app.launch()
        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 25))
        settings.tap()
        reveal(app, "open-about").tap()
        reveal(app, "about-privacy").tap()
        let policy = reveal(app, "about-privacy-policy")
        policy.tap()
        let asked = "https://fengyee.github.io/meowverse/privacy.html#" + (english ? "en" : "zh")
        let opened = expectation(for: NSPredicate(format: "value == %@", asked), evaluatedWith: policy)
        wait(for: [opened], timeout: 5)
    }

    /// The DEBUG gallery's made-up names: what the section looks like once there are sponsors.
    func testGalleryShowsTheSponsorList() {
        let app = XCUIApplication()
        app.launchArguments = (english ? TestLanguage.english : TestLanguage.chinese) + ["-MeowverseOverlayGallery", "credits"]
        app.launch()
        XCTAssertTrue(element(app, "about-sponsors-intro").waitForExistence(timeout: 25))
        snap("gallery-credits")
        // The identifier is on each name's text (on a Label it would also mark the icon).
        var names = Set<String>()
        for _ in 0..<5 where names.count < 5 {
            names.formUnion(app.staticTexts.matching(identifier: "about-sponsor").allElementsBoundByIndex.map(\.label))
            if names.count < 5 { app.swipeUp(velocity: .slow) }
        }
        XCTAssertEqual(names.count, 5, names.description)
        XCTAssertTrue(reveal(app, "about-thanks-testing").label.contains("Pudding"))
    }

    // MARK: Steps

    private func noStandIn(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for words in english ? ["will appear here", "Coming soon"] : ["会写在这里", "待补充"] {
            let said = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words))
            XCTAssertEqual(said.count, 0, words, file: file, line: line)
        }
    }

    private func noChinese(_ app: XCUIApplication, _ page: String, file: StaticString = #filePath, line: UInt = #line) {
        guard english else { return }
        let han = try! NSRegularExpression(pattern: "[\\u3400-\\u9fff]")
        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label)
        let found = labels.filter { han.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        XCTAssertTrue(found.isEmpty, "\(page) shows Chinese: \(found)", file: file, line: line)
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        usleep(600_000)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @discardableResult
    private func reveal(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(app, id)
        _ = target.waitForExistence(timeout: 3)
        for _ in 0..<12 where !(target.exists && target.isHittable) { app.swipeUp(velocity: .slow) }
        for _ in 0..<14 where !(target.exists && target.isHittable) { app.swipeDown(velocity: .slow) }
        usleep(600_000)
        XCTAssertTrue(target.exists && target.isHittable, "could not reach \(id)", file: file, line: line)
        return target
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
