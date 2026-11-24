import Foundation
import Testing
@testable import MeowverseCore

private func day(_ y: Int, _ m: Int, _ d: Int) -> IconDay { IconDay(year: y, month: m, day: d) }
private func theme(_ y: Int, _ m: Int, _ d: Int, _ hemisphere: Hemisphere = .northern) -> AppIconTheme {
    AppIconCalendar.theme(on: day(y, m, d), hemisphere: hemisphere)
}

@Suite struct AppIconCalendarTests {
    // MARK: Lunar calendar

    /// Spring Festival dates from the Hong Kong Observatory's conversion tables. 2023 has a
    /// leap 2nd month, 2025 a leap 6th, 2028 a leap 5th and 2033 a leap 11th (so the 2034 new
    /// year comes late), which a fixed "lunar year = 354 days" rule gets wrong.
    @Test(arguments: [
        (2020, day(2020, 1, 25)), (2021, day(2021, 2, 12)), (2023, day(2023, 1, 22)),
        (2024, day(2024, 2, 10)), (2025, day(2025, 1, 29)), (2026, day(2026, 2, 17)),
        (2027, day(2027, 2, 6)), (2028, day(2028, 1, 26)), (2029, day(2029, 2, 13)),
        (2033, day(2033, 1, 31)), (2034, day(2034, 2, 19)),
    ])
    func lunarNewYearMatchesTheAlmanac(year: Int, expected: IconDay) {
        #expect(AppIconCalendar.lunarNewYear(in: year) == expected)
    }

    @Test func lanternFestivalIsTheFifteenthOfTheFirstMonth() {
        #expect(AppIconCalendar.lanternFestival(in: 2027) == day(2027, 2, 20))
        #expect(AppIconCalendar.lanternFestival(in: 2026) == day(2026, 3, 3))
        // After the leap 11th month of 2033.
        #expect(AppIconCalendar.lanternFestival(in: 2034) == day(2034, 3, 5))
    }

    @Test func thanksgivingIsTheFourthThursdayOfNovember() {
        #expect(AppIconCalendar.thanksgiving(in: 2026) == day(2026, 11, 26))
        #expect(AppIconCalendar.thanksgiving(in: 2027) == day(2027, 11, 25))
        #expect(AppIconCalendar.thanksgiving(in: 2029) == day(2029, 11, 22))   // earliest possible
        #expect(AppIconCalendar.thanksgiving(in: 2024) == day(2024, 11, 28))   // latest possible
    }

    // MARK: Seasons

    @Test func northernSeasonsFollowTheMonth() {
        #expect(theme(2025, 3, 1) == .springSakura)   // 2026-03-01 is in the lantern week
        #expect(theme(2026, 5, 31) == .springSakura)
        #expect(theme(2026, 6, 1) == .summerSea)
        #expect(theme(2026, 8, 31) == .summerSea)
        #expect(theme(2026, 9, 1) == .autumnMaple)
        #expect(theme(2026, 11, 18) == .autumnMaple)
        #expect(theme(2026, 11, 12) == .autumnMaple)
        #expect(theme(2027, 2, 28) == .winterKnit)
        #expect(theme(2027, 1, 8) == .winterKnit)
    }

    @Test func southernSeasonsAreSixMonthsApart() {
        #expect(theme(2025, 3, 1, .southern) == .autumnMaple)
        #expect(theme(2026, 7, 15, .southern) == .winterKnit)
        #expect(theme(2026, 10, 1, .southern) == .springSakura)
        #expect(theme(2027, 1, 15, .southern) == .summerSea)
        // No harvest festival in the southern spring: the season shows instead.
        #expect(theme(2026, 11, 26, .southern) == .springSakura)
        // The other holidays are the same everywhere.
        #expect(theme(2026, 12, 25, .southern) == .christmasHolly)
        #expect(theme(2027, 2, 6, .southern) == .lunarNewYear)
    }

