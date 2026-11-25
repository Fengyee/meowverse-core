import Foundation
import Testing
@testable import MeowverseCore

/// R01-001 / R01-002 (audit 2026-11-24): the report discloses only what it lists. Room and cat
/// names of every room and cat, multi-line notes, and any free text a log argument carries stay
/// out; the build channel says TestFlight only for a build that was archived as a test build.
@Suite struct FeedbackDisclosureTests {
    static let roomName = "Rosalinds Sunroom"
    static let secondCat = "Pumpernickel Marmot"
    static let thirdCat = "Zanzibar"
    static let noteFirst = "hid under Aunt Rosalind's bed"
    static let noteSecond = "found the vet letter"

    static func multiState() -> AppState {
        let note = "  \(noteFirst)\n\(noteSecond)  "
        let photo = PhotoRecord(photoId: "p1", filename: "a.heic", sha256: "abc", mimeType: "image/heic", byteSize: 10,
                                width: 1, height: 1, originalFile: "o", thumbnailFile: "t", captureDate: nil,
                                captureDateSource: .unknown, exifCaptureDate: nil,
                                importedAt: Date(timeIntervalSince1970: 0), favorite: false, note: note, revision: 1)
        return AppState(revision: 3, catName: "Kitty", photos: [photo], observations: [], items: [],
                        rooms: [Room(roomId: AppState.primaryRoomId), Room(roomId: "room-2", name: roomName)],
                        cats: [Cat(catId: AppState.primaryCatId, name: "Kitty"), Cat(catId: "cat-2", name: secondCat),
                               Cat(catId: "cat-3", name: thirdCat, roomId: "room-2")])
    }

    @Test func everyRoomCatAndNoteLineIsScrubbed() {
        let state = Self.multiState()
        let log = ["room: entered \(Self.roomName)",
                   "cat: \(Self.secondCat.uppercased()) and \(Self.thirdCat) napped",
                   // A logger that flattened the note's newline to a space.
                   "photos: note=\(Self.noteFirst) \(Self.noteSecond)",
                   "photos: second line only: \(Self.noteSecond)"]
        let report = FeedbackReport(environment: FeedbackReportTests.environment(), library: .init(state: state),
                                    rawLogLines: log, privateTerms: FeedbackReport.privateTerms(in: state))
        for secret in [Self.roomName, Self.secondCat, Self.thirdCat, Self.noteFirst, Self.noteSecond, "Rosalind"] {
            #expect(!report.diagnosticsText.localizedCaseInsensitiveContains(secret), "leaked \(secret)")
        }
        // Raw form: the scrubbed lines really were rewritten, not just absent.
        #expect(report.logLines.allSatisfy { $0.contains("<redacted>") })
    }

    // MARK: Structured log messages

    @Test func numbersAndCodesStayFreeTextDoesNot() {
        let line = FeedbackReport.renderLogMessage(
            format: "rename failed: %{public}s instance=%{public}s rev=%{public}ld size=%{public}.1f %%",
            arguments: [.text("io(4)"), .text("3F2A-11"), .number("17"), .number("2.5")])
        #expect(line == "rename failed: io(4) instance=3F2A-11 rev=17 size=2.5 %")

        // Error descriptions carry file names in prose; anything with spaces or non-ASCII is not a code.
        let prose = FeedbackReport.renderLogMessage(
            format: "import failed: %{public}@ / %{public}s",
            arguments: [.text("The file “IMG_Rosalind.HEIC” couldn’t be opened."), .text("找不到文件 小橘")])
        #expect(prose == "import failed: <text> / <text>")
        #expect(!prose.contains("Rosalind"))
    }

    @Test func privateArgumentsNeverAppearEvenIfTheStoreHandsThemOver() {
        // Under a debugger the store may return the real value of a private argument.
        let line = FeedbackReport.renderLogMessage(format: "cat name set to %{private}s, default %s, hashed %{private, mask.hash}s",
                                                   arguments: [.text("Zanzibar"), .text("Kitty"), .text("Mochi")])
        #expect(line == "cat name set to <private>, default <private>, hashed <private>")
        #expect(FeedbackReport.renderLogMessage(format: "x %{public}s", arguments: [.redacted]) == "x <private>")
    }

    @Test func aFormatThatDoesNotMatchItsArgumentsKeepsOnlyTheFixedText() {
        let line = FeedbackReport.renderLogMessage(format: "a %{public}s b %{public}ld", arguments: [.text("Zanzibar")])
        #expect(line == "a <?> b <?>")
        // The store's extra component for the text after the last placeholder is not an argument.
        #expect(FeedbackReport.renderLogMessage(format: "a %{public}s b", arguments: [.text("ok"), .redacted]) == "a ok b")
    }

    // MARK: Build channel (R01-002)

    @Test func onlyAnArchivedTestBuildReadsAsTestFlight() {
        #expect(TestBuildNotice.channel(switchValue: "YES", receiptFileName: "sandboxReceipt", receiptExists: true) == .testFlight)
        // The App Store archive is also what App Review installs, with the same sandbox receipt.
        #expect(TestBuildNotice.channel(switchValue: "NO", receiptFileName: "sandboxReceipt", receiptExists: true) == .sandbox)
        #expect(TestBuildNotice.channel(switchValue: nil, receiptFileName: "receipt", receiptExists: true) == .appStore)
        #expect(TestBuildNotice.channel(switchValue: "YES", receiptFileName: "receipt", receiptExists: true) == .appStore)
        // No receipt on disk: a development install; say nothing rather than guess.
        #expect(TestBuildNotice.channel(switchValue: "NO", receiptFileName: "receipt", receiptExists: false) == .unknown)
        #expect(TestBuildNotice.channel(switchValue: "YES", receiptFileName: nil, receiptExists: false) == .unknown)
    }

    @Test func theSummaryNamesTheChannelWithoutCallingAReviewBuildTestFlight() {
        func app(_ channel: BuildChannel) -> String {
            var env = FeedbackReportTests.environment()
            env.channel = channel
            let report = FeedbackReport(environment: env, library: .init(state: .empty), rawLogLines: [], privateTerms: [])
            return String(report.summaryText.split(separator: "\n")[0])
        }
        #expect(app(.testFlight) == "App: Meowverse 1.0 (build 3, Debug, TestFlight)")
        #expect(app(.sandbox) == "App: Meowverse 1.0 (build 3, Debug, sandbox receipt)")
        #expect(app(.appStore) == "App: Meowverse 1.0 (build 3, Debug, App Store)")
        #expect(app(.unknown) == "App: Meowverse 1.0 (build 3, Debug)")
        #expect(!app(.sandbox).contains("TestFlight"))
    }
}
