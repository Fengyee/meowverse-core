import Foundation

/// Talk to Bella's fast path (docs/TALK_TO_BELLA.md): fixed phrases in Chinese and English,
/// no model.
///
/// A sentence matches only when every part of it is a known word: a piece of furniture, an
/// action, play / treat / come-here, something a cat cannot do, or filler (particles, "please",
/// "go to the"). Anything else, a negation ("别去沙发", "don't"), or two different pieces or
/// actions in one sentence returns nil, so the on-device model (or "not understood") decides.
/// The rules never guess.
public enum BellaCommandRules {
    /// The command a plain, known phrase asks for, or nil when the sentence is not one; the
    /// on-device model (when available) decides those. `catName` is the lead cat's current
    /// name, so "Bella，" / "Mochi, ..." addressing is ignored whatever she is called.
    public static func match(_ transcript: String, catName: String) -> BellaCommand? {
        // The name said at both ends ("小黑，去沙发，小黑"): the end is dropped only when the
        // sentence does not read without that ("Sofa, lie on the sofa" keeps its last word).
        for text in withoutAddress(normalized(transcript), catName: catName) {
            guard !text.isEmpty, !isNegated(text), let meanings = tokens(text) else { continue }
            // The speaker talking about themselves ("我饿了", "I want to sleep") is not an
            // instruction; "陪我玩", "跟我来", "让我摸摸" read 我 as part of another word.
            guard !meanings.contains(.speaker) else { return nil }
            return command(meanings.filter { $0 != .filler })
        }
        return nil
    }

