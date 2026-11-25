import Testing

/// The character cards of the built-in cats (`ios/Meowverse/App/CatProfiles.swift`, linked into
/// this target as `AppShared/CatProfiles.swift`). The strings here are the catalog keys: the test
/// bundle has no `CatProfiles.xcstrings`, so `String(localized:)` returns the Chinese source.
struct CatProfilesTests {
    static let builtInIDs = ["bella", "airou", "zhumi", "siamese", "ragdoll", "black", "white", "sphynx", "zhaocai"]

    @Test func everyBuiltInCatHasACard() throws {
        #expect(Set(CatProfiles.all.map(\.id)) == Set(Self.builtInIDs))
        #expect(CatProfiles.all.count == Self.builtInIDs.count, "one card per cat")
        for id in Self.builtInIDs {
            let profile = try #require(CatProfiles.profile(for: id), "\(id)")
            #expect(!profile.breed.isEmpty, "\(id)")
            #expect((2...3).contains(profile.traits.count), "\(id): two or three tags")
        }
    }

    @Test func importedAndUnknownIDsHaveNoCard() {
        #expect(CatProfiles.profile(for: "test-cat") == nil)
        #expect(CatProfiles.profile(for: "") == nil)
    }

    /// The owner's names (2026-11-20): Chinese in a Chinese interface, English otherwise.
    @Test(arguments: [
        ("black", "露娜", "Luna", CatProfile.Gender.girl),
        ("bella", "贝咪", "Bella", .girl),
        ("ragdoll", "团团", "Mochi", .girl),
        ("zhumi", "猪咪", "Zhumi", .boy),
        ("airou", "艾露", "Airou", .girl),
    ])
    func theOwnersNames(id: String, chinese: String, english: String, gender: CatProfile.Gender) throws {
        let profile = try #require(CatProfiles.profile(for: id))
        #expect(profile.name(chinese: true) == chinese)
        #expect(profile.name(chinese: false) == english)
        #expect(profile.otherName(chinese: true) == english)
        #expect(profile.otherName(chinese: false) == chinese)
        #expect(profile.gender == gender)
    }

    /// Named by the owner later the same day (2026-11-20, lead): Chinese names new, English kept.
    @Test(arguments: [
        ("siamese", "摩卡", "Mocha", CatProfile.Gender.boy),
        ("white", "雪球", "Snowy", .girl),
        ("sphynx", "粉粉", "Pinky", .boy),
    ])
    func theLaterNames(id: String, chinese: String, english: String, gender: CatProfile.Gender) throws {
        let profile = try #require(CatProfiles.profile(for: id))
        #expect(profile.name(chinese: true) == chinese)
        #expect(profile.name(chinese: false) == english)
        #expect(profile.gender == gender)
    }

    @Test func everyCardShowsAGender() {
        for profile in CatProfiles.all { #expect(profile.genderText != nil, "\(profile.id)") }
    }

    @Test func genderWords() throws {
        #expect(try #require(CatProfiles.profile(for: "bella")).genderText == "女孩")
        #expect(try #require(CatProfiles.profile(for: "zhumi")).genderText == "男孩")
    }

    /// One line for every cat (owner, 2026-11-20; 喵空间 since 2026-11-22): who sponsored her, by her name.
    @Test func everyBioSaysHerHumanSponsoredMeowverse() {
        for profile in CatProfiles.all {
            #expect(profile.bio(chinese: true) == "\(profile.chineseName)的铲屎官赞助了我们的喵空间！", "\(profile.id)")
        }
        #expect(CatProfiles.profile(for: "black")?.bio(chinese: true) == "露娜的铲屎官赞助了我们的喵空间！")
    }

    /// Every card has its tags and a 小趣事 (owner, 2026-11-24): two to five characters a tag (a
    /// run of Latin letters counts as one, spaces as none), and one or two sentences of fact.
    @Test func everyCardHasShortTagsAndAFunFact() throws {
        for profile in CatProfiles.all {
            for tag in profile.traits {
                #expect((2...5).contains(Self.length(of: tag)), "\(profile.id): 「\(tag)」")
            }
            #expect(Set(profile.traits).count == profile.traits.count, "\(profile.id): a tag twice")
            let fact = try #require(profile.funFact, "\(profile.id)")
            #expect(fact.hasSuffix("。"), "\(profile.id): \(fact)")
            let sentences = fact.filter { "。！？".contains($0) }.count
            #expect((1...2).contains(sentences), "\(profile.id): \(sentences) sentences")
            #expect(fact.count <= 60, "\(profile.id): \(fact.count) characters")
            for standIn in ["示例", "待补充", "TODO", "（"] {
                #expect(!fact.contains(standIn), "\(profile.id): \(fact)")
            }
        }
    }

    /// Bella, Mochi, Airou and Zhumi are real cats: their tags and line are what their sponsors
    /// told the owner (docs/release/1.0/cat-credits.md). Change them only with the owner.
    @Test(arguments: [
        ("bella", ["爱拍屁屁", "小馋猫", "被宠坏了"],
         "铲屎官躺在床上看电视，她就趴到胸口上要摸摸、要拍屁屁；不拍，就用湿漉漉的小鼻子拱铲屎官的手。"),
        ("ragdoll", ["爱运动", "自律 ISTJ", "爱贴贴"],
         "小时候能趴在肩膀上睡觉；长大了一个肩膀不够睡，就像围巾一样围着脖子，趴在两个肩膀上。"),
        ("airou", ["谨慎又好奇", "爱看松鼠", "躲抽屉"],
         "新买的自动猫砂盆转起来哗啦啦地响，艾露听了很生气，跑过去把它暴打了一顿。"),
        ("zhumi", ["淘气包", "爱啃纸箱", "埋伏高手"],
         "会装出一副很乖的样子，趁人不注意打开放猫粮和零食的柜子，给自己开自助餐。"),
    ])
    func theSponsorsOwnCats(id: String, traits: [String], funFact: String) throws {
        let profile = try #require(CatProfiles.profile(for: id))
        #expect(profile.traits == traits)
        #expect(profile.funFact == funFact)
    }

    /// The other four kept the tags they had; the team wrote their lines at the owner's request.
    @Test(arguments: [
        ("siamese", ["话痨", "小跟班"]),
        ("black", ["夜猫子", "追光斑"]),
        ("white", ["爱干净", "有点害羞", "温柔"]),
        ("sphynx", ["小暖炉", "钻被窝"]),
    ])
    func theOtherCatsKeepTheirTags(id: String, traits: [String]) throws {
        #expect(try #require(CatProfiles.profile(for: id)).traits == traits)
    }

    /// Characters as a reader counts them in a tag: each Han character one, a Latin word one.
    private static func length(of tag: String) -> Int {
        var count = 0, inWord = false
        for character in tag {
            if character.isWhitespace { inWord = false; continue }
            if character.isASCII, character.isLetter || character.isNumber {
                if !inWord { count += 1 }
                inWord = true
            } else {
                count += 1
                inWord = false
            }
        }
        return count
    }
}
