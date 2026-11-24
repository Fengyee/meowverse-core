import MeowverseCore
import simd
import SwiftUI
import UIKit

extension View {
    /// Lets the tour ask where the cat and the floor are on screen. Sits beside `FurnitureHotspots`
    /// in the room, with the projection the scene is actually drawn with.
    @ViewBuilder
    func tourSceneAnchors(_ framing: RoomProjection, pieces: [PhotoFurniture], catalog: FurnitureCatalog?) -> some View {
        if TourLaunch.isEnabled {
            overlay {
                RoomTourSceneAnchors(framing: framing, pieces: pieces, catalog: catalog)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        } else {
            self
        }
    }
}

private struct RoomTourSceneAnchors: UIViewRepresentable {
    @Environment(\.roomLightPhase) private var phase
    let framing: RoomProjection
    let pieces: [PhotoFurniture]
    let catalog: FurnitureCatalog?

    func makeUIView(context: Context) -> TourSceneAnchorView { TourSceneAnchorView() }

    func updateUIView(_ view: TourSceneAnchorView, context: Context) {
        view.framing = framing
        view.pieces = pieces
        view.catalog = catalog
        view.night = phase == .night
    }
}

/// What in the room a step points at.
enum TourSceneTarget: Equatable {
    /// The lead cat, the window following her.
    case cat
    /// The room's floor: the cat's step when she does not move (Reduce Motion) or is not there yet.
    case floor
    /// A piece in the room, by `instanceId` (chapters 6 and 7).
    case furniture(String)
    /// The storage chest drawn in the room (7.3).
    case storage
    /// The whole room, floor and walls: 7.2's stage window (VISUAL §17.6).
    case stage
}

/// Fills the room view. The room's camera is fixed and orthographic, so a world point becomes a
/// screen point with `RoomProjection`'s own arithmetic: no call into RealityKit.
final class TourSceneAnchorView: UIView {
    private(set) static weak var current: TourSceneAnchorView?
    var framing = RoomProjection()
    /// The room's own light: a night room is under the dim mask whatever the colour scheme.
    var night = false
    /// The pieces drawn in the room, for `.furniture`.
    var pieces: [PhotoFurniture] = []
    var catalog: FurnitureCatalog?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { Self.current = self }
    }

    /// The target's box in this view's coordinates. nil for the cat while she is not drawn.
    func rect(for target: TourSceneTarget) -> CGRect? {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        switch target {
        case .cat:
            guard let place = TourCatLocator.shared.place else { return nil }
            // About 1.1 cells tall sitting and 1.5 long loafing, 0.56 wide (BellaActor.scale),
            // along her own heading: the body runs along the root's z.
            var rect = CGRect.null
            for dx: Float in [-0.3, 0.3] {
                for dz: Float in [-0.75, 0.75] {
                    let offset = place.orientation.act(SIMD3<Float>(dx, 0, dz))
                    for y: Float in [0, 1.1] {
                        let point = framing.point(place.position + offset + [0, y, 0], in: size)
                        rect = rect.union(CGRect(origin: point, size: .zero))
                    }
                }
            }
            return rect
        case .floor:
            let half = Float(GridRules.size) / 2
            var rect = CGRect.null
            for x in [-half, half] {
                for z in [-half, half] {
                    rect = rect.union(CGRect(origin: framing.point([x, 0, z], in: size), size: .zero))
                }
            }
            return rect.intersection(bounds)
        case .furniture(let id):
            guard let piece = pieces.first(where: { $0.instanceId == id }) else { return nil }
            let rect = framing.screenRect(for: piece, catalog: catalog, in: size).intersection(bounds)
            return rect.isEmpty ? nil : rect
        case .storage:
            let rect = framing.storageChestRect(in: size).intersection(bounds)
            return rect.isEmpty ? nil : rect
        case .stage:
            // The floor's slab, its underside too (VISUAL §17.10.2 item 3), and the tops of the two
            // walls, as the room is drawn (`RoomShellAppearance`: the plinth runs from y = 0 down
            // `plinthDepth`, a little wider than the floor; walls 3.55 tall round y = 1.6).
            let half = Float(GridRules.size) / 2, slab = RoomShellSize.plinthSpan / 2
            var rect = CGRect.null
            func add(_ point: SIMD3<Float>) {
                rect = rect.union(CGRect(origin: framing.point(point, in: size), size: .zero))
            }
            for x in [-slab, slab] {
                for z in [-slab, slab] {
                    add([x, 0, z])
                    add([x, -RoomShellSize.plinthDepth, z])
                }
            }
            for x in [-half, half] {
                for z in [-half, half] where x == -half || z == -half {
                    add([x, 3.375, z])
                }
            }
            return rect.intersection(bounds)
        }
    }
}

/// The lead cat's place in the room, written by the scene controller every rendered frame.
/// A plain stored property: nothing observes it.
final class TourCatLocator {
    struct Place {
        var position: SIMD3<Float>
        var orientation: simd_quatf
    }

    static let shared = TourCatLocator()
    private(set) var place: Place?

    func report(_ cat: BellaActor, live: Bool) {
        guard TourLaunch.isEnabled else { return }
        guard live, cat.isLoaded, cat.root.isEnabled else {
            place = nil
            return
        }
        place = Place(position: cat.root.position, orientation: cat.root.orientation)
    }
}
