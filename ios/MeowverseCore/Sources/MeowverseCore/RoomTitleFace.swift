/// Which face draws a room or panel title (art/ui/OVERLAY_SPEC.md §4).
///
/// `cute` is SF Pro Rounded for Latin with ZCOOL KuaiLe cascaded in for Han characters. KuaiLe covers
/// GB2312 only, so a name with one Han character outside it would mix KuaiLe and PingFang strokes in
/// one title, which looks broken. Such a title is drawn wholly in `system` (SF Pro Rounded + PingFang).
public enum RoomTitleFace: Sendable, Equatable {
    case cute
    case system

    /// Han ideographs decide the face. Kana, Hangul, emoji, Latin and punctuation do not: the
    /// system draws them the same way in either face.
    public static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isIdeographic
    }

    /// - Parameter cuteFaceHas: whether the bundled cute face has a glyph for a scalar (its
    ///   character set, read once). Pass `{ _ in false }` when the font is unavailable.
    public static func choose(for title: String, cuteFaceHas: (Unicode.Scalar) -> Bool) -> RoomTitleFace {
        title.unicodeScalars.allSatisfy { !isHan($0) || cuteFaceHas($0) } ? .cute : .system
    }
}
