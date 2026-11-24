import MeowverseCore
import SwiftUI

/// Editing one piece where it stands: a long press lifts it, drags and the tray change a draft,
/// and nothing reaches the store until the user confirms.
@Observable
final class RoomEditMode {
    static let space = "room-edit"

    private(set) var instanceId: String?
    private(set) var draft: Placement?
    var saving = false
    /// Draft position minus the floor point under the finger (for a wall piece: its offset minus
    /// the finger's offset along the wall, in `x`), kept for one drag so the piece follows from
    /// wherever it was grabbed instead of jumping under the finger.
    private var grab: SIMD2<Float>?

    var isActive: Bool { instanceId != nil }
    /// The piece hangs on a wall: it slides and changes wall instead of moving and turning.
    var onWall: Bool { draft?.wall != nil }

    func begin(_ item: PhotoFurniture) {
        instanceId = item.instanceId
        draft = Placement(item)
        grab = nil
    }

    func end() {
        instanceId = nil
        draft = nil
        grab = nil
        saving = false
    }

    func issues(in app: AppModel) -> [PlacementIssue] {
        guard let draft, let catalog = app.catalog else { return [.unknownModel] }
        return GridRules.validate(draft, in: app.roomFurniture, catalog: catalog, ignoring: instanceId)
    }

    func ghost(in app: AppModel) -> GhostFurniture? {
        guard let draft else { return nil }
        return GhostFurniture(placement: draft, valid: issues(in: app).isEmpty,
                              among: app.roomFurniture.filter { $0.instanceId != instanceId }, lifted: instanceId)
    }

    func rotate() {
        change { $0.turn = ($0.turn + 1) % 4 }
    }

    func nudge(x: Int, z: Int) {
        change { $0.x += x; $0.z += z }
    }

    func switchWall() {
        change { $0.wall = $0.wall == .left ? .back : .left }
    }

    /// Slides a wall piece `steps` cells to the right as the room is drawn.
    func slide(right steps: Int) {
        change { $0.x += WallGeometry.offsetStep(towardsScreenRight: steps, on: $0.wall) }
    }

    /// A floor piece follows the floor point under the finger. A wall piece follows the finger
    /// along its wall, and moves to the other wall when the finger is on that one.
    func drag(to touch: RoomTouch) {
        guard let draft else { return }
        if let wall = draft.wall {
            guard let spot = touch.wallSpot(from: wall) else { return }
            // Arriving on the other wall it is held by its middle: the old grab meant the old wall.
            let offset = spot.side == wall ? grab?.x ?? Float(draft.x) - spot.offset : -Float(draft.width) / 2
            grab = [offset, 0]
            change {
                $0.wall = spot.side
                $0.x = Int((spot.offset + offset).rounded())
            }
        } else if let floor = touch.floor {
            let offset = grab ?? SIMD2(Float(draft.x), Float(draft.z)) - floor
            grab = offset
            change {
                $0.x = Int((floor.x + offset.x).rounded())
                $0.z = Int((floor.y + offset.y).rounded())
            }
        }
    }

    func endDrag() {
        grab = nil
    }

    func centre(on touch: RoomTouch) {
        if let wall = draft?.wall {
            guard let spot = touch.wallSpot(from: wall) else { return }
            change { $0.centre(on: spot.side, cell: Int(spot.offset.rounded(.down))) }
        } else if let floor = touch.floor {
            change { $0.centre(onX: Int(floor.x.rounded(.down)), z: Int(floor.y.rounded(.down))) }
        }
    }

    /// Every edit ends inside the room: a finger can leave the floor, and the piece stops at the
    /// wall (a wall piece at the end of its wall) rather than disappearing past it. Unchanged
    /// drafts are not written back, so observers hear only about real moves.
    private func change(_ edit: (inout Placement) -> Void) {
        guard var next = draft else { return }
        edit(&next)
        if next.wall != nil {
            next.x = min(max(next.x, 0), max(GridRules.size - next.width, 0))
            next.z = 0
        } else {
            let size = ArtLibrary.rotatedSize(width: next.width, depth: next.depth, turn: next.turn)
            next.x = min(max(next.x, 0), max(GridRules.size - Int(size.w), 0))
            next.z = min(max(next.z, 0), max(GridRules.size - Int(size.d), 0))
        }
        if next != draft { draft = next }
    }
}

/// Covers the room while a piece is being edited: a drag anywhere moves it cell by cell, a tap
/// puts it on the tapped cell (a wall piece: on the tapped stretch of wall). VoiceOver gets the
/// same moves as named actions.
struct RoomEditSurface: View {
    let edit: RoomEditMode
    let framing: RoomProjection
    let size: CGSize
    @Environment(AppModel.self) private var model

    var body: some View {
        let name = model.furniture(edit.instanceId)?.shownName ?? ""
        Color.clear
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(RoomEditMode.space))
                    .onChanged { edit.drag(to: framing.touch(at: $0.location, in: size)) }
                    .onEnded { value in
                        edit.endDrag()
                        if hypot(value.translation.width, value.translation.height) < 10 {
                            edit.centre(on: framing.touch(at: value.location, in: size))
                        }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("正在摆放「\(name)」")
            .accessibilityValue(model.placementStatus(edit.issues(in: model)))
            .accessibilityHint("拖动可以移动；也可以用操作菜单一格一格地移")
            .accessibilityActions {
                if edit.onWall {
                    Button("向左移一格") { edit.slide(right: -1) }
                    Button("向右移一格") { edit.slide(right: 1) }
                    Button("换一面墙") { edit.switchWall() }
                } else {
                    Button("向左移一格") { edit.nudge(x: -1, z: 0) }
                    Button("向右移一格") { edit.nudge(x: 1, z: 0) }
                    Button("向里移一格") { edit.nudge(x: 0, z: -1) }
                    Button("向外移一格") { edit.nudge(x: 0, z: 1) }
                }
            }
            .accessibilityIdentifier("edit-surface")
    }
}

