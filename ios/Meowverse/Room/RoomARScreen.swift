import ARKit
import AVFoundation
import MeowverseCore
import RealityKit
import SwiftUI
import UIKit
import os

// The room on a real table, seen through the camera: a trial on the owner's phone (round 11).
// The owner allowed perspective here, and only here (docs/WIDGETS_WATCH_AR.md, 2026-11-19); the
// room page keeps its fixed orthographic camera. No user photo appears in the scene: the photo
// boards are drawn colour blocks, as in the room. Photos show only in a piece's detail page.
// The camera picture is shown live and never recorded, saved or sent anywhere.
// All text is in the RoomAR string table, apart from the room's own detail page.

enum RoomARLog {
    static let log = Logger(subsystem: "app.meowverse", category: "ar")
}

enum RoomAREntry {
    #if DEBUG || DRILLS
    /// `-MeowverseShowAREntry`: 互动 shows the row on the simulator, which cannot track the
    /// world, so a UI test can open the page (it then says AR is unavailable here).
    private static let forced = ProcessInfo.processInfo.arguments.contains("-MeowverseShowAREntry")
    #endif

    static var worldTracking: Bool { ARWorldTrackingConfiguration.isSupported }

    /// What 互动 shows. The stand-in camera's "denied" switch counts here too.
    static var current: ARTabletopEntry {
        var supported = worldTracking
        #if DEBUG || DRILLS
        supported = supported || forced
        #endif
        return ARTabletop.entry(worldTracking: supported, camera: InAppCamera.isDenied ? .denied : .allowed)
    }
}

/// How the room screen opens the AR page. On iPhone 互动 is a sheet: the page opens once that
/// sheet has fully gone, since two presentations at once break. `covering` lasts from asking
/// until the page has fully gone again; the room holds back its own sheets until then, so
/// 编辑家具 chosen over the table opens in the room afterwards.
struct RoomARPresentation: Equatable {
    var shown = false
    private(set) var covering = false
    private var afterSheet = false

    mutating func ask(afterSheet: Bool) {
        covering = true
        if afterSheet { self.afterSheet = true } else { shown = true }
    }

    /// The 互动 sheet has gone.
    mutating func openIfAsked() {
        guard afterSheet else { return }
        afterSheet = false
        shown = true
    }

    mutating func gone() {
        shown = false
        covering = false
    }
}

struct RoomARCover: ViewModifier {
    @Binding var state: RoomARPresentation
    let appearance: RoomAppearance
    let lighting: RoomLightingMode

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $state.shown, onDismiss: { state.gone() }) {
            RoomARScreen(appearance: appearance, lighting: lighting) { state.shown = false }
        }
    }
}

