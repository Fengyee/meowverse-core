import Foundation
import MeowverseCore

// Runs --auto, --cluster and --by-place for every signal.
//
// --by-place: the owner's photos span several homes, and the app models one home per room, so
// scores over all photos mix homes. Photos are grouped into places by GPS (single linkage,
// 1 km); each place with at least `--place-minimum` photos is scored on its own, with only its
// own photos as references, and the results are pooled. Places are anonymous letters, biggest
// first; coordinates are never printed or written. Photos without GPS are one "unknown" group,
// listed but left out of the per-place scores.

struct PlaceSummary: Codable {
    var place: String
    var photos: Int
    var pieces: [String: Int]
    var years: [Int]
    var scored: Bool
}

struct CrossPlaceCheck: Codable {
    var signal: String
    var pairsSameLabelSamePlace: Int
    var pairsSameLabelOtherPlace: Int
    var pairsOtherPieceSamePlace: Int
    /// One label in one place closer than two different pieces in one place.
    var sameLabelSamePlaceVsOtherPieceSamePlace: Double?
    /// One label across places closer than two different pieces in one place.
    var sameLabelOtherPlaceVsOtherPieceSamePlace: Double?
    /// One label in one place closer than the same label across places.
    var sameLabelSamePlaceVsSameLabelOtherPlace: Double?
    var medianSameLabelSamePlace: Float?
    var medianSameLabelOtherPlace: Float?
    var medianOtherPieceSamePlace: Float?
}

struct NewModesReport: Codable {
    var signals: [String] = []
    var auto: [AutoRow]?
    var cluster: ClusterReport?
    var places: [PlaceSummary]?
    var crossPlace: [CrossPlaceCheck]?
    var margin: [MarginResult]?
}

let placeRadius: Double = 1000

func runNewModes(_ photos: [Photo], analyses: [String: Analysis], signals: [Signal], options: Options) -> NewModesReport {
    var report = NewModesReport(signals: signals.map(\.name))
    let detail: Detail = options.brief ? .brief : .full
    if options.byPlace {
        runByPlace(photos, analyses: analyses, signals: signals, options: options, report: &report)
        return report
    }
    if options.auto {
        printAutoLegend(options)
        var margin: [MarginResult] = []
        report.auto = signals.flatMap { signal in
            let samples = labelledPhotos(photos, analyses: analyses, signal: signal)
            let rows = autoFiling(samples, signal: signal.name, scope: "all photos", options: options, detail: detail)
            margin += marginSplit(samples, signal: signal.name, scope: "all photos")
            print("")
            return rows
        }
        report.margin = margin
    }
    if options.cluster {
        print("== Cold start: grouping every photo with no labels (labels only score the groups) ==")
        printClusterLegend()
        var cluster = ClusterReport()
        for (i, signal) in signals.enumerated() {
            let samples = labelledPhotos(photos, analyses: analyses, signal: signal)
            guard samples.count >= 2 else { continue }
            let check = pairDistances(samples, matrix: DistanceMatrix(vectors: samples.map(\.vector))).check(scope: "all photos", signal: signal.name)
            cluster.pairs.append(check)
            print("  [all photos · \(signal.name)] \(samples.count) photos, \(samples.filter { $0.time != nil }.count) with a capture time, \(samples.filter { $0.place != nil }.count) with GPS")
            printPairCheck(check)
            cluster.rows += clustering(samples, signal: signal.name, scope: "all photos", options: options, detail: detail, timeAlone: i == 0)
            print("")
        }
        report.cluster = cluster
    }
    return report
}

func printAutoLegend(_ options: Options) {
    print("== Auto-filing with the strict rule (time order) ==")
    print("rule: the k closest filed photos are all in one piece, the closest within squared distance d, and the piece has at least m photos.")
    print("      With all k closest in the piece it already has k photos, so m only matters when m > k; only m = 1 and m > k are shown.")
    print("      d is swept at fixed values and at pN, the N-th percentile of the signal's own pair distances.")
    print("variants: vectors only; vectors + time = same session (gap ≤ \(Int(options.sessionGap / 60)) min) counts as distance 0, GPS places more than 1 km apart never match.\n")
}

