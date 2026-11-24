import CoreGraphics
import CoreML
import Foundation
import MeowverseCore

// recognition-eval <folder> [--auto] [--cluster] [--by-place] [--brief] [--prints <vectors.json>]
//                  [--coreml <model.mlpackage|.mlmodelc>] [--coreml-units all|cpuOnly|cpuAndGPU|cpuAndNE]
//                  [--write-prints <vectors.json>] [--fixed-d <squared distance>]
//                  [--session-gap <minutes>] [--place-minimum <photos>] [--list-hashes <out.json>]
//                  [--boxes <out.json>] [--no-cache] [--misses] [--json <file>]
//
// <folder>/<category>/<piece>/<photo>   a photo of one particular piece of furniture
// <folder>/<category>/<photo>           a photo whose piece does not matter
// <folder>/none/<photo>                 a photo with no furniture in it
// Category folders may also use the app's Chinese names (沙发, 猫爬架, 无家具 …).
//
// Reads the photos in place and prints numbers; nothing is copied or uploaded. Feature prints
// are cached in the system temporary folder, one file per photo named by the SHA-256 of its
// bytes (no file names, times or places). Capture time and GPS are read from EXIF on every run
// and kept in memory only. `--misses` (file names of wrong answers) and `--json` (the same
// numbers) write only to this terminal or the file named.

/// Folder names in Chinese, as the app names the categories, plus a few everyday words for the
/// same things (a cardboard box is a hideout to a cat).
let chineseCategoryNames: [String: FurnitureCategory] = [
    "椅子": .chair, "凳子": .stool, "长凳": .bench, "桌子": .table, "床": .bed, "沙发": .sofa,
    "猫抓板": .scratcher, "猫抓板和抓柱": .scratcher, "抓柱": .scratcher, "猫爬架": .catTree,
    "小台子": .platform, "台子": .platform, "藏身窝": .hideout, "猫窝": .hideout, "纸盒": .hideout,
    "纸箱": .hideout, "逗猫玩具": .toy, "玩具": .toy, "猫砂盆": .litterBox, "窗台": .windowPerch,
    "水碗": .water, "水碗和饮水机": .water, "饮水机": .water, "照片板": .photoBoard,
]
let noneFolderNames: Set<String> = ["none", "无家具", "没有家具"]

struct Photo {
    let path: String
    let truth: FurnitureCategory?
    let piece: String?
}

