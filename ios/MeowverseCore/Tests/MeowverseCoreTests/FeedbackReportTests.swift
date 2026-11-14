import Foundation
import Testing
@testable import MeowverseCore

/// The bug-report diagnostics: counts and environment only, and nothing the user typed or
/// that names their files, even when the log mentions it.
@Suite struct FeedbackReportTests {
    // Recognisable private strings; none of them may appear anywhere in a report.
    static let catName = "Quokkamarmalade"
    static let furnitureName = "Grandmas Velvet Throne"
    static let storedName = "Attic Zebra Shelf"
    static let tag = "secret-tag-umbrella"
    static let note = "Bella hid under Aunt Rosalind's bed"
    static let filename = "IMG_Rosalind_Birthday.HEIC"
    static let originalFile = "originals/hidden-original-name.heic"
    static let thumbnailFile = "thumbnails/hidden-thumb-name.jpg"
    static let captureDay = "2019-04-07"
    static let userFolder = "/Users/rosalind/Documents/CatStuff"

    static let privateStrings = [catName, furnitureName, storedName, tag, note, filename, "IMG_Rosalind_Birthday",
                                 originalFile, thumbnailFile, "hidden-original-name", "hidden-thumb-name",
                                 captureDay, userFolder, "rosalind", "Rosalind"]

    static func piece(_ id: String, name: String, tags: [String] = []) -> PhotoFurniture {
        PhotoFurniture(instanceId: id, modelId: "kenney-chair", x: 0, z: 0, width: 1, depth: 1, turn: 0,
                       finish: .original, displayName: name, sources: [.manual(photoId: "p1")],
                       tags: tags, revision: 1)
    }

    static func privateState() -> AppState {
        let photo = PhotoRecord(photoId: "p1", filename: filename, sha256: "abc", mimeType: "image/heic", byteSize: 10,
                                width: 1, height: 1, originalFile: originalFile, thumbnailFile: thumbnailFile,
                                captureDate: captureDay, captureDateSource: .exif, exifCaptureDate: captureDay,
                                importedAt: Date(timeIntervalSince1970: 0), favorite: true, note: note, revision: 2)
        return AppState(revision: 17, catName: catName, photos: [photo], observations: [],
                        items: [piece("i1", name: furnitureName, tags: [tag]), piece("i2", name: "Box")],
                        storage: [piece("s1", name: storedName)])
    }

    static func environment(freeDisk: Int64? = 12_345_678_901) -> FeedbackReport.Environment {
        .init(appVersion: "1.0", build: "3", configuration: "Debug", testFlight: false, osVersion: "18.2",
              deviceModel: "iPhone17,1", locale: "zh_CN", textSize: "UICTContentSizeCategoryL",
              reduceMotion: true, voiceOver: false, freeDiskBytes: freeDisk)
    }

    /// Log lines as a careless future logger might write them.
    static let leakyLog = [
        "store: load: primary rev=17 photos=1 items=2",
        "store: rename: instance=i1 to \(furnitureName)",
        "store: cat name set to \(catName.lowercased())",
        "import: read \(filename) from \(userFolder)/\(filename)",
        "art: failed at file:///var/mobile/Containers/Data/Application/ABC/Library/Meowverse/x.usdz",
        "photos: note=\(note)\nsecond line with tag \(tag)",
    ]

    static func report() -> FeedbackReport {
        let state = privateState()
        return FeedbackReport(environment: environment(), library: .init(state: state), rawLogLines: leakyLog,
                              privateTerms: FeedbackReport.privateTerms(in: state))
    }

    @Test func diagnosticsCarryVersionsAndCounts() {
        let text = Self.report().diagnosticsText
        for expected in ["App: Meowverse 1.0 (build 3, Debug)", "iOS: 18.2", "Device: iPhone17,1", "Locale: zh_CN",
                         "Text size: UICTContentSizeCategoryL", "Reduce Motion: on", "VoiceOver: off",
                         "Free disk: 10-50 GB", "Photos: 1", "Furniture in room: 2", "Furniture in storage: 1",
                         "Library schema: \(AppState.currentSchemaVersion)", "Library revision: 17",
                         "Log (last 6 entries):", "store: load: primary rev=17 photos=1 items=2"] {
            #expect(text.contains(expected), "missing \(expected)")
        }
    }

