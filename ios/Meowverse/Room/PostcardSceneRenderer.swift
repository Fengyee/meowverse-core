import OSLog
import RealityKit
import UIKit

/// The print aperture has its own Metal drawable, independent of screen size and live room zoom.
@MainActor
enum PostcardSceneRenderer {
    static func render(_ room: Entity, bounds: BoundingBox, matching live: ARView, backdrop: UIColor) async throws -> CGImage {
        guard !bounds.isEmpty, let window = live.window else { throw RoomSnapshotError.unavailable }
        return try await capture(room, projection: .postcard(fitting: bounds), size: RoomPostcard.sceneSize,
                                 scale: RoomPostcard.printScale, backdrop: backdrop, in: window) { view in
            view.environment = live.environment
            RoomLook.current?.setEnvironment(on: view, hdr: true)
        }
    }

    /// One still of `scene` from a surface of its own behind the window's content.
    static func capture(_ scene: Entity, projection: RoomProjection, size: CGSize, scale: CGFloat, backdrop: UIColor,
                        in window: UIWindow, setUp: (ARView) -> Void) async throws -> CGImage {
        let view = ARView(frame: CGRect(origin: .zero, size: size), cameraMode: .nonAR, automaticallyConfigureSession: false)
        RoomRendering.configure(view, hdrEnvironment: true)
        view.contentScaleFactor = scale
        setUp(view)
        // The live room may be transparent over the theme's painting; the card gets its paper colour.
        let graded = RoomLook.current != nil
        view.environment.background = .color(graded ? .clear : backdrop)
        if graded {
            view.backgroundColor = .clear
            view.isOpaque = false
        }
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        window.insertSubview(view, at: 0)
        defer { view.removeFromSuperview() }

        let camera = Entity()
        var lens = OrthographicCameraComponent()
        lens.near = 0.1
        lens.far = 80
        lens.scaleDirection = .horizontal
        lens.scale = projection.horizontalExtent(for: size) / 2
        camera.components.set(lens)
        projection.aim(camera)
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(scene)
        anchor.addChild(camera)
        view.scene.addAnchor(anchor)
        let deadline = ContinuousClock.now + .seconds(6)
        let capture = Capture(width: Int(size.width * scale), height: Int(size.height * scale))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            // A newly attached surface sometimes returns a flat placeholder on the first draw.
            if !capture.pending {
                capture.pending = true
                view.snapshot(saveToHDR: false) { image in capture.receive(image) }
            }
            try await Task.sleep(for: .milliseconds(70))
            if let image = capture.image { return graded ? mounted(image, on: backdrop) : image }
        }
        Logger(subsystem: "Meowverse", category: "postcard").error("Print surface unavailable (last drawable \(capture.lastWidth) × \(capture.lastHeight))")
        throw RoomSnapshotError.unavailable
    }

    /// The graded scene is shot on nothing and laid on the paper, which the curve must not tint.
    private static func mounted(_ scene: CGImage, on paper: UIColor) -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: scene.width, height: scene.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return scene }
        let frame = CGRect(x: 0, y: 0, width: scene.width, height: scene.height)
        context.setFillColor(paper.cgColor)
        context.fill(frame)
        context.draw(scene, in: frame)
        return context.makeImage() ?? scene
    }

    private final class Capture {
        var pending = false
        var image: CGImage?
        var lastWidth = 0
        var lastHeight = 0
        private let width: Int
        private let height: Int

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        func receive(_ snapshot: UIImage?) {
            pending = false
            guard let pixels = snapshot?.cgImage else { return }
            lastWidth = pixels.width
            lastHeight = pixels.height
            guard
                  pixels.width >= width,
                  pixels.height >= height,
                  Self.hasRoom(in: pixels) else { return }
            image = pixels
        }

        private static func hasRoom(in image: CGImage) -> Bool {
            var sample = [UInt8](repeating: 0, count: 24 * 16)
            return sample.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: 24, height: 16, bitsPerComponent: 8,
                                              bytesPerRow: 24, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: 24, height: 16))
                let values = buffer.bindMemory(to: UInt8.self)
                return Int(values.max() ?? 0) - Int(values.min() ?? 0) > 12
            }
        }
    }
}
