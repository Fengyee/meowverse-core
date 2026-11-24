import SwiftUI

/// Enough space for a usable 3D room and a readable inspector, including in a resized iPad window.
enum RoomColumns {
    static func fits(in width: CGFloat) -> Bool { width >= 880 }

    static func inspectorWidth(in width: CGFloat) -> CGFloat {
        min(max(360, width * 0.35), 480)
    }
}

extension EnvironmentValues {
    /// The iPad can keep Bella moving beside an inspector, even while a furniture album is open.
    @Entry var roomInspectorCoversScene: Bool? = nil
    @Entry var hasSideEditTray = false
}

extension View {
    /// Let the editor lay out its room and controls across the full available iPad window.
    @ViewBuilder func roomEditor<Item: Identifiable, Editor: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Editor
    ) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad { fullScreenCover(item: item, content: content) }
        else { sheet(item: item, content: content) }
    }

    @ViewBuilder func roomEditor<Editor: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Editor
    ) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad { fullScreenCover(isPresented: isPresented, content: content) }
        else { sheet(isPresented: isPresented, content: content) }
    }
}
