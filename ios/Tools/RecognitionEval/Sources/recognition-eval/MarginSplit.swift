import Foundation
import MeowverseCore

// The margin rule, scored without choosing it on the photos it is judged on.
//
// Rule (`AutoFileRule` with `margin`): the k closest filed photos are all in one piece, the
// closest within d, and the closest filed photo of any other label (another piece, or a photo on
// the photo wall) at least r times as far as the k-th. Simulated one photo at a time in time
// order; no-furniture photos go to the photo wall and vote there. Two ways of treating offers:
// accepted where offered (the page confirmed as shown; mistakes then vote) and filed right (the
// user fixed them).
//
// Honest selection: (k, d, r) is chosen by "most offers with none wrong" on one part of the
// photos and judged on another:
//   time split            choose on the earlier half (time order), judge on the later half
//   leave one place out   (--by-place) choose on all other places, judge on the held-out place
// Ties go to the stricter setting (larger r, then smaller d, then larger k). Percentile cuts are
// taken from each scope's own pair distances, which uses no labels.

let marginNeighbours = [1, 2, 3, 5]
let marginRatios: [Float] = [1.0, 1.1, 1.25, 1.5, 2.0]
let wallLabel = "photo wall"
/// The setting the lead's scratch script suggested after seeing all photos, shown for comparison.
/// `--fixed-d <value>` replaces its percentile cut with that fixed squared distance (the constant
/// the app hard-codes), which is then also one of the cuts the honest selection may choose.
nonisolated(unsafe) var hypothesis = (k: 2, cut: "p2", r: Float(1.25))
nonisolated(unsafe) var extraMarginDistances: [Float] = []

struct MarginSetting: Hashable {
    let k: Int
    let cut: String      // "0.30" or "p2"
    let cutIndex: Int    // position in the sweep; smaller is stricter within its family
    let r: Float
    var name: String { "k=\(k) d≤\(cut) r=\(String(format: "%.2f", r))" }
}

/// One scope (all photos, or one place) simulated under every setting.
struct MarginRun {
    let photos: Int
    let half: Int
    /// Offers by setting, with each photo's position in time order.
    let offers: [MarginSetting: [(position: Int, filing: AutoFiling.Filing)]]
    let settings: [MarginSetting]
}

func marginRun(_ all: [LabelledPhoto], acceptOffers: Bool) -> MarginRun? {
    let samples = all.filter { $0.time != nil }
    guard samples.count >= 4 else { return nil }
    let order = timeOrder(samples)
    let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    let truth = samples.map(\.piece)
    let matrix = DistanceMatrix(vectors: samples.map(\.vector))
    let sweep = cuts(fixed: autoDistances + extraMarginDistances, percentiles: autoPercentiles, matrix: matrix)
    var offers: [MarginSetting: [(Int, AutoFiling.Filing)]] = [:]
    var settings: [MarginSetting] = []
    for k in marginNeighbours {
        for (index, cut) in sweep.enumerated() {
            for r in marginRatios {
                let setting = MarginSetting(k: k, cut: cut.label.split(separator: "=").first.map(String.init) ?? cut.label, cutIndex: index, r: r)
                let rule = AutoFileRule(neighbours: k, maximumDistance: cut.value, margin: r)
                offers[setting] = AutoFiling.stream(order: order, truth: truth, distances: matrix, rule: rule,
                                                    wall: wallLabel, acceptOffers: acceptOffers).map { (position[$0.item]!, $0) }
                settings.append(setting)
            }
        }
    }
    return MarginRun(photos: samples.count, half: samples.count / 2, offers: offers, settings: settings)
}

struct MarginTally: Codable {
    var photos = 0
    var offered = 0
    var right = 0
    /// Wrong offers of a photo whose true piece held fewer than 3 photos at that moment.
    var newPieceErrors = 0
    /// Wrong offers of a no-furniture photo.
    var noFurnitureErrors = 0
    var wrong: [String: Int] = [:]

