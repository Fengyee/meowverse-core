import MeowverseCore
import SwiftUI

extension FurnitureCategory {
    var title: String {
        switch self {
        case .chair: String(localized: "椅子")
        case .stool: String(localized: "凳子")
        case .bench: String(localized: "长凳")
        case .table: String(localized: "桌子")
        case .bed: String(localized: "床")
        case .sofa: String(localized: "沙发")
        case .scratcher: String(localized: "猫抓板和抓柱")
        case .catTree: String(localized: "猫爬架")
        case .platform: String(localized: "小台子")
        case .hideout: String(localized: "藏身窝")
        case .toy: String(localized: "逗猫玩具")
        case .litterBox: String(localized: "猫砂盆")
        case .windowPerch: String(localized: "窗台")
        case .water: String(localized: "猫咪饮食与猫草")
        case .photoBoard: String(localized: "照片板")
        // Household categories (round 7): their names live in the catalogue names table.
        case .bookcase: String(localized: "书架", table: "CatalogNames")
        case .sideboard: String(localized: "餐边柜", table: "CatalogNames")
        case .mediaConsole: String(localized: "影音柜", table: "CatalogNames")
        case .writingDesk: String(localized: "书桌", table: "CatalogNames")
        case .vanity: String(localized: "梳妆台", table: "CatalogNames")
        case .coatRack: String(localized: "衣帽架", table: "CatalogNames")
        case .floorLamp: String(localized: "落地灯", table: "CatalogNames")
        case .roomDivider: String(localized: "屏风", table: "CatalogNames")
        case .plantStand: String(localized: "花架", table: "CatalogNames")
        case .fireplace: String(localized: "壁炉", table: "CatalogNames")
        }
    }

    var symbol: String {
        switch self {
        case .chair: "chair"
        case .stool: "cylinder"
        case .bench: "rectangle.split.3x1"
        case .table: "table.furniture"
        case .bed: "bed.double"
        case .sofa: "sofa"
        case .scratcher: "scribble"
        case .catTree: "stairs"
        case .platform: "square.stack.3d.up"
        case .hideout: "house"
        case .toy: "tennisball"
        case .litterBox: "tray"
        case .windowPerch: "window.horizontal"
        case .water: "drop"
        case .photoBoard: "photo.artframe"
        case .bookcase: "books.vertical"
        case .sideboard: "cabinet"
        case .mediaConsole: "tv"
        case .writingDesk: "studentdesk"
        case .vanity: "comb"
        case .coatRack: "hanger"
        case .floorLamp: "lamp.floor"
        case .roomDivider: "square.split.1x2"
        case .plantStand: "leaf"
        case .fireplace: "fireplace"
        }
    }
}

extension Finish {
    var title: String {
        switch self {
        case .original: String(localized: "原色")
        case .cream: String(localized: "奶油")
        case .sage: String(localized: "鼠尾草绿")
        case .blue: String(localized: "雾蓝")
        case .apricot: String(localized: "杏桃")
        case .blush: String(localized: "蔷薇")
        case .lavender: String(localized: "薰衣草")
        }
    }

    var swatch: Color {
        switch self {
        case .original: Color(red: 0.72, green: 0.56, blue: 0.40)
        case .cream: Color(red: 0.93, green: 0.88, blue: 0.78)
        case .sage: Color(red: 0.62, green: 0.72, blue: 0.62)
        case .blue: Color(red: 0.56, green: 0.67, blue: 0.80)
        // The presets' swatches in art/furniture/palettes/presets.json.
        case .apricot: Color(red: 0.949, green: 0.706, blue: 0.561)
        case .blush: Color(red: 0.922, green: 0.718, blue: 0.745)
        case .lavender: Color(red: 0.741, green: 0.690, blue: 0.855)
        }
    }
}

extension PhotoRecord {
    /// The capture day when the photo carries one; otherwise says it is unknown. Never guessed.
    var captureLine: String { Wording.captureLine(day: captureDate, source: captureDateSource) }
}

/// The language the interface is shown in, which is not always the device language: with no
/// matching localisation the app falls back to English (the development region).
nonisolated enum AppLanguage {
    static let code = Bundle.main.preferredLocalizations.first ?? "en"
    static let isChinese = code.hasPrefix("zh")

    /// For dates and numbers inside our own sentences: the user's locale when it is in the
    /// interface language (keeping their region's date order), otherwise that language's default.
    static let locale: Locale = {
        let ui = Locale(identifier: code)
        return Locale.current.language.languageCode == ui.language.languageCode ? .current : ui
    }()
}

extension PhotoFurniture {
    /// The name to show. A piece still carrying its style's built-in name shows it in the
    /// interface language; a name the user typed is shown as typed.
    var shownName: String { Wording.catalogName(displayName) }
}

extension CatalogModel {
    var title: String { Wording.catalogName(label) }
}

