// Compiled only with MEOWVERSE_TALK_TO_BELLA=YES (Config.xcconfig): not in 1.0.
#if MEOWVERSE_TALK_TO_BELLA
import SwiftUI

/// The head in the room's bottom-right corner with its hint to the leading side. The look is
/// `BellaVoiceButton` and `BellaVoiceHint` (UI artist); this view only supplies the state, the
/// words and the tap.
struct TalkToBellaHead: View {
    let talk: TalkToBellaController
    let catName: String
    /// False while something else asks for attention first ("房间还是空的"): the "tap me" line waits.
    var canIntroduce = true
    let tap: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if let hint = talk.hint {
                BellaVoiceHint(text: Text(verbatim: hint))
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("talk-to-bella-hint")
                    .transition(.opacity)
            }
            BellaVoiceButton(state: talk.state,
                             accessibilityLabel: Text("和\(Wording.inline(catName))说话", tableName: "TalkToBella"),
                             accessibilityValue: stateValue,
                             action: tap)
                .accessibilityHint(talk.state == .unavailable
                                   ? Text("点按打开互动", tableName: "TalkToBella")
                                   : Text("点按后说一句话，比如“去沙发上躺着”；说完会自动停", tableName: "TalkToBella"))
        }
        .animation(.easeOut(duration: 0.2), value: talk.hint)
        .onChange(of: canIntroduce, initial: true) { _, free in
            if free { talk.introduce(catName: catName) }
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if TalkToBellaController.TestHook.transcript != nil {
                // UI tests only (`-TalkToBellaTranscript`): which part answered and what it led to.
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(Text(verbatim: "talk-to-bella-probe"))
                    .accessibilityValue(Text(verbatim: talk.probe))
                    .accessibilityIdentifier("talk-to-bella-probe")
            }
        }
        #endif
    }

    private var stateValue: Text {
        switch talk.state {
        case .idle: Text("等你说话", tableName: "TalkToBella")
        case .listening: Text("正在听", tableName: "TalkToBella")
        case .thinking: Text("正在想", tableName: "TalkToBella")
        case .understood: Text("听懂了", tableName: "TalkToBella")
        case .puzzled:
            if let hint = talk.hint { Text(verbatim: hint) } else { Text("没做到", tableName: "TalkToBella") }
        case .unavailable: Text("语音不可用", tableName: "TalkToBella")
        }
    }
}

/// Keeps Talk to Bella in step with the room: availability is checked on appearing and on
/// coming back to the app (a permission may have changed in Settings), and a request on its way
/// is dropped once the room stops accepting answers or the person ends the play by hand.
struct TalkToBellaLifecycle: ViewModifier {
    let talk: TalkToBellaController
    let accepting: Bool
    let playing: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { talk.refreshAvailability() }
            .onDisappear { talk.cancel() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { talk.refreshAvailability() }
            }
            .onChange(of: accepting) { _, open in
                if !open { talk.cancel() }
            }
            .onChange(of: playing) { _, active in
                guard !active else { return }
                switch talk.state {
                case .listening, .thinking: talk.cancel()
                default: break
                }
            }
    }
}
#endif
