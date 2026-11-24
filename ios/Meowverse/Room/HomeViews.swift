import MeowverseCore
import SwiftUI

/// 房间管理 or 猫咪管理: the rooms or the cats of the home. Adding one needs
/// `AppModel.offersSeveralHomes`; renaming, moving and removing what is already there does not. 猫咪管理 also holds the cat model (`CatPackCard`),
/// so every cat setting is in one place; renaming the first cat is what 设置 used to do.
struct HomeManagerView: View {
    /// Which half: 房间管理 and 猫咪管理 in the room's top band each open one.
    enum Part { case rooms, cats }

    let part: Part
    /// A toy or treat is out in the room. 猫咪管理 opens then (renaming and the cat model are
    /// fine mid-play), but adding, removing or moving a cat waits until play ends.
    var playing = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var naming: Naming?
    @State private var name = ""
    /// What the name prompt opened with: a changed name is unsaved work.
    @State private var namingStart = ""
    @State private var removing: Room?
    @State private var removingCat: Cat?
    @State private var failure: String?
    @State private var working = false

    /// What the name prompt is for.
    private enum Naming: Equatable {
        case newRoom
        case room(String)
        case newCat
        case cat(String)

        var isCat: Bool {
            switch self {
            case .newCat, .cat: true
            case .newRoom, .room: false
            }
        }
    }

    var body: some View {
        alerts(page)
            // A Home Screen quick action must not close the page over a name being typed.
            .unsentWork(naming != nil && name != namingStart)
            // A container id: without `.contain` it would replace the ids of the rows inside.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-manager")
    }

    private var page: some View {
        RoomFolio(title: pageTitle, image: part == .rooms ? "TopRooms" : "TopCats",
                  close: RoomFolioClose(label: Text("关闭"), id: "close-home") { dismiss() }) {
            switch part {
            case .rooms:
                // Who supported the feature comes first, once the feature shows.
                if model.offersSeveralHomes { SponsorCreditBanner(target: .feature(.severalRooms)) }
                roomsCard
            case .cats:
                if model.offersSeveralHomes { SponsorCreditBanner(target: .feature(.severalCats)) }
                catsCard
                // Everything about the cats is here; 设置 only points to it.
                CatPackCard()
            }
        }
        .disabled(working)
    }

    private var pageTitle: String {
        switch part {
        case .rooms: String(localized: "房间管理")
        case .cats: String(localized: "猫咪管理")
        }
    }

