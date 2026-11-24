@preconcurrency import ActivityKit
import MeowverseCore
import SwiftUI
import UIKit

// Chapter 12's three pages after the steps (PRODUCT_PLAN §3.3 12.5 to 12.7, VISUAL §17): what
// each page is about, and the facts of this device its picture and words depend on. The picture
// itself is `TourCompanyDiagram` (TourCompanyDiagram.swift, drawn by the interface artist).

/// One of the three pages, in the order they are read.
enum TourCompanyPage: Int, CaseIterable, Identifiable, Sendable {
    /// 12.5: Pixel Cat on the Home Screen and the Lock Screen.
    case homeScreen
    /// 12.6: the three controls in Control Center.
    case controlCenter
    /// 12.7: the shortcuts under the app icon.
    case iconShortcuts

    var id: Int { rawValue }
}

/// What the pages may show on this device (PRODUCT_PLAN §3.3, under 12.7: no camera, no
/// 「拍照添加」; no piece with a photo, no 「看看回忆」).
struct TourCompanyConditions: Equatable, Sendable {
    /// `InAppCamera.isAvailable`.
    var hasCamera: Bool
    /// A piece holds a photo the 「看看回忆」 shortcut can open (`QuickActionPlan.memoryCandidates`).
    var hasPhotoFurniture: Bool
    /// An iPhone with the Action button: 12.6 says it can start company too. Only in the words;
    /// the picture does not draw it (VISUAL §17.3).
    var hasActionButton = false
    /// An iPhone with a Home button (iPhone SE): Control Center opens with a swipe up from the
    /// bottom edge, not down from the top-right corner. `TourDevice.hasHomeButton`, the same
    /// devices 12.6's words call 「配备主屏幕按钮的 iPhone」 (`tour.company.controls.how`).
    var hasHomeButton = false

    /// The shortcuts under the app icon, as the Home Screen lists them, the first closest to the
    /// icon. Their titles and symbols: `QuickActionKind.title`, `.image` (QuickActions.swift).
    var shortcuts: [QuickActionKind] { QuickActionPlan.kinds(hasCamera: hasCamera, hasMemory: hasPhotoFurniture) }

    /// The three Control Center controls, in the order they are drawn (`PocketCatControlFace`).
    var controls: [PocketCatControlFace] { PocketCatControlFace.allCases }

    /// The icon on this device's Home Screen now, 40 pt (`AppIconPreview`).
    var appIcon: Image { AppIconPreview.current }
}

extension TourCompanyConditions {
    /// This device and this home.
    @MainActor
    static func current(_ model: AppModel) -> TourCompanyConditions {
        TourCompanyConditions(hasCamera: InAppCamera.isAvailable,
                              hasPhotoFurniture: !QuickActionPlan.memoryCandidates(in: model.state).isEmpty,
                              hasActionButton: TourDevice.hasActionButton,
                              hasHomeButton: TourDevice.hasHomeButton())
    }
}

/// What the tour needs to know about the hardware.
enum TourDevice {
    /// Live Activities are allowed for the app (12.3 can start one). DEBUG:
    /// `-MeowverseLiveActivitiesOff` reads them as switched off, here and on the company page, so
    /// a UI test sees 12.3 关着 without changing the simulator's settings.
    static var liveActivitiesOn: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-MeowverseLiveActivitiesOff") { return false }
        #endif
        return ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// The machine identifier, `iPhone17,1` and so on; the simulated one in the simulator.
    static var model: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// iPhone 15 Pro (iPhone16,1 and 16,2) and every iPhone from the 16 on (iPhone17,x and later).
    static var hasActionButton: Bool {
        let name = model
        guard name.hasPrefix("iPhone"), let major = Int(name.dropFirst(6).prefix { $0 != "," }) else { return false }
        return major >= 17 || name == "iPhone16,1" || name == "iPhone16,2"
    }

    /// An iPhone with a Home button: Touch ID under the screen, no Face ID. There is no API for
    /// it: such an iPhone has no safe area at the bottom of the screen (a Face ID iPhone has 34
    /// pt there for the Home indicator). iPad: false, since 12.6 is not told there (T4.8).
    @MainActor
    static func hasHomeButton(in window: UIWindow? = nil) -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = window ?? scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first else {
            return false
        }
        return window.safeAreaInsets.bottom == 0
    }

    /// An iPhone with the Dynamic Island. There is no API for it: in portrait its top safe area is
    /// 59 pt or more (the notch iPhones have 47 to 50, an iPad 24 or less).
    @MainActor
    static func hasIsland(in window: UIWindow?) -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone, let window else { return false }
        return window.safeAreaInsets.top >= 55
    }
}

/// The company page (`PocketCatView`) is on screen. A plain counter: that page is also shown in a
/// hosting controller outside the SwiftUI environment of the app (`PocketCatReturn`).
@MainActor
enum TourCompanyPageSeen {
    private(set) static var count = 0
    static var shown: Bool { count > 0 }
    static func appeared() { count += 1 }
    static func disappeared() { count = max(0, count - 1) }
}
