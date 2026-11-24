import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import MeowverseCore
import os

/// Feature prints from DINOv2 ViT-B/14 with registers (Meta AI, Apache 2.0), 8-bit weights,
/// converted by `ios/Tools/EmbeddingLab` (provenance in `ios/Tools/EmbeddingLab/PROVENANCE.md`).
///
/// The vector is the mean of the patch tokens, not the CLS token: the CLS token describes the
/// cat, the patches the room and the furniture. Measurements: `MeowverseCore/RECOGNITION_NOTES.md`.
///
/// Input is the same stored 512 px thumbnail Vision is given. The whole picture is squashed to
/// 224 × 224 with the resampler the reference vectors were made with (PIL's antialiased bicubic,
/// ported byte for byte). On the owner's 168 photos this came closest to the PyTorch vectors
/// (median cosine 0.9984; CGContext 0.9978, vImage Lanczos 0.9979, Core Image Lanczos 0.985);
/// what is left is the thumbnail itself (512 px, JPEG), not the resize.
///
/// This file is also compiled into `ios/Tools/RecognitionEval` (a symbolic link), so the
/// evaluation tool measures exactly this code. Keep it free of app-only types; the types are
/// `nonisolated` because the app target defaults to MainActor and the tool does not.
nonisolated struct DinoPhotoEmbedder: PhotoEmbedding {
    static let analyzerName = "dinov2.vitb14reg.int8.meanpatch"
    /// Raise when the model, the pooling or the preprocessing changes: cached prints are then remade.
    /// 2: prints are scaled to unit length. Revision 1 stored the model's raw output (length
    /// about 3 to 5), so every distance was far beyond the cut measured on unit vectors and no
    /// photo was ever matched on a device (round 8).
    static let revision = 2
    /// The compiled model in the app bundle (Xcode compiles `Resources/Models/<name>.mlpackage`).
    static let resourceName = "DinoV2ViTB14Reg"
    static let side = 224
    static let dimension = 768

    let runner: Runner
    /// Used when the model cannot be loaded; nil makes that an error instead (evaluation tool).
    let fallback: (any PhotoEmbedding)?

    /// What loading the model came to, for the interface and the bug report.
    enum LoadOutcome: Sendable, Equatable {
        case loaded(RecognitionDiagnostics.Load)
        case failed(reason: String)
    }

    /// Where the self-check's answer is kept (`ComputeUnitsMemo`); nil checks on every load.
    struct Memo: Sendable {
        let recall: @Sendable () -> ComputeUnitsMemo.Choice?
        let store: @Sendable (ComputeUnitsMemo.Choice) -> Void
    }

    init(modelURL: URL, computeUnits: MLComputeUnits = .all, fallback: (any PhotoEmbedding)? = VisionPhotoEmbedder(),
         onLoad: (@Sendable (LoadOutcome) -> Void)? = nil, memo: Memo? = nil) {
        runner = Runner(modelURL: modelURL, computeUnits: computeUnits, onLoad: onLoad, memo: memo)
        self.fallback = fallback
    }

    var analyzer: String { Self.analyzerName }
    var revision: Int { Self.revision }

    /// Starts loading the model in the background, so the first print does not wait for it.
    func preload() {
        let runner = runner
        _Concurrency.Task.detached(priority: .utility) { await runner.load() }
    }

    func featurePrint(imageData: Data) async throws -> FeaturePrint {
        try _Concurrency.Task.checkCancellation()
        guard let image = PhotoIngest.downsampledImage(data: imageData, maxPixel: PhotoIngest.thumbnailMaxPixel),
              let pixels = Self.squashed(image, side: Self.side)
        else { throw RecognitionError.undecodableImage }
        try _Concurrency.Task.checkCancellation()
        do {
            let vector = try await runner.embed(rgb: pixels, side: Self.side)
            return FeaturePrint(analyzer: analyzer, revision: revision, vector: vector)
        } catch Runner.Failure.load {
            guard let fallback else { throw Runner.Failure.load }
            return try await fallback.featurePrint(imageData: imageData)
        }
    }

    /// Loads the model once and runs one prediction at a time.
    actor Runner {
        enum Failure: Error { case load, output }
        private enum State { case idle, loaded(MLModel), failed }

        let modelURL: URL
        let computeUnits: MLComputeUnits
        private let onLoad: (@Sendable (LoadOutcome) -> Void)?
        private let memo: Memo?
        private var state = State.idle
        private static let log = Logger(subsystem: "app.meowverse", category: "similarity")
        /// Squared distance between the self-check's two unit prints above which the requested
        /// compute units are not trusted. Float16 against Float32 on the same 8-bit weights
        /// stays far below it; a broken accelerator path does not.
        static let selfCheckTolerance: Float = 0.05

        init(modelURL: URL, computeUnits: MLComputeUnits, onLoad: (@Sendable (LoadOutcome) -> Void)?, memo: Memo?) {
            self.modelURL = modelURL
            self.computeUnits = computeUnits
            self.onLoad = onLoad
            self.memo = memo
        }

        /// The one load in flight: `preload()` and the first prints share it (the actor is
        /// reentrant at `await`, so without it each could load the 86 MB model).
        private var loading: _Concurrency.Task<Void, Never>?

        /// Loads the model if it is not loaded yet; false when it cannot be.
        @discardableResult
        func load() async -> Bool {
            (try? await model()) != nil
        }

        private func model() async throws -> MLModel {
            if case .idle = state {
                let task = loading ?? _Concurrency.Task { await self.performLoad() }
                loading = task
                await task.value
            }
            guard case .loaded(let model) = state else { throw Failure.load }
            return model
        }

        /// Tries the requested compute units, then the CPU alone; leaves `state` loaded or failed.
        ///
        /// A model that loads on the requested units must also agree with the CPU on a fixed
        /// synthetic picture (the self-check): an accelerator path that returns garbage or NaN
        /// would otherwise give prints that never match anything, on that device only. The answer
        /// is remembered (`memo`, per build, iOS version and model revision), so later launches
        /// load one model: the requested units (still giving a finite probe print) or the CPU.
        private func performLoad() async {
            var url = modelURL
            if url.pathExtension == "mlpackage" {   // the evaluation tool; the app bundle holds .mlmodelc
                do { url = try await MLModel.compileModel(at: url) } catch {
                    return fail("compile: \(error.localizedDescription)")
                }
            }
            let compiled = url
            func load(_ units: MLComputeUnits) async throws -> MLModel {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = units
                return try await MLModel.load(contentsOf: compiled, configuration: configuration)
            }
            let clock = ContinuousClock()
            func milliseconds(since start: ContinuousClock.Instant) -> Int {
                let elapsed = start.duration(to: clock.now).components
                return Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
            }
            let recalled = computeUnits == .cpuOnly ? nil : memo?.recall()
            var chosen: (model: MLModel, units: MLComputeUnits, loadMs: Int, checkMs: Int?, check: String)?
            var lastError: (any Error)?
            if computeUnits != .cpuOnly, recalled != .cpuOnly {
                let start = clock.now
                do {
                    let model = try await load(computeUnits)
                    chosen = (model, computeUnits, milliseconds(since: start), nil, recalled == nil ? "not checked" : "self-check remembered")
                } catch {
                    lastError = error
                }
            }
            if let requested = chosen {
                let checkStart = clock.now
                let probe = Self.probePrint(requested.model)
                if recalled == .requested {
                    // Remembered as good: one probe print, which must still be finite.
                    if probe == nil { chosen = nil }
                } else if let cpu = try? await load(.cpuOnly), let reference = Self.probePrint(cpu) {
                    // The reference is the CPU on the same picture.
                    let distance = probe.flatMap { FeaturePrint(analyzer: "", revision: 0, vector: $0)
                        .distance(to: FeaturePrint(analyzer: "", revision: 0, vector: reference)) }
                    if let distance, distance <= Self.selfCheckTolerance {
                        chosen?.check = "matches cpuOnly (d \(String(format: "%.4f", distance)))"
                        memo?.store(.requested)
                    } else {
                        let what = distance.map { "d \(String(format: "%.3f", $0))" } ?? "no finite print"
                        chosen = (cpu, .cpuOnly, requested.loadMs, nil, "units \(Self.name(requested.units)) disagreed with cpuOnly (\(what))")
                        memo?.store(.cpuOnly)
                    }
                    chosen?.checkMs = milliseconds(since: checkStart)
                } else if probe == nil {
                    chosen = nil   // no print from the requested units and no CPU to fall back on
                }
            }
            if chosen == nil {
                let start = clock.now
                let why = computeUnits == .cpuOnly ? "requested" : recalled == .cpuOnly ? "self-check remembered (cpuOnly)" : "requested units unusable"
                do { chosen = (try await load(.cpuOnly), .cpuOnly, milliseconds(since: start), nil, why) } catch {
                    lastError = error
                }
            }
            guard let chosen else { return fail("load: \(lastError?.localizedDescription ?? "no usable print")") }
            state = .loaded(chosen.model)
            let outcome = RecognitionDiagnostics.Load(units: Self.name(chosen.units), loadMilliseconds: chosen.loadMs,
                                                      selfCheckMilliseconds: chosen.checkMs,
                                                      firstLoadOfBuild: computeUnits != .cpuOnly && recalled == nil, selfCheck: chosen.check)
            Self.log.notice("DINOv2 embedder loaded (compute units \(outcome.units, privacy: .public), load \(outcome.loadMilliseconds, privacy: .public) ms, self-check \(outcome.selfCheckMilliseconds ?? 0, privacy: .public) ms, \(outcome.selfCheck, privacy: .public))")
            onLoad?(.loaded(outcome))
        }

        private static func name(_ units: MLComputeUnits) -> String {
            switch units {
            case .cpuOnly: "cpuOnly"
            case .cpuAndGPU: "cpuAndGPU"
            case .cpuAndNeuralEngine: "cpuAndNE"
            case .all: "all"
            @unknown default: "units \(units.rawValue)"
            }
        }

        private func fail(_ reason: String) {
            state = .failed
            Self.log.error("DINOv2 embedder unavailable: \(reason, privacy: .public)")
            onLoad?(.failed(reason: reason))
        }

        /// A fixed synthetic picture (gradients and stripes), the same on every device.
        static let probe: [UInt8] = {
            let side = DinoPhotoEmbedder.side
            var rgb = [UInt8](repeating: 0, count: side * side * 3)
            for y in 0..<side {
                for x in 0..<side {
                    let at = (y * side + x) * 3
                    rgb[at] = UInt8((x * 255) / (side - 1))
                    rgb[at + 1] = UInt8((y * 255) / (side - 1))
                    rgb[at + 2] = (x / 16 + y / 16).isMultiple(of: 2) ? 200 : 40
                }
            }
            return rgb
        }()

        /// The unit print of `probe` on `model`, nil when it cannot be made or is not finite.
        private static func probePrint(_ model: MLModel) -> [Float]? {
            (try? rawVector(model, rgb: probe, side: DinoPhotoEmbedder.side)).flatMap(FeaturePrint.unitVector)
        }

        /// `rgb`: side × side × 3 bytes, row-major, top row first. Unit length: the model's
        /// output is not normalised, and every distance cut was measured on unit vectors.
        func embed(rgb: [UInt8], side: Int) async throws -> [Float] {
            let model = try await model()
            guard let vector = FeaturePrint.unitVector(try Self.rawVector(model, rgb: rgb, side: side)) else { throw Failure.output }
            return vector
        }

        private static func rawVector(_ model: MLModel, rgb: [UInt8], side: Int) throws -> [Float] {
            guard let buffer = DinoPhotoEmbedder.pixelBuffer(rgb: rgb, side: side) else { throw Failure.output }
            let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
            let output = try predict(model, input)
            guard let array = output.featureValue(for: "embedding")?.multiArrayValue, array.count > 0 else { throw Failure.output }
            var vector = [Float](repeating: 0, count: array.count)
            for index in 0..<array.count { vector[index] = array[index].floatValue }
            return vector
        }

        /// The synchronous prediction (an async context would pick the async overload): one at a
        /// time on this actor.
        private static func predict(_ model: MLModel, _ input: any MLFeatureProvider) throws -> any MLFeatureProvider {
            try model.prediction(from: input)
        }
    }
}

