import Testing
@testable import MeowverseCore

// 「关于测试版」 needs the build's own switch on as well as a sandbox receipt: App Review installs
// carry a sandbox receipt too, so the receipt alone showed the page to the reviewer of a store build.

@Suite struct TestBuildNoticeTests {
    @Test func aTestFlightBuildWithTheSwitchOnShowsThePage() {
        #expect(TestBuildNotice.shows(switchValue: "YES", receiptFileName: "sandboxReceipt"))
    }

    @Test func aStoreBuildUnderReviewDoesNotShowItThoughItsReceiptIsSandbox() {
        #expect(!TestBuildNotice.shows(switchValue: "NO", receiptFileName: "sandboxReceipt"))
    }

    @Test func theSwitchAloneIsNotEnoughOnAnAppStoreInstall() {
        #expect(!TestBuildNotice.shows(switchValue: "YES", receiptFileName: "receipt"))
        #expect(!TestBuildNotice.shows(switchValue: "YES", receiptFileName: nil))
    }

    @Test(arguments: [nil, "", "no", "0", "false", "$(MEOWVERSE_TEST_BUILD_NOTICE)", "maybe"] as [String?])
    func anythingButAYesIsOff(_ value: String?) {
        #expect(!TestBuildNotice.switchedOn(value))
        #expect(!TestBuildNotice.shows(switchValue: value, receiptFileName: "sandboxReceipt"))
    }

    @Test func yesReadsAsOnInAnyCaseAndAsABoolean() {
        #expect(TestBuildNotice.switchedOn("YES"))
        #expect(TestBuildNotice.switchedOn("yes"))
        #expect(TestBuildNotice.switchedOn(true))
        #expect(!TestBuildNotice.switchedOn(false))
    }

    @Test func theInfoPlistKeyIsTheOneTheBuildWrites() {
        #expect(TestBuildNotice.infoKey == "MeowverseShowsTestBuildNotice")
    }
}

// When: once, after the opening (owner). Only the opening's chapters are waited for; the chapters
// on demand may stay open for weeks. Since T5 the catalog has 15 chapters, and waiting for all of
// them kept the page from ever coming after the opening (QA_EN).
@Suite struct TestBuildNoticeTimingTests {
    private func record(opening: TourOutcome?, except open: TourChapterID? = nil,
                        others: [TourChapterID: TourOutcome] = [:]) -> TourRecord {
        var record = TourRecord()
        if let opening {
            for chapter in TourCatalog.thisBuild.opening where chapter.id != open {
                record.chapters[chapter.id.rawValue] = TourEntry(outcome: opening, revision: chapter.revision)
            }
        }
        for (id, outcome) in others { record.chapters[id.rawValue] = TourEntry(outcome: outcome, revision: 1) }
        return record
    }

    @Test func dueOnceTheOpeningHasEndedThoughTheOtherChaptersHaveNot() {
        let catalog = TourCatalog.thisBuild
        #expect(catalog.chapters.count > catalog.opening.count, "chapters on demand are told in this build")
        #expect(TestBuildNotice.openingIsOver(catalog, record: record(opening: .completed)))
    }

    @Test func dueAfterSkipAll() {
        var all = TourRecord()
        for chapter in TourCatalog.thisBuild.chapters {
            all.chapters[chapter.id.rawValue] = TourEntry(outcome: .skippedAll, revision: chapter.revision)
        }
        #expect(TestBuildNotice.openingIsOver(.thisBuild, record: all))
        // Skipped all from the second chapter on: the first was read.
        #expect(TestBuildNotice.openingIsOver(.thisBuild, record: record(opening: .skippedAll, others: [.welcome: .completed])))
    }

    @Test func dueForAHomeWhoseOpeningWasWaived() {
        #expect(TestBuildNotice.openingIsOver(.thisBuild, record: record(opening: .grandfathered)))
    }

    @Test func notWhileAnOpeningChapterIsStillToCome() {
        #expect(!TestBuildNotice.openingIsOver(.thisBuild, record: TourRecord()))
        #expect(!TestBuildNotice.openingIsOver(.thisBuild, record: record(opening: .completed, except: .topRow,
                                                                          others: [.memories: .completed])))
    }

    @Test func notForACatalogWithNoOpening() {
        let none = TourCatalog(chapters: TourCatalog.thisBuild.chapters.filter { $0.kind != .opening })
        #expect(!TestBuildNotice.openingIsOver(none, record: TourRecord()))
    }
}