    mutating func add(_ filing: AutoFiling.Filing) {
        offered += 1
        if filing.isRight { right += 1; return }
        if filing.truth == nil { noFurnitureErrors += 1 } else if filing.filedBefore < 3 { newPieceErrors += 1 }
        wrong["\(filing.truth ?? "none")\(filing.pieceWasNew ? " (new)" : "") → \(filing.filed)", default: 0] += 1
    }

    static func + (a: MarginTally, b: MarginTally) -> MarginTally {
        var t = a
        t.photos += b.photos
        t.offered += b.offered
        t.right += b.right
        t.newPieceErrors += b.newPieceErrors
        t.noFurnitureErrors += b.noFurnitureErrors
        for (w, n) in b.wrong { t.wrong[w, default: 0] += n }
        return t
    }
}

struct MarginResult: Codable {
    var scope: String
    var signal: String
    var offers: String
    var protocolName: String
    var chosen: String?
    var chosenOn: MarginTally
    var judged: MarginTally
    var low95: Double
    var high95: Double
    var hypothesisJudged: MarginTally?
}

private func tally(_ run: MarginRun, _ setting: MarginSetting, part: (Int) -> Bool) -> MarginTally {
    var t = MarginTally()
    t.photos = (0..<run.photos).filter(part).count
    for (position, filing) in run.offers[setting] ?? [] where part(position) { t.add(filing) }
    return t
}

/// Most offers with none wrong; ties to the stricter setting.
private func choose(_ settings: [MarginSetting], score: (MarginSetting) -> MarginTally) -> MarginSetting? {
    settings.map { ($0, score($0)) }
        .filter { $0.1.offered > 0 && $0.1.right == $0.1.offered }
        .max { a, b in
            (a.1.offered, a.0.r, -a.0.cutIndex, a.0.k) < (b.1.offered, b.0.r, -b.0.cutIndex, b.0.k)
        }?.0
}

private func hypothesisSetting(_ settings: [MarginSetting]) -> MarginSetting? {
    settings.first { $0.k == hypothesis.k && $0.cut == hypothesis.cut && $0.r == hypothesis.r }
}

private func describe(_ t: MarginTally) -> String {
    let (low, high) = wilson(t.right, t.offered)
    let range = t.offered == 0 ? "–" : String(format: "%.0f–%.0f%%", 100 * low, 100 * high)
    var text = "\(t.right)/\(t.offered) right (\(range)), \(percent(t.offered, t.photos)) of \(t.photos) photos"
    if t.offered > t.right {
        text += "; wrong \(t.offered - t.right): new-piece \(t.newPieceErrors), no furniture \(t.noFurnitureErrors), other \(t.offered - t.right - t.newPieceErrors - t.noFurnitureErrors)"
            + " [" + t.wrong.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + "]"
    }
    return text
}

private func result(_ scope: String, _ signal: String, _ offers: String, _ proto: String, _ chosen: MarginSetting?,
                    chosenOn: MarginTally, judged: MarginTally, hypothesis: MarginTally?) -> MarginResult {
    let (low, high) = wilson(judged.right, judged.offered)
    return MarginResult(scope: scope, signal: signal, offers: offers, protocolName: proto, chosen: chosen?.name,
                        chosenOn: chosenOn, judged: judged, low95: low, high95: high, hypothesisJudged: hypothesis)
}

private func printResult(_ r: MarginResult, indent: String) {
    print(indent + "\(r.protocolName), offers \(r.offers): chosen " + (r.chosen ?? "– (no setting with offers and none wrong)")
          + " on \(r.chosenOn.right)/\(r.chosenOn.offered); judged: \(describe(r.judged))")
    if let h = r.hypothesisJudged {
        print(indent + "  for comparison, the suggested k=\(hypothesis.k) d≤\(hypothesis.cut) r=\(hypothesis.r) judged the same way: \(describe(h))")
    }
}