/// The AR page, full screen over the room. 「回到房间」 leaves the room as it was.
struct RoomARScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("bella.groundGait") private var groundGait: GroundGait = .groundWalk
    let appearance: RoomAppearance
    let lighting: RoomLightingMode
    let onClose: () -> Void

    private enum Mode {
        case unsupported, cameraOff, live
        #if DEBUG || DRILLS
        case controls
        #endif
    }
    #if DEBUG || DRILLS
    /// `-MeowverseARDrill camera-off|controls`: the two states the simulator cannot reach, for
    /// the colour checks. `controls` is the bottom bar with a surface found, over black.
    private static let drill = UserDefaults.standard.string(forKey: "MeowverseARDrill")
    private static var drillsCameraOff: Bool { drill == "camera-off" }
    #else
    private static let drillsCameraOff = false
    #endif
    @State private var mode: Mode?
    @State private var surfaceFound = false
    @State private var placed = false
    @State private var interrupted = false
    @State private var coaching = false
    @State private var searchedLong = false
    @State private var thermal = ProcessInfo.processInfo.thermalState
    @State private var placeRequest = 0
    @State private var resetRequest = 0
    @State private var detail: OpenedPiece?
    @State private var busyDetailID: String?

    private struct OpenedPiece: Identifiable, Equatable { let id: String }

    /// On the owner's iPhone (build 7.11) the session started without the system ever asking for
    /// the camera: no prompt, no 相机 switch in Settings, a black page. So the page asks first,
    /// and only runs the session once the answer is yes.
    @MainActor private static func entryMode() async -> Mode {
        guard RoomAREntry.worldTracking else { return .unsupported }
        if InAppCamera.isDenied { return .cameraOff }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            RoomARLog.log.notice("camera access asked: \(granted ? "granted" : "refused", privacy: .public)")
            guard granted else { return .cameraOff }
        }
        await roomViewsGone()
        return .live
    }

    /// Builds 7.11–7.17 showed a black page with the room on it: while the room page's non-AR
    /// view is alive, an AR view draws no camera picture (found with bare views on the owner's
    /// iPhone, iOS 27.2). The room page drops its view while this page is open; the AR view is
    /// made only once that view has really gone.
    @MainActor private static func roomViewsGone() async {
        for _ in 0..<40 where LayoutReportingARView.alive > 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        RoomARLog.log.notice("room views alive at start: \(LayoutReportingARView.alive, privacy: .public)")
    }

    private var tooWarm: Bool { thermal == .serious || thermal == .critical }

    private var hint: ARTabletopHint {
        ARTabletop.hint(surfaceFound: surfaceFound, placed: placed, interrupted: interrupted, tooWarm: tooWarm,
                        searchedLong: searchedLong)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch mode {
            case .live: live
            #if DEBUG || DRILLS
            case .controls: bottomBar.frame(maxHeight: .infinity, alignment: .bottom)
            #endif
            case .cameraOff:
                notice(title: Text("相机权限已关闭", tableName: "RoomAR"),
                       message: Text("在系统设置里打开喵空间的相机权限，就能把房间放到桌上。相机画面只在这台设备上显示，不录制，也不保存。", tableName: "RoomAR"),
                       settings: true)
            case .unsupported:
                notice(title: Text("这台设备不能用 AR", tableName: "RoomAR"),
                       message: Text("把房间放到桌上，需要能识别周围空间的 iPhone 或 iPad。", tableName: "RoomAR"),
                       settings: false)
            case nil: EmptyView()
            }
        }
        .overlay(alignment: .topLeading) { exitButton }
        .roomLighting(mode: lighting)
        .environment(\.roomAppearance, appearance)
        .preferredColorScheme(.dark)
        .task {
            guard mode == nil else { return }
            #if DEBUG || DRILLS
            switch Self.drill {
            case "camera-off":
                mode = .cameraOff
                return
            case "controls":
                surfaceFound = true
                mode = .controls
                return
            default: break
            }
            #endif
            mode = await Self.entryMode()
        }
        // Back from Settings with the camera turned on (FF24-02, EXTENSIONS-11): the page that
        // said 相机权限已关闭 starts the table once, without asking again. Only on a yes already
        // given; denied or restricted stays as it is.
        .task(id: scenePhase) {
            guard scenePhase == .active, mode == .cameraOff, !Self.drillsCameraOff,
                  AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
            let next = await Self.entryMode()
            guard !Task.isCancelled, mode == .cameraOff else { return }
            RoomARLog.log.notice("camera access on after Settings: \(String(describing: next), privacy: .public)")
            mode = next
        }
        .sheet(item: $detail) { piece in
            FurnitureDetailView(instanceId: piece.id, busyDetailID: $busyDetailID) {
                if detail == piece { detail = nil }
            }
        }
        // A photo's page can open another piece; it opens here, over the table, not in the room behind.
        .onChange(of: model.openedFurnitureID, initial: true) { _, id in
            guard let id else { return }
            detail = OpenedPiece(id: id)
            model.openedFurnitureID = nil
        }
        // 编辑家具, 在房间里定位 and another room happen in the room: go back to it.
        .onChange(of: model.movingFurnitureID) { _, id in if id != nil { onClose() } }
        .onChange(of: model.restoringFurnitureID) { _, id in if id != nil { onClose() } }
        .onChange(of: model.pieces.locateTick) { onClose() }
        .onChange(of: model.currentRoomId) { onClose() }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermal = ProcessInfo.processInfo.thermalState
        }
        .task(id: surfaceFound || placed) {
            searchedLong = false
            guard !surfaceFound, !placed else { return }
            do { try await Task.sleep(for: ARTabletop.slowSearch) } catch { return }
            searchedLong = true
        }
        .onChange(of: hint) { _, hint in
            AccessibilityNotification.Announcement(Self.text(for: hint)).post()
        }
        .sensoryFeedback(.impact(weight: .light), trigger: placed) { _, now in now }
    }

    private var live: some View {
        RoomARSceneView(
            items: model.roomFurniture,
            cats: model.roomCats,
            groundGait: groundGait,
            paused: scenePhase != .active || detail != nil || tooWarm || interrupted,
            running: scenePhase == .active,
            placeRequest: placeRequest,
            resetRequest: resetRequest,
            onEvent: handle,
            onTapFurniture: { detail = OpenedPiece(id: $0) }
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .overlay(alignment: .topTrailing) {
            if placed {
                Button { resetRequest += 1 } label: {
                    Label { Text("重新放置", tableName: "RoomAR") } icon: { Image(systemName: "arrow.counterclockwise") }
                }
                .buttonStyle(.borderedProminent)
                .tint(.black.opacity(0.55))
                .padding(16)
                .accessibilityIdentifier("ar-replace")
            }
        }
        .overlay(alignment: .bottom) { bottomBar }
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            // The system's coaching overlay already says what to do while it shows.
            if !coaching {
                Text(Self.text(for: hint))
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.55), in: .capsule)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("ar-hint")
            }
            HStack(spacing: 12) {
                if !placed && surfaceFound {
                    // The same as tapping the table, in the middle of the screen: also for VoiceOver.
                    Button { placeRequest += 1 } label: {
                        Label { Text("放在这里", tableName: "RoomAR") } icon: { Image(systemName: "square.and.arrow.down") }
                            .prominentInk()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ar-place")
                }
                if placed, !model.roomFurniture.isEmpty {
                    // Every piece's detail without aiming at it: the VoiceOver way in.
                    Menu {
                        ForEach(model.roomFurniture) { item in
                            Button(item.shownName) { detail = OpenedPiece(id: item.instanceId) }
                        }
                    } label: {
                        Label { Text("家具", tableName: "RoomAR") } icon: { Image(systemName: "sofa") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.black.opacity(0.55))
                    .accessibilityIdentifier("ar-furniture")
                }
            }
        }
        .padding(.bottom, 24)
        .padding(.horizontal, 20)
    }

    private var exitButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.55), in: .circle)
                .foregroundStyle(.white)
        }
        .padding(16)
        .accessibilityLabel(Text("回到房间", tableName: "RoomAR"))
        .accessibilityIdentifier("ar-exit")
    }

    private func notice(title: Text, message: Text, settings: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: settings ? "camera" : "arkit")
                .font(.system(size: 44))
                .accessibilityHidden(true)
            title.font(.system(.title3, design: .rounded, weight: .bold))
            message.font(.body).multilineTextAlignment(.center)
            if settings, let url = URL(string: UIApplication.openSettingsURLString) {
                Button { UIApplication.shared.open(url) } label: { Text("打开系统设置", tableName: "RoomAR").prominentInk() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ar-open-settings")
            }
            Button(action: onClose) { Text("回到房间", tableName: "RoomAR") }
                .buttonStyle(.bordered)
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: 440)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(settings ? "ar-camera-off" : "ar-unsupported")
    }

    private func handle(_ event: RoomARSceneView.Event) {
        switch event {
        case .surfaceFound: surfaceFound = true
        case .surfaceLost: surfaceFound = false
        case .placed(let now): placed = now
        case .interrupted(let now): interrupted = now
        case .coaching(let now): coaching = now
        case .cameraDenied: mode = .cameraOff
        }
    }

    static func text(for hint: ARTabletopHint) -> String {
        switch hint {
        case .lookForSurface: String(localized: "慢慢移动设备，找一块平的桌面", table: "RoomAR")
        case .tryAnotherSurface: String(localized: "换一块光线好一点、有花纹的桌面试试", table: "RoomAR")
        case .tapToPlace: String(localized: "点一下桌面，把房间放上去", table: "RoomAR")
        case .placed: String(localized: "双指缩放、旋转，拖动换位置；点家具看照片", table: "RoomAR")
        case .interrupted: String(localized: "相机暂时用不了，稍等一下；在 iPad 上请全屏使用", table: "RoomAR")
        case .tooWarm: String(localized: "设备有点热了，猫咪先歇一会儿", table: "RoomAR")
        }
    }
}

