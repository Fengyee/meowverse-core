#if DEBUG
import SwiftUI

/// DEBUG only: the watch layout of the companion (`PocketCatWatchStatus`, the `.small` activity
/// family) at the Smart Stack's sizes, for review before anyone sees it on a watch. Launch with
/// `-MeowverseOverlayGallery watch`. An approximation: drawn by the iPhone at 2× art pixels on
/// the activity's dark green, with iPhone fonts; the watch renders the archived view itself.
struct PocketCatWatchGallery: View {
    /// HIG: the Smart Stack's Live Activity is the size of a watchOS widget.
    private let sizes: [(String, CGSize)] = [("40 mm", CGSize(width: 152, height: 69.5)),
                                             ("49 mm", CGSize(width: 198, height: 81.5))]
    private let samples: [(String?, PocketCatMood)] = [
        ("Bella", .sleeping), ("年糕", .watching), ("🍊小橘子", .eating), // not-localized: debug gallery, sample cat names
        ("Professor Whiskerton", .zoomies), ("大橘子小橘子圆滚滚的猫咪", .thinking), (nil, .playing), // not-localized: debug gallery, sample cat names
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(sizes, id: \.0) { size in
                            VStack(alignment: .leading, spacing: 2) {
                                PocketCatWatchStatus(name: sample.0, mood: sample.1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .frame(width: size.1.width, height: size.1.height)
                                    .background(Color(red: 0.12, green: 0.18, blue: 0.15), in: .rect(cornerRadius: 18))
                                    .foregroundStyle(.white)
                                    .environment(\.displayScale, 2)
                                Text(verbatim: size.0).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color.black)
        .accessibilityIdentifier("pocket-watch-gallery")
    }
}
#endif
