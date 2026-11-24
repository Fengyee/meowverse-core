import SwiftUI
import UIKit

// Where the tour's controls are on screen (docs/onboarding/TECH_DESIGN.md §3.2). Each control the
// tour can point at carries an invisible UIKit probe; the overlay window measures the probes every
// frame, in whatever layer the control lives (the room page, a sheet, a popover, a sidebar).

/// What the window covers when the control sits in a `List` (VISUAL §18.2 item 1): the control
/// itself, the row's card, or every row of its group (11.1). A row's window is its cell's card, 3 pt
/// out, with the card's corner plus those 3.
enum TourCover: Equatable {
    case control
    case row
    case group
}

extension View {
    /// Marks a control the tour can point at. `form` is the control's own outline, for the
    /// window the mask opens over it; `padding` is 6, or 3 when another control is within 12 pt.
    /// In a `List`, `cover` widens the window to the row's card or its whole group.
    /// Without the tour (a UI-test library that did not ask for it) the view is left as it is.
    @ViewBuilder
    func tourAnchor(_ id: String, form: TourNoteCutout.Form = .labelled,
                    padding: CGFloat = TourNoteMetrics.cutoutPadding, cover: TourCover = .control) -> some View {
        if TourLaunch.isEnabled {
            background(TourProbe(id: id, form: form, padding: padding, cover: cover))
        } else {
            self
        }
    }
}

private struct TourProbe: UIViewRepresentable {
    let id: String
    let form: TourNoteCutout.Form
    let padding: CGFloat
    let cover: TourCover

    func makeUIView(context: Context) -> TourProbeView { TourProbeView() }

    func updateUIView(_ view: TourProbeView, context: Context) {
        view.form = form
        view.padding = padding
        view.cover = cover
        view.anchorID = id
    }
}

/// Invisible, takes no touches, hidden from accessibility. It only exists to be measured.
final class TourProbeView: UIView {
    var form: TourNoteCutout.Form = .labelled
    var padding: CGFloat = TourNoteMetrics.cutoutPadding
    var cover = TourCover.control
    var anchorID = "" {
        didSet {
            guard oldValue != anchorID else { return }
            TourAnchorRegistry.shared.remove(self, id: oldValue)
            if window != nil { TourAnchorRegistry.shared.add(self, id: anchorID) }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            TourAnchorRegistry.shared.remove(self, id: anchorID)
        } else {
            TourAnchorRegistry.shared.add(self, id: anchorID)
        }
    }
}

/// A plain reference type, not observable: positions change every frame and must not make
/// SwiftUI recompute anything.
final class TourAnchorRegistry {
    static let shared = TourAnchorRegistry()
    private struct Entry { weak var view: TourProbeView? }
    private var probes: [String: [Entry]] = [:]

    func add(_ view: TourProbeView, id: String) {
        guard !id.isEmpty else { return }
        var list = (probes[id] ?? []).filter { $0.view != nil && $0.view !== view }
        list.append(Entry(view: view))
        probes[id] = list
    }

    func remove(_ view: TourProbeView, id: String) {
        guard let list = probes[id] else { return }
        probes[id] = list.filter { $0.view != nil && $0.view !== view }
    }

    /// The same id may sit on several layout branches that exclude one another (`ViewThatFits`,
    /// one row or two): only a probe that is in `window` with a real size counts.
    /// A probe SwiftUI keeps after its view has gone (a hidden branch, a cell kept for reuse) is
    /// not one: it is in a hidden or transparent layer, so it is left out (QA_T5 must-fix 2).
    func probe(_ id: String, in window: UIWindow) -> TourProbeView? {
        probes[id]?.compactMap(\.view).last { $0.window === window && !$0.bounds.isEmpty && Self.isDrawn($0) }
    }

    private static func isDrawn(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let layer = current {
            if layer.isHidden || layer.alpha < 0.01 { return false }
            current = layer.superview
        }
        return true
    }
}

/// Where a view is on screen right now, in its window's coordinates. Reads the presentation
/// layers, so it follows a sheet that is still sliding; the model layer already holds the final
/// position on the first frame of an animation (PROTOTYPE_T1 §3, correction 1).
enum TourGeometry {
    /// The padding of a row's window: rows touch, so 3 pt, not 6 (VISUAL §18.2 item 1).
    static let rowPadding: CGFloat = 3

