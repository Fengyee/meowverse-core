import Foundation

/// Where bug reports go. The one place the address lives.
enum FeedbackConfig {
    /// The owner's feedback address.
    static let recipient = "bella.meowverse@gmail.com"

    /// TestFlight installs carry a sandbox receipt; App Store installs do not.
    static var isTestFlight: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }
}
