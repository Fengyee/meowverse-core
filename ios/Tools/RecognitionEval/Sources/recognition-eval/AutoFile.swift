import Foundation
import MeowverseCore

// --auto: the strict auto-file rule (`AutoFileRule`), simulated in time order. Two situations:
//   A. one photo at a time: each new photo is judged against every earlier photo, all filed
//      under their true piece (the user fixed anything wrong before)
//   B. one imported batch, empty room: the user files the earliest open photo by hand, the rule
//      runs over all the others and offers its picks on one confirmation page; repeat. Either the
//      page is accepted as shown (wrong offers stay and vote from then on) or the user unticks
//      the wrong ones (they are decided by hand later and never offered again).
// Each runs on the signal's vectors alone and with capture time and GPS folded in
// (`PhotoClustering.sessionAdjusted`: one session = distance 0; far apart places never match).
// A category folder without sub-folders counts as one piece; no-furniture photos are never
// filed and count as wrong whenever they are offered, as does a photo whose piece has no
// earlier photo. The distance d is swept at fixed values and at percentiles of the signal's
// own pair distances, since scales differ between models.

struct AutoRow: Codable {
    var scope: String
    var signal: String
    var variant: String
    var situation: String
    var neighbours: Int
    var cut: String
    var maximumDistance: Float
    var minimumPhotos: Int
    var photos: Int
    /// Photos the user decided by hand (situation B only).
    var manual: Int?
    var offered: Int
    var right: Int
    var low95: Double
    var high95: Double
    /// Situation A: photos whose piece already had an earlier photo (the most that could be right).
    var inRoom: Int?
    /// Unticked offers (situation B, wrong ones unticked).
    var unticked: Int?
    /// "true → filed" label pairs and how often; "none" is no furniture, "(new)" a piece not in the room yet.
    var wrong: [String: Int]

    /// m ≤ k gives the same answers as m = 1, so only these rows are printed and summarised.
    var isShown: Bool { minimumPhotos == 1 || minimumPhotos > neighbours }
}

let autoNeighbours = [3, 5, 7]
let autoDistances: [Float] = [0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50]
let autoPercentiles: [Double] = [1, 2, 5, 10, 20]
let autoMinimumPhotos = [1, 3, 5]
let autoSituations = ["one at a time", "batch, accepted as shown", "batch, wrong ones unticked"]

