import Foundation

/// What the user decided about a photo's category when committing.
public struct SourceDecision: Sendable, Equatable {
    /// Persisted as a PhotoObservation whenever non-nil, even if the user overrode it.
    public var recognition: RecognitionResult?
    /// Non-nil only when the user kept a suggested candidate.
    public var acceptedObjectIndex: Int?

    public init(recognition: RecognitionResult?, acceptedObjectIndex: Int?) {
        self.recognition = recognition
        self.acceptedObjectIndex = acceptedObjectIndex
    }

    public static let manual = SourceDecision(recognition: nil, acceptedObjectIndex: nil)
}

/// Pure state machine for reviewing one photo's candidates. Guards against late/stale analysis
/// results overwriting a user's choice.
public struct CandidateReview: Sendable, Equatable {
    public enum Analysis: Sendable, Equatable {
        case idle
        case running(token: UUID)
        case finished(RecognitionResult)
        case unavailable
    }

    public enum SelectionOrigin: Sendable, Equatable {
        case none
        case suggested(objectIndex: Int)
        case user
    }

    public private(set) var analysis: Analysis = .idle
    public private(set) var selectedCategory: FurnitureCategory?
    public private(set) var selectionOrigin: SelectionOrigin = .none

    public init() {}

    /// Starts (or restarts) an analysis; results carrying any older token are ignored.
    /// A selection that was only a suggestion indexed into the previous result, so it is
    /// cleared; a user's own choice is never touched.
    public mutating func beginAnalysis() -> UUID {
        let token = UUID()
        analysis = .running(token: token)
        if case .suggested = selectionOrigin {
            selectedCategory = nil
            selectionOrigin = .none
        }
        return token
    }

    public mutating func receive(_ result: RecognitionResult?, token: UUID) {
        guard case .running(let current) = analysis, current == token else { return }
        guard let result else {
            analysis = .unavailable
            return
        }
        analysis = .finished(result)
        if selectionOrigin == .none, let top = result.objects.first {
            selectedCategory = top.kind
            selectionOrigin = .suggested(objectIndex: 0)
        }
    }

    /// Keep one of the finished result's candidates. Ignored when out of range or not finished.
    public mutating func acceptSuggestion(objectIndex: Int) {
        guard let result = finishedResult, result.objects.indices.contains(objectIndex) else { return }
        selectedCategory = result.objects[objectIndex].kind
        selectionOrigin = .suggested(objectIndex: objectIndex)
    }

    public mutating func chooseManually(_ category: FurnitureCategory) {
        selectedCategory = category
        selectionOrigin = .user
    }

    /// An explicit user "none of these": clears the category and still counts as a user choice,
    /// so a late suggestion will not re-select anything.
    public mutating func clearSelection() {
        selectedCategory = nil
        selectionOrigin = .user
    }

    public var finishedResult: RecognitionResult? {
        if case .finished(let result) = analysis { return result }
        return nil
    }

    public var isAnalyzing: Bool {
        if case .running = analysis { return true }
        return false
    }

    public var sourceDecision: SourceDecision {
        let accepted: Int?
        if case .suggested(let index) = selectionOrigin { accepted = index } else { accepted = nil }
        return SourceDecision(recognition: finishedResult, acceptedObjectIndex: accepted)
    }
}
