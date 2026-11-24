import Accelerate
import Foundation
import ImageIO
import MeowverseCore

// Learning from the owner's own labels: every photo already in a piece (or filed under a
// category) is a labelled example. Methods use Vision feature prints only, never Vision's
// category labels, and are compared on two questions:
//   piece:    which piece of furniture is this? (photos in <category>/<piece>/)
//   category: which category, or no furniture? (every photo)
// under three ways of choosing what the method may learn from:
//   leave-one-out   every other photo (the control: 1-NN must match the matching report)
//   other sessions  every photo taken more than `sessionGap` away from this one
//   time order      only photos taken before this one, as when photos come in one by one

struct Sample {
    let path: String
    let piece: String?
    let category: String
    let time: Date?
    let vector: [Float]
}

enum Task: String, CaseIterable { case piece, category }
enum Protocol: String, CaseIterable { case leaveOneOut = "leave-one-out", otherSessions = "other sessions", timeOrder = "time order" }

/// Photos closer together than this count as one session (one sitting on the sofa, a burst).
let sessionGap: TimeInterval = 2 * 3600

/// EXIF DateTimeOriginal with seconds, read as UTC wall-clock (only differences matter), and the
/// GPS place when there is one. The place stays in memory; nothing here writes it anywhere.
func exifTimeAndPlace(path: String) -> (time: Date?, place: PhotoPlace?) {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return (nil, nil) }
    var time: Date?
    if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
       let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        time = formatter.date(from: text)
    }
    var place: PhotoPlace?
    if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
       let lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
       let lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue {
        let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
        let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
        place = PhotoPlace(latitude: south ? -lat : lat, longitude: west ? -lon : lon)
    }
    return (time, place)
}

// MARK: Methods

/// A prediction and how sure the method is (higher is surer; only compared within a method).
struct Prediction { let label: String; let confidence: Float }

protocol Method {
    var name: String { get }
    func predict(_ query: [Float], train: [(vector: [Float], label: String)]) -> Prediction?
}

func squaredDistance(_ a: [Float], _ b: [Float]) -> Float {
    var result: Float = 0
    vDSP_distancesq(a, 1, b, 1, &result, vDSP_Length(a.count))
    return result
}

struct Majority: Method {
    let name = "always the commonest"
    func predict(_ query: [Float], train: [(vector: [Float], label: String)]) -> Prediction? {
        let counts = Dictionary(grouping: train, by: \.label).mapValues(\.count)
        guard let best = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) else { return nil }
        return Prediction(label: best.key, confidence: 0)
    }
}

/// What the app does today: the label of the single closest photo.
struct NearestPhoto: Method {
    let name = "closest photo (app today)"
    func predict(_ query: [Float], train: [(vector: [Float], label: String)]) -> Prediction? {
        guard let best = train.map({ (label: $0.label, d: squaredDistance(query, $0.vector)) })
            .min(by: { $0.d != $1.d ? $0.d < $1.d : $0.label < $1.label }) else { return nil }
        return Prediction(label: best.label, confidence: -best.d)
    }
}

/// The k closest photos vote, each weighted by 1 / distance.
struct NearestVote: Method {
    let k: Int
    var name: String { "\(k) closest photos vote" }
    func predict(_ query: [Float], train: [(vector: [Float], label: String)]) -> Prediction? {
        let nearest = train.map { (label: $0.label, d: squaredDistance(query, $0.vector)) }
            .sorted { $0.d != $1.d ? $0.d < $1.d : $0.label < $1.label }.prefix(k)
        guard !nearest.isEmpty else { return nil }
        var votes: [String: Float] = [:]
        for n in nearest { votes[n.label, default: 0] += 1 / (n.d + 1e-3) }
        let total = votes.values.reduce(0, +)
        let best = votes.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }!
        return Prediction(label: best.key, confidence: best.value / total)
    }
}

/// Each label is the average of its photos; the closest average wins.
struct NearestAverage: Method {
    let name = "closest average per label"
    func predict(_ query: [Float], train: [(vector: [Float], label: String)]) -> Prediction? {
        let groups = Dictionary(grouping: train, by: \.label)
        let scored = groups.map { label, members -> (label: String, d: Float) in
            var mean = [Float](repeating: 0, count: query.count)
            for m in members { vDSP_vadd(mean, 1, m.vector, 1, &mean, 1, vDSP_Length(mean.count)) }
            var scale = 1 / Float(members.count)
            vDSP_vsmul(mean, 1, &scale, &mean, 1, vDSP_Length(mean.count))
            return (label, squaredDistance(query, mean))
        }.sorted { $0.d != $1.d ? $0.d < $1.d : $0.label < $1.label }
        guard let first = scored.first else { return nil }
        let margin = scored.count > 1 ? scored[1].d - first.d : 1
        return Prediction(label: first.label, confidence: margin)
    }
}

