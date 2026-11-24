import SwiftUI

// The confirmation page of suggested filing (round 8). Photos are grouped by the piece they are
// suggested for; every photo starts ticked and can be unticked; a group can be ticked or unticked
// at once. "放进所选的 N 张" files the ticked ones, "先不用" leaves everything as it was.
//
// Push it on the import flow's NavigationStack (it sets its own title, toolbar and bottom bar,
// in the `.workshop` page look of the review screen). Values in, closures out; the thumbnails come
// from the caller (`ThumbnailView(photoId:)` in the app), nothing here reads the app model.

/// One photo in a suggestion. `label` is what VoiceOver reads for it, such as its capture line.
struct FilingSuggestionPhoto: Identifiable, Hashable {
    let id: String
    let label: String
}

/// The piece some photos are suggested for, and those photos.
struct FilingSuggestionGroup: Identifiable, Hashable {
    /// The piece's `instanceId`.
    let id: String
    /// `shownName`, already localised.
    let name: String
    /// Where it is when that helps, e.g. "在收纳箱" or the room name; `nil` otherwise.
    var detail: String?
    /// The piece's cover photo for its thumbnail; `nil` draws a sofa glyph instead.
    var cover: String?
    let photos: [FilingSuggestionPhoto]
}

struct FilingSuggestionReview<Thumbnail: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let groups: [FilingSuggestionGroup]
    /// The ticked photo ids. Start it with every suggested photo.
    @Binding var selection: Set<String>
    /// True while the filing is being saved: everything is held still and the button spins.
    var busy: Bool = false
    let confirm: () -> Void
    let notNow: () -> Void
    @ViewBuilder let thumbnail: (_ photoId: String) -> Thumbnail

    private var chosenCount: Int {
        groups.reduce(0) { $0 + $1.photos.filter { selection.contains($0.id) }.count }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("这些照片和下面家具里的照片很像。是在这台设备上比对的，可能有错：去掉不对的勾，再一起放进去。")
                    .font(.subheadline)
                    .foregroundStyle(Color.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(groups) { group in
                    section(group)
                }
            }
            .padding()
            .disabled(busy)
        }
        .safeAreaInset(edge: .bottom) {
            primaryButton(chosenCount == 0 ? String(localized: "先勾选要放进去的照片")
                                           : String(localized: "放进所选的 \(chosenCount) 张"),
                          enabled: chosenCount > 0, busy: busy, action: confirm)
                .accessibilityIdentifier("confirm-suggestions")
        }
        .memoryPage(.workshop)
        .navigationTitle(Text("按建议放进家具"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: notNow) { Text("先不用") }
                    .disabled(busy)
                    .accessibilityHint(Text("这次不放。照片仍然等着整理。"))
                    .accessibilityIdentifier("dismiss-suggestions")
            }
        }
    }

    // MARK: A piece and its photos

    private func section(_ group: FilingSuggestionGroup) -> some View {
        let ids = group.photos.map(\.id)
        let chosen = ids.filter(selection.contains).count
        let allChosen = chosen == ids.count
        return VStack(alignment: .leading, spacing: 12) {
            groupHeader(group, chosen: chosen, allChosen: allChosen, ids: ids)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileMinimum), spacing: 8)], spacing: 8) {
                ForEach(Array(group.photos.enumerated()), id: \.element.id) { index, photo in
                    tile(photo, in: group, index: index)
                }
            }
        }
        .padding(12)
        .memoryCard(.workshop)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("suggestion-group-\(group.id)")
    }

    private var tileMinimum: CGFloat {
        typeSize.isAccessibilitySize ? 104 : 72
    }

    @ViewBuilder
    private func groupHeader(_ group: FilingSuggestionGroup, chosen: Int, allChosen: Bool, ids: [String]) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            HStack(spacing: 12) {
                pieceThumbnail(group)
                VStack(alignment: .leading, spacing: 2) {
                    Text("放进「\(group.name)」")
                        .font(.headline)
                        .foregroundStyle(RoomPaper.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(countLine(suggested: ids.count, chosen: chosen, detail: group.detail))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(Color.subtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if allChosen { selection.subtract(ids) } else { selection.formUnion(ids) }
            } label: {
                // Both titles are laid out so the button keeps one width as it flips.
                ZStack {
                    Text("全选").opacity(allChosen ? 0 : 1)
                    Text("全不选").opacity(allChosen ? 1 : 0)
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(MemoryCommandStyle(tint: RoomPaper.moss))
            .accessibilityLabel(allChosen ? Text("全不选「\(group.name)」的建议") : Text("全选「\(group.name)」的建议"))
            .accessibilityIdentifier("suggestion-group-toggle-\(group.id)")
        }
    }

    private func countLine(suggested: Int, chosen: Int, detail: String?) -> String {
        let counts = String(localized: "建议 \(suggested) 张，已选 \(chosen) 张")
        guard let detail else { return counts }
        return counts + " · " + detail
    }

    @ViewBuilder
    private func pieceThumbnail(_ group: FilingSuggestionGroup) -> some View {
        Group {
            if let cover = group.cover {
                thumbnail(cover)
            } else {
                Image(systemName: "sofa")
                    .font(.title3)
                    .foregroundStyle(RoomPaper.moss)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoomPaper.flyleaf)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(.rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(RoomPaper.edge, lineWidth: 1) }
        .accessibilityHidden(true)
    }

    // MARK: A photo

    private func tile(_ photo: FilingSuggestionPhoto, in group: FilingSuggestionGroup, index: Int) -> some View {
        let ticked = selection.contains(photo.id)
        return Button {
            if ticked { selection.remove(photo.id) } else { selection.insert(photo.id) }
        } label: {
            SuggestionTile(ticked: ticked) { thumbnail(photo.id) }
        }
        .buttonStyle(.roomToken)
        .accessibilityLabel(Text(verbatim: photo.label))
        .accessibilityValue(ticked ? Text("会放进「\(group.name)」") : Text("不放"))
        .accessibilityAddTraits(ticked ? .isSelected : [])
        .accessibilityHint(Text("点一下切换是否放进去"))
        .accessibilityIdentifier("suggestion-photo-\(photo.id)")
    }
}

/// A square print with its tick. Unticked, the print fades and loses its moss frame, and the
/// mark is an empty ring: shape and colour both say it.
private struct SuggestionTile<Thumbnail: View>: View {
    let ticked: Bool
    @ViewBuilder let thumbnail: () -> Thumbnail

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { thumbnail().opacity(ticked ? 1 : 0.45).saturation(ticked ? 1 : 0.35) }
            .clipShape(shape)
            .overlay { shape.strokeBorder(ticked ? RoomPaper.moss.opacity(0.8) : RoomPaper.edge, lineWidth: ticked ? 1.5 : 1) }
            .overlay(alignment: .topTrailing) {
                MemorySelectionMark(isSelected: ticked)
                    .scaleEffect(1.15)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .padding(6)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(shape)
    }
}

/// The line that follows a batch change, with 撤销: the same paper bar as the photo library's
/// batch notice. Put it in the review screen's bottom inset after "放进所选的 N 张" returns; keep it
/// about 8 s, as the library does.
struct FilingNoticeBar: View {
    let message: String
    var undoing: Bool = false
    /// `nil` when the change cannot be taken back.
    var undo: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(RoomPaper.moss)
            }
            .font(.subheadline)
            .foregroundStyle(RoomPaper.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let undo {
                Button(action: undo) { Text("撤销") }
                    .font(.subheadline.weight(.semibold))
                    .tint(RoomPaper.moss)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(undoing)
                    .accessibilityIdentifier("undo-suggested-filing")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(RoomPaper.paper)
        .overlay(alignment: .top) { Divider().overlay(RoomPaper.edge) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("suggested-filing-notice")
    }

    /// "已把 12 张照片放进 3 件家具", or with one piece "已把 3 张照片放进「布艺沙发」". Photos
    /// that came off a photo board left it: "已把 3 张照片从照片板移到「布艺沙发」".
    static func filedMessage(photos: Int, pieces: [String], fromBoards: Bool = false) -> String {
        if pieces.count == 1, let name = pieces.first {
            return fromBoards ? String(localized: "已把 \(photos) 张照片从照片板移到「\(name)」")
                              : String(localized: "已把 \(photos) 张照片放进「\(name)」")
        }
        return fromBoards ? String(localized: "已把 \(photos) 张照片从照片板移到 \(pieces.count) 件家具")
                          : String(localized: "已把 \(photos) 张照片放进 \(pieces.count) 件家具")
    }
}
