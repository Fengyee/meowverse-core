import Foundation

// Talk to Bella (docs/TALK_TO_BELLA.md): one spoken sentence becomes one of these, never free
// text. Lead-owned contract: change it through the lead, not in a feature branch.

/// What the owner asked the cat to do, understood from one sentence.
public enum BellaCommand: Equatable, Hashable, Sendable, Codable {
    /// Go to a piece of furniture and do `action` at one of its interaction sites.
    /// `target` nil: any piece in the room that offers the action ("去睡一会儿").
    case visit(action: CatAction, target: FurnitureCategory?)
    /// Play with a toy, or eat a treat when `treat` is true ("去玩一会儿", "吃点零食").
    case play(treat: Bool)
    /// Walk to the front of the room, toward the person holding the phone ("过来").
    case comeHere
    /// Nothing the cat can do ("给我唱首歌"). She stays where she is and looks puzzled.
    case unsupported
}

/// Which part of the pipeline produced a command. Kept so a model answer is never presented
/// or recorded as if a fixed rule had matched (AGENTS.md: modes must be distinguishable).
public enum BellaCommandSource: String, Equatable, Sendable, Codable {
    /// `BellaCommandRules`: a fixed phrase, no model involved.
    case rules
    /// The on-device Foundation Models language model (iOS 26+, Apple Intelligence on).
    case model
}

public struct BellaUnderstanding: Equatable, Sendable {
    public let command: BellaCommand
    public let source: BellaCommandSource

    public init(command: BellaCommand, source: BellaCommandSource) {
        self.command = command
        self.source = source
    }
}

/// What the room will actually do. The app turns each case into the same calls the
/// Interactions menu makes, so voice and menu can never disagree about what is possible.
public enum BellaPlan: Equatable, Sendable {
    /// `CatInvitation(itemId:siteId:action:)`, exactly as the menu's buttons.
    case invite(itemId: String, siteId: String, action: CatAction)
    /// `RoomPlaySession.begin(item)` then `placeNext`, as choosing a toy or treat does.
    case play(CatPlayItem)
    /// A floor walk to `cell`; she sits there facing the camera.
    case come(to: GridCell)
}

/// Why a command cannot be carried out in this room right now. The app shows each as a short
/// puzzled reaction; none of them moves the cat.
public enum BellaRefusal: Error, Equatable, Sendable {
    /// `BellaCommand.unsupported`, or nothing usable was heard.
    case notUnderstood
    /// No piece of that category (nil: no piece at all) offers the action in this room.
    case noSuchFurniture(FurnitureCategory?)
    /// There is such a piece, but every site that offers the action is blocked.
    case blocked
}
