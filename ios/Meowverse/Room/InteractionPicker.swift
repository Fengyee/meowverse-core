import MeowverseCore
import SwiftUI

struct CatInvitation: Identifiable {
    let id = UUID()
    let itemId: String
    let siteId: String
    let action: CatAction
}

extension CatAction {
    var menuTitle: String {
        switch self {
        case .sit: String(localized: "坐看房间")
        case .loaf: String(localized: "趴下")
        case .sleep: String(localized: "打盹")
        case .play: String(localized: "拍一拍")
        case .scratch: String(localized: "磨爪")
        case .hide: String(localized: "躲起来")
        case .eat: String(localized: "吃一点")
        case .drink: String(localized: "喝水")
        case .dig: String(localized: "扒一扒猫砂")
        }
    }
}

struct InteractionPicker: View {
    @Environment(AppModel.self) private var model
    @State private var detent = PresentationDetent.large
    @AppStorage("bella.groundGait") private var groundGait: GroundGait = .groundWalk
    let invite: (PhotoFurniture, CatalogModel.Site, CatAction) -> Void
    var play: (CatPlayItem) -> Void = { _ in }
    var selectedPlayItem: CatPlayItem = .toyMouse
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                if model.leadCat == nil {
                    // No cat here yet: keeping you company is the one thing to do.
                    Section {
                        pocketCatRow
                    } footer: {
                        Text("猫咪搬进来以后，这里还能玩玩具、喂零食。")
                    }
                    .listRowBackground(RoomPaper.sheet)
                    tabletopSection
                } else {
                    withCat
                }
            }
            // Chapters 11 and 13 begin while this page is on top (`TourPages`); 11.2 and 13.1 scroll
            // their row into view first (LINES.md T5.14).
            .tourAnchor(TourPages.anchor(.interactionPanel), padding: 0)
            .tourScrolls(proxy, to: ["walk-style", "open-ar-tabletop"])
            }
            .foregroundStyle(RoomPaper.ink)
            .memoryPage(.companion)
            .navigationTitle("和\(Wording.inline(model.leadCatName))互动")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", action: onClose).accessibilityIdentifier("close-interaction") } }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    private var pocketCatRow: some View {
        NavigationLink { PocketCatView(catName: model.leadCatName) } label: {
            Label {
                Text(PocketCatCopy.title).font(.system(.body, design: .rounded, weight: .semibold))
            } icon: {
                PocketCatPortrait(mood: .sleeping, size: 29)
                    .frame(width: 44, height: 34)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("choose-pocket-cat")
        .tourAnchor("choose-pocket-cat", padding: 0)
    }

    /// 走路方式, moved here from the room's old "⋯" menu. Free, and about what the cat does.
    /// One row per gait with a check on the chosen one: four chips in one row squeezed each name
    /// into a column of single characters (build 4).
    private var gaitSection: some View {
        Section("走路方式") {
            ForEach(GroundGait.allCases) { gait in
                let selected = gait == groundGait
                Button { groundGait = gait } label: {
                    HStack(spacing: 12) {
                        Text(gait.title)
                            .foregroundStyle(RoomPaper.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(RoomPaper.moss)
                            .opacity(selected ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .accessibilityLabel(gait.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("ground-gait-\(gait.rawValue)")
                // 11.2's window: the first style, under the group's heading.
                .tourAnchor(gait == GroundGait.allCases.first ? "walk-style" : "", cover: .row)
                .id(gait == GroundGait.allCases.first ? "walk-style" : gait.rawValue)
            }
        }
        .listRowBackground(RoomPaper.sheet)
    }

    @ViewBuilder private var withCat: some View {
                Section("陪猫咪玩") {
                    NavigationLink {
                        PlayItemPicker(treats: false, selected: selectedPlayItem, choose: play)
                    } label: {
                        Label {
                            Text("选玩具").font(.system(.body, design: .rounded, weight: .semibold))
                        } icon: {
                            MemoryEmblem(.companion).frame(width: 44, height: 34)
                        }
                    }
                    .accessibilityIdentifier("choose-toy")
                    .tourAnchor("choose-toy", padding: 0)
                    NavigationLink {
                        PlayItemPicker(treats: true, selected: selectedPlayItem, choose: play)
                    } label: {
                        Label {
                            Text("喂小零食").font(.system(.body, design: .rounded, weight: .semibold))
                        } icon: {
                            Image(decorative: "TreatBiscuit").resizable().scaledToFit().frame(width: 44, height: 34)
                        }
                    }
                    .accessibilityIdentifier("choose-treat")
                    pocketCatRow
                }
                .listRowBackground(RoomPaper.sheet)
                tabletopSection
                // Wall and decorative pieces offer nothing to do: Bella cannot get onto them.
                let pieces = model.roomFurniture.filter { item in
                    item.wall == nil && model.catalog?.model(id: item.modelId)?.isDecorative != true
                }
                if pieces.count == 1, let only = pieces.first {
                    furnitureSections(for: only, anchored: true)
                } else {
                    Section("房间里的家具") {
                        ForEach(pieces) { item in
                            NavigationLink {
                                choices(for: item)
                            } label: {
                                Label(item.shownName, systemImage: model.catalog?.model(id: item.modelId)?.category.symbol ?? "pawprint")
                            }
                            // 11.1's window: the whole group, every piece in it (VISUAL §18.2 item 1).
                            .tourAnchor(item.id == pieces.first?.id ? "send-cat" : "", cover: .group)
                        }
                    }
                    .listRowBackground(RoomPaper.sheet)
                }
                gaitSection
    }

    // MARK: The room on a table (AR, round 11 trial)

    /// Opens the room on a real table. Its own section, right under 陪我一会儿's: the row there
    /// is another colleague's to change. No row without world tracking (`RoomAREntry`).
    var openTabletop: (() -> Void)? = nil

    @ViewBuilder private var tabletopSection: some View {
        let entry = RoomAREntry.current
        if let openTabletop, entry != .hidden {
            Section {
                Button(action: openTabletop) {
                    HStack(spacing: 12) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("放到桌上看看", tableName: "RoomAR")
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                                if entry == .cameraOff {
                                    Text("相机权限已关闭，打开后才能用。", tableName: "RoomAR")
                                        .font(.footnote)
                                        .foregroundStyle(RoomPaper.ink.opacity(0.75))
                                }
                            }
                        } icon: {
                            Image(systemName: "arkit")
                                .font(.title2)
                                .foregroundStyle(RoomPaper.moss)
                                .frame(width: 44, height: 34)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(RoomPaper.ink)
                    .contentShape(.rect)
                }
                .accessibilityIdentifier("open-ar-tabletop")
                .tourAnchor("open-ar-tabletop", cover: .row)
                .id("open-ar-tabletop")
            } footer: {
                Text("用相机把房间放到真实的桌面上。相机画面只在这台设备上显示，不录制，也不保存。", tableName: "RoomAR")
                    .accessibilityIdentifier("ar-tabletop-note")
                    // 13.1 keeps its bubble off this; with no room above, the window takes it in.
                    .tourAnchor("open-ar-tabletop-footer", padding: 0)
            }
            .listRowBackground(RoomPaper.sheet)
        }
    }

    @ViewBuilder
    private func choices(for item: PhotoFurniture) -> some View {
        List { furnitureSections(for: item) }
            .memoryPage(.companion)
            .navigationTitle(item.shownName)
            // 11.1 with several pieces hands over to this page.
            .tourAnchor("send-cat-choices", padding: 0)
    }

    /// `anchored`: in the panel itself, with one piece: the first action the cat can get to is
    /// 11.1's window.
    @ViewBuilder
    private func furnitureSections(for item: PhotoFurniture, anchored: Bool = false) -> some View {
        if let catalog = model.catalog, let piece = catalog.model(id: item.modelId),
           CatRoutine.accessCell(of: item, in: model.roomFurniture) != nil {
            let reachable = { (site: CatalogModel.Site) in
                site.actions.first.map {
                    CatRoutine.invitedTrip(items: model.roomFurniture, from: .atEntrance, catalog: catalog,
                                           itemId: item.instanceId, siteId: site.id, action: $0) != nil
                } ?? false
            }
            let tourSite = anchored && TourLaunch.isEnabled ? piece.interactionSites.first(where: reachable)?.id : nil
            ForEach(piece.interactionSites, id: \.id) { site in
                let accessible = reachable(site)
                Section(accessible ? site.title : String(localized: "\(site.title)（通路被挡住）")) {
                    ForEach(site.actions, id: \.self) { action in
                        Button(action.menuTitle) { invite(item, site, action) }
                            .disabled(!accessible)
                            .accessibilityLabel(Wording.phrases([site.title, action.menuTitle]))
                            .accessibilityIdentifier("invite-\(site.id)-\(action.rawValue)")
                            // 11.1's window with one piece: the card of its first group of
                            // actions, not the group's title (VISUAL §18.2 item 1).
                            .tourAnchor(site.id == tourSite && action == site.actions.first ? "send-cat" : "", cover: .group)
                    }
                }
                .listRowBackground(RoomPaper.sheet)
            }
        } else {
            ContentUnavailableView {
                Label {
                    Text("暂时到不了这件家具")
                } icon: {
                    MemoryEmblem(.companion).frame(width: 74, height: 58)
                }
            } description: {
                Text("把它挪一挪，给猫咪留一条通路。")
            }
            .listRowBackground(RoomPaper.sheet)
        }
    }
}