    /// True when the cat is named after a lexicon word ("饼干", "盒子", "Box"), the name sits at
    /// either end of the sentence, and reading it as her name gives a different command than
    /// reading it as the word ("去吃，饼干": eat, or eat a treat). The rules cannot tell which was
    /// meant, so the app asks the model, which is told her name, and keeps `match` only when no
    /// model answer comes back.
    public static func nameMayBeAWord(_ transcript: String, catName: String) -> Bool {
        let name = normalized(catName)
        guard !name.isEmpty, !defaultNames.contains(name), let meanings = tokens(name),
              meanings.contains(where: { $0 != .filler }) else { return false }
        let text = normalized(transcript)
        var called = text
        while startsWithWord(called, name) {
            called = String(called.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
        }
        if endsWithWord(called, name) {
            called = String(called.dropLast(name.count)).trimmingCharacters(in: .whitespaces)
        }
        guard called != text else { return false }
        return match(called, catName: "") != match(text, catName: "")
    }

    // MARK: Normalising

    /// Lower case, half width, simplified Chinese; punctuation and runs of white space become
    /// one space; apostrophes vanish ("don't" → "dont"). Lexicon words are stored this way.
    static func normalized(_ text: String) -> String {
        let simplified = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        let folded = simplified.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
            .union(.controlCharacters).union(CharacterSet(charactersIn: "\u{FE0E}\u{FE0F}\u{200D}"))
        return folded.unicodeScalars.split { separators.contains($0) }.map { String(String.UnicodeScalarView($0)) }
            .joined(separator: " ")
    }

    /// The feature's own name: "Bella" stays a way to address her after she is renamed.
    private static let defaultNames = ["bella", "贝拉"]

    /// The sentence without the cat's name where it addresses her, in the order to try: the
    /// name dropped repeatedly from the front ("团子团子，"), then also once from the end
    /// ("…，小黑"). Only whole words: "Mo" is not dropped from "Mocha".
    static func withoutAddress(_ text: String, catName: String) -> [String] {
        let names = ([normalized(catName)] + defaultNames).filter { !$0.isEmpty }
        var text = text
        while let name = names.first(where: { startsWithWord(text, $0) }) {
            text = String(text.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
        }
        guard let name = names.first(where: { endsWithWord(text, $0) }) else { return [text] }
        return [text, String(text.dropLast(name.count)).trimmingCharacters(in: .whitespaces)]
    }

    private static func isLatin(_ character: Character?) -> Bool {
        guard let character, character.isASCII else { return false }
        return character.isLetter || character.isNumber
    }

    private static func startsWithWord(_ text: String, _ word: String) -> Bool {
        guard text.hasPrefix(word) else { return false }
        let next = text.dropFirst(word.count).first
        return !(isLatin(word.last) && isLatin(next))
    }

    private static func endsWithWord(_ text: String, _ word: String) -> Bool {
        guard text.hasSuffix(word), text.count > word.count else { return false }
        let previous = text.dropLast(word.count).last
        return !(isLatin(word.first) && isLatin(previous))
    }

    // MARK: Negation

    private static let negatingCharacters: [String] = ["不", "别", "甭", "勿", "莫", "没", "停"]
    private static let negatingWords: Set<String> = ["dont", "do not", "not", "never", "no", "stop", "quit", "doesnt",
                                                     "cant", "cannot", "wont", "shouldnt", "nope"]

    static func isNegated(_ text: String) -> Bool {
        if negatingCharacters.contains(where: text.contains) { return true }
        let words = text.split(separator: " ").map(String.init)
        return words.contains(where: negatingWords.contains)
            || zip(words, words.dropFirst()).contains { negatingWords.contains("\($0) \($1)") }
    }

    // MARK: Words

    enum Meaning: Equatable, Sendable {
        case furniture(FurnitureCategory)
        case action(CatAction)
        /// Play with a toy ("玩", "play").
        case play
        /// A treat ("零食", "snack").
        case treat
        /// "过来", "这里", "come here": only on its own (or with a treat or play).
        case comeHere
        /// "来", "come": come-here on its own, filler next to anything else ("来玩").
        case come
        /// Something a cat in this room cannot do ("唱歌", "tell a joke").
        case unsupported
        /// "我", "I" on its own: the speaker is the subject, so the sentence is about them.
        case speaker
        case filler
    }

    struct Entry: Sendable {
        let word: String
        let meaning: Meaning
    }

    private static func entries(_ words: [String], _ meaning: Meaning) -> [Entry] {
        words.map { Entry(word: $0, meaning: meaning) }
    }

    /// Every known word, normalised. Furniture words follow the catalog's categories (sites and
    /// actions: `contracts`, `mv-furniture.catalog.json`); a few common mishearings of the
    /// on-device recogniser are listed with them (沙法, 猫沙盆, 猫趴架, 魔爪, 水饺, "so far").
    static let lexicon: [Entry] = furnitureWords + actionWords + otherWords

    private static let furnitureWords: [Entry] =
        entries(["沙发", "沙法", "莎发", "长沙发", "小沙发", "sofa", "couch", "settee", "loveseat", "so far"],
                .furniture(.sofa))
        + entries(["床", "大床", "小床", "猫窝", "猫床", "窝", "小窝", "被窝", "被子", "枕头", "垫子", "软垫",
                   "bed", "cat bed", "pet bed", "pillow", "cushion"], .furniture(.bed))
        + entries(["纸箱", "纸箱子", "箱子", "盒子", "纸盒", "纸盒子", "躲猫窝", "隧道", "猫隧道", "帐篷", "猫帐篷",
                   "洞", "猫洞", "山洞", "hideout", "box", "cardboard box", "tunnel", "cave", "tent", "den"],
                  .furniture(.hideout))
        + entries(["水碗", "水盆", "水盘", "饮水机", "饮水器", "喷泉", "水", "碗", "食盆", "饭盆", "饭碗", "猫碗",
                   "食碗", "喂食器", "water bowl", "bowl", "water", "fountain", "water fountain", "feeder", "dish",
                   "food bowl", "feeding station"], .furniture(.water))
        + entries(["猫抓板", "抓板", "猫爪板", "磨爪板", "猫抓柱", "抓柱", "剑麻柱", "scratcher", "scratching post",
                   "scratch post", "scratching board", "scratch board", "scratch pad"], .furniture(.scratcher))
        + entries(["猫爬架", "爬架", "猫趴架", "趴架", "猫扒架", "毛爬架", "猫架", "猫树", "cat tree", "cat tower",
                   "cat condo", "tower", "condo"], .furniture(.catTree))
        + entries(["跳台", "猫跳台", "台阶", "猫台阶", "平台", "platform", "step", "steps", "stairs"],
                  .furniture(.platform))
        + entries(["窗台", "窗边", "窗户", "窗户边", "窗", "飘窗", "window", "window perch", "window seat",
                   "windowsill", "window sill", "perch"], .furniture(.windowPerch))
        + entries(["玩具", "逗猫棒", "羽毛棒", "小老鼠", "老鼠玩具", "球", "小球", "毛线球", "毛线", "跑轮", "猫跑轮",
                   "toy", "toys", "ball", "mouse", "toy mouse", "wand", "feather wand", "feather", "yarn",
                   "wheel", "cat wheel"], .furniture(.toy))
        + entries(["猫砂盆", "砂盆", "猫沙盆", "沙盆", "猫厕所", "litter box", "litterbox", "litter tray", "litter",
                   "sandbox"], .furniture(.litterBox))
        + entries(["椅子", "椅", "扶手椅", "摇椅", "餐椅", "躺椅", "chair", "armchair"], .furniture(.chair))
        + entries(["凳子", "凳", "板凳", "小板凳", "高脚凳", "吧凳", "stool", "bar stool"], .furniture(.stool))
        + entries(["长椅", "长凳", "长条凳", "bench"], .furniture(.bench))
        + entries(["桌子", "桌", "餐桌", "茶几", "table", "coffee table"], .furniture(.table))
        + entries(["书架", "书柜", "书橱", "bookcase", "bookshelf", "shelf", "shelves"], .furniture(.bookcase))
        + entries(["餐边柜", "边柜", "矮柜", "柜子", "柜", "sideboard", "cabinet", "cupboard"], .furniture(.sideboard))
        + entries(["电视柜", "电视", "tv stand", "tv cabinet", "tv console", "media console", "tv"],
                  .furniture(.mediaConsole))
        + entries(["书桌", "写字台", "写字桌", "办公桌", "电脑桌", "desk", "writing desk"], .furniture(.writingDesk))
        + entries(["梳妆台", "化妆台", "vanity", "dressing table"], .furniture(.vanity))
        + entries(["衣帽架", "衣架", "挂衣架", "coat rack", "coat stand", "hall tree"], .furniture(.coatRack))
        + entries(["落地灯", "台灯", "灯", "floor lamp", "lamp"], .furniture(.floorLamp))
        + entries(["屏风", "隔断", "room divider", "divider"], .furniture(.roomDivider))
        + entries(["花架", "植物架", "花盆架", "plant stand"], .furniture(.plantStand))
        + entries(["壁炉", "fireplace"], .furniture(.fireplace))
        + entries(["照片板", "照片墙", "photo board", "photo wall"], .furniture(.photoBoard))

    private static let actionWords: [Entry] =
        entries(["躺", "躺着", "躺下", "躺平", "趴", "趴着", "趴下", "窝着", "卧", "卧着", "揣手", "揣手手", "歇",
                 "歇着", "休息", "放松", "lie", "lie down", "lay", "lay down", "lying", "loaf", "rest", "relax",
                 "chill", "lounge", "curl"], .action(.loaf))
        + entries(["睡", "睡觉", "睡大觉", "觉", "午觉", "打盹", "打个盹", "打瞌睡", "瞌睡", "小睡", "午睡", "眯",
                   "补觉", "困", "水饺", "打顿", "sleep", "sleeping", "asleep", "sleepy", "nap", "napping",
                   "snooze", "doze", "bedtime"], .action(.sleep))
        + entries(["坐", "坐着", "坐下", "坐好", "蹲", "蹲着", "sit", "sit down", "sitting"], .action(.sit))
        + entries(["喝", "喝水", "饮水", "渴", "口渴", "drink", "drinking", "thirsty"], .action(.drink))
        + entries(["吃", "吃饭", "干饭", "开饭", "饭", "猫粮", "饿", "eat", "eating", "food", "dinner", "lunch",
                   "breakfast", "meal", "kibble", "hungry"], .action(.eat))
        + entries(["磨爪", "磨爪子", "磨磨爪子", "磨磨爪", "磨抓", "魔爪", "磨指甲", "磨", "抓", "抓抓", "挠", "挠挠",
                   "scratch", "scratching", "claws", "claw", "sharpen"], .action(.scratch))
        + entries(["躲", "躲起来", "藏", "藏起来", "躲猫猫", "藏好", "hide", "hiding"], .action(.hide))
        + entries(["上厕所", "厕所", "尿尿", "拉臭臭", "臭臭", "便便", "拉粑粑", "粑粑", "方便", "猫砂", "猫沙",
                   "刨猫砂", "扒猫砂", "扒一扒", "扒", "dig", "pee", "poop", "potty", "toilet", "bathroom"],
                  .action(.dig))

    private static let otherWords: [Entry] =
        entries(["玩", "玩玩", "玩耍", "耍", "拍一拍", "拍拍", "抓老鼠", "抓小老鼠", "追球", "追老鼠", "逗猫",
                 "play", "playtime", "fun", "chase"], .play)
        + entries(["零食", "小零食", "小鱼干", "鱼干", "饼干", "小鱼饼干", "罐罐", "猫条", "冻干", "点心", "小点心",
                   "奖励", "treat", "treats", "snack", "snacks", "biscuit", "biscuits", "cookie"], .treat)
        + entries(["过来", "来这里", "来这儿", "来这边", "这里", "这儿", "这边", "我这", "我这里", "我这儿", "我这边",
                   "我身边", "身边", "回来", "摸摸", "摸一摸", "让我摸摸", "抱抱", "抱一抱", "让我抱抱", "come here",
                   "come over", "over here", "here", "come back", "come closer", "closer", "come to me", "pet",
                   "cuddle"], .comeHere)
        + entries(["来", "come"], .come)
        + entries(["唱", "唱歌", "唱首歌", "唱个歌", "歌", "讲笑话", "说笑话", "讲个笑话", "说个笑话", "笑话", "讲故事",
                   "讲个故事", "故事", "说话", "讲话", "聊天", "跳舞", "跳个舞", "天气", "几点", "音乐", "放音乐",
                   "sing", "song", "joke", "jokes", "story", "dance", "dancing", "talk", "speak", "weather",
                   "music", "tell"], .unsupported)
        + entries(["请", "去", "到", "往", "上", "上面", "上去", "里", "里面", "里边", "进", "进去", "那", "那儿",
                   "那里", "那边", "一", "一下", "一会", "一会儿", "会", "会儿", "一觉", "个", "点", "一点", "点儿",
                   "些", "一些", "东西", "吧", "呀", "啦", "嘛", "哦", "喔", "啊", "呢", "哈", "咯", "噢", "哟", "呗",
                   "嘞", "了", "的", "在", "着", "儿", "你", "给", "给我", "帮我", "陪", "陪我", "和", "和我", "跟", "跟我", "让我", "一起",
                   "快", "快点", "赶紧", "乖", "乖乖", "宝贝", "宝宝", "猫咪", "小猫", "猫猫", "咪咪", "咪", "猫",
                   "想", "要", "可以", "能", "好", "好好", "回", "回去", "待", "呆", "先", "再", "就", "也", "还", "吗",
                   "跳", "爬", "让", "嘿",
                   "please", "pls", "go", "to", "the", "a", "an", "on", "onto", "in", "into", "inside", "at",
                   "your", "my", "up", "now", "some", "something", "little", "bit", "while", "for", "with", "it",
                   "and", "can", "could", "would", "will", "you", "do", "be", "me", "lets", "let", "get",
                   "have", "take", "want", "wanna", "time", "use", "climb", "jump", "kitty", "kitten", "cat",
                   "baby", "sweetie", "buddy", "good", "girl", "boy", "hey", "ok", "okay", "quick", "again"],
                  .filler)
        + entries(["我", "i", "im", "ill", "ive", "id"], .speaker)

    /// Longest words first, so among equally short readings the longer first word wins.
    private static let byLength: [(word: [Character], meaning: Meaning)] =
        lexicon.map { (Array($0.word), $0.meaning) }.sorted { $0.word.count > $1.word.count }

    /// The meaning of each word in `text`, read as the fewest known words ("猫抓板" rather than
    /// "猫" + "抓" + "板"; "玩" + "玩具" where a greedy "玩玩" would leave "具"); nil when some
    /// part is not a known word. A Latin word must end at a word boundary ("box" is not read
    /// from "boxes"); spaces separate words and are never part of one's edge.
    static func tokens(_ text: String) -> [Meaning]? {
        let characters = Array(text), count = characters.count
        func words(at index: Int) -> [(word: [Character], meaning: Meaning)] {
            byLength.filter { entry in
                let end = index + entry.word.count
                guard end <= count, characters[index..<end].elementsEqual(entry.word) else { return false }
                return !(isLatin(entry.word.last) && end < count && isLatin(characters[end]))
            }
        }
        // fewest[i]: fewest words that read characters[i...]; nil when they cannot be read.
        var fewest = [Int?](repeating: nil, count: count + 1), choice = [Int?](repeating: nil, count: count + 1)
        var next = [Int](repeating: 0, count: count + 1)
        fewest[count] = 0
        for index in stride(from: count - 1, through: 0, by: -1) {
            if characters[index] == " " {
                fewest[index] = fewest[index + 1]
                next[index] = index + 1
                continue
            }
            for (offset, entry) in words(at: index).enumerated() {
                guard let rest = fewest[index + entry.word.count] else { continue }
                if fewest[index] == nil || rest + 1 < fewest[index]! {
                    fewest[index] = rest + 1
                    choice[index] = offset
                    next[index] = index + entry.word.count
                }
            }
        }
        guard fewest[0] != nil else { return nil }
        var meanings: [Meaning] = [], index = 0
        while index < count {
            if let offset = choice[index] { meanings.append(words(at: index)[offset].meaning) }
            index = next[index]
        }
        return meanings
    }

    // MARK: Meaning

    private static func command(_ meanings: [Meaning]) -> BellaCommand? {
        guard !meanings.isEmpty else { return nil }
        var pieces = Set<FurnitureCategory>(), actions = Set<CatAction>()
        var play = false, treat = false, comeHere = false, come = false, unsupported = false
        for meaning in meanings {
            switch meaning {
            case .furniture(let category): pieces.insert(category)
            case .action(let action): actions.insert(action)
            case .play: play = true
            case .treat: treat = true
            case .comeHere: comeHere = true
            case .come: come = true
            case .unsupported: unsupported = true
            case .filler, .speaker: break
            }
        }
        guard pieces.count <= 1, actions.count <= 1 else { return nil }
        let piece = pieces.first, action = actions.first
        if unsupported {
            return piece == nil && action == nil && !play && !treat && !comeHere ? .unsupported : nil
        }
        if treat {
            // "吃零食", "过来吃零食": the treat is the whole story. Not with furniture or other actions.
            return piece == nil && (action == nil || action == .eat) && !play ? .play(treat: true) : nil
        }
        if play {
            guard action == nil else { return nil }
            if piece == nil || piece == .toy { return .play(treat: false) }
            return comeHere ? nil : .visit(action: .play, target: piece)
        }
        if comeHere {
            return piece == nil && action == nil ? .comeHere : nil
        }
        if let action { return .visit(action: action, target: piece) }
        if let piece { return .visit(action: CatRoutine.action(on: piece), target: piece) }
        return come ? .comeHere : nil
    }
}
