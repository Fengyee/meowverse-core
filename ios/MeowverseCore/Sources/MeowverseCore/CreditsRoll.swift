import Foundation

/// A feature somebody's support made possible. The app gives each its words and decides where
/// it opens.
public enum SponsoredFeature: String, CaseIterable, Sendable {
    case severalRooms, severalCats
}

/// What a sponsor supported.
public enum SponsorTarget: Hashable, Sendable {
    case feature(SponsoredFeature)
    /// A cat pack's id.
    case cat(id: String)
}

/// One person (or household) who is thanked.
public struct Sponsor: Equatable, Sendable {
    /// Their public name as they want it written. Either language may be left out: the one given
    /// is then shown in both.
    public struct Name: Equatable, Sendable {
        public let zh: String?
        public let en: String?

        public init(zh: String? = nil, en: String? = nil) {
            self.zh = Self.trimmed(zh)
            self.en = Self.trimmed(en)
        }

        private static func trimmed(_ text: String?) -> String? {
            let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }

        func shown(chinese: Bool) -> String? { chinese ? zh ?? en : en ?? zh }
    }

    /// How to write a sponsor: by name, else by a nickname that the app puts into words.
    public enum Credit: Equatable, Sendable {
        case named(String)
        /// 「<猫名>的铲屎官」, with the cat's name in the interface language.
        case catsHuman(String)
        /// 「一位铲屎官」
        case someonesHuman
    }

    /// nil until they gave a name and agreed to its being public.
    public var name: Name?
    public var supports: [SponsorTarget]

    public init(name: Name?, supports: [SponsorTarget]) {
        self.name = name
        self.supports = supports
    }

    public var hasPublicName: Bool { name?.shown(chinese: true) != nil }

    public func credit(chinese: Bool, catName: (String) -> String?) -> Credit {
        if let name = name?.shown(chinese: chinese) { return .named(name) }
        if let cat = supports.lazy.compactMap(\.catID).compactMap(catName).first { return .catsHuman(cat) }
        return .someonesHuman
    }

    /// The same key means the same person: the same name, or the same cat's human. People with
    /// neither can't be told apart, so they have no key.
    var key: String? {
        if let name = name?.shown(chinese: true) { return "name:" + name }
        return supports.lazy.compactMap(\.catID).first.map { "cat:" + $0 }
    }
}

private extension SponsorTarget {
    var catID: String? {
        if case .cat(let id) = self { id } else { nil }
    }
}

/// Who 关于与隐私 thanks, and the third-party work that ships in the app.
///
/// Thanks only: no amounts, tiers, links or calls to give (App Review 3.1.1; money for the app
/// goes through In-App Purchase or not at all). The names themselves live in the app
/// (`Credits.shipped`); this type holds the rules for showing them, so they can be tested here.
public struct CreditsRoll: Equatable, Sendable {
    /// What a person helped with. The app gives each role its own words.
    public enum Role: String, CaseIterable, Sendable {
        /// The idea of the app.
        case idea
        /// Trying test builds and reporting what they found.
        case testing
    }

    public struct Group: Equatable, Sendable {
        public var role: Role
        public var names: [String]

        public init(role: Role, names: [String]) {
            self.role = role
            self.names = names
        }
    }

    /// People whose sponsorship paid for the app being on, and staying on, the App Store
    /// (the Apple Developer Program fee).
    public var sponsors: [Sponsor]
    public var thanks: [Group]

    public init(sponsors: [Sponsor], thanks: [Group]) {
        self.sponsors = sponsors
        self.thanks = thanks
    }

    /// Each person once, in their first place, with everything they supported. None means no
    /// 赞助人 group at all.
    public var listedSponsors: [Sponsor] {
        var people: [Sponsor] = []
        for sponsor in sponsors {
            if let key = sponsor.key, let index = people.firstIndex(where: { $0.key == key }) {
                for target in sponsor.supports where !people[index].supports.contains(target) {
                    people[index].supports.append(target)
                }
            } else {
                people.append(sponsor)
            }
        }
        return people
    }

    /// Everyone who supported `target`.
    public func sponsors(for target: SponsorTarget) -> [Sponsor] {
        listedSponsors.filter { $0.supports.contains(target) }
    }

    /// Whom the banner at `target` names. A cat's card already thanks "her human" in its bio, so
    /// nicknames alone get no banner there.
    public func bannerSponsors(for target: SponsorTarget) -> [Sponsor] {
        let people = sponsors(for: target)
        if case .cat = target, !people.contains(where: \.hasPublicName) { return [] }
        return people
    }

    /// The groups that have someone in them, with the names to show. An empty group is left out,
    /// header and all, with nothing in its place.
    public var listedThanks: [Group] {
        thanks.compactMap { group in
            let names = Self.listed(group.names)
            return names.isEmpty ? nil : Group(role: group.role, names: names)
        }
    }

