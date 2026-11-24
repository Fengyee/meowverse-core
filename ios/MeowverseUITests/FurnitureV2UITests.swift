import XCTest

/// Pilot evidence for the v2 furniture library (art/furniture/TECH_SPEC.md): each Blender sofa is
/// picked from the manual catalog, placed, and Bella is invited to every site and action it offers.
/// Screenshots are kept as attachments for art/furniture/validation/.
final class FurnitureV2UITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ store: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "furniture-v2-" + store, "-MeowverseSyntheticPhoto", "-MeowverseResetStore"]
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
        for attempt in 0..<8 {
            if button.exists && button.isHittable { break }
            // A sheet may still be animating in: wait first, then drag the content up from the
            // lower half (a plain swipe can land on the photo, or be eaten by the sheet).
            if attempt < 3 {
                sleep(1)
            } else {
                let window = app.windows.firstMatch
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
                    .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32)))
                sleep(1)
            }
        }
        if !(button.exists && button.isHittable) { snap("missing-" + id) }
        XCTAssertTrue(button.exists, id)
        XCTAssertTrue(button.isHittable, id)
        button.tap()
    }

    private func caption(_ app: XCUIApplication, contains words: String, timeout: TimeInterval = 40) {
        let match = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "bella-caption", words)).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: timeout), words)
    }

    /// Swipes the open sheet up, a bounded number of times, until `id` is on screen: the category
    /// grid is below the fold of the photo review once the photo and the hint above it are shown.
    private func reveal(_ app: XCUIApplication, _ id: String, swipes: Int = 8) {
        let button = app.buttons[id]
        _ = button.waitForExistence(timeout: 5)
        var done = 0
        while !(button.exists && button.isHittable) && done < swipes {
            app.swipeUp(velocity: .slow)
            done += 1
        }
        if !(button.exists && button.isHittable) { snap("missing-" + id) }
        XCTAssertTrue(button.exists && button.isHittable, "\(id) is still not on screen after \(swipes) swipes up")
    }

    private func addFurniture(_ app: XCUIApplication, category: String, model: String, finish: String? = nil) {
        tap(app, "add-synthetic")
        reveal(app, "manual-" + category)
        tap(app, "manual-" + category)
        tap(app, "next-model")
        tap(app, "model-" + model)
        XCTAssertTrue(app.descendants(matching: .any)["model-preview-ready"].waitForExistence(timeout: 15))
        snap(model + "-preview")
        tap(app, "next-placement")
        if let finish {
            // A schema 7 palette preset, picked by its VoiceOver name in the placement editor.
            let swatch = app.buttons[finish]
            XCTAssertTrue(swatch.waitForExistence(timeout: 5), finish)
            swatch.tap()
            XCTAssertTrue(swatch.isSelected, finish)
            sleep(4) // let the RealityKit preview draw the room and the recoloured ghost
            snap(model + "-placement-" + finish)
        }
        tap(app, "confirm-placement")
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 15))
    }

    private func invite(_ app: XCUIApplication, model: String, site: String, label: String, action: String) {
        tap(app, "choose-interaction")
        tap(app, "invite-\(site)-\(action)")
        caption(app, contains: Self.caption(label, action))
        app.descendants(matching: .any)["room-world"].pinch(withScale: 1.8, velocity: 2)
        sleep(5)
        snap("\(model)-\(site)-\(action)")
    }

    /// The part of the caption that names the site and the action (see `BellaStatus.caption`).
    private static func caption(_ label: String, _ action: String) -> String {
        let site = ["沿座垫横卧": "座垫", "软垫午睡": "软垫", "磨爪": "抓面", "台下阴凉": "阴凉处",
                    "逗毛球": "毛球旁", "拍橡果": "橡果旁"][label] ?? label
        let located = ["被子上", "斜坡上", "窝里", "桌子底下", "座垫中间", "桌面中间", "中间",
                       "桌面左边", "桌面右边", "隧道口", "阴凉处", "床尾"]
        let place = located.contains(site) ? site : site + "上"
        switch action {
        case "hide": return "的" + site
        case "play": return site + "拍玩具"
        case "scratch": return place + "磨爪"
        default: return place + ["sit": "坐着", "loaf": "窝着", "sleep": "睡觉"][action]!
        }
    }

    private func check(_ model: String, category: String = "sofa", finish: String? = nil, sites: [(String, String, [String])]) {
        let app = launch(model)
        addFurniture(app, category: category, model: model, finish: finish)
        for (site, label, actions) in sites {
            for action in actions {
                invite(app, model: model, site: site, label: label, action: action)
            }
        }
    }

    func testPilotSofaASites() {
        check("mv-sofa-a", sites: [("back-top", "靠背顶", ["loaf"]), ("seat-left", "左座垫", ["sit", "loaf"]),
                                   ("seat-middle", "座垫中间", ["sleep"]), ("seat-right", "右座垫", ["sit"])])
    }

    func testPilotSofaBSites() {
        // Sites as baked in mv-furniture.catalog.json (approved export): lying along the seat is
        // its own `lounge` site, the two seats are for sitting.
        check("mv-sofa-b", finish: "杏桃", sites: [("seat-left", "左座垫", ["sit"]), ("seat-right", "右座垫", ["sit"]),
                                                  ("lounge", "沿座垫横卧", ["loaf", "sleep"])])
    }

    func testPilotSofaCSites() {
        check("mv-sofa-c", sites: [("chaise", "贵妃位", ["sleep"]), ("seat", "座垫", ["sit"])])
    }

    func testPilotCatTreeASites() {
        check("mv-cat-tree-a", category: "catTree", sites: [
            ("hide", "毡窝", ["hide"]), ("ledge", "毡窝顶", ["sit"]), ("mid", "中层圆台", ["loaf"]),
            ("play", "逗毛球", ["play"]), ("scratch", "剑麻柱", ["scratch"]), ("top", "顶层软窝", ["sleep"])])
    }

    func testPilotCatTreeBSites() {
        check("mv-cat-tree-b", category: "catTree", sites: [
            ("hide", "树洞", ["hide"]), ("leaf", "叶子台", ["loaf"]), ("play", "拍橡果", ["play"]),
            ("stump", "树桩顶", ["scratch"]), ("top", "树冠软垫", ["sit"])])
    }

    func testPilotCatTreeCSites() {
        check("mv-cat-tree-c", category: "catTree", finish: "蔷薇", sites: [
            ("hide", "方块小屋", ["hide"]), ("ledge", "小屋顶", ["loaf"]), ("mid", "方块顶", ["sit"]),
            ("play", "逗毛球", ["play"]), ("scratch", "剑麻面板", ["scratch"]), ("top", "屋顶躺椅", ["sleep"])])
    }

    // Approved models beyond the pilot, integrated in batches: each site with its first action
    // (lists generated from mv-furniture.catalog.json for the ids in art/furniture/approved.json).
    private typealias Batch = [(model: String, category: String, sites: [(String, String, [String])])]

    private func checkBatch(_ batch: Batch) {
        for entry in batch { check(entry.model, category: entry.category, sites: entry.sites) }
    }

    func testBatchChairsAndStools() {
        checkBatch([
            ("mv-chair-a", "chair", [("seat", "座位", ["sit"])]),
            ("mv-chair-b", "chair", [("seat", "座位", ["sit"])]),
            ("mv-chair-c", "chair", [("seat", "座位", ["sit"])]),
            ("mv-stool-a", "stool", [("seat", "凳面", ["sit"])]),
            ("mv-stool-b", "stool", [("cap", "蘑菇顶", ["sit"])]),
            ("mv-stool-c", "stool", [("top", "墩子顶", ["sit"])]),
        ])
    }

    func testBatchBenches() {
        checkBatch([
            ("mv-bench-a", "bench", [("seat-left", "左边座位", ["sit"]), ("seat-right", "右边座位", ["sit"]), ("seat-middle", "中间", ["sleep"])]),
            ("mv-bench-b", "bench", [("seat-left", "左边座位", ["sit"]), ("seat-right", "右边座位", ["sit"]), ("seat-middle", "中间", ["sleep"])]),
            ("mv-bench-c", "bench", [("seat-left", "左边座位", ["sit"]), ("seat-right", "右边座位", ["sit"]), ("seat-middle", "中间", ["sleep"])]),
        ])
    }

    func testBatchTables() {
        checkBatch([
            ("mv-table-a", "table", [("under", "桌子底下", ["loaf"])]),
            ("mv-table-b", "table", [("under", "桌子底下", ["loaf"])]),
            ("mv-table-c", "table", [("top-left", "桌面左边", ["sit"]), ("top-right", "桌面右边", ["sit"]), ("top-middle", "桌面中间", ["sleep"])]),
        ])
    }

    func testSleepOnQuiltAndWakeOnTheSameSite() {
        let app = launch("sleep-on-quilt")
        openCatalog(app, category: "bed")
        tap(app, "next-model")
        place(app, model: "mv-bed-a")
        for action in ["sleep", "sit"] {
            invite(app, model: "mv-bed-a", site: "quilt", label: "被子上", action: action)
        }
    }

    func testBatchBeds() {
        checkBatch([
            ("mv-bed-a", "bed", [("quilt", "被子上", ["sit"]), ("pillow", "枕头", ["loaf"])]),
            ("mv-bed-b", "bed", [("bed-foot", "床尾", ["sit"]), ("pillow-left", "左枕头", ["loaf"]), ("pillow-right", "右枕头", ["loaf"])]),
            ("mv-bed-c", "bed", [("well", "窝里", ["sit"])]),
        ])
    }

    func testBatchScratchersAndPlatforms() {
        checkBatch([
            ("mv-scratcher-a", "scratcher", [("scratch", "磨爪", ["scratch"]), ("perch", "顶上软垫", ["sit"])]),
            ("mv-scratcher-b", "scratcher", [("lounge", "斜坡上", ["loaf"]), ("scratch", "磨爪", ["scratch"])]),
            ("mv-platform-c", "platform", [("deck", "平台软垫", ["sit"]), ("under", "台下阴凉", ["loaf"])]),
        ])
    }

    /// Frames of the climb to the top perch of mv-cat-tree-a, for checking the hop arc (CatHop):
    /// her feet must be above each platform before she crosses its edge.
    func testCatTreeAClimbFrames() {
        let app = launch("mv-cat-tree-a-climb")
        addFurniture(app, category: "catTree", model: "mv-cat-tree-a")
        // Start on the low ledge in close-up, so the frames show only the climb to the top.
        invite(app, model: "mv-cat-tree-a", site: "ledge", label: "毡窝顶", action: "sit")
        tap(app, "choose-interaction")
        tap(app, "invite-top-sleep")
        for frame in 0..<30 { snap(String(format: "climb-%02d", frame)) }
        caption(app, contains: Self.caption("顶层软窝", "sleep"))
    }

    // MARK: Acceptance shots (art/furniture/validation/accept-*.jpg)

    /// The acceptance frames, from an empty room and catalog placement only: no photo is
    /// imported, so no photo or import screen is ever on screen (and no test buttons: the app
    /// runs without `-MeowverseSyntheticPhoto`). Shots are named `accept-*`.
    func testAcceptanceShowcase() {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "furniture-v2-accept", "-MeowverseResetStore"]
        app.launch()
        XCTAssertTrue(app.buttons["place-furniture-first"].waitForExistence(timeout: 20))

        // The model picker offers only the mv-* styles: the legacy ids they replace are hidden.
        openCatalog(app, category: "sofa")
        tap(app, "next-model")
        for id in ["mv-sofa-a", "mv-sofa-b", "mv-sofa-c"] {
            XCTAssertTrue(app.buttons["model-" + id].waitForExistence(timeout: 5), id)
        }
        for id in ["kenney-loungeSofa", "kenney-loungeSofaLong"] {
            XCTAssertFalse(app.buttons["model-" + id].exists, "legacy \(id) is offered")
        }
        snap("accept-picker-sofa")

        // A palette swap in the placement editor, then the rest of the room from the catalog.
        place(app, model: "mv-sofa-b", finish: "杏桃", shot: "accept-palette-apricot")
        for (category, model) in [("catTree", "mv-cat-tree-c"), ("hideout", "mv-hideout-b"),
                                  ("bed", "mv-bed-c"), ("water", "mv-water-b")] {
            openCatalog(app, category: category)
            tap(app, "next-model")
            place(app, model: model)
        }
        sleep(4)
        snap("accept-room")

        // Bella on a sofa, a cat tree and a hideout.
        invite(app, piece: "木框靠枕沙发", model: "mv-sofa-b", site: "lounge", label: "沿座垫横卧", action: "sleep")
        invite(app, piece: "积木猫爬架", model: "mv-cat-tree-c", site: "top", label: "屋顶躺椅", action: "loaf")
        invite(app, piece: "毛毡圆顶窝", model: "mv-hideout-b", site: "nap", label: "软垫午睡", action: "sleep")
        invite(app, piece: "毛毡圆顶窝", model: "mv-hideout-b", site: "cave", label: "毛毡洞", action: "hide")
    }

    /// "先摆家具" in the empty room, else 添加家具 in the furniture list; then a category.
    private func openCatalog(_ app: XCUIApplication, category: String) {
        let first = app.buttons["place-furniture-first"]
        if first.exists && first.isHittable {
            first.tap()
        } else {
            tap(app, "furniture-list")
            tap(app, "add-furniture")
        }
        reveal(app, "manual-" + category)
        tap(app, "manual-" + category)
    }

    /// Picks `model` in the open model step and confirms it at the suggested spot.
    private func place(_ app: XCUIApplication, model: String, finish: String? = nil, shot: String? = nil) {
        tap(app, "model-" + model)
        XCTAssertTrue(app.descendants(matching: .any)["model-preview-ready"].waitForExistence(timeout: 15))
        tap(app, "next-placement")
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10), model)
        if let finish {
            let swatch = app.buttons[finish]
            XCTAssertTrue(swatch.waitForExistence(timeout: 5), finish)
            swatch.tap()
            XCTAssertTrue(swatch.isSelected, finish)
            sleep(4) // let the RealityKit preview draw the recoloured ghost
        }
        if let shot { snap(shot) }
        tap(app, "confirm-placement")
        XCTAssertTrue(app.buttons["furniture-list"].waitForExistence(timeout: 15), model)
    }

    /// Invites Bella to one site of one piece in a room with several: the piece row first.
    private func invite(_ app: XCUIApplication, piece: String, model: String, site: String, label: String, action: String) {
        tap(app, "choose-interaction")
        let row = app.buttons.matching(NSPredicate(format: "label == %@", piece)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), piece)
        row.tap()
        tap(app, "invite-\(site)-\(action)")
        caption(app, contains: Self.caption(label, action))
        app.descendants(matching: .any)["room-world"].pinch(withScale: 1.8, velocity: 2)
        sleep(5)
        snap("accept-\(model.dropFirst(3))-\(site)-\(action)")
    }
}