struct Options {
    var root: URL
    var misses = false
    var json: URL?
    /// The newer reports; when any is asked for, only those run (no category classifier).
    var auto = false
    var cluster = false
    var byPlace = false
    var brief = false
    var cache = true
    /// Photos closer in time than this are one session for the "with capture time" variants.
    var sessionGap: TimeInterval = 10 * 60
    /// Places with fewer photos are listed but not scored (--by-place).
    var placeMinimum = 20
    /// Vectors made by another model (--prints); used instead of Vision's.
    var prints: URL?
    /// The app's DINOv2 embedder (`DinoPhotoEmbedder`, the same source file) with this model.
    var coreml: URL?
    var coremlUnits: MLComputeUnits = .all
    /// Where to write the --coreml vectors as a --prints file (outside the repository).
    var writePrints: URL?
    var listHashes: URL?
    var boxes: URL?
    var onlyNewModes: Bool { auto || cluster || byPlace }
    var writesOnly: Bool { !onlyNewModes && (listHashes != nil || boxes != nil || writePrints != nil) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func parseOptions() -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    func value(of flag: String) -> String? {
        guard let index = args.firstIndex(of: flag) else { return nil }
        guard index + 1 < args.count else { fail("\(flag) needs a value") }
        let value = args[index + 1]
        args.removeSubrange(index...index + 1)
        return value
    }
    let json = value(of: "--json").map { URL(fileURLWithPath: $0) }
    var gap: TimeInterval = 10 * 60
    if let text = value(of: "--session-gap") {
        guard let minutes = Double(text), minutes > 0 else { fail("--session-gap needs minutes, e.g. 10") }
        gap = minutes * 60
    }
    var placeMinimum = 20
    if let text = value(of: "--place-minimum") {
        guard let n = Int(text), n >= 2 else { fail("--place-minimum needs a whole number of photos, at least 2") }
        placeMinimum = n
    }
    let prints = value(of: "--prints").map { URL(fileURLWithPath: $0) }
    let coreml = value(of: "--coreml").map { URL(fileURLWithPath: $0) }
    let units: [String: MLComputeUnits] = ["all": .all, "cpuOnly": .cpuOnly, "cpuAndGPU": .cpuAndGPU, "cpuAndNE": .cpuAndNeuralEngine]
    var coremlUnits = MLComputeUnits.all
    if let text = value(of: "--coreml-units") {
        guard let chosen = units[text] else { fail("--coreml-units: one of " + units.keys.sorted().joined(separator: ", ")) }
        coremlUnits = chosen
    }
    let writePrints = value(of: "--write-prints").map { URL(fileURLWithPath: $0) }
    if let text = value(of: "--fixed-d") {
        guard let d = Float(text), d > 0, d < 4 else { fail("--fixed-d needs a squared distance between 0 and 4, e.g. 0.42") }
        extraMarginDistances = [d]
        hypothesis.cut = String(format: "%.2f", d)
    }
    let listHashes = value(of: "--list-hashes").map { URL(fileURLWithPath: $0) }
    let boxes = value(of: "--boxes").map { URL(fileURLWithPath: $0) }
    let flags: Set<String> = ["--misses", "--timing", "--auto", "--cluster", "--no-cache", "--brief", "--by-place"]
    let given = Set(args.filter { flags.contains($0) })
    args.removeAll { flags.contains($0) }
    guard args.count == 1, !args[0].hasPrefix("--") else {
        fail("usage: recognition-eval <folder> [--auto] [--cluster] [--by-place] [--brief] [--prints <vectors.json>]\n"
             + "       [--session-gap <minutes>] [--place-minimum <photos>] [--list-hashes <out.json>] [--boxes <out.json>]\n"
             + "       [--coreml <model.mlpackage|.mlmodelc>] [--coreml-units <units>] [--write-prints <out.json>] [--fixed-d <d>]\n"
             + "       [--no-cache] [--misses] [--json <file>]\n"
             + "folder layout: <category>/<piece>/<photo>, <category>/<photo> or none/<photo>\n"
             + "categories: " + FurnitureCategory.allCases.map(\.rawValue).joined(separator: ", "))
    }
    var options = Options(root: URL(fileURLWithPath: args[0], isDirectory: true), misses: given.contains("--misses"), json: json,
                          auto: given.contains("--auto"), cluster: given.contains("--cluster"), byPlace: given.contains("--by-place"),
                          brief: given.contains("--brief"), cache: !given.contains("--no-cache"), sessionGap: gap)
    options.placeMinimum = placeMinimum
    options.prints = prints
    options.coreml = coreml
    options.coremlUnits = coremlUnits
    options.writePrints = writePrints
    if prints != nil, coreml != nil { fail("--prints and --coreml both replace Vision's prints; give one") }
    if coreml != nil, !options.onlyNewModes, writePrints == nil { fail("--coreml is used by --auto, --cluster and --by-place, or with --write-prints") }
    if writePrints != nil, coreml == nil { fail("--write-prints needs --coreml") }
    options.listHashes = listHashes
    options.boxes = boxes
    if prints != nil, !options.onlyNewModes { fail("--prints is used by --auto, --cluster and --by-place; add one of them") }
    // These two hold paths of, or facts about, private photos: never inside a Git checkout.
    for url in [listHashes, boxes, writePrints].compactMap({ $0 }) { refuseInsideRepository(url) }
    return options
}

/// Fails when `url` would land inside this repository or any other Git checkout.
func refuseInsideRepository(_ url: URL) {
    let fm = FileManager.default
    let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else {
        fail("\(url.path): the folder does not exist")
    }
    // This tool's own repository, found from its source file.
    var repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while repo.path != "/", !fm.fileExists(atPath: repo.appendingPathComponent(".git").path) { repo = repo.deletingLastPathComponent() }
    let repoPath = repo.resolvingSymlinksInPath().path.lowercased()
    let target = parent.path.lowercased()   // APFS ignores case
    if repo.path != "/", target == repoPath || target.hasPrefix(repoPath + "/") {
        fail("\(url.path) is inside the repository; write it outside, for example under $TMPDIR")
    }
    var folder = parent
    while true {
        if fm.fileExists(atPath: folder.appendingPathComponent(".git").path) {
            fail("\(url.path) is inside a Git checkout (\(folder.path)); write it outside, for example under $TMPDIR")
        }
        if folder.path == "/" { break }
        folder = folder.deletingLastPathComponent()
    }
}

/// Writes JSON readable only by this user.
func writePrivateJSON(_ object: some Encodable, to url: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        let data = try encoder.encode(object)
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try data.write(to: url)
    } catch {
        fail("could not write \(url.path): \(error.localizedDescription)")
    }
}

