import SwiftUI

/// The companion on Apple Watch (the Smart Stack's `.small` activity family; CarPlay uses the
/// same family): the whole pixel cat, the cat's name and the expression. No buttons: CarPlay
/// turns them off, and whether a watch tap runs the intent on the iPhone is unverified.
///
/// Shared so the app's DEBUG gallery (`-MeowverseOverlayGallery watch`) can draw it; the
/// extension wraps it in `PocketCatDisplay` for the rotation.
struct PocketCatWatchStatus: View {
    let name: String?
    let mood: PocketCatMood

    var body: some View {
        HStack(spacing: 8) {
            // 48 pt is three art pixels per pixel on the watch's 2× screen.
            PocketCatPortrait(mood: mood, size: 48, art: .figure).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                PocketCatNameLine(name: name)
                    .font(.headline)
                    .minimumScaleFactor(0.8)
                Text(mood.title)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        // Every expression's layer is as wide as the activity, so the visible one stays leading.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The cat's name on one line, cut with "…" when long; "Keep me company" when there is none
/// (a companion from before names, or a cat whose name is all spaces).
struct PocketCatNameLine: View {
    let name: String?

    var body: some View {
        Group {
            if let name { Text(verbatim: name) } else { Text(PocketCatCopy.title) }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }
}
