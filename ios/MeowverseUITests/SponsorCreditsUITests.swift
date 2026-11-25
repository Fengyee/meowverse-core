import XCTest

/// The sponsors by name (owner, 2026-11-22): in 关于, where the feature they supported opens and
/// on their cat's card; and the labour-of-love note that opens 设置.
///
/// What ships is one sponsor per built-in cat: four by the nickname they gave (2026-11-24), the
/// others as their cat's human. `-MeowverseSampleSponsors none|one|several` shows made-up sponsors
/// instead (DEBUG only). `TEST_RUNNER_MV_LANG=en` runs it all in English.
final class SponsorCreditsUITests: XCTestCase {
    private let english = ProcessInfo.processInfo.environment["MV_LANG"] == "en"

    private var catNames: [String] {
        english ? ["Bella", "Airou", "Zhumi", "Mocha", "Mochi", "Luna", "Snowy", "Pinky", "Zhaocai"]
                : ["贝咪", "艾露", "猪咪", "摩卡", "团团", "露娜", "雪球", "粉粉", "招财"]
    }

    /// As listed: Bella, Airou, Zhumi, Mochi and Zhaocai by the names their sponsors gave.
    private var nicknames: [String] {
        let given: [Int: String] = english ? [0: "Omucat", 1: "Yoko", 2: "Chuibao", 4: "Xin", 8: "Cornelius"]
                                           : [0: "Omucat", 1: "阳子", 2: "锤宝", 4: "Xin", 8: "科内利乌斯"]
        return catNames.enumerated().map { given[$0.offset] ?? (english ? "\($0.element)’s human" : "\($0.element)的铲屎官") }
    }
    private var oneName: String { english ? "Tangerine House" : "小橘子的家" }
    private let longName = "Captain Whiskers and the Very Long-Named Household of Seven Tabbies"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ store: String, _ extra: [String] = [], largest: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (english ? TestLanguage.english : TestLanguage.chinese)
            + ["-MeowverseStore", "credits-" + store, "-MeowverseResetStore"] + extra
        if largest { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["open-cat-manager"].waitForExistence(timeout: 60))
        return app
    }

    // MARK: What ships

    func testEachCatsHumanIsListedInAboutAndInNews() {
        let app = launch("shipped")
        openAbout(app)
        snap("about-sponsors")
        var listed = [String: Bool]()
        for _ in 0..<8 {
            for text in app.staticTexts.allElementsBoundByIndex.map(\.label) { listed[text] = true }
            if nicknames.allSatisfy({ listed[$0] == true }) { break }
            app.swipeUp(velocity: .slow)
            snap("about-sponsors-lower")
        }
        for (cat, nickname) in zip(catNames, nicknames) {
            XCTAssertEqual(listed[nickname], true, nickname)
            let supported = english ? "Supported: \(cat)" : "支持了：\(cat)"
            XCTAssertEqual(listed[supported], true, supported)
        }
        XCTAssertFalse(element(app, "about-thanks-testing").exists)

        app.terminate()
        let room = launch("shipped-news")
        room.buttons["open-room-news"].tap()
        let sponsors = room.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", nicknames[0])).firstMatch
        XCTAssertTrue(sponsors.waitForExistence(timeout: 15))
        for nickname in nicknames { XCTAssertTrue(sponsors.label.contains(nickname), nickname) }
        for _ in 0..<3 { room.swipeUp() }
        snap("news-sponsors")
    }

    /// A sponsor who gave a name is on their cat's card, in place of the bio line.
    func testANamedSponsorIsOnTheirCatsCard() {
        let app = launch("named-card")
        app.openCatManager()
        XCTAssertFalse(element(app, "sponsor-credit").exists, "no feature has a sponsor")
        openCard(app, "bella")
        let onCard = app.descendants(matching: .any)["cat-card"].descendants(matching: .any)["sponsor-credit"].firstMatch
        XCTAssertTrue(onCard.waitForExistence(timeout: 10))
        let words = english ? "This cat is supported by Omucat" : "这只猫咪由 Omucat 支持"
        XCTAssertTrue(onCard.label.contains(words), onCard.label)
        XCTAssertFalse(element(app, "cat-card-bio").exists, "the name replaces the nickname's line")
        snap("card-shipped-named")
    }

    func testACardWithOnlyTheNicknameKeepsItsBioAndAddsNothing() {
        let app = launch("nickname")
        app.openCatManager()
        XCTAssertFalse(element(app, "sponsor-credit").exists, "no feature has a sponsor")
        openCard(app, "black")
        let bio = element(app, "cat-card-bio")
        XCTAssertTrue(bio.label.contains(catNames[5]), bio.label)
        XCTAssertFalse(element(app, "sponsor-credit").exists, "the bio is the thanks")
        snap("card-nickname")
    }

    // MARK: Named sponsors (made up)

    func testOneSponsorIsNamedWhereTheirSupportOpens() {
        let app = launch("one", ["-MeowverseSampleSponsors", "one", "-MeowverseSeveralHomes"])
        app.openCatManager()
        let banner = element(app, "sponsor-credit")
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        let words = english ? "This feature was made possible by \(oneName)" : "这个功能由\(oneName)支持实现"
        XCTAssertTrue(banner.label.contains(words), banner.label)
        XCTAssertTrue(banner.isHittable, "seen without scrolling")
        XCTAssertLessThan(banner.frame.maxY, element(app, "cat-row").frame.minY, "first on the page")
        inWindow(app, banner)
        snap("feature-cats-one")

        openCard(app, "black")
        let onCard = app.descendants(matching: .any)["cat-card"].descendants(matching: .any)["sponsor-credit"].firstMatch
        XCTAssertTrue(onCard.waitForExistence(timeout: 10))
        XCTAssertTrue(onCard.label.contains(oneName), onCard.label)
        XCTAssertTrue(onCard.isHittable, "seen without scrolling")
        inWindow(app, onCard)
        XCTAssertFalse(element(app, "cat-card-bio").exists, "the name replaces the nickname's line")
        snap("card-named")

        app.terminate()
        let rooms = launch("one-rooms", ["-MeowverseSampleSponsors", "one", "-MeowverseSeveralHomes"])
        rooms.buttons["open-room-manager"].tap()
        let onRooms = element(rooms, "sponsor-credit")
        XCTAssertTrue(onRooms.waitForExistence(timeout: 10))
        XCTAssertTrue(onRooms.label.contains(words), onRooms.label)
        XCTAssertLessThan(onRooms.frame.maxY, element(rooms, "room-row").frame.minY, "first on the page")
        snap("feature-rooms-one")

        rooms.terminate()
        let about = launch("one-about", ["-MeowverseSampleSponsors", "one"])
        openAbout(about)
        XCTAssertEqual(about.staticTexts.matching(identifier: "about-sponsor").count, 1, "each person once")
        let supports = element(about, "about-sponsor-supports").label
        for part in english ? ["Luna", "several cats", "several rooms"] : ["露娜", "多只猫咪", "多个房间"] {
            XCTAssertTrue(supports.contains(part), supports)
        }
        snap("about-one")
    }

    func testSeveralAndLongNamesFit() {
        let app = launch("several", ["-MeowverseSampleSponsors", "several", "-MeowverseSeveralHomes"])
        app.openCatManager()
        let banner = element(app, "sponsor-credit")
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        for name in [oneName, longName, "Mochi & Bean"] { XCTAssertTrue(banner.label.contains(name), banner.label) }
        XCTAssertTrue(banner.isHittable)
        inWindow(app, banner)
        snap("feature-cats-several")

        app.terminate()
        let about = launch("several-about", ["-MeowverseSampleSponsors", "several"])
        openAbout(about)
        let someone = about.staticTexts[english ? "A cat’s human" : "一位铲屎官"]
        for _ in 0..<6 where !someone.exists { about.swipeUp(velocity: .slow) }
        XCTAssertTrue(someone.exists, "someone who supported nothing in particular is still listed")
        snap("about-several")
    }

    func testAHiddenFeatureHasNoBanner() {
        let app = launch("hidden", ["-MeowverseSampleSponsors", "several"])
        app.openCatManager()
        XCTAssertTrue(element(app, "cat-row").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "sponsor-credit").exists)

        app.terminate()
        let rooms = launch("hidden-rooms", ["-MeowverseSampleSponsors", "several"])
        rooms.buttons["open-room-manager"].tap()
        XCTAssertTrue(element(rooms, "room-row").waitForExistence(timeout: 10))
        XCTAssertFalse(element(rooms, "sponsor-credit").exists)
    }

    func testNobodyMeansNothingAtAll() {
        let app = launch("none", ["-MeowverseSampleSponsors", "none", "-MeowverseSeveralHomes"])
        app.openCatManager()
        XCTAssertTrue(element(app, "cat-row").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "sponsor-credit").exists)

        app.terminate()
        let about = launch("none-about", ["-MeowverseSampleSponsors", "none"])
        openAbout(about)
        XCTAssertTrue(element(about, "about-thanks-idea").waitForExistence(timeout: 10))
        XCTAssertFalse(element(about, "about-sponsors-intro").exists)
        snap("about-none")
    }

    // MARK: 设置

    func testSettingsOpensWithTheLabourOfLoveNote() {
        let app = launch("settings", ["-MeowverseLinkDrill"])
        app.buttons["open-settings"].tap()
        let note = element(app, "settings-labour-of-love")
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        XCTAssertEqual(note.label, english ? "Meowverse is a labor of love." : "喵空间是一个为爱发电的项目。")
        let link = element(app, "settings-github")
        XCTAssertTrue(link.isHittable, "seen on opening")
        let words = english ? "If you like it, please follow and star us on GitHub" : "喜欢的话，请去 GitHub 给我们一个关注和 star"
        XCTAssertTrue(link.label.contains(words), link.label)
        XCTAssertTrue(app.links["settings-github"].exists, "it reads as a link")
        XCTAssertGreaterThanOrEqual(link.frame.height, 44)
        XCTAssertLessThan(note.frame.minY, link.frame.minY)
        XCTAssertLessThan(link.frame.maxY, element(app, "open-cats-from-settings").frame.minY, "the first section")
        snap("settings-top")
        link.tap()
        let asked = expectation(for: NSPredicate(format: "value == %@", "https://github.com/Fengyee/meowverse-core"), evaluatedWith: link)
        wait(for: [asked], timeout: 5)
    }

    // MARK: The largest text size

    func testTheLargestTextFits() {
        let app = launch("largest", ["-MeowverseSampleSponsors", "one", "-MeowverseSeveralHomes"], largest: true)
        app.buttons["open-settings"].tap()
        let link = element(app, "settings-github")
        for _ in 0..<4 where !link.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(link.exists)
        sidesInWindow(app, link)
        snap("largest-settings")

        app.terminate()
        let cats = launch("largest-cats", ["-MeowverseSampleSponsors", "several", "-MeowverseSeveralHomes"], largest: true)
        cats.openCatManager()
        let banner = element(cats, "sponsor-credit")
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertTrue(banner.label.contains(longName))
        sidesInWindow(cats, banner)
        snap("largest-feature")

        cats.terminate()
        let card = launch("largest-card", ["-MeowverseSampleSponsors", "one"], largest: true)
        card.openCatManager()
        openCard(card, "black")
        let onCard = element(card, "sponsor-credit")
        XCTAssertTrue(onCard.waitForExistence(timeout: 10))
        sidesInWindow(card, onCard)
        snap("largest-card")
    }

    // MARK: Steps

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func openAbout(_ app: XCUIApplication) {
        app.buttons["open-settings"].tap()
        XCTAssertTrue(element(app, "open-cats-from-settings").waitForExistence(timeout: 10))
        let about = element(app, "open-about")
        for _ in 0..<12 where !(about.exists && about.isHittable) { app.swipeUp(velocity: .slow) }
        about.tap()
        XCTAssertTrue(app.navigationBars[english ? "About & privacy" : "关于与隐私"].waitForExistence(timeout: 10)
                      || element(app, "about-thanks-idea").waitForExistence(timeout: 5)
                      || element(app, "about-sponsors-intro").exists)
    }

    /// One slow drag from low to high inside `page`. On iPad 猫咪管理 is a popover: a swipe on
    /// it is refused ("unable to perform Swipe"), and a swipe on the app lands on the room and
    /// closes the popover. A drag that starts and ends inside it scrolls it on both.
    private func scrollUp(inside page: XCUIElement, of app: XCUIApplication) {
        let frame = page.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: frame.midX, dy: frame.minY + frame.height * 0.75))
        let to = origin.withOffset(CGVector(dx: frame.midX, dy: frame.minY + frame.height * 0.3))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    private func openCard(_ app: XCUIApplication, _ id: String) {
        let tile = app.buttons["cat-pack-" + id]
        // The grid is lazy: at the largest sizes her tile isn't in the tree until scrolled to.
        _ = tile.waitForExistence(timeout: 5)
        for _ in 0..<16 where !(tile.exists && tile.isHittable) { scrollUp(inside: element(app, "home-manager"), of: app) }
        XCTAssertTrue(tile.exists && tile.isHittable, id)
        tile.tap()
        XCTAssertTrue(element(app, "cat-card").waitForExistence(timeout: 10), "the card opens")
    }

    private func inWindow(_ app: XCUIApplication, _ target: XCUIElement) {
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(target.frame), "\(target.frame) in \(window)")
    }

    private func sidesInWindow(_ app: XCUIApplication, _ target: XCUIElement) {
        let window = app.windows.firstMatch.frame, frame = target.frame
        XCTAssertGreaterThanOrEqual(frame.minX, window.minX)
        XCTAssertLessThanOrEqual(frame.maxX, window.maxX)
        XCTAssertGreaterThanOrEqual(frame.height, 44)
    }

    private func snap(_ name: String) {
        usleep(500_000)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = (english ? "en-" : "zh-") + name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