private func letters(_ n: Int) -> String {
    n < 26 ? String(UnicodeScalar(UInt8(65 + n))) : "P\(n + 1)"
}

private func runByPlace(_ photos: [Photo], analyses: [String: Analysis], signals: [Signal], options: Options, report: inout NewModesReport) {
    let known = photos.filter { analyses[$0.path] != nil }
    let ids = PhotoClustering.places(known.map { analyses[$0.path]!.place }, within: placeRadius)
    // Letters by size, biggest first; ties by first photo.
    let sizes = Dictionary(grouping: ids.compactMap { $0 }, by: { $0 }).mapValues(\.count)
    let ranked = sizes.keys.sorted { (sizes[$0]!, -$0) > (sizes[$1]!, -$1) }
    let letter = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1, letters($0)) })
    var placeOf: [String: String] = [:]
    for (photo, id) in zip(known, ids) { if let id { placeOf[photo.path] = letter[id] } }
    let big = Set(ranked.filter { sizes[$0]! >= options.placeMinimum }.map { letter[$0]! })

    print("== Places by GPS (single linkage, \(Int(placeRadius)) m; letters are anonymous, biggest first) ==")
    var summaries: [PlaceSummary] = []
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    func describe(_ group: [Photo], name: String, scored: Bool) {
        var pieces: [String: Int] = [:]
        for p in group { pieces[p.truth.map { p.piece ?? "\($0.rawValue)/(one piece)" } ?? noneLabel, default: 0] += 1 }
        let years = Set(group.compactMap { analyses[$0.path]?.time.map { calendar.component(.year, from: $0) } }).sorted()
        summaries.append(PlaceSummary(place: name, photos: group.count, pieces: pieces, years: years, scored: scored))
        let list = pieces.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        print("  \(name): \(group.count) photos\(scored ? "" : " (not scored)"); years \(years.map(String.init).joined(separator: ", ")); \(list)")
    }
    for id in ranked {
        let name = letter[id]!
        describe(known.filter { placeOf[$0.path] == name }, name: "place \(name)", scored: big.contains(name))
    }
    let unknown = known.filter { placeOf[$0.path] == nil }
    if !unknown.isEmpty { describe(unknown, name: "unknown (no GPS)", scored: false) }
    print("  scored: places with at least \(options.placeMinimum) photos (--place-minimum); labels count only inside their place.\n")
    report.places = summaries
    if options.auto { printAutoLegend(options) }
    if options.cluster { printClusterLegend() }

    var autoRows: [AutoRow] = [], cluster = ClusterReport(), cross: [CrossPlaceCheck] = []
    var margin: [MarginResult] = []
    let detail: Detail = options.brief ? .silent : .full
    for (index, signal) in signals.enumerated() {
        let samples = labelledPhotos(photos, analyses: analyses, signal: signal)
        print("== [\(signal.name)] by place ==")
        let check = crossPlaceCheck(samples, placeOf: placeOf, signal: signal.name)
        cross.append(check)
        print("  does a label mean one physical piece? (1 = always closer, 0.5 = chance; labels include undivided folders)")
        print("    one label, one place vs different pieces, one place: \(share(check.sameLabelSamePlaceVsOtherPieceSamePlace)) (\(check.pairsSameLabelSamePlace) / \(check.pairsOtherPieceSamePlace) pairs)")
        print("    one label, other place vs different pieces, one place: \(share(check.sameLabelOtherPlaceVsOtherPieceSamePlace)) (\(check.pairsSameLabelOtherPlace) pairs)")
        print("    one label, one place vs one label, other place: \(share(check.sameLabelSamePlaceVsSameLabelOtherPlace))")
        print("    median distance: one label one place \(format(check.medianSameLabelSamePlace)), one label other place \(format(check.medianSameLabelOtherPlace)), "
              + "different pieces one place \(format(check.medianOtherPieceSamePlace))")
        var pooledPairs = PairDistances()
        var signalAuto: [AutoRow] = [], signalCluster: [ClusterRow] = []
        var placeSamples: [(name: String, samples: [LabelledPhoto])] = []
        for id in ranked {
            let name = letter[id]!
            guard big.contains(name) else { continue }
            let sub = samples.filter { placeOf[$0.path] == name }
            placeSamples.append((name, sub))
            let pairs = pairDistances(sub, matrix: DistanceMatrix(vectors: sub.map(\.vector)))
            pooledPairs = pooledPairs + pairs
            let pc = pairs.check(scope: "place \(name)", signal: signal.name)
            cluster.pairs.append(pc)
            print("  place \(name), \(sub.count) photos:")
            printPairCheck(pc)
            if options.auto { signalAuto += autoFiling(sub, signal: signal.name, scope: "place \(name)", options: options, detail: detail) }
            if options.cluster {
                signalCluster += clustering(sub, signal: signal.name, scope: "place \(name)", options: options, detail: detail, timeAlone: index == 0)
            }
        }
        let pooledCheck = pooledPairs.check(scope: "pooled places", signal: signal.name)
        cluster.pairs.append(pooledCheck)
        print("  pooled over scored places:")
        printPairCheck(pooledCheck)
        if options.auto {
            print("    auto-filing, offers and right answers summed over places:")
            let pooled = pooledAuto(signalAuto, scope: "pooled places")
            summariseAuto(pooled, indent: "      ")
            autoRows += signalAuto + pooled
            margin += marginByPlace(placeSamples, signal: signal.name)
        }
        if options.cluster {
            print("    grouping, fewest actions summed over places:")
            printPooledClustering(signalCluster, indent: "      ")
            cluster.rows += signalCluster
        }
        print("")
    }
    report.crossPlace = cross
    if options.auto { report.margin = margin }
    if options.auto { report.auto = autoRows }
    report.cluster = cluster
}

