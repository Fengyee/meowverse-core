import CoreGraphics
import Foundation

/// A stand-in for `VisionPhotoEmbedder` in UI tests only: Vision's networks do not run on the
/// simulator, so the look-alike suggestion could not be exercised there at all. The picture is
/// shrunk to an 8 × 8 grid of average colours, unit length. Two nearly identical pictures land
/// close together, which is all a UI test needs. It says nothing about real photos and is never
/// used outside a test launch; its analyzer name keeps its prints apart from Vision's.
public struct ColorGridEmbedder: PhotoEmbedding {
    static let side = 8

    public init() {}

    public static let analyzerName = "test.colorGrid"
    public var analyzer: String { Self.analyzerName }
    public var revision: Int { 1 }

    public func featurePrint(imageData: Data) async throws -> FeaturePrint {
        guard let image = PhotoIngest.downsampledImage(data: imageData, maxPixel: PhotoIngest.thumbnailMaxPixel),
              let vector = Self.grid(image)
        else { throw RecognitionError.undecodableImage }
        return FeaturePrint(analyzer: analyzer, revision: revision, vector: vector)
    }

    static func grid(_ image: CGImage) -> [Float]? {
        let side = Self.side
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var vector: [Float] = []
        vector.reserveCapacity(side * side * 3)
        for pixel in 0..<(side * side) {
            for channel in 0..<3 { vector.append(Float(bytes[pixel * 4 + channel]) / 255) }
        }
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0 else { return vector }
        return vector.map { $0 / length }
    }
}
