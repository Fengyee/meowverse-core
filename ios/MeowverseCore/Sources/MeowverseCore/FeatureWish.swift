import Foundation

/// 「我想要这个」: a feature idea as a plain mail. Only what the user wrote and one version line
/// go in. No diagnostics, no attachment, and the library is never read, so the cat's name,
/// furniture names, notes and file names cannot reach it unless the user types them.
public enum FeatureWish {
    /// The first answer is required: an empty idea says nothing.
    public static func canCompose(_ wish: String) -> Bool {
        !wish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "App 0.1.0 (3) · iOS 27.2", the last line of the mail. The user sees it in Mail and may delete it.
    public static func versionLine(appVersion: String, build: String, osVersion: String) -> String {
        "App \(appVersion) (\(build)) · iOS \(osVersion)"
    }

    /// The idea, the optional "when would you use it" under its heading, then the version line.
    /// The same text serves the composer, a mail link and the clipboard.
    public static func compose(wish: String, context: String, contextHeading: String, versionLine: String) -> FeedbackMessage {
        let idea = wish.trimmingCharacters(in: .whitespacesAndNewlines)
        let when = context.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = [idea]
        if !when.isEmpty { parts.append(contextHeading + "\n" + when) }
        parts.append(versionLine)
        return FeedbackMessage(body: parts.joined(separator: "\n\n"), attachment: nil)
    }
}
