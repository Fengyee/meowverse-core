import Foundation
import MeowverseCore

/// 「测试版说明」: a TestFlight build ends the opening with one page that says this is a test build
/// and where to report problems. Shown once per library, after chapter 4, 【跳过这一段】 or
/// 「全部跳过」; a library that already had the opening behind it (grandfathered) sees it once too,
/// on its first launch of a TestFlight build that has the page.
///
/// Only in a build with the test-build switch on (`MEOWVERSE_TEST_BUILD_NOTICE`, docs/TESTFLIGHT.md)
/// and a sandbox receipt: App Review installs have a sandbox receipt too (`TestBuildNotice`).
///
/// DEBUG only: `-MeowverseFakeTestFlight` makes the build count as TestFlight for the page (not for the
/// feedback report, which still says what the build really is).
enum TourTestBuild {
    static var showsNotice: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-MeowverseFakeTestFlight") { return true }
        #endif
        return TestBuildNotice.shows(switchValue: Bundle.main.object(forInfoDictionaryKey: TestBuildNotice.infoKey),
                                     receiptFileName: Bundle.main.appStoreReceiptURL?.lastPathComponent)
    }

    /// Beside the tour's record, `tour.record.<library>`: the build the page was read in.
    static func key(library: String) -> String { "tour.testBuildNotice.\(library)" }

    static func seen(library: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key(library: library)) != nil
    }

    static func markSeen(library: String, defaults: UserDefaults = .standard) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        defaults.set("\(version) (\(build))", forKey: key(library: library))
    }

    static func forget(library: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(library: library))
    }

    static var title: String {
        String(localized: "tour.testBuild.title", defaultValue: "关于测试版", table: "Tour",
               comment: "Test build page title, above Bella's words (docs/onboarding/LINES.md beta.notice.title).")
    }
    static var line: String {
        String(localized: "tour.testBuild.line",
               defaultValue: "现在是测试版。用着哪里别扭、哪里坏了，都请告诉我们：在“设置 › 反馈问题”里写，或者直接联系开发者。测试期间，App 的玩法和操作随时可能会变。",
               table: "Tour",
               comment: "Test build page at the end of the opening tour, TestFlight builds only. Bella speaks. Settings › Report a Problem is the Settings row of that name.")
    }
    static var report: String {
        String(localized: "tour.testBuild.report", defaultValue: "去反馈", table: "Tour",
               comment: "Test build page: main button, opens Report a Problem.")
    }
    static var gotIt: String {
        String(localized: "tour.testBuild.gotIt", defaultValue: "知道了", table: "Tour",
               comment: "Test build page: closes the page.")
    }
    static var close: String {
        String(localized: "tour.testBuild.close", defaultValue: "关闭", table: "Tour",
               comment: "Test build page: closes Report a Problem opened from the page, and the page with it.")
    }
}