extension CatalogModel.Site {
    var title: String { Wording.catalogName(label) }
}

extension CatPack {
    /// A built-in cat shows the name on her character card (`CatProfiles`), in the interface
    /// language; an imported cat shows the name in its manifest.
    var displayTitle: String {
        guard origin == .builtIn, let profile else { return manifest.name }
        return profile.name(chinese: AppLanguage.isChinese)
    }

    /// The character card of a built-in cat; nil for an imported one.
    var profile: CatProfile? {
        origin == .builtIn ? CatProfiles.profile(for: id) : nil
    }
}

enum Wording {
    /// The cat's name at the start of a Chinese sentence: a name in Latin letters keeps a space
    /// before the Chinese text ("Bella 在门口坐着"), a Chinese name does not ("团子在门口坐着").
    /// Other languages put their own spaces in the sentence, so the name comes back unchanged.
    static func subject(_ catName: String) -> String {
        guard AppLanguage.isChinese, let last = catName.unicodeScalars.last, last.isASCII else { return catName }
        return catName + " "
    }

    /// The cat's name between Chinese text ("选一张 Bella 的照片", "选一张团子的照片").
    static func inline(_ catName: String) -> String {
        subject(object(catName))
    }

    /// The cat's name after Chinese text ("留给 Bella", "留给团子").
    static func object(_ catName: String) -> String {
        guard AppLanguage.isChinese, let first = catName.unicodeScalars.first, first.isASCII else { return catName }
        return " " + catName
    }

    /// Whole sentences one after another: Chinese needs nothing between them, other languages a space.
    static func sentences(_ parts: String...) -> String {
        parts.joined(separator: AppLanguage.isChinese ? "" : " ")
    }

    /// A name in quotation marks: 「沙发」, “Sofa”.
    static func quoted(_ name: String) -> String {
        String(localized: "「\(name)」")
    }

    /// Furniture names in quotation marks, as a list.
    static func quotedNames(_ items: [PhotoFurniture]) -> String {
        items.map { quoted($0.shownName) }.joined(separator: String(localized: "、"))
    }

    /// Short phrases read out as one line.
    static func phrases(_ parts: [String]) -> String {
        parts.joined(separator: String(localized: "，"))
    }

    // MARK: Names that come from the catalog

    /// Built-in names (furniture styles, resting places) are stored and compared in Chinese and
    /// translated only here, on the way to the screen. Anything else, such as a name the user
    /// typed, is not in the table and comes back unchanged.
    static func catalogName(_ name: String) -> String {
        builtInName(name) ?? name
    }

    private static func builtInName(_ name: String) -> String? {
        let missing = "\u{1}"
        let found = Bundle.main.localizedString(forKey: name, value: missing, table: "CatalogNames")
        return found == missing ? nil : found
    }

