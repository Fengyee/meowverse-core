import MeowverseCore
import RealityKit
import UIKit

/// The style page's picture, taken by the room's renderer: the same mesh, materials, lights and
/// tone curve, so a style looks in the room as it did when it was chosen.
@MainActor
enum FurniturePortrait {
    static let backdrop = UIColor(red: 0.96, green: 0.93, blue: 0.87, alpha: 1)
    private static let size = CGSize(width: 340, height: 198)

    static func image(model: CatalogModel, finish: Finish) async throws -> CGImage {
        let placement = Placement(modelId: model.id, x: 0, z: 0, width: model.defaultWidth, depth: model.defaultSize[1],
                                  finish: finish, wall: model.mount == .wall ? .back : nil)
        let piece = try await ArtLibrary().furnitureEntity(model: model, placement: placement)
        try Task.checkCancellation()
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { throw RoomSnapshotError.unavailable }

        let scene = Entity()
        scene.addChild(piece)
        let bounds = piece.visualBounds(relativeTo: scene)
        guard !bounds.isEmpty else { throw RoomSnapshotError.unavailable }
        let sun = DirectionalLight(), fill = DirectionalLight()
        sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 40, depthBias: 3)
        sun.look(at: .zero, from: [3, 12, 7], relativeTo: nil)
        fill.look(at: [0, 1, 0], from: [12, 5, 1], relativeTo: nil)
        scene.addChild(sun)
        scene.addChild(fill)
        // Always by day: a style is chosen by its own colours.
        let phase = RoomLightPhase.daylight
        phase.apply(to: sun, fill: fill)

        let projection = RoomProjection.postcard(fitting: bounds, aspect: size.width / size.height, filling: 0.84)
        return try await PostcardSceneRenderer.capture(scene, projection: projection, size: size, scale: 2,
                                                       backdrop: backdrop, in: window) { view in
            RoomLook.current?.light(view, sun: sun, fill: fill, phase: phase)
        }
    }
}