let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "dng"]

func listPhotos(in root: URL) -> [Photo] {
    let fm = FileManager.default
    func children(_ url: URL) -> [URL] {
        // Hidden files (.DS_Store, ._ AppleDouble files on external disks) are never photos.
        ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }

    var photos: [Photo] = []
    for categoryDir in children(root) where isDirectory(categoryDir) {
        let name = categoryDir.lastPathComponent
        let truth: FurnitureCategory?
        if noneFolderNames.contains(name) {
            truth = nil
        } else if let category = FurnitureCategory(rawValue: name) ?? chineseCategoryNames[name] {
            truth = category
        } else {
            fail("unknown category folder '\(name)'. Use one of: none, "
                 + FurnitureCategory.allCases.map(\.rawValue).joined(separator: ", ")
                 + "; or in Chinese: 无家具, " + chineseCategoryNames.keys.sorted().joined(separator: ", "))
        }
        for entry in children(categoryDir) {
            if isDirectory(entry) {
                let piece = "\(name)/\(entry.lastPathComponent)"
                for file in children(entry) where isImage(file) {
                    photos.append(Photo(path: file.path, truth: truth, piece: truth == nil ? nil : piece))
                }
            } else if isImage(entry) {
                photos.append(Photo(path: entry.path, truth: truth, piece: nil))
            }
        }
    }
    return photos
}

func percent(_ part: Int, _ whole: Int) -> String {
    whole == 0 ? "–" : String(format: "%.0f%%", 100 * Double(part) / Double(whole))
}

func quantile(_ values: [Float], _ q: Double) -> Float? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
}

func format(_ value: Float?) -> String { value.map { String(format: "%.3f", $0) } ?? "–" }

func relative(_ path: String, to root: URL) -> String {
    path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path
}

// MARK: Category suggestions (what "本机识别" shows)

struct ClassifierReport: Codable {
    var photos = 0
    var mappable = 0
    var top1Correct = 0
    var anyCorrect = 0
    var noSuggestion = 0
    var unmappedCategoryPhotos = 0
    var noneFolderPhotos = 0
    var noneFolderWithSuggestion = 0
    /// truth → predicted top-1 ("–" = nothing suggested) → count
    var confusion: [String: [String: Int]] = [:]
}

