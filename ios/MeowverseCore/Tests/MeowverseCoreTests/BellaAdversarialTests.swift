import Foundation
import Testing
@testable import MeowverseCore

/// QA's round 12 adversarial checks on Talk to Bella, written against docs/TALK_TO_BELLA.md
/// rather than the implementation (including "QA 复核后补充").
@Suite struct BellaAdversarialTests {
    private func m(_ text: String, _ name: String = "Bella") -> BellaCommand? {
        BellaCommandRules.match(text, catName: name)
    }

    // MARK: Rules: the contract says nil (→ model / not understood), never a guess

    @Test(arguments: [
        // negation in other shapes
        "不去沙发", "沙发别去了", "算了，去沙发吧不用了", "Bella, no sofa", "not the sofa", "never mind",
        "don’t go to bed",            // curly apostrophe
        "Do NOT come here",
        // two commands
        "去沙发然后去床", "去沙发再去床", "去沙发和床", "sofa and bed", "去喝水再去睡觉", "lie on the sofa then sleep on the bed",
        "过来然后去沙发", "come here and sit on the sofa", "吃零食然后去睡觉",
        // punctuation / emoji / symbols only
        "？？？", "!!!", "…", "——", "🛋️", "🐈‍⬛", "😺😺😺", "#", "@@",
    ])
    func unsureOrNegatedIsNil(_ text: String) {
        #expect(m(text) == nil, "\(text) → \(String(describing: m(text)))")
    }

    @Test func playOnANamedPieceIsAVisit() {
        // By design, like "去猫爬架上玩": the resolver decides whether the bed offers play.
        #expect(m("去床上玩") == .visit(action: .play, target: .bed))
    }

    /// The speaker talking about themselves ("我饿了", "I want to go to the bathroom") is not an
    /// instruction to the cat ("QA 复核后补充").
    @Test(arguments: ["我饿了", "我渴了", "我困了", "我要睡觉了", "我要上厕所", "我去上厕所", "我想喝水",
                      "我要你去沙发", "Bella，我饿了", "I want to sleep", "I want to go to the bathroom",
                      "I want to eat", "I'm hungry", "Bella, I'm going to bed"])
    func speakerSelfStatementsAreNotCommands(_ text: String) {
        #expect(m(text) == nil, "\(text) → \(String(describing: m(text)))")
    }

    /// Instructions to her keep working, also where 我 is the object ("陪我", "跟我").
    @Test func instructionsAroundTheSpeakerStillWork() {
        let sofa = BellaCommand.visit(action: .loaf, target: .sofa)
        #expect(m("你去沙发") == sofa)
        #expect(m("去沙发吧") == sofa)
        #expect(m("陪我玩") == .play(treat: false))
        #expect(m("跟我来") == .comeHere)
        #expect(m("和我玩一会儿") == .play(treat: false))
        #expect(m("到我这里来") == .comeHere)
        #expect(m("过来让我摸摸") == .comeHere)
        #expect(m("给我唱首歌") == .unsupported)
        #expect(m("come to me") == .comeHere)
        #expect(m("let me pet you") == .comeHere)
    }

    @Test func emojiNextToAKnownPhrase() {
        // Speech never adds emoji, but the DEBUG transcript and future text input could.
        let sofa = BellaCommand.visit(action: .loaf, target: .sofa)
        #expect(m("去沙发😺") == sofa)
        #expect(m("去沙发🛋️") == sofa)
        #expect(m("🛋️去沙发") == sofa)
    }

    @Test func mixedChineseAndEnglish() {
        let sofa = BellaCommand.visit(action: .loaf, target: .sofa)
        #expect(m("Bella 去 sofa 上躺着") == sofa)
        #expect(m("去sofa上躺着") == sofa)
        #expect(m("go 沙发 lie down") == sofa)
        #expect(m("come here 贝拉") == .comeHere)
    }

    /// No timing assertion: under load the run time is not stable. The answer must be right.
    @Test func veryLongSentenceIsSane() {
        let long = String(repeating: "去沙发上躺着", count: 2_000)       // 12 000 characters
        #expect(m(long) == .visit(action: .loaf, target: .sofa))
        let noise = String(repeating: "啊", count: 5_000) + "去沙发" + String(repeating: "x", count: 5_000)
        #expect(m(noise) == nil)
    }

    // MARK: Renamed cat

