import XCTest

/// Suggested filing (按建议放进家具) on the colour-grid stand-in: the strip and the confirmation
/// page for a small batch, the representative round of a big one, offers after a relaunch, and
/// the re-run entry on a photo board. Synthetic photos only: scene 0 is the sofa photo with a
/// ball added, so every scene-0 photo looks like the sofa's.
final class BatchSuggestionsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(reset: Bool, store: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseSyntheticPhoto",
                                                      "-MeowverseColorGridSimilarity"] + extra
        if reset { app.launchArguments.append("-MeowverseResetStore") }
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 20))
        return app
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var sourceButton: NSPredicate { NSPredicate(format: "label CONTAINS %@", "查看照片") }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 20,
                              file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "expected “\(text)” in “\(element.exists ? element.label : "<missing>")”", file: file, line: line)
    }

    private func waitToVanish(_ element: XCUIElement, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, "\(element) is still there", file: file, line: line)
    }

    @discardableResult
    private func reveal(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(app, id)
        for _ in 0..<5 where !(target.exists && target.isHittable) { app.swipeUp(velocity: .slow) }
        for _ in 0..<8 where !(target.exists && target.isHittable) { app.swipeDown(velocity: .slow) }
        usleep(600_000)
        XCTAssertTrue(target.exists && target.isHittable, "could not reach \(id)", file: file, line: line)
        return target
    }

    /// The notice bar is a container; its words are in a text inside it.
    private func noticeText(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        element(app, "suggested-filing-notice").staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func tiles(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'suggestion-photo-'"))
    }

    /// A sofa holding two scene-0 photos (the rule wants two filed photos of one piece).
    private func sofaWithTwoPhotos(_ app: XCUIApplication) {
        app.buttons["add-synthetic"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 20))
        sofa.tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        let piece = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(piece.waitForExistence(timeout: 15))
        sleep(1)
        piece.tap()
        XCTAssertTrue(app.buttons["furniture-more"].waitForExistence(timeout: 10))
        app.buttons["furniture-more"].tap()
        let another = app.buttons["再添一张合成照片"]
        XCTAssertTrue(another.waitForExistence(timeout: 5))
        another.tap()
        XCTAssertTrue(element(app, "furniture-album").waitForExistence(timeout: 20), "two photos make an album")
        app.buttons["close-detail"].tap()
    }

    /// Photos that take long to arrive (full-size photos coming from iCloud): the bar says what
    /// it is waiting for, counts each photo as it arrives, and the import still completes.
    func testSlowPhotosExplainTheWait() {
        let app = launch(reset: true, store: "ui-batch-slow", extra: ["-MeowverseSyntheticBatch", "4", "2",
                                                                       "-MeowverseSyntheticLoadDelay", "7"])
        app.addSyntheticBatch()
        let progress = element(app, "batch-progress")
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertTrue((progress.value as? String ?? "").contains("iCloud"), "the bar says what a slow import waits for")
        XCTAssertTrue((progress.value as? String ?? "").hasPrefix("0 / 4"), "\(progress.value ?? "")")
        let pending = element(app, "pending-count")
        XCTAssertTrue(pending.waitForExistence(timeout: 60))
        waitForLabel(pending, containing: "4 张照片待整理", timeout: 60)
    }

    /// Adding a slow photo to a piece: the page can be closed, the room shows the progress, and
    /// the photo still arrives in the piece.
    func testAddingToAPieceCarriesOnAfterThePageCloses() {
        let app = launch(reset: true, store: "ui-add-slow", extra: ["-MeowverseSyntheticLoadDelay", "8"])
        app.buttons["add-synthetic"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 20))
        sofa.tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        let piece = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(piece.waitForExistence(timeout: 15))
        sleep(1)
        piece.tap()
        XCTAssertTrue(app.buttons["furniture-more"].waitForExistence(timeout: 10))
        app.buttons["furniture-more"].tap()
        let another = app.buttons["再添一张合成照片"]
        XCTAssertTrue(another.waitForExistence(timeout: 5))
        another.tap()
        let progress = element(app, "batch-progress")
        XCTAssertTrue(progress.waitForExistence(timeout: 3), "the page shows the add")
        XCTAssertTrue((progress.value as? String ?? "").contains("iCloud"))
        app.buttons["close-detail"].tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 5))
        XCTAssertTrue(progress.waitForExistence(timeout: 3), "the room shows the add after the page closed")
        waitToVanish(progress, timeout: 30)
        piece.tap()
        XCTAssertTrue(element(app, "furniture-album").waitForExistence(timeout: 20), "the photo arrived in the piece")
    }

    // MARK: Leaving the app during an import

    /// Six photos, each taking 8 s of the app's running time (time suspended does not count),
    /// three at a time; the app is away for 20 s, then the batch is complete with nothing left
    /// out. This does not prove background running: on the iOS 27.2 simulator the
    /// continued-processing request is declined (BGTaskScheduler error 1) and the app was not
    /// suspended within 60 s either, so the import simply keeps going. It guards that a trip away
    /// in the middle of an import leaves it whole. Background running is checked on a phone.
    func testBatchCarriesOnWhileTheAppIsAway() {
        let app = launch(reset: true, store: "ui-batch-away", extra: ["-MeowverseSyntheticBatch", "6", "2",
                                                                       "-MeowverseSyntheticLoadDelay", "8"])
        app.addSyntheticBatch()
        let progress = element(app, "batch-progress")
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertTrue((progress.value as? String ?? "").hasPrefix("0 / 6"), "\(progress.value ?? "")")
        XCUIDevice.shared.press(.home)
        sleep(20)
        app.activate()
        let pending = element(app, "pending-count")
        XCTAssertTrue(pending.waitForExistence(timeout: 20), "the batch finished after the trip away")
        waitForLabel(pending, containing: "6 张照片待整理", timeout: 2)
        XCTAssertFalse(app.alerts["导入照片"].exists, "nothing was left out")
    }

    /// The system ends the background time (or the user stops the import from the system's
    /// progress) while a photo is being added to a piece: the add stops like 「停止导入」, the
    /// page says what was not added, and the piece takes photos again.
    func testAddStoppedByTheSystemSaysWhatIsLeft() {
        let app = launch(reset: true, store: "ui-add-expiry", extra: ["-MeowverseSyntheticLoadDelay", "30",
                                                                       "-MeowverseImportExpiryDrill", "3"])
        app.buttons["add-synthetic"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 20))
        sofa.tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        let piece = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(piece.waitForExistence(timeout: 15))
        sleep(1)
        piece.tap()
        XCTAssertTrue(app.buttons["furniture-more"].waitForExistence(timeout: 10))
        app.buttons["furniture-more"].tap()
        let another = app.buttons["再添一张合成照片"]
        XCTAssertTrue(another.waitForExistence(timeout: 5))
        another.tap()
        XCTAssertTrue(element(app, "adding-progress").waitForExistence(timeout: 3))
        let notice = app.alerts["添加照片"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15), "stopped well before the 30 s photo arrived")
        let text = notice.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        XCTAssertTrue(text.contains("还有 1 张没有处理，可以再选一次。"), text)
        notice.buttons.firstMatch.tap()
        XCTAssertFalse(element(app, "adding-progress").exists, "nothing left running")
        app.buttons["furniture-more"].tap()
        XCTAssertTrue(another.waitForExistence(timeout: 5))
        XCTAssertTrue(another.isEnabled, "the piece takes photos again")
    }

    // MARK: Photos the photo library never hands over

    /// Two of six photos never arrive (a stalled iCloud request). Each gets its time limit and one
    /// longer retry (2 s, then 3 s here); the batch then moves on, stores the other four, and says
    /// the two can be picked again. Nothing hangs.
    func testPhotosThatNeverArriveAreReportedAndTheRestStored() {
        let app = launch(reset: true, store: "ui-batch-stall", extra: ["-MeowverseSyntheticBatch", "6", "2",
                                                                        "-MeowverseSyntheticLoadHangs", "2",
                                                                        "-MeowverseLoadLimits", "2", "3"])
        app.addSyntheticBatch()
        XCTAssertTrue(element(app, "batch-progress").waitForExistence(timeout: 5))
        let notice = app.alerts["导入照片"]
        XCTAssertTrue(notice.waitForExistence(timeout: 40), "the batch finished despite two silent requests")
        let text = notice.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        XCTAssertTrue(text.contains("已导入 4 张。"), text)
        XCTAssertTrue(text.contains("还有 2 张没有导入，可以再选一次。"), text)
        XCTAssertTrue(text.contains("其中 2 张等了很久也没有读到，可能是 iCloud 还没有下载好。"), text)
        XCTAssertFalse(text.contains("读不出来"), "a silent request is not an unreadable photo: \(text)")
        notice.buttons.firstMatch.tap()
        waitForLabel(element(app, "pending-count"), containing: "4 张照片待整理")
        XCTAssertFalse(element(app, "batch-progress").exists)
    }

    /// The third of three photos never arrives and the user stops: the two that arrived are
    /// stored and waiting to be sorted, the bar had counted them, and the notice says one is left.
    func testStoppingKeepsThePhotosThatArrived() {
        let app = launch(reset: true, store: "ui-batch-stop", extra: ["-MeowverseSyntheticBatch", "3", "1",
                                                                       "-MeowverseSyntheticLoadHangs", "1"])
        app.addSyntheticBatch()
        let progress = element(app, "batch-progress")
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        let twoStored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH '2 / 3'"), object: progress)
        XCTAssertEqual(XCTWaiter().wait(for: [twoStored], timeout: 20), .completed,
                       "the bar counts the two stored photos while the third is silent: \(progress.value ?? "")")
        app.buttons["batch-cancel"].tap()
        let notice = app.alerts["导入照片"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        let text = notice.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        XCTAssertTrue(text.contains("已导入 2 张。"), text)
        XCTAssertTrue(text.contains("还有 1 张没有导入，可以再选一次。"), text)
        notice.buttons.firstMatch.tap()
        waitForLabel(element(app, "pending-count"), containing: "2 张照片待整理")
    }

    /// The same for a photo added to one piece: the add ends, says the photo can be picked again,
    /// and the piece takes photos again.
    func testAPhotoThatNeverArrivesDoesNotHoldThePiece() {
        let app = launch(reset: true, store: "ui-add-stall", extra: ["-MeowverseSyntheticLoadHangs", "1",
                                                                      "-MeowverseLoadLimits", "2", "3"])
        app.buttons["add-synthetic"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 20))
        sofa.tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        let piece = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(piece.waitForExistence(timeout: 15))
        sleep(1)
        piece.tap()
        XCTAssertTrue(app.buttons["furniture-more"].waitForExistence(timeout: 10))
        app.buttons["furniture-more"].tap()
        let another = app.buttons["再添一张合成照片"]
        XCTAssertTrue(another.waitForExistence(timeout: 5))
        another.tap()
        XCTAssertTrue(element(app, "adding-progress").waitForExistence(timeout: 3))
        let notice = app.alerts["添加照片"]
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "the add ended despite the silent request")
        let text = notice.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        XCTAssertTrue(text.contains("还有 1 张没有处理，可以再选一次。"), text)
        XCTAssertTrue(text.contains("其中 1 张等了很久也没有读到"), text)
        notice.buttons.firstMatch.tap()
        XCTAssertFalse(element(app, "adding-progress").exists, "nothing left running")
        app.buttons["furniture-more"].tap()
        XCTAssertTrue(another.waitForExistence(timeout: 5))
        XCTAssertTrue(another.isEnabled, "the piece takes photos again")
    }

    /// Sorting starts only once recognition is prepared (owner, round 8): after the import, the
    /// same bar goes on to "识别中" over the batch's prints and the filed photo's, and sorting is
    /// not offered until it is done (offers are worked out only after it, `backfillFinished`).
    /// Then the review compares at once, with no "preparing" state.
    func testSortingWaitsForTheRecognitionPhase() {
        let app = launch(reset: true, store: "ui-prepare", extra: ["-MeowverseSlowPrints", "2",
                                                                    "-MeowverseSuggestionDistances", "0.02", "0.02"])
        app.buttons["add-synthetic"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 20))
        sofa.tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons.matching(sourceButton).firstMatch.waitForExistence(timeout: 15))

        app.addSyntheticBatch()
        let progress = element(app, "batch-progress")
        let recognising = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '正在识别照片'"), object: progress)
        XCTAssertEqual(XCTWaiter().wait(for: [recognising], timeout: 30), .completed, "the bar goes on to the recognition phase")
        snap("P1-recognition-phase")
        // Four prints at 2 s each: the phase lasts several seconds. Look twice inside it.
        for _ in 0..<2 {
            XCTAssertEqual(progress.label, "正在识别照片")
            XCTAssertFalse(app.buttons["start-sorting"].exists, "sorting is not offered while recognition prepares")
            XCTAssertFalse(app.buttons["batch-cancel"].exists, "preparing cannot be skipped")
            sleep(2)
        }
        waitToVanish(progress, timeout: 60)
        let sort = app.buttons["start-sorting"]
        XCTAssertTrue(sort.waitForExistence(timeout: 10), "sorting is offered once prepared")
        sort.tap()
        XCTAssertTrue(app.navigationBars["整理照片 1 / 3"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["similar-0"].waitForExistence(timeout: 10), "the review compares at once: every print is ready")
        XCTAssertFalse(element(app, "recognition-preparing").exists)
    }

    /// Reopening the app with every print already made checks them silently: no 识别中 bar at
    /// all (each print takes 2 s here, so a remade one would show), sorting is offered, and the
    /// report says nothing was made this launch.
    func testRelaunchWithAllPrintsMadeShowsNoRecognitionBar() {
        var app = launch(reset: true, store: "ui-reopen", extra: ["-MeowverseSlowPrints", "2"])
        app.buttons["add-synthetic"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 20))
        sofa.tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons.matching(sourceButton).firstMatch.waitForExistence(timeout: 15))
        app.addSyntheticBatch()
        let recognising = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '正在识别照片'"),
                                                    object: element(app, "batch-progress"))
        XCTAssertEqual(XCTWaiter().wait(for: [recognising], timeout: 30), .completed, "the first launch makes the prints")
        XCTAssertTrue((element(app, "batch-progress").value as? String ?? "").hasSuffix("/ 4"),
                      "the bar counts only the prints to make: \(element(app, "batch-progress").value ?? "")")
        XCTAssertTrue(app.buttons["start-sorting"].waitForExistence(timeout: 60))

        app.terminate()
        app = launch(reset: false, store: "ui-reopen", extra: ["-MeowverseSlowPrints", "2"])
        let progress = element(app, "batch-progress")
        for _ in 0..<12 {
            XCTAssertFalse(progress.exists, "no recognition bar when every print is already made")
            usleep(500_000)
        }
        XCTAssertTrue(app.buttons["start-sorting"].waitForExistence(timeout: 10), "sorting is offered at once")
        openFeedbackDiagnostics(app)
        let diagnostics = app.staticTexts["feedback-diagnostics-text"]
        XCTAssertTrue(diagnostics.label.contains("Since launch: 0 prints made"), diagnostics.label)
    }

    private func openFeedbackDiagnostics(_ app: XCUIApplication) {
        app.buttons["open-settings"].tap()
        reveal(app, "open-feedback").tap()
        reveal(app, "feedback-show-diagnostics").tap()
        XCTAssertTrue(app.staticTexts["feedback-diagnostics-text"].waitForExistence(timeout: 20))
    }

    private func addBatchAndStartSorting(_ app: XCUIApplication, count: Int, progressShot: String? = nil) {
        app.addSyntheticBatch()
        if let progressShot {
            // The bar over the room: label = phase, value = "done / total". The recognition
            // phase also counts the filed photos' prints, so only the import's total is the batch.
            let progress = element(app, "batch-progress")
            if progress.waitForExistence(timeout: 5) {
                XCTAssertTrue(["正在导入照片", "正在识别照片"].contains(progress.label), progress.label)
                if progress.label == "正在导入照片" {
                    XCTAssertTrue((progress.value as? String ?? "").contains(" / \(count)"), "\(progress.value ?? "")")
                }
                snap(progressShot)
            }
        }
        let pending = element(app, "pending-count")
        XCTAssertTrue(pending.waitForExistence(timeout: 60))
        waitForLabel(pending, containing: "\(count) 张照片待整理", timeout: 60)
        // The prints of the batch are made after it is stored; the review can start meanwhile,
        // but the tests start once the progress bar has gone, so the counts are settled.
        waitToVanish(element(app, "batch-progress"), timeout: 60)
        app.buttons["start-sorting"].tap()
    }

    // MARK: A small batch

    /// The strip counts the offers, the page files the ticked ones and never offers the unticked
    /// one again, 撤销 takes it back, and the provenance mark shows only on the suggested photo.
    func testSmallBatchStripConfirmUndoAndProvenance() {
        let app = launch(reset: true, store: "suggest-small")
        sofaWithTwoPhotos(app)
        addBatchAndStartSorting(app, count: 3)
        XCTAssertTrue(app.navigationBars["整理照片 1 / 3"].waitForExistence(timeout: 20))

        // The other two photos look like the sofa's; the one on screen is never on the page.
        let strip = app.buttons["filing-suggestions-entry"]
        XCTAssertTrue(strip.waitForExistence(timeout: 20))
        waitForLabel(strip, containing: "按建议放进家具，2 张")
        // The look-alike rows' footnote already says it may be wrong; the strip does not repeat it.
        waitForLabel(strip, containing: "本机比对，由你确认")
        XCTAssertFalse(app.buttons["representative-round-strip"].exists, "under 12 photos there is no round")
        sleep(1); snap("F1-review-with-strip")
        strip.tap()
        XCTAssertTrue(app.navigationBars["按建议放进家具"].waitForExistence(timeout: 10))
        XCTAssertEqual(tiles(app).count, 2)
        let confirm = app.buttons["confirm-suggestions"]
        waitForLabel(confirm, containing: "放进所选的 2 张")
        sleep(1); snap("F2-confirmation-page")

        // Untick one: it stays to be sorted by hand and is not offered again.
        tiles(app).element(boundBy: 1).tap()
        waitForLabel(confirm, containing: "放进所选的 1 张")
        confirm.tap()
        let notice = element(app, "suggested-filing-notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(noticeText(app, "已把 1 张照片放进「").exists)
        XCTAssertTrue(app.navigationBars["整理照片 1 / 2"].waitForExistence(timeout: 10), "the filed photo left the queue")
        sleep(1); snap("F3-filed-notice")

        app.buttons["undo-suggested-filing"].tap()
        waitToVanish(notice, timeout: 10)
        XCTAssertTrue(app.navigationBars["整理照片 1 / 3"].waitForExistence(timeout: 10), "back in the queue")
        waitForLabel(strip, containing: "按建议放进家具，1 张")

        strip.tap()
        XCTAssertTrue(app.navigationBars["按建议放进家具"].waitForExistence(timeout: 10))
        XCTAssertEqual(tiles(app).count, 1, "the unticked photo is not offered again")
        confirm.tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        waitForLabel(strip, containing: "按建议放进家具，暂无。")

        // The photo on screen goes into the sofa by hand; the declined one is kept in the library.
        let similar = app.buttons["similar-0"]
        XCTAssertTrue(similar.waitForExistence(timeout: 20))
        similar.tap()
        XCTAssertTrue(app.navigationBars["整理照片 2 / 2"].waitForExistence(timeout: 20))
        reveal(app, "keep-in-library").tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 20))
        sleep(2)
        XCTAssertFalse(element(app, "pending-count").exists, "nothing left to sort")

        // Sofa: the room photo, the added one, the suggested one, the one filed by hand.
        app.buttons.matching(sourceButton).firstMatch.tap()
        let album = app.buttons.matching(identifier: "album-photo")
        XCTAssertTrue(album.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(album.count, 4)
        album.element(boundBy: 2).tap()
        let caption = element(app, "photo-caption")
        XCTAssertTrue(caption.waitForExistence(timeout: 10))
        XCTAssertTrue(caption.label.contains("按相像的照片建议放入，由你确认"), caption.label)
        sleep(1); snap("F4-provenance-mark")
        app.swipeLeft()
        sleep(1)
        XCTAssertFalse(element(app, "photo-caption").label.contains("按相像的照片建议放入"), element(app, "photo-caption").label)
        XCTAssertTrue(element(app, "photo-caption").label.contains("由你手动选择"), element(app, "photo-caption").label)
    }

    // MARK: A big batch

    /// The first whole number after `prefix` in `label` (the counts use a no-break space).
    private func count(in label: String, after prefix: String) -> Int? {
        guard let start = label.range(of: prefix)?.upperBound else { return nil }
        return Int(label[start...].prefix { $0.isNumber })
    }

    /// The count once it has stopped changing for two seconds (comparing may still add some).
    private func settledCount(_ element: XCUIElement, after prefix: String) -> Int {
        var last = count(in: element.label, after: prefix)
        for _ in 0..<10 {
            sleep(2)
            let now = count(in: element.label, after: prefix)
            if now == last, now != nil { break }
            last = now
        }
        return last ?? -1
    }

    private func bigBatchLaunch(_ store: String) -> XCUIApplication {
        // Three scenes of four photos. On the colour grid the shipped DINOv2 cut (0.6) would
        // join every scene, so the cut and the radius are set on its scale; three representatives
        // instead of ten keep the round short.
        launch(reset: true, store: store, extra: ["-MeowverseSyntheticBatch", "12", "3",
                                                  "-MeowverseSuggestionDistances", "0.02", "0.02",
                                                  "-MeowverseRepresentativeRound", "3"])
    }

    /// Intro, the round counted in the strip, the end page, the confirmation page from it, and
    /// the review going on in the picked order.
    func testBigBatchRepresentativeRound() {
        let app = bigBatchLaunch("suggest-round")
        addBatchAndStartSorting(app, count: 12, progressShot: "Q1-batch-progress")
        let start = app.buttons["start-representative-round"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), "12 photos with prints: the round is introduced")
        XCTAssertTrue(app.staticTexts["先整理 3\u{00A0}张代表照片"].exists)
        XCTAssertTrue(app.navigationBars["整理照片"].exists, "no queue count on the intro")
        XCTAssertTrue(app.buttons["skip-representative-round"].exists)
        sleep(1); snap("R1-round-intro")
        start.tap()

        let strip = app.buttons["representative-round-strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 20))
        waitForLabel(strip, containing: "第 1 张，共 3 张")
        XCTAssertTrue(app.navigationBars["整理照片 1 / 12"].exists)
        sleep(1); snap("R2-round-first")
        // First representative: a new sofa.
        app.buttons["manual-sofa"].tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()

        // Second (another scene): into the same sofa, so two scenes now have a piece.
        XCTAssertTrue(app.navigationBars["整理照片 2 / 12"].waitForExistence(timeout: 20))
        waitForLabel(strip, containing: "第 2 张，共 3 张")
        reveal(app, "attach-existing").tap()
        XCTAssertTrue(app.buttons["attach-0"].waitForExistence(timeout: 10))
        app.buttons["attach-0"].tap()

        // Third (the scene nothing looks like yet): kept in the library.
        XCTAssertTrue(app.navigationBars["整理照片 3 / 12"].waitForExistence(timeout: 20))
        waitForLabel(strip, containing: "第 3 张，共 3 张")
        waitForLabel(strip, containing: "已可建议")
        let atLast = settledCount(strip, after: "已可建议 ")
        XCTAssertGreaterThan(atLast, 0, strip.label)
        sleep(1); snap("R3-round-strip-with-count")
        reveal(app, "keep-in-library").tap()

        // The round is over: the photos like the first two can be filed from the page.
        let review = app.buttons["open-suggestion-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 20), "the end page")
        XCTAssertTrue(app.buttons["skip-suggestion-review"].exists)
        XCTAssertTrue(review.label.contains("查看建议的"), review.label)
        // The same offers on the strip, the end page and the confirmation page: the photo opened
        // beneath the end page is one that is not offered (photos of the third scene remain).
        XCTAssertEqual(count(in: review.label, after: "查看建议的 "), atLast, review.label)
        XCTAssertTrue(app.navigationBars["整理照片"].exists, "no queue count on the end page")
        sleep(1); snap("R4-round-end")
        review.tap()
        XCTAssertTrue(app.navigationBars["按建议放进家具"].waitForExistence(timeout: 10))
        XCTAssertEqual(tiles(app).count, atLast)
        app.buttons["dismiss-suggestions"].tap()

        // Back to the remaining photos, in the order they were picked, with the offers on the strip.
        XCTAssertTrue(app.navigationBars["整理照片 4 / 12"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["filing-suggestions-entry"].waitForExistence(timeout: 10))
        waitForLabel(app.buttons["filing-suggestions-entry"], containing: "按建议放进家具，\(atLast) 张")
        XCTAssertFalse(strip.exists, "the round is over")
    }

    /// "不用，按原来的顺序整理": no round, the first picked photo first, and no intro again.
    func testBigBatchRoundCanBeSkipped() {
        let app = bigBatchLaunch("suggest-skip")
        addBatchAndStartSorting(app, count: 12)
        let skip = app.buttons["skip-representative-round"]
        XCTAssertTrue(skip.waitForExistence(timeout: 20))
        skip.tap()
        XCTAssertTrue(app.navigationBars["整理照片 1 / 12"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["manual-sofa"].waitForExistence(timeout: 20), "the ordinary review")
        XCTAssertFalse(app.buttons["representative-round-strip"].exists)
        reveal(app, "keep-in-library").tap()
        XCTAssertTrue(app.navigationBars["整理照片 2 / 12"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["start-representative-round"].exists, "skipped for this batch")
        XCTAssertFalse(app.buttons["representative-round-strip"].exists)
    }

    // MARK: Relaunch

    /// Stopping half-way and quitting: the declined photo stays declined, and the offers come
    /// back when the review opens and from the library's 未放进家具 list.
    func testRelaunchKeepsDeclinesAndBringsOffersBack() {
        var app = launch(reset: true, store: "suggest-relaunch")
        sofaWithTwoPhotos(app)
        addBatchAndStartSorting(app, count: 3)
        let strip = app.buttons["filing-suggestions-entry"]
        XCTAssertTrue(strip.waitForExistence(timeout: 20))
        waitForLabel(strip, containing: "按建议放进家具，2 张")
        strip.tap()
        XCTAssertTrue(app.navigationBars["按建议放进家具"].waitForExistence(timeout: 10))
        tiles(app).element(boundBy: 1).tap()
        app.buttons["confirm-suggestions"].tap()
        XCTAssertTrue(element(app, "suggested-filing-notice").waitForExistence(timeout: 10))
        tapSortingToolbarButton("stop-sorting", in: app)
        waitForLabel(element(app, "pending-count"), containing: "2 张照片待整理")

        app.terminate()
        app = launch(reset: false, store: "suggest-relaunch")
        let pending = element(app, "pending-count")
        XCTAssertTrue(pending.waitForExistence(timeout: 20))
        waitForLabel(pending, containing: "2 张照片待整理")
        app.buttons["start-sorting"].tap()
        XCTAssertTrue(app.navigationBars["整理照片 1 / 2"].waitForExistence(timeout: 20))
        // The review works the offers out again: the other photo was declined, so none.
        XCTAssertTrue(strip.waitForExistence(timeout: 20), "the strip comes back after a relaunch")
        waitForLabel(strip, containing: "按建议放进家具，暂无。")
        tapSortingToolbarButton("stop-sorting", in: app)

        // From the library: the photo that was on screen is offered; the declined one is not.
        XCTAssertTrue(app.buttons["photo-library"].waitForExistence(timeout: 10))
        app.buttons["photo-library"].tap()
        XCTAssertTrue(app.buttons["filter-unlinked"].waitForExistence(timeout: 10))
        app.buttons["filter-unlinked"].tap()
        let rerun = app.buttons["rerun-suggestions"]
        XCTAssertTrue(rerun.waitForExistence(timeout: 10))
        sleep(1); snap("L1-library-rerun-entry")
        rerun.tap()
        XCTAssertTrue(app.navigationBars["按建议放进家具"].waitForExistence(timeout: 20))
        XCTAssertEqual(tiles(app).count, 1)
        app.buttons["dismiss-suggestions"].tap()
    }

    // MARK: Photo board

    /// A photo put on the board for want of a piece is offered to the sofa it looks like; the
    /// board is never the target, and the notice can take it back.
    func testPhotoBoardRerunOffersItsPhotosAPiece() {
        let app = launch(reset: true, store: "suggest-board")
        sofaWithTwoPhotos(app)
        addBatchAndStartSorting(app, count: 3)
        XCTAssertTrue(app.navigationBars["整理照片 1 / 3"].waitForExistence(timeout: 20))
        // "未识别": no board yet, so one is placed for this photo.
        reveal(app, "similar-none").tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.navigationBars["整理照片 2 / 3"].waitForExistence(timeout: 20))
        tapSortingToolbarButton("stop-sorting", in: app)

        let board = app.buttons.matching(NSPredicate(format: "label CONTAINS '查看照片' AND NOT (label CONTAINS '沙发')")).firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        board.tap()
        let rerun = app.buttons["rerun-suggestions"]
        XCTAssertTrue(rerun.waitForExistence(timeout: 10))
        sleep(1); snap("P1-board-rerun-entry")
        rerun.tap()
        XCTAssertTrue(app.navigationBars["按建议放进家具"].waitForExistence(timeout: 20))
        XCTAssertEqual(tiles(app).count, 1)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'suggestion-group-' AND NOT (identifier BEGINSWITH 'suggestion-group-toggle-')")).count, 1)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '沙发'")).firstMatch.exists, "offered to the sofa")
        app.buttons["confirm-suggestions"].tap()
        let notice = element(app, "suggested-filing-notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(noticeText(app, "已把 1 张照片从照片板移到「").exists, "the photo moved off the board")
        XCTAssertTrue(element(app, "furniture-no-photos").waitForExistence(timeout: 10), "the photo left the board")
        XCTAssertFalse(rerun.exists, "nothing left on the board to suggest")
        sleep(1); snap("P2-board-after-filing")

        // 撤销 puts it back on the board.
        app.buttons["undo-suggested-filing"].tap()
        waitToVanish(notice, timeout: 10)
        XCTAssertFalse(element(app, "furniture-no-photos").exists)
    }
}
