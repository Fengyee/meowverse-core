import Foundation

// The character cards of the built-in cats, looked up by cat pack id. App-side data on purpose: the
// cat pack format (docs/CAT_PACK.md) stays as it is, and an imported `.meowcat` has no card.
//
// The names shown for the built-in models live here, in both languages. The manifests' `name`
// (assets/cats/<id>/cat.json) is the same English name and scripts/ios/cat-credits.test.mjs holds
// them together: a rename changes both, then a rebake and `mv snapshot`.
//
// Foundation only, so `MeowverseCoreTests` compiles this same file (`AppShared/CatProfiles.swift`
// is a link to it). Text is keyed in Chinese in the `CatProfiles` table; English is in
// CatProfiles.xcstrings.

nonisolated struct CatProfile: Sendable, Equatable {
    enum Gender: Sendable, Equatable { case girl, boy }

    let id: String
    let chineseName: String
    let englishName: String
    let gender: Gender?
    /// Breed or coat, in the interface language.
    let breed: String
    /// Two or three short tags: temperament or a favourite thing.
    let traits: [String]
    /// The card's 小趣事 line. nil until the owner writes it, and the card then has no such row.
    /// Set it per cat in `CatProfiles.all`; never invent one or ship a stand-in for it.
    let funFact: String?

    /// The name in the interface language: Chinese in a Chinese interface, English in any other.
    func name(chinese: Bool) -> String { chinese ? chineseName : englishName }

    /// The name in the other language, shown smaller under the first one; nil when it is the same.
    func otherName(chinese: Bool) -> String? {
        let other = chinese ? englishName : chineseName
        return other == name(chinese: chinese) ? nil : other
    }

    var genderText: String? {
        switch gender {
        case .girl: String(localized: "女孩", table: "CatProfiles")
        case .boy: String(localized: "男孩", table: "CatProfiles")
        case nil: nil
        }
    }

    /// One line for every cat (owner, 2026-11-20; 喵空间 since 2026-11-22): 「露娜的铲屎官赞助了我们的喵空间！」,
    /// “Luna’s human sponsored our Meowverse!”.
    func bio(chinese: Bool) -> String {
        String(localized: "\(name(chinese: chinese))的铲屎官赞助了我们的喵空间！", table: "CatProfiles")
    }

    /// The same card with another 小趣事 (the DEBUG gallery's sample).
    func withFunFact(_ funFact: String) -> CatProfile {
        CatProfile(id: id, chineseName: chineseName, englishName: englishName, gender: gender,
                   breed: breed, traits: traits, funFact: funFact)
    }
}

nonisolated enum CatProfiles {
    static func profile(for id: String) -> CatProfile? {
        all.first { $0.id == id }
    }

    /// In the order of `CatPackLibrary.builtInIDs`. Names: the owner, 2026-11-20 (Zhumi has no
    /// English name of its own and keeps "Zhumi"); genders of Mocha, Snowy and Pinky: the lead.
    static var all: [CatProfile] {
        [
            CatProfile(
                id: "bella", chineseName: "贝咪", englishName: "Bella", gender: .girl, // not-localized: a name, shown as is (Chinese interface) or as its English name
                breed: String(localized: "棕色虎斑加白", table: "CatProfiles"),
                traits: [String(localized: "爱晒太阳", table: "CatProfiles"),
                         String(localized: "罐头雷达", table: "CatProfiles"),
                         String(localized: "亲人", table: "CatProfiles")],
                funFact: nil),
            CatProfile(
                id: "airou", chineseName: "艾露", englishName: "Airou", gender: .girl, // not-localized: a name, shown as is (Chinese interface) or as its English name
                breed: String(localized: "三花", table: "CatProfiles"),
                traits: [String(localized: "好奇宝宝", table: "CatProfiles"),
                         String(localized: "纸箱检查员", table: "CatProfiles")],
                funFact: nil),
            CatProfile(
                id: "zhumi", chineseName: "猪咪", englishName: "Zhumi", gender: .boy, // not-localized: a name, shown as is (Chinese interface) or as its English name
                breed: String(localized: "黑白奶牛猫", table: "CatProfiles"),
                traits: [String(localized: "干饭第一", table: "CatProfiles"),
                         String(localized: "呼噜大王", table: "CatProfiles"),
                         String(localized: "好脾气", table: "CatProfiles")],
                funFact: nil),
            CatProfile(
                id: "siamese", chineseName: "摩卡", englishName: "Mocha", gender: .boy, // not-localized: a name, shown as is (Chinese interface) or as its English name
                breed: String(localized: "暹罗（重点色）", table: "CatProfiles"),
                traits: [String(localized: "话痨", table: "CatProfiles"),
                         String(localized: "小跟班", table: "CatProfiles")],
                funFact: nil),
            CatProfile(
                id: "ragdoll", chineseName: "团团", englishName: "Mochi", gender: .girl, // not-localized: a name, shown as is (Chinese interface) or as its English name
                breed: String(localized: "布偶（长毛）", table: "CatProfiles"),
                traits: [String(localized: "软绵绵", table: "CatProfiles"),
                         String(localized: "爱被摸摸", table: "CatProfiles"),
                         String(localized: "安静", table: "CatProfiles")],
                funFact: nil),
            CatProfile(
                id: "black", chineseName: "露娜", englishName: "Luna", gender: .girl, // not-localized: a name, shown as is (Chinese interface) or as its English name
                breed: String(localized: "黑猫", table: "CatProfiles"),
                traits: [String(localized: "夜猫子", table: "CatProfiles"),
                         String(localized: "追光斑", table: "CatProfiles")],
                funFact: nil),
            CatProfile(
                id: "white", chineseName: "雪球", englishName: "Snowy", gender: .girl, // not-localized: a name, shown as is (Chinese interface) or as its English name
                breed: String(localized: "白猫", table: "CatProfiles"),
                traits: [String(localized: "爱干净", table: "CatProfiles"),
                         String(localized: "有点害羞", table: "CatProfiles"),
                         String(localized: "温柔", table: "CatProfiles")],
                funFact: nil),
            CatProfile(
                id: "sphynx", chineseName: "粉粉", englishName: "Pinky", gender: .boy, // not-localized: a name, shown as is (Chinese interface) or as its English name
                breed: String(localized: "无毛猫", table: "CatProfiles"),
                traits: [String(localized: "小暖炉", table: "CatProfiles"),
                         String(localized: "钻被窝", table: "CatProfiles")],
                funFact: nil),
        ]
    }
}
