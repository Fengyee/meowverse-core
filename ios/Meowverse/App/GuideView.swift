import SwiftUI

/// Three short steps in the cat's voice, adapted from the web guide (src/features/settings/BellaGuide.tsx).
///
/// No longer opened: 「看看怎么玩」 starts the tour instead (PRODUCT_PLAN §4.2, §4.3). Kept for its
/// paged layout, which the tour's page mode is to borrow.
struct GuideView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Called when the user asks to start by adding a photo.
    let onAddPhoto: () -> Void
    @State private var step = 0

    private struct Stop {
        let title: String
        let words: String
    }

    private var stops: [Stop] { [
        // With iCloud backup or sync on, the copies Meowverse keeps do go to the user's iCloud.
        Stop(title: String(localized: "带一张照片回家"), words: model.photoReach.guideWords),
        Stop(title: String(localized: "给照片找到家具"),
             words: String(localized: "这台设备会猜照片里是什么家具，猜错了你可以改，也可以全部自己选。新照片还能加到房间里已有的家具上。")),
        Stop(title: String(localized: "回房间看回忆"),
             words: String(localized: "点一下家具，就能翻看让它搬进来的那些照片。房间开着的时候，我会自己走一走，找地方休息。")),
    ] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    MemoryEmblem([.album, .workshop, .home][step])
                        .frame(width: 120, height: 84)
                    Text(stops[step].title)
                        .font(.system(.title2, design: .serif, weight: .bold))
                        .multilineTextAlignment(.center)
                    Text(stops[step].words)
                        .font(.body)
                        .multilineTextAlignment(.center)
                    Text("第 \(step + 1) 步，共 \(stops.count) 步")
                        .font(.footnote)
                        .foregroundStyle(Color.subtle)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("guide-stop")
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                    if step < stops.count - 1 {
                        primaryButton(String(localized: "下一步"), enabled: true) { step += 1 }
                            .accessibilityIdentifier("guide-next")
                    } else {
                        primaryButton(String(localized: "去添加照片"), enabled: true) {
                            dismiss()
                            onAddPhoto()
                        }
                        .accessibilityIdentifier("guide-add-photo")
                    }
                    if step > 0 {
                        Button("上一步") { step -= 1 }
                            .padding(.bottom, 8)
                    }
                }
            }
            .memoryPage(.home)
            .navigationTitle("怎么玩")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("close-guide")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
