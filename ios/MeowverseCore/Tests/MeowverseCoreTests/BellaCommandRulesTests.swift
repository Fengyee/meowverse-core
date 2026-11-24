import Foundation
import Testing
@testable import MeowverseCore

/// Talk to Bella's fixed phrases (docs/TALK_TO_BELLA.md). A phrase the rules are not sure of
/// must come back nil, so the on-device model (or "not understood") decides it, never a guess.
@Suite struct BellaCommandRulesTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let text: String
        let command: BellaCommand?
        var testDescription: String { "\(text) → \(command.map { "\($0)" } ?? "nil")" }
    }

    private static func c(_ text: String, _ command: BellaCommand?) -> Case { Case(text: text, command: command) }

    static let chinese: [Case] = [
        c("去沙发上躺着", .visit(action: .loaf, target: .sofa)),
        c("去沙发上趴着吧", .visit(action: .loaf, target: .sofa)),
        c("沙法上趴一会儿", .visit(action: .loaf, target: .sofa)),
        c("上沙发", .visit(action: .loaf, target: .sofa)),
        c("去睡一会儿", .visit(action: .sleep, target: nil)),
        c("去睡觉吧", .visit(action: .sleep, target: nil)),
        c("打个盹", .visit(action: .sleep, target: nil)),
        c("去床上睡觉", .visit(action: .sleep, target: .bed)),
        c("回猫窝睡吧", .visit(action: .sleep, target: .bed)),
        c("去猫窝", .visit(action: .sleep, target: .bed)),
        c("坐下", .visit(action: .sit, target: nil)),
        c("去椅子上坐着", .visit(action: .sit, target: .chair)),
        c("喝水去", .visit(action: .drink, target: nil)),
        c("去喝点水呀", .visit(action: .drink, target: .water)),
        c("去水碗那里", .visit(action: .drink, target: .water)),
        c("吃点东西", .visit(action: .eat, target: nil)),
        c("去吃饭啦", .visit(action: .eat, target: nil)),
        c("吃零食", .play(treat: true)),
        c("给你小鱼干", .play(treat: true)),
        c("去磨磨爪子", .visit(action: .scratch, target: nil)),
        c("去猫抓板磨爪", .visit(action: .scratch, target: .scratcher)),
        c("去猫爬架上抓一抓", .visit(action: .scratch, target: .catTree)),
        c("躲起来", .visit(action: .hide, target: nil)),
        c("躲到纸箱里", .visit(action: .hide, target: .hideout)),
        c("去躲猫窝", .visit(action: .hide, target: .hideout)),
        c("去上厕所", .visit(action: .dig, target: nil)),
        c("去猫砂盆", .visit(action: .dig, target: .litterBox)),
        c("去窗台上趴着", .visit(action: .loaf, target: .windowPerch)),
        c("去猫爬架", .visit(action: .sit, target: .catTree)),
        c("去玩一会儿", .play(treat: false)),
        c("陪我玩", .play(treat: false)),
        c("玩玩具吧", .play(treat: false)),
        c("去猫爬架上玩", .visit(action: .play, target: .catTree)),
        c("过来", .comeHere),
        c("过来让我摸摸", .comeHere),
        c("来这里", .comeHere),
        c("来", .comeHere),
        c("过来吃零食", .play(treat: true)),
        c("给我唱首歌", .unsupported),
        c("讲个笑话", .unsupported),
    ]

    static let english: [Case] = [
        c("lie on the sofa", .visit(action: .loaf, target: .sofa)),
        c("Lie down on the couch, please", .visit(action: .loaf, target: .sofa)),
        c("take a nap", .visit(action: .sleep, target: nil)),
        c("go to sleep", .visit(action: .sleep, target: nil)),
        c("go to bed", .visit(action: .sleep, target: .bed)),
        c("sit down", .visit(action: .sit, target: nil)),
        c("sit on the window perch", .visit(action: .sit, target: .windowPerch)),
        c("go drink", .visit(action: .drink, target: nil)),
        c("go drink some water", .visit(action: .drink, target: .water)),
        c("eat something", .visit(action: .eat, target: nil)),
        c("want a treat?", .play(treat: true)),
        c("snack time", .play(treat: true)),
        c("sharpen your claws", .visit(action: .scratch, target: nil)),
        c("use the scratching post", .visit(action: .scratch, target: .scratcher)),
        c("go hide", .visit(action: .hide, target: nil)),
        c("hide in the box", .visit(action: .hide, target: .hideout)),
        c("go potty", .visit(action: .dig, target: nil)),
        c("go to the litter box", .visit(action: .dig, target: .litterBox)),
        c("climb the cat tree", .visit(action: .sit, target: .catTree)),
        c("play", .play(treat: false)),
        c("let's play with the ball", .play(treat: false)),
        c("come here", .comeHere),
        c("Come here, kitty!", .comeHere),
        c("come", .comeHere),
        c("sing me a song", .unsupported),
        c("tell me a joke", .unsupported),
    ]

    @Test(arguments: chinese) func matchesChinesePhrases(_ example: Case) {
        #expect(BellaCommandRules.match(example.text, catName: "Bella") == example.command)
    }

    @Test(arguments: english) func matchesEnglishPhrases(_ example: Case) {
        #expect(BellaCommandRules.match(example.text, catName: "Bella") == example.command)
    }

    @Test func ignoresTheCatNameAsPrefixOrSuffixWhateverSheIsCalled() {
        let sofa = BellaCommand.visit(action: .loaf, target: .sofa)
        #expect(BellaCommandRules.match("Bella，去沙发上躺着", catName: "Bella") == sofa)
        #expect(BellaCommandRules.match("Mochi, lie on the sofa", catName: "Mochi") == sofa)
        #expect(BellaCommandRules.match("lie on the sofa, Mochi!", catName: "Mochi") == sofa)
        #expect(BellaCommandRules.match("团子团子，去沙发上趴着", catName: "团子") == sofa)
        #expect(BellaCommandRules.match("去沙发上躺着吧，小黑。", catName: "小黑") == sofa)
        #expect(BellaCommandRules.match("Miss Pickles, come here", catName: "Miss Pickles") == .comeHere)
        // The feature is called Talk to Bella: her default name is dropped even after renaming.
        #expect(BellaCommandRules.match("贝拉，过来", catName: "Mochi") == .comeHere)
        // A name is only dropped as a whole word, never out of the middle of one.
        #expect(BellaCommandRules.match("Mocha come", catName: "Mo") == nil)
        // A cat named after a word in a phrase keeps that word in the middle of it.
        #expect(BellaCommandRules.match("Sofa, lie on the sofa", catName: "Sofa") == sofa)
        #expect(BellaCommandRules.match("Bella", catName: "Bella") == nil)
        #expect(BellaCommandRules.match("去睡觉", catName: "") == .visit(action: .sleep, target: nil))
    }

    @Test func toleratesPunctuationWidthCaseAndSpacing() {
        let sofa = BellaCommand.visit(action: .loaf, target: .sofa)
        #expect(BellaCommandRules.match("  去 沙发 上，躺着！！ ", catName: "Bella") == sofa)
        #expect(BellaCommandRules.match("ＬＩＥ ＯＮ ＴＨＥ ＳＯＦＡ", catName: "Bella") == sofa)
        #expect(BellaCommandRules.match("LIE   ON\tTHE\nSOFA...", catName: "Bella") == sofa)
        #expect(BellaCommandRules.match("ｂｅｌｌａ，ｃｏｍｅ　ｈｅｒｅ", catName: "Bella") == .comeHere)
        #expect(BellaCommandRules.match("過來", catName: "Bella") == .comeHere)
        #expect(BellaCommandRules.match("去沙發上睡覺", catName: "Bella") == .visit(action: .sleep, target: .sofa))
    }

    @Test func understandsCommonMishearings() {
        #expect(BellaCommandRules.match("沙法", catName: "Bella") == .visit(action: .loaf, target: .sofa))
        #expect(BellaCommandRules.match("去猫沙盆", catName: "Bella") == .visit(action: .dig, target: .litterBox))
        #expect(BellaCommandRules.match("去猫趴架", catName: "Bella") == .visit(action: .sit, target: .catTree))
        #expect(BellaCommandRules.match("去猫爪板", catName: "Bella") == .visit(action: .scratch, target: .scratcher))
        #expect(BellaCommandRules.match("去魔爪", catName: "Bella") == .visit(action: .scratch, target: nil))
        #expect(BellaCommandRules.match("去水饺", catName: "Bella") == .visit(action: .sleep, target: nil))
        #expect(BellaCommandRules.match("lie on the so far", catName: "Bella") == .visit(action: .loaf, target: .sofa))
    }

    @Test(arguments: ["别去沙发", "不要睡", "不要过来", "别躲起来", "沙发上不能睡", "不许吃零食",
                      "don't sit on the sofa", "do not come here", "never scratch the sofa", "stop scratching",
                      "no treats", "Bella, don't play"])
    func refusesNegations(_ text: String) {
        #expect(BellaCommandRules.match(text, catName: "Bella") == nil)
    }

    @Test(arguments: ["", "   ", "。。。", "Bella", "嗯", "去", "去那边", "please", "the",
                      "asdfgh", "今天天气怎么样呀我们去公园", "去沙发上躺着睡觉", "去床上和沙发上",
                      "过来沙发这里", "sit here", "去地上躺着", "抓老鼠追老鼠然后吃饭",
                      "what is the capital of France", "lie on the sofa and then eat", "🐱🐱", "12345",
                      "去沙发旁边", "下来", "起来"])
    func leavesUnsurePhrasesToTheModel(_ text: String) {
        #expect(BellaCommandRules.match(text, catName: "Bella") == nil)
    }

    @Test func everyLexiconWordHasOneMeaning() {
        let words = BellaCommandRules.lexicon.map(\.word)
        var seen = Set<String>(), duplicates: [String] = []
        for word in words where !seen.insert(word).inserted { duplicates.append(word) }
        #expect(duplicates.isEmpty, "\(duplicates)")
        // Words are stored already normalised, or they could never match.
        for word in words {
            #expect(BellaCommandRules.normalized(word) == word, "\(word)")
        }
    }

    @Test func namesEveryCategoryThatOffersSomethingToDo() throws {
        let catalog = try FurnitureCatalog.bundled()
        let named = Set(BellaCommandRules.lexicon.compactMap { entry -> FurnitureCategory? in
            if case .furniture(let category) = entry.meaning { return category }
            return nil
        })
        for category in FurnitureCategory.allCases where !catalog.models(in: category).isEmpty {
            #expect(named.contains(category), "\(category)")
        }
    }
}

