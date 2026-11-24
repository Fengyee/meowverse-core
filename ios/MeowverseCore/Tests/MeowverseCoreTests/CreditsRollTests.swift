import Foundation
import Testing
@testable import MeowverseCore

/// 关于与隐私: who is thanked, and the third-party list against the files that really ship.
@Suite struct CreditsRollTests {
    @Test func noNamesMeansNothingToShow() {
        let roll = CreditsRoll(sponsors: [], thanks: [.init(role: .testing, names: [])])
        #expect(roll.listedSponsors.isEmpty)
        #expect(roll.listedThanks.isEmpty)
        #expect(roll.isEmpty)
    }

    @Test func blankNamesCountAsNone() {
        let roll = CreditsRoll(sponsors: [], thanks: [.init(role: .testing, names: ["", "  ", "\n"])])
        #expect(roll.listedThanks.isEmpty)
        #expect(roll.isEmpty)
        // A sponsor is a person either way: a blank name is the nickname, not nobody.
        #expect(Sponsor(name: .init(zh: " ", en: "\n"), supports: []).credit(chinese: true, catName: cats) == .someonesHuman)
    }

    @Test func namesKeepTheirOrderWithoutSpacesOrRepeats() {
        let roll = CreditsRoll(sponsors: [], thanks: [.init(role: .testing, names: ["  Mochi ", "小橘", "Mochi", "", "Bean"])])
        #expect(roll.listedThanks.first?.names == ["Mochi", "小橘", "Bean"])
    }

    // MARK: Sponsors

    private let cats: (String) -> String? = { ["black": "Luna", "bella": "Bella"][$0] }

