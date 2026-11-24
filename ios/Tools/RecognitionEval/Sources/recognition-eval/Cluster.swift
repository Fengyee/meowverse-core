import Foundation
import MeowverseCore

// --cluster: cold start. Every photo, no labels, an empty room: group the photos so the user
// names each group once and fixes the photos that do not belong. The labels are used only to
// score the groups. Methods: agglomerative (average and complete linkage) cut at a distance
// threshold, and leader clustering in capture-time order; each on the signal's vectors alone,
// and with capture time and GPS folded in (`PhotoClustering.sessionAdjusted`). Time sessions
// alone (no vectors at all) are the baseline that says whether the vectors add anything.
// Cuts are fixed and at percentiles of the signal's own pair distances.

struct ClusterRow: Codable {
    var scope: String
    var signal: String
    var variant: String
    var method: String
    var cut: String
    var photos: Int
    var groups: Int
    var singletons: Int
    var purityPiece: Double
    var purityCategory: Double
    var cleanLargeShare: Double
    var adjustedRandPiece: Double
    var adjustedRandCategory: Double
    var actions: Int
    var nonePhotos: Int
    /// No-furniture photos sitting in a group whose commonest label is a piece.
    var noneInFurnitureGroups: Int
    /// Groups of 3+ whose commonest label is a piece and that hold at least one no-furniture photo.
    var furnitureGroupsWithNone: Int
}

/// Pair distances by kind, so checks can be pooled over places by joining the lists.
struct PairDistances {
    var same: [Float] = [], otherPiece: [Float] = [], otherCategory: [Float] = [], none: [Float] = []

    static func + (a: PairDistances, b: PairDistances) -> PairDistances {
        PairDistances(same: a.same + b.same, otherPiece: a.otherPiece + b.otherPiece,
                      otherCategory: a.otherCategory + b.otherCategory, none: a.none + b.none)
    }

    func check(scope: String, signal: String) -> PairCheck {
        PairCheck(scope: scope, signal: signal, pairsSamePiece: same.count,
                  samePieceVsOtherPieceSameCategory: PhotoClustering.closerShare(same: same, other: otherPiece),
                  samePieceVsOtherCategory: PhotoClustering.closerShare(same: same, other: otherCategory),
                  samePieceVsNoFurniture: PhotoClustering.closerShare(same: same, other: none),
                  medianSamePiece: quantile(same, 0.5), medianOtherPieceSameCategory: quantile(otherPiece, 0.5),
                  medianOtherCategory: quantile(otherCategory, 0.5), medianNoFurniture: quantile(none, 0.5))
    }
}

struct PairCheck: Codable {
    var scope: String
    var signal: String
    var pairsSamePiece: Int
    /// Share of pairs where two photos of one piece are closer than the other kind of pair.
    var samePieceVsOtherPieceSameCategory: Double?
    var samePieceVsOtherCategory: Double?
    var samePieceVsNoFurniture: Double?
    var medianSamePiece: Float?
    var medianOtherPieceSameCategory: Float?
    var medianOtherCategory: Float?
    var medianNoFurniture: Float?
}

struct ClusterReport: Codable {
    var rows: [ClusterRow] = []
    var pairs: [PairCheck] = []
}

let clusterThresholds: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.8, 1.0]
let clusterPercentiles: [Double] = [1, 2, 5, 10, 20, 30, 50]
let sessionGaps: [TimeInterval] = [2, 10, 30, 120].map { $0 * 60 }

enum GroupingMethod: CaseIterable {
    case average, complete, leader
    var name: String {
        switch self {
        case .average: "average linkage"
        case .complete: "complete linkage"
        case .leader: "leader (time order)"
        }
    }

    func groups(_ m: DistanceMatrix, order: [Int], threshold: Float) -> [Int] {
        switch self {
        case .average: PhotoClustering.agglomerative(m, linkage: .average, threshold: threshold)
        case .complete: PhotoClustering.agglomerative(m, linkage: .complete, threshold: threshold)
        case .leader: PhotoClustering.leader(m, order: order, threshold: threshold)
        }
    }
}