/// Stands in for the room's bottom bar while a piece is being edited.
struct RoomEditTray: View {
    let edit: RoomEditMode
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var removeAsked = false
    @State private var failure: (title: String, message: String)?

    var body: some View {
        let issues = edit.issues(in: model)
        let item = model.furniture(edit.instanceId)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("摆放「\(item?.shownName ?? "")」")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Label(model.placementStatus(issues), systemImage: issues.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(issues.isEmpty ? Color.subtle : Color.caution)
                    .lineLimit(2)
                    .accessibilityIdentifier("edit-status")
                if !edit.onWall {
                    Text(PlacementAccessGuides.legend)
                        .font(.footnote)
                        .foregroundStyle(Color.subtle)
                }
            }
            HStack(spacing: 8) {
                if edit.onWall {
                    tool(String(localized: "换墙"), "arrow.left.arrow.right", id: "edit-switch-wall") { edit.switchWall() }
                        .accessibilityHint("挂到另一面墙上")
                } else {
                    tool(String(localized: "旋转"), "rotate.right", id: "edit-rotate") { edit.rotate() }
                        .accessibilityHint("转四分之一圈")
                }
                tool(String(localized: "收进收纳箱"), "archivebox", id: "edit-stow", action: stow)
                    .accessibilityHint("照片会跟着家具一起收好，随时可以放回房间")
                tool(String(localized: "编辑家具"), "slider.horizontal.3", id: "edit-more") {
                    let id = edit.instanceId
                    edit.end()
                    model.movingFurnitureID = id
                }
                .accessibilityHint("改大小、配色或名字")
                tool(String(localized: "删除"), "trash", id: "edit-remove", role: .destructive) { removeAsked = true }
            }
            HStack(spacing: 8) {
                Button("取消", role: .cancel) { edit.end() }
                    .buttonStyle(.bordered)
                    .accessibilityHint("放回原来的位置")
                    .accessibilityIdentifier("edit-cancel")
                Button(action: save) {
                    HStack(spacing: 8) {
                        if edit.saving { ProgressView() }
                        Text("完成").font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .prominentInk()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!issues.isEmpty || edit.saving)
                .accessibilityIdentifier("edit-done")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(RoomPaper.paper)
        .overlay(alignment: .top) { Divider().overlay(RoomPaper.edge) }
        .disabled(edit.saving)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("edit-tray")
        .confirmationDialog("删除这件家具？", isPresented: $removeAsked, titleVisibility: .visible) {
            Button("删除", role: .destructive) { remove() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("家具会被删除，它的照片仍留在照片库里。只是暂时不想摆的话，可以收进收纳箱，随时能放回房间。")
        }
        .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好") {}
        } message: {
            Text(failure?.message ?? "")
        }
    }

    /// Icon over a small title, so four fit in a row on a narrow phone; the icon alone once the
    /// text is at an accessibility size.
    private func tool(_ title: String, _ symbol: String, id: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                if !typeSize.isAccessibilitySize {
                    Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    private func save() {
        guard let id = edit.instanceId, let draft = edit.draft, let item = model.furniture(id) else { return }
        guard draft != Placement(item) else { return edit.end() }
        edit.saving = true
        Task {
            let outcome = await model.move(instanceId: id, to: draft, displayName: item.displayName)
            // The edit may have been ended meanwhile (the piece went away); then there is nothing to close.
            guard edit.instanceId == id else { return }
            switch outcome {
            case .saved: edit.end()
            case .failed(let message):
                edit.saving = false
                failure = (String(localized: "没能保存"), message)
            }
        }
    }

    /// Reversible, so it is not asked about: the piece waits in the storage box with its photos.
    private func stow() {
        guard let id = edit.instanceId else { return }
        edit.saving = true
        Task {
            let message = await model.stow(instanceId: id)
            guard edit.instanceId == id else { return }
            if let message {
                edit.saving = false
                failure = (String(localized: "没能收进收纳箱"), message)
            } else {
                edit.end()
            }
        }
    }

    private func remove() {
        guard let id = edit.instanceId else { return }
        Task {
            if let message = await model.remove(instanceId: id) {
                failure = (String(localized: "没能删除"), message)
            } else if edit.instanceId == id {
                edit.end()
            }
        }
    }
}

extension View {
    /// Swaps the room's bottom bar for the edit tray while a piece is being edited.
    func replacedByEditTray(_ edit: RoomEditMode) -> some View {
        modifier(EditTraySwap(edit: edit))
    }
}

private struct EditTraySwap: ViewModifier {
    let edit: RoomEditMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.hasSideEditTray) private var hasSideEditTray

    func body(content: Content) -> some View {
        Group {
            if edit.isActive && hasSideEditTray {
                EmptyView()
            } else if edit.isActive {
                RoomEditTray(edit: edit)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            } else {
                content
            }
        }
        .animation(.snappy(duration: 0.25), value: edit.isActive)
    }
}
