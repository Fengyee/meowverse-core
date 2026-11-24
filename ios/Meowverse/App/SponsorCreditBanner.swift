import MeowverseCore
import SwiftUI

/// Names who supported `target` (owner, 2026-11-22): first on that feature's page, or at the top
/// of that cat's card. Nothing at all with nobody to name. A page of a feature that is still
/// hidden doesn't place it. Thanks only.
struct SponsorCreditBanner: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let target: SponsorTarget

    var body: some View {
        let people = Credits.shown.bannerSponsors(for: target)
        if !people.isEmpty {
            let shape = RoundedRectangle(cornerRadius: RoomPaper.cardCorner, style: .continuous)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // Decoration only. At accessibility sizes the words need the whole width, or long
                // English names break inside a word.
                if !typeSize.isAccessibilitySize {
                    Image(systemName: "heart.fill").foregroundStyle(RoomPaper.clay).accessibilityHidden(true)
                }
                words(Wording.inline(Credits.list(people.map(Credits.name(of:)))))
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(RoomPaper.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background {
                shape.fill(RoomPaper.sheet)
                    .overlay { shape.fill(RoomPaper.clay.opacity(0.14)) }
                    .overlay { shape.strokeBorder(RoomPaper.clay, lineWidth: 1.5) }
            }
            .padding(.horizontal, 16)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sponsor-credit")
        }
    }

    private func words(_ names: String) -> Text {
        switch target {
        case .feature: Text("这个功能由\(names)支持实现", tableName: "About")
        case .cat: Text("这只猫咪由\(names)支持", tableName: "About")
        }
    }
}
