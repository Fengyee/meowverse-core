import SwiftUI

// Bella's pictures for the tour (VISUAL §8.4), cut out of the owner-approved originals in
// art/bella-guide/approved/ by art/ui/source/bella-cutouts.py into Assets.xcassets/Bella/. The
// pictures are decorative: the views that show them hide them from VoiceOver and say "Bella" in words.

/// Bella's head for the portrait in a bubble, chosen by what the step is, not by chapter. The
/// pictures are framed for `TourNotePortrait`: all six share one position and scale, so a new
/// expression replaces the old one in place.
enum BellaHead: String, CaseIterable, Sendable {
    /// H1, looking at you, mouth a little open: explaining. The default.
    case `default`
    /// H2, looking down: pointing out the control in the cutout. Only when the bubble is above the
    /// control; below it she would be looking away from it, so use `default` or `curious` there.
    case lookDown = "look-down"
    /// H3, head tilted: the user's turn, she is waiting.
    case waiting
    /// H4, eyes smiling: a step done, a chapter finished.
    case happy
    /// H5, eyes wide: something new.
    case curious
    /// H6, ears out, mouth closed, calm: something is not ready yet. Not an error and not an apology.
    case notYet = "not-yet"

    var image: Image { Image("bella-head-\(rawValue)") }
}

/// Bella's whole-body pictures for the chapter card's 180 × 120 slot, the whole 3:2 picture on
/// transparency. All eight keep one scale.
enum BellaBody: String, CaseIterable, Sendable {
    /// B1, sitting and waving a paw: the opening, and the row along the top of the room.
    case greeting
    /// B2, holding up a blank name tag: naming the cat.
    case nameTag = "name-tag"
    /// B3, a paw on two small photos: photos.
    case photos
    /// B4, pushing a box with her head: furniture.
    case box
    /// B5, lying by an open album: memories, backup.
    case album
    /// B6, batting at a feather wand: play.
    case play
    /// B7, loafing beside a little bell: company, reminders.
    case company
    /// B8, stretching: the whole tour done.
    case stretch

    var image: Image { Image("bella-body-\(rawValue)") }
}
