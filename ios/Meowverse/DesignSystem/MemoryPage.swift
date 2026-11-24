import SwiftUI

enum MemoryChapter: String {
    case home, album, workshop, companion, postcard

    var accent: Color {
        switch self {
        case .home, .workshop: RoomPaper.moss
        case .album, .postcard: RoomPaper.clay
        case .companion: RoomPaper.teal
        }
    }

    fileprivate var illustration: String {
        switch self {
        case .home: "MemoryHouse"
        case .album: "MemoryAlbum"
        case .workshop: "MemoryWorkshop"
        case .companion: "MemoryCompanion"
        case .postcard: "MemoryPostcard"
        }
    }
}

struct MemoryEmblem: View {
    let chapter: MemoryChapter
    init(_ chapter: MemoryChapter) { self.chapter = chapter }

    var body: some View {
        Image(decorative: chapter.illustration)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// The line beside a book's gutter is deliberately outside the reading column.
private struct MemoryPaperBackground: View {
    let chapter: MemoryChapter

    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(colors: [RoomPaper.leaf, RoomPaper.flyleaf],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(chapter.accent.opacity(0.17))
                .frame(width: 1).padding(.leading, 5)
            Rectangle().fill(RoomPaper.edge.opacity(0.28))
                .frame(width: 1).padding(.leading, 8)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

extension View {
    func memoryPage(_ chapter: MemoryChapter) -> some View {
        scrollContentBackground(.hidden)
            .background { MemoryPaperBackground(chapter: chapter) }
            .toolbarBackground(RoomPaper.leaf, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .fontDesign(.rounded)
            .tint(chapter.accent)
    }

    func memoryCard(_ chapter: MemoryChapter) -> some View {
        background {
            RoundedRectangle(cornerRadius: RoomPaper.cardCorner, style: .continuous)
                .fill(RoomPaper.sheet)
                .overlay {
                    RoundedRectangle(cornerRadius: RoomPaper.cardCorner, style: .continuous)
                        .strokeBorder(chapter.accent.opacity(0.27))
                }
                .shadow(color: Color.black.opacity(0.13), radius: 2, y: 2)
        }
    }

    /// The mat lies outside the image. Corner mounts stay fixed as its aspect ratio changes.
    func memoryPhotoMount() -> some View {
        padding(7)
            .background(RoomPaper.photoMat)
            .overlay { Rectangle().strokeBorder(RoomPaper.edge.opacity(0.7)) }
            .overlay(alignment: .topLeading) { PhotoCornerMount().padding(2) }
            .overlay(alignment: .bottomTrailing) { PhotoCornerMount().rotationEffect(.degrees(180)).padding(2) }
            .shadow(color: Color.black.opacity(0.13), radius: 2, y: 2)
    }
}

private struct PhotoCornerMount: View {
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: 12, y: 0))
            p.addLine(to: CGPoint(x: 0, y: 12))
            p.closeSubpath()
        }
        .fill(RoomPaper.mount)
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Add to a choice that already supplies its accessibility label and selection trait.
struct MemorySelectionMark: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle().fill(isSelected ? RoomPaper.moss : RoomPaper.sheet)
            Circle().strokeBorder(isSelected ? RoomPaper.moss : RoomPaper.edge, lineWidth: 1.5)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(RoomPaper.sealInk)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Batch actions keep their labels readable even when the selection is empty.
struct MemoryCommandStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let activeInk = configuration.role == .destructive ? RoomPaper.destructiveInk : tint
        configuration.label
            .foregroundStyle(isEnabled ? activeInk : Color.subtle)
            .background {
                if isEnabled {
                    shape.fill(configuration.isPressed ? RoomPaper.flyleaf : RoomPaper.sheet)
                }
            }
    }
}

/// The words on a `.borderedProminent` button: the accent and the chapter tints turn light in
/// dark mode, where the system's white is about 1.8:1. A disabled button keeps the system's grey.
private struct ProminentInk: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.foregroundStyle(RoomPaper.sealInk)
        } else {
            content
        }
    }
}

extension View {
    /// Put it on the button's label, not on the button.
    func prominentInk() -> some View { modifier(ProminentInk()) }
}
