import Foundation

/// The project's public pages that the app opens in the browser. Nothing of the user's is ever
/// added to these addresses.
public enum PublicPage {
    /// The public source repository, linked from the note that opens 设置.
    public static let sourceRepository = URL(string: "https://github.com/Fengyee/meowverse-core")!

    /// The published privacy policy (source: `public/privacy.html`), at the section in the
    /// interface language.
    public static func privacyPolicy(chinese: Bool) -> URL {
        URL(string: "https://fengyee.github.io/meowverse/privacy.html#" + (chinese ? "zh" : "en"))!
    }
}
