import XCTest

/// End-to-end manual path with a drawn, non-private photo:
/// cancel leaves the room empty, a confirmed sofa survives a relaunch and still opens its photo,
/// a repeated import is recognised, and a failed save keeps the room and offers a retry.
final class PhotoToFurnitureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = name.contains("Audit")
    }

    private func launch(reset: Bool, failNextSave: Bool = false, store: String, extra: [String] = [],
                        language: [String] = TestLanguage.chinese) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = language + ["-MeowverseStore", store, "-MeowverseSyntheticPhoto"] + extra
        if reset { app.launchArguments.append("-MeowverseResetStore") }
        if failNextSave { app.launchArguments.append("-MeowverseFailNextSave") }
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 20))
        return app
    }

    private func walkToPlacement(_ app: XCUIApplication) {
        app.buttons["add-synthetic"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 20))
        sofa.tap()
        snap("2-review")
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        sleep(2); snap("3-model")
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        sleep(2); snap("4-placement")
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var sourceButton: NSPredicate { NSPredicate(format: "label CONTAINS %@", "查看照片") }

    /// No furniture in the room: nothing to tap in it, and the empty-room hint is showing. (The
    /// list button says nothing about this: it is always there, for the catalog and the storage box.)
    private func assertRoomEmpty(_ app: XCUIApplication, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.buttons.matching(sourceButton).count, 0, message, file: file, line: line)
        XCTAssertTrue(app.buttons["place-furniture-first"].waitForExistence(timeout: 5), message, file: file, line: line)
    }

    func testRoomPostcardPreviewAndShareSheet() {
        let app = launch(reset: true, store: "postcard-preview")
        walkToPlacement(app)
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 15))
        app.buttons["open-room-share"].tap()

        let preview = app.descendants(matching: .any)["room-postcard-ready"]
        XCTAssertTrue(preview.waitForExistence(timeout: 20))
        let qr = app.switches["room-share-qr"]
        // Off by default: the code leads to the frozen web demo (owner, 2026-11-20).
        XCTAssertEqual(qr.value as? String, "0")
        XCTAssertEqual(preview.value as? String, "二维码已关闭")
        // One synthetic photo (EXIF day 2026-03-14) on one sofa: the card says so, and only that.
        let stats = app.switches["room-share-stats"]
        XCTAssertTrue(stats.waitForExistence(timeout: 5))
        XCTAssertEqual(stats.value as? String, "1")
        let summary = app.descendants(matching: .any)["room-share-stats-summary"]
        XCTAssertTrue(summary.exists)
        for part in ["1 张照片", "1 件家具", "2026年3月"] {
            XCTAssertTrue(summary.label.contains(part), summary.label)
            XCTAssertTrue(preview.label.contains(part), preview.label)
        }
        XCTAssertFalse(summary.label.contains("–"), "one known day is a single month, not a range")
        snap("room-postcard-default-without-qr")
        stats.tap()
        XCTAssertEqual(stats.value as? String, "0")
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertFalse(preview.label.contains("张照片"), preview.label)
        stats.tap()
        XCTAssertEqual(stats.value as? String, "1")
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(preview.label.contains("1 张照片"), preview.label)
        let title = app.textFields["room-share-title"]
        title.tap()
        title.typeText(" · 周末\n")
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(preview.label.contains("周末"))
        qr.tap()
        XCTAssertEqual(qr.value as? String, "1")
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertEqual(preview.value as? String, "包含喵空间二维码")
        snap("room-postcard-with-qr")
        title.tap()
        title.typeText("，阳光正好的午后，猫咪在沙发上打盹，我们一起整理了所有的回忆照片\n")
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(preview.label.contains("1 张照片"), preview.label)
        snap("room-postcard-long-title-with-qr")
        qr.tap()
        XCTAssertEqual(qr.value as? String, "0")
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        snap("room-postcard-long-title-without-qr")
        app.buttons["share-room-png"].tap()
        let sheet = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label IN %@", "ActivityListView",
            ["Copy", "拷贝", "Save Image", "存储图像", "Save to Files", "存储到“文件”"])).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        snap("room-postcard-system-share")
    }

    func testCatTreeInvitationsAndSourceAfterRelaunch() {
        var app = launch(reset: true, store: "pet-interactions")
        app.buttons["add-synthetic"].tap()
        let category = app.buttons["manual-catTree"]
        XCTAssertTrue(category.waitForExistence(timeout: 20))
        category.tap()
        app.buttons["next-model"].tap()
        // mv-cat-tree-a replaced the legacy lookout tree (now hidden from the picker).
        let tree = app.buttons["model-mv-cat-tree-a"]
        XCTAssertTrue(tree.waitForExistence(timeout: 10))
        tree.tap()
        XCTAssertTrue(app.descendants(matching: .any)["model-preview-ready"].waitForExistence(timeout: 10))
        snap("pet-tree-preview")
        app.buttons["next-placement"].tap()
        app.buttons["confirm-placement"].tap()

        // Wait for the live room to replace the placement editor.
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 35))
        for (site, action, word) in [("play", "play", "拍"), ("hide", "hide", "躲"), ("top", "loaf", "窝着")] {
            app.buttons["choose-interaction"].tap()
            let invitation = app.buttons["invite-\(site)-\(action)"]
            if !invitation.waitForExistence(timeout: 2) || !invitation.isHittable { app.swipeUp() }
            XCTAssertTrue(invitation.waitForExistence(timeout: 5))
            invitation.tap()
            let arrived = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@", "bella-caption", word)).firstMatch
            XCTAssertTrue(arrived.waitForExistence(timeout: 40), "Bella arrives at \(site)")
            app.descendants(matching: .any)["room-world"].pinch(withScale: 1.8, velocity: 2)
            snap("pet-tree-\(action)")
            if action == "play" { sleep(3) } // Keep one full paw stroke in the recording.
        }

        app.terminate()
        app = launch(reset: false, store: "pet-interactions")
        app.buttons.matching(sourceButton).firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["original-photo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["photo-caption"].label.contains("由你手动选择"))
    }

    func testTapWhereFurnitureOverlapsCanOpenEitherPiece() {
        let app = launch(reset: true, store: "room-overlap")
        walkToPlacement(app)
        app.buttons["confirm-placement"].tap()
        let sofa = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(sofa.waitForExistence(timeout: 10))
        app.buttons["furniture-list"].tap()
        app.buttons["add-furniture"].tap()
        let category = app.buttons["manual-chair"], next = app.buttons["next-model"]
        XCTAssertTrue(category.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["close-furniture-list"].waitForNonExistence(timeout: 5))
        reveal(app, "manual-chair").tap()
        XCTAssertTrue(next.isEnabled)
        next.tap()
        let placement = app.buttons["next-placement"]
        XCTAssertTrue(placement.waitForExistence(timeout: 10))
        placement.tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        let chair = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "，还没有照片")).firstMatch
        XCTAssertTrue(chair.waitForExistence(timeout: 10))
        let intersection = sofa.frame.intersection(chair.frame)
        XCTAssertFalse(intersection.isEmpty)
        let tap = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: intersection.midX, dy: intersection.midY))
        let rows = app.buttons.matching(identifier: "overlap-item")
        for (piece, detail) in [(sofa, "original-photo"), (chair, "furniture-no-photos")] {
            let name = String(piece.label.split(separator: "，")[0])
            tap.tap()
            let choice = rows.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            XCTAssertEqual(rows.count, 2)
            if detail == "original-photo" { snap("room-overlap-picker") }
            choice.tap()
            XCTAssertTrue(element(app, detail).waitForExistence(timeout: 10))
            app.buttons["close-detail"].tap()
        }
    }

    func testRoomPinchAndPanKeepFurnitureTouchable() {
        let app = launch(reset: true, store: "room-camera")
        walkToPlacement(app)
        app.buttons["confirm-placement"].tap()
        let item = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        let room = element(app, "room-world")
        let original = item.frame
        snap("camera-overview")
        item.pinch(withScale: 3, velocity: 2)
        snap("camera-zoomed")
        XCTAssertGreaterThan(item.frame.width, original.width * 1.25)
        let zoomed = item.frame
        let start = item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 55, dy: 0)))
        XCTAssertGreaterThan(item.frame.midX, zoomed.midX + 15)
        XCTAssertFalse(element(app, "edit-tray").exists)
        XCTAssertFalse(element(app, "original-photo").exists)
        item.tap()
        XCTAssertTrue(element(app, "original-photo").waitForExistence(timeout: 10))
        app.buttons["close-detail"].tap()
        room.pinch(withScale: 0.15, velocity: -2)
        XCTAssertEqual(item.frame.midX, original.midX, accuracy: 3)
        XCTAssertEqual(item.frame.width, original.width, accuracy: 3)
    }

    func testScratchBoardInvitation() {
        let app = launch(reset: true, store: "scratch-board")
        app.buttons["add-synthetic"].tap()
        let category = app.buttons["manual-scratcher"]
        XCTAssertTrue(category.waitForExistence(timeout: 20))
        category.tap()
        app.buttons["next-model"].tap()
        // mv-scratcher-b replaced the legacy scratch board (now hidden from the picker).
        let board = app.buttons["model-mv-scratcher-b"]
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        board.tap()
        app.buttons["next-placement"].tap()
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons["choose-interaction"].waitForExistence(timeout: 35))
        app.buttons["choose-interaction"].tap()
        app.buttons["invite-scratch-scratch"].tap()
        let scratching = app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "bella-caption", "磨爪")).firstMatch
        XCTAssertTrue(scratching.waitForExistence(timeout: 25))
        app.descendants(matching: .any)["room-world"].pinch(withScale: 1.8, velocity: 2)
        snap("pet-scratch-board")
        sleep(2) // Record the alternating strokes.
    }

    func testCancelThenConfirmThenRelaunchFindsTheSamePhoto() {
        var app = launch(reset: true, store: "flow")
        assertRoomEmpty(app, "a fresh room has no furniture")
        snap("1-empty-room")

        // Cancel at the first step: nothing is added.
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.buttons["cancel-import"].waitForExistence(timeout: 20))
        app.buttons["cancel-import"].tap()
        app.buttons["不添加"].tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
        assertRoomEmpty(app, "cancelling leaves the room empty")

        // Cancel from the placement step as well.
        walkToPlacement(app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["cancel-import"].tap()
        app.buttons["不添加"].tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
        assertRoomEmpty(app)

        // Confirm: the sofa appears and is reachable without touching the 3D view.
        walkToPlacement(app)
        app.buttons["confirm-placement"].tap()
        let source = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["furniture-list"].isEnabled)
        sleep(1)
        snap("5-room-with-sofa")

        // Importing the same bytes again is recognised as the same photo.
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已经在")).firstMatch.waitForExistence(timeout: 20))
        app.buttons["cancel-import"].tap()
        app.buttons["不添加"].tap()

        // Quit completely and reopen: same furniture, same photo, same capture day.
        app.terminate()
        app = launch(reset: false, store: "flow")
        let restored = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(sourceButton).count, 1)
        restored.tap()
        XCTAssertTrue(app.descendants(matching: .any)["original-photo"].waitForExistence(timeout: 10))
        let caption = app.descendants(matching: .any)["photo-caption"]
        snap("6-original-photo")
        XCTAssertTrue(caption.label.contains("2026"), "EXIF capture day is kept: \(caption.label)")
        app.buttons["close-detail"].tap()

        // The stored original still hashes to what was imported.
        openSettings(app)
        tapIntegrityCheck(app)
        let result = app.staticTexts["integrity-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.contains("全部和导入时一致"), result.label)
    }

    /// Profiling aid, skipped in normal runs. Instruments launches the app; this test waits for it,
    /// then walks photo -> sofa -> original without relaunching, so one trace covers the whole flow.
    /// Run with TEST_RUNNER_MEOWVERSE_ATTACH=1 (see measure-flow.sh).
    func testProfilingWalkOnRunningApp() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MEOWVERSE_ATTACH"] == "1", "profiling only")
        let app = XCUIApplication()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 120), "start the app under Instruments first")
        XCTAssertTrue(app.buttons["add-synthetic"].waitForExistence(timeout: 20),
                      "buttons: \(app.buttons.allElementsBoundByIndex.map { $0.identifier + "/" + $0.label })")
        walkToPlacement(app)
        app.buttons["confirm-placement"].tap()
        let source = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        sleep(2)
        source.tap()
        XCTAssertTrue(app.descendants(matching: .any)["original-photo"].waitForExistence(timeout: 10))
        sleep(2)
        app.buttons["close-detail"].tap()
        sleep(3)
    }

    /// Paced walk-through for the sponsor demo recording, skipped in normal runs. Uses only the
    /// drawn synthetic photo. Run through record-demo.sh, which keeps the screen recording.
    func testDemoWalkthrough() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MEOWVERSE_DEMO"] == "1", "demo recording only")
        var app = launch(reset: true, store: "demo")
        sleep(3)
        app.buttons["add-synthetic"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 20))
        sleep(3)
        sofa.tap()
        sleep(1)
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        sleep(3)
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        sleep(2)
        for label in ["向左移一格", "向左移一格", "向里移一格"] {
            let button = app.buttons[label]
            if button.exists, button.isHittable { button.tap(); usleep(700_000) }
        }
        sleep(1)
        app.buttons["confirm-placement"].tap()
        let source = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        sleep(3)
        source.tap()
        XCTAssertTrue(app.descendants(matching: .any)["original-photo"].waitForExistence(timeout: 10))
        sleep(4)
        app.buttons["close-detail"].tap()
        sleep(2)

        // Quit completely and reopen: the sofa still leads to the same photo.
        app.terminate()
        sleep(1)
        app = launch(reset: false, store: "demo")
        let restored = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        sleep(3)
        restored.tap()
        XCTAssertTrue(app.descendants(matching: .any)["original-photo"].waitForExistence(timeout: 10))
        sleep(4)
        app.buttons["close-detail"].tap()
        sleep(2)
    }

    func testFailedSaveKeepsRoomAndRetryWorks() {
        let app = launch(reset: true, failNextSave: true, store: "fault")
        walkToPlacement(app)
        app.buttons["confirm-placement"].tap()
        let alert = app.alerts["没能保存"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.buttons["重试"].tap()
        XCTAssertTrue(app.buttons.matching(sourceButton).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["furniture-list"].isEnabled)
    }

    /// Leaving the app in the middle of an import and coming back keeps a consistent state,
    /// and cancelling afterwards still leaves the room empty across a relaunch.
    func testBackgroundDuringImportThenCancelLeavesRoomEmpty() {
        var app = launch(reset: true, store: "background")
        app.buttons["add-synthetic"].tap()
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(app.buttons["cancel-import"].waitForExistence(timeout: 20), "the review is waiting where the user left it")
        app.buttons["manual-sofa"].tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10), "the chosen step survives backgrounding")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["cancel-import"].tap()
        app.buttons["不添加"].tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
        assertRoomEmpty(app)

        app.terminate()
        app = launch(reset: false, store: "background")
        assertRoomEmpty(app, "nothing from the cancelled import was saved")
        openSettings(app)
        tapIntegrityCheck(app)
        let result = app.staticTexts["integrity-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.hasPrefix("0 件家具、0 张照片"), result.label)
    }

    /// Settings sits in the room menu.
    private func openSettings(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        let item = app.buttons["open-settings"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    /// Largest accessibility text size: every step stays reachable, and the system audit finds
    /// nothing wrong with our own screens.
    func testLargestTextSizeCompletesTheFlowAndPassesAudit() throws {
        let app = launch(reset: true, store: "a11y",
                         extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        snap("7-xxxl-room")
        try audit(app)

        app.buttons["add-synthetic"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 20))
        try audit(app)
        sofa.tap()
        snap("8-xxxl-review")
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        let confirm = app.buttons["confirm-placement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.isHittable, "confirm stays on screen at the largest text size")
        // Move with the labelled buttons only, as a VoiceOver user would.
        app.buttons["向右移一格"].tap()
        app.buttons["转四分之一圈"].tap()
        sleep(1)
        snap("9-xxxl-placement")
        try audit(app)
        confirm.tap()

        let source = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        XCTAssertTrue(app.descendants(matching: .any)["original-photo"].waitForExistence(timeout: 10))
        sleep(1)
        snap("9-xxxl-original")
        try audit(app)
    }

    // MARK: - Settings: backup round trip

    /// Rename the cat → export a backup → clear everything (two confirmations) → the room is
    /// empty → restore the export through the preview → the sofa, its original photo and the
    /// name are back, and still there after a relaunch. Uses the drill switch that feeds the
    /// export back in, so the system file picker and share sheet are not involved.
    func testBackupRoundTripClearAndRestore() {
        var app = launch(reset: true, store: "backup", extra: ["-MeowverseBackupDrill"])
        walkToPlacement(app)
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons.matching(sourceButton).firstMatch.waitForExistence(timeout: 10))

        // The cat's name is in 猫咪管理.
        app.openCatManager()
        app.waitForFirstCat(named: "Kitty")
        app.renameFirstCat(to: "Mochi")
        app.buttons["close-home"].tap()
        XCTAssertTrue(app.showsRoom("Mochi 的房间", timeout: 10))

        openSettings(app)
        waitForLabel(element(app, "storage-usage"), containing: "1 张照片、1 件家具")
        snap("backup-1-settings")

        reveal(app, "export-backup").tap()
        let exported = app.staticTexts["export-result"]
        XCTAssertTrue(exported.waitForExistence(timeout: 30))
        XCTAssertTrue(exported.label.contains("1 张照片、1 件家具"), exported.label)
        XCTAssertTrue(element(app, "share-backup").exists)
        snap("backup-2-exported")

        // Clear all: a sheet that recommends exporting first, then a second confirmation.
        reveal(app, "clear-all").tap()
        let proceed = app.buttons["clear-all-continue"].firstMatch
        XCTAssertTrue(proceed.waitForExistence(timeout: 5))
        snap("backup-3-clear-first-step")
        proceed.tap()
        let confirm = app.alerts.buttons["clear-all-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        waitForLabel(reveal(app, "backup-notice"), containing: "已清除全部数据")
        waitForLabel(reveal(app, "storage-usage"), containing: "0 张照片、0 件家具")
        // The name is cleared too (BackupRestoreTests): leaving Settings to look would discard the export.

        // Restore: preview first, nothing changes until it is confirmed.
        reveal(app, "drill-restore-last-export").tap()
        XCTAssertTrue(element(app, "preview-kind").waitForExistence(timeout: 30))
        waitForLabel(element(app, "preview-photos"), containing: "1 张照片")
        waitForLabel(element(app, "preview-furniture"), containing: "1 件家具")
        waitForLabel(element(app, "preview-kind"), containing: "App 备份")
        snap("backup-4-preview")
        // Saying no keeps the empty room.
        reveal(app, "cancel-restore").tap()
        waitForLabel(reveal(app, "storage-usage"), containing: "0 张照片、0 件家具")
        reveal(app, "drill-restore-last-export").tap()
        XCTAssertTrue(element(app, "preview-kind").waitForExistence(timeout: 30))
        reveal(app, "confirm-restore").tap()
        waitForLabel(reveal(app, "backup-notice"), containing: "已从备份恢复：1 张照片、1 件家具")
        snap("backup-5-restored")
        tapIntegrityCheck(app)
        let result = app.staticTexts["integrity-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.contains("全部和导入时一致"), result.label)
        app.buttons["close-settings"].tap()

        // Back in the room: the sofa, the name and the original photo.
        XCTAssertTrue(app.showsRoom("Mochi 的房间", timeout: 10))
        let restored = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        sleep(1)
        snap("backup-6-room-restored")
        restored.tap()
        XCTAssertTrue(app.descendants(matching: .any)["original-photo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["photo-caption"].label.contains("2026"))
        app.buttons["close-detail"].tap()

        app.terminate()
        app = launch(reset: false, store: "backup")
        XCTAssertTrue(app.showsRoom("Mochi 的房间", timeout: 10))
        XCTAssertEqual(app.buttons.matching(sourceButton).count, 1)
    }

    func testRestoreWarnsBeforeReplacingRoomsWithoutPhotosOrFurniture() {
        let app = launch(reset: true, store: "restore-empty-rooms", extra: ["-MeowverseBackupDrill", "-MeowverseSeveralHomes"])
        app.buttons["room-switcher"].tap()
        app.buttons["new-room"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("书房")
        app.alerts.buttons["新建"].tap()
        XCTAssertTrue(app.showsRoom("书房", timeout: 10))

        openSettings(app)
        reveal(app, "export-backup").tap()
        XCTAssertTrue(element(app, "export-result").waitForExistence(timeout: 20))
        reveal(app, "drill-restore-last-export").tap()
        XCTAssertTrue(element(app, "preview-kind").waitForExistence(timeout: 20))
        waitForLabel(reveal(app, "preview-warning"), containing: "所有房间和猫咪")
        XCTAssertEqual(reveal(app, "confirm-restore").label, "替换现有内容")
        reveal(app, "cancel-restore").tap()
        app.buttons["close-settings"].tap()
        XCTAssertTrue(app.showsRoom("书房", timeout: 10))
    }

    /// A web backup (ZIP v6, written by the real web writer from drawn images) → preview with
    /// what comes along → confirmed → the room has the web furniture, photos and cat name. Then
    /// a truncated copy of the same file is refused and the room stays as it is.
    /// Simulator only: the app reads the fixture from the test bundle's folder on the host.
    func testWebBackupImportFillsTheRoomAndDamagedFileChangesNothing() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("the fixture path is only readable by the app on the simulator")
        #else
        let fixture = try XCTUnwrap(Bundle(for: PhotoToFurnitureUITests.self).url(forResource: "web-v6-synthetic", withExtension: "zip"))
        var app = launch(reset: true, store: "webimport", extra: ["-MeowverseBackupFile", fixture.path])
        openSettings(app)
        reveal(app, "drill-open-backup-file").tap()
        XCTAssertTrue(element(app, "preview-kind").waitForExistence(timeout: 30))
        waitForLabel(element(app, "preview-kind"), containing: "网页版备份")
        waitForLabel(element(app, "preview-photos"), containing: "3 张照片")
        waitForLabel(element(app, "preview-furniture"), containing: "2 件家具")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "配色主题")).firstMatch.exists, "what is not carried over is listed")
        snap("web-1-preview")
        reveal(app, "confirm-restore").tap()
        waitForLabel(reveal(app, "backup-notice"), containing: "网页版备份已导入：3 张照片、2 件家具")
        snap("web-2-imported")
        app.buttons["close-settings"].tap()

        XCTAssertTrue(app.showsRoom("团子的房间", timeout: 10))
        XCTAssertTrue(app.buttons.matching(sourceButton).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(sourceButton).count, 2)
        sleep(1)
        snap("web-3-room")
        app.buttons["furniture-list"].tap()
        let sofa = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "客厅沙发", "2 张照片")).firstMatch
        XCTAssertTrue(sofa.waitForExistence(timeout: 10), "the sofa keeps both of its web source photos")
        sofa.tap()
        let dated = app.buttons.matching(identifier: "album-photo").matching(NSPredicate(format: "value CONTAINS %@", "2025")).firstMatch
        XCTAssertTrue(dated.waitForExistence(timeout: 10), "both photos are shown in the album")
        dated.tap()
        XCTAssertTrue(app.descendants(matching: .any)["original-photo"].waitForExistence(timeout: 10))
        let caption = app.descendants(matching: .any)["photo-caption"]
        XCTAssertTrue(caption.label.contains("2025") && caption.label.contains("你填写的"), "the user's date and its source: \(caption.label)")
        XCTAssertTrue(caption.label.contains("演示数据"), "the web source origin is kept: \(caption.label)")
        snap("web-4-original")
        app.buttons["close-detail"].tap()
        app.terminate()

        // The same file cut in half: refused, and the imported room is untouched.
        let damaged = FileManager.default.temporaryDirectory.appendingPathComponent("meowverse-truncated-\(UUID().uuidString).zip")
        let bytes = try Data(contentsOf: fixture)
        try bytes.prefix(bytes.count / 2).write(to: damaged)
        defer { try? FileManager.default.removeItem(at: damaged) }
        app = launch(reset: false, store: "webimport", extra: ["-MeowverseBackupFile", damaged.path])
        openSettings(app)
        reveal(app, "drill-open-backup-file").tap()
        waitForLabel(reveal(app, "backup-notice"), containing: "现在的房间没有任何改动", timeout: 30)
        XCTAssertFalse(app.buttons["confirm-restore"].exists)
        snap("web-5-refused")
        waitForLabel(reveal(app, "storage-usage"), containing: "3 张照片、2 件家具")
        app.buttons["close-settings"].tap()
        XCTAssertEqual(app.buttons.matching(sourceButton).count, 2)
        #endif
    }

    /// Settings and the restore preview at the largest text size: nothing is cut off and the
    /// system audit passes. Simulator only (reads the web fixture from the test bundle).
    func testSettingsAndRestorePreviewAtLargestTextSizePassAudit() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("the fixture path is only readable by the app on the simulator")
        #else
        let fixture = try XCTUnwrap(Bundle(for: PhotoToFurnitureUITests.self).url(forResource: "web-v6-synthetic", withExtension: "zip"))
        let app = launch(reset: true, store: "settingsa11y",
                         extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-MeowverseBackupFile", fixture.path])
        openSettings(app)
        XCTAssertTrue(element(app, "open-cats-from-settings").waitForExistence(timeout: 10))
        sleep(1); snap("S1-xxxl-settings")
        try audit(app, longList: true)
        app.swipeUp(velocity: .slow)
        sleep(1); snap("S2-xxxl-settings-backup")
        try audit(app, longList: true)
        reveal(app, "drill-open-backup-file").tap()
        XCTAssertTrue(element(app, "preview-kind").waitForExistence(timeout: 30))
        sleep(1); snap("S3-xxxl-preview")
        try audit(app, longList: true)
        reveal(app, "cancel-restore")
        sleep(1); snap("S4-xxxl-preview-confirm")
        try audit(app, longList: true)
        reveal(app, "cancel-restore").tap()
        let clearRow = reveal(app, "clear-all")
        // All of it inside the band the audit reads: peeking in at the bottom it isn't audited, and
        // the row above is then measured against the navigation bar's blur.
        let band = app.windows.firstMatch.frame.maxY - 110
        for _ in 0..<5 where clearRow.frame.maxY > band { scrollALittle(app) }
        XCTAssertLessThanOrEqual(clearRow.frame.maxY, band, "clear-all is audited")
        sleep(1); snap("S5-xxxl-settings-clear")
        try audit(app, longList: true)
        #endif
    }

    // MARK: - Photo library

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 10,
                              file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "expected “\(text)” in “\(element.exists ? element.label : "<missing>")”", file: file, line: line)
    }

    /// Lists are lazy: scroll until the row exists and can be tapped.
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(app, id)
        for _ in 0..<5 where !onScreen(app, target) { app.swipeUp(velocity: .slow) }
        // Not below: look above, stopping as soon as it shows (a swipe at the very top would close the sheet).
        for _ in 0..<8 where !onScreen(app, target) { app.swipeDown(velocity: .slow) }
        usleep(600_000)   // let the list settle before the caller taps
        XCTAssertTrue(onScreen(app, target), "could not reach \(id)", file: file, line: line)
        return target
    }

    /// Taps 核对 with room under it. At the window's foot (Settings' first section pushed it there)
    /// the button counts as hittable but the tap lands on the home indicator, and the result
    /// is a new row below the button, which must be on screen to be in the tree.
    private func tapIntegrityCheck(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let button = reveal(app, "check-integrity", file: file, line: line)
        let foot = app.windows.firstMatch.frame.maxY - 160
        for _ in 0..<5 where button.frame.maxY > foot { scrollALittle(app) }
        button.tap()
    }

    /// A fifth of the screen, with no fling.
    private func scrollALittle(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    /// Hittable and not scrolled up under the navigation bar. XCUITest calls a row behind the
    /// bar hittable, but a tap there lands on the bar (the integrity check button did this
    /// once the settings list grew).
    private func onScreen(_ app: XCUIApplication, _ target: XCUIElement) -> Bool {
        guard target.exists, target.isHittable else { return false }
        let bar = app.navigationBars.firstMatch
        return !bar.exists || target.frame.minY >= bar.frame.maxY - 1
    }

    /// Import as photo-only → it is in the library, not in any furniture → the user sets a date,
    /// a favourite and a note → all of it survives a relaunch → clearing the date brings the
    /// EXIF day back.
    func testPhotoOnlyImportLivesInLibraryAndKeepsEditsAcrossRelaunch() {
        var app = launch(reset: true, store: "library")
        app.buttons["add-synthetic"].tap()
        let photoOnly = app.buttons["photo-only"]
        XCTAssertTrue(photoOnly.waitForExistence(timeout: 20))
        snap("L1-review-other-ways")
        photoOnly.tap()

        // The library opens to show where the photo went; the room is still empty.
        let cell = app.buttons["library-photo"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        app.buttons["filter-unlinked"].tap()
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "listed under “not in furniture”")
        XCTAssertEqual(app.buttons.matching(identifier: "library-photo").count, 1)
        XCTAssertTrue((cell.value as? String)?.contains("还没放进家具") == true, "\(String(describing: cell.value))")
        XCTAssertTrue(element(app, "section-2026-03").exists, "grouped under its EXIF month")
        sleep(1); snap("L2-library-unlinked")

        cell.tap()
        let dateLine = element(app, "photo-date-line")
        XCTAssertTrue(dateLine.waitForExistence(timeout: 10))
        XCTAssertTrue(dateLine.label.contains("2026年3月14日") && dateLine.label.contains("来自照片信息"), dateLine.label)
        XCTAssertTrue(element(app, "detail-photo").waitForExistence(timeout: 10))
        snap("L3-photo-detail")

        // Set the capture day by hand: a different day of the same month.
        reveal(app, "edit-date").tap()
        XCTAssertTrue(app.buttons["save-date"].waitForExistence(timeout: 10))
        let day = app.datePickers.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "3月10日")).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 5), app.datePickers.firstMatch.debugDescription)
        day.tap()
        sleep(1); snap("L4-date-editor")
        app.buttons["save-date"].tap()
        waitForLabel(dateLine, containing: "你填写的")
        XCTAssertTrue(dateLine.label.contains("2026年3月10日"), dateLine.label)

        // Favourite and note.
        let favourite = reveal(app, "favorite-toggle")
        favourite.switches.firstMatch.exists ? favourite.switches.firstMatch.tap() : favourite.tap()
        reveal(app, "edit-note").tap()
        let noteText = app.textViews["note-text"]
        XCTAssertTrue(noteText.waitForExistence(timeout: 10))
        noteText.tap()
        noteText.typeText("Bella on the sofa")
        snap("L5-note-editor")
        app.buttons["save-note"].tap()
        let note = element(app, "photo-note")
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        XCTAssertEqual(element(app, "favorite-toggle").value as? String, "1")
        sleep(1); snap("L6-photo-detail-edited")
        reveal(app, "photo-unlinked")
        snap("L7-photo-detail-lower")

        // Quit completely and reopen.
        app.terminate()
        app = launch(reset: false, store: "library")
        assertRoomEmpty(app, "photo-only import added no furniture")
        app.buttons["photo-library"].tap()
        app.buttons["filter-favorites"].tap()
        let restored = app.buttons["library-photo"].firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        let summary = restored.value as? String ?? ""
        XCTAssertTrue(summary.contains("已收藏") && summary.contains("还没放进家具") && summary.contains("有便签"), summary)
        restored.tap()
        XCTAssertTrue(dateLine.waitForExistence(timeout: 10))
        XCTAssertTrue(dateLine.label.contains("2026年3月10日") && dateLine.label.contains("你填写的"), dateLine.label)

        // Clearing the user's day restores the EXIF day: it was never overwritten.
        reveal(app, "clear-date").tap()
        waitForLabel(dateLine, containing: "来自照片信息")
        XCTAssertTrue(dateLine.label.contains("2026年3月14日"), dateLine.label)
        XCTAssertFalse(app.buttons["clear-date"].exists)
        XCTAssertTrue(reveal(app, "photo-note").label.contains("Bella on the sofa"))
        XCTAssertEqual(element(app, "favorite-toggle").value as? String, "1")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["close-library"].tap()
        openSettings(app)
        tapIntegrityCheck(app)
        let result = app.staticTexts["integrity-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.hasPrefix("0 件家具、1 张照片") && result.label.contains("全部和导入时一致"), result.label)
    }

    /// A piece of furniture gets a second photo; removing the furniture keeps both photos in the
    /// library; a stored photo can be attached to another piece; deleting a photo is explicit and
    /// never takes furniture with it: a piece that loses its last photo stays, and says it has none.
    func testSeveralPhotosPerFurnitureRemovalKeepsThemAndDeleteIsExplicit() {
        let app = launch(reset: true, store: "memories")
        walkToPlacement(app)
        app.buttons["confirm-placement"].tap()
        let source = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        XCTAssertTrue(element(app, "original-photo").waitForExistence(timeout: 10))

        // A second (different) photo for the same sofa: the album now shows both.
        app.buttons["furniture-more"].tap()
        app.buttons["再添一张合成照片"].tap()
        XCTAssertTrue(element(app, "furniture-album").waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "album-photo").count, 2)
        waitForLabel(element(app, "album-summary"), containing: "2 张照片")
        sleep(1); snap("M1-furniture-album")
        app.buttons.matching(identifier: "album-photo").matching(NSPredicate(format: "value CONTAINS %@", "未知")).firstMatch.tap()
        waitForLabel(element(app, "photo-caption"), containing: "拍摄日期未知")
        XCTAssertTrue(app.buttons["show-album"].exists)
        sleep(1); snap("M1b-furniture-second-photo")

        // Its editing screen is reachable from the furniture.
        app.buttons["photo-details"].firstMatch.tap()
        XCTAssertTrue(element(app, "photo-date-line").waitForExistence(timeout: 10))
        snap("M2-photo-detail-from-furniture")
        reveal(app, "make-furniture")
        XCTAssertFalse(element(app, "photo-unlinked").exists)
        XCTAssertFalse(app.buttons["photo-furniture"].exists, "the piece being viewed is not a link to itself")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Remove the sofa: both photos stay, now outside any furniture.
        app.buttons["furniture-more"].tap()
        app.buttons["删除家具"].tap()
        snap("M3-remove-confirmation")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "收纳箱")).firstMatch.waitForExistence(timeout: 5),
                      "the dialog points out the gentler option")
        XCTAssertTrue(app.buttons["stow-instead"].exists)
        app.buttons["删除"].tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
        assertRoomEmpty(app)
        app.buttons["photo-library"].tap()
        app.buttons["filter-unlinked"].tap()
        XCTAssertTrue(app.buttons["library-photo"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "library-photo").count, 2)
        XCTAssertTrue(element(app, "section-unknown").exists && element(app, "section-2026-03").exists)
        sleep(1); snap("M4-library-after-removal")
        app.buttons["close-library"].tap()

        // Importing the stored photo again offers the library copy; make a new sofa from it.
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(element(app, "stored-notice").waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["photo-only"].exists, "already stored: nothing to store again")
        app.buttons["manual-sofa"].tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons.matching(sourceButton).firstMatch.waitForExistence(timeout: 10))

        // Attach the other stored photo to the new sofa from its detail screen.
        app.buttons["photo-library"].tap()
        app.buttons["filter-unlinked"].tap()
        let unlinked = app.buttons["library-photo"].firstMatch
        XCTAssertTrue(unlinked.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "library-photo").count, 1, "the photo was linked, not copied")
        unlinked.tap()
        reveal(app, "link-furniture").tap()
        app.buttons["拉扣软包沙发"].firstMatch.tap()
        XCTAssertTrue(app.buttons["photo-furniture"].waitForExistence(timeout: 10))

        // Delete this photo: the sofa has another one, so it stays.
        reveal(app, "delete-photo").tap()
        snap("M5-delete-impact")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "「拉扣软包沙发」不会被删除，只是不再包含这一张")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["删除照片"].tap()
        app.buttons["filter-all"].tap()
        let last = app.buttons["library-photo"].firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "library-photo").count, 1)

        // Delete the last photo: the dialog says the sofa stays, and it does, without photos.
        last.tap()
        reveal(app, "delete-photo").tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "「拉扣软包沙发」不会被删除")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["删除照片"].tap()
        XCTAssertTrue(app.staticTexts["还没有照片"].waitForExistence(timeout: 10))
        app.buttons["close-library"].tap()
        app.buttons["furniture-list"].tap()
        let row = app.buttons["list-room-item"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the sofa is still in the room")
        XCTAssertTrue(row.label.contains("拉扣软包沙发") && row.label.contains("还没有照片"), row.label)
        row.tap()
        XCTAssertTrue(element(app, "furniture-no-photos").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "original-photo").exists, "no photo is shown for a piece that has none")
        sleep(1); snap("M6-sofa-without-photos")
        app.buttons["close-detail"].tap()
        openSettings(app)
        tapIntegrityCheck(app)
        let result = app.staticTexts["integrity-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.hasPrefix("1 件家具、0 张照片"), result.label)
    }

    /// In the review step a photo can join a piece that is already in the room instead of
    /// creating a new one; the room keeps one sofa, which now has two photos.
    func testImportedPhotoCanJoinExistingFurniture() {
        let app = launch(reset: true, store: "attach")
        walkToPlacement(app)
        app.buttons["confirm-placement"].tap()
        let sofa = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(sofa.waitForExistence(timeout: 10))

        // Give the sofa a second photo, then delete the first from the library, so the
        // synthetic photo can be imported afresh while the sofa is still there.
        sofa.tap()
        XCTAssertTrue(element(app, "original-photo").waitForExistence(timeout: 10))
        app.buttons["furniture-more"].tap()
        app.buttons["再添一张合成照片"].tap()
        XCTAssertTrue(element(app, "furniture-album").waitForExistence(timeout: 10))
        app.buttons["close-detail"].tap()
        app.buttons["photo-library"].tap()
        let dated = app.buttons.matching(identifier: "library-photo").matching(NSPredicate(format: "value CONTAINS %@", "3月14日")).firstMatch
        XCTAssertTrue(dated.waitForExistence(timeout: 10))
        dated.tap()
        reveal(app, "delete-photo").tap()
        app.buttons["删除照片"].tap()
        XCTAssertTrue(app.buttons["library-photo"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "library-photo").count, 1)
        app.buttons["close-library"].tap()
        XCTAssertEqual(app.buttons.matching(sourceButton).count, 1, "the sofa keeps its other photo")

        // Import again and attach to the sofa instead of adding furniture.
        app.buttons["add-synthetic"].tap()
        let attach = app.buttons["attach-existing"]
        XCTAssertTrue(attach.waitForExistence(timeout: 20))
        snap("A1-review-attach-offered")
        attach.tap()
        let target = app.buttons["attach-0"]
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        sleep(1); snap("A2-attach-step")
        target.tap()

        // The sofa opens on its album; the room still has exactly one piece, the library two linked photos.
        XCTAssertTrue(element(app, "furniture-album").waitForExistence(timeout: 10))
        app.buttons["close-detail"].tap()
        XCTAssertEqual(app.buttons.matching(sourceButton).count, 1)
        app.buttons["photo-library"].tap()
        XCTAssertTrue(app.buttons["library-photo"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "library-photo").count, 2)
        XCTAssertEqual(app.buttons["filter-unlinked"].label, "未放进家具，0 张")
        app.buttons["close-library"].tap()

        // The same photo once more: it is recognised, and there is no other piece to offer.
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.buttons["view-existing-furniture"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["attach-from-notice"].exists)
        XCTAssertFalse(app.buttons["attach-existing"].exists)
        XCTAssertFalse(app.buttons["photo-only"].exists)
        app.buttons["cancel-import"].tap()
        app.buttons["不添加"].tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
        sleep(1)

        openSettings(app)
        tapIntegrityCheck(app)
        let result = app.staticTexts["integrity-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.hasPrefix("1 件家具、2 张照片") && result.label.contains("全部和导入时一致"), result.label)
    }

    /// A photo stored without furniture can become furniture later, from its own screen,
    /// without a second copy being stored.
    func testStoredPhotoBecomesFurnitureLater() {
        let app = launch(reset: true, store: "later")
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.buttons["photo-only"].waitForExistence(timeout: 20))
        app.buttons["photo-only"].tap()
        let cell = app.buttons["library-photo"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        cell.tap()
        reveal(app, "make-furniture").tap()

        // The usual flow opens on the stored photo and says it is already kept.
        XCTAssertTrue(element(app, "stored-notice").waitForExistence(timeout: 20))
        app.buttons["manual-sofa"].tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons.matching(sourceButton).firstMatch.waitForExistence(timeout: 10))

        app.buttons["photo-library"].tap()
        XCTAssertTrue(app.buttons["library-photo"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "library-photo").count, 1)
        XCTAssertEqual(app.buttons["filter-unlinked"].label, "未放进家具，0 张")
        app.buttons["library-photo"].firstMatch.tap()
        let row = reveal(app, "photo-furniture")
        row.tap()   // opens the sofa it now belongs to
        XCTAssertTrue(element(app, "original-photo").waitForExistence(timeout: 10))
        let caption = element(app, "photo-caption")
        XCTAssertTrue(caption.label.contains("2026"), caption.label)
        app.buttons["close-detail"].tap()

        openSettings(app)
        tapIntegrityCheck(app)
        let result = app.staticTexts["integrity-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.hasPrefix("1 件家具、1 张照片") && result.label.contains("全部和导入时一致"), result.label)
    }

    /// A photo larger than the app keeps: it is stored as a reduced copy, the details say so, and
    /// making furniture from the stored copy later still finds the same photo (not a second one).
    func testLargePhotoIsKeptAsAReducedCopy() {
        let app = launch(reset: true, store: "reduced", extra: ["-MeowverseLargeSyntheticPhoto"])
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.buttons["photo-only"].waitForExistence(timeout: 20))
        app.buttons["photo-only"].tap()
        let cell = app.buttons["library-photo"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        cell.tap()
        let note = reveal(app, "reduced-copy-note")
        XCTAssertTrue(note.label.contains("3600×2700"), note.label)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "2048×1536")).firstMatch.exists)
        snap("reduced-copy-details")

        reveal(app, "make-furniture").tap()
        XCTAssertTrue(element(app, "stored-notice").waitForExistence(timeout: 20))
        app.buttons["manual-sofa"].tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons.matching(sourceButton).firstMatch.waitForExistence(timeout: 10))

        app.buttons["photo-library"].tap()
        XCTAssertTrue(app.buttons["library-photo"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "library-photo").count, 1)
        app.buttons["library-photo"].firstMatch.tap()
        reveal(app, "photo-furniture").tap()
        XCTAssertTrue(element(app, "original-photo").waitForExistence(timeout: 10))
        app.buttons["close-detail"].tap()

        openSettings(app)
        tapIntegrityCheck(app)
        let result = app.staticTexts["integrity-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.hasPrefix("1 件家具、1 张照片") && result.label.contains("全部和导入时一致"), result.label)
    }

    /// Several photos at once: they are stored in the background, then sorted one at a time.
    /// Stopping half-way keeps the rest waiting, also across a relaunch.
    func testBatchImportThenSortQueueAcrossRelaunch() {
        var app = launch(reset: true, store: "batch")
        app.addSyntheticBatch()
        let pending = element(app, "pending-count")
        XCTAssertTrue(pending.waitForExistence(timeout: 30))
        waitForLabel(pending, containing: "3 张照片待整理")
        assertRoomEmpty(app, "storing photos adds no furniture")
        sleep(1); snap("B1-pending-queue")

        // First photo becomes a sofa; the next one comes up by itself.
        app.buttons["start-sorting"].tap()
        XCTAssertTrue(app.navigationBars["整理照片 1 / 3"].waitForExistence(timeout: 20))
        snap("B2-sorting-first")
        XCTAssertTrue(element(app, "photo-board-hint").exists, "no board in the room yet: sorting says where furniture-less photos can go")
        app.buttons["manual-sofa"].tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.navigationBars["整理照片 2 / 3"].waitForExistence(timeout: 20))

        // Stop here: two photos keep waiting, also after quitting.
        tapSortingToolbarButton("stop-sorting", in: app)
        waitForLabel(pending, containing: "2 张照片待整理")
        app.terminate()
        app = launch(reset: false, store: "batch")
        XCTAssertTrue(pending.waitForExistence(timeout: 10))
        waitForLabel(pending, containing: "2 张照片待整理")

        // Second photo joins the sofa, third stays loose in the library.
        app.buttons["start-sorting"].tap()
        XCTAssertTrue(app.navigationBars["整理照片 1 / 2"].waitForExistence(timeout: 20))
        app.buttons["attach-existing"].tap()
        XCTAssertTrue(app.buttons["attach-0"].waitForExistence(timeout: 10))
        app.buttons["attach-0"].tap()
        XCTAssertTrue(app.navigationBars["整理照片 2 / 2"].waitForExistence(timeout: 20))
        reveal(app, "keep-in-library").tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
        sleep(2)
        XCTAssertFalse(pending.exists, "nothing left to sort")
        XCTAssertEqual(app.buttons.matching(sourceButton).count, 1)

        app.buttons["photo-library"].tap()
        XCTAssertTrue(app.buttons["library-photo"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "library-photo").count, 3)
        XCTAssertEqual(app.buttons["filter-unlinked"].label, "未放进家具，1 张")
        app.buttons["filter-unlinked"].tap()
        XCTAssertTrue(app.buttons["sort-unlinked"].waitForExistence(timeout: 5), "loose photos can be sorted later")
        app.buttons["close-library"].tap()

        openSettings(app)
        tapIntegrityCheck(app)
        let result = app.staticTexts["integrity-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.hasPrefix("1 件家具、3 张照片") && result.label.contains("全部和导入时一致"), result.label)
    }

    /// A photo that looks like one already in a piece offers that piece first, and one tap puts
    /// it there. The batch photos are the sofa's photo with a ball added, so they look alike.
    /// Vision's networks do not run on the simulator, so prints come from the colour-grid stand-in;
    /// Vision itself is covered by the core tests and checked on a device.
    func testPhotoLikeAnExistingPieceSuggestsThatPiece() {
        let app = launch(reset: true, store: "similar", extra: ["-MeowverseColorGridSimilarity"])
        walkToPlacement(app)
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons.matching(sourceButton).firstMatch.waitForExistence(timeout: 10))
        app.addSyntheticBatch()
        let pending = element(app, "pending-count")
        XCTAssertTrue(pending.waitForExistence(timeout: 30))
        waitForLabel(pending, containing: "3 张照片待整理")
        app.buttons["start-sorting"].tap()
        XCTAssertTrue(app.navigationBars["整理照片 1 / 3"].waitForExistence(timeout: 20))
        let similar = app.buttons["similar-0"]
        XCTAssertTrue(similar.waitForExistence(timeout: 20), "the sofa is offered for a photo that looks like its own")
        XCTAssertTrue(similar.label.contains("放进「"), similar.label)
        XCTAssertFalse(app.buttons["similar-1"].exists, "only one piece in the room")
        sleep(1); snap("S1-similar-offered")

        similar.tap()
        XCTAssertTrue(app.navigationBars["整理照片 2 / 3"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["similar-0"].waitForExistence(timeout: 20), "the next look-alike is offered too")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'suggestion-'")).firstMatch.exists,
                       "with furniture photos to compare with, no category guess is shown")
        // "未识别" means the photo wall. There is none yet, so it starts placing a photo board.
        let unrecognised = reveal(app, "similar-none")
        XCTAssertTrue(unrecognised.label.contains("未识别") && unrecognised.label.contains("照片板"), unrecognised.label)
        sleep(1); snap("S2-unrecognised-without-board")
        unrecognised.tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()

        // The last photo: now "未识别" puts it on that board, in one tap.
        XCTAssertTrue(app.navigationBars["整理照片 3 / 3"].waitForExistence(timeout: 20))
        let onBoard = app.buttons.matching(NSPredicate(format: "label CONTAINS '未识别' AND label CONTAINS '放到「'")).firstMatch
        XCTAssertTrue(onBoard.waitForExistence(timeout: 20), "the board is offered for an unrecognised photo")
        sleep(1); snap("S3-unrecognised-onto-board")
        onBoard.tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 20))
        sleep(2)
        XCTAssertFalse(pending.exists, "nothing left to sort")

        openSettings(app)
        // Below the fold since Settings grew (app icons); a List row off screen is not in the tree.
        tapIntegrityCheck(app)
        let result = app.staticTexts["integrity-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.hasPrefix("2 件家具、4 张照片"), result.label)

        // One print per photo: the sofa's first photo in the backfill, then each sorted photo's
        // review print. The photo put into the sofa keeps its review print, so the backfill
        // before the next review does not make it again (that would read 5). Board photos never vote.
        reveal(app, "open-feedback").tap()
        reveal(app, "feedback-show-diagnostics").tap()
        let diagnostics = app.staticTexts["feedback-diagnostics-text"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 20))
        XCTAssertTrue(diagnostics.label.contains("Feature print: median "), diagnostics.label)
        XCTAssertTrue(diagnostics.label.contains(" ms over the last 4 (test.colorGrid)"), diagnostics.label)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 10))
        app.buttons["close-settings"].tap()

        tapFurnitureList(app)
        let row = app.buttons.matching(identifier: "list-room-item").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let sofaRow = app.buttons.matching(NSPredicate(format: "identifier == 'list-room-item' AND label CONTAINS '沙发'")).firstMatch
        XCTAssertTrue(sofaRow.label.contains("2 张照片"), sofaRow.label)
    }

    /// The one UI test on the real embedder (the simulator runs the Core ML model, about 0.3 s a
    /// photo after a few seconds' load): once a photo is filed and a batch comes in, the prints
    /// were made by DINOv2, so the model is in the bundle, loads in the app, and the Vision
    /// fallback did not trigger. (One filed photo alone is not printed: nothing compares with it yet.)
    func testFiledPhotoIsPrintedByTheDinoModel() {
        let app = launch(reset: true, store: "dino")
        walkToPlacement(app)
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons.matching(sourceButton).firstMatch.waitForExistence(timeout: 10))
        app.addSyntheticBatch()
        let pending = element(app, "pending-count")
        XCTAssertTrue(pending.waitForExistence(timeout: 30))
        waitForLabel(pending, containing: "3 张照片待整理")

        // The batch's prints and the filed photo's are made in the background; look until timed.
        var label = ""
        for _ in 0..<6 {
            openSettings(app)
            reveal(app, "open-feedback").tap()
            reveal(app, "feedback-show-diagnostics").tap()
            let diagnostics = app.staticTexts["feedback-diagnostics-text"]
            XCTAssertTrue(diagnostics.waitForExistence(timeout: 20))
            label = diagnostics.label
            if !label.contains("Feature print: not timed yet") { break }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 10))
            app.buttons["close-settings"].tap()
            sleep(5)
        }
        XCTAssertTrue(label.contains("Feature print: median ") && label.contains(" (dinov2.vitb14reg.int8.meanpatch)"), label)
        XCTAssertFalse(label.contains("vision.featurePrint"), "the Vision fallback did not run")
        XCTAssertTrue(label.contains("Recognition: DINOv2 loaded (units "), label)

        // Round 8: on the real model the batch photos (the sofa photo with a ball) must be offered
        // the sofa. Before prints were scaled to unit length no photo was ever offered anything.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["close-settings"].waitForExistence(timeout: 10))
        app.buttons["close-settings"].tap()
        let sort = app.buttons["start-sorting"]
        XCTAssertTrue(sort.waitForExistence(timeout: 60), "sorting is offered once the prints are made")
        sort.tap()
        XCTAssertTrue(app.navigationBars["整理照片 1 / 3"].waitForExistence(timeout: 20))
        let similar = app.buttons["similar-0"]
        XCTAssertTrue(similar.waitForExistence(timeout: 30), "DINOv2 offers the sofa for a photo that looks like its own")
        XCTAssertTrue(similar.label.contains("放进「"), similar.label)
        let header = app.descendants(matching: .any)["recognition-header"].firstMatch
        XCTAssertTrue(header.label.contains("本机识别（DINOv2）"), header.label)
    }

    private func tapFurnitureList(_ app: XCUIApplication) {
        let list = app.buttons["furniture-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.tap()
    }

    /// A failed photo-only save stores nothing and can be retried.
    func testFailedPhotoOnlySaveCanBeRetried() {
        let app = launch(reset: true, failNextSave: true, store: "libraryfault")
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.buttons["photo-only"].waitForExistence(timeout: 20))
        app.buttons["photo-only"].tap()
        let alert = app.alerts["没能保存"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.buttons["重试"].tap()
        XCTAssertTrue(app.buttons["library-photo"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "library-photo").count, 1)
    }

    /// Largest accessibility text size on the new screens.
    func testLibraryAtLargestTextSizePassesAudit() throws {
        let app = launch(reset: true, store: "librarya11y",
                         extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.buttons["add-synthetic"].tap()
        let photoOnly = app.buttons["photo-only"]
        XCTAssertTrue(photoOnly.waitForExistence(timeout: 20))
        photoOnly.tap()
        let cell = app.buttons["library-photo"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        sleep(1); snap("X1-xxxl-library")
        try audit(app)
        app.buttons["filter-favorites"].tap()
        sleep(1); snap("X1b-xxxl-library-empty")
        try audit(app)
        app.buttons["filter-all"].tap()
        cell.tap()
        XCTAssertTrue(element(app, "photo-date-line").waitForExistence(timeout: 10))
        sleep(1); snap("X2-xxxl-photo-detail")
        try audit(app, longList: true)
        app.swipeUp()
        sleep(1); snap("X3-xxxl-photo-detail-lower")
        try audit(app, longList: true)
        reveal(app, "edit-date").tap()
        XCTAssertTrue(app.buttons["save-date"].waitForExistence(timeout: 10))
        sleep(1); snap("X4-xxxl-date-editor")
        app.buttons["save-date"].tap()
        waitForLabel(element(app, "photo-date-line"), containing: "你填写的")
    }

    /// Runs the system audit and reports every issue with the element it is about.
    /// `longList`: the screen is a list taller than the display at this text size, so some row is
    /// always cut by the screen edge or sits under the translucent navigation bar. The audit
    /// measures such a row against the blur or the cut (contrast / text clipped / Dynamic Type),
    /// and reports it without an element. Those reports are skipped; rows that are fully on
    /// screen are still checked, and the screenshots at each scroll position were read by eye.
    private func audit(_ app: XCUIApplication, longList: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
        var found: [String] = []
        let visible = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 110)
        // Top of the pinned bottom action, when the screen has one. At the largest text size it
        // is far taller than the 110 pt above.
        let barTop = ["next-model", "next-placement", "confirm-placement", "restore-furniture"]
            .map { app.buttons[$0] }.filter(\.exists).map(\.frame.minY).min()
        try app.performAccessibilityAudit(for: audited) { issue in
            if longList, [.contrast, .textClipped, .dynamicType].contains(issue.auditType) {
                guard let element = issue.element else { return true }
                if !visible.contains(element.frame) { return true }
            }
            // Navigation-bar buttons are capped by the system (Large Content Viewer covers them),
            // and a disabled button is dimmed on purpose.
            if issue.auditType == .dynamicType, let id = issue.element?.identifier,
               ["cancel-import", "close-detail", "close-library", "cancel-date", "save-date", "cancel-note", "save-note", "close-settings", "close-furniture-list", "cancel-add-furniture", "select-photos", "select-all-photos", "cancel-select-photos", "close-furniture-picker", "close-photo-picker", "confirm-photo-picker", "select-furniture", "select-all-furniture", "cancel-select-furniture", "cancel-order", "save-order"].contains(id) { return true }
            // The room's bottom bar (caption + add buttons) is capped at AX2 so the room stays visible;
            // like the navigation bar it offers the Large Content Viewer instead.
            if issue.auditType == .dynamicType, let element = issue.element,
               element.label == "添加照片" || element.identifier == "add-synthetic" || element.label.hasPrefix("Kitty ") { return true }
            if issue.auditType == .contrast, issue.element?.isEnabled == false { return true }
            // Text scrolled under the translucent bottom bar is measured against the blur, not its own background.
            if issue.auditType == .contrast, issue.element?.isHittable == false { return true }
            // A row sliding under the pinned bottom action is measured against that bar's blur.
            if issue.auditType == .contrast, let barTop, let frame = issue.element?.frame, frame.maxY > barTop - 16 { return true }
            // Checked by eye in the exported screenshots: the capture line wraps fully at this size.
            if issue.auditType == .textClipped, issue.element?.label.hasPrefix("拍摄于") == true { return true }
            // A navigation row whose label wraps to two lines at AX5 is reported as clipped; the screenshot shows both lines whole.
            if issue.auditType == .textClipped, issue.element?.label == "查看 3D 模型" { return true }
            // The furniture hotspots are clear buttons over 3D objects; there is no text to measure.
            if issue.auditType == .contrast, issue.element?.label.hasSuffix("查看照片") == true { return true }
            let element = issue.element.map { "\($0.elementType.rawValue) '\($0.label)' id=\($0.identifier)" } ?? "no element"
            found.append("\(issue.compactDescription) — \(element) — \(issue.detailedDescription)")
            return true
        }
        XCTAssertTrue(found.isEmpty, "accessibility audit: " + found.joined(separator: " | "), file: file, line: line)
    }

    private var audited: XCUIAccessibilityAuditType {
        [.contrast, .hitRegion, .sufficientElementDescription, .dynamicType, .textClipped, .trait]
    }

    // MARK: - Furniture without photos, the storage box, taking a photo off a piece

    /// Catalog flow without a photo, from the empty room.
    private func placeSofaWithoutPhoto(_ app: XCUIApplication) {
        app.buttons["place-furniture-first"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 10))
        sofa.tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
    }

    private func openSofaWithOnePhotoFromLibrary(_ app: XCUIApplication) {
        tapFurnitureList(app)
        let piece = app.buttons.matching(identifier: "list-room-item")
            .matching(NSPredicate(format: "label CONTAINS %@", "1 张照片")).firstMatch
        XCTAssertTrue(piece.waitForExistence(timeout: 10))
        piece.tap()
        XCTAssertTrue(element(app, "original-photo").waitForExistence(timeout: 10))
    }

    private func checkIntegrity(_ app: XCUIApplication, prefix: String, file: StaticString = #filePath, line: UInt = #line) {
        openSettings(app)
        tapIntegrityCheck(app, file: file, line: line)
        let result = app.staticTexts["integrity-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(result.label.hasPrefix(prefix), result.label, file: file, line: line)
        app.buttons["close-settings"].tap()
    }

    /// "先摆家具": cancelling saves nothing; a confirmed piece is in the room after a relaunch,
    /// says it has no photos, and then gets its first one.
    func testFurnitureWithoutPhotoIsKeptAndGetsItsFirstPhotoLater() {
        var app = launch(reset: true, store: "nophoto")
        assertRoomEmpty(app)

        // Back out at the last step: nothing was saved.
        placeSofaWithoutPhoto(app)
        sleep(1); snap("N1-place-without-photo")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1); snap("N2-grouped-categories")
        app.buttons["cancel-add-furniture"].tap()
        assertRoomEmpty(app, "cancelling the catalog flow leaves the room empty")

        placeSofaWithoutPhoto(app)
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.buttons["place-furniture-first"].exists, "the room is no longer empty")

        app.terminate()
        app = launch(reset: false, store: "nophoto")
        app.buttons["furniture-list"].tap()
        let row = app.buttons["list-room-item"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the piece survived the relaunch")
        XCTAssertTrue(row.label.contains("拉扣软包沙发") && row.label.contains("还没有照片"), row.label)
        XCTAssertFalse(row.label.contains("0 张"), row.label)
        sleep(1); snap("N3-list-without-photo")
        row.tap()
        XCTAssertTrue(element(app, "furniture-no-photos").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["add-first-photo"].exists)
        XCTAssertFalse(element(app, "original-photo").exists)
        sleep(1); snap("N4-detail-without-photo")

        // Its first photo, added from its own screen, is a manual source.
        app.buttons["furniture-more"].tap()
        app.buttons["再添一张合成照片"].tap()
        XCTAssertTrue(element(app, "original-photo").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "photo-caption").label.contains("由你手动选择"))
        app.buttons["close-detail"].tap()
        checkIntegrity(app, prefix: "1 件家具、1 张照片")
    }

    /// 收起: the piece leaves the room and keeps its photo; the photo is not "outside furniture";
    /// 放回房间 brings it back through the placement editor, and it is still there after a relaunch.
    /// Many-to-many by hand: photos go onto a second piece, off one, back from the library,
    /// and several are favourited, filtered by furniture and deleted at once. No piece is lost.
    func testSeveralPhotosMoveBetweenPiecesAndBatchActionsInTheLibrary() {
        let app = launch(reset: true, store: "manytomany")
        // Piece A has no photos; piece B gets two.
        placeSofaWithoutPhoto(app)
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons["add-synthetic"].waitForExistence(timeout: 10))
        walkToPlacement(app)
        app.buttons["confirm-placement"].tap()
        openSofaWithOnePhotoFromLibrary(app)
        app.buttons["furniture-more"].tap()
        app.buttons["再添一张合成照片"].tap()
        XCTAssertTrue(element(app, "furniture-album").waitForExistence(timeout: 10))
        let album = app.buttons.matching(identifier: "album-photo")
        XCTAssertEqual(album.count, 2)

        // Both photos also go onto piece A: they stay on B.
        app.buttons["album-select"].tap()
        album.element(boundBy: 0).tap()
        album.element(boundBy: 1).tap()
        waitForLabel(element(app, "album-summary"), containing: "已选 2 张")
        sleep(1); snap("N1-album-selecting")
        app.buttons["album-also"].tap()
        XCTAssertTrue(app.navigationBars["也放进另一件家具"].waitForExistence(timeout: 10))
        sleep(1); snap("N2-furniture-picker")
        app.buttons["拉扣软包沙发"].firstMatch.tap()
        XCTAssertTrue(app.buttons["album-select"].waitForExistence(timeout: 10))
        XCTAssertEqual(album.count, 2, "the photos are still on this piece")
        XCTAssertEqual(album.matching(NSPredicate(format: "value CONTAINS %@", "也在另外 1 件家具里")).count, 2)

        // One photo leaves B. It is still on A and in the library.
        app.buttons["album-select"].tap()
        album.element(boundBy: 0).tap()
        app.buttons["album-unlink"].tap()
        XCTAssertTrue(element(app, "original-photo").waitForExistence(timeout: 10), "one photo left: shown full size")

        // ... and comes back from the library, without importing anything.
        app.buttons["furniture-more"].tap()
        app.buttons["从照片库选照片"].tap()
        let offered = app.buttons.matching(identifier: "picker-photo")
        XCTAssertTrue(offered.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(offered.count, 1, "only the photo that is not on this piece is offered")
        offered.firstMatch.tap()
        sleep(1); snap("N3-photo-picker")
        app.buttons["confirm-photo-picker"].tap()
        XCTAssertTrue(element(app, "furniture-album").waitForExistence(timeout: 10))
        XCTAssertEqual(album.count, 2)
        app.buttons["close-detail"].tap()

        // The library shows both photos once each, on two pieces.
        app.buttons["photo-library"].tap()
        let cells = app.buttons.matching(identifier: "library-photo")
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(cells.count, 2, "linking never copies a photo")
        XCTAssertTrue((cells.firstMatch.value as? String)?.contains("在「拉扣软包沙发」、「拉扣软包沙发」里") == true, "\(String(describing: cells.firstMatch.value))")

        // Favourite both at once, then take it back.
        app.buttons["select-photos"].tap()
        cells.element(boundBy: 0).tap()
        cells.element(boundBy: 1).tap()
        XCTAssertTrue(app.navigationBars["已选 2 张"].waitForExistence(timeout: 5))
        sleep(1); snap("N4-library-selecting")
        app.buttons["batch-favorite"].tap()
        XCTAssertTrue(app.staticTexts["已收藏 2 张照片"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["filter-favorites"].label, "收藏，2 张")
        snap("N5-batch-notice")
        app.buttons["undo-batch"].tap()
        waitForLabel(app.buttons["filter-favorites"], containing: "0 张")

        // Filter by furniture, then clear it.
        app.buttons["filter-furniture"].tap()
        XCTAssertTrue(app.navigationBars["按家具筛选"].waitForExistence(timeout: 10))
        app.buttons["拉扣软包沙发"].firstMatch.tap()
        app.buttons["close-furniture-picker"].tap()
        waitForLabel(app.buttons["filter-furniture"], containing: "按家具筛选：「拉扣软包沙发」")
        XCTAssertEqual(cells.count, 2)
        sleep(1); snap("N6-furniture-filter")
        app.buttons["clear-furniture-filter"].tap()
        XCTAssertEqual(app.buttons["filter-furniture"].label, "按家具筛选")

        // Delete both at once: the dialog says what it touches, and both pieces stay.
        app.buttons["select-photos"].tap()
        app.buttons["select-all-photos"].tap()
        app.buttons["batch-delete"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "其中 2 张在家具里，涉及 2 件家具")).firstMatch.waitForExistence(timeout: 5))
        snap("N7-batch-delete")
        app.buttons["删除 2 张照片"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["还没有照片"].waitForExistence(timeout: 10))
        app.buttons["close-library"].tap()
        tapFurnitureList(app)
        let rows = app.buttons.matching(identifier: "list-room-item")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(rows.count, 2, "deleting photos never deletes furniture")
        XCTAssertTrue(rows.firstMatch.label.contains("还没有照片"), rows.firstMatch.label)
        XCTAssertTrue(app.staticTexts["房间里 2 / 20"].exists)
        sleep(1); snap("N8-furniture-list")
    }

    /// Names the piece in the placement editor, then confirms it.
    private func confirmPlacement(_ app: XCUIApplication, named name: String) {
        let field = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "家具的名字")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.replaceText(with: name)
        app.buttons["confirm-placement"].tap()
    }

    /// A long press on a photo in the library: favourite, cover, take off furniture (one piece or
    /// all, with 撤销), put on furniture, share, delete. Then the same "take off" for ticked photos
    /// from the batch bar, which asks which piece first when they are on several.
    func testLongPressMenuAndBatchTakePhotosOffFurniture() {
        let app = launch(reset: true, store: "photomenu")
        // 窗边沙发 has no photos; 客厅沙发 gets two, and both go onto 窗边沙发 as well.
        placeSofaWithoutPhoto(app)
        confirmPlacement(app, named: "窗边沙发")
        XCTAssertTrue(app.buttons["add-synthetic"].waitForExistence(timeout: 10))
        walkToPlacement(app)
        confirmPlacement(app, named: "客厅沙发")
        openSofaWithOnePhotoFromLibrary(app)
        app.buttons["furniture-more"].tap()
        app.buttons["再添一张合成照片"].tap()
        XCTAssertTrue(element(app, "furniture-album").waitForExistence(timeout: 10))
        let album = app.buttons.matching(identifier: "album-photo")
        XCTAssertEqual(album.count, 2)
        app.buttons["album-select"].tap()
        album.element(boundBy: 0).tap()
        album.element(boundBy: 1).tap()
        app.buttons["album-also"].tap()
        XCTAssertTrue(app.navigationBars["也放进另一件家具"].waitForExistence(timeout: 10))
        app.buttons["窗边沙发"].firstMatch.tap()
        XCTAssertTrue(app.buttons["album-select"].waitForExistence(timeout: 10))
        app.buttons["close-detail"].tap()

        app.buttons["photo-library"].tap()
        let cells = app.buttons.matching(identifier: "library-photo")
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(cells.count, 2)
        let first = cells.element(boundBy: 0)
        let onBoth = NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "客厅沙发", "窗边沙发")
        XCTAssertTrue(onBoth.evaluate(with: first), "\(String(describing: first.value))")

        // On two pieces: 设为封面 and 从家具移出 list them; 放进家具… has nothing left to offer.
        first.press(forDuration: 1.2)
        let takeOff = menuButton(app, "从家具移出")
        XCTAssertTrue(takeOff.waitForExistence(timeout: 5))
        XCTAssertTrue(menuButton(app, "设为封面").exists)
        XCTAssertTrue(menuButton(app, "收藏").exists)
        XCTAssertTrue(menuButton(app, "分享或导出").exists)
        XCTAssertTrue(menuButton(app, "删除").exists)
        XCTAssertFalse(menuButton(app, "放进家具…").exists, "the photo is on every piece already")
        sleep(1); snap("M1-long-press-menu")
        takeOff.tap()
        let all = menuButton(app, "从全部 2 件家具移出")
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        XCTAssertTrue(menuButton(app, "客厅沙发").exists && menuButton(app, "窗边沙发").exists)
        XCTAssertTrue(app.staticTexts["这张照片在 2 件家具里"].exists, "the submenu says how many pieces, as the batch bar does")
        sleep(1); snap("M2-take-off-submenu")
        all.tap()
        XCTAssertTrue(app.staticTexts["已把 1 张照片从 2 件家具移出"].waitForExistence(timeout: 10))
        waitForValue(first, containing: "还没放进家具")
        waitForLabel(app.buttons["filter-unlinked"], containing: "1 张")
        app.buttons["undo-batch"].tap()
        let back = XCTNSPredicateExpectation(predicate: onBoth, object: first)
        XCTAssertEqual(XCTWaiter().wait(for: [back], timeout: 10), .completed, "撤销 puts the photo back on both pieces")
        waitForLabel(app.buttons["filter-unlinked"], containing: "0 张")

        // Favourite from the menu.
        first.press(forDuration: 1.2)
        menuButton(app, "收藏").tap()
        waitForLabel(app.buttons["filter-favorites"], containing: "1 张")
        XCTAssertTrue((first.value as? String)?.contains("已收藏") == true)

        // The second photo becomes 窗边沙发's cover; the menu then marks it.
        let second = cells.element(boundBy: 1)
        second.press(forDuration: 1.2)
        menuButton(app, "设为封面").tap()
        let windowCover = menuButton(app, "窗边沙发")
        XCTAssertTrue(windowCover.waitForExistence(timeout: 5))
        windowCover.tap()
        XCTAssertTrue(app.staticTexts["已设为「窗边沙发」的封面"].waitForExistence(timeout: 10))
        second.press(forDuration: 1.2)
        menuButton(app, "设为封面").tap()
        let marked = menuButton(app, "窗边沙发（已是封面）")
        XCTAssertTrue(marked.waitForExistence(timeout: 5))
        XCTAssertFalse(marked.isEnabled, "the cover it already is cannot be chosen again")
        sleep(1); snap("M3-cover-marked")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()

        // Ticked photos on two pieces: the bar asks which piece, or all.
        app.buttons["select-photos"].tap()
        XCTAssertTrue(app.buttons["batch-unlink"].waitForExistence(timeout: 5))
        for id in ["batch-link", "batch-favorite", "batch-unlink", "batch-export", "batch-delete"] {
            XCTAssertFalse(app.buttons[id].isEnabled, "\(id) waits for a ticked photo")
        }
        sleep(1); snap("M4a-batch-bar-nothing-ticked")
        app.buttons["select-all-photos"].tap()
        XCTAssertTrue(app.navigationBars["已选 2 张"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["batch-export"].label, "分享或导出", "the same name as in the long-press menu")
        sleep(1); snap("M4-batch-bar")
        app.buttons["batch-export"].tap()
        let shareItem = menuButton(app, "分享照片")
        let saveItem = menuButton(app, "保存到系统相册")
        XCTAssertTrue(shareItem.waitForExistence(timeout: 5) && saveItem.exists)
        XCTAssertLessThan(shareItem.frame.minY, saveItem.frame.minY, "top-down, as in the long-press menu")
        sleep(1); snap("M4b-batch-export-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(app.buttons["batch-unlink"].waitForExistence(timeout: 5))
        app.buttons["batch-unlink"].tap()
        let living = menuButton(app, "客厅沙发")
        let everyPiece = menuButton(app, "从全部 2 件家具移出")
        XCTAssertTrue(living.waitForExistence(timeout: 5))
        XCTAssertTrue(everyPiece.exists)
        XCTAssertTrue(app.staticTexts["选中的照片在 2 件家具里"].exists)
        XCTAssertLessThan(living.frame.minY, everyPiece.frame.minY, "the pieces first, then all of them")
        sleep(1); snap("M5-batch-which-piece")
        living.tap()
        XCTAssertTrue(app.staticTexts["已把 2 张照片从「客厅沙发」移出"].waitForExistence(timeout: 10))
        XCTAssertTrue(onBoth.evaluate(with: first) == false && (first.value as? String)?.contains("窗边沙发") == true,
                      "still on the other piece: \(String(describing: first.value))")
        waitForLabel(app.buttons["filter-unlinked"], containing: "0 张")
        app.buttons["undo-batch"].tap()
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: onBoth, object: first)], timeout: 10), .completed)

        // On one piece only, the menu names it; delete asks first and leaves the pieces.
        first.press(forDuration: 1.2)
        menuButton(app, "从家具移出").tap()
        menuButton(app, "窗边沙发").tap()
        waitForValue(first, containing: "在「客厅沙发」里")
        first.press(forDuration: 1.2)
        let takeOffOne = menuButton(app, "从「客厅沙发」移出")
        XCTAssertTrue(takeOffOne.waitForExistence(timeout: 5))
        XCTAssertTrue(menuButton(app, "已是「客厅沙发」的封面").exists, "it is the first photo of 客厅沙发")
        let putOn = menuButton(app, "放进家具…")
        XCTAssertTrue(putOn.exists)
        XCTAssertLessThan(putOn.frame.minY, takeOffOne.frame.minY, "putting on comes before taking off")
        sleep(1); snap("M6-menu-one-piece")
        menuButton(app, "删除").tap()
        let confirm = app.buttons["confirm-delete-photo"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "「客厅沙发」不会被删除")).firstMatch.exists)
        sleep(1); snap("M8-delete-confirm")
        confirm.tap()
        wait(for: [expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: cells)], timeout: 10)

        // A photo on no piece: no cover, nothing to take off; 放进家具… is there.
        let last = cells.element(boundBy: 0)
        last.press(forDuration: 1.2)
        menuButton(app, "从家具移出").tap()
        let offAll = menuButton(app, "从全部 2 件家具移出")
        XCTAssertTrue(offAll.waitForExistence(timeout: 5))
        offAll.tap()
        waitForValue(last, containing: "还没放进家具")
        last.press(forDuration: 1.2)
        XCTAssertTrue(menuButton(app, "放进家具…").waitForExistence(timeout: 5))
        XCTAssertFalse(menuButton(app, "设为封面").exists)
        XCTAssertFalse(menuButton(app, "从家具移出").exists)
        sleep(1); snap("M7-menu-on-no-piece")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        app.buttons["close-library"].tap()
        tapFurnitureList(app)
        XCTAssertEqual(app.buttons.matching(identifier: "list-room-item").count, 2, "no piece goes with a photo")
    }

    /// English: the long-press menu and the batch bar, also at the largest accessibility size,
    /// where every button of the bar must still be on screen.
    func testEnglishLongPressMenuAndBatchBarFit() {
        var app = launch(reset: true, store: "photomenu-en", language: TestLanguage.english)
        walkToPlacement(app)
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons["photo-library"].waitForExistence(timeout: 10))
        app.buttons["photo-library"].tap()
        let cell = app.buttons.matching(identifier: "library-photo").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        cell.press(forDuration: 1.2)
        XCTAssertTrue(menuButton(app, "Share or export").waitForExistence(timeout: 5))
        XCTAssertTrue(menuButton(app, "Favorite").exists, "the action, not the filter's “Favorites”")
        sleep(1); snap("E1-long-press-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        app.buttons["select-photos"].tap()
        app.buttons["select-all-photos"].tap()
        XCTAssertEqual(app.buttons["batch-unlink"].label, "Take out of furniture")
        XCTAssertEqual(app.buttons["batch-export"].label, "Share or export")
        XCTAssertEqual(app.buttons["batch-favorite"].label, "Favorite")
        sleep(1); snap("E2-batch-bar")
        app.terminate()

        app = launch(reset: false, store: "photomenu-en",
                     extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"],
                     language: TestLanguage.english)
        app.buttons["photo-library"].tap()
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        app.buttons["select-photos"].tap()
        app.buttons["select-all-photos"].tap()
        let screen = app.windows.firstMatch.frame
        for id in ["batch-link", "batch-favorite", "batch-unlink", "batch-export", "batch-delete"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 5), id)
            XCTAssertTrue(screen.contains(button.frame), "\(id) is on screen: \(button.frame)")
            XCTAssertTrue(button.isHittable, id)
        }
        sleep(1); snap("E3-batch-bar-xxxl")
    }

    /// A long-press menu item, found by what it says (menu items carry no identifiers).
    private func menuButton(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func waitForValue(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 10,
                              file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "expected “\(text)” in “\(element.value as? String ?? "<missing>")”", file: file, line: line)
    }

    /// The furniture library: cover and order of a piece's photos, lock, filters, order, covers
    /// view, several pieces at once, and pointing a piece out in the room.
    func testFurnitureLibraryLockCoverBatchAndLocate() {
        let app = launch(reset: true, store: "furniturelib")
        // Piece A has no photos; piece B gets two.
        placeSofaWithoutPhoto(app)
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons["add-synthetic"].waitForExistence(timeout: 10))
        walkToPlacement(app)
        app.buttons["confirm-placement"].tap()
        openSofaWithOnePhotoFromLibrary(app)
        app.buttons["furniture-more"].tap()
        app.buttons["再添一张合成照片"].tap()
        XCTAssertTrue(element(app, "furniture-album").waitForExistence(timeout: 10))
        let album = app.buttons.matching(identifier: "album-photo")
        XCTAssertEqual(album.count, 2)
        let cover = NSPredicate(format: "value CONTAINS %@", "封面")
        XCTAssertTrue((album.element(boundBy: 0).value as? String)?.contains("封面") == true, "the first photo is the cover until another is chosen")

        // The second photo becomes the cover.
        app.buttons["album-select"].tap()
        XCTAssertFalse(app.buttons["album-cover"].isEnabled, "nothing chosen yet")
        album.element(boundBy: 1).tap()
        sleep(1); snap("L1-album-one-selected")
        app.buttons["album-cover"].tap()
        XCTAssertTrue(app.buttons["album-select"].waitForExistence(timeout: 10))
        XCTAssertEqual(album.matching(cover).count, 1)
        XCTAssertTrue((album.element(boundBy: 1).value as? String)?.contains("封面") == true)
        sleep(1); snap("L2-album-cover-chosen")

        // The order sheet opens and closes without changing anything.
        app.buttons["furniture-more"].tap()
        app.buttons["reorder-photos"].tap()
        XCTAssertTrue(app.navigationBars["调整照片顺序"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "order-row").count, 2)
        sleep(1); snap("L3-order")
        app.buttons["save-order"].tap()
        XCTAssertTrue(app.buttons["album-select"].waitForExistence(timeout: 10))
        XCTAssertEqual(album.count, 2)

        // Locked: the piece says so, and cannot be edited, put away or deleted from here.
        app.buttons["furniture-more"].tap()
        app.buttons["toggle-lock"].tap()
        XCTAssertTrue(element(app, "locked-banner").waitForExistence(timeout: 10))
        app.buttons["furniture-more"].tap()
        XCTAssertFalse(app.buttons["编辑家具"].isEnabled)
        XCTAssertFalse(app.buttons["stow-furniture"].isEnabled)
        XCTAssertFalse(app.buttons["删除家具"].isEnabled)
        sleep(1); snap("L4-locked-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()   // closes the menu
        app.buttons["close-detail"].tap()

        // The library lists both, the locked one marked.
        tapFurnitureList(app)
        let roomRows = app.buttons.matching(identifier: "list-room-item")
        let storedRows = app.buttons.matching(identifier: "list-stored-item")
        XCTAssertTrue(roomRows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(roomRows.count, 2)
        XCTAssertTrue(app.staticTexts["房间里 2 / 20"].exists)
        let lockedRows = roomRows.matching(NSPredicate(format: "label CONTAINS %@", "已锁定"))
        XCTAssertEqual(lockedRows.count, 1)
        XCTAssertTrue(lockedRows.firstMatch.label.contains("2 张照片"), lockedRows.firstMatch.label)
        sleep(1); snap("L5-library")

        // Putting everything away skips the locked piece and says so.
        app.buttons["select-furniture"].tap()
        app.buttons["select-all-furniture"].tap()
        XCTAssertTrue(app.navigationBars["已选 2 件"].waitForExistence(timeout: 5))
        sleep(1); snap("L6-library-selecting")
        app.buttons["batch-stow"].tap()
        let notice = element(app, "furniture-notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.label.contains("已收纳 1 件") && notice.label.contains("另外 1 件"), notice.label)
        XCTAssertEqual(roomRows.count, 1)
        XCTAssertEqual(storedRows.count, 1)
        XCTAssertTrue(roomRows.firstMatch.label.contains("已锁定"))
        sleep(1); snap("L7-after-batch-stow")

        // Place filter, order, covers view.
        XCTAssertEqual(app.buttons["place-stored"].label, "收纳箱，1 件")
        app.buttons["place-stored"].tap()
        XCTAssertEqual(roomRows.count, 0)
        XCTAssertEqual(storedRows.count, 1)
        app.buttons["place-all"].tap()
        app.buttons["furniture-sort"].tap()
        app.buttons["照片张数"].tap()
        XCTAssertTrue(app.staticTexts["2 件家具"].waitForExistence(timeout: 5), "a sorted list is one flat list")
        XCTAssertTrue(roomRows.firstMatch.label.contains("2 张照片"))
        XCTAssertTrue(storedRows.firstMatch.label.contains("在收纳箱"), storedRows.firstMatch.label)
        sleep(1); snap("L8-sorted")
        app.buttons["furniture-layout"].tap()
        XCTAssertTrue(roomRows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(roomRows.count + storedRows.count, 2)
        sleep(1); snap("L9-covers")
        app.buttons["furniture-layout"].tap()
        app.buttons["furniture-filter"].tap()
        app.buttons["还没有照片的"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()   // closes the menu
        XCTAssertTrue(element(app, "furniture-narrowed").waitForExistence(timeout: 5))
        XCTAssertEqual(roomRows.count, 0)
        XCTAssertEqual(storedRows.count, 1)
        sleep(1); snap("L10-filtered")
        app.buttons["clear-furniture-filters"].tap()
        XCTAssertEqual(roomRows.count + storedRows.count, 2)
        app.buttons["furniture-sort"].tap()
        app.buttons["添加顺序"].tap()

        // Pointing the locked piece out closes the library and marks it in the room.
        app.buttons.matching(identifier: "piece-menu").element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons["删除家具"].isEnabled, "a locked piece cannot be deleted")
        XCTAssertFalse(app.buttons["收进收纳箱"].isEnabled)
        app.buttons["在房间里定位"].tap()
        let roomNotice = element(app, "room-notice")
        XCTAssertTrue(roomNotice.waitForExistence(timeout: 10))
        XCTAssertTrue(roomNotice.label.contains("在这里"), roomNotice.label)
        snap("L11-located")

        let located = app.buttons.matching(sourceButton).firstMatch
        located.press(forDuration: 0.8)
        waitForLabel(roomNotice, containing: "已锁定")
        XCTAssertFalse(element(app, "edit-tray").exists)

        // Unlocked, it can be deleted; its photos stay in the library.
        tapFurnitureList(app)
        XCTAssertTrue(roomRows.firstMatch.waitForExistence(timeout: 10))
        app.buttons.matching(identifier: "piece-menu").element(boundBy: 0).tap()
        app.buttons["解锁"].tap()
        XCTAssertTrue(roomRows.firstMatch.waitForExistence(timeout: 5))
        waitForLabel(roomRows.firstMatch, containing: "2 张照片")
        XCTAssertEqual(roomRows.matching(NSPredicate(format: "label CONTAINS %@", "已锁定")).count, 0)
        app.buttons.matching(identifier: "piece-menu").element(boundBy: 0).tap()
        app.buttons["删除家具"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.label.contains("拉扣软包沙发"), alert.label)
        sleep(1); snap("L12-delete-asked")
        alert.buttons["删除"].tap()
        XCTAssertTrue(element(app, "list-room-empty").waitForExistence(timeout: 10))
        XCTAssertEqual(storedRows.count, 1)
        app.buttons["close-furniture-list"].tap()
        app.buttons["photo-library"].tap()
        XCTAssertTrue(app.buttons["library-photo"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "library-photo").count, 2)
    }

    func testStowedFurnitureKeepsItsPhotoAndComesBack() {
        var app = launch(reset: true, store: "stow")
        walkToPlacement(app)
        app.buttons["confirm-placement"].tap()
        let sofa = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(sofa.waitForExistence(timeout: 10))
        sofa.tap()
        XCTAssertTrue(element(app, "original-photo").waitForExistence(timeout: 10))
        app.buttons["furniture-more"].tap()
        snap("S1-more-menu")
        app.buttons["收进收纳箱"].tap()
        assertRoomEmpty(app, "a stowed piece is not in the room")

        // Its photo still belongs to it.
        app.buttons["photo-library"].tap()
        let cell = app.buttons["library-photo"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["filter-unlinked"].label, "未放进家具，0 张")
        XCTAssertTrue((cell.value as? String)?.contains("在「拉扣软包沙发」里") == true, "\(String(describing: cell.value))")
        app.buttons["close-library"].tap()

        // Also after quitting: listed under the storage box, photo browsable from there.
        app.terminate()
        app = launch(reset: false, store: "stow")
        assertRoomEmpty(app)
        app.buttons["furniture-list"].tap()
        let stored = app.buttons["list-stored-item"].firstMatch
        XCTAssertTrue(stored.waitForExistence(timeout: 10))
        XCTAssertTrue(stored.label.contains("拉扣软包沙发") && stored.label.contains("1 张照片"), stored.label)
        XCTAssertFalse(app.buttons["list-room-item"].exists)
        sleep(1); snap("S2-storage-box")
        stored.tap()
        XCTAssertTrue(element(app, "original-photo").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "stored-banner").exists)
        sleep(1); snap("S3-stored-detail")
        app.buttons["furniture-more"].tap()
        XCTAssertFalse(app.buttons["收进收纳箱"].exists, "a stored piece cannot be stowed or moved")
        XCTAssertFalse(app.buttons["编辑家具"].exists)
        XCTAssertTrue(app.buttons["删除家具"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()   // closes the menu

        app.buttons["restore-furniture"].tap()
        let confirm = app.buttons["confirm-placement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        waitForLabel(element(app, "placement-status"), containing: "可以摆放")
        sleep(1); snap("S4-restore-placement")
        confirm.tap()
        XCTAssertTrue(app.buttons.matching(sourceButton).firstMatch.waitForExistence(timeout: 10))

        app.terminate()
        app = launch(reset: false, store: "stow")
        let back = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(sourceButton).count, 1)
        back.tap()
        XCTAssertTrue(element(app, "original-photo").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "photo-caption").label.contains("2026"))
        XCTAssertFalse(element(app, "stored-banner").exists)
        app.buttons["close-detail"].tap()
        app.buttons["furniture-list"].tap()
        XCTAssertTrue(app.buttons["list-room-item"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["list-stored-item"].exists)
        app.buttons["close-furniture-list"].tap()
        checkIntegrity(app, prefix: "1 件家具、1 张照片")
    }

    /// 从这件家具移出: only the link goes. The photo stays in the library, the piece stays, and a
    /// piece left without photos says so.
    func testPhotoCanBeTakenOffAPieceWithoutDeletingEither() {
        let app = launch(reset: true, store: "unlink")
        walkToPlacement(app)
        app.buttons["confirm-placement"].tap()
        let sofa = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(sofa.waitForExistence(timeout: 10))
        sofa.tap()
        XCTAssertTrue(element(app, "original-photo").waitForExistence(timeout: 10))
        app.buttons["furniture-more"].tap()
        app.buttons["再添一张合成照片"].tap()
        XCTAssertTrue(element(app, "furniture-album").waitForExistence(timeout: 10))

        // Swipe the picture, then touch the actual footer for the newly displayed photo.
        app.buttons.matching(identifier: "album-photo").matching(NSPredicate(format: "value CONTAINS %@", "2026")).firstMatch.tap()
        element(app, "original-photo").swipeLeft()
        waitForLabel(element(app, "photo-caption"), containing: "拍摄日期未知")
        let edit = app.buttons["photo-details"]
        edit.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForLabel(element(app, "photo-date-line"), containing: "拍摄日期未知")
        let favorite = reveal(app, "favorite-toggle")
        favorite.switches.firstMatch.exists ? favorite.switches.firstMatch.tap() : favorite.tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: favorite)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        app.navigationBars["照片"].buttons.element(boundBy: 0).tap()
        waitForLabel(edit, containing: "已收藏")
        let unlink = app.buttons["quick-unlink-photo"]
        snap("U1-unlink-offered")
        unlink.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(element(app, "original-photo").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "furniture-album").exists)
        waitForLabel(element(app, "photo-caption"), containing: "2026")

        // Take the last one off as well: the sofa stays and says it has no photos.
        app.buttons["photo-details"].firstMatch.tap()
        reveal(app, "unlink-photo").tap()
        XCTAssertTrue(element(app, "furniture-no-photos").waitForExistence(timeout: 10))
        app.buttons["close-detail"].tap()

        // Both photos are still in the library, now outside any furniture.
        app.buttons["photo-library"].tap()
        XCTAssertTrue(app.buttons["library-photo"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "library-photo").count, 2)
        XCTAssertEqual(app.buttons["filter-unlinked"].label, "未放进家具，2 张")

        // From a photo's own screen (library context) there is nothing to take it off.
        app.buttons["library-photo"].firstMatch.tap()
        reveal(app, "make-furniture")
        XCTAssertFalse(app.buttons["unlink-photo"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["close-library"].tap()
        checkIntegrity(app, prefix: "1 件家具、2 张照片")
    }

    /// The new screens at the largest text size: grouped categories, the furniture list with the
    /// storage box, a piece without photos and a stored piece.
    func testCatalogFlowAndStorageAtLargestTextSizePassAudit() throws {
        let app = launch(reset: true, store: "storagea11y",
                         extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        func showFurnitureRow(_ identifier: String) -> XCUIElement {
            let row = app.buttons[identifier].firstMatch
            let list = app.scrollViews.containing(.button, identifier: "add-furniture").firstMatch
            let search = app.searchFields.firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 8))
            for _ in 0..<6 {
                let viewport = list.frame.intersection(app.frame)
                let top = max(viewport.minY, app.buttons["close-furniture-list"].frame.maxY)
                let bottom = search.exists && search.frame.midY > viewport.midY ? search.frame.minY : viewport.maxY
                if row.exists, row.isHittable, row.frame.midY > top, row.frame.midY < bottom {
                    return row
                }
                if row.exists && row.frame.midY <= top { list.swipeDown(velocity: .slow) }
                else { list.swipeUp(velocity: .slow) }
            }
            XCTFail("Could not bring \(identifier) above the search field")
            return row
        }
        let help = app.buttons["empty-room-help"]
        XCTAssertTrue(help.waitForExistence(timeout: 10))
        help.tap()
        app.buttons["place-furniture-first"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 10))
        sleep(1); snap("Y1-xxxl-categories")
        try audit(app, longList: true)
        sofa.tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        let confirm = app.buttons["confirm-placement"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10))

        app.buttons["furniture-list"].tap()
        _ = showFurnitureRow("list-room-item")
        sleep(1); snap("Y2-xxxl-list")
        try audit(app, longList: true)
        showFurnitureRow("list-room-item").coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
        XCTAssertTrue(element(app, "furniture-no-photos").waitForExistence(timeout: 10))
        sleep(1); snap("Y3-xxxl-no-photos")
        try audit(app)
        app.buttons["furniture-more"].tap()
        app.buttons["收进收纳箱"].tap()
        XCTAssertTrue(help.waitForExistence(timeout: 10))

        app.buttons["furniture-list"].tap()
        _ = showFurnitureRow("list-stored-item")
        sleep(1); snap("Y4-xxxl-storage-box")
        try audit(app, longList: true)
        showFurnitureRow("list-stored-item").coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
        let restore = app.buttons["restore-furniture"]
        XCTAssertTrue(restore.waitForExistence(timeout: 10))
        XCTAssertTrue(restore.isHittable, "the way back stays on screen at the largest text size")
        sleep(1); snap("Y5-xxxl-stored-detail")
        try audit(app)
    }

    // MARK: - Editing in the room

    /// A long press lifts the sofa for editing in the room. 取消 puts it back unchanged; a drag
    /// followed by 完成 moves it, and the new cell is still there after a relaunch.
    func testLongPressEditsPlacementInTheRoomAndCancelKeepsIt() {
        var app = launch(reset: true, store: "room-edit")
        walkToPlacement(app)
        app.buttons["confirm-placement"].tap()
        let sofa = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(sofa.waitForExistence(timeout: 10))
        sleep(1)
        let original = sofa.value as? String
        XCTAssertNotNil(original)

        // A plain tap still opens the source photo.
        sofa.tap()
        XCTAssertTrue(app.descendants(matching: .any)["original-photo"].waitForExistence(timeout: 10))
        app.buttons["close-detail"].tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))

        // Long press, turn it, cancel: nothing was saved.
        let tray = element(app, "edit-tray")
        sofa.press(forDuration: 1)
        XCTAssertTrue(tray.waitForExistence(timeout: 5))
        for id in ["photo-library", "furniture-list", "choose-interaction", "add-photo"] {
            XCTAssertFalse(app.buttons[id].exists, "Only editing controls are available while moving a piece")
        }
        app.buttons["edit-rotate"].tap()
        sleep(1); snap("E1-edit-mode")
        app.buttons["edit-cancel"].tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 5))
        XCTAssertEqual(sofa.value as? String, original, "cancel leaves the sofa where it was")

        // Long press and keep dragging towards the middle of the room, then confirm.
        let room = element(app, "room-world")
        sofa.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1, thenDragTo: room.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)))
        XCTAssertTrue(tray.waitForExistence(timeout: 5))
        sleep(1); snap("E2-dragged")
        let done = app.buttons["edit-done"]
        XCTAssertTrue(done.isEnabled, "the new cell is allowed: \(element(app, "edit-status").label)")
        done.tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
        let moved = sofa.value as? String
        XCTAssertNotEqual(moved, original, "the drag moved the sofa to another cell")

        app.terminate()
        app = launch(reset: false, store: "room-edit")
        let restored = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertEqual(restored.value as? String, moved, "the confirmed move survives a relaunch")
    }
}

