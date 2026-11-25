import SwiftUI

/// A tap on the island (or the Home Screen quick action) may arrive while a photo picker or another SwiftUI sheet is presented.
/// Present from this scene's visible controller so dismissing returns to the same work.
struct PocketCatReturn: ViewModifier {
    /// The lead cat's name. The page below is hosted outside the app's environment, so it
    /// cannot read `AppModel` itself.
    let catName: String
    @Environment(\.scenePhase) private var phase
    @State private var request: UUID?

    func body(content: Content) -> some View {
        content
            // The widgets read company from the App Group: catch up on a companion that ended
            // (or began) while the app was away.
            .onChange(of: phase, initial: true) { _, phase in
                if phase == .active { PocketCatCompanyMirror.reconcile() }
            }
            .onOpenURL { url in
                guard let host = Bundle.main.bundleIdentifier, url == PocketCatLink.url(for: host) else { return }
                TourOutside.arrived()
                request = UUID()
            }
            // The Home Screen's "陪我一会儿" arrives here once the room is showing.
            .onChange(of: QuickActionCenter.shared.companionRequest) { _, asked in
                if asked != nil { request = UUID() }
            }
            .background { PocketCatPresenter(request: $request, catName: catName) }
    }
}

private struct PocketCatPresenter: UIViewControllerRepresentable {
    @Binding var request: UUID?
    let catName: String

    final class Controller: UIViewController {
        weak var companion: UIViewController?
        var pendingRequest: UUID?
        var catName = ""
        var didPresent: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            presentCompanionIfRequested()
        }

        func presentCompanionIfRequested() {
            guard pendingRequest != nil, let root = view.window?.rootViewController else { return }
            var top = root
            while let presented = top.presentedViewController { top = presented }
            // A transition first: the companion page on its way out still counts as presented
            // until it has gone, and would swallow this request (X24-05).
            if let transition = top.transitionCoordinator,
               transition.animate(alongsideTransition: nil, completion: { [weak self] _ in
                   self?.presentCompanionIfRequested()
               }) { return }
            if let companion, companion.presentingViewController != nil, !companion.isBeingDismissed {
                return consumeRequest()
            }

            // The page reads the name when company starts, not when it opened: the library may
            // have been cleared or restored under it (X24-04).
            let openedWith = catName
            let screen = UIHostingController(rootView: NavigationStack {
                PocketCatView(catName: openedWith, currentName: { [weak self] in self?.catName ?? openedWith })
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { [weak self] in self?.companion?.dismiss(animated: true) } label: {
                                Text("Done", tableName: "PocketCat")
                            }
                            .accessibilityIdentifier("pocket-close-return")
                        }
                    }
            })
            companion = screen
            // Used up once the page is really up: a refused presentation leaves the request
            // for the next update or appearance (X24-05).
            top.present(screen, animated: true) { [weak self, weak screen] in
                guard let self, let screen, self.companion === screen, screen.presentingViewController != nil else { return }
                self.consumeRequest()
            }
        }

        private func consumeRequest() {
            pendingRequest = nil
            didPresent?()
        }
    }

    func makeUIViewController(context: Context) -> Controller {
        let presenter = Controller()
        presenter.view.isUserInteractionEnabled = false
        return presenter
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.pendingRequest = request
        controller.catName = catName
        controller.didPresent = { request = nil }
        if request != nil { Task { @MainActor in controller.presentCompanionIfRequested() } }
    }
}
