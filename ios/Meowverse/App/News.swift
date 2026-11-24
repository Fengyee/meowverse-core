import SwiftUI

/// What 公告 says. Ships with the app: nothing is fetched. When a build ships, move what it brought
/// to the top of `features` and take it out of `plans`.
enum News {
    struct Item: Identifiable {
        let id: String
        let title: LocalizedStringResource
        let note: LocalizedStringResource
    }

    /// Only what is in the build that carries this list.
    static let features: [Item] = [
        Item(id: "furniture-sets",
             title: .init("三套新家具", table: "News"),
             note: .init("鎏金宫廷、江南雅居、樱庭和室。三套家具各有配套的房间主题。", table: "News")),
        Item(id: "tour",
             title: .init("使用导览", table: "News"),
             note: .init("Bella 带你认识这个家。想再看一遍：设置 › 使用导览。", table: "News")),
    ] + talk + [
        Item(id: "cats",
             title: .init("八只猫和它们的角色卡", table: "News"),
             note: .init("在猫咪管理的猫咪模型里点一只，先看看它是谁，再决定要不要换。", table: "News")),
        Item(id: "companion",
             title: .init("小组件和控制中心", table: "News"),
             note: .init("把像素小猫放到主屏幕和锁屏，或者从控制中心让它陪你一会儿。", table: "News")),
        Item(id: "quality",
             title: .init("画质三档", table: "News"),
             note: .init("在设置里选自动、高、中或低。", table: "News")),
    ]

    /// Talk to Bella is only in a `MEOWVERSE_TALK_TO_BELLA=YES` build (FeatureFlags.talkToBella).
    #if MEOWVERSE_TALK_TO_BELLA
    private static let talk: [Item] = [
        Item(id: "talk",
             title: .init("和猫咪说话", table: "News"),
             note: .init("点房间角落的猫咪头像，说“去沙发上躺着”或“过来”。识别只在这台设备上进行，不录音。", table: "News")),
    ]
    #else
    private static let talk: [Item] = []
    #endif

    /// Only what the owner has put on the list. No dates, no prices, no promises about either.
    static let plans: [Item] = [
    ]

    /// The News button's hint: only the groups the panel shows (`RoomNewsPanel`).
    static var hint: String {
        switch (plans.isEmpty, Credits.shown.isEmpty) {
        case (false, false): String(localized: "新功能、正在计划和鸣谢", table: "News")
        case (true, false): String(localized: "新功能和鸣谢", table: "News")
        case (false, true): String(localized: "新功能和正在计划", table: "News")
        case (true, true): String(localized: "新功能", table: "News")
        }
    }
}
