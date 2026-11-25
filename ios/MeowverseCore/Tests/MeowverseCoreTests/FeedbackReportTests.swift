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
        .init(appVersion: "1.0", build: "3", configuration: "Debug", channel: .unknown, osVersion: "18.2",
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

    /// Which model is really in use, how many filed photos can be compared now, how far the
    /// backfill is, and what the last batch came to: counts and distances only, no photo id.
    @Test func recognitionLinesAreCountsAndDistancesOnly() throws {
        let nearest = RecognitionDiagnostics.BatchSummary(compared: 12, offers: 3, nearest: [0.9, 0.2, 0.5, 0.31])
        let first = RecognitionDiagnostics.Load(units: "all", loadMilliseconds: 4210, selfCheckMilliseconds: 7376,
                                                firstLoadOfBuild: true, selfCheck: "matches cpuOnly (d 0.0012)")
        let diagnostics = RecognitionDiagnostics(engine: .dino(first), filedReady: 140, filedTotal: 168,
                                                 backfill: (done: 150, total: 180), lastBatch: nearest, printsMade: 28, printsChecked: 140)
        let state = Self.privateState()
        let report = FeedbackReport(environment: Self.environment(), library: .init(state: state), rawLogLines: [],
                                    privateTerms: FeedbackReport.privateTerms(in: state), recognition: diagnostics)
        let text = report.summaryText
        #expect(text.contains("Recognition: DINOv2 loaded (units all, load 4210 ms, self-check 7376 ms, first load of this build, matches cpuOnly (d 0.0012))"))
        #expect(text.contains("Prints: 140 of 168 filed photos ready; backfill 150 / 180"))
        #expect(text.contains("Since launch: 28 prints made, 140 only checked"))
        #expect(text.contains("Last batch: 12 photos compared, 3 offers, nearest distance min 0.200, median 0.405"))

        let remembered = RecognitionDiagnostics.Load(units: "all", loadMilliseconds: 900, selfCheckMilliseconds: nil,
                                                     firstLoadOfBuild: false, selfCheck: "self-check remembered")
        #expect(RecognitionDiagnostics(engine: .dino(remembered), filedReady: 0, filedTotal: 0, backfill: nil, lastBatch: nil)
            .lines.first == "Recognition: DINOv2 loaded (units all, load 900 ms, self-check remembered)")
        let vision = RecognitionDiagnostics(engine: .visionAfterDinoFailed, filedReady: 0, filedTotal: 2, backfill: nil, lastBatch: nil)
        #expect(vision.lines == ["Recognition: Apple Vision (DINOv2 failed to load)",
                                 "Prints: 0 of 2 filed photos ready; backfill done",
                                 "Since launch: 0 prints made, 0 only checked",
                                 "Last batch: none this launch"])
        #expect(RecognitionDiagnostics(engine: .dinoLoading, filedReady: 0, filedTotal: 0, backfill: nil, lastBatch: nil)
            .lines.first == "Recognition: DINOv2 not loaded yet (loads with the first print)")
        let empty = RecognitionDiagnostics.BatchSummary(compared: 0, offers: 0, nearest: [])
        #expect(empty.line == "Last batch: 0 photos compared, 0 offers, nearest distance none")
        // The nearest filed photo of each candidate, from the prints themselves.
        let a = FeaturePrint(analyzer: "x", revision: 1, vector: [1, 0]), b = FeaturePrint(analyzer: "x", revision: 1, vector: [0, 1])
        let refs = [FurniturePhotoPrint(instanceId: "i", photoId: "r", print: a)]
        #expect(RecognitionDiagnostics.nearestDistances(of: ["q1": a, "q2": b], to: refs).sorted() == [0, 2])
    }

    /// One line with the device's print speed: a median, a count and which kind of print, all
    /// from a fixed alphabet, so nothing about a photo can ride along.
    @Test func printTimingIsOneLineOfNumbers() throws {
        var timings = FeaturePrintTimings()
        for ms in [151.4, 139.6, 2_000] { timings.record(milliseconds: ms, analyzer: "vision.featurePrint.catCovered") }
        let state = Self.privateState()
        let report = FeedbackReport(environment: Self.environment(), library: .init(state: state), rawLogLines: [],
                                    privateTerms: FeedbackReport.privateTerms(in: state), featurePrint: timings)
        let lines = report.summaryText.split(separator: "\n").filter { $0.hasPrefix("Feature print:") }
        #expect(lines == ["Feature print: median 151 ms over the last 3 (vision.featurePrint.catCovered)"])
        #expect(report.diagnosticsText.contains(lines[0]))

        let none = FeedbackReport(environment: Self.environment(), library: .init(state: .empty), rawLogLines: [], privateTerms: [])
        #expect(none.summaryText.contains("Feature print: not timed yet"))

        // Only the app's own analyzer names reach the text; anything else reads "other".
        var odd = FeaturePrintTimings()
        odd.record(milliseconds: 12, analyzer: "\(Self.userFolder)/\(Self.filename) \(Self.catName)\nnext")
        let line = FeedbackReport.featurePrintLine(odd)
        #expect(line == "Feature print: median 12 ms over the last 1 (other)")
        for analyzer in [VisionPhotoEmbedder(masking: .none).analyzer, VisionPhotoEmbedder(masking: .coverCat).analyzer,
                         ColorGridEmbedder().analyzer, KnownAnalyzer.dinoV2] {
            var known = FeaturePrintTimings()
            known.record(milliseconds: 1, analyzer: analyzer)
            #expect(FeedbackReport.featurePrintLine(known).hasSuffix("(\(analyzer))"))
        }
    }

    /// How photos were fetched: one line of counts from a fixed alphabet.
    @Test func photoRequestCountsAreOneLineOfNumbers() {
        var stats = PhotoLoadStats()
        stats.requested = 12
        stats.timedOut = 3
        stats.gaveUp = 1
        stats.failed = 2
        let report = FeedbackReport(environment: Self.environment(), library: .init(state: .empty), rawLogLines: [],
                                    privateTerms: [], photoLoads: stats)
        let lines = report.summaryText.split(separator: "\n").filter { $0.hasPrefix("Photo requests") }
        #expect(lines == ["Photo requests since launch: 12, timed out 3, given up 1, failed 2"])
        let none = FeedbackReport(environment: Self.environment(), library: .init(state: .empty), rawLogLines: [], privateTerms: [])
        #expect(none.summaryText.contains("Photo requests since launch: 0, timed out 0, given up 0, failed 0"))
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
