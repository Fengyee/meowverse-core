import Foundation
import MeowverseCore

// The goal as the owner put it: for a new photo, suggest at least one and at most three pieces
// already in the room when one of them is right, and answer "未识别" when none is (a piece not
// in the room yet, or no furniture at all).
//
// Simulated in time order, as photos arrive in the app: a piece is "in the room" once it has a
// photo taken earlier. Each photo is either
//   known    its piece already has earlier photos: right if the piece is among the 1–3 shown
//   new      its piece has no earlier photo, or the photo has no furniture: right if "未识别"
// A rule turns per-piece scores into a list of up to three pieces above a threshold, or nothing.
// The threshold is chosen on the earlier half of the photos and judged on the later half.
//
// Photos with no furniture take part as references labelled "none": the app keeps them too
// (photo board, library), so a photo closest to them can be answered "未识别".

let noneLabel = "none"
let maxShown = 3

struct OpenSample {
    let label: String       // piece, or noneLabel
    let time: Date
    let vector: [Float]
}

/// Per-piece scores for one query (higher = more likely); "none" may score too but is never shown.
protocol PieceScorer {
    var name: String { get }
    var thresholds: [Float] { get }
    func scores(_ query: [Float], references: [OpenSample]) -> [String: Float]
}

/// The app today: a piece scores minus the distance to its closest photo.
struct ClosestDistanceScorer: PieceScorer {
    let name = "closest photo distance (app today)"
    var thresholds: [Float] { stride(from: Float(0.10), through: 0.80, by: 0.025).map { -$0 } }
    func scores(_ query: [Float], references: [OpenSample]) -> [String: Float] {
        var best: [String: Float] = [:]
        for r in references {
            let d = squaredDistance(query, r.vector)
            best[r.label] = max(best[r.label] ?? -.infinity, -d)
        }
        return best
    }
}

/// The app's own vote (`SimilarFurniture.voteShares`); a piece scores its share of the vote.
struct VoteScorer: PieceScorer {
    let k: Int
    var name: String { "\(k) closest photos vote" }
    var thresholds: [Float] { stride(from: Float(0.05), through: 1.0, by: 0.05).map { $0 } }
    func scores(_ query: [Float], references: [OpenSample]) -> [String: Float] {
        let refs = references.enumerated().map {
            FurniturePhotoPrint(instanceId: $1.label, photoId: String(format: "%06d", $0), print: evalPrint($1.vector))
        }
        return Dictionary(uniqueKeysWithValues: SimilarFurniture.voteShares(evalPrint(query), against: refs, neighbours: k).map { ($0.instanceId, $0.share) })
    }
}

func evalPrint(_ vector: [Float]) -> FeaturePrint { FeaturePrint(analyzer: "eval", revision: 0, vector: vector) }

/// The softmax classifier trained on every earlier photo (pieces and "none").
struct ClassifierScorer: PieceScorer {
    let name = "classifier trained on your labels"
    var thresholds: [Float] { stride(from: Float(0.05), through: 1.0, by: 0.05).map { $0 } }
    func scores(_ query: [Float], references: [OpenSample]) -> [String: Float] {
        Softmax().probabilities(query, train: references.map { (vector: $0.vector, label: $0.label) })
    }
}

/// Up to three pieces scoring at least `threshold`, best first; empty means "未识别".
func shown(_ scores: [String: Float], threshold: Float) -> [String] {
    scores.filter { $0.key != noneLabel && $0.value >= threshold }
        .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        .prefix(maxShown).map(\.key)
}

struct OpenTally: Codable {
    var known = 0, knownHit = 0, knownWrongList = 0, knownSaidNone = 0
    var new = 0, newSaidNone = 0
    var shownTotal = 0, lists = 0
    var right: Int { knownHit + newSaidNone }
    var asked: Int { known + new }

    mutating func add(truth: String, isKnown: Bool, list: [String]) {
        if isKnown {
            known += 1
            if list.isEmpty { knownSaidNone += 1 } else if list.contains(truth) { knownHit += 1 } else { knownWrongList += 1 }
        } else {
            new += 1
            if list.isEmpty { newSaidNone += 1 }
        }
        if !list.isEmpty { shownTotal += list.count; lists += 1 }
    }
}

struct OpenResult: Codable {
    var scorer: String
    var reading: String
    var threshold: Float
    var tuning: OpenTally
    var judged: OpenTally
}

