import Foundation

public struct FurnitureFloorShadowPlacement: Equatable, Sendable {
    public let modelID: String
    public let x: Float
    public let z: Float
    public let turn: Int
    public let scale: Float

    public init(modelID: String, x: Float, z: Float, turn: Int, scale: Float) {
        self.modelID = modelID
        self.x = x
        self.z = z
        self.turn = turn
        self.scale = scale
    }
}

public struct FurnitureFloorShadowAtlas: Sendable {
    public struct Stamp: Decodable, Sendable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    private let width: Int
    private let texelsPerCell: Float
    private let stamps: [String: Stamp]
    private let pixels: [UInt8]

    public init?(width: Int, height: Int, texelsPerCell: Int, stamps: [String: Stamp], pixels: [UInt8]) {
        guard width > 0, height > 0, width <= pixels.count / height, width * height == pixels.count,
              texelsPerCell > 0, stamps.values.allSatisfy({ stamp in
                  stamp.x >= 0 && stamp.y >= 0 && stamp.x < width && stamp.y < height
                  && stamp.width > 0 && stamp.height > 0
                  && stamp.width <= width - stamp.x && stamp.height <= height - stamp.y
              }) else { return nil }
        self.width = width
        self.texelsPerCell = Float(texelsPerCell)
        self.stamps = stamps
        self.pixels = pixels
    }

    public func contains(modelID: String) -> Bool { stamps[modelID] != nil }

    public func visibility(placements: [FurnitureFloorShadowPlacement], roomCells: Int, edges: Int) throws -> [UInt8] {
        var layer = [UInt8](repeating: 255, count: edges * edges)
        let cellStep = Float(roomCells) / Float(edges)
        let origin = (cellStep - Float(roomCells)) / 2
        for item in placements {
            try Task.checkCancellation()
            guard let stamp = stamps[item.modelID], item.scale > 0 else { continue }
            let turn = (item.turn % 4 + 4) % 4
            let scale = item.scale / texelsPerCell
            let halfX = Float(stamp.width) * scale / 2
            let halfZ = Float(stamp.height) * scale / 2
            let xRadius = turn.isMultiple(of: 2) ? halfX : halfZ
            let zRadius = turn.isMultiple(of: 2) ? halfZ : halfX
            let columns = region(center: item.x, radius: xRadius, origin: origin, step: cellStep, edge: edges)
            let rows = region(center: item.z, radius: zRadius, origin: origin, step: cellStep, edge: edges)
            for j in rows {
                let z = origin + Float(j) * cellStep - item.z
                for i in columns {
                    let x = origin + Float(i) * cellStep - item.x
                    let (localX, localZ) = inverseTurn(turn, x: x, z: z)
                    let u = localX / scale + Float(stamp.width - 1) / 2
                    let v = localZ / scale + Float(stamp.height - 1) / 2
                    let at = j * edges + i
                    let next = sample(stamp, u: u, v: v)
                    if next < 255 {
                        layer[at] = UInt8(max(82, (Int(layer[at]) * next + 127) / 255))
                    }
                }
            }
        }
        return layer
    }

    private func region(center: Float, radius: Float, origin: Float, step: Float, edge: Int) -> Range<Int> {
        let start = max(0, Int(ceil((center - radius - origin) / step)))
        let end = min(edge, Int(floor((center + radius - origin) / step)) + 1)
        return start..<max(start, end)
    }

    private func inverseTurn(_ turn: Int, x: Float, z: Float) -> (Float, Float) {
        switch turn {
        case 1: (-z, x)
        case 2: (-x, -z)
        case 3: (z, -x)
        default: (x, z)
        }
    }

    private func sample(_ stamp: Stamp, u: Float, v: Float) -> Int {
        guard u >= 0, v >= 0, u <= Float(stamp.width - 1), v <= Float(stamp.height - 1) else { return 255 }
        let x0 = Int(u), y0 = Int(v)
        let x1 = min(x0 + 1, stamp.width - 1), y1 = min(y0 + 1, stamp.height - 1)
        let mixX = u - Float(x0), mixY = v - Float(y0)
        let top = (stamp.y + y0) * width + stamp.x
        let bottom = (stamp.y + y1) * width + stamp.x
        let a = Float(pixels[top + x0]) * (1 - mixX) + Float(pixels[top + x1]) * mixX
        let b = Float(pixels[bottom + x0]) * (1 - mixX) + Float(pixels[bottom + x1]) * mixX
        return Int((a * (1 - mixY) + b * mixY).rounded())
    }
}
