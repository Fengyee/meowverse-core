import ActivityKit
import MeowverseCore
import SwiftUI
import UIKit

/// The Home Screen quick actions (long press on the app icon).
///
/// All four are dynamic: they are registered once the library is open and first-launch setup
/// is done, so a fresh install shows none. A tap only records what was asked for; the room
/// carries it out after the library has loaded (see `RoomScreen.handleQuickAction`).
@MainActor
@Observable
final class QuickActionCenter {
    static let shared = QuickActionCenter()

    struct Request: Equatable {
        let id = UUID()
        let kind: QuickActionKind
    }

    /// The action waiting for the room. A newer tap replaces an older one.
    var pending: Request?
    /// Changed to put the companion screen over whatever is showing, as the island's link does.
    var companionRequest: UUID?
    /// Open pages holding something the user wrote and has not sent (see `View.unsentWork`).
    private var unsentPages: Set<UUID> = []

    /// A quick action to add photos must not close a page that would lose this.
    var hasUnsentWork: Bool { !unsentPages.isEmpty }

    func setUnsentWork(_ active: Bool, page: UUID) {
        if active { unsentPages.insert(page) } else { unsentPages.remove(page) }
    }

    private init() {
        #if DEBUG || DRILLS
        let options = LaunchOptions.current
        if let raw = options.quickAction, let kind = QuickActionKind(rawValue: raw) {
            if options.quickActionDelay > 0 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(options.quickActionDelay))
                    self?.pending = Request(kind: kind)
                }
            } else {
                pending = Request(kind: kind)
            }
        }
        #endif
    }

    @discardableResult
    func receive(_ item: UIApplicationShortcutItem) -> Bool {
        guard let kind = QuickActionKind(rawValue: item.type) else { return false }
        pending = Request(kind: kind)
        return true
    }
}

/// SwiftUI apps hear about quick actions only through a scene delegate.
final class QuickActionAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }
}

final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Launched from a quick action.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem { QuickActionCenter.shared.receive(item) }
    }

    /// Brought back from the background by a quick action.
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        QuickActionCenter.shared.receive(shortcutItem)
    }
}

extension View {
    /// Marks this page as holding unsent work while `active` and the page is showing: a
    /// half-written mail, or one open in the composer. Quick actions then leave it open.
    func unsentWork(_ active: Bool) -> some View {
        modifier(UnsentWork(active: active))
    }

    /// Keeps the Home Screen items in step with the library: on every change of scene phase
    /// (so leaving the app shows the current state) and whenever the furniture changes.
    /// Registered from the first launch on: they used to wait for the first-launch reminder page,
    /// which is gone (Q-05, docs/ONBOARDING_TOUR.md §9).
    func quickActionItems(model: AppModel) -> some View {
        modifier(QuickActionItems(model: model))
    }
}

private struct UnsentWork: ViewModifier {
    let active: Bool
    @State private var page = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) { QuickActionCenter.shared.setUnsentWork(active, page: page) }
            .onAppear { QuickActionCenter.shared.setUnsentWork(active, page: page) }
            .onDisappear { QuickActionCenter.shared.setUnsentWork(false, page: page) }
    }
}

private struct QuickActionItems: ViewModifier {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase, initial: true) { update() }
            .onChange(of: model.phase) { update() }
            .onChange(of: model.state.revision) { update() }
            .onChange(of: model.libraryGeneration) { update() }
            .onChange(of: model.leadCatName) { update() }
    }

    private func update() {
        guard model.phase == .ready else { return }
        // The Control Center button starts company without the model; it reads this name.
        PocketCatAttributes.remember(model.leadCatName)
        let hasMemory = !QuickActionPlan.memoryCandidates(in: model.state).isEmpty
        let keepingCompany = PocketCatActivity.activities.contains(where: \.isOngoing)
        UIApplication.shared.shortcutItems = QuickActionPlan.kinds(hasCamera: InAppCamera.isAvailable, hasMemory: hasMemory)
            .map { item($0, keepingCompany: keepingCompany) }
    }

    /// Titles only. A piece's or a cat's name never shows on the Home Screen, which others can see.
    private func item(_ kind: QuickActionKind, keepingCompany: Bool) -> UIApplicationShortcutItem {
        let subtitle = kind == .companion && keepingCompany ? String(localized: "Keeping you company", table: "PocketCat") : nil
        return UIApplicationShortcutItem(type: kind.rawValue, localizedTitle: kind.title, localizedSubtitle: subtitle,
                                         icon: kind.icon, userInfo: nil)
    }
}

extension QuickActionKind {
    /// The item's title on the Home Screen. Also drawn by the tour's chapter 12 (12.7).
    var title: String {
        switch self {
        case .camera: String(localized: "拍照添加")
        case .library: String(localized: "从相册添加")
        // Its own key: the Home Screen items are title case in English ("Keep Me Company"),
        // while the companion screen keeps PocketCat's sentence-case title.
        case .companion: String(localized: "陪我一会儿")
        case .memory: String(localized: "看看回忆")
        }
    }

    /// Our own symbol, where the item has one in place of the system's: company carries the cat's
    /// paw of its Control Center control, a template symbol from `ControlSymbols.xcassets`, which
    /// the app builds in too. `icon` and `image` both follow this.
    private var asset: String? {
        switch self {
        case .companion: PocketCatControlFace.company.symbol
        case .camera, .library, .memory: nil
        }
    }

    /// The item's icon on the Home Screen.
    var icon: UIApplicationShortcutIcon {
        if let asset { UIApplicationShortcutIcon(templateImageName: asset) } else { UIApplicationShortcutIcon(systemImageName: symbol) }
    }

    /// The same icon in SwiftUI, for pictures of the Home Screen menu.
    var image: Image {
        if let asset { Image(asset) } else { Image(systemName: symbol) }
    }

    /// The nearest SF Symbol. To show the item, use `icon` or `image`: company's differs.
    var symbol: String {
        switch self {
        case .camera: "camera"
        case .library: "photo.on.rectangle"
        case .companion: "pawprint"
        case .memory: "photo.stack"
        }
    }
}

/// One line over everything on screen, including sheets, for a few seconds. Touches pass
/// through; VoiceOver reads it out.
enum TransientNotice {
    private static var window: UIWindow?
    private static var hideTask: Task<Void, Never>?

    static func show(_ text: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let window = Self.window ?? PassThroughWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: NoticeLine(text: text))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        Self.window = window
        UIAccessibility.post(notification: .announcement, argument: text)
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            Self.window?.isHidden = true
            Self.window = nil
        }
    }

    /// Takes the line away now, for a page that comes in its place.
    static func hide() {
        hideTask?.cancel()
        hideTask = nil
        window?.isHidden = true
        window = nil
    }

    private final class PassThroughWindow: UIWindow {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }

    private struct NoticeLine: View {
        let text: String

        var body: some View {
            VStack {
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .memoryCard(.home)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .accessibilityIdentifier("quick-action-notice")
                Spacer()
            }
        }
    }
}
