import Foundation

/// The bug report's lines about look-alike recognition: which model really makes the prints,
/// how many filed photos can be compared now, how far the background backfill is, and what the
/// last batch came to. Counts, durations and distances only: never a photo id or a name, and
/// never an error's own text (it can hold a path).
public struct RecognitionDiagnostics: Sendable, Equatable {
    public enum Engine: Sendable, Equatable {
        case dinoLoading
        case dino(Load)
        /// The DINOv2 model failed to load in this launch or an earlier one of this build.
        case visionAfterDinoFailed
        /// The build has no DINOv2 model.
        case vision
        /// The UI tests' colour grid.
        case testStandIn
    }

    /// How the DINOv2 model was loaded.
    public struct Load: Sendable, Equatable {
        /// The compute units predictions run on.
        public var units: String
        /// Loading the model that is used.
        public var loadMilliseconds: Int
        /// The self-check (the CPU copy and both probe prints); nil when it was remembered.
        public var selfCheckMilliseconds: Int?
        /// No remembered self-check for this build, iOS version and model.
        public var firstLoadOfBuild: Bool
        /// e.g. "matches cpuOnly (d 0.0003)" or "self-check remembered".
        public var selfCheck: String

        public init(units: String, loadMilliseconds: Int, selfCheckMilliseconds: Int?, firstLoadOfBuild: Bool, selfCheck: String) {
            self.units = units
            self.loadMilliseconds = loadMilliseconds
            self.selfCheckMilliseconds = selfCheckMilliseconds
            self.firstLoadOfBuild = firstLoadOfBuild
            self.selfCheck = selfCheck
        }
    }

    /// The last batch the rule ran over.
    public struct BatchSummary: Sendable, Equatable {
        public var compared: Int
        public var offers: Int
        /// Each compared photo's distance to its nearest filed photo.
        public var nearest: [Float]

        public init(compared: Int, offers: Int, nearest: [Float]) {
            self.compared = compared
            self.offers = offers
            self.nearest = nearest.filter(\.isFinite)
        }

        public var line: String {
            let sorted = nearest.sorted()
            var text = "Last batch: \(compared) photos compared, \(offers) offers, nearest distance "
            guard let first = sorted.first else { return text + "none" }
            let middle = sorted.count / 2
            let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            text += String(format: "min %.3f, median %.3f", first, median)
            return text
        }
    }

    public var engine: Engine
    public var filedReady: Int
    public var filedTotal: Int
    public var backfillDone: Int?
    public var backfillTotal: Int?
    public var lastBatch: BatchSummary?
    /// Since launch: prints actually made, and photos whose stored print was only checked.
    public var printsMade: Int
    public var printsChecked: Int

    public init(engine: Engine, filedReady: Int, filedTotal: Int, backfill: (done: Int, total: Int)?, lastBatch: BatchSummary?,
                printsMade: Int = 0, printsChecked: Int = 0) {
        self.engine = engine
        self.filedReady = filedReady
        self.filedTotal = filedTotal
        backfillDone = backfill?.done
        backfillTotal = backfill?.total
        self.lastBatch = lastBatch
        self.printsMade = printsMade
        self.printsChecked = printsChecked
    }

    public var lines: [String] {
        let engineText = switch engine {
        case .dinoLoading: "DINOv2 not loaded yet (loads with the first print)"
        case let .dino(load):
            "DINOv2 loaded (units \(load.units), load \(load.loadMilliseconds) ms, "
                + (load.selfCheckMilliseconds.map { "self-check \($0) ms, " } ?? "")
                + (load.firstLoadOfBuild ? "first load of this build, " : "") + "\(load.selfCheck))"
        case .visionAfterDinoFailed: "Apple Vision (DINOv2 failed to load)"
        case .vision: "Apple Vision (no DINOv2 model in this build)"
        case .testStandIn: "test colour grid"
        }
        let backfill = backfillDone.flatMap { done in backfillTotal.map { "backfill \(done) / \($0)" } } ?? "backfill done"
        return ["Recognition: \(engineText)",
                "Prints: \(filedReady) of \(filedTotal) filed photos ready; \(backfill)",
                "Since launch: \(printsMade) prints made, \(printsChecked) only checked",
                lastBatch?.line ?? "Last batch: none this launch"]
    }

    /// For each print in `queries`, the distance to the nearest comparable reference.
    public static func nearestDistances(of queries: [String: FeaturePrint], to references: [FurniturePhotoPrint]) -> [Float] {
        queries.compactMap { id, query in
            references.filter { $0.photoId != id }.compactMap { query.distance(to: $0.print) }.min()
        }
    }
}
