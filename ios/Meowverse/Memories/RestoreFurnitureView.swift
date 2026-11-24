import MeowverseCore
import SwiftUI

/// Brings a piece back from the storage box. It returns to where it stood when that spot is
/// still allowed, otherwise to the first free one; either way the user confirms the placement.
struct RestoreFurnitureView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let item: PhotoFurniture
    @State private var placement: Placement?
    @State private var displayName: String
    @State private var saving = false
    @State private var failure: String?

    init(item: PhotoFurniture) {
        self.item = item
        _displayName = State(initialValue: item.shownName)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let piece = app.catalog?.model(id: item.modelId), let binding = Binding($placement) {
                    PlacementEditor(
                        placement: binding, displayName: $displayName, model: piece, ignoring: nil,
                        confirmTitle: String(localized: "放回房间"), busy: saving, onConfirm: save)
                } else if app.catalog?.model(id: item.modelId) == nil {
                    ContentUnavailableView("找不到这个款式", systemImage: "questionmark.square.dashed")
                }
            }
            .memoryPage(.workshop)
            .navigationTitle("放回「\(item.shownName)」")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.accessibilityIdentifier("cancel-restore-furniture")
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .onAppear { if placement == nil { placement = startingPlacement } }
        .alert("没能保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("重试") { save() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var startingPlacement: Placement {
        guard let catalog = app.catalog else { return item.placement }
        return GridRules.placementForTransfer(item.placement, in: app.roomFurniture, catalog: catalog) ?? item.placement
    }

    private func save() {
        guard let placement, !saving else { return }
        saving = true
        Task {
            let outcome = await app.restore(instanceId: item.instanceId, placement: placement, displayName: displayName)
            saving = false
            switch outcome {
            case .saved: dismiss()
            case .failed(let message): failure = message
            }
        }
    }
}
