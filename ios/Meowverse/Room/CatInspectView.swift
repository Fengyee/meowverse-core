import MeowverseCore
import RealityKit
import SwiftUI

/// The active cat pack's high-resolution model (`inspect.usdz`). It is read only while this
/// screen is open and released when it closes; the room never loads it.
struct CatInspectView: View {
    let pack: CatPack
    @State private var model: Entity?
    @State private var failed = false
    /// VoiceOver's adjustable action turns the model in steps.
    @State private var turn = 0

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .memoryPage(.companion)
            .navigationTitle("3D 模型")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: pack.cacheKey) { await load() }
            .onDisappear { model = nil }
    }

    @ViewBuilder private var content: some View {
        if let model {
            InspectSceneView(model: model, turn: turn)
            .accessibilityElement()
            .accessibilityLabel("\(Wording.subject(pack.displayTitle))的 3D 模型")
            .accessibilityHint("单指拖动可以转动模型，双指捏合可以放大缩小。")
            .accessibilityAddTraits(.allowsDirectInteraction)
            .accessibilityAdjustableAction { direction in
                turn += direction == .increment ? 1 : -1
            }
            .accessibilityIdentifier("cat-inspect-model")
        } else if failed {
            ContentUnavailableView("没能打开这个模型", systemImage: "exclamationmark.triangle",
                                   description: Text("3D 模型文件读不出来。房间里的猫咪不受影响。"))
                .accessibilityIdentifier("cat-inspect-failed")
        } else {
            ProgressView("正在载入 3D 模型…")
                .accessibilityIdentifier("cat-inspect-loading")
        }
    }

    private func load() async {
        guard model == nil else { return }
        guard let url = pack.inspectURL else {
            failed = true
            return
        }
        do {
            let entity = try await Entity(contentsOf: url)
            try Task.checkCancellation()
            model = Self.fitted(entity)
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }

    /// Centres the model on the origin and scales it to half a metre across, whatever units it was authored in.
    static func fitted(_ entity: Entity) -> Entity {
        let holder = Entity()
        holder.addChild(entity)
        let bounds = entity.visualBounds(relativeTo: holder)
        let size = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        guard size.isFinite, size > 0 else { return holder }
        let factor = 0.5 / size
        entity.scale *= SIMD3(repeating: factor)
        entity.position = (entity.position - bounds.center) * factor
        return holder
    }
}

/// Same renderer as the room (`ARView` without a camera feed), with an orbiting perspective
/// camera: one finger turns, a pinch zooms.
private struct InspectSceneView: UIViewRepresentable {
    let model: Entity
    let turn: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: CGRect(x: 0, y: 0, width: 320, height: 320), cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(.secondarySystemBackground)
        view.isAccessibilityElement = false
        context.coordinator.attach(model: model, to: view)
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:))))
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.setTurn(turn)
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        // Releases the model's resources with the screen.
        view.scene.anchors.removeAll()
    }

    final class Coordinator: NSObject {
        private let anchor = AnchorEntity(world: .zero)
        private let camera = PerspectiveCamera()
        private var yaw: Float = .pi / 6
        private var pitch: Float = 0.25
        private var distance: Float = 0.9
        private var lastTurn = 0
        private var startDistance: Float = 1.6

        func attach(model: Entity, to view: ARView) {
            anchor.addChild(model)
            camera.camera.fieldOfViewInDegrees = 40
            anchor.addChild(camera)
            let key = DirectionalLight()
            key.light.intensity = 3000
            key.look(at: .zero, from: [0.6, 1, 1], relativeTo: nil)
            anchor.addChild(key)
            let fill = DirectionalLight()
            fill.light.intensity = 1200
            fill.look(at: .zero, from: [-1, 0.4, -0.6], relativeTo: nil)
            anchor.addChild(fill)
            view.scene.addAnchor(anchor)
            place()
        }

        func setTurn(_ turn: Int) {
            guard turn != lastTurn else { return }
            yaw += Float(turn - lastTurn) * .pi / 6
            lastTurn = turn
            place()
        }

        private func place() {
            let eye = SIMD3<Float>(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
            camera.look(at: .zero, from: eye, relativeTo: nil)
        }

        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            let delta = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)
            yaw -= Float(delta.x) * 0.01
            pitch = min(max(pitch + Float(delta.y) * 0.01, -1.2), 1.2)
            place()
        }

        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { startDistance = distance }
            distance = min(max(startDistance / Float(max(gesture.scale, 0.01)), 0.35), 4)
            place()
        }
    }
}