/// Scores every photo once, in time order, against the photos taken before it.
func scoreInTimeOrder(_ samples: [OpenSample], scorer: any PieceScorer) -> [(truth: String, isKnown: Bool, scores: [String: Float])] {
    let ordered = samples.sorted { $0.time < $1.time }
    return ordered.indices.map { i in
        let earlier = Array(ordered[..<i])
        let truth = ordered[i].label
        let isKnown = truth != noneLabel && earlier.contains { $0.label == truth }
        return (truth, isKnown, earlier.isEmpty ? [:] : scorer.scores(ordered[i].vector, references: earlier))
    }
}

func tally(_ rows: ArraySlice<(truth: String, isKnown: Bool, scores: [String: Float])>, threshold: Float) -> OpenTally {
    var t = OpenTally()
    for row in rows { t.add(truth: row.truth, isKnown: row.isKnown, list: shown(row.scores, threshold: threshold)) }
    return t
}

func describe(_ t: OpenTally) -> String {
    let size = t.lists == 0 ? "–" : String(format: "%.1f", Double(t.shownTotal) / Double(t.lists))
    return "right \(t.right)/\(t.asked) \(percent(t.right, t.asked)) · in the room: listed \(t.knownHit)/\(t.known) \(percent(t.knownHit, t.known)), "
        + "wrong list \(t.knownWrongList), 未识别 \(t.knownSaidNone) · not in the room: 未识别 \(t.newSaidNone)/\(t.new) \(percent(t.newSaidNone, t.new)) · list size \(size)"
}

func runOpenSet(_ photos: [Photo], analyses: [String: Analysis]) -> [OpenResult] {
    let masking = VisionPhotoEmbedder.CatMasking.coverCat
    // Reading A (primary): a category folder without sub-folders is one piece.
    // Reading B: those photos only say the category; they are left out.
    let readings: [(name: String, label: (Photo) -> String?)] = [
        ("undivided folder = one piece", { p in p.truth == nil ? noneLabel : (p.piece ?? "\(p.truth!.rawValue)/(one piece)") }),
        ("undivided folders left out", { p in p.truth == nil ? noneLabel : p.piece }),
    ]
    let scorers: [any PieceScorer] = [ClosestDistanceScorer(), VoteScorer(k: 5), ClassifierScorer()]
    var results: [OpenResult] = []
    print("== Goal: 1–3 suggestions when the piece is in the room, otherwise 未识别 (time order, cat painted over) ==")
    for reading in readings {
        let samples = photos.compactMap { photo -> OpenSample? in
            guard let label = reading.label(photo), let analysis = analyses[photo.path],
                  let time = analysis.time, let print = analysis.prints[masking] else { return nil }
            return OpenSample(label: label, time: time, vector: print.vector)
        }
        let half = samples.count / 2
        print("\n[\(reading.name)] \(samples.count) photos; threshold chosen on the earliest \(half), judged on the latest \(samples.count - half)")
        for scorer in scorers {
            let rows = scoreInTimeOrder(samples, scorer: scorer)
            let tuningRows = rows[..<half], judgedRows = rows[half...]
            // Most photos handled right on the earlier half; ties go to the stricter threshold.
            let best = scorer.thresholds.max { a, b in
                let ra = tally(tuningRows, threshold: a).right, rb = tally(tuningRows, threshold: b).right
                return ra != rb ? ra < rb : a > b
            }!
            let result = OpenResult(scorer: scorer.name, reading: reading.name, threshold: best,
                                    tuning: tally(tuningRows, threshold: best), judged: tally(judgedRows, threshold: best))
            results.append(result)
            print("  \(scorer.name), threshold \(String(format: "%.3f", abs(best)))")
            print("    earlier half: \(describe(result.tuning))")
            print("    later half:   \(describe(result.judged))")
            // The whole trade-off, over all photos: how much listing is given up for each step
            // towards answering 未识别 correctly.
            var lastNone = -1
            for threshold in scorer.thresholds.sorted(by: >).reversed() {
                let t = tally(rows[...], threshold: threshold)
                let nonePercent = t.new == 0 ? 0 : 100 * t.newSaidNone / t.new
                guard nonePercent / 10 != lastNone / 10 else { continue }
                lastNone = nonePercent
                print("      threshold \(String(format: "%.3f", abs(threshold))): in the room listed \(percent(t.knownHit, t.known)) · not in the room 未识别 \(percent(t.newSaidNone, t.new)) · list size \(t.lists == 0 ? "–" : String(format: "%.1f", Double(t.shownTotal) / Double(t.lists)))")
            }
        }
        // Reference points on the later half: never suggesting, and always listing the 3 best.
        let rows = scoreInTimeOrder(samples, scorer: VoteScorer(k: 5))[half...]
        print("  for comparison, later half: always 未识别 → \(describe(tally(rows, threshold: .infinity)))")
        let closest = scoreInTimeOrder(samples, scorer: ClosestDistanceScorer())[half...]
        print("  for comparison, later half: always list the 3 closest → \(describe(tally(closest, threshold: -.infinity)))")
    }
    print("")
    return results
}

