import CoreGraphics
import Foundation
import os
import Vision

public protocol FurnitureRecognizing: Sendable {
    func recognize(imageData: Data) async throws -> RecognitionResult
}

public enum RecognitionError: Error, Equatable, Sendable {
    case undecodableImage
}

/// On-device furniture suggestions from Vision's built-in image classifier
/// (`ClassifyImageRequest`, revision 2; no model download). See RECOGNITION_NOTES.md.
public struct VisionFurnitureRecognizer: FurnitureRecognizing {
    public static let analyzer = "vision.classifyImage"
    public static let analyzerRevision = 2
    /// Labels below this confidence are dropped.
    public static let minimumConfidence = 0.10
    /// Images are downsampled (ImageIO) to at most this many pixels on the long side.
    public static let maxPixel = 1024

    /// Real identifiers observed in `ClassifyImageRequest().supportedIdentifiers` (revision 2).
    public static let labelTable: [String: FurnitureCategory] = [
        "sofa": .sofa,
        "chair": .chair,
        "armchair": .chair,
        "chair_other": .chair,
        "folding_chair": .chair,
        "swivel_chair": .chair,
        "high_chair": .chair,
        "stool": .stool,
        "bench": .bench,
        "table": .table,
        "desk": .table,
        "bed": .bed,
        "crib": .bed,
    ]

    /// Identifiers taken as evidence that a cat is probably visible.
    public static let catLabels: Set<String> = ["cat", "adult_cat", "kitten", "feline"]

    private static let log = Logger(subsystem: "app.meowverse", category: "recognition")

    public init() {}

    public static func category(forLabel label: String) -> FurnitureCategory? {
        labelTable[label.lowercased()]
    }

    /// Pure mapping from (identifier, confidence) pairs to a result. Exposed for tests.
    public static func result(from classifications: [(identifier: String, confidence: Double)]) -> RecognitionResult {
        var best: [FurnitureCategory: ObservedObject] = [:]
        var cat = false
        for (identifier, confidence) in classifications where confidence >= minimumConfidence {
            if catLabels.contains(identifier) { cat = true }
            guard let kind = category(forLabel: identifier) else { continue }
            if let existing = best[kind], existing.confidence >= confidence { continue }
            best[kind] = ObservedObject(kind: kind, label: identifier, confidence: confidence)
        }
        let objects = best.values.sorted {
            $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.kind.rawValue < $1.kind.rawValue
        }
        return RecognitionResult(analyzer: analyzer, analyzerRevision: analyzerRevision, objects: objects, catLikely: cat)
    }

    public func recognize(imageData: Data) async throws -> RecognitionResult {
        let pairs = try await Task.detached(priority: .userInitiated) { () async throws -> [(identifier: String, confidence: Double)] in
            guard let image = PhotoIngest.downsampledImage(data: imageData, maxPixel: Self.maxPixel) else {
                throw RecognitionError.undecodableImage
            }
            let request = ClassifyImageRequest()
            let observations = try await request.perform(on: image)
            return observations.map { (identifier: $0.identifier, confidence: Double($0.confidence)) }
        }.value
        let result = Self.result(from: pairs)
        Self.log.info("recognize: labels=\(pairs.count, privacy: .public) objects=\(result.objects.count, privacy: .public)")
        return result
    }
}