func printClusterLegend() {
    print("user actions = name each group once with its commonest label + fix every photo that is not that label; labelling every photo = one action each.")
    print("purity = photos carrying their group's commonest label; clean = photos in groups of 3+ that are at least 90% one label; ARI = adjusted Rand index (1 = the true grouping, 0 = chance).")
    print("pieces: a category folder without sub-folders is one piece; no-furniture photos are one more label, \"none\". pN = the N-th percentile of this signal's pair distances.\n")
}

/// Pair distances among photos with a real piece folder (and to no-furniture photos).
func pairDistances(_ samples: [LabelledPhoto], matrix: DistanceMatrix) -> PairDistances {
    var p = PairDistances()
    for i in samples.indices {
        for j in (i + 1)..<samples.count {
            let a = samples[i], b = samples[j], d = matrix[i, j]
            let aReal = a.piece != nil && !a.undivided, bReal = b.piece != nil && !b.undivided
            if aReal, bReal {
                if a.piece == b.piece { p.same.append(d) } else if a.category == b.category { p.otherPiece.append(d) } else { p.otherCategory.append(d) }
            } else if (aReal && b.piece == nil) || (bReal && a.piece == nil) {
                p.none.append(d)
            }
        }
    }
    return p
}

func share(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "–" }

func printPairCheck(_ c: PairCheck, indent: String = "    ") {
    print(indent + "pair check (real piece folders, \(c.pairsSamePiece) same-piece pairs; 1 = always closer, 0.5 = chance): one piece vs other piece of the same category "
          + "\(share(c.samePieceVsOtherPieceSameCategory)), vs other category \(share(c.samePieceVsOtherCategory)), vs no-furniture photo \(share(c.samePieceVsNoFurniture))"
          + " · median distance one piece \(format(c.medianSamePiece)), other piece same category \(format(c.medianOtherPieceSameCategory)), other category \(format(c.medianOtherCategory)), no furniture \(format(c.medianNoFurniture))")
}