func evaluateClassifier(_ photos: [Photo], analyses: [String: Analysis], options: Options) -> ClassifierReport {
    let mappable = Set(VisionFurnitureRecognizer.labelTable.values)
    var report = ClassifierReport()
    var misses: [String] = []
    for photo in photos {
        guard let result = analyses[photo.path]?.recognition else { continue }
        report.photos += 1
        let top = result.objects.first?.kind
        let truthName = photo.truth?.rawValue ?? "none"
        report.confusion[truthName, default: [:]][top?.rawValue ?? "–", default: 0] += 1
        guard let truth = photo.truth else {
            report.noneFolderPhotos += 1
            if top != nil { report.noneFolderWithSuggestion += 1 }
            continue
        }
        guard mappable.contains(truth) else {
            report.unmappedCategoryPhotos += 1
            continue
        }
        report.mappable += 1
        if top == nil { report.noSuggestion += 1 }
        if top == truth { report.top1Correct += 1 }
        if result.objects.contains(where: { $0.kind == truth }) { report.anyCorrect += 1 }
        if top != truth { misses.append("  \(relative(photo.path, to: options.root)): \(top?.rawValue ?? "nothing")") }
    }

    print("== Category suggestions (Vision image classifier, as in the app) ==")
    print("photos read: \(report.photos)")
    print("in categories Vision can name (\(mappable.map(\.rawValue).sorted().joined(separator: ", "))): \(report.mappable)")
    print("  first suggestion right: \(report.top1Correct) (\(percent(report.top1Correct, report.mappable)))")
    print("  right one anywhere in the list: \(report.anyCorrect) (\(percent(report.anyCorrect, report.mappable)))")
    print("  nothing suggested: \(report.noSuggestion) (\(percent(report.noSuggestion, report.mappable)))")
    print("in categories Vision has no label for: \(report.unmappedCategoryPhotos) (can never be suggested)")
    if report.noneFolderPhotos > 0 {
        print("no-furniture photos given a suggestion anyway: \(report.noneFolderWithSuggestion) of \(report.noneFolderPhotos)")
    }
    print("confusion (truth → first suggestion):")
    for truth in report.confusion.keys.sorted() {
        let row = report.confusion[truth]!.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        print("  \(truth): \(row)")
    }
    if options.misses, !misses.isEmpty {
        print("wrong or missing first suggestion:")
        misses.forEach { print($0) }
    }
    print("")
    return report
}

// MARK: Matching against furniture already in the room

struct MatchingReport: Codable {
    struct Sweep: Codable {
        var threshold: Float
        var shown: Int
        var correct: Int
    }

    var masking: String
    var pieces = 0
    var queries = 0
    var top1Correct = 0
    var top2Correct = 0
    var sameNearest: [Float] = []
    var otherNearest: [Float] = []
    var sweep: [Sweep] = []
    /// Highest threshold whose shown suggestions are at least 90% right.
    var suggestedThreshold: Float?
}

func evaluateMatching(_ photos: [Photo], analyses: [String: Analysis], masking: VisionPhotoEmbedder.CatMasking,
                      options: Options) -> MatchingReport {
    let embedder = VisionPhotoEmbedder(masking: masking)
    var prints: [(photo: Photo, print: FeaturePrint)] = []
    for photo in photos where photo.piece != nil {
        guard let print = analyses[photo.path]?.prints[masking] else { continue }
        prints.append((photo, print))
    }
    var report = MatchingReport(masking: masking.rawValue)
    let counts = Dictionary(grouping: prints, by: { $0.photo.piece! }).mapValues(\.count)
    report.pieces = counts.count
    var nearest: [(distance: Float, correct: Bool)] = []
    var misses: [String] = []
    for (index, query) in prints.enumerated() where counts[query.photo.piece!, default: 0] >= 2 {
        let references = prints.enumerated().filter { $0.offset != index }.map {
            FurniturePhotoPrint(instanceId: $0.element.photo.piece!, photoId: $0.element.photo.path, print: $0.element.print)
        }
        let ranked = SimilarFurniture.rank(query.print, against: references, maxDistance: .infinity, limit: .max)
        guard let first = ranked.first else { continue }
        report.queries += 1
        let piece = query.photo.piece!
        if first.instanceId == piece { report.top1Correct += 1 } else {
            misses.append("  \(relative(query.photo.path, to: options.root)) → \(first.instanceId) (\(format(first.distance)))")
        }
        if ranked.prefix(2).contains(where: { $0.instanceId == piece }) { report.top2Correct += 1 }
        if let same = ranked.first(where: { $0.instanceId == piece }) { report.sameNearest.append(same.distance) }
        if let other = ranked.first(where: { $0.instanceId != piece }) { report.otherNearest.append(other.distance) }
        nearest.append((first.distance, first.instanceId == piece))
    }
    for step in 1...30 {
        let threshold = Float(step) * 0.05
        let shown = nearest.filter { $0.distance <= threshold }
        report.sweep.append(.init(threshold: threshold, shown: shown.count, correct: shown.filter(\.correct).count))
    }
    report.suggestedThreshold = report.sweep.filter { $0.shown >= 5 && Double($0.correct) >= 0.9 * Double($0.shown) }.last?.threshold

    print("== Matching to existing furniture, cat \(masking == .coverCat ? "painted over" : "left in") (\(embedder.analyzer)) ==")
    print("pieces: \(report.pieces), photos asked (pieces with 2+ photos, each left out in turn): \(report.queries)")
    print("  closest piece is the right one: \(report.top1Correct) (\(percent(report.top1Correct, report.queries)))")
    print("  right one in the first two: \(report.top2Correct) (\(percent(report.top2Correct, report.queries)))")
    print("  distance to own piece      p10 \(format(quantile(report.sameNearest, 0.1))) · median \(format(quantile(report.sameNearest, 0.5))) · p90 \(format(quantile(report.sameNearest, 0.9)))")
    print("  distance to closest other  p10 \(format(quantile(report.otherNearest, 0.1))) · median \(format(quantile(report.otherNearest, 0.5))) · p90 \(format(quantile(report.otherNearest, 0.9)))")
    print("  threshold → suggestion shown / right when shown (the app now votes instead; see below):")
    for row in report.sweep where row.shown > 0 && Int((row.threshold * 100).rounded()) % 10 == 0 {
        print("    \(format(row.threshold)): shown \(percent(row.shown, report.queries)), right \(percent(row.correct, row.shown))")
    }
    print("  highest threshold with ≥90% right: \(format(report.suggestedThreshold))")
    if options.misses, !misses.isEmpty {
        print("closest piece wrong:")
        misses.forEach { print($0) }
    }
    print("")
    return report
}

