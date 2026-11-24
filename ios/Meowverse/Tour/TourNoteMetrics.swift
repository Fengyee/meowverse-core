import SwiftUI
import UIKit

// The numbers, fixed colours and timings of the tour's look, from docs/onboarding/VISUAL.md §2 (as
// revised by its §8) and docs/ONBOARDING_TOUR.md §0 and §3. Nothing here reads the app model or
// the tour's state: `TourNoteBubble`, `TourNoteMask` and `TourChapterCard` are plain views the tour's host
// places and drives.

/// Sizes in points. `nonisolated` so the shapes can read them.
nonisolated enum TourNoteMetrics {
    // The bubble (VISUAL §2.3).
    static let bubblePadding: CGFloat = 16
    static let bubbleShadow: (opacity: Double, radius: CGFloat, y: CGFloat) = (0.22, 8, 4)
    /// Leave this much on each side of the bubble on iPhone: the bubble is the screen width less 32.
    static let bubbleMargin: CGFloat = 16
    /// The least margin when the bubble moves towards a control near the screen's edge (VISUAL §9.1).
    static let bubbleLeastMargin: CGFloat = 8
    /// At most 340 wide on iPhone; 360 on iPad, the width of a panel popover.
    static func bubbleMaxWidth(regular: Bool) -> CGFloat { regular ? 360 : 340 }

    // The tail: a 16 × 9 triangle with a 2 pt rounded tip, part of the bubble's outline.
    static let tailWidth: CGFloat = 16
    static let tailHeight: CGFloat = 9
    static let tailTipRadius: CGFloat = 2
    /// The tip stays at least this far from the end of the bubble's edge, clear of the corner.
    static let tailCornerClearance: CGFloat = 28
    /// Between the tip and the cutout's line.
    static let tailGap: CGFloat = 6

    // The portrait and the progress dots (VISUAL §8.3, §2.5).
    static let portraitSize: CGFloat = 44
    /// Bella's ears stand this far above the portrait's circle.
    static let portraitEarRoom: CGFloat = 6
    /// Above the circle's middle the picture is this much wider than the circle on each side, so a
    /// tilted or spread ear (H3, H6) keeps its tip. The `bella-head-*` pictures are 50 × 50 pt.
    static let portraitSideRoom: CGFloat = 3
    static let dotSize: CGFloat = 6
    static let dotSpacing: CGFloat = 6
    static let currentDotWidth: CGFloat = 14
    static let dotRing: CGFloat = 1.5
    /// More steps than this show as digits (2/7).
    static let mostDots = 5

    // 【下一步】 and 【跳过这一段】 (VISUAL §2.4).
    static let nextCorner: CGFloat = 15
    static let nextMinWidth: CGFloat = 96
    static let hitSize: CGFloat = 44

    // The cutout (VISUAL §2.2).
    static let cutoutPadding: CGFloat = 6
    /// When another control is within 12 pt of the target.
    static let cutoutTightPadding: CGFloat = 3
    static let cutoutMinSize: CGFloat = 44
    /// A control of an icon over a label has no plate of its own.
    static let cutoutLabelledCorner: CGFloat = 12
    static let cutoutLine: CGFloat = 1.5
    static let cutoutLineIncreasedContrast: CGFloat = 2.5
    static let cutoutShadow: (opacity: Double, radius: CGFloat, y: CGFloat) = (0.30, 3, 1.5)

    // The chapter card's illustration: a 3:2 landscape slot.
    static let illustrationSize = CGSize(width: 180, height: 120)

    // At accessibility text sizes (VISUAL §9.1).
    /// A bubble or a card grows to this share of the screen's height before its words scroll: pass
    /// `screenHeight * tallestShare` as their `maxHeight`.
    static let tallestShare: CGFloat = 0.7
    /// When the words scroll, the edge where they are cut fades over half a line (VISUAL §10.1); this
    /// is the fade only while the line is not yet measured, or for `TourNoteWords` given no sample.
    static let scrollFade: CGFloat = 16

    /// Where a bubble of `length` starts along the screen so its tail can point at `window`
    /// (VISUAL §2.3, §9.1). Centred on the window, 16 pt from the screen's edges. The tail's tip is
    /// held 28 pt from the bubble's corners, so near an edge it may miss the window's centre: that is
    /// fine while it stays within the middle half of the window. Past that the bubble moves towards
    /// the control, as far as it must and never closer than 8 pt to the screen's edge.
    ///
    /// For a tail on the top or bottom edge use `bubbleX`. For one on the left or right edge pass
    /// heights: the bubble's, the screen's and the window's vertical span.
    static func bubbleStart(length: CGFloat, screen: CGFloat, window: ClosedRange<CGFloat>) -> CGFloat {
        let centre = (window.lowerBound + window.upperBound) / 2
        let slack = (window.upperBound - window.lowerBound) / 4
        let clear = tailCornerClearance
        func kept(_ start: CGFloat, margin: CGFloat) -> CGFloat {
            screen - 2 * margin < length ? (screen - length) / 2 : min(max(start, margin), screen - margin - length)
        }
        var start = kept(centre - length / 2, margin: bubbleMargin)
        if start + clear > centre + slack {
            start = centre + slack - clear
        } else if start + length - clear < centre - slack {
            start = centre - slack - length + clear
        }
        return kept(start, margin: bubbleLeastMargin)
    }

    /// `bubbleStart` across the screen. Give the tail `offset: window.midX - x`.
    static func bubbleX(width: CGFloat, screenWidth: CGFloat, window: CGRect) -> CGFloat {
        bubbleStart(length: width, screen: screenWidth, window: window.minX...window.maxX)
    }
}

