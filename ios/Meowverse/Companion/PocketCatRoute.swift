import MeowverseCore

/// Where the Control Center buttons that open the app go: the Home Screen quick action's queue,
/// which the room carries out once the library has loaded and the app is in front. The
/// extension has its own empty `PocketCatRoute` (`PocketCatWidget/PocketCatRoute.swift`).
@MainActor
enum PocketCatRoute {
    static func open(_ destination: PocketCatDestination) {
        let kind: QuickActionKind = switch destination {
        case .camera: .camera
        case .library: .library
        }
        QuickActionCenter.shared.pending = .init(kind: kind)
    }
}
