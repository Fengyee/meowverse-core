import Testing

/// The character cards of the built-in cats (`ios/Meowverse/App/CatProfiles.swift`, linked into
/// this target as `AppShared/CatProfiles.swift`). The strings here are the catalog keys: the test
/// bundle has no `CatProfiles.xcstrings`, so `String(localized:)` returns the Chinese source.
struct CatProfilesTests {
    static let builtInIDs = ["bella", "airou", "zhumi", "siamese", "ragdoll", "black", "white", "sphynx"]

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

    /// The owner has not written the fun facts yet: no card has one, and none has a stand-in for
    /// one. Update this when they are written; never invent one.
    @Test func noCatHasAFunFactUntilTheOwnerWritesOne() {
        for profile in CatProfiles.all {
            let fact: String? = profile.funFact
            #expect(fact == nil, "\(profile.id)")
        }
    }

    @Test func aWrittenFunFactIsKept() throws {
        let fact: String? = try #require(CatProfiles.profile(for: "bella")).withFunFact("会自己开门").funFact
        #expect(fact == "会自己开门")
    }
}
