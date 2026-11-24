import SwiftUI

/// Two bookplates sit on the glass above the room; only the buttons intercept scene gestures.
struct RoomLibraryControls: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var widthClass
    let photos: () -> Void
    let furniture: () -> Void

    var body: some View {
        let compact = widthClass == .compact
        let column = typeSize.isAccessibilitySize
        let stacked = compact && typeSize >= .xxLarge
        if column {
            plates(pile, short: true, stacked: stacked)
        } else {
            // Each label stays one whole word on one line: beside the icon if both plates fit
            // the row, under it if not (English on the narrower phones), and the plates pile up
            // as they do at accessibility sizes when even that is too wide. Words never break.
            ViewThatFits(in: .horizontal) {
                if !stacked { plates(row, short: false, stacked: false) }
                plates(row, short: false, stacked: true)
                plates(pile, short: false, stacked: false)
            }
        }
    }

    private var row: AnyLayout { AnyLayout(HStackLayout(alignment: .bottom, spacing: 8)) }
    private var pile: AnyLayout { AnyLayout(VStackLayout(alignment: .leading, spacing: 5)) }

    /// One short word per plate in English, so a label never has to break inside a word.
    private func plates(_ layout: AnyLayout, short: Bool, stacked: Bool) -> some View {
        let photoTitle = short
            ? String(localized: "bookplate.photos.short", defaultValue: "照片",
                     comment: "Room bookplate for the photo library at the largest text sizes; one short word")
            : String(localized: "bookplate.photos", defaultValue: "照片库",
                     comment: "Room bookplate that opens the photo library; one short word")
        let furnitureTitle = short
            ? String(localized: "家具")
            : String(localized: "bookplate.furniture", defaultValue: "家具库",
                     comment: "Room bookplate that opens the furniture list; one short word")
        return layout {
            bookplate(photoTitle, icon: "RoomPhotoAlbum", spoken: "照片库",
                      id: "photo-library", stacked: stacked, action: photos)
            bookplate(furnitureTitle, icon: "RoomFurnitureAlbum", spoken: "家具列表",
                      id: "furniture-list", stacked: stacked, action: furniture)
        }
    }

    private func bookplate(_ title: String, icon: String, spoken: LocalizedStringKey,
                           id: String, stacked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 4))
            layout {
                Image(icon).renderingMode(.original).resizable().scaledToFit().frame(width: 32, height: 32)
                Text(title)
                    .font(.system(typeSize.isAccessibilitySize ? .caption : .subheadline, design: .rounded, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .padding(.leading, 7)
            .padding(.trailing, 12)
            .padding(.vertical, stacked ? 4 : 0)
            .frame(minWidth: 44, minHeight: 44)
            .roomPaper(corner: RoomPaper.bookplateCorner)
            .contentShape(.rect(cornerRadius: RoomPaper.bookplateCorner))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(spoken))
        // Voice Control answers to the words on the plate as well as the spoken name.
        .accessibilityInputLabels([Text(spoken), Text(title)])
        .accessibilityIdentifier(id)
        .accessibilityShowsLargeContentViewer { Label { Text(spoken) } icon: { Image(icon) } }
        // Chapter 3, opened by hand in a furnished room, points at 家具库.
        .tourAnchor(id, form: .plate(corner: RoomPaper.bookplateCorner))
    }
}

extension View {
    func roomPaper(corner: CGFloat) -> some View {
        foregroundStyle(RoomPaper.ink)
            .background {
                let paper = RoundedRectangle(cornerRadius: corner, style: .continuous)
                paper.fill(RoomPaper.paper)
                    .overlay { paper.strokeBorder(RoomPaper.edge, lineWidth: 1) }
                    .shadow(color: Color.black.opacity(0.12), radius: 2, y: 2)
            }
    }
}