    @Test func regionPicksTheHemisphere() {
        #expect(Hemisphere(regionCode: "AU") == .southern)
        #expect(Hemisphere(regionCode: "nz") == .southern)
        #expect(Hemisphere(regionCode: "AR") == .southern)
        #expect(Hemisphere(regionCode: "ZA") == .southern)
        #expect(Hemisphere(regionCode: "CN") == .northern)
        #expect(Hemisphere(regionCode: "US") == .northern)
        #expect(Hemisphere(regionCode: nil) == .northern)
        #expect(Hemisphere(regionCode: "") == .northern)
    }

    // MARK: Holiday windows (icon_usage_notes.md for 2026–27)

    @Test func thanksgivingRunsUntilChristmas() {
        #expect(theme(2026, 11, 18) == .autumnMaple)
        #expect(theme(2026, 11, 19) == .thanksgivingHarvest)
        #expect(theme(2026, 11, 26) == .thanksgivingHarvest)
        #expect(theme(2026, 11, 29) == .thanksgivingHarvest)
        // The notes end the window on the Sunday (11-29). Going back to autumn for one or two
        // days before Christmas would cost an extra system alert, so it runs to 11-30.
        #expect(theme(2026, 11, 30) == .thanksgivingHarvest)
        #expect(theme(2027, 11, 29) == .thanksgivingHarvest)   // Thanksgiving 11-25
        #expect(theme(2027, 12, 1) == .christmasHolly)
        // The earliest Thanksgiving (11-22) starts on 11-15.
        #expect(theme(2029, 11, 14) == .autumnMaple)
        #expect(theme(2029, 11, 15) == .thanksgivingHarvest)
    }

    @Test func holidaysEndBackOnTheSeason() {
        #expect(theme(2027, 1, 8) == .winterKnit)       // after New Year
        #expect(theme(2027, 2, 23) == .winterKnit)      // after the Lantern Festival
        #expect(theme(2026, 3, 6) == .springSakura)     // after a lantern week in March
        #expect(theme(2026, 12, 1, .southern) == .christmasHolly)
        #expect(theme(2027, 1, 8, .southern) == .summerSea)
    }

    @Test func christmasThenNewYearAcrossTheYearBoundary() {
        #expect(theme(2026, 12, 1) == .christmasHolly)
        #expect(theme(2026, 12, 26) == .christmasHolly)
        #expect(theme(2026, 12, 27) == .newYearStarlight)
        #expect(theme(2026, 12, 31) == .newYearStarlight)
        #expect(theme(2027, 1, 1) == .newYearStarlight)
        #expect(theme(2027, 1, 7) == .newYearStarlight)
        #expect(theme(2027, 1, 8) == .winterKnit)
    }

    @Test func lateThanksgivingHandsOverToChristmas() {
        // 2024-11-28: the window would run to 12-01, the first day of Christmas.
        #expect(theme(2024, 11, 30) == .thanksgivingHarvest)
        #expect(theme(2024, 12, 1) == .christmasHolly)
    }

    @Test func springFestivalValentineAndLanternIn2027() {
        #expect(theme(2027, 1, 22) == .winterKnit)
        #expect(theme(2027, 1, 23) == .lunarNewYear)
        #expect(theme(2027, 2, 6) == .lunarNewYear)
        #expect(theme(2027, 2, 9) == .lunarNewYear)
        #expect(theme(2027, 2, 10) == .valentineRose)
        #expect(theme(2027, 2, 14) == .valentineRose)
        #expect(theme(2027, 2, 15) == .valentineRose)
        #expect(theme(2027, 2, 16) == .lanternGlow)
        #expect(theme(2027, 2, 20) == .lanternGlow)
        #expect(theme(2027, 2, 22) == .lanternGlow)
        #expect(theme(2027, 2, 23) == .winterKnit)
        #expect(theme(2027, 3, 1) == .springSakura)
    }

