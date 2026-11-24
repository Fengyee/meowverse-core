import Foundation

/// Photo vectors made outside the app (another model, run by a script on the Mac), so the
/// evaluation tool can score them with the same reports as Vision's prints.
///
/// File format (JSON):
///
///     { "model": "name of the model", "dimension": 512,
///       "vectors": { "<SHA-256 of the photo file's bytes, hex>": [0.1, -0.2, …], … } }
///
/// `dimension` is optional; without it the most common vector length is used. Each kept vector
/// is scaled to unit length, so squared Euclidean distance runs 0–4 as for Vision. Entries that
/// cannot be used are skipped and counted, never guessed: a key that is not a SHA-256, a value
/// that is not a list of numbers, the wrong length, a value that is not finite, or all zeros.
public struct ExternalPrints: Sendable, Equatable {
    public struct Skipped: Sendable, Equatable {
        public var badKey = 0
        public var notNumbers = 0
        public var wrongDimension = 0
        public var notFinite = 0
        public var zero = 0
        public var total: Int { badKey + notNumbers + wrongDimension + notFinite + zero }
        public init() {}
    }

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case notJSON
        case missingModel
        case missingVectors
        case badDimension
        case noUsableVectors

        public var description: String {
            switch self {
            case .notJSON: "not a JSON object"
            case .missingModel: "no \"model\" name"
            case .missingVectors: "no \"vectors\" object"
            case .badDimension: "\"dimension\" is not a positive whole number"
            case .noUsableVectors: "no usable vectors"
            }
        }
    }

    public let model: String
    public let dimension: Int
    /// Unit-length vectors by lowercase SHA-256.
    public let vectors: [String: [Float]]
    public let skipped: Skipped

    public static func load(_ data: Data) throws -> ExternalPrints {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw LoadError.notJSON }
        guard let model = (root["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            throw LoadError.missingModel
        }
        guard let entries = root["vectors"] as? [String: Any] else { throw LoadError.missingVectors }
        var declared: Int?
        if let value = root["dimension"] {
            guard let number = value as? NSNumber, !isBool(number), number.doubleValue == number.doubleValue.rounded(),
                  number.intValue > 0 else { throw LoadError.badDimension }
            declared = number.intValue
        }
        var skipped = Skipped()
        var raw: [String: [Double]] = [:]
        for (key, value) in entries {
            let hash = key.lowercased()
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { skipped.badKey += 1; continue }
            guard let list = value as? [Any], !list.isEmpty,
                  let numbers = list.map({ ($0 as? NSNumber).flatMap { isBool($0) ? nil : $0.doubleValue } }) as [Double?]?,
                  !numbers.contains(where: { $0 == nil }) else { skipped.notNumbers += 1; continue }
            raw[hash] = numbers.map { $0! }
        }
        let lengths = Dictionary(grouping: raw.values, by: \.count).mapValues(\.count)
        guard let dimension = declared ?? lengths.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) })?.key else {
            throw LoadError.noUsableVectors
        }
        var vectors: [String: [Float]] = [:]
        for (hash, values) in raw {
            guard values.count == dimension else { skipped.wrongDimension += 1; continue }
            guard values.allSatisfy(\.isFinite) else { skipped.notFinite += 1; continue }
            let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0, norm.isFinite else { skipped.zero += 1; continue }
            vectors[hash] = values.map { Float($0 / norm) }
        }
        guard !vectors.isEmpty else { throw LoadError.noUsableVectors }
        return ExternalPrints(model: model, dimension: dimension, vectors: vectors, skipped: skipped)
    }

    /// The vector of each photo hash, nil where the file has none; and how many were missing.
    public func lookup(_ hashes: [String]) -> (vectors: [[Float]?], missing: Int) {
        let found = hashes.map { vectors[$0.lowercased()] }
        return (found, found.filter { $0 == nil }.count)
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
