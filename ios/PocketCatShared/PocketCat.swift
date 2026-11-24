import ActivityKit
import SwiftUI

nonisolated enum PocketCatLink {
    static func url(for hostBundleID: String) -> URL? {
        URL(string: hostBundleID + "://companion")
    }
}

extension PocketCatAttributes: ActivityAttributes {}

nonisolated enum PocketCatCopy {
    static let title = LocalizedStringResource("Keep me company", table: "PocketCat")
    static let change = LocalizedStringResource("Change expression", table: "PocketCat")
    static let end = LocalizedStringResource("End company", table: "PocketCat")
}

/// Which drawing of the same tabby: the head (`pocket-<mood>`, 20 px, for the 20 pt compact and
/// minimal island) or the whole cat (`pocket-figure-<mood>`, 32 px, for the 32 pt expanded
/// island and Lock Screen). Both are exactly 2× or 3× in those slots and carry a light 1 px
/// halo so the dark outline reads on the black island. Heads: art/ui/source/pocket-cat-portraits.py.
enum PocketCatArt {
    case face, figure

    func imageName(_ mood: PocketCatMood) -> String {
        switch self {
        case .face: "pocket-" + mood.rawValue
        case .figure: "pocket-figure-" + mood.rawValue
        }
    }

    var pixels: CGFloat {
        switch self {
        case .face: 20
        case .figure: 32
        }
    }
}

struct PocketCatPortrait: View {
    @Environment(\.displayScale) private var displayScale
    let mood: PocketCatMood
    let size: CGFloat
    var art = PocketCatArt.face

    var body: some View {
        Image(art.imageName(mood))
            .resizable()
            .interpolation(.none)
            .frame(width: drawn, height: drawn)
            .frame(width: size, height: size)
            .accessibilityLabel(Text(mood.title))
    }

    /// The nearest whole number of screen pixels per art pixel, so the pixels stay square in
    /// sizes that are not an exact multiple (the app's 29 and 48 pt). Layout keeps `size`.
    private var drawn: CGFloat {
        let scale = max(displayScale, 1)
        let multiple = max(1, (size * scale / art.pixels).rounded())
        return multiple * art.pixels / scale
    }
}
