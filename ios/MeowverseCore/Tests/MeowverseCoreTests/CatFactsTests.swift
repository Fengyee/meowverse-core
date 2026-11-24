import Foundation
import Testing
@testable import MeowverseCore

/// The cat facts the app ships: every one has both languages, and only facts whose source was
/// opened and checked (docs/CAT_FACTS_SOURCES.md) are in the rotation.
///
/// The strings table (app target) and the sources table (docs) live outside this package. The
/// public meowverse-core repository has neither, so those checks are skipped there. Whether they
/// run depends on the repository (the app project beside the package), not on the files: in the
/// private repository a moved or missing table fails.
@Suite struct CatFactsTests {
    /// ios/
    static let iosFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let stringsTable = iosFolder.appendingPathComponent("Meowverse/CatFacts.xcstrings")
    static let sourcesTable = iosFolder.deletingLastPathComponent().appendingPathComponent("docs/CAT_FACTS_SOURCES.md")
    /// ios/Meowverse.xcodeproj: only the private repository has the app.
    static let isPrivateRepository = FileManager.default.fileExists(atPath: iosFolder.appendingPathComponent("Meowverse.xcodeproj").path)

    @Test func idsAreStableUniqueAndNamespaced() {
        #expect(CatFacts.all.count == 20)
        #expect(Set(CatFacts.all).count == CatFacts.all.count)
        for id in CatFacts.all {
            #expect(id.range(of: #"^fact\.[a-z]+(-[a-z]+)*$"#, options: .regularExpression) != nil, "\(id)")
        }
    }

    @Test func theRotationIsTheCheckedFactsInDraftOrder() {
        #expect(CatFacts.verified.isSubset(of: Set(CatFacts.all)), "a checked id with no text")
        #expect(CatFacts.rotation == CatFacts.all.filter(CatFacts.verified.contains))
    }

    @Test(.enabled(if: CatFactsTests.isPrivateRepository,
                   "no ios/Meowverse.xcodeproj: package-only copy (meowverse-core) without the app's CatFacts.xcstrings"))
    func everyFactHasChineseAndEnglishText() throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.stringsTable)) as? [String: Any]
        #expect(json?["sourceLanguage"] as? String == "zh-Hans")
        let strings = try #require(json?["strings"] as? [String: [String: Any]])
        #expect(Set(strings.keys) == Set(CatFacts.all), "the table and CatFacts.all list the same ids")
        let han = try NSRegularExpression(pattern: "[\u{3400}-\u{9FFF}]")
        for id in CatFacts.all {
            let entry = try #require(strings[id], "\(id) is missing from CatFacts.xcstrings")
            #expect(entry["extractionState"] as? String == "manual", "\(id): keys are not in the source, so Xcode must not mark them stale")
            let localizations = entry["localizations"] as? [String: [String: [String: String]]]
            for language in ["zh-Hans", "en"] {
                let unit = localizations?[language]?["stringUnit"]
                #expect(unit?["state"] == "translated", "\(id) \(language)")
                let text = unit?["value"] ?? ""
                #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(id) \(language) is empty")
                #expect(!text.contains("%"), "\(id) \(language): shown verbatim, no format specifiers")
                let hasHan = han.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                #expect(hasHan == (language == "zh-Hans"), "\(id) \(language) is in the wrong language")
            }
        }
    }

    struct SourceRow {
        let id: String
        let organisation: String
        let pageTitle: String
        let links: [String]
        let accessed: String
        let checkerRole: String
        let checked: String

        static let day = #"^\d{4}-\d{2}-\d{2}$"#

        /// A link, a visit date, a role and a check date: the fact may be sent.
        var isChecked: Bool {
            !links.isEmpty && !organisation.isEmpty && !pageTitle.isEmpty && accessed.range(of: Self.day, options: .regularExpression) != nil
                && !checkerRole.isEmpty && checkerRole != "—" && checked.range(of: Self.day, options: .regularExpression) != nil
        }
    }

    static func sourceRows() throws -> [SourceRow] {
        let text = try String(contentsOf: sourcesTable, encoding: .utf8)
        // Only the table under "## 来源表"; later sections may list the ids again.
        let section = text.components(separatedBy: "\n## 来源表\n").dropFirst().first?.components(separatedBy: "\n## ").first ?? ""
        let link = try NSRegularExpression(pattern: #"https://[^\s<>()|\]]+"#)
        return section.split(separator: "\n").compactMap { line -> SourceRow? in
            guard line.hasPrefix("| `fact.") else { return nil }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // id | 机构 | 页面标题 | 链接 | 访问日期 | 核对角色 | 核对日期
            guard cells.count == 7 else {
                return SourceRow(id: "malformed: \(line)", organisation: "", pageTitle: "", links: [], accessed: "", checkerRole: "", checked: "")
            }
            let links = link.matches(in: cells[3], range: NSRange(cells[3].startIndex..., in: cells[3]))
                .compactMap { Range($0.range, in: cells[3]).map { String(cells[3][$0]) } }
            return SourceRow(id: cells[0].trimmingCharacters(in: CharacterSet(charactersIn: "`")), organisation: cells[1],
                             pageTitle: cells[2], links: links, accessed: cells[4], checkerRole: cells[5], checked: cells[6])
        }
    }

    @Test(.enabled(if: CatFactsTests.isPrivateRepository,
                   "no ios/Meowverse.xcodeproj: package-only copy (meowverse-core) without docs/CAT_FACTS_SOURCES.md"))
    func theSourcesTableHasOneRowPerFact() throws {
        let rows = try Self.sourceRows()
        #expect(rows.map(\.id).sorted() == CatFacts.all.sorted())
    }

    @Test(.enabled(if: CatFactsTests.isPrivateRepository,
                   "no ios/Meowverse.xcodeproj: package-only copy (meowverse-core) without docs/CAT_FACTS_SOURCES.md"))
    func onlyFactsWithACheckedSourceAreSent() throws {
        let checked = Set(try Self.sourceRows().filter(\.isChecked).map(\.id))
        #expect(CatFacts.verified == checked,
                "CatFacts.verified must list exactly the rows of docs/CAT_FACTS_SOURCES.md with a link, visit date, role and check date")
    }
}
