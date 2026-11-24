import Foundation
import MeowverseCore

// What the newer reports (--auto, --cluster, --by-place) compare: one vector per photo from a
// "signal" (Vision's print of the whole picture, of the cat's neighbourhood, or vectors made by
// another model and given with --prints). Every report runs once per signal.

struct Signal {
    let id: String
    let name: String
    let vector: (Analysis) -> [Float]?
}

/// Vision's prints, as the app makes them (whole picture) and around the cat (`CatCrop`).
func visionSignals() -> [Signal] {
    [
        Signal(id: "vision.whole.catCovered", name: "Vision, whole picture, cat painted over") { $0.prints[.coverCat]?.vector },
        Signal(id: "vision.whole", name: "Vision, whole picture, cat left in") { $0.prints[.none]?.vector },
    ] + CatCrop.variants.map { variant in
        Signal(id: variant.id, name: variant.name) { $0.extra[variant.id] }
    }
}

func externalSignal(_ prints: ExternalPrints) -> Signal {
    Signal(id: "external", name: "\(prints.model) (--prints)") { prints.vectors[$0.hash] }
}

/// One photo with what the evaluation knows about it. `piece` nil = no furniture.
struct LabelledPhoto {
    let path: String
    let piece: String?
    let category: String
    /// The photo is in a category folder without sub-folders, so its "piece" is the whole folder.
    let undivided: Bool
    let time: Date?
    /// EXIF GPS, in memory only.
    let place: PhotoPlace?
    let vector: [Float]
}

/// Photos that have a vector for `signal`; a category folder without sub-folders is one piece.
func labelledPhotos(_ photos: [Photo], analyses: [String: Analysis], signal: Signal) -> [LabelledPhoto] {
    photos.compactMap { photo in
        guard let analysis = analyses[photo.path], let vector = signal.vector(analysis), !vector.isEmpty else { return nil }
        let piece = photo.truth.map { photo.piece ?? "\($0.rawValue)/(one piece)" }
        return LabelledPhoto(path: photo.path, piece: piece, category: photo.truth?.rawValue ?? "none",
                             undivided: photo.truth != nil && photo.piece == nil, time: analysis.time,
                             place: analysis.place, vector: vector)
    }
}

/// Capture time order; photos without a time go last, in folder order.
func timeOrder(_ samples: [LabelledPhoto]) -> [Int] {
    samples.indices.sorted { a, b in
        switch (samples[a].time, samples[b].time) {
        case let (x?, y?): (x, a) < (y, b)
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): a < b
        }
    }
}

/// A distance cut: fixed, or at a percentile of this signal's pair distances (scales differ by model).
struct Cut: Codable, Hashable {
    var label: String
    var value: Float
}

func cuts(fixed: [Float], percentiles: [Double], matrix: DistanceMatrix) -> [Cut] {
    let relative = PhotoClustering.pairPercentiles(matrix, percents: percentiles)
    return fixed.map { Cut(label: String(format: "%.2f", $0), value: $0) }
        + zip(percentiles, relative).map { Cut(label: String(format: "p%g=%.2f", $0, $1), value: $1) }
}

/// How much to print: whole tables, or only pair checks, best rows and summary lines.
enum Detail { case full, brief, silent }

extension String {
    func leftPad(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
    func rightPad(_ width: Int) -> String { padding(toLength: max(width, count), withPad: " ", startingAt: 0) }
}
