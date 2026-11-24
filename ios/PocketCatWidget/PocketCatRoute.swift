/// The extension's copy of the app's `PocketCatRoute` (`Meowverse/Companion/PocketCatRoute.swift`).
/// The intents that call it open the app and run there, so this is never reached.
@MainActor
enum PocketCatRoute {
    static func open(_ destination: PocketCatDestination) {}
}