    @Test func eachPersonIsListedOnceWithEverythingTheySupported() {
        let roll = CreditsRoll(sponsors: [
            Sponsor(name: .init(zh: "小橘"), supports: [.cat(id: "black")]),
            Sponsor(name: nil, supports: []),
            Sponsor(name: .init(zh: " 小橘 "), supports: [.feature(.severalCats), .cat(id: "black")]),
        ], thanks: [])
        #expect(roll.listedSponsors == [
            Sponsor(name: .init(zh: "小橘"), supports: [.cat(id: "black"), .feature(.severalCats)]),
            Sponsor(name: nil, supports: []),
        ])
        #expect(!roll.isEmpty)
    }

    @Test func peopleWithoutANameStaySeparateUnlessTheNicknameIsTheSame() {
        let roll = CreditsRoll(sponsors: [
            Sponsor(name: nil, supports: [.cat(id: "black")]),
            Sponsor(name: nil, supports: [.cat(id: "bella")]),
            Sponsor(name: nil, supports: [.cat(id: "black"), .feature(.severalRooms)]),
            Sponsor(name: nil, supports: []),
            Sponsor(name: nil, supports: []),
        ], thanks: [])
        #expect(roll.listedSponsors.count == 4)
        #expect(roll.listedSponsors.first?.supports == [.cat(id: "black"), .feature(.severalRooms)])
    }

    @Test func aSponsorWithoutANameIsTheirCatsHuman() {
        for chinese in [true, false] {
            #expect(Sponsor(name: nil, supports: [.feature(.severalCats), .cat(id: "black")]).credit(chinese: chinese, catName: cats) == .catsHuman("Luna"))
            #expect(Sponsor(name: nil, supports: [.feature(.severalCats)]).credit(chinese: chinese, catName: cats) == .someonesHuman)
            #expect(Sponsor(name: nil, supports: [.cat(id: "gone")]).credit(chinese: chinese, catName: cats) == .someonesHuman)
        }
    }

    @Test func aNameReplacesTheNicknameInBothLanguages() {
        let both = Sponsor(name: .init(zh: "小橘", en: "Tangerine"), supports: [.cat(id: "black")])
        #expect(both.credit(chinese: true, catName: cats) == .named("小橘"))
        #expect(both.credit(chinese: false, catName: cats) == .named("Tangerine"))
        // Either language may be left out: the one that was given is their name.
        #expect(Sponsor(name: .init(zh: "小橘"), supports: []).credit(chinese: false, catName: cats) == .named("小橘"))
        #expect(Sponsor(name: .init(en: "Tangerine"), supports: []).credit(chinese: true, catName: cats) == .named("Tangerine"))
    }

    @Test func aTargetHasThePeopleWhoSupportedIt() {
        let orange = Sponsor(name: .init(zh: "小橘"), supports: [.feature(.severalCats)])
        let luna = Sponsor(name: nil, supports: [.cat(id: "black")])
        let roll = CreditsRoll(sponsors: [orange, luna], thanks: [])
        #expect(roll.sponsors(for: .feature(.severalCats)) == [orange])
        #expect(roll.sponsors(for: .cat(id: "black")) == [luna])
        #expect(roll.sponsors(for: .feature(.severalRooms)).isEmpty)
    }

    /// A feature names everyone, nicknames included. A cat's card already thanks "her human", so a
    /// banner comes only with a public name.
    @Test func theBannerDoesNotRepeatACatsBioLine() {
        let luna = Sponsor(name: nil, supports: [.cat(id: "black"), .feature(.severalRooms)])
        let only = CreditsRoll(sponsors: [luna], thanks: [])
        #expect(only.bannerSponsors(for: .cat(id: "black")).isEmpty)
        #expect(only.bannerSponsors(for: .feature(.severalRooms)) == [luna])

        let named = Sponsor(name: .init(en: "Pudding"), supports: [.cat(id: "black")])
        let both = CreditsRoll(sponsors: [luna, named], thanks: [])
        #expect(both.bannerSponsors(for: .cat(id: "black")) == [luna, named])
        #expect(both.bannerSponsors(for: .feature(.severalCats)).isEmpty)
    }

    @Test func theSourceLinkIsThePublicRepository() {
        #expect(PublicPage.sourceRepository.absoluteString == "https://github.com/Fengyee/meowverse-core")
    }

    @Test func aGroupWithoutNamesIsLeftOut() {
        let roll = CreditsRoll(sponsors: [], thanks: [
            .init(role: .idea, names: [" Omucat "]),
            .init(role: .testing, names: []),
        ])
        #expect(roll.listedThanks == [.init(role: .idea, names: ["Omucat"])])
        #expect(!roll.isEmpty)
    }

    // MARK: The privacy policy

    @Test func thePrivacyPolicyOpensAtTheSectionInTheInterfaceLanguage() {
        #expect(PublicPage.privacyPolicy(chinese: true).absoluteString == "https://fengyee.github.io/meowverse/privacy.html#zh")
        #expect(PublicPage.privacyPolicy(chinese: false).absoluteString == "https://fengyee.github.io/meowverse/privacy.html#en")
    }

    /// The anchors the app links to are in the page's source: an edit that renames one turns this red.
    @Test func thePrivacyPolicyHasBothSections() throws {
        let page = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("public/privacy.html")
        let html = try String(contentsOf: page, encoding: .utf8)
        for chinese in [true, false] {
            let anchor = try #require(PublicPage.privacyPolicy(chinese: chinese).fragment)
            #expect(html.contains("<section id=\"\(anchor)\""), "public/privacy.html has no #\(anchor)")
        }
    }

    // MARK: Third-party notices against the bundle

    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Meowverse/Resources")

    private static func attribution() throws -> String {
        try String(contentsOf: resources.appendingPathComponent("Art/ATTRIBUTION.txt"), encoding: .utf8)
    }

    @Test func everyNoticeIsBackedByAShippedFile() throws {
        let attribution = try Self.attribution()
        #expect(ThirdPartyNotice.shipped.map(\.id) == ThirdPartyNotice.ID.allCases)
        for notice in ThirdPartyNotice.shipped {
            #expect(notice.licenseFile != nil || notice.attributionMark != nil, "\(notice.id) is backed by nothing")
            if let mark = notice.attributionMark {
                #expect(attribution.contains(mark), "ATTRIBUTION.txt no longer credits \(notice.id)")
            }
            if let file = notice.licenseFile {
                let found = ["Models", "Fonts"].contains {
                    FileManager.default.fileExists(atPath: Self.resources.appendingPathComponent("\($0)/\(file).txt").path)
                }
                #expect(found, "\(file).txt is not in the bundle")
            }
        }
    }

    /// A new third-party source in ATTRIBUTION.txt needs its own row under 开源与素材.
    @Test func everySourceSiteInTheAttributionHasARow() throws {
        let attribution = try Self.attribution()
        let licenceSites: Set<String> = ["creativecommons.org", "openfontlicense.org"]
        // Kenney's archive is on OpenGameArt; the font's release is in google/fonts on GitHub.
        let alsoCovered: [String: ThirdPartyNotice.ID] = ["opengameart.org": .kenneyFurniture]
        let rowSites = Set(ThirdPartyNotice.shipped.compactMap { URL(string: $0.source)?.host() })
        let regex = try NSRegularExpression(pattern: #"https?://([A-Za-z0-9.-]+)"#)
        let text = attribution as NSString
        let sites = Set(regex.matches(in: attribution, range: NSRange(location: 0, length: text.length))
            .map { text.substring(with: $0.range(at: 1)).lowercased() })
        #expect(!sites.isEmpty)
        for site in sites where !licenceSites.contains(site) && alsoCovered[site] == nil {
            #expect(rowSites.contains(site), "\(site) is credited in ATTRIBUTION.txt but has no row")
        }
    }
}
