#if DEBUG || DRILLS
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A drawn, non-private stand-in photo for UI tests and fault drills. Carries an EXIF capture day.
enum SyntheticPhoto {
    /// `variant` 0 is the standard photo. Other variants add a coloured ball (different bytes)
    /// and carry no capture date, to exercise "date unknown" and several photos per furniture.
    /// 1 draws 1200x900 px. `-MeowverseLargeSyntheticPhoto` sets 3 (3600x2700 px) once at launch,
    /// so a UI test can import a photo large enough to be stored as a reduced copy.
    nonisolated(unsafe) static var pixelScale: CGFloat = 1

    /// Wall, floor and sofa colours of each scene: photos of one scene look alike, photos of
    /// different scenes do not (for the batch suggestion tests).
    private nonisolated static let scenes: [(wall: UIColor, floor: UIColor, sofa: UIColor, seat: UIColor)] = [
        (UIColor(red: 0.93, green: 0.89, blue: 0.80, alpha: 1), UIColor(red: 0.80, green: 0.68, blue: 0.52, alpha: 1),
         UIColor(red: 0.45, green: 0.56, blue: 0.62, alpha: 1), UIColor(red: 0.52, green: 0.63, blue: 0.69, alpha: 1)),
        (UIColor(red: 0.22, green: 0.30, blue: 0.42, alpha: 1), UIColor(red: 0.30, green: 0.20, blue: 0.14, alpha: 1),
         UIColor(red: 0.85, green: 0.55, blue: 0.25, alpha: 1), UIColor(red: 0.92, green: 0.65, blue: 0.32, alpha: 1)),
        (UIColor(red: 0.62, green: 0.82, blue: 0.58, alpha: 1), UIColor(red: 0.95, green: 0.95, blue: 0.92, alpha: 1),
         UIColor(red: 0.70, green: 0.20, blue: 0.30, alpha: 1), UIColor(red: 0.78, green: 0.28, blue: 0.38, alpha: 1)),
    ]

    /// A synthetic photo request that never answers and ignores cancellation, as a stalled
    /// iCloud download (`-MeowverseSyntheticLoadHangs`).
    /// A synthetic photo that takes `delay` seconds of the app's running time to arrive, as an
    /// original coming from iCloud does (`-MeowverseSyntheticLoadDelay`). It waits in short steps,
    /// so time spent suspended does not count: a UI test can tell whether the app kept running in
    /// the background.
    nonisolated static func slowly(_ delay: Double) async throws {
        for _ in 0..<Int((delay * 4).rounded()) { try await Task.sleep(for: .milliseconds(250)) }
    }

    nonisolated static func neverArrives() async {
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
    }

    nonisolated static func jpeg(variant: Int = 0, scene: Int = 0) -> Data {
        let palette = scenes[scene % scenes.count]
        let size = CGSize(width: 1200, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = pixelScale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            palette.wall.setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            palette.floor.setFill()
            cg.fill(CGRect(x: 0, y: 640, width: 1200, height: 260))
            // Sofa
            palette.sofa.setFill()
            UIBezierPath(roundedRect: CGRect(x: 180, y: 330, width: 840, height: 250), cornerRadius: 50).fill()
            palette.seat.setFill()
            UIBezierPath(roundedRect: CGRect(x: 140, y: 470, width: 920, height: 190), cornerRadius: 44).fill()
            // Cat loaf
            UIColor(red: 0.42, green: 0.34, blue: 0.27, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 470, y: 400, width: 300, height: 130)).fill()
            UIBezierPath(ovalIn: CGRect(x: 700, y: 360, width: 110, height: 100)).fill()
            let ear = UIBezierPath()
            ear.move(to: CGPoint(x: 715, y: 385)); ear.addLine(to: CGPoint(x: 728, y: 335)); ear.addLine(to: CGPoint(x: 752, y: 372))
            ear.move(to: CGPoint(x: 768, y: 372)); ear.addLine(to: CGPoint(x: 792, y: 335)); ear.addLine(to: CGPoint(x: 802, y: 388))
            ear.fill()
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 735, y: 410, width: 44, height: 40)).fill()
            if variant != 0 {
                UIColor(hue: CGFloat(variant % 7) / 7, saturation: 0.7, brightness: 0.85, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: 260 + (variant % 5) * 40, y: 690, width: 90, height: 90)).fill()
            }
        }
        let output = NSMutableData()
        guard let cgImage = image.cgImage,
              let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return Data() }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if variant == 0 {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: "2026:03:14 09:26:53"]
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}
#endif