    @Test func springFestivalDaysBeatValentine() {
        // 2029: new year's day is 02-13, so 02-14 is the second day of the festival.
        #expect(theme(2029, 2, 12) == .lunarNewYear)
        #expect(theme(2029, 2, 14) == .lunarNewYear)
        #expect(theme(2029, 2, 15) == .lunarNewYear)
        // Before both: the nearer festival shows, so the icon does not flip back and forth.
        #expect(theme(2029, 2, 10) == .lunarNewYear)
        // 2026: Valentine's Day comes first (02-14), then the festival (02-17).
        #expect(theme(2026, 2, 10) == .valentineRose)
        #expect(theme(2026, 2, 15) == .lunarNewYear)
        // 2024: festival 02-09–02-12, then Valentine, then the festival until the lantern week.
        #expect(theme(2024, 2, 10) == .lunarNewYear)
        #expect(theme(2024, 2, 13) == .valentineRose)
        #expect(theme(2024, 2, 16) == .lunarNewYear)
        #expect(theme(2024, 2, 20) == .lanternGlow)
    }

    @Test func lanternFestivalInMarchAndOnValentinesDay() {
        // 2026: new year 02-17, lantern 03-03; the lantern week runs into spring.
        #expect(theme(2026, 2, 14) == .valentineRose)
        #expect(theme(2026, 2, 17) == .lunarNewYear)
        #expect(theme(2026, 3, 3) == .lanternGlow)
        #expect(theme(2026, 3, 5) == .lanternGlow)
        #expect(theme(2026, 3, 6) == .springSakura)
        // 2033: the lantern festival falls on 02-14 and wins the whole overlap.
        #expect(theme(2033, 2, 10) == .lanternGlow)
        #expect(theme(2033, 2, 14) == .lanternGlow)
        #expect(theme(2033, 2, 16) == .lanternGlow)
        #expect(theme(2033, 2, 17) == .winterKnit)
    }

    @Test func earlySpringFestivalAfterNewYear() {
        // 2023-01-22: the festival window opens 01-08, the day after the new-year window ends.
        #expect(theme(2023, 1, 7) == .newYearStarlight)
        #expect(theme(2023, 1, 8) == .lunarNewYear)
    }

    @Test func everyDayOfSeveralYearsHasATheme() {
        // The daily icons are never chosen by date; every date falls in a season or a holiday.
        var seen = Set<AppIconTheme>()
        for year in 2024...2035 {
            for hemisphere in [Hemisphere.northern, .southern] {
                var d = day(year, 1, 1)
                while d.year == year {
                    seen.insert(AppIconCalendar.theme(on: d, hemisphere: hemisphere))
                    d = d.adding(days: 1)
                }
            }
        }
        #expect(seen == Set(AppIconTheme.allCases).subtracting([.creamClassic, .midnightSage]))
    }

    // MARK: Local day

    @Test func theDayIsTheLocalCalendarDay() throws {
        // 2026-12-26 23:30 in New York is already 12-27 in UTC and in Shanghai.
        let ny = try #require(TimeZone(identifier: "America/New_York"))
        let sh = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let instant = Date(timeIntervalSince1970: 1_798_345_800)   // 2026-12-27T04:30:00Z
        #expect(IconDay(instant, in: ny) == day(2026, 12, 26))
        #expect(IconDay(instant, in: sh) == day(2026, 12, 27))
        #expect(AppIconCalendar.theme(at: instant, in: ny, hemisphere: .northern) == .christmasHolly)
        #expect(AppIconCalendar.theme(at: instant, in: sh, hemisphere: .northern) == .newYearStarlight)
    }