    /// Nobody to thank.
    public var isEmpty: Bool { listedSponsors.isEmpty && listedThanks.isEmpty }

    /// Names as typed, without surrounding white space, without blank entries and without the
    /// same name twice (first place kept).
    private static func listed(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// One piece of third-party work bundled in the app, as listed under 开源与素材.
///
/// Facts only, not translated: the app adds what it is used for in the reader's language. The
/// full text that the licence asks to ship is in the bundle (`licenseFile`), or the credit is in
/// `Resources/Art/ATTRIBUTION.txt` (`attributionMark` must appear there; `CreditsRollTests`
/// checks both against the real files, and that every source site in ATTRIBUTION.txt has a row).
public struct ThirdPartyNotice: Identifiable, Equatable, Sendable {
    public enum ID: String, CaseIterable, Sendable {
        case dinov2, hunyuan3D, zcoolKuaiLe, kenneyFurniture, threeDAssets, fripouille
    }

    public let id: ID
    /// The work's own name.
    public let name: String
    /// Who holds the copyright or made it, as the licence or the source names them.
    public let author: String
    /// Short licence name for the row.
    public let license: String
    public let licenseURL: String
    public let source: String
    /// Base name of a `.txt` in the app bundle holding the licence text, when one ships.
    public let licenseFile: String?
    /// Text in ATTRIBUTION.txt that carries this credit, when it is there (the model's credit is in its licence file).
    public let attributionMark: String?

    public static let shipped: [ThirdPartyNotice] = [
        ThirdPartyNotice(
            id: .dinov2, name: "DINOv2 (ViT-B/14, with registers)", author: "Meta Platforms, Inc. and affiliates",
            license: "Apache License 2.0", licenseURL: "https://www.apache.org/licenses/LICENSE-2.0",
            source: "https://huggingface.co/facebook/dinov2-with-registers-base",
            licenseFile: "DINOv2-LICENSE", attributionMark: nil),
        // Seven built-in cats are reconstructed with Hunyuan3D-2mv, from the 2.0 repository
        // (docs/CAT_RECON.md). 2.1 was tried and not adopted. Bella came first and her version was
        // not recorded. The licence's notice is in ATTRIBUTION.txt.
        ThirdPartyNotice(
            id: .hunyuan3D, name: "Tencent Hunyuan3D", author: "Tencent",
            license: "Tencent Hunyuan 3D Community License", licenseURL: "https://github.com/Tencent-Hunyuan/Hunyuan3D-2/blob/main/LICENSE",
            source: "https://github.com/Tencent-Hunyuan/Hunyuan3D-2",
            licenseFile: nil, attributionMark: "Tencent Hunyuan 3D 2.0 is licensed under the Tencent Hunyuan 3D 2.0 Community License Agreement"),
        ThirdPartyNotice(
            id: .zcoolKuaiLe, name: "ZCOOL KuaiLe", author: "The ZCOOL KuaiLe Project Authors (Liu Bingke, Yang Kang, Wu Shaojie)",
            license: "SIL Open Font License 1.1", licenseURL: "https://openfontlicense.org",
            source: "https://github.com/googlefonts/zcool-kuaile",
            licenseFile: "ZCOOLKuaiLe-OFL", attributionMark: "ZCOOL KuaiLe Regular, by Liu Bingke, Yang Kang and Wu Shaojie."),
        ThirdPartyNotice(
            id: .kenneyFurniture, name: "Furniture Kit", author: "Kenney (www.kenney.nl)",
            license: "CC0 1.0", licenseURL: "http://creativecommons.org/publicdomain/zero/1.0/",
            source: "https://kenney.nl/assets/furniture-kit",
            licenseFile: nil, attributionMark: "\"Furniture Kit (2018 author release)\" by Kenney"),
        ThirdPartyNotice(
            id: .threeDAssets, name: "Companion Animals & Pet Home", author: "3D Assets",
            license: "CC0 1.0", licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/",
            source: "https://3dassets.dev/packs/companion-animals-and-pet-home",
            licenseFile: nil, attributionMark: "Source license for the 3D Assets models"),
        ThirdPartyNotice(
            id: .fripouille, name: "3d modelling my cat: Fripouille", author: "guillaume bolis",
            license: "CC BY 4.0", licenseURL: "https://creativecommons.org/licenses/by/4.0/",
            source: "https://sketchfab.com/3d-models/3d-modelling-my-cat-fripouille-0ab14bf98e754f8d90fe1bf1c84ca66c",
            licenseFile: nil, attributionMark: "“3d modelling my cat: Fripouille” by guillaume bolis (2020)"),
    ]
}
