import Foundation
import Testing
@testable import MeowverseCore

@Suite struct CandidateReviewTests {
    let result = RecognitionResult(analyzer: "t", analyzerRevision: 1, objects: [
        ObservedObject(kind: .sofa, label: "sofa", confidence: 0.8),
        ObservedObject(kind: .chair, label: "armchair", confidence: 0.4),
    ], catLikely: true)

    @Test func suggestionPreselectedWhenNothingChosen() {
        var review = CandidateReview()
        let token = review.beginAnalysis()
        #expect(review.isAnalyzing)
        review.receive(result, token: token)
        #expect(review.selectedCategory == .sofa)
        #expect(review.selectionOrigin == .suggested(objectIndex: 0))
        #expect(review.sourceDecision == SourceDecision(recognition: result, acceptedObjectIndex: 0))
        review.acceptSuggestion(objectIndex: 1)
        #expect(review.selectedCategory == .chair)
        #expect(review.sourceDecision.acceptedObjectIndex == 1)
        review.acceptSuggestion(objectIndex: 7) // out of range: ignored
        #expect(review.selectionOrigin == .suggested(objectIndex: 1))
    }

    @Test func lateResultAfterManualChoiceKeepsChoice() {
        var review = CandidateReview()
        let token = review.beginAnalysis()
        review.chooseManually(.table)
        review.receive(result, token: token)
        #expect(review.selectedCategory == .table)
        #expect(review.selectionOrigin == .user)
        #expect(review.analysis == .finished(result))
        // Recognition still recorded, but not accepted.
        #expect(review.sourceDecision == SourceDecision(recognition: result, acceptedObjectIndex: nil))
    }

    @Test func clearedSelectionIsNotOverwritten() {
        var review = CandidateReview()
        let token = review.beginAnalysis()
        review.clearSelection()
        review.receive(result, token: token)
        #expect(review.selectedCategory == nil)
        #expect(review.selectionOrigin == .user)
    }

    @Test func staleTokenIgnoredEntirely() {
        var review = CandidateReview()
        let old = review.beginAnalysis()
        let fresh = review.beginAnalysis()
        review.receive(result, token: old)
        #expect(review.analysis == .running(token: fresh))
        #expect(review.selectedCategory == nil && review.selectionOrigin == .none)
        review.receive(nil, token: UUID())
        #expect(review.analysis == .running(token: fresh))
        review.receive(nil, token: fresh)
        #expect(review.analysis == .unavailable)
        review.receive(result, token: fresh) // already resolved: ignored
        #expect(review.analysis == .unavailable)
        #expect(review.sourceDecision == .manual)
    }

    @Test func emptyResultSelectsNothing() {
        var review = CandidateReview()
        let token = review.beginAnalysis()
        let empty = RecognitionResult(analyzer: "t", analyzerRevision: 1, objects: [], catLikely: false)
        review.receive(empty, token: token)
        #expect(review.selectionOrigin == .none)
        #expect(review.sourceDecision == SourceDecision(recognition: empty, acceptedObjectIndex: nil))
        review.chooseManually(.bed)
        #expect(review.sourceDecision.acceptedObjectIndex == nil)
    }
}

@Suite struct VisionRecognizerTests {
    @Test func labelMapping() {
        let expected: [String: FurnitureCategory?] = [
            "sofa": .sofa, "armchair": .chair, "chair": .chair, "folding_chair": .chair, "swivel_chair": .chair,
            "stool": .stool, "bench": .bench, "table": .table, "desk": .table, "bed": .bed, "crib": .bed,
            "wheelchair": nil, "car_seat": nil, "toilet_seat": nil, "bedding": nil, "tableware": nil, "cat": nil,
        ]
        for (label, category) in expected {
            #expect(VisionFurnitureRecognizer.category(forLabel: label) == category, "\(label)")
        }
    }

    @Test func tableUsesOnlyRealIdentifiers() async throws {
        let request = VNSupportedIdentifiers.load()
        for label in VisionFurnitureRecognizer.labelTable.keys {
            #expect(request.contains(label), "\(label) is a real classifier identifier")
        }
        for label in VisionFurnitureRecognizer.catLabels {
            #expect(request.contains(label), "\(label) is a real classifier identifier")
        }
    }

    @Test func resultBestPerCategoryThresholdAndSort() {
        let r = VisionFurnitureRecognizer.result(from: [
            ("chair", 0.3), ("armchair", 0.5), ("sofa", 0.6), ("desk", 0.09), ("bed", 0.10),
            ("kitten", 0.2), ("tableware", 0.9),
        ])
        #expect(r.objects == [
            ObservedObject(kind: .sofa, label: "sofa", confidence: 0.6),
            ObservedObject(kind: .chair, label: "armchair", confidence: 0.5),
            ObservedObject(kind: .bed, label: "bed", confidence: 0.10),
        ])
        #expect(r.catLikely == true)
        #expect(r.analyzer == VisionFurnitureRecognizer.analyzer)
        #expect(VisionFurnitureRecognizer.result(from: [("cat", 0.05)]).catLikely == false)
    }

    @Test func recognizeSyntheticImageSmoke() async throws {
        let data = TestSupport.imageData(width: 400, height: 300, seed: 5)
        let result = try await VisionFurnitureRecognizer().recognize(imageData: data)
        #expect(result.analyzerRevision == 2)
        #expect(result.objects.allSatisfy { $0.confidence >= VisionFurnitureRecognizer.minimumConfidence })
        #expect(result.objects.map(\.confidence) == result.objects.map(\.confidence).sorted(by: >))
        #expect(Set(result.objects.map(\.kind)).count == result.objects.count)
        #expect(result.catLikely != nil)
    }

    @Test func recognizeRejectsUndecodable() async {
        await #expect(throws: RecognitionError.undecodableImage) {
            try await VisionFurnitureRecognizer().recognize(imageData: Data("nope".utf8))
        }
    }
}

import Vision

enum VNSupportedIdentifiers {
    static func load() -> Set<String> {
        Set(ClassifyImageRequest().supportedIdentifiers)
    }
}