// MARK: - Preprocessing

nonisolated extension DinoPhotoEmbedder {
    /// The picture squashed to `side` × `side` with PIL's bicubic, as RGB bytes (top row first).
    static func squashed(_ image: CGImage, side: Int) -> [UInt8]? {
        guard let rgbx = storedRGBX(image) else { return nil }
        let square = PILResample.resize(rgbx, width: image.width, height: image.height, toWidth: side, toHeight: side)
        var rgb = [UInt8](repeating: 0, count: side * side * 3)
        for pixel in 0..<(side * side) {
            rgb[pixel * 3] = square[pixel * 4]
            rgb[pixel * 3 + 1] = square[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = square[pixel * 4 + 2]
        }
        return rgb
    }

    /// The decoded pixels as stored, without colour conversion (as PIL reads them): RGBX bytes.
    private static func storedRGBX(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard let space = image.colorSpace.flatMap({ $0.model == .rgb ? $0 : nil }) ?? CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// A 32BGRA pixel buffer from RGB bytes; Core ML converts it to the model's RGB input.
    static func pixelBuffer(rgb: [UInt8], side: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<side {
            for x in 0..<side {
                let from = (y * side + x) * 3, to = y * rowBytes + x * 4
                pixels[to] = rgb[from + 2]
                pixels[to + 1] = rgb[from + 1]
                pixels[to + 2] = rgb[from]
                pixels[to + 3] = 255
            }
        }
        return buffer
    }
}

/// PIL's 8-bit resampling with the bicubic filter (Pillow `libImaging/Resample.c`): separable,
/// antialiased when shrinking (the kernel widens by the scale), fixed-point weights with 22
/// fractional bits, horizontal pass first, each pass rounded and clipped to a byte. Checked byte
/// for byte against Pillow on 512×384, 384×512 and 300×200 inputs. The fourth byte is skipped.
nonisolated enum PILResample {
    private static let precisionBits = 22
    private static let support = 2.0

    private static func bicubic(_ value: Double) -> Double {
        let a = -0.5, x = abs(value)
        if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
        if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
        return 0
    }

    /// For each output index: first input index and fixed-point weights.
    private static func coefficients(input: Int, output: Int) -> [(start: Int, weights: [Int32])] {
        let scale = Double(input) / Double(output)
        let filterScale = max(scale, 1)
        let reach = support * filterScale
        return (0..<output).map { index in
            let center = (Double(index) + 0.5) * scale
            let lower = max(Int(center - reach + 0.5), 0)
            let upper = min(Int(center + reach + 0.5), input)
            var weights = (lower..<upper).map { bicubic((Double($0) - center + 0.5) / filterScale) }
            let total = weights.reduce(0, +)
            if total != 0 { weights = weights.map { $0 / total } }
            let unit = Double(1 << precisionBits)
            return (lower, weights.map { w in Int32(w < 0 ? (-0.5 + w * unit) : (0.5 + w * unit)) })
        }
    }

    private static func clip(_ sum: Int64) -> UInt8 {
        let value = sum >> Int64(precisionBits)
        return UInt8(min(max(value, 0), 255))
    }

    /// RGBX bytes in, RGBX bytes out: the three colour channels are resampled, the fourth is left 0.
    static func resize(_ pixels: [UInt8], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [UInt8] {
        var current = pixels, currentWidth = width
        let half = Int64(1) << Int64(precisionBits - 1)
        if toWidth != width {
            let table = coefficients(input: width, output: toWidth)
            var out = [UInt8](repeating: 0, count: toWidth * height * 4)
            for y in 0..<height {
                for (x, entry) in table.enumerated() {
                    for channel in 0..<3 {
                        var sum = half
                        for (offset, weight) in entry.weights.enumerated() {
                            sum += Int64(current[(y * width + entry.start + offset) * 4 + channel]) * Int64(weight)
                        }
                        out[(y * toWidth + x) * 4 + channel] = clip(sum)
                    }
                }
            }
            current = out
            currentWidth = toWidth
        }
        if toHeight != height {
            let table = coefficients(input: height, output: toHeight)
            var out = [UInt8](repeating: 0, count: currentWidth * toHeight * 4)
            for (y, entry) in table.enumerated() {
                for x in 0..<currentWidth {
                    for channel in 0..<3 {
                        var sum = half
                        for (offset, weight) in entry.weights.enumerated() {
                            sum += Int64(current[((entry.start + offset) * currentWidth + x) * 4 + channel]) * Int64(weight)
                        }
                        out[(y * currentWidth + x) * 4 + channel] = clip(sum)
                    }
                }
            }
            current = out
        }
        return current
    }
}

// MARK: - Choosing the embedder

/// The embedder the app uses: DINOv2 when its model is in the bundle and has not failed to load
/// on this build before, otherwise Vision's feature prints. Selecting the colour grid for UI
/// tests stays in `AppModel`.
nonisolated enum PhotoEmbedderFactory {
    /// Set when the model failed to load, to the build that failed; the next launch of that
    /// build starts with Vision so its print cache is coherent from the start.
    static let failureKey = "MeowverseDinoEmbedderFailedBuild"

    /// The DINOv2 embedder has no fallback of its own: when its model fails to load, its prints
    /// fail and `onLoad` hears `.failed`, and the app switches to Vision as a whole (embedder,
    /// print cache and labels together), so a Vision print is never kept under DINOv2's name or
    /// dropped by a cache opened for DINOv2 (round 8: that left the whole launch with no match).
    static func make(bundle: Bundle = .main, defaults: UserDefaults = .standard,
                     onLoad: @escaping @Sendable (DinoPhotoEmbedder.LoadOutcome) -> Void) -> any PhotoEmbedding {
        let build = (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        guard let url = bundle.url(forResource: DinoPhotoEmbedder.resourceName, withExtension: "mlmodelc"),
              defaults.string(forKey: failureKey) != build
        else { return VisionPhotoEmbedder() }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let scope = ComputeUnitsMemo.scope(build: build, os: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                                           modelRevision: DinoPhotoEmbedder.revision)
        let memo = DinoPhotoEmbedder.Memo(recall: { ComputeUnitsMemo.recall(scope, in: .standard) },
                                          store: { ComputeUnitsMemo.remember($0, for: scope, in: .standard) })
        // Not preloaded: the model loads with the first print that is needed, so a launch with
        // every print already made never loads it (round 8: 11.6 s on the first launch of a build).
        return DinoPhotoEmbedder(modelURL: url, fallback: nil, onLoad: { outcome in
            if case .failed = outcome { UserDefaults.standard.set(build, forKey: failureKey) }
            onLoad(outcome)
        }, memo: memo)
    }
}
