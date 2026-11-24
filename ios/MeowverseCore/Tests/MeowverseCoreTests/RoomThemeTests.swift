import Foundation
import Testing
@testable import MeowverseCore

/// Round 7: ten room themes replace the five seasons; round 13 adds one for each furniture set. The old `room.appearance.season` value keeps
/// its meaning and is read when no theme has been saved yet, so an existing room keeps its look.
struct RoomThemeTests {
    @Test func themesInTrayOrderWithStableIds() {
        #expect(RoomTheme.allCases.map(\.rawValue) == [
            "cream-oak", "mint-conservatory", "sea-salt", "peach-bakery", "sakura-letters",
            "mushroom-rain", "honey-picnic", "lilac-moon", "winter-knit", "forest-library",
            "gilded-palace", "jiangnan-study", "sakura-tatami",
        ])
        #expect(RoomTheme.defaultsKey == "room.appearance.theme")
        #expect(RoomTheme.legacySeasonKey == "room.appearance.season")
    }

    @Test func savedSeasonsMoveToTheirUpgrade() {
        let expected: [String: RoomTheme] = [
            "classic": .creamOak, "spring": .mintConservatory, "summer": .seaSalt,
            "autumn": .peachBakery, "winter": .winterKnit,
        ]
        for (season, theme) in expected {
            #expect(RoomTheme.resolve(theme: nil, legacySeason: season) == theme)
            #expect(RoomTheme.resolve(theme: "", legacySeason: season) == theme)
        }
    }

    @Test func aSavedThemeWinsOverTheOldSeason() {
        #expect(RoomTheme.resolve(theme: "lilac-moon", legacySeason: "winter") == .lilacMoon)
        #expect(RoomTheme.resolve(theme: "cream-oak", legacySeason: "spring") == .creamOak)
    }

    @Test func unknownOrMissingValuesFallBackWithoutLosingTheOtherKey() {
        #expect(RoomTheme.resolve(theme: nil, legacySeason: nil) == .creamOak)
        #expect(RoomTheme.resolve(theme: "", legacySeason: "") == .creamOak)
        // A theme id from a newer build this one does not know: the season still counts.
        #expect(RoomTheme.resolve(theme: "starry-attic", legacySeason: "summer") == .seaSalt)
        #expect(RoomTheme.resolve(theme: "starry-attic", legacySeason: "monsoon") == .creamOak)
    }

    /// Saving also writes the season an older build understands, when there is one, so going back
    /// to an older build shows the nearest look instead of the default.
    @Test func upgradesWriteTheirSeasonBack() {
        #expect(RoomTheme.creamOak.legacySeason == "classic")
        #expect(RoomTheme.mintConservatory.legacySeason == "spring")
        #expect(RoomTheme.seaSalt.legacySeason == "summer")
        #expect(RoomTheme.peachBakery.legacySeason == "autumn")
        #expect(RoomTheme.winterKnit.legacySeason == "winter")
        for theme in [RoomTheme.sakuraLetters, .mushroomRain, .honeyPicnic, .lilacMoon, .forestLibrary] {
            #expect(theme.legacySeason == nil)
        }
        for theme in RoomTheme.allCases {
            if let season = theme.legacySeason {
                #expect(RoomTheme.resolve(theme: nil, legacySeason: season) == theme)
            }
        }
    }

    /// The furniture sets' rooms came after the seasons: saving one leaves the season an older
    /// build reads as it was, so that build shows the last look it knew.
    @Test(arguments: ["gilded-palace", "jiangnan-study", "sakura-tatami"])
    func aSetsThemeIsStoredWithoutTouchingTheSeason(id: String) throws {
        let theme = try #require(RoomTheme(rawValue: id))
        let name = "RoomThemeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("winter", forKey: RoomTheme.legacySeasonKey)
        theme.store(in: defaults)
        #expect(RoomTheme.stored(in: defaults) == theme)
        #expect(defaults.string(forKey: RoomTheme.legacySeasonKey) == "winter")
    }

    @Test func storedValuesRoundTripThroughUserDefaults() throws {
        let name = "RoomThemeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("autumn", forKey: RoomTheme.legacySeasonKey)
        #expect(RoomTheme.stored(in: defaults) == .peachBakery)
        RoomTheme.honeyPicnic.store(in: defaults)
        #expect(RoomTheme.stored(in: defaults) == .honeyPicnic)
        #expect(defaults.string(forKey: RoomTheme.legacySeasonKey) == "autumn")
        RoomTheme.winterKnit.store(in: defaults)
        #expect(defaults.string(forKey: RoomTheme.legacySeasonKey) == "winter")
        #expect(defaults.string(forKey: RoomTheme.defaultsKey) == "winter-knit")
    }
}