func autoFiling(_ all: [LabelledPhoto], signal: String, scope: String, options: Options, detail: Detail) -> [AutoRow] {
    let samples = all.filter { $0.time != nil }
    let say: (String) -> Void = { if detail != .silent { print($0) } }
    guard samples.count >= 2 else {
        say("  [\(scope) · \(signal)] auto-filing: fewer than 2 photos with a capture time, skipped")
        return []
    }
    let order = timeOrder(samples)
    let truth = samples.map(\.piece)
    let raw = DistanceMatrix(vectors: samples.map(\.vector))
    let withTime = PhotoClustering.sessionAdjusted(raw, times: samples.map(\.time), places: samples.map(\.place), gap: options.sessionGap)
    let sweep = cuts(fixed: autoDistances, percentiles: autoPercentiles, matrix: raw)
    var seen = Set<String>(), inRoom = 0
    for i in order { if let p = truth[i] { if seen.contains(p) { inRoom += 1 }; seen.insert(p) } }
    say("  [\(scope) · \(signal)] auto-filing: \(samples.count) photos with a capture time of \(all.count); "
        + "\(Set(truth.compactMap { $0 }).count) pieces, no furniture \(truth.filter { $0 == nil }.count), "
        + "\(inRoom) arrived with their piece already in the room")

    var rows: [AutoRow] = []
    var redundantSame = true
    for (variant, matrix) in [("vision", raw), ("vision + time", withTime)] {
        let variantName = variant == "vision" ? "vectors only" : "vectors + time"
        var streamRows: [AutoRow] = [], batchRows: [(AutoRow, AutoRow)] = []
        for k in autoNeighbours { for cut in sweep {
            var plain: [AutoFiling.Filing]?
            for m in autoMinimumPhotos {
                let rule = AutoFileRule(neighbours: k, maximumDistance: cut.value, minimumPhotos: m)
                let offers = AutoFiling.stream(order: order, truth: truth, distances: matrix, rule: rule)
                if m == 1 { plain = offers } else if m <= k, offers != plain { redundantSame = false }
                streamRows.append(row(scope, signal, variantName, autoSituations[0], rule, cut, samples.count, offers, inRoom: inRoom))
                let shown = AutoFiling.batch(order: order, truth: truth, distances: matrix, rule: rule, page: .acceptedAsShown)
                let unticked = AutoFiling.batch(order: order, truth: truth, distances: matrix, rule: rule, page: .wrongOnesRejected)
                var a = row(scope, signal, variantName, autoSituations[1], rule, cut, samples.count, shown.offers, inRoom: nil)
                a.manual = shown.manual
                var b = row(scope, signal, variantName, autoSituations[2], rule, cut, samples.count, unticked.offers, inRoom: nil)
                b.manual = unticked.manual
                b.unticked = unticked.rejected
                batchRows.append((a, b))
            }
        } }
        rows += streamRows + batchRows.flatMap { [$0.0, $0.1] }
        guard detail == .full else { continue }
        print("    [\(variantName)] A. one photo at a time, earlier photos filed right")
        print("      k  d          m   offered  right  precision (95%)     coverage: all / in-room   wrong (true → filed)")
        for r in streamRows where r.isShown {
            print("      \(r.neighbours)  \(r.cut.rightPad(9))  \(r.minimumPhotos)   " + offerColumns(r)
                  + "   \(percent(r.offered, r.photos).leftPad(4)) / \(percent(r.right, inRoom).leftPad(4))       \(wrongText(r.wrong))")
        }
        print("    [\(variantName)] B. one batch into an empty room, filed by hand in time order, rule re-run after each")
        print("      k  d          m   accepted as shown: by hand  offered  right  precision (95%)   | wrong ones unticked: by hand  right/offered   wrong as shown (true → filed)")
        for (a, b) in batchRows where a.isShown {
            print("      \(a.neighbours)  \(a.cut.rightPad(9))  \(a.minimumPhotos)                   \(String(a.manual ?? 0).leftPad(5))  " + offerColumns(a)
                  + " |                      \(String(b.manual ?? 0).leftPad(5))  \("\(b.right)/\(b.offered)".leftPad(13))     \(wrongText(a.wrong))")
        }
    }
    if detail != .silent {
        summariseAuto(rows)
        if !redundantSame { print("    check FAILED: some rows with m ≤ k differ from m = 1; see --json") }
        else if detail == .full { print("    check: rows with m ≤ k equal m = 1: yes") }
    }
    if options.misses, detail == .full {
        printMisses(samples, order: order, truth: truth, matrix: raw, options: options)
    }
    return rows
}

private func row(_ scope: String, _ signal: String, _ variant: String, _ situation: String, _ rule: AutoFileRule, _ cut: Cut,
                 _ photos: Int, _ offers: [AutoFiling.Filing], inRoom: Int?) -> AutoRow {
    let right = offers.filter(\.isRight).count
    let (low, high) = wilson(right, offers.count)
    var wrong: [String: Int] = [:]
    for offer in offers where !offer.isRight {
        wrong["\(offer.truth ?? "none")\(offer.pieceWasNew ? " (new)" : "") → \(offer.filed)", default: 0] += 1
    }
    return AutoRow(scope: scope, signal: signal, variant: variant, situation: situation, neighbours: rule.neighbours, cut: cut.label,
                   maximumDistance: rule.maximumDistance, minimumPhotos: rule.minimumPhotos, photos: photos, offered: offers.count,
                   right: right, low95: low, high95: high, inRoom: inRoom, wrong: wrong)
}