    /// For a probe in a `List` row with a wider `cover`: the view to measure, the rect in it, and
    /// the card's corner. nil outside a list (the control's own window is used).
    static func cell(of probe: TourProbeView) -> (view: UIView, local: CGRect, corner: CGFloat)? {
        guard probe.cover != .control else { return nil }
        var view = probe.superview
        while let current = view, !(current is UICollectionViewCell) { view = current.superview }
        guard let cell = view as? UICollectionViewCell else { return nil }
        let corner = cardCorner(of: cell)
        guard probe.cover == .group else { return (cell, cell.bounds, corner) }
        var list = cell.superview
        while let current = list, !(current is UICollectionView) { list = current.superview }
        guard let list = list as? UICollectionView, let path = list.indexPath(for: cell) else { return (cell, cell.bounds, corner) }
        let rows = (0..<list.numberOfItems(inSection: path.section)).compactMap {
            list.layoutAttributesForItem(at: IndexPath(item: $0, section: path.section))?.frame
        }
        let group = rows.reduce(CGRect.null) { $0.union($1) }
        // The group's corner is on its first row.
        let first = list.cellForItem(at: IndexPath(item: 0, section: path.section)).map(cardCorner) ?? corner
        return group.isNull ? (cell, cell.bounds, corner) : (list, group, first)
    }

    /// The corner of a list row's card: the largest one drawn in the cell, at most two levels in
    /// (a row in the middle of a group has square corners; the group's corner is on its ends).
    private static func cardCorner(of cell: UIView) -> CGFloat {
        var corner = cell.layer.cornerRadius
        for child in cell.subviews {
            corner = max(corner, child.layer.cornerRadius)
            for grandchild in child.subviews { corner = max(corner, grandchild.layer.cornerRadius) }
        }
        return corner > 0 ? corner : 10
    }

    static func rect(of view: UIView, local: CGRect? = nil) -> (shown: CGRect, model: CGRect)? {
        guard let window = view.window else { return nil }
        let bounds = local ?? view.bounds
        let model = view.convert(bounds, to: window)
        guard let layer = view.layer.presentation(), let top = window.layer.presentation() else { return (model, model) }
        return (layer.convert(bounds, to: top), model)
    }
}

extension View {
    /// Scrolls `proxy`'s list to the control the tour is about to point at, when it is one of
    /// `ids` (11.2, 13.1, 14.2: Q-05, LINES.md T5.14). The control carries `.id(itsAnchorID)`. The
    /// step waits until the scroll has finished (`TourCoordinator.waitsForScroll`), so its window
    /// and bubble are placed on the row where it stays.
    @ViewBuilder
    func tourScrolls(_ proxy: ScrollViewProxy, to ids: Set<String>) -> some View {
        if TourLaunch.isEnabled {
            modifier(TourScrolls(proxy: proxy, ids: ids))
        } else {
            self
        }
    }
}

private struct TourScrolls: ViewModifier {
    @Environment(TourCoordinator.self) private var tour: TourCoordinator?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let proxy: ScrollViewProxy
    let ids: Set<String>

    @State private var appeared = ContinuousClock.now

    func body(content: Content) -> some View {
        content
            .onAppear { appeared = .now }
            .task(id: tour?.scrollTarget) {
                guard let target = tour?.scrollTarget, ids.contains(target) else { return }
                // A sheet that is still coming up has not laid its list out yet (14.1 opens
                // Settings). A list already up waits only for the last step's window to shut
                // (`TourNoteMotion.windowClose`, 0.15 s), so no fading window frames the rows
                // sliding under it (VISUAL §18.2 item 5). Under Reduce Motion the window and the
                // bubble fade together and the list jumps once both have gone (§19.4).
                let settled = max(appeared + .milliseconds(350), .now + .milliseconds(reduceMotion ? 140 : 180))
                if settled > .now {
                    do { try await Task.sleep(until: settled) } catch { return }
                }
                // A List scrolls in UIKit: the SwiftUI animation's completion comes at once, before
                // the rows have moved (11.2's bubble was placed on the row's old place). So wait
                // out the scroll itself.
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .center) }
                // A jump is laid out by the next frame, and no more than 0.1 s may be empty (§19.4).
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 17 : 400)) } catch { return }
                tour?.scrolled(to: target)
            }
    }
}