/// Multinomial logistic regression on the prints (L2-regularised, full-batch gradient descent),
/// trained from scratch for every query: small enough to run on a phone too.
struct Softmax: Method {
    var lambda: Float = 1e-3
    var steps = 300
    var rate: Float = 2
    var name: String { "classifier trained on your labels" }

    func predict(_ query: [Float], train: [(vector: [Float], label: String)]) -> Prediction? {
        probabilities(query, train: train)
            .max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }
            .map { Prediction(label: $0.key, confidence: $0.value) }
    }

    /// Probability of each label seen in training.
    func probabilities(_ query: [Float], train: [(vector: [Float], label: String)]) -> [String: Float] {
        let labels = Array(Set(train.map(\.label))).sorted()
        guard !labels.isEmpty else { return [:] }
        if labels.count == 1 { return [labels[0]: 1] }
        let n = train.count, d = query.count + 1, k = labels.count
        let index = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($1, $0) })
        // Prints all point roughly the same way, which leaves plain gradient descent crawling.
        // Centre on the training mean and scale to unit mean square norm (learned from the
        // training photos only), then apply the same to the query.
        var mean = [Float](repeating: 0, count: d - 1)
        for sample in train { vDSP_vadd(mean, 1, sample.vector, 1, &mean, 1, vDSP_Length(d - 1)) }
        var inverseN = 1 / Float(n)
        vDSP_vsmul(mean, 1, &inverseN, &mean, 1, vDSP_Length(d - 1))
        let meanSquare = train.reduce(Float(0)) { $0 + squaredDistance($1.vector, mean) } / Float(n)
        let scale = meanSquare > 0 ? 1 / meanSquare.squareRoot() : 1
        func standardise(_ v: [Float]) -> [Float] { zip(v, mean).map { ($0 - $1) * scale } }
        var x = [Float](repeating: 0, count: n * d)       // n × d, last column = bias 1
        var y = [Float](repeating: 0, count: n * k)       // one-hot
        for (row, sample) in train.enumerated() {
            let v = standardise(sample.vector)
            for j in 0..<(d - 1) { x[row * d + j] = v[j] }
            x[row * d + d - 1] = 1
            y[row * k + index[sample.label]!] = 1
        }
        var w = [Float](repeating: 0, count: d * k)       // d × k
        var logits = [Float](repeating: 0, count: n * k)
        var grad = [Float](repeating: 0, count: d * k)
        for _ in 0..<steps {
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(n), Int32(k), Int32(d), 1, x, Int32(d), w, Int32(k), 0, &logits, Int32(k))
            for row in 0..<n {
                let base = row * k
                var top = -Float.infinity
                for c in 0..<k { top = max(top, logits[base + c]) }
                var sum: Float = 0
                for c in 0..<k { logits[base + c] = exp(logits[base + c] - top); sum += logits[base + c] }
                for c in 0..<k { logits[base + c] = logits[base + c] / sum - y[base + c] }
            }
            // grad = Xᵀ (P − Y) / n + λ W
            cblas_sgemm(CblasRowMajor, CblasTrans, CblasNoTrans, Int32(d), Int32(k), Int32(n), 1 / Float(n), x, Int32(d), logits, Int32(k), 0, &grad, Int32(k))
            for i in 0..<(d * k) { w[i] -= rate * (grad[i] + lambda * w[i]) }
        }
        var scores = [Float](repeating: 0, count: k)
        let q = standardise(query) + [1]
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, 1, Int32(k), Int32(d), 1, q, Int32(d), w, Int32(k), 0, &scores, Int32(k))
        let top = scores.max()!
        let exps = scores.map { exp($0 - top) }
        let sum = exps.reduce(0, +)
        return Dictionary(uniqueKeysWithValues: zip(labels, exps.map { $0 / sum }))
    }
}

// MARK: Evaluation

struct Outcome { let correct: Bool; let confidence: Float }

struct MethodResult: Codable {
    var method: String
    var asked: Int
    var correct: Int
    var low95: Double
    var high95: Double
    /// Accuracy on the surest 25 / 50 / 75 % of answers, and the confidence at each cut;
    /// empty when the method has no confidence to sort by.
    var surest: [String: Double]
    var surestCut: [String: Float]
}

struct ProtocolResult: Codable {
    var task: String
    var masking: String
    var protocolName: String
    /// Photos with no earlier / other-session photo of their own label: nothing could be right.
    var unanswerable: Int
    var results: [MethodResult]
}

func wilson(_ k: Int, _ n: Int) -> (Double, Double) {
    guard n > 0 else { return (0, 0) }
    let z = 1.96, p = Double(k) / Double(n), nn = Double(n)
    let centre = (p + z * z / (2 * nn)) / (1 + z * z / nn)
    let half = z * ((p * (1 - p) + z * z / (4 * nn)) / nn).squareRoot() / (1 + z * z / nn)
    return (max(0, centre - half), min(1, centre + half))
}