// MARK: The design the owner chose: always list, the user can answer 未识别 herself

/// Always the best piece, then others at least `floor`, up to three. The photo wall is a piece
/// like any other ("none" photos are its photos), so a photo with no furniture can be right too.
func alwaysList(_ scores: [String: Float], floor: Float) -> [String] {
    let ranked = scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
    guard let first = ranked.first else { return [] }
    return [first.key] + ranked.dropFirst().filter { $0.value >= floor }.prefix(maxShown - 1).map(\.key)
}

func runAlwaysList(_ photos: [Photo], analyses: [String: Analysis]) {
    let masking = VisionPhotoEmbedder.CatMasking.coverCat
    let samples = photos.compactMap { photo -> OpenSample? in
        guard let analysis = analyses[photo.path], let time = analysis.time, let print = analysis.prints[masking] else { return nil }
        let label = photo.truth == nil ? noneLabel : (photo.piece ?? "\(photo.truth!.rawValue)/(one piece)")
        return OpenSample(label: label, time: time, vector: print.vector)
    }
    print("Historical always-list baseline ( \(SimilarFurniture.neighbours) closest vote, others from \(SimilarFurniture.alsoShownFrom), at most \(SimilarFurniture.limit))")
    print("== Always list 1–3, photo wall is a piece (time order, cat painted over, undivided folder = one piece) ==")
    let scorers: [(any PieceScorer, [Float])] = [(VoteScorer(k: 5), [0.1, 0.2, 0.3]), (ClassifierScorer(), [0.05, 0.1, 0.2, 0.3])]
    for (scorer, floors) in scorers {
        let rows = scoreInTimeOrder(samples, scorer: scorer)
        // A photo can be right only once its piece (or the wall) has an earlier photo. Same set
        // for every method: rows come in the same time order as `ordered`.
        let ordered = samples.sorted { $0.time < $1.time }
        let seen = ordered.indices.map { i in ordered[..<i].contains { $0.label == ordered[i].label } }
        let answerable = zip(rows, seen).filter(\.1).map(\.0)
        let wallRows = answerable.filter { $0.truth == noneLabel }
        for floor in floors {
            var hit = 0, size = 0, top1 = 0, wallHit = 0
            for row in answerable {
                let list = alwaysList(row.scores, floor: floor)
                size += list.count
                if list.contains(row.truth) { hit += 1; if row.truth == noneLabel { wallHit += 1 } }
                if list.first == row.truth { top1 += 1 }
            }
            let (low, high) = wilson(hit, answerable.count)
            print("  \(scorer.name), others shown from \(floor): right one listed \(hit)/\(answerable.count) \(percent(hit, answerable.count)) "
                  + String(format: "(%.0f–%.0f%%)", 100 * low, 100 * high)
                  + " · first is right \(percent(top1, answerable.count)) · list size \(String(format: "%.1f", Double(size) / Double(max(1, answerable.count))))"
                  + " · no-furniture photos given the wall \(wallHit)/\(wallRows.count)")
        }
    }
    print("")
}

/// How long training takes as the library grows (synthetic unit vectors, same shape as prints).
func timeTraining() {
    print("== Classifier training time on this Mac (synthetic prints, 768 floats) ==")
    var generator = SystemRandomNumberGenerator()
    for (n, k) in [(200, 8), (1000, 20), (3000, 40), (10000, 60)] {
        let train: [(vector: [Float], label: String)] = (0..<n).map { i in
            var v = (0..<768).map { _ in Float.random(in: -1...1, using: &generator) }
            let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            v = v.map { $0 / norm }
            return (v, "p\(i % k)")
        }
        let start = Date()
        _ = Softmax().probabilities(train[0].vector, train: train)
        print("  \(n) photos, \(k) pieces: \(String(format: "%.2f", Date().timeIntervalSince(start))) s for 300 steps")
    }
    print("")
}
