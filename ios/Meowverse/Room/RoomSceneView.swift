import Combine
import MeowverseCore
import OSLog
import RealityKit
import SwiftUI
import UIKit

/// One "come here" from Talk to Bella. Like `CatInvitation`, each request has its own id.
struct CatSummon: Identifiable, Equatable {
    let id = UUID()
    let cell: GridCell
}

struct GhostFurniture: Equatable {
    let placement: Placement
    let valid: Bool
    /// The stored piece this ghost stands in for while it is edited in the room: that piece is
    /// hidden, and the ghost floats above its footprint even where it may not be put down.
    let lifted: String?
    let accessCells: Set<GridCell>

    init(placement: Placement, valid: Bool, among others: [PhotoFurniture], lifted: String? = nil) {
        self.placement = placement
        self.valid = valid
        self.lifted = lifted
        accessCells = placement.wall == nil ? CatRoutine.placementGuideCells(in: others, previewing: placement) : []
    }
}

enum PlacementPreviewState {
    case loading, ready, unavailable
}

/// The fixed orthographic miniature room. Furniture taps and floor taps are reported to SwiftUI;
/// VoiceOver equivalents live in the SwiftUI layer around this view.
struct RoomSceneView: UIViewRepresentable {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.roomAppearance) private var appearance
    @Environment(\.roomLightPhase) private var lightPhase
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.roomInspectorCoversScene) private var inspectorCoversScene
    let items: [PhotoFurniture]
    let ghost: GhostFurniture?
    let onTapFurniture: ((String) -> Void)?
    let onTapCell: ((Int, Int) -> Void)?
    /// A tap on a wall while placing: the wall and the cell along it.
    var onTapWall: ((WallSide, Int) -> Void)? = nil

    var groundGait: GroundGait = .groundWalk
    var invitation: CatInvitation? = nil
    /// Talk to Bella's "come here" (docs/TALK_TO_BELLA.md): a new id walks the lead cat to the
    /// cell (`BellaActor.come(to:)`), once per id, like `invitation`.
    var summon: CatSummon? = nil
    var playSession: RoomPlaySession? = nil
    var framing = RoomProjection()
    var snapshotSource: RoomSnapshotSource?
    var onCameraChange: ((CGFloat, CGPoint, CGSize) -> Void)?
    var showsStorageChest = false
    /// The cats this room shows, the first one leading (captions, invitations and play follow
    /// it). nil = a scene that is not a saved room (the placement editor): one still cat.
    var cats: [Cat]? = nil
    var onPreviewState: ((PlacementPreviewState) -> Void)?
    /// Called once, when the first furniture and the cat are in place (or could not load), so the
    /// launch cover can lift on a finished room instead of pieces appearing one by one.
    var onSceneReady: (() -> Void)? = nil
    /// The room page paints the theme's backdrop behind a transparent view; other scenes (the
    /// placement editor) keep the backdrop colour.
    var seeThrough = false

    func makeCoordinator() -> RoomSceneController { RoomSceneController() }

    func makeUIView(context: Context) -> ARView {
        let view = LayoutReportingARView(frame: CGRect(x: 0, y: 0, width: 320, height: 320), cameraMode: .nonAR, automaticallyConfigureSession: false)
        let quality = app.quality.tier.settings
        RoomRendering.configure(view, hdrEnvironment: quality.hdrEnvironment)
        view.contentScaleFactor = RoomRendering.renderScale(quality)
        view.isAccessibilityElement = false
        Perf.mark("RoomViewMade")
        context.coordinator.attach(to: view)
        context.coordinator.applyAppearance(appearance, lightPhase: lightPhase, seeThrough: seeThrough)
        view.onLayout = { [weak controller = context.coordinator] size in controller?.frameCamera(for: size) }
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(RoomSceneController.tapped(_:))))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(RoomSceneController.panned(_:)))
        pan.name = "play-follow"
        pan.isEnabled = false
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        return view
    }

    /// Bella lives only in the saved room; the placement editor shows a still scene.
    private var isLiveRoom: Bool { ghost == nil && onTapCell == nil }

    func updateUIView(_ view: ARView, context: Context) {
        let controller = context.coordinator
        controller.onPreviewState = onPreviewState
        controller.onSceneReady = onSceneReady
        controller.applyAppearance(appearance, lightPhase: lightPhase, seeThrough: seeThrough)
        controller.onTapFurniture = onTapFurniture
        controller.onTapCell = onTapCell
        controller.onTapWall = onTapWall
        controller.reduceMotion = reduceMotion
        controller.bella.groundGait = groundGait
        // 设置 › 画质 takes effect at once: read here, so a change updates this view.
        controller.applyQuality(app.quality.tier.settings)
        for recognizer in view.gestureRecognizers ?? [] where recognizer.name == "play-follow" {
            recognizer.isEnabled = isLiveRoom && playSession?.windUpMouseID == nil && playSession?.item?.isTreat == false
        }
        if isLiveRoom { snapshotSource?.controller = controller }
        controller.cameraGestures.onChange = inspectorCoversScene == true ? nil : onCameraChange
        controller.cameraGestures.isZoomed = framing.isZoomed
        controller.cameraGestures.playing = playSession?.isActive == true
        controller.cameraGestures.attach(to: controller.cameraGestures.onChange == nil ? nil : view)
        controller.framing = framing
        controller.showStorageChest(showsStorageChest, art: app.art)
        // Bella holds still while the room is not what the user is looking at. Sheets this view
        // cannot see from here (list, about, photo picker) are caught by the controller.
        controller.bellaPaused = !isLiveRoom || scenePhase != .active || app.importSession != nil || app.isPreparingImport
            || (inspectorCoversScene ?? (app.openedFurnitureID != nil)) || app.movingFurnitureID != nil
        controller.bella.onStatus = isLiveRoom ? { [app] status in app.bellaStatus = status } : nil
        if let art = app.art {
            // Every cat wears the chosen cat pack for now; a look of its own per cat is not built.
            // The tier follows 画质 (`AppModel.roomCat`); the postcard uses the best one there is.
            controller.postcardCat = app.postcardCat
            controller.onCatTierUnusable = { [app] variant in app.catTierUnusable(variant) }
            controller.sync(items: items, ghost: ghost, art: art, cat: app.roomCat,
                            showsLead: cats?.isEmpty != true, companions: isLiveRoom ? Array((cats ?? []).dropFirst().map(\.catId)) : [])
            if isLiveRoom { controller.syncPlay(playSession) }
            if isLiveRoom, let invitation, invitation.id != controller.lastInvitation {
                controller.bella.invite(itemId: invitation.itemId, siteId: invitation.siteId, action: invitation.action)
                controller.lastInvitation = invitation.id
            }
            if isLiveRoom, let summon, summon.id != controller.lastSummon,
               !RoomSceneController.answeredSummons.contains(summon.id) {
                controller.bella.come(to: summon.cell)
                controller.lastSummon = summon.id
                RoomSceneController.answeredSummons.insert(summon.id)
            }
        }
    }

    static func dismantleUIView(_ view: ARView, coordinator: RoomSceneController) {
        coordinator.detach()
    }
}

/// The fixed orthographic camera, shared by the renderer, picking and the SwiftUI hotspots.
struct RoomProjection: Equatable {
    static let position: SIMD3<Float> = [14, 14.35, 17]
    static let target: SIMD3<Float> = [0, 1.55, 0]
    private static let overview = SIMD2<Float>(15.45, 11.4) * (Float(GridRules.size) / 10)
    private static let closeUp: SIMD2<Float> = [5.2, 4.8]
    private var frame = overview
    private var closeness: Float = 0
    private var offset: SIMD2<Float> = .zero

    var isZoomed: Bool { closeness > 0 }
    private var center: SIMD3<Float> { Self.target + Self.right * offset.x + Self.up * offset.y }

    static let postcardAspect = RoomPostcard.sceneSize.width / RoomPostcard.sceneSize.height
    static func postcard(fitting bounds: BoundingBox, aspect: CGFloat = postcardAspect, filling: Float = 0.94) -> Self {
        var result = Self()
        let aspect = Float(aspect)
        let centerOffset = bounds.center - target
        result.offset = [simd_dot(centerOffset, right), simd_dot(centerOffset, up)]
        let width = simd_dot(bounds.extents, abs(right))
        let height = simd_dot(bounds.extents, abs(up))
        // The room occupies up to 94% of the postcard aperture, including tall furniture.
        let apertureWidth = max(width, height * aspect) / filling
        result.frame = [apertureWidth, apertureWidth / aspect]
        return result
    }