    private var roomsCard: some View {
        RoomFolioCard(footer: roomsFooter) {
            ForEach(model.state.allRooms) { room in roomRow(room).folioRowPadding() }
            if model.offersSeveralHomes {
                Button {
                    ask(.newRoom, current: "")
                } label: {
                    RoomFolioAddLabel(title: Text("新建房间"))
                        .folioRowPadding()
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(model.state.allRooms.count >= AppState.maxRooms)
                .accessibilityIdentifier("manager-new-room")
            }
        }
    }

    private var catsCard: some View {
        RoomFolioCard(footer: catsFooter) {
            if playing, catsCanChange {
                Label(waitForPlayWords, systemImage: "pause.circle")
                    .font(.footnote)
                    .foregroundStyle(RoomPaper.note)
                    .fixedSize(horizontal: false, vertical: true)
                    .folioRowPadding()
                    .accessibilityIdentifier("cats-wait-for-play")
            }
            ForEach(model.state.allCats) { cat in catRow(cat).folioRowPadding() }
            if model.offersSeveralHomes {
                Button {
                    ask(.newCat, current: "")
                } label: {
                    RoomFolioAddLabel(title: Text("添加猫咪"))
                        .folioRowPadding()
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(playing || model.state.allCats.count >= AppState.maxCats)
                .accessibilityIdentifier("manager-new-cat")
            }
        }
    }

    /// Deleting is only explained where there is, or can be, a room to delete.
    private var roomsFooter: Text {
        let limit = String(GridRules.maxItems)
        return model.offersSeveralHomes || model.hasSeveralRooms
            ? Text("每个房间最多 \(limit) 件家具。删除房间时，里面的家具会连同照片收进收纳箱，不会被删除。第一个房间不能删除。")
            : Text("房间里最多摆 \(limit) 件家具。")
    }

    /// Whether a cat can be added, removed or moved. With one room and one cat, and adding
    /// hidden, the page has only names and models, so it explains none of those.
    private var catsCanChange: Bool { model.offersSeveralHomes || model.hasSeveralRooms || model.hasSeveralCats }

    private var catsFooter: Text? {
        catsCanChange ? Text("“跟着你”的猫咪出现在你正在看的房间里；也可以让它住在一个房间。第一只猫咪不能移除。") : nil
    }

    private var waitForPlayWords: String {
        model.offersSeveralHomes
            ? String(localized: "正在玩耍。玩完以后才能添加、移除猫咪或换它住的房间。")
            : String(localized: "正在玩耍。玩完以后才能移除猫咪或换它住的房间。")
    }

    private func alerts(_ content: some View) -> some View {
        content
                .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }), presenting: naming) { purpose in
                if purpose.isCat {
                    TextField("名字", text: $name).autocorrectionDisabled()
                } else {
                    TextField("名字（可以不填）", text: $name).autocorrectionDisabled()
                }
                Button(purpose == .newRoom ? "新建" : purpose == .newCat ? "添加" : "保存") { save(purpose) }
                Button("取消", role: .cancel) {}
            } message: { purpose in
                if purpose.isCat {
                    Text("最多 \(String(AppState.maxCatNameLength)) 个字。")
                } else {
                    Text("最多 \(String(AppState.maxRoomNameLength)) 个字。不填就用默认的名字。")
                }
            }
            .alert("移除这只猫咪？", isPresented: Binding(get: { removingCat != nil }, set: { if !$0 { removingCat = nil } }), presenting: removingCat) { cat in
                Button("移除猫咪", role: .destructive) { run { if let failed = await model.removeCat(cat.catId) { failure = failed.message } } }
                Button("取消", role: .cancel) {}
            } message: { cat in
                Text("「\(cat.name)」不再出现在房间里。照片和家具都不受影响。")
            }
            .alert("删除这个房间？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { room in
                Button("删除房间", role: .destructive) { remove(room) }
                Button("取消", role: .cancel) {}
            } message: { room in
                Text(removeMessage(room))
            }
            .alert("没能保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好") {}
            } message: {
                Text(failure ?? "")
            }
    }

    private func roomRow(_ room: Room) -> some View {
        let current = room.roomId == model.currentRoomId
        let count = model.state.furniture(inRoom: room.roomId).count
        return HStack(spacing: 8) {
            Button {
                model.showRoom(room.roomId)
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.roomName(room)).foregroundStyle(Color.primary)
                        Text(count == 0 ? String(localized: "还没有家具") : String(localized: "\(count) 件家具"))
                            .font(.subheadline)
                            .foregroundStyle(Color.subtle)
                    }
                    Spacer(minLength: 8)
                    if current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityHidden(true) }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(current ? .isSelected : [])
            .accessibilityHint("打开这个房间")
            .accessibilityIdentifier("room-row")
            Menu {
                Button("改名", systemImage: "pencil") { ask(.room(room.roomId), current: room.name ?? "") }
                    .accessibilityIdentifier("rename-room")
                if room.roomId != AppState.primaryRoomId {
                    Button("删除房间", systemImage: "trash", role: .destructive) { removing = room }
                        .accessibilityIdentifier("remove-room")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("\(model.roomName(room))的更多操作")
            .accessibilityIdentifier("room-row-menu")
        }
    }

    private var namingTitle: String {
        switch naming {
        case .newRoom: String(localized: "新建房间")
        case .room: String(localized: "房间的名字")
        case .newCat: String(localized: "添加猫咪")
        case .cat, nil: String(localized: "猫咪的名字")
        }
    }

    private func catRow(_ cat: Cat) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cat.name)
                Text(model.whereabouts(of: cat))
                    .font(.subheadline)
                    .foregroundStyle(Color.subtle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("cat-row")
            Spacer(minLength: 8)
            Menu {
                Button("改名", systemImage: "pencil") { ask(.cat(cat.catId), current: cat.name) }
                    .accessibilityIdentifier("rename-cat")
                if model.hasSeveralRooms || cat.roomId != nil {
                    Picker("住在哪里", selection: Binding(get: { cat.roomId }, set: { roomId in
                        run { if let failed = await model.setCatRoom(cat.catId, roomId) { failure = failed.message } }
                    })) {
                        Text("跟着你").tag(String?.none)
                        ForEach(model.state.allRooms) { room in
                            Text(model.roomName(room)).tag(String?.some(room.roomId))
                        }
                    }
                    .disabled(playing)
                }
                if cat.catId != AppState.primaryCatId {
                    Button("移除猫咪", systemImage: "trash", role: .destructive) { removingCat = cat }
                        .disabled(playing)
                        .accessibilityIdentifier("remove-cat")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("\(cat.name)的更多操作")
            .accessibilityIdentifier("cat-row-menu")
        }
    }

    private func ask(_ purpose: Naming, current: String) {
        name = current
        namingStart = current
        naming = purpose
    }

    private func removeMessage(_ room: Room) -> String {
        let count = model.state.furniture(inRoom: room.roomId).count
        let name = model.roomName(room)
        return count == 0
            ? String(localized: "「\(name)」是空的。删除后不能恢复。")
            : String(localized: "「\(name)」里的 \(count) 件家具会连同照片收进收纳箱，可以再摆进别的房间。")
    }

    private func save(_ purpose: Naming) {
        let typed = name
        run {
            switch purpose {
            case .newRoom:
                if let failed = await model.addRoom(name: typed) { failure = failed.message } else { dismiss() }
            case .room(let roomId):
                if let failed = await model.renameRoom(roomId, to: typed) { failure = failed.message }
            case .newCat:
                if let failed = await model.addCat(name: typed) { failure = failed.message }
            case .cat(let catId):
                if let failed = await model.renameCat(catId, to: typed) { failure = failed.message }
            }
        }
    }

    private func remove(_ room: Room) {
        run {
            if let failed = await model.removeRoom(room.roomId) { failure = failed.message }
        }
    }

    private func run(_ body: @escaping () async -> Void) {
        guard !working else { return }
        working = true
        Task {
            await body()
            working = false
        }
    }
}

