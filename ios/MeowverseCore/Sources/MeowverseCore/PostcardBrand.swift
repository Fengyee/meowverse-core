/// The letterhead of the room postcard (`RoomPostcard.drawBrand` in the app): the app's name in the
/// interface language. Owner: the Chinese name 喵空间 is used everywhere in Chinese; English and
/// every other interface keep Meowverse. The app draws `.latin` in Georgia and `.chinese` in the
/// title face (ZCOOL KuaiLe), which covers all three characters.
public enum PostcardBrand: Sendable, Equatable {
    case latin
    case chinese

    /// `languageCode` is the interface localization in use (`Bundle.main.preferredLocalizations`).
    public static func forInterface(languageCode: String) -> PostcardBrand {
        languageCode.hasPrefix("zh") ? .chinese : .latin
    }

    public var words: String {
        switch self {
        case .latin: "Meowverse"
        case .chinese: "喵空间"
        }
    }
}