/// Time split on one scope (all photos).
func marginSplit(_ samples: [LabelledPhoto], signal: String, scope: String) -> [MarginResult] {
    var results: [MarginResult] = []
    print("  [\(scope) · \(signal)] margin rule, chosen on the earlier half, judged on the later half (time order):")
    for accept in [true, false] {
        guard let run = marginRun(samples, acceptOffers: accept) else { print("    too few photos with a capture time"); return results }
        let earlier = { (p: Int) in p < run.half }, later = { (p: Int) in p >= run.half }
        let chosen = choose(run.settings) { tally(run, $0, part: earlier) }
        let judged = chosen.map { tally(run, $0, part: later) } ?? MarginTally(photos: run.photos - run.half)
        let h = hypothesisSetting(run.settings).map { tally(run, $0, part: later) }
        let r = result(scope, signal, accept ? "accepted where offered" : "filed right", "time split",
                       chosen, chosenOn: chosen.map { tally(run, $0, part: earlier) } ?? MarginTally(), judged: judged, hypothesis: h)
        printResult(r, indent: "    ")
        results.append(r)
    }
    return results
}

/// Time split pooled over places, and leave one place out.
func marginByPlace(_ places: [(name: String, samples: [LabelledPhoto])], signal: String) -> [MarginResult] {
    var results: [MarginResult] = []
    print("  margin rule, honest selection over places:")
    for accept in [true, false] {
        let runs = places.compactMap { place in marginRun(place.samples, acceptOffers: accept).map { (place.name, $0) } }
        guard let settings = runs.first?.1.settings, runs.count >= 2 else { print("    fewer than two places to compare"); return results }
        let offers = accept ? "accepted where offered" : "filed right"
        // Time split inside every place, pooled.
        func pooled(_ s: MarginSetting, later: Bool) -> MarginTally {
            runs.map { run in tally(run.1, s, part: { later ? $0 >= run.1.half : $0 < run.1.half }) }.reduce(MarginTally(), +)
        }
        let chosen = choose(settings) { pooled($0, later: false) }
        let split = result("pooled places", signal, offers, "time split in each place, pooled", chosen,
                           chosenOn: chosen.map { pooled($0, later: false) } ?? MarginTally(),
                           judged: chosen.map { pooled($0, later: true) } ?? MarginTally(),
                           hypothesis: hypothesisSetting(settings).map { pooled($0, later: true) })
        printResult(split, indent: "    ")
        results.append(split)
        // Leave one place out: choose on every other place (all their photos), judge the held-out one.
        var judged = MarginTally(), chosenOn = MarginTally(), picks: [String] = []
        var hypo = MarginTally()
        for (name, run) in runs {
            let others = runs.filter { $0.0 != name }
            let pick = choose(settings) { s in others.map { tally($0.1, s, part: { _ in true }) }.reduce(MarginTally(), +) }
            picks.append("\(name): \(pick?.name ?? "–")")
            if let pick {
                judged = judged + tally(run, pick, part: { _ in true })
                chosenOn = chosenOn + others.map { tally($0.1, pick, part: { _ in true }) }.reduce(MarginTally(), +)
            } else {
                judged.photos += run.photos
            }
            if let h = hypothesisSetting(settings) { hypo = hypo + tally(run, h, part: { _ in true }) }
        }
        var loo = result("pooled places", signal, offers, "leave one place out", nil, chosenOn: chosenOn, judged: judged, hypothesis: hypo)
        loo.chosen = picks.joined(separator: "; ")
        print("    leave one place out, offers \(offers): chosen per held-out place \(loo.chosen!); judged: \(describe(judged))")
        print("      for comparison, the suggested k=\(hypothesis.k) d≤\(hypothesis.cut) r=\(hypothesis.r) on every place: \(describe(hypo))")
        results.append(loo)
    }
    return results
}