/// The room's title on its plate in the room's top band: a menu that switches rooms, and makes
/// one where `AppModel.offersSeveralHomes`.
struct RoomSwitcher: View {
    @Environment(AppModel.self) private var model
    @State private var newRoomShown = false
    @State private var name = ""
    @State private var failure: String?

    var body: some View {
        let title = model.roomName(model.currentRoom)
        Menu {
            Section {
                ForEach(model.state.allRooms) { room in
                    Button {
                        model.showRoom(room.roomId)
                    } label: {
                        if room.roomId == model.currentRoomId {
                            Label(model.roomName(room), systemImage: "checkmark")
                        } else {
                            Text(model.roomName(room))
                        }
                    }
                }
            }
            if model.offersSeveralHomes {
                Button {
                    name = ""
                    newRoomShown = true
                } label: {
                    Label("新建房间", systemImage: "plus")
                }
                .disabled(model.state.allRooms.count >= AppState.maxRooms)
                .accessibilityIdentifier("new-room")
            }
        } label: {
            RoomTopBarTitleFace(title: title)
        }
        .menuStyle(.button)
        .buttonStyle(.roomToken)
        .accessibilityLabel(title)
        .accessibilityHint(model.offersSeveralHomes ? String(localized: "切换房间，或新建房间") : String(localized: "切换房间"))
        .accessibilityShowsLargeContentViewer { Text(title) }
        .accessibilityIdentifier("room-switcher")
        .tourAnchor("room-switcher", form: .plate(corner: RoomPaper.bookplateCorner))
        // A Home Screen quick action must not dismiss the prompt over a name being typed.
        .unsentWork(newRoomShown && !name.isEmpty)
        .alert("新建房间", isPresented: $newRoomShown) {
            TextField("名字（可以不填）", text: $name)
                .autocorrectionDisabled()
            Button("新建") {
                let typed = name
                Task { if let failed = await model.addRoom(name: typed) { failure = failed.message } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("最多 \(String(AppState.maxRoomNameLength)) 个字。不填就用默认的名字。")
        }
        .alert("没能保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好") {}
        } message: {
            Text(failure ?? "")
        }
    }
}

private extension View {
    /// A row inside a folio card: 16 pt in from the card, at least 44 pt tall.
    func folioRowPadding() -> some View {
        padding(.horizontal, 16).padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}