/// The ARKit view under the AR page. The room inside is the room page's own controller in
/// tabletop mode: the same furniture, theme, light and cats.
struct RoomARSceneView: UIViewRepresentable {
    enum Event {
        case surfaceFound
        /// Every table plane ARKit had found is gone (G24-06): look for one again.
        case surfaceLost
        case placed(Bool)
        case interrupted(Bool)
        case coaching(Bool)
        case cameraDenied
    }

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.roomAppearance) private var appearance
    @Environment(\.roomLightPhase) private var lightPhase
    let items: [PhotoFurniture]
    let cats: [Cat]
    let groundGait: GroundGait
    /// The cats hold still: something covers the table, the app is inactive, the phone is hot.
    let paused: Bool
    /// False in the background: the camera session stops.
    let running: Bool
    let placeRequest: Int
    let resetRequest: Int
    let onEvent: (Event) -> Void
    let onTapFurniture: (String) -> Void

    func makeCoordinator() -> RoomARCoordinator { RoomARCoordinator() }

    func makeUIView(context: Context) -> ARView {
        // RealityKit's defaults: the room's render options were not tried with the camera picture.
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.isAccessibilityElement = false
        let coordinator = context.coordinator
        coordinator.onEvent = onEvent
        coordinator.controller.attach(to: view, tabletop: true)
        coordinator.install(on: view)
        coordinator.placeRequest = placeRequest
        coordinator.resetRequest = resetRequest
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        let coordinator = context.coordinator
        let controller = coordinator.controller
        coordinator.onEvent = onEvent
        coordinator.onTapFurniture = onTapFurniture
        controller.applyAppearance(appearance, lightPhase: lightPhase, seeThrough: false)
        controller.reduceMotion = reduceMotion
        controller.bella.groundGait = groundGait
        controller.bellaPaused = paused
        coordinator.setRunning(running)
        if let art = app.art {
            // The same cat tier as the room (画质's memory choice also fits AR's budget).
            controller.onCatTierUnusable = { [app] variant in app.catTierUnusable(variant) }
            controller.sync(items: items, ghost: nil, art: art, cat: app.roomCat,
                            showsLead: !cats.isEmpty, companions: Array(cats.dropFirst().map(\.catId)))
        }
        if placeRequest != coordinator.placeRequest {
            coordinator.placeRequest = placeRequest
            coordinator.placeInMiddle()
        }
        if resetRequest != coordinator.resetRequest {
            coordinator.resetRequest = resetRequest
            coordinator.takeOff()
        }
    }

    static func dismantleUIView(_ view: ARView, coordinator: RoomARCoordinator) {
        coordinator.stop()
        coordinator.controller.detach()
    }
}