    /// Keep the world point under the pinch fixed, or move it by the pan in screen points.
    mutating func adjust(scale: CGFloat = 1, anchor: CGPoint = .zero, pan: CGSize = .zero, in size: CGSize) {
        guard size.width > 0, size.height > 0, scale.isFinite, scale > 0 else { return }
        let aspect = Float(size.width / size.height)
        let full = max(frame.x, frame.y * aspect), close = max(Self.closeUp.x, Self.closeUp.y * aspect)
        let old = horizontalExtent(for: size)
        let extent = min(full, max(close, old / Float(scale)))
        closeness = (full - extent) / (full - close)
        let pixel = extent / Float(size.width)
        offset.x += (Float(anchor.x / size.width) - 0.5) * (old - extent) - Float(pan.width) * pixel
        offset.y += (0.5 - Float(anchor.y / size.height)) * (old - extent) / aspect + Float(pan.height) * pixel
        let limit = simd_min(frame, SIMD2<Float>(1, 1 / aspect) * (full - extent)) / 2
        offset = simd_clamp(offset, -limit, limit)
    }

    /// Part of the way from this framing to `other` (0 here, 1 there): the tour's animated reset.
    func blended(toward other: Self, _ fraction: Float) -> Self {
        let t = min(max(fraction, 0), 1)
        var result = other
        result.frame = frame + (other.frame - frame) * t
        result.closeness = closeness + (other.closeness - closeness) * t
        result.offset = offset + (other.offset - offset) * t
        return result
    }

    var eye: SIMD3<Float> { Self.position + center - Self.target }

    func aim(_ camera: Entity) {
        camera.look(at: center, from: eye, relativeTo: nil)
    }
    static let forward = simd_normalize(target - position)
    static let right = simd_normalize(simd_cross(forward, [0, 1, 0]))
    static let up = simd_cross(right, forward)

    /// Full horizontal extent of the view volume, in cells.
    func horizontalExtent(for size: CGSize) -> Float {
        guard size.width > 0, size.height > 0 else { return frame.x }
        let aspect = Float(size.width / size.height)
        let full = max(frame.x, frame.y * aspect), close = max(Self.closeUp.x, Self.closeUp.y * aspect)
        return full + (close - full) * closeness
    }

    func point(_ world: SIMD3<Float>, in size: CGSize) -> CGPoint {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        let extent = horizontalExtent(for: size)
        let vertical = extent * Float(size.height / max(size.width, 1))
        let offset = world - eye
        return CGPoint(
            x: CGFloat(simd_dot(offset, Self.right) / extent + 0.5) * size.width,
            y: CGFloat(0.5 - simd_dot(offset, Self.up) / vertical) * size.height)
    }

    func ray(through point: CGPoint, in size: CGSize) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard size.width > 0, size.height > 0 else { return nil }
        let extent = horizontalExtent(for: size)
        let vertical = extent * Float(size.height / size.width)
        let x = (Float(point.x / size.width) - 0.5) * extent
        let y = (0.5 - Float(point.y / size.height)) * vertical
        return (eye + Self.right * x + Self.up * y, Self.forward)
    }

    func storageChestRect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .null }
        var rect = CGRect.null
        for x in [-RoomStorageChest.halfWidth, RoomStorageChest.halfWidth] {
            for z in [-RoomStorageChest.halfDepth, RoomStorageChest.halfDepth] {
                for y: Float in [0, RoomStorageChest.height] {
                    let corner = point(RoomStorageChest.position + [x, y, z], in: size)
                    rect = rect.union(CGRect(origin: corner, size: .zero))
                }
            }
        }
        return rect
    }

    /// Where a screen point meets the floor, in grid units: cell `x` spans `x..<x + 1`.
    func floorPoint(at point: CGPoint, in size: CGSize) -> SIMD2<Float>? {
        guard let ray = ray(through: point, in: size), ray.direction.y < -0.001 else { return nil }
        let hit = ray.origin + ray.direction * (-ray.origin.y / ray.direction.y)
        let half = Float(GridRules.size) / 2
        return [hit.x + half, hit.z + half]
    }

    /// What a screen point touches first on its way into the room: a wall (with the offset along
    /// it in cells, which may run past either end) or, with `wall` nil, the floor. `floor` is
    /// the floor plane under the point either way, as `floorPoint` gives it.
    func touch(at point: CGPoint, in size: CGSize) -> RoomTouch {
        var touch = RoomTouch(floor: floorPoint(at: point, in: size))
        guard let ray = ray(through: point, in: size), ray.direction.x < -0.001, ray.direction.z < -0.001 else { return touch }
        let half = Float(GridRules.size) / 2
        let left = (-half - ray.origin.x) / ray.direction.x, back = (-half - ray.origin.z) / ray.direction.z
        let floor = ray.direction.y < -0.001 ? -ray.origin.y / ray.direction.y : .infinity
        guard min(left, back) < floor else { return touch }
        let hit = ray.origin + ray.direction * min(left, back)
        touch.wall = left < back ? (.left, hit.z + half) : (.back, hit.x + half)
        return touch
    }

    /// Screen bounding box of a piece of furniture (footprint × fitted height), or of a wall
    /// piece on its wall.
    func screenRect(for item: PhotoFurniture, catalog: FurnitureCatalog?, in size: CGSize) -> CGRect {
        if let wall = item.wall {
            let centre = WallGeometry.centre(wall: wall, x: item.x, width: item.width)
            let reach = WallGeometry.along(wall) * (Float(item.width) / 2 - WallGeometry.inset)
            var rect = CGRect.null
            for side: Float in [-1, 1] {
                for y in [-WallGeometry.pieceHeight / 2, WallGeometry.pieceHeight / 2] {
                    for out in [0, WallGeometry.thickness] {
                        let corner = self.point(centre + reach * side + [0, y, 0] + WallGeometry.normal(wall) * out, in: size)
                        rect = rect.union(CGRect(origin: corner, size: .zero))
                    }
                }
            }
            return rect
        }
        let footprint = ArtLibrary.rotatedSize(width: item.width, depth: item.depth, turn: item.turn)
        let centre = ArtLibrary.worldPoint(x: item.x, z: item.z, width: item.width, depth: item.depth, turn: item.turn)
        let height = catalog?.model(id: item.modelId).map { ArtLibrary.fit($0, width: item.width, depth: item.depth).height } ?? 1
        var rect = CGRect.null
        for dx in [-footprint.w / 2, footprint.w / 2] {
            for dz in [-footprint.d / 2, footprint.d / 2] {
                for y in [0, height] {
                    let corner = point(centre + [dx, y, dz], in: size)
                    rect = rect.union(CGRect(origin: corner, size: .zero))
                }
            }
        }
        return rect
    }
}

/// See `RoomProjection.touch`.
struct RoomTouch {
    var floor: SIMD2<Float>?
    var wall: (side: WallSide, offset: Float)?

    /// The offset along `current` this touch stands for: where it meets a wall, or else the
    /// floor point carried straight back to `current`. A touch on the other wall changes wall.
    func wallSpot(from current: WallSide) -> (side: WallSide, offset: Float)? {
        wall ?? floor.map { (current, current == .back ? $0.x : $0.y) }
    }
}

enum RoomRendering {
    static func configure(_ view: ARView, hdrEnvironment: Bool = false) {
        view.renderOptions = [
            .disableMotionBlur, .disableDepthOfField, .disableCameraGrain, .disablePersonOcclusion,
            .disableFaceMesh, .disableAREnvironmentLighting, .disableHDR, .disableGroundingShadows,
        ]
        RoomLook.current?.install(on: view, hdrEnvironment: hdrEnvironment)
    }

    static func renderScale(_ settings: RenderQualitySettings) -> CGFloat {
        let scale = CGFloat(settings.renderScale(screenScale: Double(UIScreen.main.scale)))
        #if DEBUG || DRILLS
        if ProcessInfo.processInfo.arguments.contains("-MeowverseCapRoomScaleAt2x") { return min(scale, 2) }
        #endif
        return scale
    }
}

