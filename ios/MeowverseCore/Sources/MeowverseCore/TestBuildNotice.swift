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

    /// How this install came to the device, for the bug report (R01-002). Only a build archived
    /// with the test-build switch and running on a sandbox receipt is a TestFlight test build. The
    /// App Store archive also runs on a sandbox receipt, both under App Review and on internal
    /// TestFlight, so with the switch off a sandbox receipt says only that: never "TestFlight".
    /// No receipt on disk (Xcode and development installs) is unknown.
    public static func channel(switchValue: Any?, receiptFileName: String?, receiptExists: Bool) -> BuildChannel {
        guard receiptExists, let receiptFileName else { return .unknown }
        switch receiptFileName {
        case "sandboxReceipt": return switchedOn(switchValue) ? .testFlight : .sandbox
        case "receipt": return .appStore
        default: return .unknown
        }
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

/// Where the running build came from, as far as the build and its receipt can tell.
public enum BuildChannel: String, Sendable, Equatable {
    case appStore, testFlight, sandbox, unknown

    /// The words the bug report adds after the configuration; nil adds nothing.
    public var reportLabel: String? {
        switch self {
        case .appStore: "App Store"
        case .testFlight: "TestFlight"
        case .sandbox: "sandbox receipt"
        case .unknown: nil
        }
    }
}
