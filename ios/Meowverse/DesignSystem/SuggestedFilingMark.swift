import SwiftUI

/// The provenance mark of a photo that went into its piece from a suggestion the user confirmed
/// (round 8). It is a source line like `Wording.sourceLine` ("本机识别为椅子，由你确认"): the same
/// `.subheadline` in `Color.subtle`, with its own symbol, so on-device recognition, manual choice,
/// demo data and suggestions never share one. Put it in the photo caption under the source line;
/// the caption combines its children for VoiceOver, so it is read with the date and source.
struct SuggestedFilingMark: View {
    static let symbol = "photo.stack"

    var body: some View {
        Label {
            Text("按相像的照片建议放入，由你确认")
        } icon: {
            Image(systemName: Self.symbol)
        }
        .font(.subheadline)
        .foregroundStyle(Color.subtle)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("suggested-filing-mark")
    }
}