/// ARView that reports its size so the orthographic frame can follow layout.
final class LayoutReportingARView: ARView {
    var onLayout: ((CGSize) -> Void)?

    /// How many room views are alive. While any is, an AR view in the same app shows no camera
    /// picture, so the AR page waits for this to reach zero.
    @MainActor static private(set) var alive = 0

    @MainActor override init(frame: CGRect, cameraMode: ARView.CameraMode, automaticallyConfigureSession: Bool) {
        super.init(frame: frame, cameraMode: cameraMode, automaticallyConfigureSession: automaticallyConfigureSession)
        Self.alive += 1
    }

    @MainActor required init(frame: CGRect) {
        super.init(frame: frame)
        Self.alive += 1
    }

    @MainActor required dynamic init?(coder decoder: NSCoder) {
        super.init(coder: decoder)
        Self.alive += 1
    }

    deinit {
        MainActor.assumeIsolated { Self.alive -= 1 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        presentFramesAsRendered()
        onLayout?(bounds.size)
    }

    /// RealityKit's drawable layer presents with Core Animation transactions, so a rendered frame
    /// reaches the screen only when something else in the app commits one. In 摆放 the draft is
    /// added when its model has loaded, after the press's own commit: the preview kept showing
    /// the frame before (no piece, or the piece a cell behind) until the next touch.
    private func presentFramesAsRendered() {
        for case let drawable as CAMetalLayer in layer.sublayers ?? [] where drawable.presentsWithTransaction {
            drawable.presentsWithTransaction = false
        }
    }
}

final class RoomSceneController: NSObject {
    var onTapFurniture: ((String) -> Void)?
    var onTapCell: ((Int, Int) -> Void)?
    var onTapWall: ((WallSide, Int) -> Void)?
    var reduceMotion = false
    /// Set from SwiftUI: the app is inactive, or an import or a furniture sheet covers the room.
    var bellaPaused = false
    let bella = BellaActor()
    var lastInvitation: UUID?
    var lastSummon: UUID?
    /// Every "come here" any room scene has acted on. The room page drops its scene while
    /// 放到桌上看看 is open and builds a new controller afterwards (and `lastSummon` with it),
    /// while the page still holds the last summon: without this she would be called again.
    /// One id per spoken command, so it stays tiny.
    static var answeredSummons: Set<UUID> = []
    var framing = RoomProjection() {
        didSet {
            guard oldValue != framing, let view else { return }
            frameCamera(for: view.bounds.size)
        }
    }

    private weak var view: ARView?
    private let anchor = AnchorEntity(world: .zero)
    /// Everything of the room: shell, furniture, cats, props. In the app it sits where the anchor
    /// is; on a table in AR it is scaled, turned and moved there (`placeOnTable`).
    private let room = Entity()
    /// AR (round 11 trial): the room stands on a real table, seen through the phone's camera,
    /// instead of in front of the fixed orthographic camera.
    private(set) var isTabletop = false
    /// On a table the lights turn with the room but are not scaled with it, so the sun's shadow
    /// reach stays in metres.
    private let lightRig = Entity()
    private let camera = Entity()
    private let furnitureRoot = Entity()
    private let shell = RoomShellAppearance()
    private let floorShadows = RoomFloorShadows()
    private var hdrEnvironmentActive = false
    private let ghostRoot = Entity()
    private let placementGrid = Entity()
    private var storageChest: Entity?
    private var storageChestHasSurfaceMaps = false
    private var storageChestAppearanceTask: Task<Void, Never>?
    private var bellaTask: Task<Void, Never>?
    /// False in a room no cat is in: the first cat's actor stays, hidden and still.
    private var showsLead = true
    private var companions: [String: Companion] = [:]
    private var bellaLoadFailed = false
    private weak var syncedArt: ArtLibrary?
    /// The cat pack and tier the room should show; a change of either swaps the cat's meshes
    /// without a relaunch, and she carries on from where she was (`BellaActor.resume`).
    private var wantedCat: CatPackVariant?
    /// The finest tier there is (never 低), for the postcard. Nil: the postcard keeps the room's cat.
    var postcardCat: CatPackVariant?
    /// A 低/高 tier's files did not load: the app marks the tier unusable and the room gets 中.
    var onCatTierUnusable: ((CatPackVariant) -> Void)?
    private var hasAllFurniture = false
    private var updates: (any Cancellable)?
    private var shown: [String: (item: PhotoFurniture, entity: Entity, details: ArtLibrary.FurnitureDetails)] = [:]
    private var pendants: [String: Entity] = [:]
    private var swingingItemId: String?
    private var furnitureLoads: [String: (item: PhotoFurniture, details: ArtLibrary.FurnitureDetails, task: Task<Void, Never>)] = [:]
    private var ghostLoad: Task<Void, Never>?
    private var shownGhost: GhostFurniture?
    private var ghostDetails = ArtLibrary.FurnitureDetails.flat
    var onPreviewState: ((PlacementPreviewState) -> Void)?
    var onSceneReady: (() -> Void)?
    private var reportedReady = false
    private var previewState: PlacementPreviewState = .loading
    private var reportedPreviewState: PlacementPreviewState?
    /// The draft's model and what it was built from: kept while the same piece is moved or
    /// turned. `ghostKey` is set from the start of the load, `ghostEntity` once it has loaded.
    private var ghostKey: PlacementPreviewKey<ArtLibrary.FurnitureDetails>?
    private var ghostEntity: Entity?
    private var firstSync = true
    private weak var playSession: RoomPlaySession?
    private let playProp = PlayProp()
    private var runningMouse: WindUpMouse?
    private var playItems: [PhotoFurniture] = []
    #if DEBUG || DRILLS
    /// `-MeowverseCatProbe`: an invisible element whose value is the lead cat's pack and exact
    /// floor position and heading, so a UI test can check she stays put across a pack switch.
    /// It sits on the window: the scene view itself is hidden from accessibility.
    private var probe: UIView?
    /// `-MeowverseQualityProbe`: what the room view really draws with (drawable scale, sun shadow).
    private var qualityProbe: UIView?
    private var probesFurnitureTextures = false
    /// `-MeowverseCatProbe`: the cat (`pack#tier`) on the last postcard taken, read after the
    /// share sheet is closed.
    private var postcardProbe: UIView?
    /// `-MeowverseGhostProbe`: the placement preview's draft as drawn: its cell, turn, how many
    /// furniture models stand in the draft layer (the footprint planes are not counted) and the
    /// preview state, so a UI test can tell a draft that vanished from one still loading.
    private var ghostProbe: UIView?
    /// `-MeowverseGhostProbe`: how many times the draft's 3D model was loaded, and how many times
    /// 「正在载入 3D 模型…」 was reported to the editor, since this view was made.
    private var ghostLoadsProbe: UIView?
    private var ghostModelLoads = 0
    private var ghostLoadingReports = 0
    private static let probesGhost = ProcessInfo.processInfo.arguments.contains("-MeowverseGhostProbe")
    #endif
    /// 设置 › 画质 as applied to this view; nil until the first update.
    private var appliedQuality: RenderQualitySettings?
    private var furnitureTextureLimit: Int { appliedQuality?.furnitureTextureLimit ?? FurnitureBaseColors.fullSize }

    private var furnitureOcclusion: Bool { FurnitureOcclusion.enabled(appliedQuality?.furnitureOcclusion ?? true) }

    /// The room page and the placement editor follow 画质. AR on a table keeps RealityKit's own
    /// settings (not part of this round), and the postcard is drawn in full (`capturePostcard`).
    func applyQuality(_ settings: RenderQualitySettings) {
        guard !isTabletop, let view, settings != appliedQuality else { return }
        let previousOcclusion = furnitureOcclusion
        if appliedQuality?.hdrEnvironment != settings.hdrEnvironment {
            hdrEnvironmentActive = RoomLook.current?.setEnvironment(on: view, hdr: settings.hdrEnvironment) == true
        }
        appliedQuality = settings
        if previousOcclusion != furnitureOcclusion {
            FurnitureOcclusion.set(furnitureOcclusion, on: furnitureRoot)
            FurnitureOcclusion.set(furnitureOcclusion, on: ghostRoot)
        }
        let scale = RoomRendering.renderScale(settings)
        if view.contentScaleFactor != scale {
            view.contentScaleFactor = scale
            view.setNeedsLayout()
        }
        shell.setSunShadows(settings.sunShadows)
        refreshFloorShadows()
    }

