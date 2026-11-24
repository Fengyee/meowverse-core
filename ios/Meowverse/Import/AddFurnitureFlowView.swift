import MeowverseCore
import SwiftUI

/// "先布置房间": category → model → placement, straight from the catalog. The piece has no
/// photos and claims none; they can be added to it afterwards. Nothing is saved until the
/// placement is confirmed, so closing the sheet at any step leaves the room as it was.
struct AddFurnitureFlowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onPlaced: () -> Void

    enum Step: Hashable { case model, placement }
    @State private var path: [Step] = []
    @State private var category: FurnitureCategory?
    @State private var chosenModelID: String?
    @State private var placement: Placement?
    @State private var displayName = ""
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        NavigationStack(path: $path) {
            categoryStep
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .model: modelStep
                    case .placement: placementStep
                    }
                }
        }
        .interactiveDismissDisabled(saving)
        .sensoryFeedback(.selection, trigger: category)
        .sensoryFeedback(.selection, trigger: chosenModelID)
        .sensoryFeedback(.error, trigger: failure) { _, failure in failure != nil }
        .alert("没能保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("重试") { save() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var models: [CatalogModel] {
        guard let category, let catalog = model.catalog else { return [] }
        return catalog.models(in: category)
    }

    private var chosenModel: CatalogModel? {
        models.first { $0.id == chosenModelID }
    }

    private var categoryStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("选一件家具摆进房间。它先不带照片，之后随时可以给它添。")
                    .font(.subheadline)
                    .foregroundStyle(Color.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                CategoryPicker(selected: category) { category = $0 }
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            primaryButton(String(localized: "下一步：选款式"), enabled: category != nil) {
                if chosenModel == nil { chosenModelID = models.first?.id }
                path.append(.model)
            }
            .accessibilityIdentifier("next-model")
        }
        .memoryPage(.workshop)
        .navigationTitle("添加家具")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }.accessibilityIdentifier("cancel-add-furniture")
            }
        }
    }

    private var modelStep: some View {
        ScrollView {
            ModelChooser(models: models, chosenID: $chosenModelID, finish: placement?.finish ?? .original)
                .padding()
        }
        .safeAreaInset(edge: .bottom) {
            primaryButton(String(localized: "下一步：摆放"), enabled: chosenModel != nil) {
                guard let chosenModel else { return }
                if placement?.modelId != chosenModel.id {
                    placement = model.suggestedPlacement(for: chosenModel)
                    displayName = chosenModel.title
                }
                path.append(.placement)
            }
            .accessibilityIdentifier("next-placement")
        }
        .memoryPage(.workshop)
        .navigationTitle("选款式")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var placementStep: some View {
        if let chosenModel, let binding = Binding($placement) {
            PlacementEditor(
                placement: binding,
                displayName: $displayName,
                model: chosenModel,
                ignoring: nil,
                confirmTitle: String(localized: "确认摆放"),
                busy: saving,
                onConfirm: save
            )
            .memoryPage(.workshop)
            .navigationTitle("摆放")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(saving)
        }
    }

    private func save() {
        guard let placement, !saving else { return }
        saving = true
        Task {
            let outcome = await model.addFurniture(placement: placement, displayName: displayName)
            saving = false
            switch outcome {
            case .saved:
                onPlaced()
                dismiss()
            case .failed(let message):
                failure = message
            }
        }
    }
}
