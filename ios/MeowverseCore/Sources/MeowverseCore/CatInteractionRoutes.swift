import Foundation

/// A site's contact and intermediate landings in room space.
struct CatLanding {
    let point: GridPoint
    let via: [GridPoint]
    let yaw: Double
    let legacy: Bool

    init?(item: PhotoFurniture, model: CatalogModel, site: CatalogModel.Site) {
        guard let fit = GridRules.fit(model, width: item.width, depth: item.depth) else { return nil }
        let turn = Double(item.turn) * .pi / 2
        let heading = model.orientationY + turn
        let size = GridRules.rotatedSize(width: item.width, depth: item.depth, turn: item.turn)
        let centreX = Double(item.x) + Double(size.width - GridRules.size) / 2
        let centreZ = Double(item.z) + Double(size.depth - GridRules.size) / 2
        let sine = sin(heading), cosine = cos(heading)
        func world(_ v: [Double]) -> GridPoint {
            let x = (v[0] + fit.offset[0]) * fit.scale, z = (v[2] + fit.offset[2]) * fit.scale
            return GridPoint(x: centreX + cosine * x + sine * z, y: (v[1] + fit.offset[1]) * fit.scale,
                             z: centreZ + cosine * z - sine * x)
        }
        point = world(site.position)
        via = site.via.map(world)
        legacy = model.sites == nil
        yaw = legacy ? turn : heading + site.facing
    }

    func sharedPath(to destination: CatLanding) -> [GridPoint]? {
        let source = via + [point], target = destination.via + [destination.point]
        let shared = zip(source, target).prefix { $0 == $1 }.count
        guard shared > 0 else { return nil }
        return Array(source.dropFirst(shared - 1).reversed()) + target.dropFirst(shared)
    }

    /// A segment's projection may cross a neighbour even if both endpoints are clear, e.g. a
    /// diagonal from an approach cell into a wide platform. Check each grid interval traversed.
    func isAccessible(from approach: GridCell, avoiding obstacles: Set<GridCell>) -> Bool {
        let stops = [CatRoutine.cellPoint(approach)] + via + [point]
        let half = Double(GridRules.size) / 2
        func clear(x: Double, z: Double) -> Bool {
            let cell = GridCell(x: Int(floor(x + half)), z: Int(floor(z + half)))
            return GridRules.inRoom(x: cell.x, z: cell.z) && !obstacles.contains(cell)
        }
        for (a, b) in zip(stops, stops.dropFirst()) {
            guard clear(x: b.x, z: b.z) else { return false }
            let dx = b.x - a.x, dz = b.z - a.z
            var crossings = [0.0, 1.0]
            for i in 0...GridRules.size {
                let line = Double(i) - half
                for (origin, delta) in [(a.x, dx), (a.z, dz)] where abs(delta) > 1e-9 {
                    let t = (line - origin) / delta
                    if t > 0 && t < 1 { crossings.append(t) }
                }
            }
            crossings.sort()
            for (lo, hi) in zip(crossings, crossings.dropFirst()) where hi > lo {
                let t = (lo + hi) / 2
                if !clear(x: a.x + dx * t, z: a.z + dz * t) { return false }
            }
        }
        return true
    }
}

extension CatRoutine {
    public static func seatPoint(of item: PhotoFurniture, catalog: FurnitureCatalog, siteId: String? = nil) -> GridPoint? {
        guard let model = catalog.model(id: item.modelId),
              let site = model.interactionSites.first(where: { siteId == nil || $0.id == siteId })
        else { return nil }
        return CatLanding(item: item, model: model, site: site)?.point
    }
}

struct CatVisitPlanner {
    let rest: CatRest
    let catalog: FurnitureCatalog
    let blocked: Set<GridCell>
    /// Free cells she can walk to from where she is now.
    private let reachable: Set<GridCell>
    private let origin: CatLanding?

    init(items: [PhotoFurniture], rest: CatRest, catalog: FurnitureCatalog) {
        self.rest = rest
        self.catalog = catalog
        blocked = GridRules.blockedCells(items)
        reachable = GridRules.reachableCells(blocked: blocked, from: rest.cell)
        if let owner = items.first(where: { $0.instanceId == rest.itemId }), let model = catalog.model(id: owner.modelId),
           let site = model.interactionSites.first(where: { $0.id == (rest.siteId ?? "seat") }) {
            origin = CatLanding(item: owner, model: model, site: site)
        } else {
            origin = nil
        }
    }

    func visit(item: PhotoFurniture, sample: Double, request: (id: String, action: CatAction)? = nil) -> CatTrip? {
        // The front cell when she can walk to it, as on the web; otherwise a free cell at the side.
        guard let model = catalog.model(id: item.modelId),
              let approach = CatRoutine.accessCell(of: item, reachable: reachable),
              let path = CatRoutine.route(blocked: blocked, from: rest.cell, to: approach) else { return nil }
        let options = model.interactionSites.flatMap { site in site.actions.map { (site, $0) } }
        guard !options.isEmpty else { return nil }
        let first = rest.lastActivityByItem[item.instanceId].map { ($0 + 1) % options.count }
            ?? min(Int(Double(options.count) * sample), options.count - 1)
        let obstacles = blocked.subtracting(GridRules.blockedCells([item]))
        for offset in options.indices {
            let index = (first + offset) % options.count
            let (site, action) = options[index]
            if let request, request.id != site.id || request.action != action { continue }
            guard let landing = CatLanding(item: item, model: model, site: site),
                  landing.legacy || landing.isAccessible(from: approach, avoiding: obstacles) else { continue }
            var end = rest
            end.cell = approach
            end.action = action
            end.itemId = item.instanceId
            end.lastItemId = item.instanceId
            end.siteId = site.id
            if options.count > 1 { end.lastActivityByItem[item.instanceId] = index }
            return trip(end: end, path: path, destination: landing, rotation: landing.yaw)
        }
        return nil
    }

    func trip(end: CatRest, path: [GridCell], destination: CatLanding?, rotation: Double) -> CatTrip {
        let shared = end.itemId != nil && end.itemId == rest.itemId ? destination.flatMap { origin?.sharedPath(to: $0) } : nil
        return CatTrip(end: end, leaving: origin?.point, path: path, seat: destination?.point, rotation: rotation,
                exitVia: origin.map { Array($0.via.reversed()) } ?? [], entryVia: destination?.via ?? [],
                sharedAccessPath: shared, legacyExit: origin?.legacy == true, legacyEntry: destination?.legacy == true)
    }
}