    func attach(to view: ARView, tabletop: Bool = false) {
        self.view = view
        isTabletop = tabletop
        view.scene.addAnchor(anchor)
        anchor.addChild(room)
        if tabletop {
            anchor.addChild(lightRig)
            // Not shown until it is put down on a table.
            room.isEnabled = false
        }
        #if DEBUG || DRILLS
        if ProcessInfo.processInfo.arguments.contains("-MeowverseCatProbe") {
            let probe = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
            probe.isAccessibilityElement = true
            probe.accessibilityIdentifier = "bella-probe"
            probe.accessibilityLabel = "bella-probe"
            self.probe = probe
            if !tabletop {
                let card = UIView(frame: CGRect(x: 4, y: 0, width: 2, height: 2))
                card.isAccessibilityElement = true
                card.accessibilityIdentifier = "postcard-cat-probe"
                card.accessibilityLabel = "postcard-cat-probe"
                card.accessibilityValue = "none"
                postcardProbe = card
            }
        }
        if !tabletop, ProcessInfo.processInfo.arguments.contains("-MeowverseQualityProbe") {
            let probe = UIView(frame: CGRect(x: 2, y: 0, width: 2, height: 2))
            probe.isAccessibilityElement = true
            probe.accessibilityIdentifier = "room-quality-probe"
            probe.accessibilityLabel = "room-quality-probe"
            qualityProbe = probe
            probesFurnitureTextures = ProcessInfo.processInfo.arguments.contains("-MeowverseFurnitureTextureProbe")
        }
        #endif
        buildShell()
        room.addChild(furnitureRoot)
        room.addChild(ghostRoot)
        room.addChild(bella.root)
        room.addChild(playProp.root)
        bella.onPlayConsumed = { [weak self] id in self?.playSession?.consumed(id) }
        bella.onPlayRejected = { [weak self] id in self?.playSession?.rejected(id) }
        // Bella is driven by the render loop: no frames (background, dismantled view), no motion.
        updates = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            guard let self else { return }
            if let report = self.onPreviewState, self.previewState != self.reportedPreviewState {
                self.reportedPreviewState = self.previewState
                #if DEBUG || DRILLS
                if self.previewState == .loading { self.ghostLoadingReports += 1 }
                #endif
                report(self.previewState)
            }
            self.bella.reduceMotion = self.reduceMotion
            let active = self.isBellaActive
            self.bella.tick(event.deltaTime, active: active && self.showsLead)
            for companion in self.companions.values {
                companion.actor.reduceMotion = self.reduceMotion
                companion.actor.groundGait = self.bella.groundGait
                companion.actor.tick(event.deltaTime, active: active)
            }
            self.playProp.update(time: event.deltaTime, progress: self.bella.playProgress, active: active, reduceMotion: self.reduceMotion)
            #if DEBUG || DRILLS
            self.updateProbe()
            #endif
            TourCatLocator.shared.report(self.bella, live: !self.isTabletop && self.bella.onStatus != nil)
            if active {
                self.updatePendant()
                self.updateMouse(delta: event.deltaTime)
            }
        }

        // On a table, ARKit's camera is the camera.
        guard !tabletop else { return }
        var lens = OrthographicCameraComponent()
        lens.near = 0.1
        lens.far = 80
        lens.scaleDirection = .horizontal
        camera.components.set(lens)
        framing.aim(camera)
        anchor.addChild(camera)
    }

    #if DEBUG || DRILLS
    private func updateProbe() {
        if let qualityProbe, let view {
            // Only the saved room's view, read back from the view and the light themselves.
            let window = bella.onStatus != nil ? view.window : nil
            if qualityProbe.superview !== window {
                qualityProbe.removeFromSuperview()
                window?.addSubview(qualityProbe)
            }
            var value = String(format: "scale %.2f shadows %@", Double(view.contentScaleFactor), shell.castsSunShadows ? "on" : "off")
            if probesFurnitureTextures {
                let materials = Self.furnitureMaterials(in: furnitureRoot)
                let widths = materials.compactMap { $0.baseColor.texture?.resource.width }.sorted().map(String.init)
                value += " albedos " + (widths.isEmpty ? "none" : widths.joined(separator: ","))
                value += " occlusion \(materials.filter { $0.ambientOcclusion.texture != nil }.count)"
                let roughness = materials.filter { $0.roughness.texture != nil }.count
                let normals = materials.filter { $0.normal.texture != nil }.count
                value += " hdr \(hdrEnvironmentActive ? "on" : "off") floor \(shell.hasFloorOcclusion ? "on" : "off") maps \(roughness),\(normals)"
            }
            if qualityProbe.accessibilityValue != value { qualityProbe.accessibilityValue = value }
        }
        if Self.probesGhost, let view, bella.onStatus == nil,
           let ghost = shownGhost {
            if ghostProbe == nil {
                let made = UIView(frame: CGRect(x: 6, y: 0, width: 2, height: 2))
                made.isAccessibilityElement = true
                made.accessibilityIdentifier = "placement-ghost-probe"
                made.accessibilityLabel = "placement-ghost-probe"
                ghostProbe = made
            }
            if let ghostProbe, ghostProbe.superview !== view.window {
                ghostProbe.removeFromSuperview()
                view.window?.addSubview(ghostProbe)
            }
            let models = ghostRoot.children.filter { !($0 is ModelEntity) && $0.isEnabled }.count
            let state = switch previewState { case .loading: "loading"; case .ready: "ready"; case .unavailable: "unavailable" }
            let value = "\(ghost.placement.x) \(ghost.placement.z) turn \(ghost.placement.turn) models \(models) \(state)"
            if ghostProbe?.accessibilityValue != value { ghostProbe?.accessibilityValue = value }
            if ghostLoadsProbe == nil {
                let made = UIView(frame: CGRect(x: 8, y: 0, width: 2, height: 2))
                made.isAccessibilityElement = true
                made.accessibilityIdentifier = "placement-ghost-loads-probe"
                made.accessibilityLabel = "placement-ghost-loads-probe"
                ghostLoadsProbe = made
            }
            if let ghostLoadsProbe, ghostLoadsProbe.superview !== view.window {
                ghostLoadsProbe.removeFromSuperview()
                view.window?.addSubview(ghostLoadsProbe)
            }
            let loads = "loads \(ghostModelLoads) loading \(ghostLoadingReports)"
            if ghostLoadsProbe?.accessibilityValue != loads { ghostLoadsProbe?.accessibilityValue = loads }
        } else {
            // No draft on screen: no probe, rather than the last draft's value (BB24-05).
            ghostProbe?.removeFromSuperview()
            ghostLoadsProbe?.removeFromSuperview()
        }
        guard let probe else { return }
        // Only the saved room's cat, not the placement editor's still one.
        let window = bella.onStatus != nil ? view?.window : nil
        if probe.superview !== window {
            probe.removeFromSuperview()
            window?.addSubview(probe)
        }
        let position = bella.root.position, turn = bella.root.orientation
        let yaw = atan2(2 * turn.imag.y * turn.real, 1 - 2 * turn.imag.y * turn.imag.y)
        let shown = bella.isLoaded && bella.root.isEnabled
        let value = "\(shown ? bella.packKey ?? "none" : "none") " + String(format: "%.3f %.3f %.3f", position.x, position.z, yaw)
        if probe.accessibilityValue != value { probe.accessibilityValue = value }
    }

    private static func furnitureMaterials(in entity: Entity) -> [PhysicallyBasedMaterial] {
        var materials = (entity as? ModelEntity)?.model?.materials.compactMap { $0 as? PhysicallyBasedMaterial } ?? []
        for child in entity.children { materials += furnitureMaterials(in: child) }
        return materials
    }
    #endif

    private func updateMouse(delta: TimeInterval) {
        guard let id = playSession?.windUpMouseID else { return }
        if runningMouse == nil, let piece = shown[id] {
            runningMouse = WindUpMouse(piece: piece.item, entity: piece.entity, items: playItems, bella: bella)
        }
        runningMouse?.tick(delta, bella: bella, reduceMotion: reduceMotion)
    }

