import Foundation

/// The first six categories also occur in imported web libraries.
public enum FurnitureCategory: String, Codable, CaseIterable, Sendable {
    case chair, stool, bench, table, bed, sofa
    case scratcher, catTree, platform, hideout, toy
    case litterBox, windowPerch, water
    /// Hangs on a wall and holds photos in which no furniture can be made out.
    case photoBoard
    /// Household furniture (schema 12). Picked from the catalogue only: photo recognition never
    /// names them (`isRecognisedFromPhotos`). Several are decorative (`CatalogModel.isDecorative`).
    case bookcase, sideboard, mediaConsole, writingDesk, vanity
    case coatRack, floorLamp, roomDivider, plantStand, fireplace

    /// Whether the photo review offers this category: recognition can name it, and the manual
    /// list shows it. The household categories are catalogue-only for now.
    public var isRecognisedFromPhotos: Bool {
        switch self {
        case .chair, .stool, .bench, .table, .bed, .sofa, .scratcher, .catTree, .platform, .hideout, .toy,
             .litterBox, .windowPerch, .water, .photoBoard: true
        case .bookcase, .sideboard, .mediaConsole, .writingDesk, .vanity,
             .coatRack, .floorLamp, .roomDivider, .plantStand, .fireplace: false
        }
    }
}

/// The colour a placed piece is drawn in. The first four mirror `Finish` in
/// contracts/grid-world.ts (web, frozen); apricot, blush and lavender are palette presets of the
/// v2 furniture library, native only, and need schema 7 (art/furniture/TECH_SPEC.md §8).
/// Case order is the picker order: original, then the presets in presets.json order.
public enum Finish: String, Codable, CaseIterable, Sendable {
    case original, cream, sage, blue, apricot, blush, lavender

    /// The finishes schema 1...6 files and web backups can hold.
    public static let legacy: [Finish] = [.original, .cream, .sage, .blue]
}

/// One entry of `contracts/semantic-furniture.catalog.json` `.models[]`.
/// Unknown keys (e.g. `sourceFiles`) are ignored.
public struct CatalogModel: Identifiable, Codable, Sendable, Equatable {
    public struct Bounds: Codable, Sendable, Equatable {
        public let min: [Double]
        public let max: [Double]
    }

    public struct Seat: Codable, Sendable, Equatable {
        public let position: [Double]
        public let facing: Double
    }

    public struct Site: Identifiable, Codable, Sendable, Equatable {
        public let id: String
        public let label: String
        public let position: [Double]
        /// Heading about +Y, in the model's coordinate system.
        public let facing: Double
        public let actions: [CatAction]
        /// Intermediate landing points, ordered from the approach cell to the site.
        public let via: [[Double]]
        /// The exporter's pose hint (`paw-up`, `paw-flat`, `curl`...); nil for older catalogs.
        public var poseHint: String? = nil

        /// A scratch on a low horizontal board: the flat forepaw strokes, not the raised ones.
        public var scratchesFlat: Bool { poseHint == "paw-flat" }
        /// A toy lying on the floor (round 7 soft furnishings): she bats it with the ground paw
        /// (`bat_ground`, as the play props), not the raised one that reaches 0.70 up.
        public var batsAtGround: Bool { poseHint == "bat-ground" }
    }

    /// Where a piece of this model goes: on floor cells, or on a wall where it uses none.
    public enum Mount: String, Codable, Sendable {
        case floor, wall
    }

    public let id: String
    public let label: String
    public let category: FurnitureCategory
    /// `[width, depth]` in cells, before rotation.
    public let defaultSize: [Int]
    /// Allowed `[width, depth]` pairs, before rotation.
    public let sizes: [[Int]]
    public let path: String
    public let sha256: String
    public let bytes: Int
    public let bounds: Bounds
    public let triangles: Int
    public let orientationY: Double
    public let seat: Seat
    public let sites: [Site]?
    /// nil in catalog files written before wall pieces existed; read it through `mount`.
    let storedMount: Mount?

