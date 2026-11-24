import Accelerate
import CoreGraphics
import Foundation

// Grouping photos by their feature prints, for two questions the evaluation tool measures
// before any interface is built:
//   cold start   a first import with an empty room: can the photos be grouped so the user
//                names a group instead of every photo? (`PhotoClustering`, scored by `ClusterScore`)
//   auto-filing  the room already has photos: is a new photo so clearly one piece that it can be
//                offered for filing on a confirmation page? (`AutoFileRule`, `AutoFiling`)
// Distances are squared Euclidean, as `FeaturePrint.distance(to:)`; 0–4 for unit vectors.

/// Squared Euclidean distances between every pair of vectors.
public struct DistanceMatrix: Sendable, Equatable {
    public let count: Int
    private var values: [Float]

    public init(vectors: [[Float]]) {
        count = vectors.count
        values = [Float](repeating: 0, count: count * count)
        for i in 0..<count {
            for j in (i + 1)..<max(i + 1, count) {
                var d: Float = 0
                let length = vDSP_Length(min(vectors[i].count, vectors[j].count))
                vDSP_distancesq(vectors[i], 1, vectors[j], 1, &d, length)
                values[i * count + j] = d
                values[j * count + i] = d
            }
        }
    }

    public subscript(i: Int, j: Int) -> Float {
        get { values[i * count + j] }
        set {
            values[i * count + j] = newValue
            values[j * count + i] = newValue
        }
    }
}

/// Where a photo was taken, from its EXIF GPS. Callers keep it in memory only.
public struct PhotoPlace: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Great-circle distance in metres (haversine, mean Earth radius).
    public func metres(to other: PhotoPlace) -> Double {
        let r = 6_371_000.0, rad = Double.pi / 180
        let dLat = (other.latitude - latitude) * rad, dLon = (other.longitude - longitude) * rad
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * rad) * cos(other.latitude * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, a.squareRoot()))
    }
}

public enum PhotoClustering {
    public enum Linkage: String, Sendable, CaseIterable {
        /// Mean of the distances between the two groups' photos.
        case average
        /// Largest distance between the two groups' photos: every pair must be close.
        case complete
    }

    /// One step of agglomerative clustering: the groups whose smallest members are `a` < `b`
    /// joined at `height`.
    public struct Merge: Sendable, Equatable {
        public let a: Int
        public let b: Int
        public let height: Float
    }

    /// Every merge, closest first. Ties go to the pair with the smallest indices, so the result is
    /// deterministic. O(n³), fine for a few thousand photos on a Mac.
    public static func dendrogram(_ distances: DistanceMatrix, linkage: Linkage) -> [Merge] {
        let n = distances.count
        var d = distances
        var size = [Int](repeating: 1, count: n)
        var active = [Bool](repeating: true, count: n)
        var merges: [Merge] = []
        merges.reserveCapacity(max(0, n - 1))
        for _ in 0..<max(0, n - 1) {
            var best: (i: Int, j: Int, d: Float)?
            for i in 0..<n where active[i] {
                for j in (i + 1)..<n where active[j] {
                    let value = d[i, j]
                    if best == nil || value < best!.d { best = (i, j, value) }
                }
            }
            guard let (i, j, height) = best else { break }
            for k in 0..<n where active[k] && k != i && k != j {
                switch linkage {
                case .average:
                    d[i, k] = (Float(size[i]) * d[i, k] + Float(size[j]) * d[j, k]) / Float(size[i] + size[j])
                case .complete:
                    d[i, k] = max(d[i, k], d[j, k])
                }
            }
            size[i] += size[j]
            active[j] = false
            merges.append(Merge(a: i, b: j, height: height))
        }
        return merges
    }

