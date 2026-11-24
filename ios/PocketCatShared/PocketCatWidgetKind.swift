import WidgetKit

/// The Home Screen and Lock Screen widgets' kinds (round 11). Whatever starts, changes or ends
/// company asks them to read the Live Activity again, so a widget never offers "Keep me company"
/// while a companion runs, or shows an expression the Lock Screen doesn't. Reloads asked for by
/// the app in front, or by a widget's own button, don't count against WidgetKit's budget.
/// The Control Center toggle is asked too, so it shows on or off as company starts and ends.
nonisolated enum PocketCatWidgetKind {
    static let home = "app.meowverse.widget.home"
    static let lock = "app.meowverse.widget.lock"

    static func reload() {
        WidgetCenter.shared.reloadTimelines(ofKind: home)
        WidgetCenter.shared.reloadTimelines(ofKind: lock)
        ControlCenter.shared.reloadControls(ofKind: PocketCatCompanyToggle.kind)
    }
}