func evaluate(_ samples: [Sample], task: Task, proto: Protocol, methods: [any Method]) -> (unanswerable: Int, outcomes: [[Outcome]]) {
    let pool: [(sample: Sample, label: String)] = samples.compactMap { s in
        switch task {
        case .piece: s.piece.map { (s, $0) }
        case .category: (s, s.category)
        }
    }
    var outcomes = Array(repeating: [Outcome](), count: methods.count)
    var unanswerable = 0
    for (i, query) in pool.enumerated() {
        let train = pool.enumerated().filter { j, other in
            guard j != i else { return false }
            switch proto {
            case .leaveOneOut: return true
            case .otherSessions:
                guard let a = query.sample.time, let b = other.sample.time else { return true }
                return abs(a.timeIntervalSince(b)) > sessionGap
            case .timeOrder:
                guard let a = query.sample.time, let b = other.sample.time else { return false }
                return b < a
            }
        }.map { (vector: $0.element.sample.vector, label: $0.element.label) }
        guard train.contains(where: { $0.label == query.label }) else { unanswerable += 1; continue }
        for (m, method) in methods.enumerated() {
            guard let p = method.predict(query.sample.vector, train: train) else { continue }
            outcomes[m].append(Outcome(correct: p.label == query.label, confidence: p.confidence))
        }
    }
    return (unanswerable, outcomes)
}

func summarise(_ name: String, _ outcomes: [Outcome]) -> MethodResult {
    let correct = outcomes.filter(\.correct).count
    let (low, high) = wilson(correct, outcomes.count)
    let sorted = outcomes.sorted { $0.confidence > $1.confidence }
    var surest: [String: Double] = [:], cut: [String: Float] = [:]
    if Set(outcomes.map(\.confidence)).count > 1 {
        for share in [25, 50, 75] {
            let top = sorted.prefix(max(1, sorted.count * share / 100))
            surest["\(share)%"] = Double(top.filter(\.correct).count) / Double(top.count)
            cut["\(share)%"] = top.last?.confidence
        }
    }
    return MethodResult(method: name, asked: outcomes.count, correct: correct, low95: low, high95: high, surest: surest, surestCut: cut)
}

func runPersonal(_ photos: [Photo], analyses: [String: Analysis]) -> [ProtocolResult] {
    let methods: [any Method] = [Majority(), NearestPhoto(), NearestVote(k: 5), NearestAverage(), Softmax()]
    var all: [ProtocolResult] = []
    let timed = photos.filter { analyses[$0.path]?.time != nil }.count
    print("== Learning from your own labels (feature prints only; no Vision category labels) ==")
    print("photos with a capture time: \(timed) of \(photos.count); one session = within \(Int(sessionGap / 3600)) h")
    for masking in VisionPhotoEmbedder.CatMasking.allCases {
        let samples = photos.compactMap { photo -> Sample? in
            guard let analysis = analyses[photo.path], let print = analysis.prints[masking] else { return nil }
            return Sample(path: photo.path, piece: photo.piece, category: photo.truth?.rawValue ?? "none",
                          time: analysis.time, vector: print.vector)
        }
        // Tripwire: trained on every photo, the classifier must get its own training photos
        // nearly all right; if not, it is underfitting and its numbers below mean nothing.
        let everything = samples.map { (vector: $0.vector, label: $0.category) }
        let fitted = everything.filter { Softmax().predict($0.vector, train: everything)?.label == $0.label }.count
        print("sanity (\(masking.rawValue)): classifier fits its own training photos \(fitted)/\(everything.count)")
        for task in Task.allCases {
            for proto in Protocol.allCases {
                let (unanswerable, outcomes) = evaluate(samples, task: task, proto: proto, methods: methods)
                let results = zip(methods, outcomes).map { summarise($0.name, $1) }
                all.append(ProtocolResult(task: task.rawValue, masking: masking.rawValue, protocolName: proto.rawValue,
                                          unanswerable: unanswerable, results: results))
                print("\n[\(task.rawValue) · cat \(masking == .coverCat ? "painted over" : "left in") · \(proto.rawValue)] asked \(results.first?.asked ?? 0), could not be right \(unanswerable)")
                print("  method                              right          95% range    surest 25% / 50% / 75%")
                for r in results {
                    let name = r.method.padding(toLength: 34, withPad: " ", startingAt: 0)
                    let right = "\(r.correct)/\(r.asked) \(percent(r.correct, r.asked))".padding(toLength: 14, withPad: " ", startingAt: 0)
                    let range = String(format: "%2.0f–%2.0f%%", 100 * r.low95, 100 * r.high95).padding(toLength: 12, withPad: " ", startingAt: 0)
                    let surest = ["25%", "50%", "75%"].map { key in
                        r.surest[key].map { String(format: "%3.0f%% (≥%.2f)", 100 * $0, r.surestCut[key] ?? 0) } ?? "  –"
                    }.joined(separator: " / ")
                    print("  \(name)  \(right) \(range) \(surest)")
                }
            }
        }
    }
    print("")
    return all
}