    /// Group of each photo when the merging stops before the first merge higher than `threshold`.
    /// Groups are numbered 0, 1, … in order of their first photo.
    public static func cut(_ merges: [Merge], count: Int, at threshold: Float) -> [Int] {
        var parent = Array(0..<count)
        func root(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for merge in merges {
            guard merge.height <= threshold else { break }
            let ra = root(merge.a), rb = root(merge.b)
            parent[max(ra, rb)] = min(ra, rb)
        }
        return renumbered((0..<count).map(root))
    }

    public static func agglomerative(_ distances: DistanceMatrix, linkage: Linkage, threshold: Float) -> [Int] {
        cut(dendrogram(distances, linkage: linkage), count: distances.count, at: threshold)
    }

    /// Leader clustering: photos taken in `order`; each joins the group whose first photo (its
    /// leader) is closest, if within `threshold`, and otherwise starts a group. Ties go to the
    /// older group. Order matters; one pass.
    public static func leader(_ distances: DistanceMatrix, order: [Int], threshold: Float) -> [Int] {
        var group = [Int](repeating: -1, count: distances.count)
        var leaders: [Int] = []
        for item in order {
            var best: (group: Int, d: Float)?
            for (g, l) in leaders.enumerated() {
                let d = distances[item, l]
                if d <= threshold, best == nil || d < best!.d { best = (g, d) }
            }
            if let best {
                group[item] = best.group
            } else {
                group[item] = leaders.count
                leaders.append(item)
            }
        }
        return renumbered(group)
    }

    /// Sessions by time alone: photos sorted by time, a gap longer than `gap` starts a new session.
    /// A photo without a time is a session of its own.
    public static func sessions(times: [Date?], gap: TimeInterval) -> [Int] {
        var group = [Int](repeating: -1, count: times.count)
        let timed = times.indices.filter { times[$0] != nil }.sorted { (times[$0]!, $0) < (times[$1]!, $1) }
        var next = 0
        var last: Date?
        for item in timed {
            if let last, times[item]!.timeIntervalSince(last) <= gap { group[item] = next - 1 } else {
                group[item] = next
                next += 1
            }
            last = times[item]
        }
        for item in times.indices where group[item] < 0 {
            group[item] = next
            next += 1
        }
        return renumbered(group)
    }

    /// Distances with capture time and place folded in: photos in one session (see `sessions`)
    /// become distance 0, so they are merged or kept together before anything else; photos both
    /// with a GPS place more than `apartMetres` apart become `apart`, so they are never grouped.
    public static func sessionAdjusted(_ distances: DistanceMatrix, times: [Date?], places: [PhotoPlace?] = [],
                                       gap: TimeInterval, apartMetres: Double = 1000, apart: Float = 4) -> DistanceMatrix {
        var adjusted = distances
        let session = sessions(times: times, gap: gap)
        for i in 0..<distances.count {
            for j in (i + 1)..<max(i + 1, distances.count) {
                if i < places.count, j < places.count, let a = places[i], let b = places[j], a.metres(to: b) > apartMetres {
                    adjusted[i, j] = apart
                } else if session[i] == session[j] {
                    adjusted[i, j] = 0
                }
            }
        }
        return adjusted
    }

    /// Places by GPS: photos within `metres` of each other are one place, and so is any chain of
    /// such photos (single linkage). nil for a photo without GPS. Places are numbered 0, 1, … in
    /// order of their first photo.
    public static func places(_ places: [PhotoPlace?], within metres: Double) -> [Int?] {
        var parent = Array(places.indices)
        func root(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        let located = places.indices.filter { places[$0] != nil }
        for (n, i) in located.enumerated() {
            for j in located[(n + 1)...] where places[i]!.metres(to: places[j]!) <= metres {
                let ri = root(i), rj = root(j)
                parent[max(ri, rj)] = min(ri, rj)
            }
        }
        var number: [Int: Int] = [:]
        return places.indices.map { i in
            guard places[i] != nil else { return nil }
            let r = root(i)
            if let n = number[r] { return n }
            number[r] = number.count
            return number.count - 1
        }
    }

    /// The region around the cats to print: the box holding every cat box (normalised, any
    /// origin), grown by `factor` in width and height about its centre and kept inside the
    /// picture. nil when there is no box.
    public static func neighbourhood(of boxes: [CGRect], factor: Double) -> CGRect? {
        guard let first = boxes.first else { return nil }
        let union = boxes.dropFirst().reduce(first) { $0.union($1) }
        let w = union.width * factor, h = union.height * factor
        let grown = CGRect(x: union.midX - w / 2, y: union.midY - h / 2, width: w, height: h)
        let kept = grown.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return kept.isNull || kept.isEmpty ? nil : kept
    }

    /// Distances at these percentiles (0–100) of all pairs, nearest rank: the smallest distance
    /// with at least that share of pairs at or below it. Empty with fewer than two photos.
    public static func pairPercentiles(_ distances: DistanceMatrix, percents: [Double]) -> [Float] {
        let n = distances.count
        guard n >= 2 else { return [] }
        var all: [Float] = []
        all.reserveCapacity(n * (n - 1) / 2)
        for i in 0..<n { for j in (i + 1)..<n { all.append(distances[i, j]) } }
        all.sort()
        return percents.map { p in
            let rank = Int((min(max(p, 0), 100) / 100 * Double(all.count)).rounded(.up))
            return all[min(all.count - 1, max(0, rank - 1))]
        }
    }

    /// Share of (same, other) pairs where the same-label distance is smaller; ties count half.
    /// 1 means every same-label pair is closer than every other pair; 0.5 is chance.
    public static func closerShare(same: [Float], other: [Float]) -> Double? {
        guard !same.isEmpty, !other.isEmpty else { return nil }
        let sortedOther = other.sorted()
        var wins = 0.0
        for s in same {
            let below = lowerBound(sortedOther, s), notAbove = upperBound(sortedOther, s)
            wins += Double(sortedOther.count - notAbove) + 0.5 * Double(notAbove - below)
        }
        return wins / (Double(same.count) * Double(other.count))
    }

    private static func lowerBound(_ a: [Float], _ x: Float) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let mid = (lo + hi) / 2; if a[mid] < x { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    private static func upperBound(_ a: [Float], _ x: Float) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let mid = (lo + hi) / 2; if a[mid] <= x { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    static func renumbered(_ groups: [Int]) -> [Int] {
        var map: [Int: Int] = [:]
        return groups.map { g in
            if let m = map[g] { return m }
            map[g] = map.count
            return map.count - 1
        }
    }
}

/// How well a grouping matches the true labels, and what it would save the user.
public struct ClusterScore: Sendable, Equatable {
    public let photos: Int
    public let clusters: Int
    public let singletons: Int
    /// Photos carrying their group's most common label, as a share of all photos.
    public let purity: Double
    /// Photos in groups of at least `minimumSize` whose most common label has at least
    /// `minimumShare` of the group, as a share of all photos: the groups worth offering.
    public let cleanLargeShare: Double
    public let adjustedRand: Double
    /// Name each group once with its most common label, then fix every other photo one by one.
    public let actions: Int

    public init(groups: [Int], truth: [String], minimumSize: Int = 3, minimumShare: Double = 0.9) {
        precondition(groups.count == truth.count)
        photos = groups.count
        var members: [Int: [String: Int]] = [:]
        for (g, t) in zip(groups, truth) { members[g, default: [:]][t, default: 0] += 1 }
        clusters = members.count
        var majority = 0, clean = 0, single = 0
        for counts in members.values {
            let size = counts.values.reduce(0, +), top = counts.values.max() ?? 0
            majority += top
            if size == 1 { single += 1 }
            if size >= minimumSize, Double(top) >= minimumShare * Double(size) { clean += size }
        }
        singletons = single
        purity = photos == 0 ? 0 : Double(majority) / Double(photos)
        cleanLargeShare = photos == 0 ? 0 : Double(clean) / Double(photos)
        actions = clusters + photos - majority
        adjustedRand = Self.adjustedRandIndex(groups, truth)
    }

    /// Hubert–Arabie adjusted Rand index: 1 for the same partition, about 0 for chance.
    public static func adjustedRandIndex<A: Hashable, B: Hashable>(_ a: [A], _ b: [B]) -> Double {
        precondition(a.count == b.count)
        func pairs(_ x: Int) -> Double { Double(x) * Double(x - 1) / 2 }
        var table: [A: [B: Int]] = [:], rows: [A: Int] = [:], cols: [B: Int] = [:]
        for (x, y) in zip(a, b) {
            table[x, default: [:]][y, default: 0] += 1
            rows[x, default: 0] += 1
            cols[y, default: 0] += 1
        }
        let index = table.values.flatMap(\.values).reduce(0) { $0 + pairs($1) }
        let rowPairs = rows.values.reduce(0) { $0 + pairs($1) }, colPairs = cols.values.reduce(0) { $0 + pairs($1) }
        let total = pairs(a.count)
        guard total > 0 else { return 1 }
        let expected = rowPairs * colPairs / total, maximum = (rowPairs + colPairs) / 2
        guard maximum != expected else { return 1 }
        return (index - expected) / (maximum - expected)
    }
}

/// The strict rule for offering to file a photo without asking about it one by one: its
/// `neighbours` closest filed photos are all in one piece and only that piece, the closest is
/// within `maximumDistance`, that piece already holds at least `minimumPhotos` photos, and the
/// closest filed photo with any other label (another piece, or a photo on the photo wall) is at
/// least `margin` times as far as the `neighbours`-th closest (squared distances; equal passes).
/// With no photo of another label filed yet the margin passes. Fewer filed photos than
/// `neighbours` means no offer. A photo in two pieces breaks the agreement and counts as
/// another label. Pieces in `notOffered` (the photo wall) vote but are never offered.
///
/// Notes: when all `neighbours` closest photos are in the piece, it already has that many, so
/// `minimumPhotos` only adds anything when it is larger than `neighbours`; and every photo of
/// another label is at least as far as the `neighbours`-th, so `margin` 1 adds nothing.
public struct AutoFileRule: Sendable, Hashable {
    public var neighbours: Int
    public var maximumDistance: Float
    public var minimumPhotos: Int
    public var margin: Float

    public init(neighbours: Int, maximumDistance: Float, minimumPhotos: Int = 1, margin: Float = 1) {
        self.neighbours = neighbours
        self.maximumDistance = maximumDistance
        self.minimumPhotos = minimumPhotos
        self.margin = margin
    }

    /// The piece to offer for `query`, or nil. Prints made differently from `query` are skipped.
    public func piece(for query: FeaturePrint, among references: [FurniturePhotoPrint],
                      notOffered: Set<String> = []) -> FurnitureMatch? {
        var pieces: [String: Set<String>] = [:], prints: [String: FeaturePrint] = [:], photosIn: [String: Set<String>] = [:]
        for r in references {
            pieces[r.photoId, default: []].insert(r.instanceId)
            photosIn[r.instanceId, default: []].insert(r.photoId)
            if prints[r.photoId] == nil, query.isComparable(with: r.print) { prints[r.photoId] = r.print }
        }
        let sorted = prints.compactMap { id, p -> (id: String, d: Float)? in
            guard let d = query.distance(to: p), d.isFinite else { return nil }
            return (id, d)
        }.sorted { ($0.d, $0.id) < ($1.d, $1.id) }
        let nearest = sorted.prefix(neighbours)
        guard let verdict = verdict(nearest.map { (pieces[$0.id]!, $0.d) },
                                    nearestOther: { piece in sorted.first { pieces[$0.id]! != [piece] }?.d },
                                    photosIn: { photosIn[$0]?.count ?? 0 }, notOffered: notOffered) else { return nil }
        return FurnitureMatch(instanceId: verdict.piece, photoId: nearest.first!.id, distance: verdict.distance)
    }

    /// The rule itself, on the closest photos (closest first), the distance to the closest photo
    /// not only in a given piece (asked only when everything else passes), and photo counts.
    func verdict(_ nearest: [(pieces: Set<String>, distance: Float)], nearestOther: (String) -> Float?,
                 photosIn: (String) -> Int, notOffered: Set<String> = []) -> (piece: String, distance: Float)? {
        guard neighbours > 0, nearest.count >= neighbours, let first = nearest.first,
              first.distance <= maximumDistance, first.pieces.count == 1, let piece = first.pieces.first,
              !notOffered.contains(piece), nearest.allSatisfy({ $0.pieces == first.pieces }),
              photosIn(piece) >= minimumPhotos else { return nil }
        if margin > 1, let other = nearestOther(piece), other < margin * nearest[neighbours - 1].distance { return nil }
        return (piece, first.distance)
    }
}

/// Simulations of the rule on photos with known answers, for the evaluation tool.
/// `truth[i]` is the piece of photo i, or nil when it shows no furniture.
public enum AutoFiling {
    public struct Filing: Sendable, Equatable {
        public let item: Int
        public let truth: String?
        public let filed: String
        /// Photos filed under this photo's true label (its piece, or the photo wall) when offered.
        public let filedBefore: Int
        /// The true piece had no filed photo yet when this was offered.
        public var pieceWasNew: Bool { truth != nil && filedBefore == 0 }
        public var isRight: Bool { truth == filed }

        public init(item: Int, truth: String?, filed: String, filedBefore: Int) {
            self.item = item
            self.truth = truth
            self.filed = filed
            self.filedBefore = filedBefore
        }
    }

    /// Photos arrive one at a time in `order`; each is judged against the photos before it.
    /// Earlier photos are filed under their true piece (the user fixed anything wrong), or, with
    /// `acceptOffers`, an offered photo stays where it was offered (the page was confirmed as
    /// shown). No-furniture photos are references only when `wall` names the photo wall's label;
    /// the wall votes but is never offered. Returns the offers made.
    public static func stream(order: [Int], truth: [String?], distances: DistanceMatrix, rule: AutoFileRule,
                              wall: String? = nil, acceptOffers: Bool = false) -> [Filing] {
        var filed: [Int] = []
        var label: [Int: String] = [:]
        var count: [String: Int] = [:]
        var offers: [Filing] = []
        let notOffered: Set<String> = wall.map { [$0] } ?? []
        for item in order {
            let own = truth[item] ?? wall
            var placed = own
            if let verdict = judge(item, filed: filed, label: { label[$0]! }, count: count, distances: distances, rule: rule,
                                   notOffered: notOffered) {
                offers.append(Filing(item: item, truth: truth[item], filed: verdict, filedBefore: own.map { count[$0, default: 0] } ?? 0))
                if acceptOffers { placed = verdict }
            }
            if let placed {
                filed.append(item)
                label[item] = placed
                count[placed, default: 0] += 1
            }
        }
        return offers
    }

    /// What the user does with the confirmation page.
    public enum Page: String, Sendable, CaseIterable {
        /// Confirms everything shown; wrong offers land in the wrong piece and vote from then on.
        case acceptedAsShown
        /// Unticks the wrong offers; they go back to the queue and are not offered again.
        case wrongOnesRejected
    }

    public struct BatchResult: Sendable, Equatable {
        /// Photos the user decided one by one (including the rejected offers, decided later).
        public var manual = 0
        /// Every offer shown on a page, right or wrong.
        public var offers: [Filing] = []
        /// Offers unticked on the page (only with `.wrongOnesRejected`); each also costs a tap.
        public var rejected = 0
    }

    /// One import into an empty room (or `room`, already filed photos with their pieces): the
    /// user decides the earliest open photo in `order` by hand, then the rule runs over every
    /// photo still open and offers its picks on one page; repeat until none is open.
    public static func batch(order: [Int], truth: [String?], distances: DistanceMatrix, rule: AutoFileRule,
                             page: Page, room: [(item: Int, piece: String)] = []) -> BatchResult {
        var label: [Int: String] = [:]
        var count: [String: Int] = [:]
        var filed: [Int] = []
        for (item, piece) in room {
            label[item] = piece
            count[piece, default: 0] += 1
            filed.append(item)
        }
        var open = order
        var noOffer = Set<Int>()
        var result = BatchResult()
        while !open.isEmpty {
            let item = open.removeFirst()
            result.manual += 1
            if let piece = truth[item] {
                label[item] = piece
                count[piece, default: 0] += 1
                filed.append(item)
            }
            // Everything on one page is judged against the same filed photos.
            let shownCount = count
            var picks: [(item: Int, piece: String)] = []
            for candidate in open where !noOffer.contains(candidate) {
                if let piece = judge(candidate, filed: filed, label: { label[$0]! }, count: shownCount, distances: distances, rule: rule) {
                    picks.append((candidate, piece))
                }
            }
            for pick in picks {
                let offer = Filing(item: pick.item, truth: truth[pick.item], filed: pick.piece,
                                   filedBefore: truth[pick.item].map { shownCount[$0, default: 0] } ?? 0)
                result.offers.append(offer)
                if page == .wrongOnesRejected, !offer.isRight {
                    // Unticked: stays open, decided by hand later, never offered again.
                    result.rejected += 1
                    noOffer.insert(pick.item)
                    continue
                }
                open.removeAll { $0 == pick.item }
                label[pick.item] = pick.piece
                count[pick.piece, default: 0] += 1
                filed.append(pick.item)
            }
        }
        return result
    }

    private static func judge(_ item: Int, filed: [Int], label: (Int) -> String, count: [String: Int],
                              distances: DistanceMatrix, rule: AutoFileRule, notOffered: Set<String> = []) -> String? {
        guard rule.neighbours > 0, filed.count >= rule.neighbours else { return nil }
        var nearest: [(item: Int, d: Float)] = []
        for other in filed where other != item {
            let d = distances[item, other]
            if nearest.count == rule.neighbours, let last = nearest.last, (d, other) >= (last.d, last.item) { continue }
            let index = nearest.firstIndex { (d, other) < ($0.d, $0.item) } ?? nearest.count
            nearest.insert((other, d), at: index)
            if nearest.count > rule.neighbours { nearest.removeLast() }
        }
        return rule.verdict(nearest.map { ([label($0.item)], $0.d) },
                            nearestOther: { piece in
                                var closest: Float?
                                for other in filed where other != item && label(other) != piece {
                                    let d = distances[item, other]
                                    if closest == nil || d < closest! { closest = d }
                                }
                                return closest
                            },
                            photosIn: { count[$0, default: 0] }, notOffered: notOffered)?.piece
    }
}
