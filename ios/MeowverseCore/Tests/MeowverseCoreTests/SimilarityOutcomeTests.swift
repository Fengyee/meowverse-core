import Testing
@testable import MeowverseCore

/// IMPORT-2: "nothing looks like it" needs a comparison that finished; a failed one says so.
@Suite struct SimilarityOutcomeTests {
    private func print(_ values: [Float], analyzer: String = "a") -> FeaturePrint {
        FeaturePrint(analyzer: analyzer, revision: 1, vector: values)
    }

    private func reference(_ photo: String, _ made: FeaturePrint, piece: String = "sofa") -> FurniturePhotoPrint {
        FurniturePhotoPrint(instanceId: piece, photoId: photo, print: made)
    }

    private var query: FeaturePrint { print([1, 0]) }

    @Test func noFurniturePhotosMeansNothingWasCompared() {
        #expect(SimilarityOutcome(query: query, against: [], expected: []) == .nothingToCompare)
        #expect(SimilarityOutcome(query: nil, against: [], expected: []) == .nothingToCompare)
    }

    @Test func thePhotosOwnPrintFailingIsAFailure() {
        #expect(SimilarityOutcome(query: nil, against: [reference("p", query)], expected: ["p"]) == .failed)
    }

    @Test func noReferencePrintIsAFailure() {
        #expect(SimilarityOutcome(query: query, against: [], expected: ["p"]) == .failed)
    }

    @Test func printsMadeByAnotherAnalyzerAreNotAComparison() {
        let other = reference("p", print([1, 0], analyzer: "b"))
        #expect(SimilarityOutcome(query: query, against: [other], expected: ["p"]) == .failed)
    }

    @Test func aPrintWithoutAFiniteDistanceIsNotAComparison() {
        #expect(SimilarityOutcome(query: query, against: [reference("p", print([.nan, 0]))], expected: ["p"]) == .failed)
    }

    @Test func aMissingOrUnusableReferenceMakesItPartial() {
        let good = reference("p", query)
        #expect(SimilarityOutcome(query: query, against: [good], expected: ["p", "q"]) == .compared(complete: false))
        let stale = reference("q", print([0, 1], analyzer: "b"))
        #expect(SimilarityOutcome(query: query, against: [good, stale], expected: ["p", "q"]) == .compared(complete: false))
    }

    /// One photo in two pieces is one photo compared, and cannot stand in for a missing one.
    @Test func aPhotoInTwoPiecesCountsOnce() {
        let twice = [reference("p", query), reference("p", query, piece: "bed")]
        #expect(SimilarityOutcome(query: query, against: twice, expected: ["p", "q"]) == .compared(complete: false))
    }

    @Test func farFromEverythingIsAFinishedComparison() {
        let far = [reference("p", print([0, 1])), reference("q", print([-1, 0]))]
        #expect(SimilarFurniture.suggest(query, against: far).isEmpty)
        #expect(SimilarityOutcome(query: query, against: far, expected: ["p", "q"]) == .compared(complete: true))
    }
}
