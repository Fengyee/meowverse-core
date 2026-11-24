import MeowverseCore
import SwiftUI

/// Draw over the preview so the last access cell stays visible even under an invalid draft.
struct PlacementAccessGuides: View {
    let cells: Set<GridCell>
    var projection = RoomProjection()

    static let halfSide: Float = 0.43
    static let legend = LocalizedStringKey("虚线格是房间入口和猫咪上下家具的位置")

    var body: some View {
        Canvas { context, size in
            let h = Self.halfSide
            let corners: [SIMD3<Float>] = [[-h, 0, -h], [h, 0, -h], [h, 0, h], [-h, 0, h]]
            for cell in cells {
                let origin = CatRoutine.cellPoint(cell)
                let center = SIMD3<Float>(Float(origin.x), 0.025, Float(origin.z))
                var path = Path()
                path.addLines(corners.map { projection.point(center + $0, in: size) })
                path.closeSubpath()
                context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 2.8)
                context.stroke(path, with: .color(Color(red: 0.18, green: 0.35, blue: 0.31)),
                               style: StrokeStyle(lineWidth: 1.8, lineJoin: .round, dash: [3.4, 2.2]))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