    public var mount: Mount { storedMount ?? .floor }

    private enum CodingKeys: String, CodingKey {
        case id, label, category, defaultSize, sizes, path, sha256, bytes, bounds, triangles, orientationY, seat, sites
        case storedMount = "mount"
    }

    /// A floor piece with an explicitly empty site list (TECH_SPEC §4): the cat has nothing to do
    /// there and walks round it like any obstacle. A missing list is a legacy model, not this.
    public var isDecorative: Bool { mount == .floor && sites?.isEmpty == true }

    /// Nothing for a wall piece or a decorative one: Bella cannot get onto it.
    public var interactionSites: [Site] {
        if mount == .wall || isDecorative { return [] }
        return sites ?? [Site(id: "seat", label: "座面", position: seat.position, facing: seat.facing,
                       actions: [CatRoutine.action(on: category)], via: [])]
    }

    public var defaultWidth: Int { defaultSize.first ?? 1 }
    public var defaultDepth: Int { defaultSize.count > 1 ? defaultSize[1] : 1 }

    public func allows(width: Int, depth: Int) -> Bool {
        sizes.contains { $0.count == 2 && $0[0] == width && $0[1] == depth }
    }
}

public enum CatalogError: Error, Equatable, Sendable {
    case missingResource
    case invalid(String)
}

/// A retired model id that still resolves (art/furniture/TECH_SPEC.md §6): rooms, backups and
/// web imports keep the ids they were saved with.
public struct CatalogAlias: Codable, Sendable, Equatable {
    public let from: String
    public let to: String
    /// The legacy model's category; the target must have the same one, so photo links that
    /// name a recognised object kind stay valid.
    public let category: FurnitureCategory
}

public struct FurnitureCatalog: Sendable, Equatable {
    private struct File: Decodable {
        let models: [CatalogModel]
        let aliases: [CatalogAlias]?
    }

    public let models: [CatalogModel]
    /// Legacy id -> current id, consulted only for ids no model has.
    public let aliases: [String: String]

    /// Decodes the whole catalog JSON file.
    public init(data: Data) throws {
        try self.init(files: [data])
    }

    private init(files: [Data], builtIn: [CatalogModel] = []) throws {
        let decoded = try files.map { try JSONDecoder().decode(File.self, from: $0) }
        let models = decoded.flatMap(\.models) + builtIn
        var seen = Set<String>()
        for model in models {
            guard !model.id.isEmpty, seen.insert(model.id).inserted else { throw CatalogError.invalid("duplicateId") }
            guard model.defaultSize.count == 2, model.sizes.contains(model.defaultSize),
                  model.sizes.allSatisfy({ $0.count == 2 && $0.allSatisfy { (1...GridRules.size).contains($0) } })
            else { throw CatalogError.invalid("badSize") }
            guard model.bounds.min.count == 3, model.bounds.max.count == 3,
                  zip(model.bounds.min, model.bounds.max).allSatisfy({ $0.isFinite && $1.isFinite && $0 < $1 }),
                  model.orientationY.isFinite, model.seat.position.count == 3,
                  model.seat.position.allSatisfy(\.isFinite), model.seat.facing.isFinite
            else { throw CatalogError.invalid("badGeometry") }
            guard model.mount == .floor || model.sizes.allSatisfy({ $0[1] == 1 }) else { throw CatalogError.invalid("badWallSize") }
            try Self.validateSites(model)
        }
        self.models = models
        aliases = try Self.validateAliases(decoded.flatMap { $0.aliases ?? [] }, models: models)
    }

    /// Every alias names an existing target of the same category, once. An alias wins over a
    /// legacy model of the same id (TECH_SPEC §6).
    private static func validateAliases(_ aliases: [CatalogAlias], models: [CatalogModel]) throws -> [String: String] {
        let byId = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var table: [String: String] = [:]
        for alias in aliases {
            guard !alias.from.isEmpty, alias.from != alias.to, table[alias.from] == nil,
                  let target = byId[alias.to], target.category == alias.category
            else { throw CatalogError.invalid("badAlias") }
            table[alias.from] = alias.to
        }
        return table
    }

