import UIKit

/// The navigation bar buttons the tour points at (6.2 「再添一张照片」, 6.3 「更多」). SwiftUI puts a
/// toolbar item in a bar button of its own, where a `tourAnchor` probe may not be drawn, so such a
/// button is found by its accessibility identifier, only for these ids, and remembered.
@MainActor
enum TourBarItems {
    static let ids: Set<String> = ["add-source-photo", "furniture-more"]
    private static var found: [String: Weak] = [:]

    private final class Weak {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }

    static func view(_ id: String, in window: UIWindow) -> UIView? {
        guard ids.contains(id) else { return nil }
        if let view = found[id]?.view, view.window === window, !view.bounds.isEmpty, view.accessibilityIdentifier == id {
            return view
        }
        guard let view = search(id, in: window) else { return nil }
        found[id] = Weak(view)
        return view
    }

    private static func search(_ id: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == id, !view.bounds.isEmpty, !view.isHidden { return view }
        for child in view.subviews {
            if let hit = search(id, in: child) { return hit }
        }
        return nil
    }
}
