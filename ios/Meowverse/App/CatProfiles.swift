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
    /// Two or three short tags (2–5 characters in Chinese): temperament or a favourite thing.
    let traits: [String]
    /// The card's 小趣事 line, one or two sentences; with nil the card has no such row. Where each
    /// cat's tags and line come from is written at `CatProfiles.all`.
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
}

nonisolated enum CatProfiles {
    static func profile(for id: String) -> CatProfile? {
        all.first { $0.id == id }
    }

    /// In the order of `CatPackLibrary.builtInIDs`. Names: the owner, 2026-11-20 (Zhumi has no
    /// English name of its own and keeps "Zhumi"); genders of Mocha, Snowy and Pinky: the lead.
    ///
    /// Tags and 小趣事 (2026-11-24): for Bella, Mochi, Airou and Zhumi the owner passed on what
    /// their sponsors told about their own cats, kept in its meaning and only cut into short tags.
    /// For Mocha, Luna, Snowy and Pinky the owner asked the team to write them: gentle, believable,
    /// true to the breed and the tags they already had, and no injury or illness. The final text
    /// and its sources are in docs/release/1.0/cat-credits.md; change a real cat's line only with
    /// the owner.
    ///
    /// Zhaocai (2026-11-23): the name is the owner's; gender and breed word are the lead's. Tags and
    /// 小趣事 (2026-11-24) from what the owner told about him, cut into short tags as for the others.
    static var all: [CatProfile] {
        [
            CatProfile(
                id: "bella", chineseName: "贝咪", englishName: "Bella", gender: .girl, // not-localized: a name, shown as is (Chinese interface) or as its English name
                breed: String(localized: "棕色虎斑加白", table: "CatProfiles"),
                traits: [String(localized: "爱拍屁屁", table: "CatProfiles"),
                         String(localized: "小馋猫", table: "CatProfiles"),
                         String(localized: "被宠坏了", table: "CatProfiles")],
                funFact: String(localized: "铲屎官躺在床上看电视，她就趴到胸口上要摸摸、要拍屁屁；不拍，就用湿漉漉的小鼻子拱铲屎官的手。", table: "CatProfiles")),
            CatProfile(
                id: "airou", chineseName: "艾露", englishName: "Airou", gender: .girl, // not-localized: a name, shown as is (Chinese interface) or as its English name
                breed: String(localized: "三花", table: "CatProfiles"),
                traits: [String(localized: "谨慎又好奇", table: "CatProfiles"),
                         String(localized: "爱看松鼠", table: "CatProfiles"),
                         String(localized: "躲抽屉", table: "CatProfiles")],
                funFact: String(localized: "新买的自动猫砂盆转起来哗啦啦地响，艾露听了很生气，跑过去把它暴打了一顿。", table: "CatProfiles")),
            CatProfile(
                id: "zhumi", chineseName: "猪咪", englishName: "Zhumi", gender: .boy, // not-localized: a name, shown as is (Chinese interface) or as its English name
                breed: String(localized: "黑白奶牛猫", table: "CatProfiles"),
                traits: [String(localized: "淘气包", table: "CatProfiles"),
                         String(localized: "爱啃纸箱", table: "CatProfiles"),
                         String(localized: "埋伏高手", table: "CatProfiles")],
                funFact: String(localized: "会装出一副很乖的样子，趁人不注意打开放猫粮和零食的柜子，给自己开自助餐。", table: "CatProfiles")),
            CatProfile(
                id: "siamese", chineseName: "摩卡", englishName: "Mocha", gender: .boy, // not-localized: a name, shown as is (Chinese interface) or as its English name
                breed: String(localized: "暹罗（重点色）", table: "CatProfiles"),
                traits: [String(localized: "话痨", table: "CatProfiles"),
                         String(localized: "小跟班", table: "CatProfiles")],
                funFact: String(localized: "你走到哪儿，他就跟到哪儿，一路喵个不停，像在汇报家里今天发生的每一件事。", table: "CatProfiles")),
            CatProfile(
                id: "ragdoll", chineseName: "团团", englishName: "Mochi", gender: .girl, // not-localized: a name, shown as is (Chinese interface) or as its English name
                breed: String(localized: "布偶（长毛）", table: "CatProfiles"),
                traits: [String(localized: "爱运动", table: "CatProfiles"),
                         String(localized: "自律 ISTJ", table: "CatProfiles"),
                         String(localized: "爱贴贴", table: "CatProfiles")],
                funFact: String(localized: "小时候能趴在肩膀上睡觉；长大了一个肩膀不够睡，就像围巾一样围着脖子，趴在两个肩膀上。", table: "CatProfiles")),
            CatProfile(
                id: "black", chineseName: "露娜", englishName: "Luna", gender: .girl, // not-localized: a name, shown as is (Chinese interface) or as its English name
                breed: String(localized: "黑猫", table: "CatProfiles"),
                traits: [String(localized: "夜猫子", table: "CatProfiles"),
                         String(localized: "追光斑", table: "CatProfiles")],
                funFact: String(localized: "白天总在睡觉，一到晚上就来了精神。手表反射到墙上的一小块光，她能追着扑上好半天。", table: "CatProfiles")),
            CatProfile(
                id: "white", chineseName: "雪球", englishName: "Snowy", gender: .girl, // not-localized: a name, shown as is (Chinese interface) or as its English name
                breed: String(localized: "白猫", table: "CatProfiles"),
                traits: [String(localized: "爱干净", table: "CatProfiles"),
                         String(localized: "有点害羞", table: "CatProfiles"),
                         String(localized: "温柔", table: "CatProfiles")],
                funFact: String(localized: "家里来了客人，她先躲在床底下偷偷看；等客人走了才出来，把自己从头到尾舔得干干净净。", table: "CatProfiles")),
            CatProfile(
                id: "sphynx", chineseName: "粉粉", englishName: "Pinky", gender: .boy, // not-localized: a name, shown as is (Chinese interface) or as its English name
                breed: String(localized: "无毛猫", table: "CatProfiles"),
                traits: [String(localized: "小暖炉", table: "CatProfiles"),
                         String(localized: "钻被窝", table: "CatProfiles")],
                funFact: String(localized: "没有毛，摸起来暖乎乎的，像个小暖水袋。天一凉，他就钻进被窝，只露出两只大耳朵。", table: "CatProfiles")),
            CatProfile(
                id: "zhaocai", chineseName: "招财", englishName: "Zhaocai", gender: .boy, // not-localized: a name, shown as is (Chinese interface) or as its English name
                breed: String(localized: "金渐层", table: "CatProfiles"),
                traits: [String(localized: "高冷", table: "CatProfiles"),
                         String(localized: "爱吃猫条", table: "CatProfiles"),
                         String(localized: "捉迷藏", table: "CatProfiles")],
                funFact: String(localized: "有一次不小心被关在厨房里，它不哭也不闹，默默坐在玻璃门旁，等主人自己发现它。", table: "CatProfiles")),
        ]
    }
}
