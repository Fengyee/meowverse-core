import Foundation

/// The diagnostics block a user can attach to a bug report. Pure: the app gathers the inputs,
/// this type decides what goes into the text. English `key: value` lines so the developer can
/// read any report whatever the user's language.
///
/// Never included: photos, thumbnails, file names, notes, the cat's name, furniture names,
/// tags, capture dates or file paths. Library data enters only as counts. Log lines are
/// scrubbed of paths and of every user-typed string known from the library state.
public struct FeedbackReport: Sendable, Equatable {
    public struct Environment: Sendable, Equatable {
        public var appVersion: String
        public var build: String
        /// "Debug" or "Release".
        public var configuration: String
        public var testFlight: Bool
        public var osVersion: String
        /// e.g. "iPhone17,1"; the simulator reports the model it simulates.
        public var deviceModel: String
        public var locale: String
        /// The raw content size category, e.g. "UICTContentSizeCategoryL".
        public var textSize: String
        public var reduceMotion: Bool
        public var voiceOver: Bool
        /// nil when the volume could not be asked.
        public var freeDiskBytes: Int64?

        public init(appVersion: String, build: String, configuration: String, testFlight: Bool,
                    osVersion: String, deviceModel: String, locale: String, textSize: String,
                    reduceMotion: Bool, voiceOver: Bool, freeDiskBytes: Int64?) {
            self.appVersion = appVersion
            self.build = build
            self.configuration = configuration
            self.testFlight = testFlight
            self.osVersion = osVersion
            self.deviceModel = deviceModel
            self.locale = locale
            self.textSize = textSize
            self.reduceMotion = reduceMotion
            self.voiceOver = voiceOver
            self.freeDiskBytes = freeDiskBytes
        }
    }

    /// Counts only. Nothing the user typed or picked can reach this struct.
    public struct Library: Sendable, Equatable {
        public var photos: Int
        public var furnitureInRoom: Int
        public var furnitureInStorage: Int
        public var schemaVersion: Int
        public var revision: Int

        public init(photos: Int, furnitureInRoom: Int, furnitureInStorage: Int, schemaVersion: Int, revision: Int) {
            self.photos = photos
            self.furnitureInRoom = furnitureInRoom
            self.furnitureInStorage = furnitureInStorage
            self.schemaVersion = schemaVersion
            self.revision = revision
        }

        public init(state: AppState) {
            self.init(photos: state.photos.count, furnitureInRoom: state.items.count,
                      furnitureInStorage: state.storage.count, schemaVersion: state.schemaVersion,
                      revision: state.revision)
        }
    }

    /// At most this many log lines are kept, newest last.
    public static let maxLogLines = 200
    /// A longer log line is cut; one runaway message must not fill the report.
    public static let maxLogLineLength = 300

    public let environment: Environment
    public let library: Library
    /// Already scrubbed.
    public let logLines: [String]
    /// nil: the log could not be read. Empty: it was read and had nothing from Meowverse.
    public let logUnavailableReason: String?

    /// `rawLogLines` are scrubbed here with `privateTerms` (see `privateTerms(in:)`) and paths removed.
    public init(environment: Environment, library: Library, rawLogLines: [String],
                privateTerms: [String], logUnavailableReason: String? = nil) {
        self.environment = environment
        self.library = library
        let terms = Self.normalizedTerms(privateTerms)
        self.logLines = rawLogLines.suffix(Self.maxLogLines).map { Self.scrub($0, terms: terms) }
        self.logUnavailableReason = logUnavailableReason
    }

    // MARK: Text

    /// Everything except the log. Short enough for a mail link.
    public var summaryText: String {
        let env = environment, lib = library
        return [
            "App: Meowverse \(env.appVersion) (build \(env.build), \(env.configuration)\(env.testFlight ? ", TestFlight" : ""))",
            "iOS: \(env.osVersion)",
            "Device: \(env.deviceModel)",
            "Locale: \(env.locale)",
            "Text size: \(env.textSize)",
            "Reduce Motion: \(env.reduceMotion ? "on" : "off")",
            "VoiceOver: \(env.voiceOver ? "on" : "off")",
            "Free disk: \(Self.diskBucket(env.freeDiskBytes))",
            "Photos: \(lib.photos)",
            "Furniture in room: \(lib.furnitureInRoom)",
            "Furniture in storage: \(lib.furnitureInStorage)",
            "Library schema: \(lib.schemaVersion)",
            "Library revision: \(lib.revision)",
        ].joined(separator: "\n")
    }

