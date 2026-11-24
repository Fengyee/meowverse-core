import Foundation

/// The room's look: floor, walls and the room page's background (round 7's ten themes, and round 13's
/// three that go with the furniture sets). Free for everyone. The raw values are stored, so they never change.
///
/// Before round 7 the look was one of five seasons under `room.appearance.season`. That key keeps
/// its meaning: it is read whenever no theme is saved yet, and a theme that upgrades a season
/// writes the season back, so an older build still shows the nearest look.
public enum RoomTheme: String, CaseIterable, Sendable {
    case creamOak = "cream-oak"
    case mintConservatory = "mint-conservatory"
    case seaSalt = "sea-salt"
    case peachBakery = "peach-bakery"
    case sakuraLetters = "sakura-letters"
    case mushroomRain = "mushroom-rain"
    case honeyPicnic = "honey-picnic"
    case lilacMoon = "lilac-moon"
    case winterKnit = "winter-knit"
    case forestLibrary = "forest-library"
    case gildedPalace = "gilded-palace"
    case jiangnanStudy = "jiangnan-study"
    case sakuraTatami = "sakura-tatami"

    public static let defaultsKey = "room.appearance.theme"
    public static let legacySeasonKey = "room.appearance.season"

    /// The season this theme upgrades. Summer and 海盐蓝岸 were nearly the same striped room, so
    /// they merge; autumn goes to the nearest warm room, 桃桃烘焙.
    public var legacySeason: String? {
        switch self {
        case .creamOak: "classic"
        case .mintConservatory: "spring"
        case .seaSalt: "summer"
        case .peachBakery: "autumn"
        case .winterKnit: "winter"
        case .sakuraLetters, .mushroomRain, .honeyPicnic, .lilacMoon, .forestLibrary,
             .gildedPalace, .jiangnanStudy, .sakuraTatami: nil
        }
    }

    /// A saved theme wins; then the old season; then the default. Unknown values (from a newer
    /// build) are skipped rather than reset, so the other key still counts.
    public static func resolve(theme: String?, legacySeason: String?) -> RoomTheme {
        if let theme, let known = RoomTheme(rawValue: theme) { return known }
        if let legacySeason, let upgrade = allCases.first(where: { $0.legacySeason == legacySeason }) { return upgrade }
        return .creamOak
    }

    public static func stored(in defaults: UserDefaults) -> RoomTheme {
        resolve(theme: defaults.string(forKey: defaultsKey), legacySeason: defaults.string(forKey: legacySeasonKey))
    }

    public func store(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
        if let legacySeason { defaults.set(legacySeason, forKey: Self.legacySeasonKey) }
    }
}