    /// The art credits (ATTRIBUTION.txt) start some lines with a built-in style name
    /// ("木椅 — 3D Assets — …"); that name follows the interface language, the rest is English.
    static func credits(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard let dash = line.range(of: " — ") else { return String(line) }
            return catalogName(String(line[..<dash.lowerBound])) + line[dash.lowerBound...]
        }.joined(separator: "\n")
    }

    /// A furniture name inside a sentence. English says "the wooden chair" for a built-in name
    /// and leaves the user's own name as typed; Chinese uses the name as it is.
    static func mention(_ item: PhotoFurniture) -> String {
        mention(displayName: item.displayName)
    }

    /// The same for a stored furniture name that does not come with its piece (a reminder's).
    static func mention(displayName: String) -> String {
        builtInName(displayName).map(inSentence) ?? displayName
    }

    /// One of our own names (a toy, a resting place) inside a sentence: "the felt mouse".
    static func inSentence(_ ownName: String) -> String {
        let name = AppLanguage.isChinese ? ownName : ownName.lowercased(with: AppLanguage.locale)
        return String(localized: "name-in-sentence", defaultValue: "\(name)",
                      comment: "One of the app's own names used inside a sentence; the argument is already lower-cased. English adds 'the'.")
    }

    /// A site can already say where the cat is (for example, “on the quilt”).
    static func on(_ name: String) -> String {
        if AppLanguage.isChinese, ["上", "里", "内", "底下", "中间", "左边", "右边", "前", "口", "阴凉处", "床尾", "侧边", "下方"].contains(where: name.hasSuffix) { return name } // not-localized: Chinese locative endings
        return String(localized: "\(name)上")
    }

    static func inside(_ name: String) -> String {
        if AppLanguage.isChinese, name.hasSuffix("里") || name.hasSuffix("内") { return name } // not-localized: Chinese locative endings
        return String(localized: "\(name)里")
    }

    /// A few site labels in the interaction menu describe an activity; a caption needs the place.
    /// Round 10's labels go through `CaptionPlace` in both languages; the Chinese-only cases below
    /// are older and stay as they are.
    static func captionSite(_ label: String) -> String {
        if case .part(let part) = CaptionPlace.forSite(label), part != label {
            return inSentence(catalogName(part))
        }
        if AppLanguage.isChinese {
            switch label { // not-localized: built-in Chinese catalog site labels
            case "沿座垫横卧": return "座垫" // not-localized: Chinese caption wording
            case "软垫午睡": return "软垫" // not-localized: Chinese caption wording
            case "磨爪": return "抓面" // not-localized: Chinese caption wording
            case "台下阴凉": return "阴凉处" // not-localized: Chinese caption wording
            case "逗毛球": return "毛球旁" // not-localized: Chinese caption wording
            case "拍橡果": return "橡果旁" // not-localized: Chinese caption wording
            default: break
            }
        }
        return inSentence(catalogName(label))
    }

    static func captureLine(day: String?, source: CaptureDateSource) -> String {
        // Read and shown in the day calendar: a day whose local midnight was skipped is still that day.
        guard source != .unknown, let text = dayTitle(day) else { return String(localized: "拍摄日期未知") }
        return source == .exif ? String(localized: "拍摄于 \(text)（来自照片信息）") : String(localized: "拍摄于 \(text)（你填写的）")
    }

    /// How many photos a piece holds. A piece placed without one says so rather than "0 张".
    /// `syncing`: photos iCloud sync says it has on another device that are not here yet; those
    /// are on their way, never "no photos yet".
    static func photoCountLine(_ item: PhotoFurniture, syncing: Int = 0) -> String {
        if !item.sources.isEmpty { return String(localized: "\(item.sources.count) 张照片") }
        return syncing > 0 ? String(localized: "照片还在同步") : String(localized: "还没有照片")
    }

    /// What a furniture row says under the name: kind, photos, when one was last added,
    /// (when asked) that the piece is put away, and that it is locked. A time that was never recorded is left out.
    /// `room` names the room the piece stands in, when there is more than one room to tell apart.
    static func furnitureLine(_ item: PhotoFurniture, category: FurnitureCategory?, lastPhotoAdded: Date?, stored: Bool,
                              room: String? = nil, syncing: Int = 0) -> String {
        var parts: [String] = []
        if let category { parts.append(category.title) }
        parts.append(photoCountLine(item, syncing: syncing))
        if let lastPhotoAdded {
            let when = lastPhotoAdded.formatted(Date.RelativeFormatStyle(presentation: .named, locale: AppLanguage.locale))
            parts.append(String(localized: "上次添照片：\(when)"))
        }
        if stored { parts.append(String(localized: "在收纳箱")) }
        if let room { parts.append(room) }
        if item.isLocked { parts.append(String(localized: "已锁定")) }
        return parts.joined(separator: " · ")
    }

    /// The confirmation text for deleting several photos at once.
    static func deletionMessage(loss: PhotoLoss, onFurniture: Int, furniture: Int) -> String {
        var base = sentences(String(localized: "删除的是喵空间里保存的照片和它们的便签，删除后无法撤销。"), originalsLine(loss))
        if onFurniture > 0 {
            base = sentences(String(localized: "其中 \(onFurniture) 张在家具里，涉及 \(furniture) 件家具。家具都会保留，只是不再包含这些照片。"), base)
        }
        return ([base] + reachLines(loss)).joined(separator: "\n")
    }

    /// The promise only when Photos confirmed every original; otherwise how many may be the only copy.
    static func originalsLine(_ loss: PhotoLoss) -> String {
        loss.unconfirmed == 0
            ? String(localized: "系统相册里的原片不受影响。")
            : String(localized: "其中 \(loss.unconfirmed) 张没能确认系统相册里还有原片，可能是唯一一份。")
    }

    /// Where else a deletion reaches.
    static func reachLines(_ loss: PhotoLoss) -> [String] {
        var lines: [String] = []
        if loss.onNewerPieces > 0 {
            lines.append(String(localized: "有 \(loss.onNewerPieces) 张在更新版本的家具上，这台设备暂时显示不了那些家具。删除后，它们也不再包含这些照片。"))
        }
        if loss.syncing { lines.append(String(localized: "iCloud 同步开着：打开了同步的其他设备上也会删除。")) }
        if loss.backingUp { lines.append(String(localized: "备份到 iCloud 云盘开着：下一次备份里也不会再有删掉的照片。")) }
        return lines
    }

    static func likelihood(_ confidence: Double) -> String {
        switch confidence {
        case 0.6...: String(localized: "把握较大")
        case 0.3...: String(localized: "有些把握")
        default: String(localized: "不太确定")
        }
    }

    /// "本机识别（DINOv2）" or "本机识别（Apple Vision）" for what `analyzer` made; the plain
    /// header when nothing has been made yet or by a test stand-in. Model names stay untranslated.
    static func recognitionHeader(analyzer: String?) -> String {
        guard let engine = analyzer.flatMap(KnownAnalyzer.engineName(of:)) else { return String(localized: "本机识别") }
        return String(localized: "本机识别（\(engine)）")
    }

    /// How the photo came to be on the piece (`AppState.provenance(of:)`), in words. nil for a
    /// confirmed suggestion: `SuggestedFilingMark` says that one, with its own symbol.
    static func sourceLine(_ provenance: FilingProvenance, category: FurnitureCategory?) -> String? {
        switch provenance {
        case .recognised(.remote): String(localized: "网页版云端分析识别为\(category?.title ?? String(localized: "家具"))，由你确认")
        case .recognised: String(localized: "本机识别为\(category?.title ?? String(localized: "家具"))，由你确认")
        case .suggestedBySimilarPhotos: nil
        case .handPicked: String(localized: "由你手动选择")
        case .demo: String(localized: "演示数据")
        }
    }

    /// The symbol beside `sourceLine`: on-device, cloud (web backups only), suggestion, manual
    /// and demo data never share one.
    static func sourceSymbol(_ provenance: FilingProvenance) -> String {
        switch provenance {
        case .recognised(.remote): "cloud"
        case .recognised: "iphone"
        case .suggestedBySimilarPhotos: SuggestedFilingMark.symbol
        case .handPicked: "hand.tap"
        case .demo: "testtube.2"
        }
    }

    /// Why a `.meowcat` file was not imported. The cat in the room is never changed by a refusal.
    static func catPackFailure(_ error: any Error) -> String {
        let reason: String
        switch error as? CatPackError {
        case .notArchive: reason = String(localized: "这个文件不是可以读取的猫咪模型（.meowcat）。")
        case .renderBudgetExceeded: reason = String(localized: "模型超出房间渲染上限。请缩小贴图、简化网格或减少动画关键帧后重新导入。")
        case .tooLarge: reason = String(localized: "文件太大：单个文件最多 \(CatPackLimits.standard.maxFileBytes / 1_048_576) MB，合计最多 \(CatPackLimits.standard.maxTotalBytes / 1_048_576) MB。")
        case .unsafeName: reason = String(localized: "压缩包里有不安全的文件名。")
        case .nestedFolder: reason = String(localized: "模型文件要直接放在压缩包的最外层，不能放在文件夹里。")
        case .missingManifest: reason = String(localized: "压缩包里没有 cat.json 清单。")
        case .badManifest, .invalidName, .invalidFileName: reason = String(localized: "cat.json 清单的内容不完整或写法不对。")
        case .unsupportedFormat: reason = String(localized: "这不是喵空间的猫咪模型清单。")
        case .newerVersion(let version): reason = String(localized: "它是更新版本的喵空间制作的（格式第 \(version) 版），请先更新 App。")
        case .invalidID: reason = String(localized: "清单里的编号只能用小写字母、数字和连字符，最多 40 个字。")
        case .missingFile(let name): reason = String(localized: "缺少清单里列出的文件 \(name)。")
        case .badMesh(let name): reason = String(localized: "姿态网格 \(name) 读不出来或数据不一致。")
        case .badGaits: reason = String(localized: "地面步态文件读不出来或数据不一致。")
        case .jointCount(let count): reason = String(localized: "骨骼需要 \(CatGaitRig.jointCount) 个关节，这个模型有 \(count) 个。")
        case .badTexture(let name): reason = String(localized: "贴图 \(name) 不是可以读取的 PNG、JPEG 或 WebP 图片，或边长超过 \(CatPackValidator.maxTextureEdge) 像素。")
        case .badInspect: reason = String(localized: "高精度模型不是有效的 USDZ 文件。")
        case .badPreview: reason = String(localized: "缩略图不是可以读取的图片。")
        case .reservedID: reason = String(localized: "它的编号和内置的猫咪相同，请在清单里换一个编号。")
        case .writeFailed: return String(localized: "没能保存这个猫咪模型。原来的模型都没有变化，可以再试一次。")
        case .notFound: return String(localized: "找不到这个猫咪模型，可能已经被删除。")
        case nil: reason = String(localized: "没能读取这个文件。")
        }
        return String(localized: "没有导入：\(reason)已有的猫咪模型没有变化。")
    }
}

extension Color {
    /// Secondary text that still clears 4.5:1 on our light and dark backgrounds.
    static let subtle = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.76, alpha: 1) : UIColor(white: 0.33, alpha: 1) })
    /// Warning text with enough contrast in both appearances.
    static let caution = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 1.0, green: 0.72, blue: 0.35, alpha: 1) : UIColor(red: 0.62, green: 0.30, blue: 0.0, alpha: 1) })
}
