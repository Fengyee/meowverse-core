import CoreGraphics
import OSLog
import RealityKit
import simd

enum RoomStudioLighting {
    private static weak var cached: EnvironmentResource?

    static func environment() -> EnvironmentResource? {
        if let cached { return cached }
        guard let image = panorama() else { return nil }
        do {
            let resource = try EnvironmentResource(equirectangular: image, withName: "room-softboxes")
            cached = resource
            return resource
        } catch {
            Logger(subsystem: "app.meowverse", category: "look").error("Room softboxes unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private struct Softbox {
        let direction: SIMD3<Float>
        let outer: Float
        let inner: Float
        let color: SIMD3<Float>

        init(direction: SIMD3<Float>, radiusDegrees: Float, color: SIMD3<Float>) {
            self.direction = simd_normalize(direction)
            let radius = radiusDegrees * .pi / 180
            outer = cos(radius)
            inner = cos(radius * 0.60)
            self.color = color
        }

        func radiance(at direction: SIMD3<Float>) -> SIMD3<Float> {
            let t = min(1, max(0, (simd_dot(self.direction, direction) - outer) / (inner - outer)))
            return color * t * t * (3 - 2 * t)
        }
    }

    private static func panorama() -> CGImage? {
        let width = 512, height = 256
        let boxes = [
            Softbox(direction: [-3, 6, -4], radiusDegrees: 22, color: [4, 3.6, 3.1]),
            Softbox(direction: [4, 3, -2], radiusDegrees: 24, color: [1.3, 1.55, 1.9]),
            Softbox(direction: [-2, 5, 4], radiusDegrees: 16, color: [5, 4.5, 3.9]),
        ]
        let ring = (0..<width).map { column in
            let angle = (Float(column) + 0.5) / Float(width) * 2 * .pi
            return SIMD2<Float>(-sin(angle), cos(angle))
        }
        let sky = SIMD3<Float>(0.22, 0.24, 0.27)
        let ground = SIMD3<Float>(0.23, 0.20, 0.17)
        var pixels: [SIMD4<Float>] = []
        pixels.reserveCapacity(width * height)
        for row in 0..<height {
            let latitude = (0.5 - (Float(row) + 0.5) / Float(height)) * .pi
            let y = sin(latitude), radius = cos(latitude)
            let diffuse = ground + max(0, y) * sky
            for longitude in ring {
                let direction = SIMD3<Float>(longitude.x * radius, y, longitude.y * radius)
                let rgb = boxes.reduce(diffuse) { $0 + $1.radiance(at: direction) }
                pixels.append(SIMD4(rgb.x, rgb.y, rgb.z, 1))
            }
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
            .union([.floatComponents, .byteOrder32Little])
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let provider = CGDataProvider(data: pixels.withUnsafeBytes { Data($0) } as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
                       bytesPerRow: width * MemoryLayout<SIMD4<Float>>.stride, space: space, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
