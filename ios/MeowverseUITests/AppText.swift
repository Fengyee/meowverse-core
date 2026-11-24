import XCTest

extension TestLanguage {
    /// `TEST_RUNNER_MV_LANG=en` runs a language-independent test in English; Chinese otherwise.
    static var isEnglish: Bool { ProcessInfo.processInfo.environment["MV_LANG"] == "en" }
    static var current: [String] { isEnglish ? english : chinese }
}

/// The words the app shows, read from its compiled string tables. A test names the key the app
/// uses (for most of the app that is the Chinese text), so one assertion holds in both languages
/// and follows a change of the translation.
///
/// Prefer an accessibility identifier to find an element; use this to check what it says.
/// The app's `Localizable` and `Tour` catalogs are compiled into this test bundle too (the same
/// files, through the Meowverse folder's target exceptions), so these work on a phone as well.
/// Any other table is read from the built app, which only a simulator's runner can see: to use
/// one on a phone, add its catalog to those exceptions.
enum AppText {
    private final class InTestBundle {}
    private static let tests = Bundle(for: InTestBundle.self)
    private static let app: Bundle? = {
        let folders = ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] ?? ""
        return folders.split(separator: ":").lazy.compactMap { Bundle(path: "\($0)/Meowverse.app") }.first
    }()

    /// The text of `key` in the language of the run, with `arguments` in its placeholders.
    static func string(_ key: String, table: String = "Localizable", _ arguments: CVarArg...,
                       file: StaticString = #filePath, line: UInt = #line) -> String {
        let format = value(of: key, table: table, file: file, line: line)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: TestLanguage.isEnglish ? "en_US" : "zh_CN"), arguments: arguments)
    }

    /// A regular expression for the whole text of `key`, for a line whose arguments the test does
    /// not know: every fixed word must be there, each placeholder stands for one or more characters.
    static func pattern(_ key: String, table: String = "Localizable",
                        file: StaticString = #filePath, line: UInt = #line) -> String {
        var rest = value(of: key, table: table, file: file, line: line)[...]
        var pattern = ""
        while let placeholder = rest.range(of: #"%(\d+\$)?(@|l{0,2}d|#@\w+@)"#, options: .regularExpression) {
            pattern += NSRegularExpression.escapedPattern(for: String(rest[..<placeholder.lowerBound])) + ".+"
            rest = rest[placeholder.upperBound...]
        }
        return pattern + NSRegularExpression.escapedPattern(for: String(rest))
    }

    private static func value(of key: String, table: String, file: StaticString, line: UInt) -> String {
        let missing = "\u{0}missing"
        let bundled = tests.path(forResource: table, ofType: "strings", inDirectory: nil, forLocalization: "en") != nil
        let source = bundled ? tests : app
        // A key that is the Chinese text has no entry of its own in zh-Hans, and every key has
        // an English one: that is where a renamed or mistyped key shows.
        guard let source,
              let english = localization("en", in: source),
              english.localizedString(forKey: key, value: missing, table: table) != missing,
              let shown = TestLanguage.isEnglish ? english : localization("zh-Hans", in: source)
        else {
            XCTFail("no text “\(key)” in \(table) (read from: \(source?.bundlePath ?? "nothing, the table is not in the test bundle"))",
                    file: file, line: line)
            // Never a string that some label could match by accident.
            return missing
        }
        return shown.localizedString(forKey: key, value: key, table: table)
    }

    private static func localization(_ name: String, in bundle: Bundle) -> Bundle? {
        bundle.path(forResource: name, ofType: "lproj").flatMap { Bundle(path: $0) }
    }
}