    @Test func renamedCatAddressing() {
        let sofa = BellaCommand.visit(action: .loaf, target: .sofa)
        #expect(m("小不点，去沙发上躺着", "小不点") == sofa, "a name containing 不 must not read as a negation")
        #expect(m("去沙发上躺着，小不点", "小不点") == sofa)
        #expect(m("Bella，去沙发上躺着", "Mochi") == sofa)
        #expect(m("Mochi Mochi, come here", "Mochi") == .comeHere)
        // Name both before and after (people do say it twice).
        #expect(m("小黑，去沙发，小黑", "小黑") == sofa)
        // A name that is all filler / empty after normalising.
        #expect(m("！！！去沙发", "！！！") == sofa)
        // A cat named after a lexicon word ("饼干", "盒子"): `match` reads the name as an address;
        // `nameMayBeAWord` sends such sentences to the model (BellaNameCollisionTests).
    }

    // MARK: Mishearings

    @Test func mishearings() {
        // The listed ones map; others go to the model rather than being guessed.
        #expect(m("去莎发上躺着") == .visit(action: .loaf, target: .sofa))
        #expect(m("去沙法") == .visit(action: .loaf, target: .sofa))
        for text in ["去杀发", "去傻发", "过赖", "国来", "lie on the sofer", "lie on the soda", "come hear",
                     "go to bad", "take a nab"] {
            #expect(m(text) == nil, "\(text) → \(String(describing: m(text)))")
        }
    }

    // MARK: Resolver

    private let catalog: FurnitureCatalog
    init() throws { catalog = try FurnitureCatalog.bundled() }

    private func piece(_ id: String, _ modelId: String, x: Int, z: Int) throws -> PhotoFurniture {
        let model = try #require(catalog.model(id: modelId))
        return PhotoFurniture(instanceId: id, modelId: modelId, x: x, z: z, width: model.defaultWidth,
                              depth: model.defaultDepth, turn: 0, wall: nil, finish: .original,
                              displayName: model.label, sources: [], tags: [], revision: 1)
    }

    /// "去沙发上喝水" in a room WITH a sofa stays `.noSuchFurniture(.sofa)`: no sofa offers drink.
    /// `BellaRefusal` is unchanged on purpose ("QA 复核后补充"); the App words it as "沙发上不能
    /// 这样做" because the room has a sofa, and as "房间里还没有沙发" only when it has none.
    @Test func namedPieceThatLacksTheActionIsNoSuchFurniture() throws {
        let room = [try piece("sofa", "mv-sofa-a", x: 6, z: 5)]
        let command = try #require(m("去沙发上喝水"))
        #expect(command == .visit(action: .drink, target: .sofa))
        #expect(BellaCommandResolver.resolve(command, items: room, catalog: catalog) == .failure(.noSuchFurniture(.sofa)))
    }

    /// Decorative pieces offer nothing: going to one is refused, and Bella does not move.
    @Test func decorativePiecesAreRefused() throws {
        let decorative = catalog.models.filter(\.isDecorative)
        #expect(!decorative.isEmpty)
        for model in decorative {
            let room = [try piece("d", model.id, x: 6, z: 5)]
            let command = BellaCommand.visit(action: CatRoutine.action(on: model.category), target: model.category)
            #expect(BellaCommandResolver.resolve(command, items: room, catalog: catalog)
                    == .failure(.noSuchFurniture(model.category)), "\(model.id)")
        }
    }

    /// The model may answer "visit, play, no piece" where the rules say `.play(treat: false)`:
    /// both take the same path, a reachable toy first, else the felt mouse.
    @Test func modelVisitPlayWithoutFurnitureIsPlay() throws {
        let rooms: [[PhotoFurniture]] = [[], [try piece("toy", "mv-toy-a", x: 3, z: 3)],
                                         [try piece("sofa", "mv-sofa-a", x: 6, z: 5)]]
        for room in rooms {
            #expect(BellaCommandResolver.resolve(.visit(action: .play, target: nil), items: room, catalog: catalog)
                    == BellaCommandResolver.resolve(.play(treat: false), items: room, catalog: catalog))
        }
        #expect(BellaCommandResolver.resolve(.visit(action: .play, target: nil), items: [], catalog: catalog)
                == .success(.play(.toyMouse)))
        #expect(BellaCommandResolver.resolve(.visit(action: .play, target: nil), items: rooms[1], catalog: catalog)
                == .success(.invite(itemId: "toy", siteId: "mouse", action: .play)))
    }
}
