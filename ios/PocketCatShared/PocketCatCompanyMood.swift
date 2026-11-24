import AppIntents
import Foundation

/// The expressions by name, and the choice of one in the "Keep Me Company" control (owner,
/// round 11: the control can be set to start company with a chosen expression). Foundation and
/// AppIntents only: the Core tests compile this file through a symlink
/// (`MeowverseCore/Tests/MeowverseCoreTests/PocketCatShared/`).
extension PocketCatMood {
    /// The one name for each expression: the companion page, the Live Activity, the widgets and
    /// the control's setting all use it.
    nonisolated var title: LocalizedStringResource {
        switch self {
        case .sleeping: .init("Sleeping", table: "PocketCat")
        case .playing: .init("Playing", table: "PocketCat")
        case .zoomies: .init("Zoomies", table: "PocketCat")
        case .thinking: .init("Thinking", table: "PocketCat")
        case .eating: .init("Eating", table: "PocketCat")
        case .watching: .init("Watching", table: "PocketCat")
        }
    }
}

/// The system lists the expressions from these literals (App Intents reads them at build time,
/// so they can't call `title`); `PocketCatCompanyMoodTests` keeps the two the same. A saved
/// choice is stored as the raw value.
nonisolated extension PocketCatMood: AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Expression", table: "PocketCat"))

    static let caseDisplayRepresentations: [PocketCatMood: DisplayRepresentation] = [
        .sleeping: DisplayRepresentation(title: LocalizedStringResource("Sleeping", table: "PocketCat")),
        .playing: DisplayRepresentation(title: LocalizedStringResource("Playing", table: "PocketCat")),
        .zoomies: DisplayRepresentation(title: LocalizedStringResource("Zoomies", table: "PocketCat")),
        .thinking: DisplayRepresentation(title: LocalizedStringResource("Thinking", table: "PocketCat")),
        .eating: DisplayRepresentation(title: LocalizedStringResource("Eating", table: "PocketCat")),
        .watching: DisplayRepresentation(title: LocalizedStringResource("Watching", table: "PocketCat")),
    ]
}

/// The control's one setting: which expression company starts with. The default is the one the
/// control always started with, so a control added before it had settings (same kind, no saved
/// configuration) carries on as it was. Not offered to Shortcuts: it only configures the control.
@available(iOS 18.0, macOS 26.0, *)
struct PocketCatCompanyConfiguration: ControlConfigurationIntent {
    static let title = LocalizedStringResource("Keep Me Company", table: "PocketCat")
    static let isDiscoverable = false

    // A literal, as App Intents requires; equal to `PocketCatCompanyToggle.defaultMood` (tested).
    @Parameter(title: LocalizedStringResource("Expression", table: "PocketCat"), default: .sleeping)
    var mood: PocketCatMood

    init() {}
    init(mood: PocketCatMood) { self.mood = mood }
}
