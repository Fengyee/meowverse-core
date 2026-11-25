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
        /// TestFlight only for an archived test build; see `TestBuildNotice.channel`.
        public var channel: BuildChannel
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

        public init(appVersion: String, build: String, configuration: String, channel: BuildChannel,
                    osVersion: String, deviceModel: String, locale: String, textSize: String,
                    reduceMotion: Bool, voiceOver: Bool, freeDiskBytes: Int64?) {
            self.appVersion = appVersion
            self.build = build
            self.configuration = configuration
            self.channel = channel
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
    /// How long the latest feature prints took on this device; durations only.
    public let featurePrint: FeaturePrintTimings
    /// How picked photos were fetched since launch; counts only.
    public let photoLoads: PhotoLoadStats
    /// Which model makes the prints and how far they are; nil when not gathered.
    public let recognition: RecognitionDiagnostics?

    /// `rawLogLines` are scrubbed here with `privateTerms` (see `privateTerms(in:)`) and paths removed.
    public init(environment: Environment, library: Library, rawLogLines: [String],
                privateTerms: [String], logUnavailableReason: String? = nil,
                featurePrint: FeaturePrintTimings = FeaturePrintTimings(), photoLoads: PhotoLoadStats = PhotoLoadStats(),
                recognition: RecognitionDiagnostics? = nil) {
        self.environment = environment
        self.featurePrint = featurePrint
        self.photoLoads = photoLoads
        self.recognition = recognition
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
            "App: Meowverse \(env.appVersion) (build \(env.build), \(env.configuration)\(env.channel.reportLabel.map { ", " + $0 } ?? ""))",
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
            Self.featurePrintLine(featurePrint),
            photoLoads.line,
        ].joined(separator: "\n") + (recognition.map { "\n" + $0.lines.joined(separator: "\n") } ?? "")
    }

    /// The app's own analyzer names; any other name is reported as "other", never as written.
    static let knownAnalyzers: Set<String> = ["vision.featurePrint", "vision.featurePrint.catCovered", "test.colorGrid",
                                              "dinov2.vitb14reg.int8.meanpatch"]

    /// e.g. "Feature print: median 142 ms over the last 20 (vision.featurePrint.catCovered)".
    public static func featurePrintLine(_ timings: FeaturePrintTimings) -> String {
        guard let median = timings.median else { return "Feature print: not timed yet" }
        let analyzer = timings.analyzer.flatMap { knownAnalyzers.contains($0) ? $0 : nil } ?? "other"
        return "Feature print: median \(Int(median.rounded())) ms over the last \(timings.count) (\(analyzer))"
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

    // MARK: Structured log messages

    /// One argument of a log entry as the log store hands it over.
    public enum LogArgument: Sendable, Equatable {
        /// An integer or floating-point value, already printed.
        case number(String)
        /// A string, data or object argument as the store printed it.
        case text(String)
        /// The store gave no value (redacted, or a kind it cannot print).
        case redacted
    }

    /// A string argument is kept only when it reads as a code: ASCII letters, digits and a few
    /// punctuation marks, no spaces, at most 64 characters (error codes, ids, enum names). Prose,
    /// error descriptions and anything a person typed fail this and become `<text>`.
    static let codePattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_.:()\[\]#=+\-/,@]{1,64}$"#)
    /// A printf-style placeholder as os_log writes them, `%%` included.
    static let placeholderPattern = try! NSRegularExpression(
        pattern: #"%(?:%|(\{[^}]*\})?[-+ #0-9.*']*(?:hh|h|ll|l|q|L|z|t|j)?[diouxXeEfFgGaAcsSpPmn@])"#)

    /// The message of one log entry, built from its fixed format string and an allow-list of its
    /// arguments instead of the store's composed text (R01-001): numbers stay, a string stays only
    /// when its placeholder is public and it reads as a code, private ones are `<private>` even
    /// when the store handed over the value, everything else is `<text>`. When the arguments do
    /// not line up with the placeholders, every placeholder becomes `<?>`. `arguments` may carry
    /// one extra trailing entry (the store's component for the closing text); it is ignored.
    public static func renderLogMessage(format: String, arguments: [LogArgument]) -> String {
        let ns = format as NSString
        let matches = placeholderPattern.matches(in: format, range: NSRange(location: 0, length: ns.length))
        let slots = matches.filter { ns.substring(with: $0.range) != "%%" }
        // The store hands over one component per placeholder, plus one for the text after the
        // last placeholder when there is any.
        let aligned = arguments.count == slots.count || arguments.count == slots.count + 1
        var out = "", cursor = 0, index = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let spec = ns.substring(with: match.range)
            if spec == "%%" { out += "%"; continue }
            defer { index += 1 }
            guard aligned else { out += "<?>"; continue }
            let privacy = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1))
            out += render(arguments[index], public: privacy.contains("public"), spec: spec)
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func render(_ argument: LogArgument, public isPublic: Bool, spec: String) -> String {
        switch argument {
        case .redacted: return "<private>"
        case .number(let value):
            // Swift's Logger writes numbers without a privacy word and makes them public; an
            // explicit private one stays private.
            return spec.contains("private") ? "<private>" : value
        case .text(let value):
            guard isPublic else { return "<private>" }
            let range = NSRange(value.startIndex..., in: value)
            return codePattern.firstMatch(in: value, range: range) != nil ? value : "<text>"
        }
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

    /// Every string in the library the user typed or that came from their files: every cat's
    /// and every room's name, furniture names, tags, notes and photo file names. Used to scrub log
    /// lines; the report itself never reads these fields. Only today's values are known here: a
    /// name changed earlier in the run is not, which is why log messages are rebuilt from their
    /// format and allow-listed arguments (`renderLogMessage`) before this scrubbing.
    public static func privateTerms(in state: AppState) -> [String] {
        let pieces = state.items + state.storage
        var terms = [state.catName]
        terms += state.allCats.map(\.name)
        terms += state.allRooms.compactMap(\.name)
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
    /// A multi-line term (a note) is also matched as it reads once a log line's newlines become
    /// spaces, and line by line.
    static func normalizedTerms(_ terms: [String]) -> [String] {
        let expanded = terms.flatMap { term -> [String] in
            let lines = term.components(separatedBy: .newlines)
            guard lines.count > 1 else { return [term] }
            return [term, lines.joined(separator: " ")] + lines
        }
        return Set(expanded.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
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
