import SwiftUI
import UIKit

/// A 40 pt picture of the app's icon (VISUAL §17.8 item 3). An alternate icon cannot be read as
/// an image, so each has a copy in `Assets.xcassets/AppIconPreview/`, written by
/// `scripts/ios/app-icon-previews.py`: `AppIconPreview` for the main icon,
/// `AppIconPreview-<season>` for `AppIcon-<season>`.
enum AppIconPreview {
    /// The icon on the Home Screen now. It follows the seasons (`AppIconSwitcher`); read again
    /// each time a view asks, since `alternateIconName` is not observable.
    @MainActor
    static var current: Image { image(forAlternate: UIApplication.shared.alternateIconName) }

    /// The preview for an alternate icon name (`AppIcon-spring-sakura`), or the main icon's for nil
    /// and for a name without a preview.
    static func image(forAlternate name: String?) -> Image {
        Image(uiImage: uiImage(forAlternate: name) ?? UIImage())
    }

    static func uiImage(forAlternate name: String?) -> UIImage? {
        if let name, name.hasPrefix("AppIcon-"),
           let image = UIImage(named: "AppIconPreview-" + name.dropFirst("AppIcon-".count)) {
            return image
        }
        return UIImage(named: "AppIconPreview")
    }
}
