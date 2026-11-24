import SwiftUI

struct RoomActionControls: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var widthClass
    let hasCat: Bool
    let canAdd: Bool
    let interact: () -> Void
    let addPhoto: () -> Void
    /// Set where a camera is available: "添加照片" then asks between the library and the camera.
    var takePhoto: (() -> Void)?

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 5))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 6))
        layout {
            control("互动", image: "RoomPlayPaw", id: "choose-interaction",
                    hint: "选玩具、喂零食，或邀请猫咪到家具上活动", enabled: hasCat, action: interact)
            let stacks = widthClass == .compact && typeSize >= .accessibility4
            if let takePhoto {
                control("添加照片", image: "RoomAddCamera", id: "add-photo",
                        hint: "从相册选照片，或者拍一张新照片。只有你选中的照片会被读取。", enabled: canAdd,
                        stacksLongLabel: stacks) { label in
                    Menu {
                        Button("从相册选择", systemImage: "photo.on.rectangle", action: addPhoto)
                            .accessibilityIdentifier("add-photo-library")
                        Button("拍照", systemImage: "camera", action: takePhoto)
                            .accessibilityIdentifier("add-photo-camera")
                    } label: { label }
                }
            } else {
                control("添加照片", image: "RoomAddCamera", id: "add-photo",
                        hint: "从相册选照片，可以一次选多张。只有你选中的会被读取。", enabled: canAdd,
                        stacksLongLabel: stacks, action: addPhoto)
            }
        }
    }

    private func control(_ title: LocalizedStringKey, image: String, id: String, hint: LocalizedStringKey,
                         enabled: Bool, stacksLongLabel: Bool = false, action: @escaping () -> Void) -> some View {
        control(title, image: image, id: id, hint: hint, enabled: enabled, stacksLongLabel: stacksLongLabel) { label in
            Button(action: action) { label }
        }
    }

    private func control(_ title: LocalizedStringKey, image: String, id: String, hint: LocalizedStringKey,
                         enabled: Bool, stacksLongLabel: Bool = false,
                         @ViewBuilder trigger: (AnyView) -> some View) -> some View {
        trigger(AnyView(controlLabel(title, image: image, stacksLongLabel: stacksLongLabel)))
        .buttonStyle(.plain)
        .disabled(!enabled)
        .saturation(enabled ? 1 : 0)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(hint))
        .accessibilityIdentifier(id)
        .tourAnchor(id, padding: 3)
        .accessibilityShowsLargeContentViewer { Label { Text(title) } icon: { Image(image) } }
    }

    private func controlLabel(_ title: LocalizedStringKey, image: String, stacksLongLabel: Bool) -> some View {
        Group {
            let placesIconBesideText = typeSize.isAccessibilitySize && !stacksLongLabel
            let layout = placesIconBesideText
                ? AnyLayout(HStackLayout(spacing: 2))
                : AnyLayout(VStackLayout(spacing: -3))
            layout {
                Image(image).renderingMode(.original).resizable().scaledToFit()
                    .frame(width: typeSize.isAccessibilitySize ? 31 : 47,
                           height: typeSize.isAccessibilitySize ? 31 : 44)
                    .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
                Text(title)
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .roomPaper(corner: 5)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
    }
}
