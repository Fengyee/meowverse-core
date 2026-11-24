import CoreGraphics
import CoreML
import Foundation
import ImageIO
import MeowverseCore
@testable import recognition_eval
import Testing
import UniformTypeIdentifiers

/// The app's DINOv2 embedder (`ios/Meowverse/App/DinoPhotoEmbedder.swift`, the same file) with
/// the shipped model, on pictures drawn here: no private photo is read. Each picture goes the
/// app's way, `PhotoIngest.makeDraft` to the 512 px thumbnail, through `FeaturePrintCache`, then
/// the review's `SimilarFurniture.suggest` and the batch rule with the shipped numbers. Two
/// near-duplicate pictures of one piece must be offered that piece.
@Suite(.serialized) struct DinoEndToEndTests {
    static let model = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Meowverse/Resources/Models/DinoV2ViTB14Reg.mlpackage")

    /// Three scenes; `variant` moves the piece a little, changes the light and may add a ball.
    enum Scene: CaseIterable { case sofa, lamp, rug }

    static func picture(_ scene: Scene, variant: Int) throws -> Data {
        let width = 1024, height = 768
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let shift = CGFloat(variant * 14), light = 1 - CGFloat(variant) * 0.04
        func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect, round: CGFloat = 0) {
            context.setFillColor(CGColor(srgbRed: r * light, green: g * light, blue: b * light, alpha: 1))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: round, cornerHeight: round, transform: nil))
            context.fillPath()
        }
        switch scene {
        case .sofa:
            fill(0.93, 0.86, 0.74, CGRect(x: 0, y: 0, width: width, height: height))
            fill(0.55, 0.42, 0.30, CGRect(x: 0, y: 0, width: width, height: 180))
            fill(0.70, 0.84, 0.95, CGRect(x: 620, y: 420, width: 260, height: 240))
            fill(0.30, 0.45, 0.62, CGRect(x: 120 + shift, y: 170, width: 560, height: 230), round: 40)
            fill(0.36, 0.52, 0.70, CGRect(x: 150 + shift, y: 330, width: 240, height: 140), round: 30)
            fill(0.36, 0.52, 0.70, CGRect(x: 410 + shift, y: 330, width: 240, height: 140), round: 30)
        case .lamp:
            fill(0.20, 0.32, 0.30, CGRect(x: 0, y: 0, width: width, height: height))
            for stripe in stride(from: 0, to: width, by: 64) {
                fill(0.26, 0.40, 0.37, CGRect(x: stripe, y: 0, width: 24, height: height))
            }
            fill(0.85, 0.80, 0.30, CGRect(x: 420 + shift, y: 520, width: 200, height: 140), round: 12)
            fill(0.12, 0.12, 0.12, CGRect(x: 510 + shift, y: 120, width: 20, height: 400))
            fill(0.12, 0.12, 0.12, CGRect(x: 440 + shift, y: 100, width: 160, height: 30), round: 8)
        case .rug:
            fill(0.96, 0.96, 0.96, CGRect(x: 0, y: 0, width: width, height: height))
            for row in 0..<8 { for column in 0..<10 where (row + column).isMultiple(of: 2) {
                fill(0.20, 0.55, 0.25, CGRect(x: column * 102, y: row * 96, width: 102, height: 96))
            } }
            fill(0.75, 0.15, 0.12, CGRect(x: 380 + shift, y: 260, width: 280, height: 260), round: 140)
        }
        if variant == 2 { fill(0.95, 0.35, 0.20, CGRect(x: 760, y: 200, width: 70, height: 70), round: 35) }
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// `all` is what the app asks for (with the CPU self-check behind it); `cpuOnly` is the reference.
    @Test(arguments: [MLComputeUnits.cpuOnly, .all])
    func nearDuplicatesOfOnePieceAreOfferedThatPiece(units: MLComputeUnits) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dino-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Filed: two photos of each piece. Asked about: a third photo of the sofa and of the lamp.
        var urls: [String: URL] = [:]
        for scene in Scene.allCases {
            for variant in 0...2 {
                let draft = try PhotoIngest.makeDraft(data: try Self.picture(scene, variant: variant), filename: nil)
                let url = folder.appending(path: "\(scene)-\(variant).jpg")
                try draft.thumbnailJPEG.write(to: url)
                urls["\(scene)-\(variant)"] = url
            }
        }
        let embedder = DinoPhotoEmbedder(modelURL: Self.model, computeUnits: units, fallback: nil)
        let cache = FeaturePrintCache(fileURL: folder.appending(path: "prints.bin"), analyzer: embedder.analyzer,
                                      revision: embedder.revision)
        let ids = urls.keys.sorted(), files = urls
        await cache.refresh(ids, input: { files[$0] }, embed: { try await embedder.featurePrint(imageData: $0) })

        var references: [FurniturePhotoPrint] = []
        for scene in Scene.allCases {
            for variant in 0...1 {
                let print = try #require(await cache.print(for: "\(scene)-\(variant)"), "the cache keeps the DINOv2 print")
                references.append(FurniturePhotoPrint(instanceId: "\(scene)", photoId: "\(scene)-\(variant)", print: print))
            }
        }
        for scene in [Scene.sofa, .lamp] {
            let query = try #require(await cache.print(for: "\(scene)-2"))
            #expect(query.analyzer == KnownAnalyzer.dinoV2)
            let length = query.vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
            #expect(abs(length - 1) < 1e-3, "prints are unit length, the scale the thresholds were measured on")
            let nearest = references.compactMap { query.distance(to: $0.print) }.min() ?? .infinity
            #expect(nearest <= SimilarFurniture.dinoMaximumDistance, "nearest \(nearest)")

            let review = SimilarFurniture.suggest(query, against: references)
            #expect(review.first?.instanceId == "\(scene)", "review offers \(review.map(\.instanceId)), nearest \(nearest)")

            let offers = BatchSuggestions.offers(for: [SuggestionCandidate(photoId: "\(scene)-2")], prints: ["\(scene)-2": query],
                                                 references: references, boards: [], declined: [])
            #expect(offers.map(\.instanceId) == ["\(scene)"], "batch rule offers \(offers.map(\.instanceId))")
        }
    }
}
