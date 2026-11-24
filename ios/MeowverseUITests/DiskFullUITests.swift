import XCTest

/// JOURNEY-NEW-1: a full disk is named, and a batch that got some photos in doesn't say all is as it was.
/// `-MeowverseDiskFullAfter <n>` fills the disk after n photos.
final class DiskFullUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testABatchThatRanOutOfSpaceSaysSo() {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", "disk-full", "-MeowverseResetStore", "-MeowverseSyntheticPhoto",
                                                      "-MeowverseColorGridSimilarity", "-MeowverseDiskFullAfter", "1"]
        app.launch()
        app.addSyntheticBatch()
        let alert = app.alerts["导入照片"]
        XCTAssertTrue(alert.waitForExistence(timeout: 30))
        let said = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(said.contains("已导入 1 张"), said)
        XCTAssertFalse(said.contains("保持原样"), said)
        XCTAssertTrue(said.contains("空间不够"), said)
    }
}
