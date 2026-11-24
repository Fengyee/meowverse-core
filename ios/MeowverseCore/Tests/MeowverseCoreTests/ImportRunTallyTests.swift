import Testing
@testable import MeowverseCore

/// The one progress the system shows while photo imports carry on in the background.
@Suite struct ImportRunTallyTests {
    @Test func oneImportCountsItsPhotos() {
        var tally = ImportRunTally()
        #expect(!tally.isRunning)
        tally.update(.batch, .init(shown: 0, total: 30))
        #expect(tally.isRunning)
        #expect(tally.completed == 0 && tally.total == 30)
        tally.update(.batch, .init(shown: 12, total: 30))
        #expect(tally.completed == 12 && tally.total == 30)
        tally.update(.batch, nil)
        #expect(!tally.isRunning)
    }

    /// A failed save, photos that never arrived and 停止 all end a run short of its total
    /// (JOURNEY-NEW-3): the system's progress keeps that count and is no success.
    @Test func aRunThatStopsShortIsNotASuccess() {
        var tally = ImportRunTally()
        tally.update(.batch, .init(shown: 0, total: 50))
        tally.update(.batch, .init(shown: 22, total: 50))
        tally.update(.batch, nil)
        #expect(tally.ending(expired: false) == .init(completed: 22, total: 50, success: false))
    }

    @Test func aRunThatGotThroughEveryPhotoIsASuccess() {
        var tally = ImportRunTally()
        tally.update(.batch, .init(shown: 30, total: 30))
        tally.update(.batch, nil)
        #expect(tally.ending(expired: false) == .init(completed: 30, total: 30, success: true))
        #expect(!tally.ending(expired: true).success)
    }

    /// The bar drops what an ended import didn't reach; the ending doesn't.
    @Test func oneImportShortMakesTheSharedRunShort() {
        var tally = ImportRunTally()
        tally.update(.batch, .init(shown: 12, total: 30))
        tally.update(.adding, .init(shown: 0, total: 3))
        tally.update(.batch, nil)
        tally.update(.adding, .init(shown: 3, total: 3))
        tally.update(.adding, nil)
        #expect(tally.ending(expired: false) == .init(completed: 15, total: 33, success: false))
    }

    /// A photo-by-photo count never claims more than the import holds.
    @Test func shownIsCappedByTheTotal() {
        var tally = ImportRunTally()
        tally.update(.adding, .init(shown: 5, total: 3))
        #expect(tally.completed == 3 && tally.total == 3)
    }

    /// Two imports at once share one bar. When the first finishes its photos stay counted as
    /// done: the bar neither jumps back nor loses its total under the user.
    @Test func overlappingImportsShareOneBar() {
        var tally = ImportRunTally()
        tally.update(.batch, .init(shown: 0, total: 30))
        tally.update(.adding, .init(shown: 0, total: 3))
        #expect(tally.completed == 0 && tally.total == 33)
        tally.update(.batch, .init(shown: 30, total: 30))
        tally.update(.adding, .init(shown: 1, total: 3))
        tally.update(.batch, nil)
        #expect(tally.isRunning)
        #expect(tally.completed == 31 && tally.total == 33)
        tally.update(.adding, .init(shown: 3, total: 3))
        #expect(tally.completed == 33)
        tally.update(.adding, nil)
        #expect(!tally.isRunning)
    }

    /// An import stopped half way keeps only what it got through: the rest is not counted as
    /// done, so the bar does not pretend those photos arrived.
    @Test func aStoppedImportKeepsOnlyWhatItGotThrough() {
        var tally = ImportRunTally()
        tally.update(.batch, .init(shown: 10, total: 30))
        tally.update(.adding, .init(shown: 0, total: 3))
        tally.update(.batch, nil)
        #expect(tally.completed == 10 && tally.total == 13)
    }

    /// Once nothing runs, the next import starts a fresh count.
    @Test func theNextRunStartsFromZero() {
        var tally = ImportRunTally()
        tally.update(.batch, .init(shown: 4, total: 4))
        tally.update(.batch, nil)
        tally.update(.adding, .init(shown: 0, total: 2))
        #expect(tally.completed == 0 && tally.total == 2)
    }

    /// Ending an import that never reported changes nothing.
    @Test func endingAnUnknownImportIsHarmless() {
        var tally = ImportRunTally()
        tally.update(.adding, nil)
        #expect(!tally.isRunning && tally.completed == 0 && tally.total == 0)
    }
}
