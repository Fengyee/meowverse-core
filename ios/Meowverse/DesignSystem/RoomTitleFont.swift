import CoreText
import MeowverseCore
import SwiftUI
import UIKit

/// The face of room and panel titles (art/ui/OVERLAY_SPEC.md §4, option C).
///
/// SF Pro Rounded Semibold draws Latin letters, digits and `’`. ZCOOL KuaiLe, bundled and listed in
/// `UIAppFonts`, is cascaded in for Han characters. A title with any Han character KuaiLe lacks is drawn
/// wholly in the system face (SF Pro Rounded + PingFang), so one title never mixes two Han styles.
/// Only titles use this face. Buttons, labels and body text keep the system rounded face.
enum RoomTitleFont {
    static let cuteFaceName = "ZCOOLKuaiLe-Regular"

    /// KuaiLe's character set, read once. Empty if the font did not register, so every title with
    /// Han characters falls back to the system face instead of a patchwork.
    private static let cuteCharacters: CharacterSet = {
        let font = CTFontCreateWithName(cuteFaceName as CFString, 12, nil)
        // CoreText substitutes another font for a name it does not know.
        guard CTFontCopyPostScriptName(font) as String == cuteFaceName else { return CharacterSet() }
        return CTFontCopyCharacterSet(font) as CharacterSet
    }()

    /// A set lookup per scalar of a name of at most 20 characters: cheap enough for `body`.
    static func face(for title: String) -> RoomTitleFace {
        RoomTitleFace.choose(for: title) { cuteCharacters.contains($0) }
    }

    /// `size` at the default text size, scaled like `style` and capped at `maximum` points.
    static func pointSize(_ size: CGFloat, relativeTo style: UIFont.TextStyle, maximum: CGFloat,
                          typeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        return min(maximum, UIFontMetrics(forTextStyle: style).scaledValue(for: size, compatibleWith: traits))
    }

    static func uiFont(for title: String, pointSize: CGFloat) -> UIFont {
        let system = UIFont.systemFont(ofSize: pointSize, weight: .semibold)
        var descriptor = system.fontDescriptor.withDesign(.rounded) ?? system.fontDescriptor
        if face(for: title) == .cute {
            descriptor = descriptor.addingAttributes([
                .cascadeList: [UIFontDescriptor(name: cuteFaceName, size: pointSize)],
            ])
        }
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    /// The room title on the plate: 21 pt at the default size, scaled like `.title3`, capped at the
    /// largest non-accessibility size (25 pt). Panel titles pass 24 / `.title2` / 30.
    static func font(for title: String, size: CGFloat = 21, relativeTo style: UIFont.TextStyle = .title3,
                     maximum: CGFloat = 25, typeSize: DynamicTypeSize) -> Font {
        Font(uiFont(for: title, pointSize: pointSize(size, relativeTo: style, maximum: maximum, typeSize: typeSize)))
    }
}