    private static func validateSites(_ model: CatalogModel) throws {
        guard let sites = model.sites, !model.isDecorative else { return }
        guard !sites.isEmpty, Set(sites.map(\.id)).count == sites.count,
              let fit = GridRules.fit(model, width: model.defaultWidth, depth: model.defaultDepth) else {
            throw CatalogError.invalid("badSites")
        }
        func validPoint(_ point: [Double]) -> Bool {
            guard point.count == 3, point.allSatisfy(\.isFinite) else { return false }
            let x = (point[0] + fit.offset[0]) * fit.scale, z = (point[2] + fit.offset[2]) * fit.scale
            let sine = sin(model.orientationY), cosine = cos(model.orientationY)
            let dx = cosine * x + sine * z, dz = cosine * z - sine * x
            let tolerance = 0.02
            let halfDepth = Double(model.defaultDepth) / 2 + tolerance
            return abs(dx) <= Double(model.defaultWidth) / 2 + tolerance && (-halfDepth...halfDepth + 1).contains(dz)
                && point[1] >= model.bounds.min[1] - tolerance && point[1] <= model.bounds.max[1] + tolerance
        }
        for site in sites {
            guard !site.id.isEmpty, !site.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !site.actions.isEmpty, Set(site.actions).count == site.actions.count,
                  site.facing.isFinite, validPoint(site.position), site.via.allSatisfy(validPoint)
            else { throw CatalogError.invalid("badSite") }
        }
    }

    /// The catalog files the app ships, in order. The v2 library (`mv-furniture.catalog`) carries
    /// the legacy-id aliases.
    public static let bundledFiles = ["semantic-furniture.catalog", "pet-furniture.catalog", "mv-furniture.catalog"]

    public static func bundled() throws -> FurnitureCatalog {
        let data = try bundledFiles.map { name in
            guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
                throw CatalogError.missingResource
            }
            return try Data(contentsOf: url)
        }
        return try FurnitureCatalog(files: data, builtIn: builtInModels)
    }

    /// Models the app draws itself, so they have no baked asset and are not in the catalog
    /// files (which are generated from, and checked against, the baked art). `bundled()` adds
    /// them. `path`, `sha256`, `bytes` and `triangles` are empty; `bounds` is the board's
    /// nominal shape at the default size.
    public static let builtInModels: [CatalogModel] = [
        CatalogModel(id: "wall-photo-board", label: "照片板", category: .photoBoard, defaultSize: [2, 1],
                     sizes: [[2, 1], [3, 1]], path: "", sha256: "", bytes: 0,
                     bounds: .init(min: [-1, 0, -0.05], max: [1, 1, 0.05]), triangles: 0, orientationY: 0,
                     seat: .init(position: [0, 0, 0], facing: 0), sites: nil, storedMount: .wall),
    ]

    /// The model with this id. A legacy id with an alias is the model it now stands for, even
    /// while the legacy catalog still ships a model of that id: saved rooms draw and edit the
    /// replacement (TECH_SPEC §6).
    public func model(id: String) -> CatalogModel? {
        if let target = aliases[id], let replacement = models.first(where: { $0.id == target }) { return replacement }
        return models.first { $0.id == id }
    }

    /// The id `model(id:)` resolves to; nil when nothing does.
    public func canonicalId(_ id: String) -> String? {
        model(id: id)?.id
    }

    /// True for a legacy id that an alias resolves to another model.
    public func isLegacyAlias(_ id: String) -> Bool {
        aliases[id] != nil
    }

    /// The models a picker offers for new placements: aliased legacy models are left out.
    public func models(in category: FurnitureCategory) -> [CatalogModel] {
        models.filter { $0.category == category && aliases[$0.id] == nil }
    }
}