/// Groups the photos every way and scores them. Prints the table (`.full`), or only the best
/// row per method (`.brief`), or nothing.
func clustering(_ samples: [LabelledPhoto], signal: String, scope: String, options: Options, detail: Detail,
                timeAlone: Bool) -> [ClusterRow] {
    guard samples.count >= 2 else { return [] }
    let pieceTruth = samples.map { $0.piece ?? noneLabel }, categoryTruth = samples.map(\.category)
    let order = timeOrder(samples)
    let raw = DistanceMatrix(vectors: samples.map(\.vector))
    let nonePhotos = samples.filter { $0.piece == nil }.count
    let variants: [(name: String, matrix: DistanceMatrix)] = [
        ("vectors only", raw),
        ("vectors + time", PhotoClustering.sessionAdjusted(raw, times: samples.map(\.time), places: samples.map(\.place), gap: options.sessionGap)),
    ]
    let sweep = cuts(fixed: clusterThresholds, percentiles: clusterPercentiles, matrix: raw)
    var rows: [ClusterRow] = []
    if timeAlone {
        for gap in sessionGaps {
            rows.append(clusterRow(scope, signal: "–", variant: "time alone", method: "sessions ≤ \(Int(gap / 60)) min", cut: "–",
                                   groups: PhotoClustering.sessions(times: samples.map(\.time), gap: gap),
                                   pieceTruth: pieceTruth, categoryTruth: categoryTruth))
        }
    }
    for variant in variants {
        let average = PhotoClustering.dendrogram(variant.matrix, linkage: .average)
        let complete = PhotoClustering.dendrogram(variant.matrix, linkage: .complete)
        for method in GroupingMethod.allCases {
            for cut in sweep {
                let groups: [Int] = switch method {
                case .average: PhotoClustering.cut(average, count: samples.count, at: cut.value)
                case .complete: PhotoClustering.cut(complete, count: samples.count, at: cut.value)
                case .leader: method.groups(variant.matrix, order: order, threshold: cut.value)
                }
                rows.append(clusterRow(scope, signal: signal, variant: variant.name, method: method.name, cut: cut.label,
                                       groups: groups, pieceTruth: pieceTruth, categoryTruth: categoryTruth))
            }
        }
    }
    guard detail != .silent else { return rows }
    print("  [\(scope) · \(signal)] grouping \(samples.count) photos: \(Set(pieceTruth).count - (nonePhotos > 0 ? 1 : 0)) pieces, \(nonePhotos) without furniture; "
          + "labelling every photo = \(samples.count) actions, one group of everything = \(ClusterScore(groups: Array(repeating: 0, count: samples.count), truth: pieceTruth).actions)")
    if detail == .full {
        print("    variant          method               cut        groups singles  purity piece/cat  clean  ARI piece/cat  actions  none in furniture groups")
        for row in rows { print(describeRow(row)) }
    }
    print("    fewest actions per method:")
    for variant in variants {
        for method in GroupingMethod.allCases {
            guard let best = rows.filter({ $0.variant == variant.name && $0.method == method.name })
                .min(by: { $0.actions < $1.actions }) else { continue }
            let cut = sweep.first { $0.label == best.cut }!.value
            var line = "      \(variant.name), \(method.name) at \(best.cut): \(best.actions) actions "
                + "(\(String(format: "%.0f", 100 * Double(samples.count - best.actions) / Double(samples.count)))% fewer), "
                + "\(best.groups) groups, clean \(percentOf(best.cleanLargeShare)), ARI \(String(format: "%.2f", best.adjustedRandPiece))"
            if nonePhotos > 0 {
                line += "; no-furniture photos in furniture groups \(best.noneInFurnitureGroups)/\(nonePhotos); "
                    + withoutNone(samples, timed: variant.name != "vectors only", method: method, threshold: cut, order: order, options: options)
            }
            print(line)
        }
    }
    if let best = rows.filter({ $0.variant == "time alone" }).min(by: { $0.actions < $1.actions }) {
        print("      time alone, \(best.method): \(best.actions) actions, \(best.groups) groups, clean \(percentOf(best.cleanLargeShare)), ARI \(String(format: "%.2f", best.adjustedRandPiece))")
    }
    return rows
}

/// Actions summed over places per setting; the best per method.
func printPooledClustering(_ rows: [ClusterRow], indent: String = "    ") {
    struct Key: Hashable { let variant, method, cut: String }
    var sums: [Key: (actions: Int, photos: Int, clean: Double)] = [:]
    var variants: [String] = [], methods: [String: [String]] = [:]
    for r in rows {
        let key = Key(variant: r.variant, method: r.method, cut: r.cut.split(separator: "=").first.map(String.init) ?? r.cut)
        let s = sums[key] ?? (0, 0, 0)
        sums[key] = (s.actions + r.actions, s.photos + r.photos, s.clean + r.cleanLargeShare * Double(r.photos))
        if !variants.contains(r.variant) { variants.append(r.variant) }
        if !(methods[r.variant] ?? []).contains(r.method) { methods[r.variant, default: []].append(r.method) }
    }
    for variant in variants {
        for method in methods[variant] ?? [] {
            guard let best = sums.filter({ $0.key.variant == variant && $0.key.method == method })
                .min(by: { ($0.value.actions, $0.key.cut) < ($1.value.actions, $1.key.cut) }) else { continue }
            let v = best.value
            print(indent + "\(variant), \(method)\(variant == "time alone" ? "" : " at \(best.key.cut)"): \(v.actions) actions for \(v.photos) photos "
                  + "(\(String(format: "%.0f", 100 * Double(v.photos - v.actions) / Double(max(1, v.photos))))% fewer), clean \(percentOf(v.clean / Double(max(1, v.photos))))")
        }
    }
}

