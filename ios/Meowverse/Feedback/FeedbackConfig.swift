import Foundation
import MeowverseCore

/// Where bug reports go. The one place the address lives.
enum FeedbackConfig {
    /// The owner's feedback address.
    static let recipient = "bella.meowverse@gmail.com"

    /// Where this install came from (R01-002). A sandbox receipt alone cannot tell TestFlight
    /// from App Review: the build's own test-build switch decides, see `TestBuildNotice.channel`.
    static var channel: BuildChannel {
        let receipt = Bundle.main.appStoreReceiptURL
        return TestBuildNotice.channel(switchValue: Bundle.main.object(forInfoDictionaryKey: TestBuildNotice.infoKey),
                                       receiptFileName: receipt?.lastPathComponent,
                                       receiptExists: receipt.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
    }
}
