import MeowverseCore
import SwiftUI

/// Position, turn, size and finish for one piece of furniture, with the room as a live preview.
/// A wall-mounted model gets its wall and the position along it instead of a cell and a turn.
/// Every change is available as a labelled button, so the 3D view is never the only way in.
struct PlacementEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var placement: Placement
    @Binding var displayName: String
    @State private var previewState: PlacementPreviewState = .loading
    let model: CatalogModel
    let ignoring: String?
    let confirmTitle: String
    let busy: Bool
    let onConfirm: () -> Void

    private var others: [PhotoFurniture] {
        app.roomFurniture.filter { $0.instanceId != ignoring }
    }

    private var issues: [PlacementIssue] {
        guard let catalog = app.catalog else { return [.unknownModel] }
        return GridRules.validate(placement, in: app.roomFurniture, catalog: catalog, ignoring: ignoring)
    }

    var body: some View {
        let issues = issues
        let ghost = GhostFurniture(placement: placement, valid: issues.isEmpty, among: others)
        GeometryReader { geometry in
            if RoomColumns.fits(in: geometry.size.width) {
                HStack(spacing: 0) {
                    preview(ghost, issues: issues)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    ScrollView { controls(issues).padding() }
                        .safeAreaInset(edge: .bottom) { confirmButton(issues) }
                        .frame(width: RoomColumns.inspectorWidth(in: geometry.size.width))
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        preview(ghost, issues: issues)
                            .frame(height: typeSize.isAccessibilitySize ? 232 : 312)
                            .clipShape(.rect(cornerRadius: 8))
                            .padding(4)
                            .memoryCard(.workshop)
                        controls(issues)
                    }
                    .padding()
                }
                .safeAreaInset(edge: .bottom) { confirmButton(issues) }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            // A caller that found no free wall hands over a floor placement: hang it, so the
            // wall controls have something to work on and the reason shown is the real one.
            if onWall, placement.wall == nil {
                placement.wall = .back
                placement.z = 0
                placement.turn = 0
            }
        }
    }

    private func preview(_ ghost: GhostFurniture, issues: [PlacementIssue]) -> some View {
        RoomSceneView(
            items: others,
            ghost: ghost,
            onTapFurniture: nil,
            onTapCell: { x, z in
                // A floor tap under a wall piece slides it along the wall it is on.
                if let wall = placement.wall {
                    placement.centre(on: wall, cell: wall == .back ? x : z)
                } else {
                    placement.centre(onX: x, z: z)
                }
            },
            onTapWall: onWall ? { wall, cell in placement.centre(on: wall, cell: cell) } : nil,
            onPreviewState: { previewState = $0 }
        )
        .overlay {
            if previewState == .ready && !onWall { PlacementAccessGuides(cells: ghost.accessCells) }
            if previewState != .ready {
                Group {
                    if previewState == .unavailable {
                        Label(previewStatus(issues), systemImage: "photo")
                    } else {
                        ProgressView("正在载入 3D 模型…").tint(RoomPaper.ink)
                    }
                }
                .padding(12)
                .roomPaper(corner: RoomPaper.bookplateCorner)
                .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("房间预览")
        .accessibilityValue(previewStatus(issues))
        .accessibilityIdentifier("placement-preview")
    }

    private func previewStatus(_ issues: [PlacementIssue]) -> String {
        switch previewState {
        case .ready: app.placementStatus(issues)
        case .loading: String(localized: "正在载入 3D 模型…")
        case .unavailable: String(localized: "这个款式未能载入。请返回重选，或稍后再试。")
        }
    }

    private func controls(_ issues: [PlacementIssue]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if typeSize.isAccessibilitySize { positionPad }
            positionFeedback(issues)
            if !typeSize.isAccessibilitySize { positionPad }

            if model.sizes.count > 1 {
                Picker("大小", selection: sizeBinding) {
                    ForEach(model.sizes.indices, id: \.self) { index in
                        Text(onWall ? "\(model.sizes[index][0]) 格宽" : "\(model.sizes[index][0])×\(model.sizes[index][1]) 格").tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("placement-size")
            }

            if !finishChoices.isEmpty { finishRow } // none for a theme set: its colours are its own

            VStack(alignment: .leading, spacing: 6) {
                Text("名字").font(.subheadline).foregroundStyle(Color.subtle)
                TextField("家具的名字", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
            }
        }
    }

    @ViewBuilder
    private var positionPad: some View {
        if onWall { wallPad } else { movePad }
    }

    private func positionFeedback(_ issues: [PlacementIssue]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(app.placementStatus(issues), systemImage: issues.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(issues.isEmpty ? Color.primary : Color.caution)
                .accessibilityIdentifier("placement-status")
            if !onWall {
                Text(PlacementAccessGuides.legend)
                    .font(.footnote)
                    .foregroundStyle(RoomPaper.ink)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .memoryCard(.workshop)
    }

    private func confirmButton(_ issues: [PlacementIssue]) -> some View {
        primaryButton(confirmTitle, enabled: issues.isEmpty && previewState == .ready, busy: busy, action: onConfirm)
            .accessibilityIdentifier("confirm-placement")
    }

    private var onWall: Bool { model.mount == .wall }

    private var wallPad: some View {
        VStack(spacing: 10) {
            Picker("挂在哪面墙", selection: Binding { placement.wall ?? .back } set: { placement.wall = $0 }) {
                Text("左墙").tag(WallSide.left)
                Text("后墙").tag(WallSide.back)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("wall-side")
            HStack(spacing: 10) {
                padButton(String(localized: "向左移一格"), "arrow.left") {
                    placement.x += WallGeometry.offsetStep(towardsScreenRight: -1, on: placement.wall)
                }
                .accessibilityIdentifier("wall-slide-left")
                padButton(String(localized: "向右移一格"), "arrow.right") {
                    placement.x += WallGeometry.offsetStep(towardsScreenRight: 1, on: placement.wall)
                }
                .accessibilityIdentifier("wall-slide-right")
            }
        }
    }

    private var movePad: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            HStack(spacing: 10) {
                padButton(String(localized: "向左移一格"), "arrow.left") { placement.x -= 1 }
                padButton(String(localized: "向右移一格"), "arrow.right") { placement.x += 1 }
            }
            HStack(spacing: 10) {
                padButton(String(localized: "向里移一格"), "arrow.up") { placement.z -= 1 }
                padButton(String(localized: "向外移一格"), "arrow.down") { placement.z += 1 }
            }
            padButton(String(localized: "转四分之一圈"), "rotate.right") { placement.turn = (placement.turn + 1) % 4 }
        }
    }

    private func padButton(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }

    /// Six or seven swatches no longer fit beside the label on a phone, so the label sits above them;
    /// each keeps a 44-point target and the row scrolls if Display Zoom narrows the screen.
    private var finishRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("配色").font(.subheadline).foregroundStyle(Color.subtle)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { finishSwatches }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }

    /// A v2 model offers its palette presets (no "original": that is its default preset, shown
    /// selected until another swatch is picked). v1 art keeps every finish.
    private var finishChoices: [(finish: Finish, title: String, swatch: Color)] {
        let looks = FurnitureLooks.bundled
        guard let offered = looks.pickerFinishes(modelId: model.id) else {
            return Finish.allCases.map { ($0, $0.title, $0.swatch) }
        }
        return offered.map { choice in
            let rgb = choice.preset.swatch
            let title = choice.preset.label[AppLanguage.isChinese ? "zh" : "en"] ?? choice.finish.title
            return (choice.finish, title, Color(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2]))
        }
    }

    private var finishSwatches: some View {
        let shown = FurnitureLooks.bundled.shownFinish(placement.finish, modelId: model.id)
        return ForEach(finishChoices, id: \.finish) { choice in
            Button {
                placement.finish = choice.finish
            } label: {
                RoundedRectangle(cornerRadius: 7)
                    .fill(choice.swatch)
                    .frame(width: 36, height: 32)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(RoomPaper.ink.opacity(shown == choice.finish ? 1 : 0.32),
                                          lineWidth: shown == choice.finish ? 2 : 1)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if shown == choice.finish {
                            MemorySelectionMark(isSelected: true).frame(width: 14, height: 14)
                        }
                    }
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(choice.title)
            .accessibilityAddTraits(shown == choice.finish ? .isSelected : [])
        }
    }

    private var sizeBinding: Binding<Int> {
        Binding {
            model.sizes.firstIndex { $0[0] == placement.width && $0[1] == placement.depth } ?? 0
        } set: { index in
            placement.width = model.sizes[index][0]
            placement.depth = model.sizes[index][1]
        }
    }
}

extension AppModel {
    /// One line on whether a placement is allowed, shared by the placement editor and in-room editing.
    func placementStatus(_ issues: [PlacementIssue]) -> String {
        guard let first = issues.first else { return String(localized: "这个位置可以摆放") }
        switch first {
        case .outOfBounds: return String(localized: "超出了房间范围")
        case .overlaps(let id):
            let name = furniture(id)?.shownName ?? String(localized: "别的家具")
            return String(localized: "和「\(name)」重叠了")
        case .tooManyItems: return String(localized: "房间最多放 \(GridRules.maxItems) 件家具")
        case .sizeNotAllowed: return String(localized: "这个款式不支持这个大小")
        case .unknownModel: return String(localized: "找不到这个款式")
        case .blocksEntrance:
            guard let leadCat else { return String(localized: "请让门口这一格保持空着。") }
            return String(localized: "请把门口这一格留给\(Wording.object(leadCat.name))")
        case .unreachable:
            guard let leadCat else { return String(localized: "这处空地暂时到不了，换个位置试试。") }
            return String(localized: "\(Wording.subject(leadCat.name))走不到这里：留出一格通道，或转个方向")
        case .wrongMount: return String(localized: "这个款式不能放在这里")
        case .hidesPhotoBoard(let id):
            // Either way round: placing the tall piece, or hanging the board behind it.
            let other = furniture(id)
            let name = other?.shownName ?? String(localized: "照片板", table: "CatalogNames")
            return other?.wall == nil && other != nil
                ? String(localized: "照片板会被「\(name)」挡住", table: "CatalogNames")
                : String(localized: "会挡住墙上的「\(name)」", table: "CatalogNames")
        }
    }
}

extension Placement {
    /// Move so the footprint is centred on a cell, whatever the turn.
    mutating func centre(onX x: Int, z: Int) {
        let cells = GridRules.occupiedCells(x: self.x, z: self.z, width: width, depth: depth, turn: turn)
        guard let minX = cells.map(\.x).min(), let maxX = cells.map(\.x).max(),
              let minZ = cells.map(\.z).min(), let maxZ = cells.map(\.z).max() else { return }
        self.x += x - (minX + maxX) / 2
        self.z += z - (minZ + maxZ) / 2
    }

    /// Hang a wall piece on `wall` with its middle at `cell`, kept within the wall's length.
    mutating func centre(on wall: WallSide, cell: Int) {
        self.wall = wall
        x = min(max(cell - (width - 1) / 2, 0), max(GridRules.size - width, 0))
        z = 0
    }
}

/// Re-position an existing piece. The source photos stay attached.
struct MoveFurnitureView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let item: PhotoFurniture
    @State private var placement: Placement
    @State private var displayName: String
    @State private var saving = false
    @State private var failure: String?

    init(item: PhotoFurniture) {
        self.item = item
        _placement = State(initialValue: item.placement)
        _displayName = State(initialValue: item.shownName)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let model = app.catalog?.model(id: item.modelId) {
                    PlacementEditor(
                        placement: $placement, displayName: $displayName, model: model, ignoring: item.instanceId,
                        confirmTitle: String(localized: "保存"), busy: saving, onConfirm: save)
                } else {
                    ContentUnavailableView("找不到这个款式", systemImage: "questionmark.square.dashed")
                }
            }
            .memoryPage(.workshop)
            .navigationTitle("编辑「\(item.shownName)」")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .alert("没能保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("重试") { save() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func save() {
        saving = true
        Task {
            let outcome = await app.move(instanceId: item.instanceId, to: placement, displayName: displayName)
            saving = false
            switch outcome {
            case .saved: dismiss()
            case .failed(let message): failure = message
            }
        }
    }
}