private func clusterRow(_ scope: String, signal: String, variant: String, method: String, cut: String, groups: [Int],
                        pieceTruth: [String], categoryTruth: [String]) -> ClusterRow {
    let piece = ClusterScore(groups: groups, truth: pieceTruth), category = ClusterScore(groups: groups, truth: categoryTruth)
    var members: [Int: [String]] = [:]
    for (g, label) in zip(groups, pieceTruth) { members[g, default: []].append(label) }
    var noneInFurniture = 0, spoiled = 0
    for labels in members.values {
        let counts = Dictionary(grouping: labels, by: { $0 }).mapValues(\.count)
        let top = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }!.key
        let none = counts[noneLabel, default: 0]
        guard top != noneLabel, none > 0 else { continue }
        noneInFurniture += none
        if labels.count >= 3 { spoiled += 1 }
    }
    return ClusterRow(scope: scope, signal: signal, variant: variant, method: method, cut: cut, photos: groups.count,
                      groups: piece.clusters, singletons: piece.singletons, purityPiece: piece.purity, purityCategory: category.purity,
                      cleanLargeShare: piece.cleanLargeShare, adjustedRandPiece: piece.adjustedRand, adjustedRandCategory: category.adjustedRand,
                      actions: piece.actions, nonePhotos: pieceTruth.filter { $0 == noneLabel }.count,
                      noneInFurnitureGroups: noneInFurniture, furnitureGroupsWithNone: spoiled)
}

func percentOf(_ share: Double) -> String { String(format: "%.0f%%", 100 * share) }

private func describeRow(_ r: ClusterRow) -> String {
    "    " + r.variant.rightPad(16) + " " + r.method.rightPad(20) + " " + r.cut.rightPad(9) + "  "
        + String(r.groups).leftPad(6) + " " + String(r.singletons).leftPad(7) + "  "
        + "\(percentOf(r.purityPiece).leftPad(5)) / \(percentOf(r.purityCategory).leftPad(4))   "
        + percentOf(r.cleanLargeShare).leftPad(5) + "  "
        + String(format: "%5.2f / %5.2f", r.adjustedRandPiece, r.adjustedRandCategory) + "  "
        + String(r.actions).leftPad(7) + "  "
        + "\(r.noneInFurnitureGroups)/\(r.nonePhotos) photos, \(r.furnitureGroupsWithNone) groups of 3+"
}

/// The furniture photos' scores when the no-furniture photos take part, against clustering the
/// furniture photos alone with the same setting: the direct answer to "do they pollute groups?".
private func withoutNone(_ samples: [LabelledPhoto], timed: Bool, method: GroupingMethod, threshold: Float,
                         order: [Int], options: Options) -> String {
    func matrix(_ s: [LabelledPhoto]) -> DistanceMatrix {
        let raw = DistanceMatrix(vectors: s.map(\.vector))
        guard timed else { return raw }
        return PhotoClustering.sessionAdjusted(raw, times: s.map(\.time), places: s.map(\.place), gap: options.sessionGap)
    }
    let furniture = samples.indices.filter { samples[$0].piece != nil }
    guard !furniture.isEmpty else { return "" }
    let everything = method.groups(matrix(samples), order: order, threshold: threshold)
    let with = ClusterScore(groups: furniture.map { everything[$0] }, truth: furniture.map { samples[$0].piece! })
    let alone = furniture.map { samples[$0] }
    let without = ClusterScore(groups: method.groups(matrix(alone), order: timeOrder(alone), threshold: threshold), truth: alone.map { $0.piece! })
    return "furniture photos with them / without them: purity \(percentOf(with.purity)) / \(percentOf(without.purity)), "
        + String(format: "ARI %.2f / %.2f", with.adjustedRand, without.adjustedRand)
}