    /// The full block shown to the user and attached to the mail.
    public var diagnosticsText: String {
        var text = summaryText + "\n"
        if let reason = logUnavailableReason {
            text += "Log: unavailable (\(reason))"
        } else if logLines.isEmpty {
            text += "Log: no entries"
        } else {
            text += "Log (last \(logLines.count) entries):\n" + logLines.joined(separator: "\n")
        }
        return text
    }

    // MARK: Disk

    /// Coarse on purpose: the exact number says more about the device than the bug needs.
    public static func diskBucket(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return "unknown" }
        let gb = Double(bytes) / 1_000_000_000
        switch gb {
        case ..<0.5: return "under 0.5 GB"
        case ..<2: return "0.5-2 GB"
        case ..<10: return "2-10 GB"
        case ..<50: return "10-50 GB"
        default: return "50 GB or more"
        }
    }

    // MARK: Redaction

    /// Every string in the library the user typed or that came from their files: the cat's
    /// name, furniture names, tags, notes and photo file names. Used to scrub log lines; the
    /// report itself never reads these fields.
    public static func privateTerms(in state: AppState) -> [String] {
        let pieces = state.items + state.storage
        var terms = [state.catName]
        terms += pieces.map(\.displayName)
        terms += pieces.flatMap(\.tags)
        terms += state.photos.map(\.note)
        terms += state.photos.compactMap(\.filename)
        // A file name may also be logged without its extension.
        terms += state.photos.compactMap { $0.filename.map { ($0 as NSString).deletingPathExtension } }
        return terms
    }

    /// Longest first so a name that contains another is replaced whole. Single characters are
    /// skipped: replacing them would shred every line without protecting anything.
    static func normalizedTerms(_ terms: [String]) -> [String] {
        Set(terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter { $0.count >= 2 }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }

    private static let pathPattern = try! NSRegularExpression(pattern: #"(?:file://)?(?:~|/)[^\s"'(),;]*"#)

    /// Paths become `<path>`, private terms become `<redacted>`, newlines become spaces, and the
    /// line is cut to `maxLogLineLength`.
    public static func scrub(_ line: String, privateTerms: [String]) -> String {
        scrub(line, terms: normalizedTerms(privateTerms))
    }

    static func scrub(_ line: String, terms: [String]) -> String {
        var text = line.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        let range = NSRange(text.startIndex..., in: text)
        text = pathPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "<path>")
        for term in terms {
            text = text.replacingOccurrences(of: term, with: "<redacted>", options: [.caseInsensitive, .diacriticInsensitive])
        }
        if text.count > maxLogLineLength {
            text = String(text.prefix(maxLogLineLength)) + "…"
        }
        return text
    }
}

/// The plain-text mail built from the user's description and, if they kept it, the diagnostics.
public struct FeedbackMessage: Sendable, Equatable {
    public let body: String
    /// Full diagnostics to attach as a `.txt`, only when they are too long for the body.
    public let attachment: String?

    public static let separator = "\n\n---- Diagnostics ----\n"
    /// Longer diagnostics go into an attachment and the body keeps the summary.
    public static let attachThreshold = 4_000
    /// Mail links get long fast once percent-encoded; above this the log stays out of the link.
    public static let mailLinkLimit = 1_800

    /// For the system mail composer.
    public static func compose(description: String, report: FeedbackReport?) -> FeedbackMessage {
        let note = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let report else { return FeedbackMessage(body: note, attachment: nil) }
        let full = report.diagnosticsText
        if full.count <= attachThreshold {
            return FeedbackMessage(body: joined(note, full), attachment: nil)
        }
        let body = joined(note, report.summaryText + "\nLog: attached as diagnostics.txt")
        return FeedbackMessage(body: body, attachment: full)
    }

    /// For a `mailto:` link, which cannot carry an attachment.
    public static func mailLinkBody(description: String, report: FeedbackReport?) -> String {
        let note = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let report else { return note }
        let full = report.diagnosticsText
        if note.count + full.count <= mailLinkLimit { return joined(note, full) }
        return joined(note, report.summaryText + "\nLog: left out of the mail link (too long); use Copy in the app to include it")
    }

    /// Everything in one piece, for the clipboard: nothing is split off or left out.
    public static func plainText(description: String, report: FeedbackReport?) -> String {
        let note = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let report else { return note }
        return joined(note, report.diagnosticsText)
    }

    /// The description, then the diagnostics under a separator; no blank lead when there is no description.
    static func joined(_ note: String, _ diagnostics: String) -> String {
        note.isEmpty ? "---- Diagnostics ----\n" + diagnostics : note + separator + diagnostics
    }
}