    /// The redaction check: a state full of recognisable private strings, a log that names
    /// them, and none of them survive into anything a mail could carry.
    @Test func noPrivateStringReachesAnyOutput() {
        let report = Self.report()
        let outputs = [report.diagnosticsText, report.summaryText,
                       FeedbackMessage.compose(description: "", report: report).body,
                       FeedbackMessage.mailLinkBody(description: "", report: report),
                       FeedbackMessage.plainText(description: "", report: report)]
        for output in outputs {
            for secret in Self.privateStrings {
                #expect(!output.localizedCaseInsensitiveContains(secret), "leaked \(secret)")
            }
        }
        #expect(report.diagnosticsText.contains("<redacted>"))
        #expect(report.diagnosticsText.contains("<path>"))
        // A multi-line message stays one line in the report.
        #expect(report.logLines.allSatisfy { !$0.contains("\n") })
    }

    @Test func pathsAreRemovedAndLongLinesCut() {
        let scrubbed = FeedbackReport.scrub("open /private/var/x y ~/Desktop/z", privateTerms: [])
        #expect(scrubbed == "open <path> y <path>")
        let long = FeedbackReport.scrub(String(repeating: "a", count: 1_000), privateTerms: [])
        #expect(long.count == FeedbackReport.maxLogLineLength + 1)
    }

    @Test func singleCharacterTermsDoNotShredTheLog() {
        #expect(FeedbackReport.scrub("rev=3 items=2", privateTerms: ["e", " ", ""]) == "rev=3 items=2")
    }

    @Test func onlyTheNewestLogLinesAreKept() {
        let lines = (0..<500).map { "line \($0)" }
        let report = FeedbackReport(environment: Self.environment(), library: .init(state: .empty),
                                    rawLogLines: lines, privateTerms: [])
        #expect(report.logLines.count == FeedbackReport.maxLogLines)
        #expect(report.logLines.last == "line 499")
        #expect(report.logLines.first == "line 300")
    }

    @Test func diskIsBucketed() {
        #expect(FeedbackReport.diskBucket(nil) == "unknown")
        #expect(FeedbackReport.diskBucket(100_000_000) == "under 0.5 GB")
        #expect(FeedbackReport.diskBucket(1_000_000_000) == "0.5-2 GB")
        #expect(FeedbackReport.diskBucket(5_000_000_000) == "2-10 GB")
        #expect(FeedbackReport.diskBucket(200_000_000_000) == "50 GB or more")
        #expect(!Self.report().diagnosticsText.contains("12345678901"))
    }

    @Test func unreadableAndEmptyLogsAreSaidSo() {
        let none = FeedbackReport(environment: Self.environment(), library: .init(state: .empty), rawLogLines: [], privateTerms: [])
        #expect(none.diagnosticsText.hasSuffix("Log: no entries"))
        let failed = FeedbackReport(environment: Self.environment(), library: .init(state: .empty), rawLogLines: [],
                                    privateTerms: [], logUnavailableReason: "permission")
        #expect(failed.diagnosticsText.hasSuffix("Log: unavailable (permission)"))
    }

    @Test func shortDiagnosticsGoInTheBodyLongOnesAreAttached() {
        let short = FeedbackMessage.compose(description: "  It crashed.  ", report: Self.report())
        #expect(short.body.hasPrefix("It crashed.\n\n---- Diagnostics ----\nApp: Meowverse 1.0"))
        #expect(short.attachment == nil)

        let long = FeedbackReport(environment: Self.environment(), library: .init(state: .empty),
                                  rawLogLines: (0..<200).map { "store: entry number \($0) with some detail" }, privateTerms: [])
        let message = FeedbackMessage.compose(description: "It crashed.", report: long)
        #expect(message.attachment == long.diagnosticsText)
        #expect(message.body.contains("Photos: 0"))
        #expect(!message.body.contains("entry number"))
        #expect(message.body.contains("attached as diagnostics.txt"))
    }

    @Test func withoutDiagnosticsOnlyTheDescriptionIsSent() {
        #expect(FeedbackMessage.compose(description: "Hi", report: nil) == FeedbackMessage(body: "Hi", attachment: nil))
        #expect(FeedbackMessage.mailLinkBody(description: "Hi", report: nil) == "Hi")
    }

    @Test func emptyDescriptionStartsWithTheDiagnostics() {
        #expect(FeedbackMessage.compose(description: "", report: Self.report()).body.hasPrefix("---- Diagnostics ----\nApp:"))
    }

    @Test func mailLinkLeavesALongLogOut() {
        let long = FeedbackReport(environment: Self.environment(), library: .init(state: .empty),
                                  rawLogLines: (0..<200).map { "store: entry \($0)" }, privateTerms: [])
        let body = FeedbackMessage.mailLinkBody(description: "x", report: long)
        #expect(!body.contains("entry 199"))
        #expect(body.contains("left out of the mail link"))
        #expect(body.count < FeedbackMessage.mailLinkLimit)
    }
}