/// A cat named after a lexicon word ("饼干", "盒子", "Box"): said at either end of the sentence,
/// the name may be calling her or may be the thing asked for. When the two readings disagree the
/// rules flag the sentence so the model (which is told her name) decides; `match` keeps its old
/// answer for devices without the model.
@Suite struct BellaNameCollisionTests {
    private func flagged(_ text: String, _ name: String) -> Bool {
        BellaCommandRules.nameMayBeAWord(text, catName: name)
    }

    @Test func readingsThatDisagreeAreFlagged() {
        #expect(flagged("去吃，饼干", "饼干"))
        #expect(flagged("饼干，去吃", "饼干"))
        #expect(flagged("盒子里躲着", "盒子"))
        #expect(flagged("去沙发，盒子", "盒子"))
        #expect(flagged("Box, come here", "Box"))
    }

    @Test func plainNamesAndAbsentNamesAreNotFlagged() {
        #expect(!flagged("小黑，去沙发", "小黑"))
        #expect(!flagged("去沙发上躺着", "饼干"))
        #expect(!flagged("去吃饼干", "团子"))
        #expect(!flagged("Bella，过来", "Bella"))
        #expect(!flagged("Mochi, come here", "Mochi"))
        // The name in the middle is never an address.
        #expect(!flagged("去吃饼干零食", "饼干"))
    }

    @Test func readingsThatAgreeAreNotFlagged() {
        // Both readings are "eat a treat".
        #expect(!flagged("饼干，吃零食", "饼干"))
        // Both readings are "hide in the box".
        #expect(!flagged("盒子，去盒子里躲着", "盒子"))
        // Only her name: the word reading ("box") and the empty one disagree, so the model decides.
        #expect(flagged("盒子盒子", "盒子"))
    }

    @Test func matchStillAnswersWithoutTheModel() {
        #expect(BellaCommandRules.match("饼干，去吃", catName: "饼干") == .visit(action: .eat, target: nil))
        #expect(BellaCommandRules.match("Box, come here", catName: "Box") == .comeHere)
    }
}
