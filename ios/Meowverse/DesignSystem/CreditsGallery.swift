#if DEBUG
import SwiftUI

/// DEBUG review page, `-MeowverseOverlayGallery credits`: the first sections of 关于与隐私 as they
/// will look once sponsors and testers have given names. The names are `Credits.sample`, made up.
struct CreditsGallery: View {
    var body: some View {
        NavigationStack {
            List {
                AboutCreditsSections(roll: Credits.sample)
            }
            .navigationTitle("关于与隐私")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