private func crossPlaceCheck(_ samples: [LabelledPhoto], placeOf: [String: String], signal: String) -> CrossPlaceCheck {
    let located = samples.filter { placeOf[$0.path] != nil && $0.piece != nil }
    let m = DistanceMatrix(vectors: located.map(\.vector))
    var sameSame: [Float] = [], sameOther: [Float] = [], otherSame: [Float] = []
    for i in located.indices {
        for j in (i + 1)..<located.count {
            let samePlace = placeOf[located[i].path] == placeOf[located[j].path], sameLabel = located[i].piece == located[j].piece
            switch (sameLabel, samePlace) {
            case (true, true): sameSame.append(m[i, j])
            case (true, false): sameOther.append(m[i, j])
            case (false, true): otherSame.append(m[i, j])
            case (false, false): break
            }
        }
    }
    return CrossPlaceCheck(signal: signal, pairsSameLabelSamePlace: sameSame.count, pairsSameLabelOtherPlace: sameOther.count,
                           pairsOtherPieceSamePlace: otherSame.count,
                           sameLabelSamePlaceVsOtherPieceSamePlace: PhotoClustering.closerShare(same: sameSame, other: otherSame),
                           sameLabelOtherPlaceVsOtherPieceSamePlace: PhotoClustering.closerShare(same: sameOther, other: otherSame),
                           sameLabelSamePlaceVsSameLabelOtherPlace: PhotoClustering.closerShare(same: sameSame, other: sameOther),
                           medianSameLabelSamePlace: quantile(sameSame, 0.5), medianSameLabelOtherPlace: quantile(sameOther, 0.5),
                           medianOtherPieceSamePlace: quantile(otherSame, 0.5))
}
