/// Whether the 「关于测试版」 page may show. TestFlight and the App Store run the same binary, and
/// App Review installs carry a sandbox receipt just as TestFlight installs do, so the receipt alone
/// cannot tell a test build from a store build under review. The build carries its own switch
/// (`MEOWVERSE_TEST_BUILD_NOTICE` in `Config.xcconfig`, written into Info.plist under `infoKey`):
/// off by default, turned on when a build is archived for TestFlight (docs/TESTFLIGHT.md). The
/// page needs both the switch and a sandbox receipt.
public enum TestBuildNotice {
    public static let infoKey = "MeowverseShowsTestBuildNotice"

    /// The switch as Info.plist carries it: "YES" (any case) or a true Boolean is on; anything
    /// else, a missing key or a setting left unexpanded included, is off.
    public static func switchedOn(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: flag
        case let text as String: text.uppercased() == "YES"
        default: false
        }
    }

    /// `receiptFileName`: the last path component of `Bundle.main.appStoreReceiptURL`.
    public static func shows(switchValue: Any?, receiptFileName: String?) -> Bool {
        switchedOn(switchValue) && receiptFileName == "sandboxReceipt"
    }

    /// The page comes once, after the opening (owner): when every chapter of the opening has an
    /// ending, whether read, skipped, skipped with everything, or waived for a home that was not
    /// empty. The chapters on demand are not waited for; they may stay open for weeks. Waiting for
    /// every chapter of the catalog kept the page away once T5 added them (QA_EN).
    public static func openingIsOver(_ catalog: TourCatalog, record: TourRecord) -> Bool {
        let opening = catalog.opening
        return !opening.isEmpty && opening.allSatisfy { record.entry(for: $0.id) != nil }
    }
}