    @Test func iconNamesMatchTheAssetCatalog() throws {
        #expect(AppIconTheme.christmasHolly.iconName == "AppIcon-christmas-holly")
        let names = Set(AppIconTheme.allCases.map(\.iconName))
        #expect(names.count == 12)
        // Every theme has an icon set with the home-screen sizes for iPhone (60 pt @2x/@3x) and
        // iPad (76 pt and 83.5 pt @2x), each file present, and the app target builds each set
        // as an alternate icon. (Explicit sizes, not one 1024 px image: actool would store a
        // 1024 px copy per idiom, about 5.5 MB per icon.)
        struct Slot: Decodable, Hashable { let idiom: String; let size: String; let scale: String; let filename: String? }
        struct Set_: Decodable { let images: [Slot] }
        let ios = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../..").standardized
        let catalog = ios.appending(path: "Meowverse/Assets.xcassets")
        for name in names {
            let folder = catalog.appending(path: "\(name).appiconset")
            let slots = try JSONDecoder().decode(Set_.self, from: Data(contentsOf: folder.appending(path: "Contents.json"))).images
            let filled = Set(slots.filter { $0.filename != nil }.map { "\($0.idiom) \($0.size) \($0.scale)" })
            #expect(filled.isSuperset(of: ["iphone 60x60 2x", "iphone 60x60 3x", "ipad 76x76 2x", "ipad 83.5x83.5 2x"]), "\(name)")
            #expect(!slots.contains { $0.size == "1024x1024" }, "\(name)")
            for file in slots.compactMap(\.filename) {
                #expect(FileManager.default.fileExists(atPath: folder.appending(path: file).path), "\(name)/\(file)")
            }
        }
        let project = try String(contentsOf: ios.appending(path: "Meowverse.xcodeproj/project.pbxproj"), encoding: .utf8)
        let settings = project.components(separatedBy: "\n").filter { $0.contains("ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES") }
        #expect(settings.count == 2)   // Debug and Release
        for line in settings {
            let value = try #require(line.split(separator: "\"").dropFirst().first)
            #expect(Set(value.split(separator: " ").map(String.init)) == names)
        }
    }
}

@Suite struct AppIconSyncTests {
    @Test func targetIsTheThemeOrThePrimaryIcon() {
        #expect(AppIconSync.target(followsCalendar: true, theme: .summerSea) == "AppIcon-summer-sea")
        #expect(AppIconSync.target(followsCalendar: false, theme: .summerSea) == nil)
    }

    @Test func switchesOnlyWhenTheIconDiffers() {
        #expect(AppIconSync.shouldAttempt(target: "AppIcon-summer-sea", current: "AppIcon-summer-sea", lastAttempt: nil) == false)
        #expect(AppIconSync.shouldAttempt(target: nil, current: nil, lastAttempt: nil) == false)
        #expect(AppIconSync.shouldAttempt(target: "AppIcon-summer-sea", current: nil, lastAttempt: nil))
        #expect(AppIconSync.shouldAttempt(target: nil, current: "AppIcon-summer-sea", lastAttempt: nil))
    }

    @Test func eachTargetIsTriedOnce() {
        // A failed (or refused) attempt is not repeated on every return to the foreground…
        #expect(AppIconSync.shouldAttempt(target: "AppIcon-summer-sea", current: nil,
                                          lastAttempt: .icon("AppIcon-summer-sea")) == false)
        #expect(AppIconSync.shouldAttempt(target: nil, current: "AppIcon-summer-sea", lastAttempt: .primary) == false)
        // …but a new target (the next season) is tried.
        #expect(AppIconSync.shouldAttempt(target: "AppIcon-autumn-maple", current: nil,
                                          lastAttempt: .icon("AppIcon-summer-sea")))
        #expect(AppIconSync.shouldAttempt(target: nil, current: "AppIcon-summer-sea",
                                          lastAttempt: .icon("AppIcon-summer-sea")))
    }

    @Test func attemptRecordRoundTripsThroughDefaults() {
        #expect(AppIconSync.Attempt(stored: AppIconSync.Attempt.primary.stored) == .primary)
        #expect(AppIconSync.Attempt(stored: AppIconSync.Attempt.icon("AppIcon-lantern-glow").stored) == .icon("AppIcon-lantern-glow"))
        #expect(AppIconSync.Attempt(stored: nil) == nil)
        #expect(AppIconSync.Attempt(target: nil) == .primary)
    }
}
