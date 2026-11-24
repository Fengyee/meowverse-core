import ActivityKit
import SwiftUI
import WidgetKit

/// The extension: the companion's Live Activity, the round-11 controls and the round-11 Home
/// Screen and Lock Screen widgets. The activity keeps its type and configuration, so a
/// companion that is running across an update carries on.
@main
struct PocketCatWidgets: WidgetBundle {
    var body: some Widget {
        PocketCatWidget()
        PocketCatCompanyControl()
        PocketCatTakePhotoControl()
        PocketCatAddFromPhotosControl()
        PocketCatHomeWidget()
        PocketCatLockWidget()
    }
}

struct PocketCatWidget: Widget {
    private var returnURL: URL? {
        guard let host = Bundle.main.object(forInfoDictionaryKey: "MeowverseHostBundleID") as? String else { return nil }
        return PocketCatLink.url(for: host)
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PocketCatAttributes.self) { context in
            PocketCatLockScreen(context: context)
                .widgetURL(returnURL)
                .activityBackgroundTint(Color(red: 0.12, green: 0.18, blue: 0.15))
                .activitySystemActionForegroundColor(.white)
                .foregroundStyle(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    PocketCatDisplay(state: context.state) { PocketCatStatus(mood: $0, caption: .title) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PocketCatActions(sessionID: context.activityID)
                }
            } compactLeading: {
                PocketCatDisplay(state: context.state) { PocketCatPortrait(mood: $0, size: 20) }
            } compactTrailing: {
                EmptyView()
            } minimal: {
                PocketCatDisplay(state: context.state) { PocketCatPortrait(mood: $0, size: 20) }
            }
            .widgetURL(returnURL)
        }
        // The watch's Smart Stack (and CarPlay) get their own layout from the Lock Screen
        // closure; without this they borrow the compact island, a lone head beside a gap.
        .supplementalActivityFamilies([.small])
    }
}

/// The Lock Screen (`.medium`) and the watch (`.small`) share the system's one closure.
private struct PocketCatLockScreen: View {
    @Environment(\.activityFamily) private var family
    let context: ActivityViewContext<PocketCatAttributes>

    var body: some View {
        let name = context.attributes.shownName
        switch family {
        case .small:
            PocketCatDisplay(state: context.state, name: name) { PocketCatWatchStatus(name: name, mood: $0) }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        default:
            // The Lock Screen as approved, with the cat's name in place of "Keep me company"
            // (owner, 2026-11-19).
            ViewThatFits(in: .horizontal) {
                HStack {
                    PocketCatDisplay(state: context.state, name: name) { PocketCatStatus(mood: $0, caption: .name(name)) }
                    Spacer(minLength: 8)
                    PocketCatActions(sessionID: context.activityID)
                }
                VStack(alignment: .leading) {
                    PocketCatDisplay(state: context.state, name: name) { PocketCatStatus(mood: $0, caption: .name(name)) }
                    PocketCatActions(sessionID: context.activityID)
                }
            }
            .padding()
        }
    }
}

private struct PocketCatStatus: View {
    enum Caption {
        /// "Keep me company", as the expanded island has always shown.
        case title
        /// The cat's name, or the title when there is none.
        case name(String?)
    }

    let mood: PocketCatMood
    let caption: Caption

    var body: some View {
        HStack(spacing: 10) {
            PocketCatPortrait(mood: mood, size: 32, art: .figure).accessibilityHidden(true)
            VStack(alignment: .leading) {
                switch caption {
                case .title: Text(PocketCatCopy.title).font(.caption)
                case .name(let name): PocketCatNameLine(name: name).font(.caption)
                }
                Text(mood.title).font(.headline)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PocketCatActions: View {
    let sessionID: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            buttons(showsTitles: true).fixedSize(horizontal: true, vertical: false)
            buttons(showsTitles: false)
        }
        .buttonStyle(.bordered)
        .tint(.white)
    }

    private func buttons(showsTitles: Bool) -> some View {
        HStack {
            Button(intent: ChangePocketCatMood(sessionID: sessionID)) {
                if showsTitles { Text(PocketCatCopy.change) } else { Image(systemName: "face.smiling") }
            }
            .accessibilityLabel(Text(PocketCatCopy.change))
            .accessibilityIdentifier("pocket-change")
            Button(intent: EndPocketCatCompany(sessionID: sessionID)) {
                if showsTitles { Text(PocketCatCopy.end) } else { Image(systemName: "stop.fill") }
            }
            .accessibilityLabel(Text(PocketCatCopy.end))
            .accessibilityIdentifier("pocket-end")
        }
    }
}
