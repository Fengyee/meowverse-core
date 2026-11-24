import Foundation

/// The Home Screen quick actions (long press on the app icon). Registered at run time only:
/// before the library exists there is nowhere for them to go.
public enum QuickActionKind: String, CaseIterable, Sendable {
    case camera = "app.meowverse.camera"
    case library = "app.meowverse.library"
    case companion = "app.meowverse.companion"
    case memory = "app.meowverse.memory"
}

public enum QuickActionPlan {
    /// The first item sits closest to the icon. No camera, no "Take Photo"; no piece with a
    /// photo, no "Revisit a Memory".
    public static func kinds(hasCamera: Bool, hasMemory: Bool) -> [QuickActionKind] {
        QuickActionKind.allCases.filter { kind in
            switch kind {
            case .camera: hasCamera
            case .memory: hasMemory
            case .library, .companion: true
            }
        }
    }

    /// Pieces that have at least one photo, in the room or in storage. The Home Screen never
    /// names one: the piece is chosen when the action is tapped.
    public static func memoryCandidates(in state: AppState) -> [String] {
        state.allFurniture.filter { !$0.sources.isEmpty }.map(\.instanceId)
    }

    public static func pickMemory(from candidates: [String], using generator: inout some RandomNumberGenerator) -> String? {
        candidates.randomElement(using: &generator)
    }
}