struct Report: Codable {
    var classifier: ClassifierReport
    var matching: [MatchingReport]
    var personal: [ProtocolResult]
    var openSet: [OpenResult]
}

/// What the app would compute for one photo.
struct Analysis {
    /// SHA-256 of the photo file's bytes: the key of the cache and of `--prints`.
    var hash = ""
    var recognition: RecognitionResult?
    var prints: [VisionPhotoEmbedder.CatMasking: FeaturePrint] = [:]
    /// Cat-neighbourhood prints by `CatCrop.Variant.id`.
    var extra: [String: [Float]] = [:]
    /// Cat boxes Vision found (normalised, lower-left origin); nil when not looked for.
    var cats: [CGRect]?
    var time: Date?
    /// EXIF GPS, in memory only: never cached, printed or written.
    var place: PhotoPlace?
}

let options = parseOptions()
let photos = listPhotos(in: options.root)
guard !photos.isEmpty else { fail("no photos found under \(options.root.path)") }
var external: ExternalPrints?
if let url = options.prints {
    do {
        external = try ExternalPrints.load(Data(contentsOf: url))
    } catch let error as ExternalPrints.LoadError {
        fail("--prints \(url.lastPathComponent): \(error.description)")
    } catch {
        fail("--prints: could not read \(url.path): \(error.localizedDescription)")
    }
}
// The app's own DINOv2 path: same source file, same thumbnail bytes, no fallback to Vision.
let dino = options.coreml.map {
    DinoPhotoEmbedder(modelURL: $0, computeUnits: options.coremlUnits, fallback: nil)
}
var dinoVectors: [String: [Float]] = [:]
var dinoMilliseconds: [Double] = []
var dinoFailed = 0
// What has to come from Vision: the classifier only for the older reports; prints unless another
// model's vectors replace them; cat boxes for --boxes.
let needClassifier = !options.onlyNewModes && !options.writesOnly
let needPrints = !options.writesOnly && external == nil && dino == nil
let needCats = options.boxes != nil || (needPrints && options.onlyNewModes)
let recognizer = VisionFurnitureRecognizer()
let printCache = options.cache ? PrintCache() : nil
var analyses: [String: Analysis] = [:]
var unreadable = 0
var cacheHits = 0
var noCat = 0
for (index, photo) in photos.enumerated() {
    // The same steps the app takes on import: decode with orientation applied, classify the
    // photo, and make prints from the 512 px thumbnail. One photo in memory at a time.
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: photo.path)) else {
        unreadable += 1
        continue
    }
    var analysis = Analysis(hash: PhotoIngest.sha256Hex(data))
    (analysis.time, analysis.place) = exifTimeAndPlace(path: photo.path)
    if let dino {
        // As in the app: the print is made from the stored 512 px thumbnail.
        guard let draft = try? PhotoIngest.makeDraft(data: data, filename: nil) else {
            unreadable += 1
            continue
        }
        let clock = ContinuousClock(), start = clock.now
        if let print = try? await dino.featurePrint(imageData: draft.thumbnailJPEG) {
            let elapsed = start.duration(to: clock.now).components
            dinoMilliseconds.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
            dinoVectors[analysis.hash] = print.vector
        } else {
            dinoFailed += 1
        }
    }
    if needClassifier || needPrints || needCats {
        var entry = printCache?.entry(for: analysis.hash) ?? CachedPhoto()
        func usable(_ id: String, _ analyzer: String) -> FeaturePrint? {
            entry.prints[id].flatMap { $0.analyzer == analyzer && $0.revision == VisionPhotoEmbedder.revision && !$0.vector.isEmpty ? $0 : nil }
        }
        let crops = options.onlyNewModes ? CatCrop.variants : []
        let missing = (needPrints && (VisionPhotoEmbedder.CatMasking.allCases.contains { usable($0.rawValue, VisionPhotoEmbedder(masking: $0).analyzer) == nil }
                                      || crops.contains { usable($0.id, $0.analyzer) == nil }))
            || (needCats && entry.cats == nil)
        if needClassifier || missing {
            guard let draft = try? PhotoIngest.makeDraft(data: data, filename: nil) else {
                unreadable += 1
                continue
            }
            if needClassifier { analysis.recognition = try? await recognizer.recognize(imageData: draft.data) }
            if missing, let image = PhotoIngest.downsampledImage(data: draft.thumbnailJPEG, maxPixel: VisionPhotoEmbedder.maxPixel) {
                if entry.cats == nil, let cats = try? await CatCrop.cats(in: image) {
                    entry.cats = cats.map { [$0.minX, $0.minY, $0.width, $0.height] }
                }
                if needPrints {
                    for masking in VisionPhotoEmbedder.CatMasking.allCases where usable(masking.rawValue, VisionPhotoEmbedder(masking: masking).analyzer) == nil {
                        entry.prints[masking.rawValue] = try? await VisionPhotoEmbedder(masking: masking).featurePrint(imageData: draft.thumbnailJPEG)
                    }
                    let cats = (entry.cats ?? []).map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
                    for variant in crops where usable(variant.id, variant.analyzer) == nil && entry.cats != nil {
                        entry.prints[variant.id] = try? await CatCrop.print(image, cats: cats, variant: variant)
                    }
                }
                printCache?.store(entry, for: analysis.hash)
            }
        } else {
            cacheHits += 1
        }
        for masking in VisionPhotoEmbedder.CatMasking.allCases {
            analysis.prints[masking] = usable(masking.rawValue, VisionPhotoEmbedder(masking: masking).analyzer)
        }
        for variant in crops { analysis.extra[variant.id] = usable(variant.id, variant.analyzer)?.vector }
        analysis.cats = entry.cats.map { $0.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } }
        if analysis.cats?.isEmpty == true { noCat += 1 }
    }
    analyses[photo.path] = analysis
    if (index + 1) % 25 == 0 { FileHandle.standardError.write(Data("  \(index + 1)/\(photos.count)\n".utf8)) }
}
if let printCache, needPrints || needCats {
    FileHandle.standardError.write(Data("prints: \(cacheHits) of \(photos.count) photos fully from the cache in \(printCache.directory.path) (--no-cache to bypass)\n".utf8))
}
print("photos: \(photos.count) (\(unreadable) unreadable), pieces: \(Set(photos.compactMap(\.piece)).count)\n")
if let dino, let model = options.coreml {
    guard !dinoVectors.isEmpty else { fail("--coreml \(model.lastPathComponent): no print could be made (\(dinoFailed) failed); see the log above") }
    let sorted = dinoMilliseconds.sorted()
    print("--coreml: \(dinoVectors.count) prints by \(dino.analyzer) r\(dino.revision), "
          + "\(dinoFailed) failed; median \(String(format: "%.1f", sorted[sorted.count / 2])) ms per print "
          + "(decode, resize and prediction; first print includes loading the model)")
    let file: [String: Any] = ["model": "\(dino.analyzer).r\(dino.revision)",
                               "dimension": dinoVectors.first!.value.count,
                               "vectors": dinoVectors.mapValues { $0.map(Double.init) }]
    let data: Data
    do { data = try JSONSerialization.data(withJSONObject: file) } catch { fail("--coreml: \(error.localizedDescription)") }
    if let url = options.writePrints {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        do { try data.write(to: url) } catch { fail("--write-prints: could not write \(url.path): \(error.localizedDescription)") }
        print("vectors written to \(url.path) (keyed by photo SHA-256, readable only by you; keep it out of the repo)")
    }
    do { external = try ExternalPrints.load(data) } catch { fail("--coreml: \(error)") }
}