    private func updatePendant() {
        let swing = bella.toySwing
        if let last = swingingItemId, last != swing?.itemId {
            pendants[last]?.orientation = simd_quatf(angle: 0, axis: [1, 0, 0])
        }
        swingingItemId = swing?.itemId
        if let swing { pendants[swing.itemId]?.orientation = simd_quatf(angle: swing.angle, axis: [1, 0, 0]) }
    }

    let cameraGestures = RoomCameraGestures()

    func showStorageChest(_ visible: Bool, art: ArtLibrary?) {
        if visible, storageChest == nil {
            let chest = RoomStorageChest.make()
            room.addChild(chest)
            storageChest = chest
        }
        storageChest?.isEnabled = visible
        guard let storageChest, let art else { return }
        let enhanced = visible && appliedQuality?.furnitureSurfaceMaps == true
        guard enhanced != storageChestHasSurfaceMaps else { return }
        storageChestHasSurfaceMaps = enhanced
        storageChestAppearanceTask?.cancel()
        storageChestAppearanceTask = Task {
            do {
                try await art.applySurfaceMaps(to: storageChest, model: RoomStorageChest.surfaceID, enabled: enhanced)
            } catch is CancellationError {
                return
            } catch {
                Logger(subsystem: "app.meowverse", category: "furniture-maps").error("Storage chest finish: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func detach() {
        cameraGestures.attach(to: nil)
        for load in furnitureLoads.values { load.task.cancel() }
        furnitureLoads.removeAll()
        floorShadows.cancel()
        storageChestAppearanceTask?.cancel()
        ghostLoad?.cancel()
        ghostLoad = nil
        ghostKey = nil
        ghostEntity = nil
        bellaTask?.cancel()
        for companion in companions.values { companion.task?.cancel() }
        updates?.cancel()
        updates = nil
        #if DEBUG || DRILLS
        probe?.removeFromSuperview()
        qualityProbe?.removeFromSuperview()
        // The window keeps its subviews; a placement opened again must not find this one (BB24-05).
        ghostProbe?.removeFromSuperview()
        ghostProbe = nil
        ghostLoadsProbe?.removeFromSuperview()
        ghostLoadsProbe = nil
        #endif
        bella.onStatus = nil
        bella.onPlayConsumed = nil
        bella.onPlayRejected = nil
        view?.scene.removeAnchor(anchor)
        view = nil
    }

    /// The room is on screen, in the foreground, with nothing presented over it.
    private var isBellaActive: Bool {
        guard !bellaPaused, shownGhost == nil, let window = view?.window else { return false }
        // The AR page is itself presented; what covers it is in `bellaPaused`. The cats start
        // once the room is on the table.
        if isTabletop { return room.isEnabled }
        return window.rootViewController?.presentedViewController == nil
    }

    /// AR: stands the room on the table as `pose` says; nil takes it off again (重新放置).
    func placeOnTable(_ pose: ARTabletopPose?) {
        guard isTabletop else { return }
        guard let pose else {
            room.isEnabled = false
            return
        }
        room.transform = Transform(scale: SIMD3(repeating: pose.scale), rotation: pose.rotation, translation: pose.translation)
        lightRig.orientation = pose.rotation
        room.isEnabled = true
    }

    func frameCamera(for size: CGSize) {
        guard !isTabletop else { return }
        if cameraGestures.onChange != nil { cameraGestures.attach(to: view) }
        guard size.width > 0, size.height > 0, var lens = camera.components[OrthographicCameraComponent.self] else { return }
        framing.aim(camera)
        lens.scale = framing.horizontalExtent(for: size) / 2 // RealityKit's scale is the half extent
        camera.components.set(lens)
    }

    // MARK: Static room

    func applyAppearance(_ appearance: RoomAppearance, lightPhase: RoomLightPhase, seeThrough: Bool) {
        if let view { shell.apply(appearance, lightPhase: lightPhase, to: view, seeThrough: seeThrough, cameraFeed: isTabletop) }
    }

    private func buildShell() {
        let side = Float(GridRules.size)
        // The plinth, floor and walls take the theme's materials.
        if isTabletop {
            // Shadows reach across a table seen from arm's length, in metres (not checked on a phone yet).
            shell.install(on: room, lights: lightRig, shadowReach: 3)
        } else {
            shell.install(on: room, lights: room, shadowReach: 45)
        }
        placementGrid.isEnabled = false
        room.addChild(placementGrid)
        var lineMaterial = UnlitMaterial()
        lineMaterial.color = .init(tint: UIColor(hex: 0xc5b599))
        let alongX = MeshResource.generateBox(size: [side, 0.004, 0.025])
        let alongZ = MeshResource.generateBox(size: [0.025, 0.004, side])
        for index in 0...GridRules.size {
            let offset = Float(index) - side / 2
            let a = ModelEntity(mesh: alongX, materials: [lineMaterial])
            a.position = [0, 0.004, offset]
            let b = ModelEntity(mesh: alongZ, materials: [lineMaterial])
            b.position = [offset, 0.004, 0]
            placementGrid.addChild(a)
            placementGrid.addChild(b)
        }
    }

    // MARK: Sync with app state

    func sync(items: [PhotoFurniture], ghost: GhostFurniture?, art: ArtLibrary, cat: CatPackVariant?,
              showsLead: Bool = true, companions wanted: [String] = []) {
        if runningMouse != nil, playItems != items {
            runningMouse?.putAway()
            runningMouse = nil
        }
        playItems = items
        syncedArt = art
        self.showsLead = showsLead
        if cat?.key != wantedCat?.key {
            let replacing = wantedCat != nil
            wantedCat = cat
            if replacing {
                reloadBella()
                for companion in companions.values { unload(companion) }
            }
        }
        syncCompanions(wanted)
        let wanted = Dictionary(uniqueKeysWithValues: items.map { ($0.instanceId, $0) })
        // Only what the entity is built from (model, size, finish, place) rebuilds it; a new name,
        // photo, cover or lock keeps the piece (and a prop on it) as it is (G24-03).
        for (id, current) in shown {
            guard let item = wanted[id], item.placement == current.item.placement else {
                current.entity.removeFromParent()
                shown[id] = nil
                pendants[id] = nil
                continue
            }
            if item != current.item { shown[id] = (item, current.entity, current.details) }
        }
        for (id, load) in furnitureLoads
        where wanted[id]?.placement != load.item.placement || load.details != furnitureDetails(for: load.item.modelId, art: art) {
            load.task.cancel()
            furnitureLoads[id] = nil
        }
        for item in items where furnitureLoads[item.instanceId] == nil {
            let details = furnitureDetails(for: item.modelId, art: art)
            if shown[item.instanceId]?.details != details {
                loadFurniture(item, from: art, details: details, animate: !firstSync)
            }
        }
        firstSync = false
        hasAllFurniture = shown.count == wanted.count

        for (id, current) in shown { current.entity.isEnabled = id != ghost?.lifted }
        let details = ghost.map { furnitureDetails(for: $0.placement.modelId, art: art) } ?? .flat
        if ghost != shownGhost || details != ghostDetails {
            placementGrid.isEnabled = ghost != nil
            shownGhost = ghost
            ghostDetails = details
            let model = ghost.flatMap { art.catalog.model(id: $0.placement.modelId) }
            let wanted = ghost.flatMap { ghost in model.map { _ in PlacementPreviewKey(ghost.placement, lifted: ghost.lifted, details: details) } }
            let shows = ghost.map { PlacementPreviewPlan.showsModel(valid: $0.valid, lifted: $0.lifted) } ?? false
            // The same piece moved or turned keeps the model it has (or is loading), so the preview
            // neither blinks nor goes back to 「正在载入 3D 模型…」 at every cell (l-placement-preview).
            let plan = PlacementPreviewPlan.plan(held: ghostKey, wanted: wanted, shows: shows)
            ghostRoot.children.removeAll()
            if !plan.keepsHeld {
                ghostLoad?.cancel()
                ghostLoad = nil
                ghostEntity = nil
                ghostKey = nil
            }
            previewState = .ready
            if let ghost, let model, let wanted {
                let wallMount = model.mount == .wall
                if plan.keepsHeld {
                    if let ghostEntity {
                        if shows {
                            // Kept off the layer on a cell it may not take, it missed any 画质 change there.
                            FurnitureOcclusion.set(furnitureOcclusion, on: ghostEntity)
                            ghostRoot.addChild(ghostEntity)
                            place(ghostEntity, for: ghost, wallMount: wallMount, rising: false)
                        }
                    } else if shows {
                        // The first load is still on its way; it puts the model where the draft is then.
                        previewState = .loading
                    }
                } else if plan.startsLoad {
                    previewState = .loading
                    ghostKey = wanted
                    #if DEBUG || DRILLS
                    ghostModelLoads += 1
                    #endif
                    ghostLoad = Task { [weak self] in
                        guard let self else { return }
                        let loaded = try? await art.furnitureEntity(model: model, placement: ghost.placement,
                                                                    details: details, occlusion: self.furnitureOcclusion)
                        guard !Task.isCancelled, self.ghostKey == wanted else { return }
                        self.ghostLoad = nil
                        guard let entity = loaded else {
                            self.ghostKey = nil
                            self.previewState = .unavailable
                            return
                        }
                        entity.components.remove(CollisionComponent.self)
                        FurnitureOcclusion.set(self.furnitureOcclusion, on: entity)
                        self.ghostEntity = entity
                        if let latest = self.shownGhost,
                           PlacementPreviewPlan.showsModel(valid: latest.valid, lifted: latest.lifted) {
                            self.ghostRoot.addChild(entity)
                            self.place(entity, for: latest, wallMount: wallMount, rising: true)
                        }
                        self.previewState = .ready
                    }
                }
                addFootprint(for: ghost)
            } else if ghost != nil {
                previewState = .unavailable
            }
        }
        // Wall pieces are not part of Bella's world: she neither visits nor walks around them.
        let floorItems = items.filter { $0.wall == nil }
        bella.sync(items: floorItems, catalog: art.catalog)
        bella.root.isEnabled = showsLead && bella.isLoaded && ghost == nil
        for companion in companions.values {
            companion.actor.sync(items: floorItems, catalog: art.catalog)
            companion.actor.root.isEnabled = companion.actor.isLoaded && ghost == nil
        }
        if ghost == nil {
            loadBella(from: art)
            loadCompanions(from: art)
        }
        refreshFloorShadows()
        reportReadyIfLoaded()
    }

    private func refreshFloorShadows() {
        guard !isTabletop, let art = syncedArt else { return }
        let items = furnitureLoads.isEmpty ? shown.values.map(\.item) : playItems
        let placements = appliedQuality?.softFloorShadows == true
            ? RoomFloorShadows.placements(for: items, excluding: shownGhost?.lifted, catalog: art.catalog)
            : []
        floorShadows.update(placements) { [weak self] in self?.shell.setFloorOcclusion($0) }
    }

    /// The first set of furniture has settled (shown or failed) and the cat, when the room has
    /// one, is in or failed. Reported once, after the current SwiftUI update.
    private func reportReadyIfLoaded() {
        guard !reportedReady, !firstSync, furnitureLoads.isEmpty,
              !showsLead || bella.isLoaded || bellaLoadFailed, let onSceneReady else { return }
        reportedReady = true
        Task { @MainActor in onSceneReady() }
    }

    private func furnitureDetails(for modelID: String, art: ArtLibrary) -> ArtLibrary.FurnitureDetails {
        guard let model = art.catalog.model(id: modelID) else { return .flat }
        return .init(textureLimit: art.hasFurnitureBaseColors(model.id) ? furnitureTextureLimit : 0,
                     surfaceMaps: appliedQuality?.furnitureSurfaceMaps == true && FurnitureSurfaceMaps.supports(model: model.id, slot: nil))
    }

    private func loadFurniture(_ item: PhotoFurniture, from art: ArtLibrary, details: ArtLibrary.FurnitureDetails, animate: Bool) {
        guard let model = art.catalog.model(id: item.modelId) else { return }
        let id = item.instanceId
        let task = Task { [weak self] in
            do {
                guard let self else { return }
                let placement = Placement(item)
                if let piece = self.shown[id]?.entity {
                    try await art.applyFurnitureDetails(to: piece, placement: placement, details: details)
                    try Task.checkCancellation()
                    self.shown[id] = (self.latest(item), piece, details)
                } else {
                    let entity = try await art.furnitureEntity(model: model, placement: placement, details: details,
                                                               occlusion: self.furnitureOcclusion)
                    try Task.checkCancellation()
                    self.addFurniture(entity, item: self.latest(item), details: details, animate: animate)
                }
                self.hasAllFurniture = self.shown.count == self.playItems.count
            } catch {
                guard !Task.isCancelled else { return }
                Logger(subsystem: "Meowverse", category: "art").error("Furniture unavailable: \(model.id, privacy: .public)")
            }
            self?.furnitureLoads[id] = nil
            if self?.furnitureLoads.isEmpty == true { self?.refreshFloorShadows() }
            self?.reportReadyIfLoaded()
        }
        furnitureLoads[id] = (item, details, task)
    }

    /// The piece as last synced: a load keeps running across a change of name or photos (same
    /// placement), so it records the newer record, not the one it started with.
    private func latest(_ item: PhotoFurniture) -> PhotoFurniture {
        playItems.first { $0.instanceId == item.instanceId && $0.placement == item.placement } ?? item
    }

    private func addFurniture(_ entity: Entity, item: PhotoFurniture, details: ArtLibrary.FurnitureDetails, animate: Bool) {
        let id = item.instanceId
        entity.name = "furniture:" + id
        entity.isEnabled = id != shownGhost?.lifted
        FurnitureOcclusion.set(furnitureOcclusion, on: entity)
        furnitureRoot.addChild(entity)
        shown[id] = (item, entity, details)
        pendants[id] = entity.findEntity(named: ArtLibrary.pendantName)
        if animate, !reduceMotion { settle(entity) }
    }

    // MARK: More than one cat

    /// A cat of the room other than the one the captions follow. It runs the same routine by
    /// itself: no caption, no invitations, no play.
    private final class Companion {
        let actor = BellaActor()
        var task: Task<Void, Never>?
        var failed = false
    }

    /// Adds and removes the other cats so the scene has exactly `wanted`, in that order.
    private func syncCompanions(_ wanted: [String]) {
        for (id, companion) in companions where !wanted.contains(id) {
            companion.task?.cancel()
            companion.actor.root.removeFromParent()
            companions[id] = nil
        }
        for (index, id) in wanted.enumerated() where companions[id] == nil {
            let companion = Companion()
            let actor = companion.actor
            // Beside the door, one cell further along for each cat; a cell that is taken or
            // outside the room is moved to the nearest free one when the room is synced.
            actor.start(at: GridCell(x: GridRules.entrance.x + (index + 1) * (index.isMultiple(of: 2) ? 1 : -1), z: GridRules.entrance.z - 1),
                        after: Double(index + 1) * 1.7)
            actor.avoiding = { [weak self, weak actor] in self?.claimed(besides: actor) ?? [] }
            room.addChild(actor.root)
            companions[id] = companion
        }
        bella.avoiding = { [weak self] in
            guard let self else { return [] }
            return self.claimed(besides: self.bella)
        }
    }

    /// The pieces the other cats are on or heading for.
    private func claimed(besides actor: BellaActor?) -> Set<String> {
        var taken = Set(companions.values.filter { $0.actor !== actor }.compactMap(\.actor.claimedItemId))
        if bella !== actor, showsLead, let id = bella.claimedItemId { taken.insert(id) }
        return taken
    }

    private func unload(_ companion: Companion) {
        companion.task?.cancel()
        companion.task = nil
        companion.failed = false
        companion.actor.unload()
        companion.actor.root.isEnabled = false
    }

    private func loadCompanions(from art: ArtLibrary) {
        guard let cat = wantedCat, !companions.values.contains(where: { $0.task != nil }),
              let companion = companions.values.first(where: { !$0.actor.isLoaded && !$0.failed }) else { return }
        let resources = art.resources(for: cat)
        companion.task = Task { [weak self, weak companion] in
            await self?.bellaTask?.value
            guard let self, let companion, !Task.isCancelled else { return }
            do {
                try await companion.actor.load(from: resources, catalog: art.catalog)
                try Task.checkCancellation()
                companion.actor.root.isEnabled = self.shownGhost == nil
            } catch {
                guard !Task.isCancelled else { return }
                Logger(subsystem: "Meowverse", category: "art").error("Second cat failed to load: \(String(describing: error), privacy: .public)")
                companion.failed = true
            }
            companion.task = nil
            if self.shownGhost == nil { self.loadCompanions(from: art) }
        }
    }

    /// New furniture eases down into place instead of popping in.
    private func settle(_ entity: Entity) {
        let rest = entity.transform
        var start = rest
        start.translation.y += 0.6
        entity.transform = start
        entity.move(to: rest, relativeTo: entity.parent, duration: 0.35, timingFunction: .easeOut)
    }

    /// The draft's model where the draft is: a lifted piece hovers there, a new one stands there.
    private func place(_ entity: Entity, for ghost: GhostFurniture, wallMount: Bool, rising: Bool) {
        guard ghost.lifted == nil else {
            float(entity, to: ghost.placement, rising: rising)
            return
        }
        var placement = ghost.placement
        // As `ArtLibrary.furnitureEntity` hangs a wall model that names no wall yet.
        if wallMount, placement.wall == nil { placement.wall = .back }
        (entity.position, entity.orientation) = ArtLibrary.pose(of: placement)
    }

    /// The piece being edited hovers over its cell, or a wall piece in front of its wall; with
    /// Reduce Motion it is simply shown there.
    private func float(_ entity: Entity, to placement: Placement, rising: Bool) {
        var hover = entity.transform
        (hover.translation, hover.rotation) = ArtLibrary.pose(of: placement, lift: placement.wall == nil ? 0.35 : 0.3)
        guard !reduceMotion else {
            entity.transform = hover
            return
        }
        if rising {
            var rest = hover
            rest.translation = ArtLibrary.pose(of: placement).position
            entity.transform = rest
        }
        entity.move(to: hover, relativeTo: entity.parent, duration: rising ? 0.25 : 0.12, timingFunction: .easeOut)
    }

    private func addFootprint(for ghost: GhostFurniture) {
        let p = ghost.placement
        let size = ArtLibrary.rotatedSize(width: p.width, depth: p.depth, turn: p.turn)
        var material = UnlitMaterial()
        let color = ghost.valid ? UIColor(hex: 0x6d9977) : UIColor(hex: 0xbb6e62)
        // Under a lifted piece only the rim of the footprint shows, so it is drawn stronger.
        let strength: Float = ghost.lifted == nil ? 0.45 : 0.85
        material.color = .init(tint: color.withAlphaComponent(CGFloat(strength)))
        material.blending = .transparent(opacity: .init(floatLiteral: strength))
        if p.wall != nil {
            // A wall piece marks its span on the wall, a rim wider than the piece itself.
            let patch = ModelEntity(mesh: .generatePlane(width: Float(p.width) - 0.04, height: WallGeometry.pieceHeight + 0.24),
                                    materials: [material])
            (patch.position, patch.orientation) = ArtLibrary.pose(of: p, lift: 0.012)
            ghostRoot.addChild(patch)
            return
        }
        let plane = ModelEntity(mesh: .generatePlane(width: size.w, depth: size.d), materials: [material])
        plane.position = ArtLibrary.worldPoint(x: p.x, z: p.z, width: p.width, depth: p.depth, turn: p.turn) + [0, 0.025, 0]
        ghostRoot.addChild(plane)

        let occupied = GridRules.occupiedCells(x: p.x, z: p.z, width: p.width, depth: p.depth, turn: p.turn)
        // A guide inside the draft already has its fill. A second transparent layer would darken it.
        let uncovered = ghost.accessCells.subtracting(occupied.map { GridCell(x: $0.x, z: $0.z) })
        guard !uncovered.isEmpty else { return }
        let side = PlacementAccessGuides.halfSide * 2
        let tile = MeshResource.generatePlane(width: side, depth: side)
        for cell in uncovered {
            let marker = ModelEntity(mesh: tile, materials: [material])
            marker.position = ArtLibrary.worldPoint(x: cell.x, z: cell.z, width: 1, depth: 1, turn: 0) + [0, plane.position.y, 0]
            ghostRoot.addChild(marker)
        }
    }

    /// Another cat pack or tier was chosen: the old meshes go, the new ones load where she stood.
    private func reloadBella() {
        bellaTask?.cancel()
        bellaTask = nil
        bellaLoadFailed = false
        bella.unload()
        bella.root.isEnabled = false
    }

    private func loadBella(from art: ArtLibrary) {
        guard !bella.isLoaded, !bellaLoadFailed, bellaTask == nil, let cat = wantedCat else { return }
        let resources = art.resources(for: cat)
        bellaTask = Task { [weak self] in
            do {
                try await self?.bella.load(from: resources, catalog: art.catalog)
            } catch {
                // A load cancelled by a pack switch must not clear the newer load's task.
                guard !Task.isCancelled else { return }
                Logger(subsystem: "Meowverse", category: "art").error("Cat pack failed to load: \(String(describing: error), privacy: .public)")
                self?.bellaTask = nil
                if cat.tier != .medium {
                    // A downloaded tier that does not load: 中 instead, not no cat. The app marks
                    // the tier unusable; the next sync brings the 中 variant.
                    Logger(subsystem: "Meowverse", category: "art").error("Cat tier \(cat.tier.rawValue, privacy: .public) unusable; showing medium")
                    self?.onCatTierUnusable?(cat)
                } else {
                    self?.bellaLoadFailed = true
                }
                self?.reportReadyIfLoaded()
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.bella.root.isEnabled = self.showsLead && self.shownGhost == nil
            Perf.mark("RoomReady")
            self.reportReadyIfLoaded()
        }
    }

    /// The postcard's cat when the room shows a coarser tier (低) than the finest there is: that
    /// tier's skeleton player, loaded once for this card and not kept. Nil when the room already
    /// shows the finest, or when it does not load (the card then keeps the room's cat).
    private func postcardSkeleton() async -> GroundGaitPlayer? {
        guard let best = postcardCat, let shown = wantedCat, best.pack.cacheKey == shown.pack.cacheKey,
              best.tier > shown.tier, bella.skeletalPlayer != nil else { return nil }
        do {
            return try await GroundGaitPlayer.load(from: CatArt(variant: best))
        } catch {
            Logger(subsystem: "Meowverse", category: "art").error("Postcard cat tier \(best.tier.rawValue, privacy: .public) unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Nothing the postcard shows is still loading: the furniture, the first cat when the room
    /// has one, and every other cat (in and visible, or failed).
    private var postcardSceneSettled: Bool {
        furnitureLoads.isEmpty
            && (!showsLead || (bella.isLoaded && bella.root.isEnabled))
            && companions.values.allSatisfy { $0.failed || ($0.actor.isLoaded && $0.actor.root.isEnabled) }
    }

    /// Settled and whole: every piece shown, the cats wearing the pack the room wants.
    private var postcardSceneComplete: Bool {
        hasAllFurniture && !firstSync && (!showsLead || bella.packKey == wantedCat?.key)
            && companions.values.allSatisfy { !$0.failed && $0.actor.packKey == wantedCat?.key }
    }

    /// What the postcard copies, compared across its one wait (the finer skeleton) so a room that
    /// changed meanwhile is waited for again instead of copied half-loaded (FF24-03).
    private struct PostcardStamp: Equatable {
        let cat: String?
        let lead: String?
        let furniture: [String: Placement]
        let entities: [String: ObjectIdentifier]
        let details: [String: ArtLibrary.FurnitureDetails]
        let companions: [String: String?]
    }

    private var postcardStamp: PostcardStamp {
        PostcardStamp(cat: wantedCat?.key, lead: bella.packKey,
                      furniture: shown.mapValues(\.item.placement), entities: shown.mapValues { ObjectIdentifier($0.entity) },
                      details: shown.mapValues(\.details), companions: companions.mapValues(\.actor.packKey))
    }

    func capturePostcard() async throws -> CGImage {
        guard let view, view.window != nil, shownGhost == nil, let syncedArt else { throw RoomSnapshotError.unavailable }
        if bellaLoadFailed {
            bellaLoadFailed = false
            loadBella(from: syncedArt)
        }
        // Every cat of the room is on the card, not only the first (G24-04): one that failed
        // gets one more try, as the first cat does above.
        var retriedCompanions = false
        for companion in companions.values where companion.failed {
            companion.failed = false
            retriedCompanions = true
        }
        if retriedCompanions { loadCompanions(from: syncedArt) }
        let deadline = ContinuousClock.now + .seconds(12)
        var finer: GroundGaitPlayer?
        while true {
            // A room no cat is in has nobody to wait for.
            while !postcardSceneSettled {
                try Task.checkCancellation()
                guard !bellaLoadFailed, !companions.values.contains(where: \.failed),
                      ContinuousClock.now < deadline, view.window != nil else { throw RoomSnapshotError.unavailable }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard postcardSceneComplete, view.bounds.width > 0, view.bounds.height > 0 else { throw RoomSnapshotError.unavailable }
            // The card shows the finest tier there is, whatever 画质 the room is drawn with.
            let stamp = postcardStamp
            finer = await postcardSkeleton()
            try Task.checkCancellation()
            // The room may have changed while that loaded (an iCloud update, another cat tier):
            // the card is taken of the scene as it is now, so it must still be whole (FF24-03).
            if postcardStamp == stamp, postcardSceneSettled, postcardSceneComplete { break }
            finer = nil
            guard ContinuousClock.now < deadline, view.window != nil else { throw RoomSnapshotError.unavailable }
        }
        let cardCat = (finer != nil ? postcardCat?.key : bella.packKey) ?? "none"
        Logger(subsystem: "Meowverse", category: "art").notice("Postcard cat \(cardCat, privacy: .public)")
        #if DEBUG || DRILLS
        if let postcardProbe {
            if postcardProbe.superview !== view.window {
                postcardProbe.removeFromSuperview()
                view.window?.addSubview(postcardProbe)
            }
            postcardProbe.accessibilityValue = cardCat
        }
        #endif
        // Freeze copies of the public room geometry at this instant, even if the live room is zoomed.
        let frozen = Entity()
        var bounds = BoundingBox.empty
        let cats = [bella] + companions.values.map(\.actor)
        let postcardFurniture = shown.values.map { ($0.entity.name, Placement($0.item), $0.details) }
        let shadowLayout = RoomFloorShadows.placements(for: shown.values.map(\.item), catalog: syncedArt.catalog)
        var frozenFloor: Entity?
        var frozenFurniture: Entity?
        for child in room.children where child.isEnabled && child !== camera && child !== storageChest {
            bounds.formUnion(child.visualBounds(relativeTo: room, excludeInactive: true))
            let copy = child.clone(recursive: true)
            if child === furnitureRoot { frozenFurniture = copy }
            if shell.isFloor(child) { frozenFloor = copy }
            if cats.contains(where: { $0.root === child }) { copy.components.remove(OpacityComponent.self) }
            if let finer, let live = cats.first(where: { $0.root === child })?.skeletalPlayer,
               let skin = copy.findEntity(named: GroundGaitPlayer.entityName) as? ModelEntity {
                finer.dress(skin, like: live)
            }
            // The card is one still picture: it keeps the sun's shadow on every 画质 tier.
            if child === shell.sunLight, let sun = copy as? DirectionalLight { sun.shadow = shell.sunShadow }
            frozen.addChild(copy)
        }
        for (name, placement, details) in postcardFurniture where details != .full {
            if let furniture = frozenFurniture?.findEntity(named: name) {
                try await syncedArt.applyFurnitureDetails(to: furniture, placement: placement, details: .full)
            }
        }
        if let frozenFloor {
            let texture = try? await RoomFloorShadows.texture(for: shadowLayout)
            try Task.checkCancellation()
            if let texture { RoomShellAppearance.applyFloorOcclusion(texture, to: frozenFloor) }
        }
        return try await PostcardSceneRenderer.render(frozen, bounds: bounds, matching: view, backdrop: shell.solidBackdrop)
    }

    // MARK: Picking

    func syncPlay(_ session: RoomPlaySession?) {
        playSession = session
        if runningMouse?.id != session?.windUpMouseID {
            runningMouse?.putAway()
            runningMouse = nil
        }
        if session?.windUpMouseID != nil {
            playProp.clear()
            return
        }
        bella.play(session?.request)
        if let request = session?.request {
            let point = request.point
            playProp.show(request.item, at: [Float(point.x), 0, Float(point.z)])
        } else {
            playProp.clear()
        }
    }

    private func play(at point: CGPoint) {
        guard let session = playSession, session.isActive, session.windUpMouseID == nil, let catalog = syncedArt?.catalog,
              let view, let floor = framing.floorPoint(at: point, in: view.bounds.size) else { return }
        let x = Int(floor.x.rounded(.down)), z = Int(floor.y.rounded(.down))
        guard GridRules.inRoom(x: x, z: z) else { return }
        session.place(x: x, z: z, items: playItems, catalog: catalog)
    }

    @objc func panned(_ recognizer: UIPanGestureRecognizer) {
        guard let view, playSession?.item?.isTreat == false,
              recognizer.state == .began || recognizer.state == .changed || recognizer.state == .ended else { return }
        play(at: recognizer.location(in: view))
    }

    @objc func tapped(_ recognizer: UITapGestureRecognizer) {
        if playSession?.isActive == true, let view {
            play(at: recognizer.location(in: view))
            return
        }
        guard let view else { return }
        let point = recognizer.location(in: view)
        if let onTapCell {
            let touch = framing.touch(at: point, in: view.bounds.size)
            if let onTapWall, let wall = touch.wall {
                onTapWall(wall.side, Int(wall.offset.rounded(.down)))
                return
            }
            guard let floor = touch.floor else { return }
            let x = Int(floor.x.rounded(.down)), z = Int(floor.y.rounded(.down))
            if GridRules.inRoom(x: x, z: z) { onTapCell(x, z) }
            return
        }
        guard let onTapFurniture, let id = furnitureID(at: point) else { return }
        onTapFurniture(id)
    }

    /// The piece of furniture under a point of the view, if the first thing there is one.
    func furnitureID(at point: CGPoint) -> String? {
        guard let view else { return nil }
        // The fixed camera's own projection in the app; ARKit's perspective camera on a table,
        // where lengths are metres rather than cells.
        let ray = isTabletop ? view.ray(through: point) : framing.ray(through: point, in: view.bounds.size)
        guard let ray else { return nil }
        let hits = view.scene.raycast(origin: ray.origin, direction: ray.direction, length: isTabletop ? 20 : 80, query: .nearest)
        var entity: Entity? = hits.first?.entity
        while let current = entity {
            if current.name.hasPrefix("furniture:") { return String(current.name.dropFirst("furniture:".count)) }
            entity = current.parent
        }
        return nil
    }
}

extension Placement {
    init(_ item: PhotoFurniture) {
        self = item.placement
    }

}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

/// A single catalogue model on a plain backdrop, for the "choose a model" step.
struct ModelPreviewView: View {
    let model: CatalogModel
    let finish: Finish
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color(FurniturePortrait.backdrop)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable().scaledToFit()
            } else if failed {
                Label("款式预览暂不可用", systemImage: "photo")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView("正在绘制款式")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.title) 的预览")
        .accessibilityValue(image != nil ? "已显示" : (failed ? "暂不可用" : "正在绘制"))
        .accessibilityIdentifier(image != nil ? "model-preview-ready" : "model-preview-pending")
        .task(id: model.id + finish.rawValue) {
            failed = false
            image = nil
            do {
                let portrait = try await FurniturePortrait.image(model: model, finish: finish)
                try Task.checkCancellation()
                image = portrait
                return
            } catch {
                if Task.isCancelled { return }
            }
            // No Metal surface: the drawn portrait is better than none.
            let job = Task.detached(priority: .userInitiated) { [model, finish] in
                try FurniturePreviewRenderer.image(model: model, finish: finish)
            }
            do {
                let rendered = try await withTaskCancellationHandler {
                    try await job.value
                } onCancel: {
                    job.cancel()
                }
                try Task.checkCancellation()
                image = rendered
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}
