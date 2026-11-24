#if DEBUG
import SwiftUI

/// DEBUG only: the Talk to Bella head in all six states, the hint, and the head in the room's
/// bottom-right corner above 互动 and 添加照片, for review before the room wires it.
/// `-MeowverseOverlayGallery bella`; add `-MeowverseGalleryReduceMotion` to draw every head as
/// under Reduce Motion (the row "reduce motion" always is). Captions are the gallery's own, not
/// shipped copy.
struct BellaVoiceGallery: View {
    @Environment(\.colorScheme) private var scheme
    private let reducesMotion = ProcessInfo.processInfo.arguments.contains("-MeowverseGalleryReduceMotion")

    private let states: [(String, BellaVoiceState)] = [
        ("idle", .idle),
        ("listening 0.2", .listening(level: 0.2)),
        ("listening 0.9", .listening(level: 0.9)),
        ("thinking", .thinking),
        ("understood", .understood),
        ("puzzled", .puzzled),
        ("unavailable", .unavailable),
    ]

    var body: some View {
        ZStack {
            (scheme == .dark ? Color(red: 0.17, green: 0.15, blue: 0.13) : Color(red: 0.953, green: 0.918, blue: 0.859))
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 14) {
                        ForEach(states, id: \.0) { name, state in
                            VStack(spacing: 10) {
                                head(state)
                                caption(name)
                            }
                        }
                    }
                    .padding(.top, 8)
                    VStack(alignment: .trailing, spacing: 8) {
                        hinted(.puzzled, "房间里还没有沙发") // not-localized: debug gallery sample
                        hinted(.puzzled, "There’s no sofa in this room yet") // not-localized: debug gallery sample
                        hinted(.puzzled, "房间里还没有沙发") // not-localized: debug gallery sample
                            .dynamicTypeSize(.accessibility2)
                        hinted(.unavailable, "这台设备不能在本机识别语音，可以用互动菜单") // not-localized: debug gallery sample
                            .dynamicTypeSize(.accessibility5)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    caption("reduce motion: puzzled, listening 0.2 / 0.9, unavailable")
                    HStack(spacing: 22) {
                        head(.puzzled)
                        head(.listening(level: 0.2))
                        head(.listening(level: 0.9))
                        head(.unavailable)
                    }
                    .padding(.leading, 8)
                    .environment(\.bellaPreviewsReduceMotion, true)
                    caption("room corner")
                    roomCorner
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .environment(\.bellaPreviewsReduceMotion, reducesMotion)
    }

    private func head(_ state: BellaVoiceState) -> some View {
        BellaVoiceButton(state: state, accessibilityLabel: Text(verbatim: "Bella"), // not-localized: debug gallery
                         accessibilityValue: Text(verbatim: ""), action: {})
    }

    private func hinted(_ state: BellaVoiceState, _ words: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            BellaVoiceHint(text: Text(verbatim: words))
            head(state)
        }
    }

    private func caption(_ name: String) -> some View {
        Text(verbatim: name)
            .font(.caption2.monospaced())
            .foregroundStyle(RoomPaper.ink.opacity(0.7))
    }

    private var roomCorner: some View {
        VStack(alignment: .trailing, spacing: 10) {
            hinted(.listening(level: 0.6), "房间里还没有沙发") // not-localized: debug gallery sample
                .padding(.trailing, 4)
            HStack(alignment: .bottom) {
                RoomLibraryControls(photos: {}, furniture: {})
                Spacer(minLength: 8)
                RoomActionControls(hasCat: true, canAdd: true, interact: {}, addPhoto: {})
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.62, green: 0.72, blue: 0.66), in: .rect(cornerRadius: 12))
    }
}
#endif