/// The tour's fixed colours, by what they are for. None follows the system colour scheme. The values
/// are design-system tokens (`art/ui/tokens.json`, VISUAL §9.2).
enum TourNoteInk {
    /// The mask over a bright page, #29231F: `RoomPaper.shadeOnBright`.
    static let maskOnBright = RoomPaper.shadeOnBright
    /// The mask over a dim page, #120E0B: `RoomPaper.shadeOnDim`.
    static let maskOnDim = RoomPaper.shadeOnDim
    /// The cutout's line and the glow inside a cutout on a dim page: `paper`'s light value, #FFF4DE.
    /// It is "the paper the cut shows", so it follows `paper` and has no name of its own.
    static let cutoutLine = fixed(RoomPaper.paper, .light)
    /// The round base behind Bella's portrait, the sage of the app icon, #AFBF98: `RoomPaper.sage`.
    static let portraitBase = RoomPaper.sage

    private static func fixed(_ token: Color, _ style: UIUserInterfaceStyle) -> Color {
        Color(uiColor: UIColor(token).resolvedColor(with: UITraitCollection(userInterfaceStyle: style)))
    }
}

/// Timings (VISUAL §2.6). Under Reduce Motion every entrance, exit and change is `reduced`: a
/// 0.2 s fade with no movement, scaling or line change.
enum TourNoteMotion {
    /// The cutout opening, and the cutout and bubble moving to the next control.
    static let moveSpring = Spring(duration: 0.35, bounce: 0.1)
    static let move = Animation.spring(moveSpring)
    /// From one step to the next: the same spring, started once the old words have faded out.
    static let stepMove = move.delay(wordsOut)
    /// How long `move` takes to come to rest: its `duration` is perceptual and the spring is still
    /// moving after it.
    static let moveSettle = 0.6
    /// How long a step's window waits on the old control while the new one cannot be measured.
    static let measureWait = 0.6
    static let maskIn = Animation.easeOut(duration: 0.25)
    /// The mask fades while the cutout opens outwards.
    static let maskOut = Animation.easeIn(duration: 0.3)
    /// The host removes the mask this long after `isShown` turns false.
    static let maskOutDuration = 0.3
    /// The bubble arrives 0.1 s after the mask, moving 8 pt away from the control.
    static let bubbleIn = Animation.easeOut(duration: 0.3).delay(0.1)
    static let bubbleTravel: CGFloat = 8
    static let bubbleOut = Animation.easeOut(duration: fadesOut)
    /// `bubbleOut`'s length: what goes is gone before what comes (VISUAL §19.4).
    static let fadesOut = 0.15
    /// The same length under Reduce Motion, evenly: eased out it was gone by 0.1 s, and the screen
    /// read as empty until the next step (VISUAL §19.4: no more than 0.1 s).
    static let reducedOut = Animation.linear(duration: fadesOut)
    /// A window closing because its control opened a panel or a page over it (VISUAL §13.3 b): it
    /// shrinks to 0.92 and fills in with the mask while the mask fades.
    static let windowClose = Animation.easeIn(duration: 0.15)
    /// Between steps the words fade out, the bubble moves, and the new words fade in.
    static let wordsOut = 0.12
    static let wordsIn = 0.18
    /// The new words start to come in this long after the move began: the spring is four fifths of
    /// the way there, so the window has as good as arrived. With the old words' fade this keeps the
    /// bubble without words for about 0.2 s, under the 0.3 s VISUAL §13.4 item 6 allows (the whole
    /// 0.35 s move left it empty for 0.57 s, §17.11.2).
    static let wordsInAfterMove = 0.15
    /// The line thickens to twice its width and settles, once, as the cutout opens.
    static let linePulse = (rise: 0.3, settle: 0.5)
    static let reduced = Animation.easeInOut(duration: 0.2)
}

extension AnyTransition {
    /// How a bubble or a chapter card arrives and leaves. `tail` is the edge its tail is on, so the
    /// bubble starts 8 pt nearer the control it points at; a card passes nil and only fades.
    /// Put the change in `withAnimation`. Buttons take taps from the first frame.
    static func tourNote(tail: Edge?, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity.animation(TourNoteMotion.reduced) }
        let travel = TourNoteMotion.bubbleTravel
        let start: CGSize = switch tail {
        case .top: CGSize(width: 0, height: -travel)
        case .bottom: CGSize(width: 0, height: travel)
        case .leading: CGSize(width: -travel, height: 0)
        case .trailing: CGSize(width: travel, height: 0)
        case nil: .zero
        }
        return .asymmetric(insertion: .offset(start).combined(with: .opacity).animation(TourNoteMotion.bubbleIn),
                           removal: .opacity.animation(TourNoteMotion.bubbleOut))
    }
}