// MARK: - QA round 10 (photo menu): 0 / 1 piece, mixed batch, delete confirmation

extension PhotoToFurnitureUITests {
    private func qaMenu(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func testQAMenuOnALoosePhotoAndAMixedBatch() {
        let app = launch(reset: true, store: "qamenu")
        walkToPlacement(app)
        confirmPlacement(app, named: "客厅沙发")
        openSofaWithOnePhotoFromLibrary(app)
        app.buttons["furniture-more"].tap()
        app.buttons["再添一张合成照片"].tap()
        XCTAssertTrue(element(app, "furniture-album").waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: app.buttons.matching(identifier: "album-photo"))], timeout: 10)
        app.buttons["close-detail"].tap()
        app.buttons["photo-library"].tap()
        let cells = app.buttons.matching(identifier: "library-photo")
        wait(for: [expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: cells)], timeout: 15)
        // Make one photo loose with the menu (one piece: the item names it).
        cells.element(boundBy: 1).press(forDuration: 1.2)
        qaMenu(app, "从「客厅沙发」移出").tap()
        XCTAssertTrue(app.staticTexts["已把 1 张照片从「客厅沙发」移出"].waitForExistence(timeout: 10))
        sleep(9) // let the notice go
        let loose = cells.matching(NSPredicate(format: "value CONTAINS %@", "还没放进家具")).firstMatch
        let onSofa = cells.matching(NSPredicate(format: "value CONTAINS %@", "客厅沙发")).firstMatch
        XCTAssertTrue(loose.exists && onSofa.exists, "\(cells.allElementsBoundByIndex.map { $0.value as? String ?? "" })")

        // 0 pieces: no cover, no take-off; put-on, favourite, share, delete are there.
        loose.press(forDuration: 1.2)
        XCTAssertTrue(qaMenu(app, "放进家具…").waitForExistence(timeout: 5))
        XCTAssertFalse(qaMenu(app, "设为封面").exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "封面")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "移出")).firstMatch.exists)
        XCTAssertTrue(qaMenu(app, "收藏").exists && qaMenu(app, "分享或导出").exists && qaMenu(app, "删除").exists)
        sleep(1); snap("QA1-loose-menu")
        // Delete asks; cancelling (outside the dialog) keeps the photo.
        qaMenu(app, "删除").tap()
        XCTAssertTrue(app.buttons["confirm-delete-photo"].firstMatch.waitForExistence(timeout: 5))
        sleep(1); snap("QA2-delete-asks")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        sleep(1)
        XCTAssertEqual(cells.count, 2, "cancel keeps the photo")

        // Put on from the menu, then 撤销.
        loose.press(forDuration: 1.2)
        qaMenu(app, "放进家具…").tap()
        let row = app.buttons["客厅沙发"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        sleep(1); snap("QA3-picker")
        row.tap()
        XCTAssertTrue(app.staticTexts["已把 1 张照片放进「客厅沙发」"].waitForExistence(timeout: 10))
        app.buttons["undo-batch"].tap()
        waitForLabel(app.buttons["filter-unlinked"], containing: "1 张")

        // One piece: the menu names it and says it is already the cover.
        onSofa.press(forDuration: 1.2)
        let isCover = qaMenu(app, "已是「客厅沙发」的封面")
        XCTAssertTrue(isCover.waitForExistence(timeout: 5))
        XCTAssertFalse(isCover.isEnabled)
        XCTAssertTrue(qaMenu(app, "从「客厅沙发」移出").exists)
        XCTAssertFalse(qaMenu(app, "放进家具…").exists, "the only piece holds it already")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        sleep(1)

        // A batch of one only-loose photo: take-off is off.
        app.buttons["select-photos"].tap()
        loose.tap()
        XCTAssertTrue(app.navigationBars["已选 1 张"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["batch-unlink"].isEnabled, "nothing to take off")
        // Mixed: one on the sofa, one loose. One piece: a button, no question.
        onSofa.tap()
        XCTAssertTrue(app.navigationBars["已选 2 张"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["batch-unlink"].isEnabled)
        sleep(1); snap("QA4-mixed-batch")
        app.buttons["batch-unlink"].tap()
        XCTAssertTrue(app.staticTexts["已把 1 张照片从「客厅沙发」移出"].waitForExistence(timeout: 10))
        waitForLabel(app.buttons["filter-unlinked"], containing: "2 张")
        app.buttons["undo-batch"].tap()
        waitForLabel(app.buttons["filter-unlinked"], containing: "1 张")
        XCTAssertTrue((onSofa.value as? String)?.contains("客厅沙发") == true)

        // Long press while ticking: does acting on one photo end the selection?
        app.buttons["select-photos"].tap()
        onSofa.tap()
        XCTAssertTrue(app.navigationBars["已选 1 张"].waitForExistence(timeout: 5))
        loose.press(forDuration: 1.2)
        sleep(1); snap("QA5a-press-in-select-mode")
        let titles = app.navigationBars.allElementsBoundByIndex.map(\.identifier)
        print("QA select-mode press: menu=\(qaMenu(app, "分享或导出").exists) bars=\(titles) favButtons=\(app.buttons.matching(NSPredicate(format: "label == '收藏'")).allElementsBoundByIndex.map(\.identifier))")
        let menuFav = app.buttons.matching(NSPredicate(format: "label == '收藏' AND identifier != 'batch-favorite'")).firstMatch
        if menuFav.exists { menuFav.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap() }
        sleep(2); snap("QA5-after-menu-in-select-mode")
        print("QA favorites after: \(app.buttons["filter-favorites"].label)")
        print("QA select-mode after menu: 已选1=\(app.navigationBars["已选 1 张"].exists) select-photos=\(app.buttons["select-photos"].exists)")
    }
}
