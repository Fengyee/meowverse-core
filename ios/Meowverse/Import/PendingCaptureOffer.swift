import MeowverseCore
import SwiftUI

/// At launch, offers back a photo taken in the app that the last run left unconfirmed
/// (JOURNEY-NEW-4, owner 2026-11-22). One question: 继续 reopens the same review, 不要了
/// deletes the held file. Until the user confirms in that review, nothing is in the library.
struct PendingCaptureOffer: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .task(id: model.phase) {
                if model.phase == .ready { await model.findPendingCapture() }
            }
            .alert("上次拍的照片还没有保存，要继续吗？", isPresented: shown) {
                Button("继续") { model.resumePendingCapture() }
                // No destructive role: with one, the system adds a third button, 取消.
                Button("不要了") { model.discardPendingCapture() }
            } message: {
                Text("它只暂存在这台设备上，还没有放进喵空间。")
            }
    }

    private var shown: Binding<Bool> {
        Binding(get: { model.pendingCaptureOffer != nil },
                // Dismissed by the system without an answer: the photo stays held, asked next launch.
                set: { if !$0 { model.pendingCaptureOffer = nil } })
    }
}
