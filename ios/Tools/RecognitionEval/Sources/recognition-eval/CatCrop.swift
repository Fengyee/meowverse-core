import CoreGraphics
import Foundation
import MeowverseCore
import Vision

/// Vision prints of the cat's neighbourhood: the cat sits on the furniture, so the region around
/// it should say more about the piece than the whole room does. The crop is the cat box (all cats
/// Vision finds) grown by a factor (`PhotoClustering.neighbourhood`), with the cat left in or
/// painted over first as the app does. A photo where no cat is found falls back to the whole
/// picture. Same 512 px thumbnail as the app's prints.
enum CatCrop {
    struct Variant {
        let factor: Double
        let coverCat: Bool
        var id: String { "vision.cat\(factor)x" + (coverCat ? ".catCovered" : "") }
        var name: String { "Vision, \(factor)× around the cat, cat \(coverCat ? "painted over" : "left in")" }
        var analyzer: String { "eval.catNeighbourhood.\(factor)" + (coverCat ? ".catCovered" : "") }
    }

    static let variants: [Variant] = [1.5, 2.5].flatMap { f in [false, true].map { Variant(factor: f, coverCat: $0) } }
    /// The app grows a cat box by this much on each side before painting it over.
    static let coverMargin: CGFloat = 0.08

    /// Cat boxes, normalised with Vision's lower-left origin.
    static func cats(in image: CGImage) async throws -> [CGRect] {
        try await RecognizeAnimalsRequest().perform(on: image)
            .filter { $0.labels.contains { $0.identifier.lowercased() == "cat" } }
            .map(\.boundingBox.cgRect)
    }

    static func print(_ image: CGImage, cats: [CGRect], variant: Variant) async throws -> FeaturePrint {
        var input = image
        if let region = PhotoClustering.neighbourhood(of: cats, factor: variant.factor) {
            let painted = variant.coverCat ? (cover(cats, in: image) ?? image) : image
            let w = CGFloat(image.width), h = CGFloat(image.height)
            // CGImage cropping counts rows from the top; Vision's boxes count from the bottom.
            let pixels = CGRect(x: region.minX * w, y: (1 - region.maxY) * h, width: region.width * w, height: region.height * h).integral
            if pixels.width >= 16, pixels.height >= 16, let cropped = painted.cropping(to: pixels) { input = cropped }
        }
        let observation = try await GenerateImageFeaturePrintRequest().perform(on: input)
        let vector: [Float] = observation.data.withUnsafeBytes { raw in
            switch observation.elementType {
            case .double: raw.bindMemory(to: Double.self).prefix(observation.elementCount).map { Float($0) }
            default: Array(raw.bindMemory(to: Float.self).prefix(observation.elementCount))
            }
        }
        return FeaturePrint(analyzer: variant.analyzer, revision: VisionPhotoEmbedder.revision, vector: vector)
    }

    /// Paints the boxes with the picture's average colour, as `VisionPhotoEmbedder` does.
    static func cover(_ boxes: [CGRect], in image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: full)
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            guard let one = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            one.interpolationQuality = .medium
            one.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        context.setFillColor(CGColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1))
        for box in boxes {
            let p = CGRect(x: box.minX * CGFloat(width), y: box.minY * CGFloat(height),
                           width: box.width * CGFloat(width), height: box.height * CGFloat(height))
            context.fill(p.insetBy(dx: -p.width * coverMargin, dy: -p.height * coverMargin).intersection(full))
        }
        return context.makeImage()
    }
}
