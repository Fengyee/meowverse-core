import MeowverseCore
import SwiftUI

/// How the category picker groups the catalog, so the list stays readable as categories are added.
enum CategoryGroup: CaseIterable {
    case furniture, decor, catSupplies, wall

    /// Exhaustive on purpose: a new category does not compile until it is given a group.
    init(_ category: FurnitureCategory) {
        switch category {
        case .sofa, .chair, .stool, .bench, .table, .bed: self = .furniture
        case .bookcase, .sideboard, .mediaConsole, .writingDesk, .vanity: self = .furniture
        case .coatRack, .floorLamp, .roomDivider, .plantStand, .fireplace: self = .decor
        case .catTree, .scratcher, .platform, .hideout, .toy, .litterBox, .windowPerch, .water: self = .catSupplies
        case .photoBoard: self = .wall
        }
    }

    var title: String {
        switch self {
        case .furniture: String(localized: "家具")
        case .decor: String(localized: "摆设", table: "CatalogNames")
        case .catSupplies: String(localized: "猫咪用品")
        case .wall: String(localized: "墙面")
        }
    }

    /// The sofa leads: it is what most photos show. `photosOnly`: the photo review lists only
    /// what recognition can name (the household categories are catalogue-only).
    func categories(photosOnly: Bool = false) -> [FurnitureCategory] {
        let own = FurnitureCategory.allCases.filter { CategoryGroup($0) == self && (!photosOnly || $0.isRecognisedFromPhotos) }
        return own.filter { $0 == .sofa } + own.filter { $0 != .sofa }
    }
}

/// One selectable row with a check mark; used for categories, suggestions and models.
struct ChoiceRow: View {
    let title: String
    var detail: String?
    let symbol: String
    let selected: Bool
    var compact = false
    let action: () -> Void
    /// Grows with the text, so a large symbol never runs into the title.
    @ScaledMetric(relativeTo: .body) private var symbolWidth = 28

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 8 : 12) {
                Image(systemName: symbol)
                    .foregroundStyle(RoomPaper.ink)
                    .frame(width: symbolWidth, height: symbolWidth)
                    .background(RoomPaper.edge.opacity(0.17), in: .rect(cornerRadius: 6))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    if let detail {
                        Text(detail).font(.footnote).foregroundStyle(Color.subtle)
                    }
                }
                Spacer()
                if selected || !compact {
                    MemorySelectionMark(isSelected: selected)
                        .frame(width: 19, height: 19)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .memoryCard(.workshop)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(RoomPaper.ink, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Every category under its group heading. Headings rather than a segmented control: each
/// category stays one tap away, and nothing is squeezed at the largest text sizes.
struct CategoryPicker: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let selected: FurnitureCategory?
    /// One line under the 墙面 group, when there is something worth saying about it.
    var wallHint: String?
    /// The photo review: only categories recognition can name (`isRecognisedFromPhotos`).
    var photosOnly = false
    let choose: (FurnitureCategory) -> Void

    private func rows(_ categories: [FurnitureCategory], columns: Int) -> [[FurnitureCategory]] {
        stride(from: 0, to: categories.count, by: columns).map { Array(categories[$0..<min($0 + columns, categories.count)]) }
    }

    // Not lazy: every category exists as soon as the screen does, also below the fold.
    private func cells(_ categories: [FurnitureCategory], columns: Int) -> some View {
        VStack(spacing: 8) {
            ForEach(rows(categories, columns: columns), id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { category in
                        ChoiceRow(title: category.title, symbol: category.symbol, selected: selected == category, compact: columns == 2) {
                            choose(category)
                        }
                        .frame(maxHeight: .infinity)
                        .accessibilityIdentifier("manual-\(category.rawValue)")
                    }
                    // Keeps a lone last cell at column width.
                    if row.count < columns { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(CategoryGroup.allCases.filter { !$0.categories(photosOnly: photosOnly).isEmpty }, id: \.self) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title)
                        .font(.system(.headline, design: .serif, weight: .semibold))
                        .foregroundStyle(Color.subtle)
                        .accessibilityAddTraits(.isHeader)
                    cells(group.categories(photosOnly: photosOnly), columns: typeSize.isAccessibilitySize ? 1 : 2)
                    if group == .wall, let wallHint {
                        Text(wallHint)
                            .font(.footnote)
                            .foregroundStyle(Color.subtle)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("photo-board-hint")
                    }
                }
            }
        }
    }
}

/// The models of one category with a 3D preview of the chosen one.
struct ModelChooser: View {
    let models: [CatalogModel]
    @Binding var chosenID: String?
    let finish: Finish

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let chosen = models.first(where: { $0.id == chosenID }) {
                VStack(alignment: .leading, spacing: 4) {
                    ModelPreviewView(model: chosen, finish: finish)
                        .frame(height: 198)
                        .clipShape(.rect(cornerRadius: 8))
                        .accessibilityLabel("\(chosen.title) 的预览")
                    HStack(spacing: 8) {
                        MemoryEmblem(.workshop).frame(width: 36, height: 27)
                        Text(chosen.title)
                            .font(.system(.headline, design: .serif, weight: .semibold))
                            .foregroundStyle(RoomPaper.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 3)
                    .accessibilityHidden(true)
                }
                .padding(5)
                .memoryCard(.workshop)
            }
            ForEach(models) { candidate in
                ChoiceRow(title: candidate.title, detail: Self.detail(candidate), symbol: candidate.category.symbol,
                          selected: candidate.id == chosenID) {
                    chosenID = candidate.id
                }
                .accessibilityIdentifier("model-\(candidate.id)")
            }
        }
    }

    private static func detail(_ candidate: CatalogModel) -> String {
        let size = candidate.mount == .wall ? String(localized: "挂在墙上，宽 \(candidate.defaultWidth) 格") : String(localized: "占 \(candidate.defaultWidth)×\(candidate.defaultDepth) 格")
        guard let sites = candidate.sites else { return size }
        if candidate.isDecorative { return size + " · " + String(localized: "摆设，猫咪会绕开", table: "CatalogNames") }
        let actions = CatAction.allCases.filter { action in sites.contains { $0.actions.contains(action) } }
        return size + " · " + actions.map(\.menuTitle).joined(separator: String(localized: "、"))
    }
}
