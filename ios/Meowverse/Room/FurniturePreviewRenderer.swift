import CoreGraphics
import Foundation
import MeowverseCore
import simd

/// An orthographic product portrait, rasterized once when the selected style changes.
/// A private depth buffer keeps legs, cubby openings and overlapping platforms correctly ordered.
nonisolated enum FurniturePreviewRenderer {
    private struct Face {
        var a, b, c: SIMD3<Float>
        let color: UInt32
    }

    private static let eye = simd_normalize(SIMD3<Float>(5, 4, 8))
    private static let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), eye))
    private static let up = simd_cross(eye, right)
    private static let sun = simd_normalize(SIMD3<Float>(-4, 8, 6))

    static func image(model: CatalogModel, finish: Finish) throws -> CGImage {
        let faces: [Face]
        if model.mount == .wall {
            faces = boardFaces(width: model.defaultWidth, finish: finish)
        } else {
            let mesh = try FurnitureMesh.decode(ArtLibrary.data(model.id, "json"))
            faces = try project(mesh, modelId: model.id, orientation: Float(model.orientationY), finish: finish)
        }
        guard let first = faces.first else { throw ArtLibrary.ArtError.missing(model.id) }
        var low = first.a, high = first.a
        for face in faces {
            low = simd_min(low, simd_min(face.a, simd_min(face.b, face.c)))
            high = simd_max(high, simd_max(face.a, simd_max(face.b, face.c)))
        }
        let span = high - low, scale = 508 / max(span.x, span.y, 0.001)
        let width = max(1, Int(ceil(span.x * scale)) + 4), height = max(1, Int(ceil(span.y * scale)) + 4)
        var pixels = [UInt32](repeating: 0, count: width * height)
        var depth = [Float](repeating: -.infinity, count: pixels.count)
        func screen(_ p: SIMD3<Float>) -> SIMD3<Float> {
            [(p.x - low.x) * scale + 2, (p.y - low.y) * scale + 2, p.z]
        }
        for (index, face) in faces.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            draw(Face(a: screen(face.a), b: screen(face.b), c: screen(face.c), color: face.color),
                 width: width, height: height, pixels: &pixels, depth: &depth)
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { throw ArtLibrary.ArtError.missing(model.id) }
        return image
    }

    /// Into view space: x right, y down, z towards the viewer.
    private static func view(_ p: SIMD3<Float>) -> SIMD3<Float> {
        [simd_dot(p, right), -simd_dot(p, up), simd_dot(p, eye)]
    }

    /// Flat shading; `diffuse` is the cosine between the face normal and the sun.
    private static func shaded(_ base: SIMD3<Float>, diffuse: Float) -> UInt32 {
        let lit = base * (0.78 + 0.22 * max(0, diffuse) + 0.08 * min(0, diffuse))
        func byte(_ v: Float) -> UInt32 { UInt32(UInt8(clamping: Int((255 * v).rounded()))) }
        return byte(lit.x) | byte(lit.y) << 8 | byte(lit.z) << 16 | 0xff000000
    }

    /// The photo board has no baked mesh: its boxes are turned into faces here, seen from the front.
    private static func boardFaces(width: Int, finish: Finish) -> [Face] {
        // Corner indices (bit 0: +x, bit 1: +y, bit 2: +z) of each side, and the side's normal.
        let sides: [(corners: [Int], normal: SIMD3<Float>)] = [
            ([1, 3, 7, 5], [1, 0, 0]), ([0, 4, 6, 2], [-1, 0, 0]), ([2, 6, 7, 3], [0, 1, 0]),
            ([0, 1, 5, 4], [0, -1, 0]), ([4, 5, 7, 6], [0, 0, 1]), ([0, 2, 3, 1], [0, 0, -1]),
        ]
        var faces: [Face] = []
        for box in PhotoBoardDesign.boxes(width: width, finish: finish) {
            let tilt = simd_quatf(angle: box.tilt, axis: [0, 0, 1])
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
            box.color.getRed(&r, green: &g, blue: &b, alpha: &alpha)
            let base = SIMD3<Float>(Float(r), Float(g), Float(b))
            let corners = (0..<8).map { index in
                let sign = SIMD3<Float>(index & 1 == 0 ? -1 : 1, index & 2 == 0 ? -1 : 1, index & 4 == 0 ? -1 : 1)
                return view(box.centre + tilt.act(box.size / 2 * sign))
            }
            for side in sides {
                let color = shaded(base, diffuse: simd_dot(tilt.act(side.normal), sun))
                let c = side.corners.map { corners[$0] }
                faces.append(Face(a: c[0], b: c[1], c: c[2], color: color))
                faces.append(Face(a: c[0], b: c[2], c: c[3], color: color))
            }
        }
        return faces
    }

    /// Palette looks of v2 models: the portrait shows a slot's preset colour (patterns are left out
    /// at this size); v1 models keep their tinted flat colours.
    private static let looks = FurnitureLooks.bundled

    private static func baseColor(_ material: FurnitureMesh.Material, modelId: String, finish: Finish) -> SIMD3<Float> {
        if let slot = material.slot, let look = looks.material(modelId: modelId, finish: finish, slot: slot) {
            return SIMD3(Float(look.color[0]), Float(look.color[1]), Float(look.color[2]))
        }
        let rgb = material.color
        let tinted = ArtLibrary.color([rgb[0], rgb[1], rgb[2]], materialName: material.name, finish: finish)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
        tinted.getRed(&r, green: &g, blue: &b, alpha: &alpha)
        return SIMD3(Float(r), Float(g), Float(b))
    }

    private static func project(_ mesh: FurnitureMesh, modelId: String, orientation: Float, finish: Finish) throws -> [Face] {
        let rotation = simd_quatf(angle: orientation, axis: [0, 1, 0])
        let light = rotation.inverse.act(sun)
        var faces: [Face] = []
        for part in mesh.parts {
            try Task.checkCancellation()
            let base = baseColor(part.material, modelId: modelId, finish: finish)
            func vertex(_ index: UInt32) -> SIMD3<Float> {
                let k = Int(index) * 3
                return SIMD3(part.positions[k], part.positions[k + 1], part.positions[k + 2])
            }
            func normal(_ index: UInt32) -> SIMD3<Float> {
                let k = Int(index) * 3
                return SIMD3(part.normals[k], part.normals[k + 1], part.normals[k + 2])
            }
            for i in stride(from: 0, to: part.indices.count - 2, by: 3) {
                let corners = [part.indices[i], part.indices[i + 1], part.indices[i + 2]]
                let n = corners.reduce(SIMD3<Float>.zero) { $0 + normal($1) }
                let color = shaded(base, diffuse: simd_dot(n, light) / max(simd_length(n), 0.001))
                faces.append(Face(a: view(rotation.act(vertex(corners[0]))), b: view(rotation.act(vertex(corners[1]))),
                                  c: view(rotation.act(vertex(corners[2]))), color: color))
            }
        }
        return faces
    }

    private static func draw(_ face: Face, width: Int, height: Int, pixels: inout [UInt32], depth: inout [Float]) {
        let a = face.a, b = face.b, c = face.c
        let ab = b - a, ac = c - a, det = ab.x * ac.y - ab.y * ac.x
        guard abs(det) > 1e-6 else { return }
        let low = simd_min(a, simd_min(b, c)), high = simd_max(a, simd_max(b, c))
        let x0 = max(0, Int(floor(low.x))), x1 = min(width - 1, Int(ceil(high.x)))
        let y0 = max(0, Int(floor(low.y))), y1 = min(height - 1, Int(ceil(high.y)))
        guard x0 <= x1, y0 <= y1 else { return }
        let du = ac.y / det, dv = -ab.y / det
        for y in y0...y1 {
            let py = Float(y) + 0.5 - a.y, px = Float(x0) + 0.5 - a.x
            var u = (px * ac.y - py * ac.x) / det, v = (py * ab.x - px * ab.y) / det
            for x in x0...x1 {
                if u >= -0.00001, v >= -0.00001, u + v <= 1.00001 {
                    let index = y * width + x, z = a.z + u * ab.z + v * ac.z
                    if z > depth[index] { depth[index] = z; pixels[index] = face.color }
                }
                u += du
                v += dv
            }
        }
    }
}
