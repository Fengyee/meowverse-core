/// What the placement preview's draft model is built from: the model, its size and finish, the
/// stored piece it stands in for (nil while adding a new one) and how much detail it is drawn
/// with. Where it stands, which wall it hangs on and which way it faces are not part of it: those
/// only move the model that is already there.
public struct PlacementPreviewKey<Details: Equatable>: Equatable {
    public let modelId: String
    public let width: Int
    public let depth: Int
    public let finish: Finish
    public let lifted: String?
    public let details: Details

    public init(_ placement: Placement, lifted: String?, details: Details) {
        modelId = placement.modelId
        width = placement.width
        depth = placement.depth
        finish = placement.finish
        self.lifted = lifted
        self.details = details
    }
}

/// How the draft model follows a change of the draft.
public struct PlacementPreviewPlan: Equatable {
    /// The model already loaded or loading for the draft stays and is moved to the new place.
    public let keepsHeld: Bool
    /// A model is loaded for the new draft.
    public let startsLoad: Bool

    public init(keepsHeld: Bool, startsLoad: Bool) {
        self.keepsHeld = keepsHeld
        self.startsLoad = startsLoad
    }

    /// The draft's model shows where the piece may stand, and always for a lifted piece; a new
    /// piece on a cell it may not take shows only its footprint.
    public static func showsModel(valid: Bool, lifted: String?) -> Bool {
        lifted != nil || valid
    }

    /// `held`: what the model loaded or loading now was built from. `wanted`: what the new draft
    /// needs (nil when there is no draft or its model is unknown). `shows`: `showsModel`.
    public static func plan<Details>(held: PlacementPreviewKey<Details>?, wanted: PlacementPreviewKey<Details>?,
                                     shows: Bool) -> PlacementPreviewPlan {
        let keeps = held != nil && held == wanted
        return PlacementPreviewPlan(keepsHeld: keeps, startsLoad: !keeps && wanted != nil && shows)
    }
}
