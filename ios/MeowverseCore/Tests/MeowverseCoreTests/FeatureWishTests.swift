import Foundation
import Testing
@testable import MeowverseCore

/// 「我想要这个」: the mail holds what the user wrote and one version line, nothing else.
@Suite struct FeatureWishTests {
    static let version = FeatureWish.versionLine(appVersion: "0.1.0", build: "3", osVersion: "27.2")

    @Test func theVersionLineNamesTheAppAndTheSystem() {
        #expect(Self.version == "App 0.1.0 (3) · iOS 27.2")
    }

    @Test func theBodyHoldsBothAnswersThenTheVersion() {
        let message = FeatureWish.compose(wish: "  A cat bed by the window \n", context: "\nShe naps there every afternoon ",
                                          contextHeading: "When:", versionLine: Self.version)
        #expect(message.body == "A cat bed by the window\n\nWhen:\nShe naps there every afternoon\n\nApp 0.1.0 (3) · iOS 27.2")
        #expect(message.attachment == nil)
    }

    @Test func anEmptyContextIsLeftOut() {
        let message = FeatureWish.compose(wish: "Snow outside", context: " \n ", contextHeading: "When:", versionLine: Self.version)
        #expect(message.body == "Snow outside\n\nApp 0.1.0 (3) · iOS 27.2")
        #expect(!message.body.contains("When:"))
    }

    @Test func aWishNeedsSomethingWritten() {
        #expect(!FeatureWish.canCompose(""))
        #expect(!FeatureWish.canCompose("  \n\t "))
        #expect(FeatureWish.canCompose("x"))
    }

    /// The composer never sees the library: whatever names, notes and files it holds stay out.
    @Test func noDiagnosticsAndNoLibraryNamesReachTheMail() {
        let state = FeedbackReportTests.privateState()
        let message = FeatureWish.compose(wish: "More toys", context: "In the evening", contextHeading: "When:", versionLine: Self.version)
        for term in FeedbackReport.privateTerms(in: state) + FeedbackReportTests.privateStrings where term.count >= 2 {
            #expect(!message.body.localizedCaseInsensitiveContains(term), "leaked \(term)")
        }
        let report = FeedbackReportTests.report()
        for line in report.diagnosticsText.split(separator: "\n") where !line.isEmpty {
            #expect(!message.body.contains(line), "a diagnostics line: \(line)")
        }
        for marker in ["Diagnostics", "Device:", "Locale:", "Free disk", "Photos:", "Log"] {
            #expect(!message.body.contains(marker), "\(marker)")
        }
        #expect(message.attachment == nil)
    }
}
