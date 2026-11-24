/// Where the room caption ("Kitty 在…坐着", "Kitty is sitting …") says Bella rests on a piece,
/// chosen from the site's built-in Chinese label.
///
/// A site label is written for the interaction menu. Inside a caption that also names the piece,
/// some round 10 labels said the piece twice ("在纸箱的纸箱里", "on the in the box of the cardboard
/// box") or named an activity ("坐垫上打盹"). Those get a caption place here; every other label
/// keeps the wording it always had (`CaptionPlaceTests`).
public enum CaptionPlace: Equatable, Sendable {
    /// The site is the inside of the piece itself: "Kitty 在纸箱里坐着", "Kitty is sitting in the
    /// cardboard box". Resting actions only; any other action uses the site label.
    case insidePiece
    /// A part of the piece, by its built-in name (a CatalogNames key, translated like a label):
    /// "Kitty 在浴缸猫窝的软垫上窝着", "Kitty is loafing on the cushion of the bathtub cat bed".
    case part(String)

    /// Round 10's labels only; add a new round's labels here when they would read badly.
    public static let overrides: [String: CaptionPlace] = [
        "纸箱里": .insidePiece, // not-localized: built-in Chinese catalog site labels
        "跑轮里": .insidePiece, // not-localized: built-in Chinese catalog site labels
        "箱门口探头": .part("门洞"), // not-localized: built-in Chinese catalog site labels
        "坐垫上打盹": .part("坐垫"), // not-localized: built-in Chinese catalog site labels
        "浴缸窝里": .part("软垫"), // not-localized: built-in Chinese catalog site labels
    ]

    public static func forSite(_ label: String) -> CaptionPlace {
        overrides[label] ?? .part(label)
    }
}