private func offerColumns(_ row: AutoRow) -> String {
    let precision = row.offered == 0 ? "–".rightPad(17)
        : String(format: "%3.0f%% (%2.0f–%3.0f%%)", 100 * Double(row.right) / Double(row.offered), 100 * row.low95, 100 * row.high95).rightPad(17)
    return "\(String(row.offered).leftPad(7))  \(String(row.right).leftPad(5))  \(precision)"
}

private func wrongText(_ wrong: [String: Int]) -> String {
    wrong.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
}

/// File names of wrong offers in situation A, for the app's own setting family at its loosest
/// fixed cut (k = 3, d 0.50): only printed with --misses, only to the terminal.
private func printMisses(_ samples: [LabelledPhoto], order: [Int], truth: [String?], matrix: DistanceMatrix, options: Options) {
    let rule = AutoFileRule(neighbours: 3, maximumDistance: 0.5, minimumPhotos: 1)
    let wrong = AutoFiling.stream(order: order, truth: truth, distances: matrix, rule: rule).filter { !$0.isRight }
    guard !wrong.isEmpty else { return }
    print("    wrong offers, one at a time, k=3 d≤0.50 (file names):")
    for offer in wrong { print("      \(relative(samples[offer.item].path, to: options.root)) → \(offer.filed)") }
}

/// The strictest reading of "very sure": the most offers with none wrong, and the most right
/// whose 95% range stays at or above 90%.
func summariseAuto(_ rows: [AutoRow], indent: String = "    ") {
    for variant in ["vectors only", "vectors + time"] {
        for situation in autoSituations {
            let candidates = rows.filter { $0.variant == variant && $0.situation == situation && $0.isShown && $0.offered > 0 }
            guard let any = rows.first(where: { $0.variant == variant && $0.situation == situation }) else { continue }
            func name(_ r: AutoRow) -> String { "k=\(r.neighbours) d≤\(r.cut) m=\(r.minimumPhotos)" }
            let flawless = candidates.filter { $0.right == $0.offered }.max { ($0.offered, -$0.maximumDistance) < ($1.offered, -$1.maximumDistance) }
            let safe = candidates.filter { $0.low95 >= 0.9 }.max { ($0.right, -$0.maximumDistance) < ($1.right, -$1.maximumDistance) }
            print(indent + "\(variant) · \(situation) (\(any.photos) photos): none wrong at most "
                  + (flawless.map { "\($0.offered) (\(name($0)))" } ?? "– (no setting)")
                  + " · 95% range ≥ 90%: " + (safe.map { "\($0.right)/\($0.offered) right (\(name($0)))" } ?? "no setting"))
        }
    }
}

/// Offers and right answers summed over places, per setting, with the Wilson range recomputed.
func pooledAuto(_ rows: [AutoRow], scope: String) -> [AutoRow] {
    struct Key: Hashable { let signal, variant, situation, cut: String; let k, m: Int }
    var pooled: [Key: AutoRow] = [:]
    var order: [Key] = []
    for r in rows {
        let key = Key(signal: r.signal, variant: r.variant, situation: r.situation, cut: r.cut.split(separator: "=").first.map(String.init) ?? r.cut,
                      k: r.neighbours, m: r.minimumPhotos)
        if var p = pooled[key] {
            p.photos += r.photos
            p.offered += r.offered
            p.right += r.right
            p.manual = r.manual.map { $0 + (p.manual ?? 0) }
            p.unticked = r.unticked.map { $0 + (p.unticked ?? 0) }
            p.inRoom = r.inRoom.map { $0 + (p.inRoom ?? 0) }
            for (w, n) in r.wrong { p.wrong[w, default: 0] += n }
            pooled[key] = p
        } else {
            var p = r
            p.scope = scope
            p.cut = key.cut
            pooled[key] = p
            order.append(key)
        }
    }
    return order.map { key in
        var p = pooled[key]!
        (p.low95, p.high95) = wilson(p.right, p.offered)
        return p
    }
}
