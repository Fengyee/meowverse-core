import MeowverseCore
import SwiftUI

@Observable
final class RoomPlaySession {
    private(set) var item: CatPlayItem?
    private(set) var request: CatPlayRequest?
    private(set) var feedback: String?

    private(set) var windUpMouseID: String?

    var isActive: Bool { item != nil }

    func begin(_ item: CatPlayItem) {
        windUpMouseID = nil
        self.item = item
        request = nil
        feedback = nil
    }

    func windUp(_ mouse: PhotoFurniture) {
        begin(.windUpMouse)
        windUpMouseID = mouse.instanceId
    }

    func end() {
        windUpMouseID = nil
        item = nil
        request = nil
        feedback = nil
    }

    func place(x: Int, z: Int, items: [PhotoFurniture], catalog: FurnitureCatalog) {
        guard let item else { return }
        let next = CatPlayRequest(item: item, cell: GridCell(x: x, z: z))
        guard CatRoutine.playTrip(items: items, from: .atEntrance, catalog: catalog, request: next) != nil else {
            feedback = String(localized: "这处空地暂时到不了，换个位置试试。")
            return
        }
        feedback = nil
        if request?.cell == next.cell { return }
        request = next
    }

    func placeNext(items: [PhotoFurniture], catalog: FurnitureCatalog) {
        guard let item else { return }
        let cells = (0..<GridRules.size).flatMap { z in (0..<GridRules.size).map { GridCell(x: $0, z: z) } }
            .filter { $0 != GridRules.entrance }
            .sorted { distance($0) < distance($1) }
        let first = request.flatMap { request in cells.firstIndex(of: request.cell).map { $0 + 1 } } ?? 0
        for offset in cells.indices {
            let cell = cells[(first + offset) % cells.count]
            let next = CatPlayRequest(item: item, cell: cell)
            if CatRoutine.playTrip(items: items, from: .atEntrance, catalog: catalog, request: next) != nil {
                request = next
                feedback = nil
                return
            }
        }
        feedback = String(localized: "房间里没有可以放下的位置，先移动一件家具留出空地。")
    }

    func consumed(_ id: UUID) {
        guard request?.id == id else { return }
        request = nil
        feedback = String(localized: "吃完了。可以再放一份，或结束互动。")
    }

    func rejected(_ id: UUID) {
        guard request?.id == id else { return }
        request = nil
        feedback = String(localized: "这处空地暂时到不了，换个位置试试。")
    }

    private func distance(_ cell: GridCell) -> Int {
        abs(cell.x - GridRules.entrance.x) + abs(cell.z - GridRules.entrance.z)
    }
}

extension CatPlayItem {
    var title: String {
        switch self {
        case .windUpMouse: String(localized: "发条小鼠")
        case .toyMouse: String(localized: "毛毡小鼠")
        case .toyBall: String(localized: "拼色小球")
        case .featherWand: String(localized: "羽毛逗猫棒")
        case .treatSalmon: String(localized: "三文鱼小片")
        case .treatChicken: String(localized: "鸡肉小块")
        case .treatBiscuit: String(localized: "小鱼饼干")
        }
    }

    var symbol: String {
        switch self {
        case .toyMouse, .windUpMouse: "teddybear"
        case .toyBall: "tennisball"
        case .featherWand: "wand.and.stars"
        case .treatSalmon: "fish"
        case .treatChicken: "fork.knife"
        case .treatBiscuit: "fish.fill"
        }
    }

    var detail: String {
        switch self {
        case .windUpMouse: String(localized: "小鼠会沿着空地跑开，等猫咪追上。")
        case .toyMouse: String(localized: "拖着小鼠，带猫咪在房间里走走")
        case .toyBall: String(localized: "换个位置，让猫咪追着球跑")
        case .featherWand: String(localized: "轻移羽毛，等猫咪伸爪拍一拍")
        case .treatSalmon: String(localized: "一口大小的粉橙鱼片")
        case .treatChicken: String(localized: "几块淡金色的小点心")
        case .treatBiscuit: String(localized: "酥酥的小鱼形饼干")
        }
    }
}

private extension CatPlayItem {
    var pickerIllustration: String {
        switch self {
        case .toyMouse, .windUpMouse: "PlayMouse"
        case .toyBall: "PlayBall"
        case .featherWand: "PlayFeather"
        case .treatSalmon: "TreatSalmon"
        case .treatChicken: "TreatChicken"
        case .treatBiscuit: "TreatBiscuit"
        }
    }
}

struct PlayItemPicker: View {
    let treats: Bool
    let selected: CatPlayItem
    let choose: (CatPlayItem) -> Void

    var body: some View {
        List(CatPlayItem.allCases.filter { $0.isTreat == treats && $0 != .windUpMouse }) { item in
            Button {
                choose(item)
            } label: {
                HStack(spacing: 16) {
                    Image(decorative: item.pickerIllustration)
                        .resizable().scaledToFit()
                        .padding(2)
                        .frame(width: 54, height: 54)
                        .background(RoomPaper.paper, in: .rect(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(RoomPaper.edge.opacity(0.65)) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.system(.headline, design: .rounded)).foregroundStyle(RoomPaper.ink)
                        Text(item.detail).font(.subheadline).foregroundStyle(Color.subtle)
                    }
                    Spacer(minLength: 0)
                    MemorySelectionMark(isSelected: selected == item)
                }
                .padding(.vertical, 8)
                .contentShape(.rect)
            }
            .listRowBackground(RoomPaper.sheet)
            .accessibilityIdentifier("play-item-" + item.rawValue)
            .accessibilityValue(selected == item ? "已选择" : "")
            .accessibilityHint("选择后，在房间空地上点按放下")
        }
        .memoryPage(.companion)
        .navigationTitle(treats ? "小零食" : "选个玩具")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RoomPlayTray: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let session: RoomPlaySession
    let placeNext: () -> Void
    let change: () -> Void

    var body: some View {
        if let item = session.item {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(item.title).font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer()
                    Button("换一个", systemImage: "arrow.triangle.2.circlepath", action: change)
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("change-play-item")
                    Button("结束互动", systemImage: "xmark", action: session.end)
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("end-play")
                }
                if session.windUpMouseID != nil {
                    Text(item.detail)
                        .font(.subheadline)
                        .accessibilityIdentifier("wind-up-running")
                } else {
                    if !typeSize.isAccessibilitySize || session.request == nil || session.feedback != nil {
                        Text(session.feedback ?? (item.isTreat ? String(localized: "点按空地放下，等猫咪过来吃。") : String(localized: "点按或拖动空地，带猫咪跟着玩。")))
                            .font(.subheadline)
                            .foregroundStyle(Color.subtle)
                            .accessibilityIdentifier("play-feedback")
                    }
                    Button(session.request == nil ? "放到空地" : "换位置", action: placeNext)
                        .buttonStyle(.bordered)
                        .lineLimit(1)
                        .accessibilityHint("依次选择房间里能到达的空地")
                        .accessibilityIdentifier("place-play-item")
                        .accessibilityValue(session.request.map { "第 \($0.cell.x + 1) 列，第 \($0.cell.z + 1) 行" } ?? "尚未放下")
                }
            }
            .padding(16)
            .background(RoomPaper.paper, in: .rect(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(RoomPaper.edge, lineWidth: 1) }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("play-tray")
        }
    }
}
