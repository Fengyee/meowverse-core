import XCTest

/// Round 10's six new pieces (art/furniture/reviews/r10-new-furniture.md), picked from the
/// furniture catalogue without a photo: each one is placed, Bella is invited to every site and
/// action it offers, and the furniture list says it has no photo yet. The cat wheel is tall
/// enough to hide a photo board, so it may not stand flush under one (GridRules.newPieces).
/// Screenshots are kept as attachments.
final class Round10FurnitureUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private typealias Site = (id: String, label: String, actions: [String])
    private struct Piece {
        let model: String, category: String, name: String, english: String
        let sites: [Site]
    }

    private static let pieces: [Piece] = [
        Piece(model: "mv-sofa-d", category: "sofa", name: "懒人豆袋沙发", english: "Slouch beanbag sofa", sites: [
            ("seat-left", "左座垫", ["sit"]), ("seat-right", "右座垫", ["sit"]), ("seat-middle", "座垫中间", ["loaf", "sleep"])]),
        Piece(model: "mv-hideout-d", category: "hideout", name: "纸箱", english: "Cardboard box", sites: [
            ("in-box", "纸箱里", ["sit", "loaf", "sleep"]), ("peek", "箱门口探头", ["hide"])]),
        Piece(model: "mv-chair-d", category: "chair", name: "人体工学椅", english: "Ergonomic chair", sites: [("seat", "座位", ["sit", "loaf"])]),
        Piece(model: "mv-chair-e", category: "chair", name: "折叠懒人椅", english: "Folding floor chair", sites: [
            ("seat", "座位", ["sit"]), ("nap", "坐垫上打盹", ["loaf", "sleep"])]),
        Piece(model: "mv-bed-f", category: "bed", name: "浴缸猫窝", english: "Bathtub cat bed", sites: [("nest", "浴缸窝里", ["sit", "loaf", "sleep"])]),
        Piece(model: "mv-toy-g", category: "toy", name: "猫咪跑轮", english: "Cat wheel", sites: [("wheel", "跑轮里", ["sit", "loaf"])]),
    ]

    private func launch(_ store: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "round10-" + store, "-MeowverseResetStore"]
        app.launch()
        XCTAssertTrue(app.buttons["place-furniture-first"].waitForExistence(timeout: 20))
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
        _ = button.waitForExistence(timeout: 10)
        for _ in 0..<6 where !(button.exists && button.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        if !(button.exists && button.isHittable) { snap("missing-" + id) }
        XCTAssertTrue(button.exists && button.isHittable, id)
        button.tap()
    }

    /// "先摆家具" in the empty room, else 添加家具 in the furniture list; then the category and
    /// on to its model step.
    private func openCatalog(_ app: XCUIApplication, category: String) {
        let first = app.buttons["place-furniture-first"]
        if first.exists && first.isHittable {
            first.tap()
        } else {
            tap(app, "furniture-list")
            tap(app, "add-furniture")
        }
        tap(app, "manual-" + category)
        tap(app, "next-model")
    }

    private func place(_ app: XCUIApplication, _ piece: Piece, shot: String? = nil) {
        openCatalog(app, category: piece.category)
        tap(app, "model-" + piece.model)
        XCTAssertTrue(app.descendants(matching: .any)["model-preview-ready"].waitForExistence(timeout: 20), piece.model)
        if let shot {
            sleep(2) // the preview fades in
            snap(shot)
        }
        tap(app, "next-placement")
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10), piece.model)
        tap(app, "confirm-placement")
        XCTAssertTrue(app.buttons["furniture-list"].waitForExistence(timeout: 15), piece.model)
    }

    /// The whole caption once she is there (`BellaStatus.caption`, Chinese), never naming the
    /// piece twice: "Kitty 在纸箱里坐着", "Kitty 躲在纸箱的门洞", "Kitty 在浴缸猫窝的软垫上窝着".
    private static func caption(_ piece: Piece, label: String, action: String) -> String {
        let word = ["sit": "坐着", "loaf": "窝着", "sleep": "睡觉"][action]
        if ["纸箱里", "跑轮里"].contains(label), let word { return "Kitty 在\(piece.name)里\(word)" }
        let site = ["箱门口探头": "门洞", "坐垫上打盹": "坐垫", "浴缸窝里": "软垫"][label] ?? label
        if action == "hide" { return "Kitty 躲在\(piece.name)的\(site)" }
        let place = ["上", "里", "中间"].contains(where: site.hasSuffix) ? site : site + "上"
        return "Kitty 在\(piece.name)的\(place)" + word!
    }

    /// The English caption for the first action of every site (`BellaStatus.caption`).
    private static let englishCaptions: [(model: String, site: String, action: String, caption: String)] = [
        ("mv-sofa-d", "seat-left", "sit", "Kitty is sitting on the left cushion of the slouch beanbag sofa"),
        ("mv-sofa-d", "seat-right", "sit", "Kitty is sitting on the right cushion of the slouch beanbag sofa"),
        ("mv-sofa-d", "seat-middle", "loaf", "Kitty is loafing on the middle of the seat of the slouch beanbag sofa"),
        ("mv-hideout-d", "in-box", "sit", "Kitty is sitting in the cardboard box"),
        ("mv-hideout-d", "peek", "hide", "Kitty is hiding in the doorway of the cardboard box"),
        ("mv-chair-d", "seat", "sit", "Kitty is sitting on the seat of the ergonomic chair"),
        ("mv-chair-e", "seat", "sit", "Kitty is sitting on the seat of the folding floor chair"),
        ("mv-chair-e", "nap", "loaf", "Kitty is loafing on the pad of the folding floor chair"),
        ("mv-bed-f", "nest", "sit", "Kitty is sitting on the cushion of the bathtub cat bed"),
        ("mv-toy-g", "wheel", "loaf", "Kitty is loafing in the cat wheel"),
    ]

    private func invite(_ app: XCUIApplication, _ piece: Piece, site: String, label: String, action: String, shot: String) {
        invite(app, row: nil, site: site, action: action, words: Self.caption(piece, label: label, action: action), shot: shot)
    }

    /// `row`: the piece's row in the interaction picker, when the room holds more than one piece.
    private func invite(_ app: XCUIApplication, row: String?, site: String, action: String, words: String, shot: String) {
        tap(app, "choose-interaction")
        if let row {
            let button = app.buttons.matching(NSPredicate(format: "label == %@", row)).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10), row)
            button.tap()
        }
        tap(app, "invite-\(site)-\(action)")
        let caption = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "bella-caption", words)).firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 40), words)
        sleep(4) // past the settle blend
        snap(shot)
    }

    /// One room per piece: placed from the catalogue, then every site and action, the first one
    /// shot unzoomed (the piece in the room) and the rest in close-up.
    private func check(_ piece: Piece) {
        let app = launch(String(piece.model.dropFirst(3)))
        place(app, piece, shot: "\(piece.model)-picker")
        // Placed without a photo: the room says so (AGENTS.md).
        let hotspot = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", "\(piece.name)，还没有照片")).firstMatch
        XCTAssertTrue(hotspot.waitForExistence(timeout: 10), "\(piece.name)，还没有照片")
        var first = true
        for (site, label, actions) in piece.sites {
            for action in actions {
                invite(app, piece, site: site, label: label, action: action,
                       shot: first ? "\(piece.model)-room" : "\(piece.model)-\(site)-\(action)")
                if first {
                    app.descendants(matching: .any)["room-world"].pinch(withScale: 1.8, velocity: 2)
                    sleep(3)
                    snap("\(piece.model)-\(site)-\(action)")
                    first = false
                }
            }
        }
    }

    func testBeanbagSofa() { check(Self.pieces[0]) }
    func testCardboardBox() { check(Self.pieces[1]) }
    func testErgonomicChair() { check(Self.pieces[2]) }
    func testFoldingFloorChair() { check(Self.pieces[3]) }
    func testBathtubBed() { check(Self.pieces[4]) }
    func testCatWheel() { check(Self.pieces[5]) }

    /// In English: all six in one room, Bella invited to every site, and the caption reads as one
    /// sentence ("Kitty is sitting in the cat wheel", not "on the in the wheel of the cat wheel").
    func testEnglishCaptions() {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.english + ["-MeowverseStore", "round10-english", "-MeowverseResetStore"]
        app.launch()
        XCTAssertTrue(app.buttons["place-furniture-first"].waitForExistence(timeout: 20))
        for piece in Self.pieces { place(app, piece) }
        for line in Self.englishCaptions {
            let piece = Self.pieces.first { $0.model == line.model }!
            invite(app, row: piece.english, site: line.site, action: line.action, words: line.caption,
                   shot: "en-\(line.model)-\(line.site)-\(line.action)")
        }
    }

    /// The cat wheel alone in an English room, Bella in it: the English review shot.
    func testEnglishCatWheelRoom() {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.english + ["-MeowverseStore", "round10-english-wheel", "-MeowverseResetStore"]
        app.launch()
        XCTAssertTrue(app.buttons["place-furniture-first"].waitForExistence(timeout: 20))
        place(app, Self.pieces[5])
        invite(app, row: nil, site: "wheel", action: "sit", words: "Kitty is sitting in the cat wheel", shot: "en-mv-toy-g-room")
    }

    /// All six in one room from the catalogue; the furniture list shows each with "还没有照片".
    func testAllSixInOneRoomAndTheFurnitureList() {
        let app = launch("all")
        for piece in Self.pieces { place(app, piece) }
        sleep(4)
        snap("round10-room")

        tap(app, "furniture-list")
        XCTAssertTrue(app.buttons["add-furniture"].waitForExistence(timeout: 10))
        for piece in Self.pieces {
            let row = app.buttons.matching(NSPredicate(
                format: "(label CONTAINS %@) AND (label CONTAINS %@ OR value CONTAINS %@)", piece.name, "还没有照片", "还没有照片")).firstMatch
            for _ in 0..<4 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(row.exists, "\(piece.name) row with 还没有照片")
        }
        app.swipeDown(velocity: .slow)
        sleep(1)
        snap("round10-furniture-list")
    }

    private func status(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["placement-status"].firstMatch.label
    }

    /// A photo board on the back wall, then the wheel pushed flush under it: refused, with the
    /// reason; slid along the wall until the board is clear, it goes in.
    func testCatWheelKeepsClearOfAPhotoBoard() {
        let app = launch("wheel-board")
        openCatalog(app, category: "photoBoard")
        XCTAssertTrue(app.descendants(matching: .any)["model-preview-ready"].waitForExistence(timeout: 20))
        tap(app, "next-placement")
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        tap(app, "confirm-placement")
        XCTAssertTrue(app.buttons["furniture-list"].waitForExistence(timeout: 15))

        openCatalog(app, category: "toy")
        tap(app, "model-mv-toy-g")
        XCTAssertTrue(app.descendants(matching: .any)["model-preview-ready"].waitForExistence(timeout: 20))
        tap(app, "next-placement")
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        for _ in 0..<15 {
            app.buttons["向里移一格"].tap()
            if status(app) == "超出了房间范围" {
                app.buttons["向外移一格"].tap()
                break
            }
        }
        // Slide along the wall until it sits under the board: rightwards, then back leftwards.
        var steps = 0
        for direction in ["向右移一格", "向左移一格"] where !status(app).contains("照片板") {
            steps = 0
            while !status(app).contains("照片板") && status(app) != "超出了房间范围" && steps < 15 {
                app.buttons[direction].tap()
                steps += 1
            }
            if status(app) == "超出了房间范围" { app.buttons[direction == "向右移一格" ? "向左移一格" : "向右移一格"].tap() }
        }
        XCTAssertTrue(status(app).contains("照片板"), status(app))
        sleep(3)
        snap("mv-toy-g-hides-board")
        steps = 0
        while status(app) != "这个位置可以摆放" && steps < 10 {
            app.buttons["向左移一格"].tap()
            steps += 1
        }
        XCTAssertEqual(status(app), "这个位置可以摆放")
        tap(app, "confirm-placement")
        XCTAssertTrue(app.buttons["furniture-list"].waitForExistence(timeout: 15))
        sleep(4)
        snap("mv-toy-g-beside-board")
    }
}
