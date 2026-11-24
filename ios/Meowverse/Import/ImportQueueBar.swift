import SwiftUI

/// Above the room's bottom bar: how far a background import is (then how far its photos are
/// being compared on this device), and how many stored photos still wait to be sorted into
/// furniture. Absent when there is nothing to say.
struct ImportQueueBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PhotoStorageBanner()
        if let progress = model.batch.progress {
            BatchProgressBar(phase: .importing, done: progress.shown, total: progress.total,
                             note: Text("iCloud 里的原图要先下载，需要网络，可能要等一会儿。可以先做别的，导入会接着进行。")) {
                model.cancelBatchImport()
            }
        } else if let adding = model.photos.adding {
            // Photos being added to one piece: the page that started it may be closed by now.
            BatchProgressBar(phase: .importing, done: adding.shown, total: adding.total,
                             note: Text("iCloud 里的原图要先下载，需要网络，可能要等一会儿。可以先做别的，导入会接着进行。"))
        } else if model.importSession == nil {
            if let recognition = model.batch.suggestions.recognition, recognition.phase == .recognising {
                // Sorting is offered only once the prints are made (owner, round 8): until then
                // the photos would be compared with nothing. Preparing cannot be skipped.
                if recognition.shown {
                    BatchProgressBar(phase: .recognizing, done: recognition.completed, total: recognition.total)
                }
            } else if !model.pendingPhotoIds.isEmpty {
                let count = model.pendingPhotoIds.count
                row {
                    MemoryEmblem(.album).frame(width: 32, height: 27)
                    Text("\(count) 张照片待整理")
                        .accessibilityIdentifier("pending-count")
                } action: {
                    Button("整理") { model.startSorting() }
                        .accessibilityHint("逐张决定照片放进哪件家具。可以随时停下。")
                        .accessibilityIdentifier("start-sorting")
                        // 8.1's window (LINES.md T5.1). The bordered button's capsule.
                        .tourAnchor("start-sorting", form: .plate(corner: 18))
                }
            }
        }
    }

    private func row(@ViewBuilder label: () -> some View, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 10) {
            label()
            Spacer(minLength: 8)
            action()
                .buttonStyle(.bordered)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(RoomPaper.paper)
        .overlay(alignment: .top) { Divider().overlay(RoomPaper.edge) }
    }
}