/// The camera session, plane finding and the table gestures.
final class RoomARCoordinator: NSObject, @preconcurrency ARSessionDelegate, @preconcurrency ARCoachingOverlayViewDelegate,
                               UIGestureRecognizerDelegate {
    let controller = RoomSceneController()
    var onEvent: ((RoomARSceneView.Event) -> Void)?
    var onTapFurniture: ((String) -> Void)?
    var placeRequest = 0
    var resetRequest = 0
    private weak var view: ARView?
    private var pose: ARTabletopPose?
    private var running = false
    private var surfaceReported = false
    /// The horizontal planes ARKit has now, so losing the last one is reported (G24-06).
    private var planes: Set<UUID> = []
    /// The finger's last point on the table while dragging.
    private var dragPoint: SIMD3<Float>?

    func install(on view: ARView) {
        self.view = view
        view.session.delegate = self
        let coaching = ARCoachingOverlayView()
        coaching.session = view.session
        coaching.goal = .horizontalPlane
        coaching.activatesAutomatically = true
        coaching.delegate = self
        coaching.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(coaching)
        NSLayoutConstraint.activate([
            coaching.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            coaching.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            coaching.topAnchor.constraint(equalTo: view.topAnchor),
            coaching.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(rotated(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        for recognizer in [pinch, rotation, pan] as [UIGestureRecognizer] {
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
        }
    }

    func setRunning(_ wanted: Bool) {
        guard wanted != running, let view else { return }
        running = wanted
        if wanted {
            let configuration = ARWorldTrackingConfiguration()
            configuration.planeDetection = [.horizontal]
            // Our own lights keep the room's colours; nothing of the room needs the real light.
            configuration.environmentTexturing = .none
            // Kept anchors and tracking: coming back from the background finds the same table.
            RoomARLog.log.notice("session run, camera \(AVCaptureDevice.authorizationStatus(for: .video).rawValue, privacy: .public)")
            view.session.run(configuration)
        } else {
            RoomARLog.log.notice("session paused")
            view.session.pause()
        }
    }

    func stop() {
        running = false
        view?.session.pause()
        view?.session.delegate = nil
    }

    // MARK: Placing

    func placeInMiddle() {
        guard let view else { return }
        place(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
    }

    func takeOff() {
        pose = nil
        controller.placeOnTable(nil)
        report(.placed(false))
    }

    private func place(at point: CGPoint) {
        guard let view, let hit = view.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first else { return }
        let spot = hit.worldTransform.columns.3
        pose = .placed(at: [spot.x, spot.y, spot.z], facing: view.cameraTransform.translation)
        controller.placeOnTable(pose)
        report(.placed(true))
    }

    /// Events from inside `updateUIView` must not change SwiftUI state during the update.
    private func report(_ event: RoomARSceneView.Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    // MARK: Gestures

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let view else { return }
        let point = recognizer.location(in: view)
        guard pose != nil else {
            place(at: point)
            return
        }
        if let id = controller.furnitureID(at: point) { onTapFurniture?(id) }
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        guard let current = pose, recognizer.state == .changed else { return }
        pose = current.scaled(by: Float(recognizer.scale))
        recognizer.scale = 1
        controller.placeOnTable(pose)
    }

    @objc private func rotated(_ recognizer: UIRotationGestureRecognizer) {
        guard let current = pose, recognizer.state == .changed else { return }
        // Clockwise on the screen, looking down at the table, is clockwise seen from above.
        pose = current.turned(by: -Float(recognizer.rotation))
        recognizer.rotation = 0
        controller.placeOnTable(pose)
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard let view, let current = pose else { return }
        let point = recognizer.location(in: view)
        let onTable = view.ray(through: point).flatMap {
            ARTabletop.floorHit(origin: $0.origin, direction: $0.direction, planeY: current.base.y)
        }
        switch recognizer.state {
        case .began: dragPoint = onTable
        case .changed:
            guard let from = dragPoint, let to = onTable else { return }
            pose = current.moved(from: from, to: to)
            dragPoint = to
            controller.placeOnTable(pose)
        default: dragPoint = nil
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch and rotate together; a drag stays a drag.
        let pair: (UIGestureRecognizer) -> Bool = { $0 is UIPinchGestureRecognizer || $0 is UIRotationGestureRecognizer }
        return pair(gestureRecognizer) && pair(other)
    }

    // MARK: Session

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        planes.formUnion(anchors.compactMap { ($0 as? ARPlaneAnchor)?.alignment == .horizontal ? $0.identifier : nil })
        guard !surfaceReported, !planes.isEmpty else { return }
        surfaceReported = true
        onEvent?(.surfaceFound)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        planes.subtract(anchors.map(\.identifier))
        guard surfaceReported, planes.isEmpty else { return }
        RoomARLog.log.notice("table plane lost")
        surfaceReported = false
        onEvent?(.surfaceLost)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        RoomARLog.log.error("session failed: \(String(describing: error), privacy: .public)")
        if (error as? ARError)?.code == .cameraUnauthorized {
            onEvent?(.cameraDenied)
        } else {
            onEvent?(.interrupted(true))
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        RoomARLog.log.notice("session interrupted")
        onEvent?(.interrupted(true))
    }
    func sessionInterruptionEnded(_ session: ARSession) {
        RoomARLog.log.notice("session interruption ended")
        onEvent?(.interrupted(false))
    }
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        RoomARLog.log.notice("tracking: \(String(describing: camera.trackingState), privacy: .public)")
    }

    func coachingOverlayViewWillActivate(_ coachingOverlayView: ARCoachingOverlayView) { onEvent?(.coaching(true)) }
    func coachingOverlayViewDidDeactivate(_ coachingOverlayView: ARCoachingOverlayView) { onEvent?(.coaching(false)) }
}
