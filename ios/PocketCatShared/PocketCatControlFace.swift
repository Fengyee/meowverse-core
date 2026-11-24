import Foundation

/// The three Control Center controls as the user finds them there: the symbol (in
/// `ControlSymbols.xcassets`, built into both the app and the widget extension) and the name.
/// The widget extension draws the controls with these; the app's tour draws them in chapter 12's
/// second page (docs/onboarding/VISUAL.md §17.3, 12.6).
enum PocketCatControlFace: CaseIterable, Sendable {
    case company, camera, library

    /// `Image(symbol)`: a custom SF Symbol, templated.
    var symbol: String {
        switch self {
        case .company: "pawprint.cat.fill"
        case .camera: "camera.paw"
        case .library: "photo.on.rectangle.paw"
        }
    }

    /// The name in the control gallery, which is also what a search there finds.
    var title: LocalizedStringResource {
        switch self {
        case .company: LocalizedStringResource("Keep Me Company", table: "PocketCat")
        case .camera: LocalizedStringResource("Take Photo", table: "PocketCat")
        case .library: LocalizedStringResource("Add from Photos", table: "PocketCat")
        }
    }
}
