import XCTest

/// iCloud sync with the test switch: a plain folder inside the app's container stands in for
/// CloudKit (`-MeowverseSyncFolder`), so two test libraries are two devices on one account.
/// Consent first → library A's sofa and photo reach library B → an edit on B reaches A → the
/// problems a real cloud has (signed out, full, another account, data deleted) are shown as
/// they are. Real CloudKit is never reached from here; see "iCloud 同步" in ios/README.md.
final class ICloudSyncUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(store: String, reset: Bool, syncFolder: String?, account: String? = nil, fault: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseSyntheticPhoto"]
        if reset { app.launchArguments.append("-MeowverseResetStore") }
        if let syncFolder { app.launchArguments += ["-MeowverseSyncFolder", syncFolder] }
        if let account { app.launchArguments += ["-MeowverseSyncAccount", account] }
        if let fault { app.launchArguments += ["-MeowverseSyncFault", fault] }
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 20))
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 15,
                              file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "expected “\(text)” in “\(element.exists ? element.label : "<missing>")”", file: file, line: line)
    }

    @discardableResult
    private func reveal(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(app, id)
        _ = target.waitForExistence(timeout: 3)
        for _ in 0..<5 where !(target.exists && target.isHittable) { app.swipeUp(velocity: .slow) }
        for _ in 0..<8 where !(target.exists && target.isHittable) { app.swipeDown(velocity: .slow) }
        usleep(600_000)
        XCTAssertTrue(target.exists && target.isHittable, "could not reach \(id)", file: file, line: line)
        return target
    }

    private func openSyncPage(_ app: XCUIApplication) {
        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        reveal(app, "open-icloud-sync").tap()
        XCTAssertTrue(app.switches["icloud-sync-toggle"].waitForExistence(timeout: 5))
    }

    /// Switch → consent sheet → agree. Nothing is synced before the agreement.
    private func turnSyncOn(_ app: XCUIApplication, expecting contents: String? = nil) {
        let status = element(app, "icloud-sync-status")
        waitForLabel(status, containing: "已关闭")
        XCTAssertFalse(app.buttons["icloud-sync-now"].isEnabled, "nothing can be synced before consent")
        app.switches["icloud-sync-toggle"].coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let summary = element(app, "icloud-sync-consent-contents")
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        if let contents { waitForLabel(summary, containing: contents) }
        waitForLabel(element(app, "icloud-sync-consent-photos"), containing: "相册里的原图不会上传")
        snap("sync-consent")
        app.buttons["icloud-sync-consent-confirm"].tap()
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var sourceButton: NSPredicate { NSPredicate(format: "label CONTAINS %@", "查看照片") }

    private func placeSofaFromSyntheticPhoto(_ app: XCUIApplication) {
        app.buttons["add-synthetic"].tap()
        let sofa = app.buttons["manual-sofa"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 20))
        sofa.tap()
        app.buttons["next-model"].tap()
        XCTAssertTrue(app.buttons["next-placement"].waitForExistence(timeout: 10))
        app.buttons["next-placement"].tap()
        XCTAssertTrue(app.buttons["confirm-placement"].waitForExistence(timeout: 10))
        app.buttons["confirm-placement"].tap()
        XCTAssertTrue(app.buttons.matching(sourceButton).firstMatch.waitForExistence(timeout: 10))
    }

    func testAPieceAndItsPhotoReachTheOtherLibraryAndAnEditComesBack() {
        let folder = "sync" + UUID().uuidString.prefix(8)
        var app = launch(store: "synca", reset: true, syncFolder: folder)
        placeSofaFromSyntheticPhoto(app)
        openSyncPage(app)
        turnSyncOn(app, expecting: "1 件家具")
        let status = element(app, "icloud-sync-status")
        waitForLabel(status, containing: "上次同步", timeout: 30)
        XCTAssertFalse(status.label.contains("等待上传"), "everything went: \(status.label)")
        snap("sync-a-on")
        app.terminate()

        // "Another iPhone on the same account": an empty library that turns sync on.
        app = launch(store: "syncb", reset: true, syncFolder: folder)
        XCTAssertEqual(app.buttons.matching(sourceButton).count, 0, "nothing arrives before sync is on")
        openSyncPage(app)
        turnSyncOn(app, expecting: "0 件家具")
        waitForLabel(element(app, "icloud-sync-status"), containing: "上次同步", timeout: 30)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        waitForLabel(reveal(app, "storage-usage"), containing: "1 张照片、1 件家具")

        // An edit on B: the cat's new name (in 猫咪管理), sent with "立即同步".
        app.buttons["close-settings"].tap()
        app.openCatManager()
        app.renameFirstCat(to: "同步小咪")
        app.buttons["close-home"].tap()
        app.buttons["open-settings"].tap()
        reveal(app, "open-icloud-sync").tap()
        app.buttons["icloud-sync-now"].tap()
        waitForLabel(element(app, "icloud-sync-notice"), containing: "同步完成", timeout: 30)
        XCTAssertFalse(element(app, "icloud-sync-status").label.contains("等待上传"))
        snap("sync-b-synced")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["close-settings"].tap()

        // The piece came with its photo: the copy was downloaded and checked against its hash.
        let piece = app.buttons.matching(sourceButton).firstMatch
        XCTAssertTrue(piece.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(sourceButton).count, 1, "one sofa, not two")
        piece.tap()
        XCTAssertTrue(element(app, "original-photo").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "photo-caption").label.contains("2026"), "the photo's day came with it")
        app.terminate()

        // Back on A: launching syncs, and B's edit is there.
        app = launch(store: "synca", reset: false, syncFolder: folder)
        app.openCatManager()
        app.waitForFirstCat(named: "同步小咪", timeout: 30)
        app.buttons["close-home"].tap()
        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        waitForLabel(reveal(app, "storage-usage"), containing: "1 张照片、1 件家具")
    }

    func testProblemsAreShownAsTheyAre() {
        // Not signed in: nothing goes anywhere, and the page says why.
        var app = launch(store: "syncout", reset: true, syncFolder: "sync" + UUID().uuidString.prefix(8), fault: "signedOut")
        openSyncPage(app)
        turnSyncOn(app)
        let status = element(app, "icloud-sync-status")
        waitForLabel(status, containing: "没有登录 iCloud", timeout: 30)
        XCTAssertFalse(status.label.contains("上次同步"), "never says it synced")
        snap("sync-signed-out")
        app.terminate()

        // iCloud full: the photo waits, the rest still goes, and the page says so.
        let full = "sync" + UUID().uuidString.prefix(8)
        app = launch(store: "syncfull", reset: true, syncFolder: full, fault: "quota")
        placeSofaFromSyntheticPhoto(app)
        openSyncPage(app)
        turnSyncOn(app)
        waitForLabel(element(app, "icloud-sync-status"), containing: "储存空间已满", timeout: 30)
        waitForLabel(element(app, "icloud-sync-status"), containing: "等待上传")
        snap("sync-quota")
        app.buttons["icloud-sync-now"].tap()
        waitForLabel(element(app, "icloud-sync-notice"), containing: "储存空间已满", timeout: 30)
        app.terminate()

        // The other device gets the sofa, and says its photo is on the way: not "no photos yet".
        app = launch(store: "syncfullb", reset: true, syncFolder: full)
        openSyncPage(app)
        turnSyncOn(app)
        waitForLabel(element(app, "icloud-sync-status"), containing: "1 张照片还没同步到这台设备", timeout: 30)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["close-settings"].tap()
        let waiting = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "照片还在同步")).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "还没有照片")).count, 0)
        waiting.tap()
        waitForLabel(element(app, "no-photos-title"), containing: "照片还在同步")
        snap("sync-photo-on-the-way")
        // PRIVACY-5: the same in the list a new photo is put into.
        app.buttons["close-detail"].tap()
        app.buttons["add-synthetic"].tap()
        XCTAssertTrue(app.buttons["manual-sofa"].waitForExistence(timeout: 20))
        reveal(app, "attach-existing").tap()
        waitForLabel(app.buttons["attach-0"], containing: "照片还在同步", timeout: 10)
        app.terminate()

        // Nothing fits (SYNC-3): records are refused too, so nothing synced and edits wait as well.
        app = launch(store: "syncbrim", reset: true, syncFolder: "sync" + UUID().uuidString.prefix(8), fault: "full")
        placeSofaFromSyntheticPhoto(app)
        openSyncPage(app)
        turnSyncOn(app)
        waitForLabel(element(app, "icloud-sync-status"), containing: "储存空间已满", timeout: 30)
        let brim = element(app, "icloud-sync-status").label
        snap("sync-full")
        XCTAssertFalse(brim.contains("照常同步"), brim)
        XCTAssertFalse(brim.contains("上次同步"), brim)
        app.terminate()

        // The iCloud data was deleted: sync stops and asks; re-uploading starts again.
        let folder = "sync" + UUID().uuidString.prefix(8)
        app = launch(store: "syncgone", reset: true, syncFolder: folder, fault: "deleted")
        openSyncPage(app)
        turnSyncOn(app)
        waitForLabel(element(app, "icloud-sync-status"), containing: "同步数据已被删除", timeout: 30)
        XCTAssertTrue(app.buttons["icloud-sync-start-over"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["icloud-sync-now"].isEnabled, "waits for the user's choice")
        snap("sync-deleted")
        reveal(app, "icloud-sync-start-over").tap()
        waitForLabel(element(app, "icloud-sync-status"), containing: "上次同步", timeout: 30)
        XCTAssertFalse(app.buttons["icloud-sync-start-over"].exists)
    }

    func testAnotherAccountIsAskedAboutAndNeverMergedSilently() {
        let folder = "sync" + UUID().uuidString.prefix(8)
        var app = launch(store: "syncacct", reset: true, syncFolder: folder, account: "first")
        openSyncPage(app)
        turnSyncOn(app)
        waitForLabel(element(app, "icloud-sync-status"), containing: "上次同步", timeout: 30)
        app.terminate()

        app = launch(store: "syncacct", reset: false, syncFolder: folder, account: "second")
        openSyncPage(app)
        let status = element(app, "icloud-sync-status")
        waitForLabel(status, containing: "另一个 Apple 账户", timeout: 30)
        XCTAssertTrue(app.buttons["icloud-sync-start-over"].waitForExistence(timeout: 5))
        snap("sync-account-changed")

        // Turning it off from there: both sides stay, the switch is off.
        reveal(app, "icloud-sync-turn-off").tap()
        waitForLabel(element(app, "icloud-sync-notice"), containing: "都还在")
        waitForLabel(status, containing: "已关闭")
        XCTAssertEqual(app.switches["icloud-sync-toggle"].value as? String, "0")
    }

    // MARK: Clearing all data with sync on (docs/ICLOUD_SYNC.md §7, §12 item 6)

    /// A sofa on A, synced; B turns sync on and has it too. Both apps are terminated.
    private func sharedSofa(_ folder: String, a: String, b: String) {
        var app = launch(store: a, reset: true, syncFolder: folder)
        placeSofaFromSyntheticPhoto(app)
        openSyncPage(app)
        turnSyncOn(app, expecting: "1 件家具")
        waitForLabel(element(app, "icloud-sync-status"), containing: "上次同步", timeout: 30)
        app.terminate()
        app = launch(store: b, reset: true, syncFolder: folder)
        openSyncPage(app)
        turnSyncOn(app, expecting: "0 件家具")
        waitForLabel(element(app, "icloud-sync-status"), containing: "上次同步", timeout: 30)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        waitForLabel(reveal(app, "storage-usage"), containing: "1 张照片、1 件家具")
        app.terminate()
    }

    /// Settings › 清除全部数据 › 继续清除: with sync on, the question about the home in iCloud.
    private func askToClear(_ app: XCUIApplication) {
        reveal(app, "clear-all").tap()
        let proceed = app.buttons["clear-all-continue"].firstMatch
        XCTAssertTrue(proceed.waitForExistence(timeout: 5))
        proceed.tap()
        XCTAssertTrue(app.buttons["clear-all-this-device"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["clear-all-everywhere"].firstMatch.exists)
    }

    private func aboutLine(_ app: XCUIApplication) -> XCUIElement {
        reveal(app, "open-about").tap()
        reveal(app, "about-privacy").tap()
        // The last section of 隐私: scroll to it, rows off screen are not in the tree.
        return reveal(app, "about-network")
    }

    func testClearingOnlyThisDeviceTurnsItsSyncOffAndLeavesTheOtherDevice() {
        let folder = "sync" + UUID().uuidString.prefix(8)
        sharedSofa(folder, a: "syncclra", b: "syncclrb")
        var app = launch(store: "syncclra", reset: false, syncFolder: folder)
        app.buttons["open-settings"].tap()
        // With sync on, the about page says how the app goes online, above the no-server line.
        let about = aboutLine(app)
        waitForLabel(about, containing: "没有自己的服务器")
        waitForLabel(element(app, "about-sync"), containing: "通过 Apple 的 iCloud")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap() // 关于与隐私 → 设置

        // Cancelling the new question clears nothing. iOS 27 shows no cancel button in the
        // dialog on iPhone: a tap outside it cancels.
        askToClear(app)
        snap("clear-scope-question")
        let cancel = app.buttons["clear-all-scope-cancel"].firstMatch
        if cancel.exists && cancel.isHittable { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap() }
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2))
        waitForLabel(reveal(app, "storage-usage"), containing: "1 张照片、1 件家具")

        askToClear(app)
        app.buttons["clear-all-this-device"].firstMatch.tap()
        let confirm = app.alerts.buttons["clear-all-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "同步会关闭")).firstMatch.exists)
        confirm.tap()
        waitForLabel(reveal(app, "backup-notice"), containing: "iCloud 同步也已关闭", timeout: 20)
        waitForLabel(reveal(app, "storage-usage"), containing: "0 张照片、0 件家具")
        // Sync is off here: nothing merges back, however long it waits.
        sleep(8)
        waitForLabel(reveal(app, "storage-usage"), containing: "0 张照片、0 件家具")
        reveal(app, "open-icloud-sync").tap()
        waitForLabel(element(app, "icloud-sync-status"), containing: "已关闭")
        XCTAssertEqual(app.switches["icloud-sync-toggle"].value as? String, "0")
        waitForLabel(element(app, "icloud-sync-notice"), containing: "清除全部数据时关闭了")
        XCTAssertFalse(element(app, "icloud-sync-notice").label.contains("家和 iCloud 里的数据都还在"))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        waitForLabel(aboutLine(app), containing: "没有自己的服务器")
        XCTAssertFalse(element(app, "about-sync").exists, "sync is off: no sync line")
        snap("clear-this-device-done")
        app.terminate()

        // B still has everything after syncing.
        app = launch(store: "syncclrb", reset: false, syncFolder: folder)
        openSyncPage(app)
        app.buttons["icloud-sync-now"].tap()
        waitForLabel(element(app, "icloud-sync-notice"), containing: "同步完成", timeout: 30)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        waitForLabel(reveal(app, "storage-usage"), containing: "1 张照片、1 件家具")
    }

    func testDeletingTheHomeInICloudEmptiesTheOtherDeviceToo() {
        let folder = "sync" + UUID().uuidString.prefix(8)
        sharedSofa(folder, a: "syncdela", b: "syncdelb")
        var app = launch(store: "syncdela", reset: false, syncFolder: folder)
        app.buttons["open-settings"].tap()
        askToClear(app)
        app.buttons["clear-all-everywhere"].firstMatch.tap()
        // The second confirmation says the other devices are emptied too.
        let confirm = app.alerts.buttons["clear-all-everywhere-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "也会一起被清空")).firstMatch.exists)
        snap("clear-everywhere-confirm")
        confirm.tap()
        waitForLabel(reveal(app, "backup-notice"), containing: "已删除 iCloud 里的家", timeout: 30)
        waitForLabel(reveal(app, "storage-usage"), containing: "0 张照片、0 件家具")
        // Sync stays on, and its first sync on the cleared library brings nothing back.
        reveal(app, "open-icloud-sync").tap()
        waitForLabel(element(app, "icloud-sync-status"), containing: "上次同步", timeout: 30)
        app.buttons["icloud-sync-now"].tap()
        waitForLabel(element(app, "icloud-sync-notice"), containing: "同步完成", timeout: 30)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        waitForLabel(reveal(app, "storage-usage"), containing: "0 张照片、0 件家具")
        app.terminate()

        // B takes the deletion with its launch sync.
        app = launch(store: "syncdelb", reset: false, syncFolder: folder)
        app.buttons["open-settings"].tap()
        waitForLabel(reveal(app, "storage-usage"), containing: "0 张照片、0 件家具", timeout: 30)
        XCTAssertEqual(app.buttons.matching(sourceButton).count, 0)
        snap("clear-everywhere-other-device")
    }

    func testDeletingTheHomeInICloudOfflineClearsNothing() {
        let app = launch(store: "syncdeloff", reset: true, syncFolder: "sync" + UUID().uuidString.prefix(8), fault: "offline")
        placeSofaFromSyntheticPhoto(app)
        openSyncPage(app)
        turnSyncOn(app)
        waitForLabel(element(app, "icloud-sync-status"), containing: "没有网络", timeout: 30)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        askToClear(app)
        app.buttons["clear-all-everywhere"].firstMatch.tap()
        let confirm = app.alerts.buttons["clear-all-everywhere-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        waitForLabel(reveal(app, "backup-notice"), containing: "哪里都没有清除", timeout: 30)
        waitForLabel(element(app, "backup-notice"), containing: "没有网络")
        waitForLabel(reveal(app, "storage-usage"), containing: "1 张照片、1 件家具")
    }

    /// A test library without the switch never reaches CloudKit and has no sync row.
    func testTestLibraryWithoutTheSwitchHasNoSyncRow() {
        let app = launch(store: "syncoff", reset: true, syncFolder: nil)
        app.buttons["open-settings"].tap()
        reveal(app, "import-web-backup")
        XCTAssertFalse(element(app, "open-icloud-sync").exists)
    }
}
