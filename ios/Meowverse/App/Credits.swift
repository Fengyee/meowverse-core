import MeowverseCore
import SwiftUI

/// The names 关于与隐私 thanks. Thanks only: no amounts, links or asking (App Review 3.1.1).
enum Credits {
    /// One line per sponsor (owner, 2026-11-22). With `name: nil` they show as 「<猫名>的铲屎官」.
    /// Once someone has given a name and agreed to its being public, change that line's nil to
    /// `.init(zh: "…", en: "…")`; either language may be left out. Never make a name up.
    static let sponsors: [Sponsor] = [
        Sponsor(name: nil, supports: [.cat(id: "bella")]),
        Sponsor(name: nil, supports: [.cat(id: "airou")]),
        Sponsor(name: nil, supports: [.cat(id: "zhumi")]),
        Sponsor(name: nil, supports: [.cat(id: "siamese")]),
        Sponsor(name: nil, supports: [.cat(id: "ragdoll")]),
        Sponsor(name: nil, supports: [.cat(id: "black")]),
        Sponsor(name: nil, supports: [.cat(id: "white")]),
        Sponsor(name: nil, supports: [.cat(id: "sphynx")]),
    ]

    /// The testers, as they agreed to be shown. While this is empty, 测试 does not show at all.
    static let testers: [String] = []

    /// Omucat is credited for the idea in the public repository's CONTRIBUTORS.md.
    static let thanks: [CreditsRoll.Group] = [
        .init(role: .idea, names: ["Omucat"]),
        .init(role: .testing, names: testers),
    ]

    static let shipped = CreditsRoll(sponsors: sponsors, thanks: thanks)

    /// What the pages show: `shipped`, or in DEBUG the made-up sponsors a test asks for with
    /// `-MeowverseSampleSponsors none|one|several`.
    static var shown: CreditsRoll {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-MeowverseSampleSponsors"), arguments.indices.contains(index + 1) {
            switch arguments[index + 1] {
            case "none": return CreditsRoll(sponsors: [], thanks: thanks)
            case "one": return CreditsRoll(sponsors: sampleOne, thanks: thanks)
            case "several": return CreditsRoll(sponsors: sample.sponsors, thanks: thanks)
            default: break
            }
        }
        #endif
        return shipped
    }

    #if DEBUG
    private static let sampleOne = [
        Sponsor(name: .init(zh: "小橘子的家", en: "Tangerine House"), // not-localized: made-up sample name in both languages
                supports: [.feature(.severalCats), .feature(.severalRooms), .cat(id: "black")]),
    ]

    /// Made-up names for the review gallery (`-MeowverseOverlayGallery credits`) and the tests,
    /// never shipped: both languages, a long one, English only, and the two nicknames.
    static let sample = CreditsRoll(
        sponsors: sampleOne + [
            Sponsor(name: .init(en: "Captain Whiskers and the Very Long-Named Household of Seven Tabbies"), supports: [.feature(.severalCats)]),
            Sponsor(name: .init(en: "Mochi & Bean"), supports: [.feature(.severalCats), .cat(id: "bella")]),
            Sponsor(name: nil, supports: [.cat(id: "airou")]),
            Sponsor(name: nil, supports: []),
        ],
        thanks: [.init(role: .idea, names: ["Omucat"]), .init(role: .testing, names: ["Pudding", "阿福", "Sesame"])] // not-localized: made-up sample names
    )
    #endif

    // MARK: In words

    /// A sponsor as written in the interface language.
    static func name(of sponsor: Sponsor) -> String {
        switch sponsor.credit(chinese: AppLanguage.isChinese, catName: catName) {
        case .named(let name): name
        case .catsHuman(let cat): String(localized: "\(cat)的铲屎官", table: "About")
        case .someonesHuman: String(localized: "一位铲屎官", table: "About")
        }
    }

    /// Several names or things in one line.
    static func list(_ parts: [String]) -> String {
        parts.joined(separator: AppLanguage.isChinese ? "、" : ", ") // not-localized: list separator
    }

    /// 「支持了：露娜、多只猫咪」, or nil for someone who supported nothing in particular.
    static func supported(by sponsor: Sponsor) -> String? {
        let things = sponsor.supports.compactMap { target -> String? in
            switch target {
            case .cat(let id): catName(id)
            case .feature(.severalRooms): String(localized: "多个房间", table: "About")
            case .feature(.severalCats): String(localized: "多只猫咪", table: "About")
            }
        }
        return things.isEmpty ? nil : String(localized: "支持了：\(list(things))", table: "About")
    }

    private static func catName(_ id: String) -> String? {
        CatProfiles.profile(for: id)?.name(chinese: AppLanguage.isChinese)
    }
}

extension CreditsRoll.Role {
    var title: LocalizedStringResource {
        switch self {
        case .idea: .init("创意", table: "About")
        case .testing: .init("测试", table: "About")
        }
    }
}

extension ThirdPartyNotice {
    /// What it does in Meowverse, for the row under the name.
    var use: LocalizedStringResource {
        switch id {
        case .dinov2: .init("识别照片像哪件家具，在这台设备上运行", table: "About")
        case .hunyuan3D: .init("从参考图生成内置猫的模型", table: "About")
        case .zcoolKuaiLe: .init("房间和面板标题里的中文字体", table: "About")
        case .kenneyFurniture: .init("一部分家具模型", table: "About")
        case .threeDAssets: .init("一部分猫咪家具模型", table: "About")
        case .fripouille: .init("Bella 早期版本的模型模板", table: "About")
        }
    }

    /// The longer note at the top of its page.
    var detail: LocalizedStringResource {
        switch id {
        case .dinov2:
            .init("找出照片像房间里的哪件家具，用的是 Meta AI 的 DINOv2 模型（ViT-B/14，带 register），在这台设备上运行。它按 Apache License 2.0 授权，版权归 Meta Platforms, Inc. 及其关联公司。喵空间把它转换成了 Core ML 格式（8 位权重）。", table: "About")
        case .hunyuan3D:
            .init("内置猫的模型用腾讯混元 3D 从参考图生成，再由喵空间修整、绑定骨骼并制作动作。混元 3D 按 Tencent Hunyuan 3D Community License 授权。喵空间与腾讯没有关联，也不受腾讯赞助或认可。", table: "About")
        case .zcoolKuaiLe:
            .init("房间和面板标题里的中文用的是站酷快乐体（ZCOOL KuaiLe），未经修改随 App 发布，按 SIL Open Font License 1.1 授权。", table: "About")
        case .kenneyFurniture:
            .init("一部分家具来自 Kenney 的 Furniture Kit，按 CC0 1.0 放入公有领域。喵空间把原来的 OBJ 模型转换成 App 用的格式，没有改动几何形状。", table: "About")
        case .threeDAssets:
            .init("一部分猫咪家具来自 3D Assets 的宠物素材，按 CC0 1.0 放入公有领域。发布方说明这些原始模型是用 AI 工具制作的。喵空间为 Bella 调整了它们。", table: "About")
        case .fripouille:
            .init("Bella 早期版本的模型改编自 guillaume bolis 的“3d modelling my cat: Fripouille”（2020），原模型和贴图按 CC BY 4.0 授权。", table: "About")
        }
    }

    var licenseText: String? {
        licenseFile
            .flatMap { Bundle.main.url(forResource: $0, withExtension: "txt") }
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}