if let url = options.listHashes {
    // Only {sha256: absolute path}, for a script on this Mac to find the photos. Outside the repo.
    var list: [String: String] = [:]
    for photo in photos { if let a = analyses[photo.path] { list[a.hash] = URL(fileURLWithPath: photo.path).standardizedFileURL.path } }
    writePrivateJSON(list, to: url)
    print("\(list.count) hashes and paths written to \(url.path) (readable only by you; keep it out of the repo)")
}
if let url = options.boxes {
    // Per sha256: cat boxes, normalised, origin top-left (as most image libraries count), x y w h.
    var boxes: [String: [[Double]]] = [:]
    for a in analyses.values { if let cats = a.cats { boxes[a.hash] = cats.map { [$0.minX, 1 - $0.maxY, $0.width, $0.height] } } }
    writePrivateJSON(boxes, to: url)
    print("cat boxes for \(boxes.count) photos written to \(url.path) (\(boxes.values.filter(\.isEmpty).count) with no cat found)")
}
if options.writesOnly { exit(0) }

if options.onlyNewModes {
    let signals: [Signal]
    if let external {
        let (_, missing) = external.lookup(analyses.values.map(\.hash))
        let s = external.skipped
        print("vectors from \(external.model): \(external.vectors.count) usable, dimension \(external.dimension); "
              + "photos without a vector \(missing) of \(analyses.count) (left out); entries skipped: \(s.total) "
              + "(bad key \(s.badKey), not numbers \(s.notNumbers), wrong dimension \(s.wrongDimension), not finite \(s.notFinite), all zero \(s.zero))\n")
        signals = [externalSignal(external)]
    } else {
        print("cat found by Vision in \(analyses.count - noCat) of \(analyses.count) photos; the crop variants use the whole picture for the rest\n")
        signals = visionSignals()
    }
    let report = runNewModes(photos, analyses: analyses, signals: signals, options: options)
    if let json = options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(report).write(to: json)
            print("numbers written to \(json.path)")
        } catch {
            fail("could not write \(json.path): \(error.localizedDescription)")
        }
    }
    exit(0)
}
let classifier = evaluateClassifier(photos, analyses: analyses, options: options)
let matching = VisionPhotoEmbedder.CatMasking.allCases.map { evaluateMatching(photos, analyses: analyses, masking: $0, options: options) }
let personal = runPersonal(photos, analyses: analyses)
let openSet = runOpenSet(photos, analyses: analyses)
runAlwaysList(photos, analyses: analyses)
if CommandLine.arguments.contains("--timing") { timeTraining() }
if let json = options.json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        try encoder.encode(Report(classifier: classifier, matching: matching, personal: personal, openSet: openSet)).write(to: json)
        print("numbers written to \(json.path)")
    } catch {
        fail("could not write \(json.path): \(error.localizedDescription)")
    }
}
