import XCTest

final class AdditionalFeaturesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ store: String, reset: Bool = true, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "additional-" + store, "-MeowverseSyntheticPhoto"] + extra
        if reset { app.launchArguments.append("-MeowverseResetStore") }
        app.launch()
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 20))
        return app
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func tap(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id]
        if !button.exists { _ = button.waitForExistence(timeout: 5) }
        for _ in 0..<6 {
            if button.exists && button.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(button.exists, id)
        XCTAssertTrue(button.isHittable, id)
        button.tap()
    }

    private func caption(_ app: XCUIApplication, contains word: String, timeout: TimeInterval = 40) {
        let match = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "bella-caption", word)).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: timeout), word)
    }

    private func choose(_ app: XCUIApplication, item: String, treat: Bool = false) {
        tap(app, "choose-interaction")
        tap(app, treat ? "choose-treat" : "choose-toy")
        tap(app, "play-item-" + item)
        XCTAssertTrue(app.buttons["place-play-item"].waitForExistence(timeout: 10))
    }

    private func addFurniture(_ app: XCUIApplication, category: String, model: String) {
        tap(app, "add-synthetic")
        tap(app, "manual-" + category)
        tap(app, "next-model")
        tap(app, "model-" + model)
        XCTAssertTrue(app.descendants(matching: .any)["model-preview-ready"].waitForExistence(timeout: 15))
        snap(model + "-preview")
        tap(app, "next-placement")
        tap(app, "confirm-placement")
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 15))
    }

    private func invite(_ app: XCUIApplication, site: String, action: String, word: String, shot: String) {
        tap(app, "choose-interaction")
        tap(app, "invite-\(site)-\(action)")
        caption(app, contains: word)
        app.descendants(matching: .any)["room-world"].pinch(withScale: 1.8, velocity: 2)
        sleep(1)
        snap(shot)
    }

    // The room sound switches live only in the top band's 音乐音效 panel now:
    // RoomTopBarUITests.testSoundTogglesPersistAcrossLaunches covers them switching on their own
    // and persisting.

    func testWindUpMouseRunsAgainAfterTheCatCatchesIt() throws {
        let app = launch("wind-up")
        addFurniture(app, category: "toy", model: "mv-toy-d")
        let source = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查看照片")).firstMatch
        let home = try XCTUnwrap(source.value as? String)
        tap(app, "choose-interaction")
        tap(app, "invite-tail-play")
        XCTAssertTrue(app.staticTexts["wind-up-running"].waitForExistence(timeout: 10))
        caption(app, contains: "正在玩发条小鼠")
        caption(app, contains: "正靠近发条小鼠")
        caption(app, contains: "正在玩发条小鼠")
        snap("wind-up-after-second-catch")
        tap(app, "end-play")
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        XCTAssertEqual(source.value as? String, home)
        snap("wind-up-back-home")
        source.tap()
        XCTAssertTrue(app.descendants(matching: .any)["original-photo"].waitForExistence(timeout: 15))
    }

    func testSelectableToysFollowAndEndInEmptyRoom() {
        let app = launch("toys")
        for (item, word) in [("toyMouse", "毛毡小鼠"), ("toyBall", "拼色小球"), ("featherWand", "羽毛逗猫棒")] {
            choose(app, item: item)
            tap(app, "place-play-item")
            caption(app, contains: "正在玩" + word)
            app.descendants(matching: .any)["room-world"].pinch(withScale: 1.8, velocity: 2)
            sleep(1)
            snap("free-play-" + item)
            tap(app, "place-play-item")
            caption(app, contains: "正在玩" + word)
            tap(app, "end-play")
            XCTAssertFalse(app.buttons["place-play-item"].exists)
        }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查看照片")).count, 0)
        app.terminate()
        app.launch()
        tap(app, "choose-interaction")
        tap(app, "choose-toy")
        XCTAssertEqual(app.buttons["play-item-featherWand"].value as? String, "已选择")
        snap("selected-toy-after-relaunch")
    }

    func testThreeTreatsAreConsumedWithoutAddingFurniture() {
        let app = launch("treats")
        for (item, word) in [("treatSalmon", "三文鱼小片"), ("treatChicken", "鸡肉小块"), ("treatBiscuit", "小鱼饼干")] {
            choose(app, item: item, treat: true)
            tap(app, "place-play-item")
            caption(app, contains: "正在吃" + word)
            app.descendants(matching: .any)["room-world"].pinch(withScale: 1.8, velocity: 2)
            sleep(1)
            snap("treat-" + item)
            let finished = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "吃完了")).firstMatch
            XCTAssertTrue(finished.waitForExistence(timeout: 15))
            tap(app, "end-play")
        }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查看照片")).count, 0)
    }

    func testLitterBoxDigAndSourceAfterRelaunch() {
        let app = launch("litter")
        // The pickers offer the v2 model that replaced the legacy id (mv-furniture.catalog.json
        // aliases); its sites, labels and actions are read from the baked catalog.
        addFurniture(app, category: "litterBox", model: "mv-litter-box-a")
        invite(app, site: "sand", action: "dig", word: "扒砂", shot: "litter-box-dig")
        app.terminate()
        app.launchArguments.removeAll { $0 == "-MeowverseResetStore" }
        app.launch()
        let source = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查看照片")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 20))
        source.tap()
        XCTAssertTrue(app.descendants(matching: .any)["original-photo"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["photo-caption"].label.contains("由你手动选择"))
        snap("litter-source-after-relaunch")
    }

    func testWindowPerchSitLoafAndSleep() {
        let app = launch("window")
        addFurniture(app, category: "windowPerch", model: "mv-window-perch-a")
        invite(app, site: "watch", action: "sit", word: "窗边座位", shot: "window-watch")
        invite(app, site: "nap", action: "loaf", word: "窝着", shot: "window-loaf")
        invite(app, site: "nap", action: "sleep", word: "睡觉", shot: "window-sleep")
    }

    /// Every site of the cat tree once, together covering every action it offers (sit, loaf,
    /// sleep, play, hide, scratch). The legacy lookout tree had six activities on four sites;
    /// mv-cat-tree-a has seven sites.
    func testCatTreeEverySiteAndAction() {
        let app = launch("tree")
        addFurniture(app, category: "catTree", model: "mv-cat-tree-a")
        for (site, action, word) in [("play", "play", "逗毛球拍玩具"), ("hide", "hide", "的毡窝"),
                                      ("scratch", "scratch", "剑麻柱上磨爪"), ("mid", "sit", "中层圆台上坐着"),
                                      ("ledge", "sit", "毡窝顶上坐着"), ("upper", "loaf", "高层圆台上窝着"),
                                      ("top", "sleep", "顶层软窝上睡觉")] {
            invite(app, site: site, action: action, word: word, shot: "cat-tree-\(site)-\(action)")
        }
    }

    func testScratchBoardAndSisalPost() {
        var app = launch("scratch-board")
        addFurniture(app, category: "scratcher", model: "mv-scratcher-b")
        invite(app, site: "scratch", action: "scratch", word: "磨爪", shot: "scratch-board-contact")
        app.terminate()
        app = launch("sisal")
        addFurniture(app, category: "scratcher", model: "mv-scratcher-a")
        invite(app, site: "scratch", action: "scratch", word: "磨爪", shot: "sisal-post-scratch")
        invite(app, site: "perch", action: "sit", word: "顶上软垫", shot: "sisal-post-perch")
    }

    func testFeatherWandFurniture() {
        let app = launch("wand-furniture")
        addFurniture(app, category: "toy", model: "mv-toy-b")
        invite(app, site: "plume", action: "play", word: "拍玩具", shot: "feather-wand-contact")
    }

    func testWaterBowlAndFlowerFountain() {
        var app = launch("water-bowl")
        addFurniture(app, category: "water", model: "mv-water-a")
        invite(app, site: "water", action: "drink", word: "舔水", shot: "water-bowl-drink")
        invite(app, site: "kibble", action: "eat", word: "吃东西", shot: "food-bowl-eat")
        app.terminate()
        app = launch("fountain")
        addFurniture(app, category: "water", model: "mv-water-b")
        invite(app, site: "basin", action: "drink", word: "舔水", shot: "flower-fountain-drink")
    }
}
