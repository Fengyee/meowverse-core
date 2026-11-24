import MeowverseCore
import SwiftUI
import UIKit

// The three diagrams of chapter 12's pages (docs/onboarding/VISUAL.md §17.1–17.4): a part of the
// screen drawn in SwiftUI, never a system screenshot and never the device's frame, with the tour's
// own mask and cream-lined window on the place to look. The pieces of the app in them are the real
// ones: the pixel cat, the one-colour cat, the Control Center symbols, the Home Screen items
// (`QuickActionPlan.kinds`) and their titles. Everything else is an empty cell.
//
// Coordinates are VISUAL §17.3's, in points from the plate's top-left corner. Colours named
// "fixed" there are the screen's (sage, mask, cream, the companion window's green) and do not follow
// the colour scheme; the plate, the edges, the widget and menu paper and the text do.

/// The diagram at the top of one of chapter 12's pages: 320 × 200 on every device, not scaled with
/// Dynamic Type, hidden from VoiceOver (the page's words say all it shows). At accessibility text
/// sizes it draws nothing: check `TourCompanyDiagram.isShown(at:)` to drop the space after it.
struct TourCompanyDiagram: View {
    static let size = CGSize(width: 320, height: 200)

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var contrast

    let page: TourCompanyPage
    let conditions: TourCompanyConditions
    /// 12.5 with the Home Screen alone, across the whole drawing (VISUAL §17.9.2 item 2). On iPad
    /// chapter 12 speaks only of the Home Screen widget and the icon until iPad has been seen on a
    /// device (LINES.md T4.8, plan A), so the picture shows no Lock Screen either.
    private let homeOnly: Bool
    /// 12.6's gesture: up from the bottom edge on an iPhone with a Home button, else down from the
    /// top-right corner (VISUAL §17.9.2 item 3). The picture reads this from the conditions and
    /// decides nothing itself.
    private let swipesUp: Bool

    init(page: TourCompanyPage, conditions: TourCompanyConditions) {
        self.init(page: page, conditions: conditions, homeOnly: UIDevice.current.userInterfaceIdiom == .pad,
                  swipesUp: conditions.hasHomeButton)
    }

    /// For the previews and the gallery, which show any device's layout on any device.
    init(page: TourCompanyPage, conditions: TourCompanyConditions, homeOnly: Bool, swipesUp: Bool) {
        self.page = page
        self.conditions = conditions
        self.homeOnly = homeOnly
        self.swipesUp = swipesUp
    }

    /// Hidden from AX1 up, like the chapter card's illustration (VISUAL §17.4, §9.1).
    static func isShown(at size: DynamicTypeSize) -> Bool { !size.isAccessibilitySize }

    var body: some View {
        if Self.isShown(at: typeSize) {
            ZStack(alignment: .topLeading) {
                Plate.shape.fill(RoomPaper.leaf)
                Plate.shape.strokeBorder(RoomPaper.edge, lineWidth: 1)
                drawing
            }
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .dynamicTypeSize(...DynamicTypeSize.large)
            .environment(\.diagramLine, contrast == .increased ? TourNoteMetrics.cutoutLineIncreasedContrast
                                                                 : TourNoteMetrics.cutoutLine)
            .environment(\.diagramMask, contrast == .increased ? 0.70 : 0.56)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var drawing: some View {
        switch page {
        case .homeScreen: HomeAndLock(homeOnly: homeOnly)
        case .controlCenter: ControlCenter(controls: conditions.controls, swipesUp: swipesUp)
        case .iconShortcuts: IconShortcuts(kinds: conditions.shortcuts, icon: conditions.appIcon)
        }
    }

    /// The captions under 12.5's two pieces. The page's two subheadings use these same strings, word
    /// for word (VISUAL §17.2).
    static let homeScreenCaption = LocalizedStringResource("tour.company.homeScreen", defaultValue: "主屏幕", table: "Tour")
    static let lockScreenCaption = LocalizedStringResource("tour.company.lockScreen", defaultValue: "锁屏", table: "Tour")
}

// MARK: - Shared pieces

private enum Plate {
    static let shape = RoundedRectangle(cornerRadius: RoomPaper.cardCorner, style: .continuous)
}

/// Fixed colours of the drawn screen.
private enum ScreenInk {
    /// The cutout's line, and the empty cells and clock bars at their own strengths: #FFF4DE.
    static let cream = TourNoteInk.cutoutLine
    /// The screen itself: the app icon's sage, #AFBF98.
    static let screen = RoomPaper.sage
    /// The companion page's window behind the colour pixel cat, #293B30 in both modes (art-craft:
    /// a pixel cat on light paper always sits in it). Same value as `PocketCatWidgetPalette.window`.
    static let companionWindow = Color(uiColor: UIColor(hex: 0x293B30))
    static let shade = RoomPaper.shadeOnBright
    /// Control Center's dark layer over the screen.
    static let controlCenterShade = 0.90
    /// Our three controls inside that fixed dark layer: `paper`'s and `moss`'s light values in both
    /// modes (VISUAL §17.9.2 item 1). Dark `paper` there was darker than the empty controls.
    static let controlFace = RoomPaper.drawnControlFace
    static let controlGlyph = RoomPaper.drawnControlGlyph
}

private struct DiagramLineKey: EnvironmentKey { static let defaultValue = TourNoteMetrics.cutoutLine }
private struct DiagramMaskKey: EnvironmentKey { static let defaultValue = 0.56 }

private extension EnvironmentValues {
    /// The window's cream line: 1.5 pt, 2.5 with Increase Contrast.
    var diagramLine: CGFloat {
        get { self[DiagramLineKey.self] }
        set { self[DiagramLineKey.self] = newValue }
    }

    /// The tour's mask over the bright screen: 56 %, 70 % with Increase Contrast.
    var diagramMask: Double {
        get { self[DiagramMaskKey.self] }
        set { self[DiagramMaskKey.self] = newValue }
    }
}

private extension View {
    /// Lays the view out at `rect` in its parent's top-left coordinates.
    func at(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
    }

    func at(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> some View {
        at(CGRect(x: x, y: y, width: width, height: height))
    }
}

private func continuous(_ corner: CGFloat) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: corner, style: .continuous)
}

/// A part of a screen at `frame` in the plate: a sage rounded rectangle with a 1 pt `edge` line,
/// which keeps it apart from the plate in dark mode. Its content is laid out in the part's own
/// coordinates and clipped to it.
private struct ScreenPart<Content: View>: View {
    static var corner: CGFloat { 14 }
    let frame: CGRect
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScreenInk.screen
            content()
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .clipShape(continuous(Self.corner))
        .overlay { continuous(Self.corner).strokeBorder(RoomPaper.edge, lineWidth: 1) }
        .offset(x: frame.minX, y: frame.minY)
    }
}

/// An app or a control that is not ours: a 28 pt cell, cream at 55 %.
private struct EmptyCell: View {
    var body: some View {
        continuous(6.5).fill(ScreenInk.cream.opacity(0.55)).frame(width: 28, height: 28)
    }
}

/// The tour's mask over a whole part of a screen, open at `window`, with the cream line on the
/// window's edge. No shadow falls into it: at this size it would only blur the edge.
private struct DiagramMask: View {
    @Environment(\.diagramMask) private var strength
    let window: CGRect?
    let corner: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Holed(hole: window, corner: corner)
                .fill(ScreenInk.shade.opacity(strength), style: FillStyle(eoFill: true))
            if let window {
                WindowLine(corner: corner).at(window)
            }
        }
    }

    private nonisolated struct Holed: Shape {
        let hole: CGRect?
        let corner: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path(rect)
            if let hole {
                path.addRoundedRect(in: hole, cornerSize: CGSize(width: corner, height: corner), style: .continuous)
            }
            return path
        }
    }
}

/// The cream line of a window, on its edge (half in, half out, as in the tour's own cutout).
private struct WindowLine: View {
    @Environment(\.diagramLine) private var width
    let corner: CGFloat

    var body: some View {
        continuous(corner).stroke(ScreenInk.cream, lineWidth: width)
    }
}

/// A line of text in the diagram: one line, shrinking to 0.8 before it is cut.
private extension Text {
    func diagramText(_ font: Font, _ colour: Color) -> some View {
        self.font(font).foregroundStyle(colour).lineLimit(1).minimumScaleFactor(0.8)
    }
}

// MARK: - 12.5 Home Screen and Lock Screen

private struct HomeAndLock: View {
    let homeOnly: Bool

    /// Side by side; on iPad the Home Screen alone, the whole width of the drawing, so it reads as
    /// an iPad's and not as a lone iPhone. The widget and its window stay where they are.
    private var home: CGRect { CGRect(x: 12, y: 12, width: homeOnly ? 296 : 172, height: 154) }
    /// Cells at x = 9 + 42i: four columns, or seven with 7 pt to spare on the right.
    private var columns: Int { homeOnly ? 7 : 4 }

    private let lock = CGRect(x: 196, y: 12, width: 112, height: 154)

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScreenPart(frame: home) {
                ForEach(0..<4, id: \.self) { row in
                    ForEach(0..<columns, id: \.self) { column in
                        // The top-left 2 × 2 is the widget.
                        if row > 1 || column > 1 {
                            EmptyCell().offset(x: 9 + 42 * CGFloat(column), y: 12 + 42 * CGFloat(row))
                        }
                    }
                }
                SmallWidget().at(9, 12, 70, 70)
                DiagramMask(window: CGRect(x: 6, y: 9, width: 76, height: 76), corner: 19)
            }
            caption(TourCompanyDiagram.homeScreenCaption, under: home)
            if !homeOnly {
                ScreenPart(frame: lock) {
                    // The clock as two bars: the date, then the time. No digits.
                    Capsule().fill(ScreenInk.cream.opacity(0.85)).at(36, 14, 40, 5)
                    Capsule().fill(ScreenInk.cream.opacity(0.85)).at(20, 24, 72, 22)
                    // The rectangular widget, with no plate of its own, as on a real Lock Screen.
                    Image("mono-figure-sleeping")
                        .resizable()
                        .renderingMode(.template)
                        .interpolation(.none)
                        .foregroundStyle(ScreenInk.cream)
                        .at(16, 64, 32, 32)
                    Capsule().fill(ScreenInk.cream.opacity(0.9)).at(54, 70, 38, 5)
                    Capsule().fill(ScreenInk.cream.opacity(0.9)).at(54, 81, 26, 5)
                    // The flashlight and the camera.
                    Circle().fill(ScreenInk.cream.opacity(0.3)).at(12, 124, 20, 20)
                    Circle().fill(ScreenInk.cream.opacity(0.3)).at(80, 124, 20, 20)
                    DiagramMask(window: CGRect(x: 9, y: 57, width: 94, height: 46), corner: 10)
                }
                caption(TourCompanyDiagram.lockScreenCaption, under: lock)
            }
        }
    }

    private func caption(_ words: LocalizedStringResource, under part: CGRect) -> some View {
        Text(words)
            .diagramText(.caption2, RoomPaper.note)
            .frame(width: part.width)
            .offset(x: part.minX, y: 172)
    }
}

/// The small Pixel Cat widget as the user first sees it in the widget gallery: the resting cat
/// (`getSnapshot`) in the companion window, and the button as a bare capsule.
private struct SmallWidget: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            continuous(16).fill(RoomPaper.paper)
            // The real widget's stitched line.
            continuous(12.5)
                .strokeBorder(RoomPaper.edge, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .padding(3.5)
            continuous(8).fill(ScreenInk.companionWindow).at(15, 6, 40, 40)
            // 32 px on 32 pt: 2 or 3 screen pixels to an art pixel, whole numbers on every device.
            Image("pocket-figure-sleeping")
                .resizable()
                .interpolation(.none)
                .at(19, 10, 32, 32)
            Capsule().fill(RoomPaper.moss).at(13, 52, 44, 8)
        }
    }
}

// MARK: - 12.6 Control Center

private struct ControlCenter: View {
    /// Ours, in the order they are drawn: the third row from the left, and the legend from the top.
    let controls: [PocketCatControlFace]
    /// Up from the bottom edge (an iPhone with a Home button), else down from the top-right corner.
    let swipesUp: Bool
    private let part = CGRect(x: 12, y: 23, width: 112, height: 154)

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScreenPart(frame: part) {
                // Control Center's own dark layer; it is the mask here, so there is no second one.
                ScreenInk.shade.opacity(ScreenInk.controlCenterShade)
                // The bottom row (y = 126) makes way for the swipe up.
                ForEach(0..<(swipesUp ? 4 : 5), id: \.self) { row in
                    ForEach(0..<4, id: \.self) { column in
                        let origin = CGPoint(x: 11 + 24 * CGFloat(column), y: 30 + 24 * CGFloat(row))
                        if row == 2, column < 3, controls.indices.contains(column) {
                            control(controls[column]).offset(x: origin.x, y: origin.y)
                        } else {
                            Circle().fill(ScreenInk.cream.opacity(0.18))
                                .frame(width: 18, height: 18)
                                .offset(x: origin.x, y: origin.y)
                        }
                    }
                }
                WindowLine(corner: 12).at(8, 75, 72, 24)
                SwipeTrail(up: swipesUp).at(0, 0, part.width, part.height)
            }
            legend
        }
    }

    /// Ours, all three off: no "keeping company" look. Fixed colours, as the dark layer is fixed.
    private func control(_ face: PocketCatControlFace) -> some View {
        Circle().fill(ScreenInk.controlFace)
            .frame(width: 18, height: 18)
            .overlay { Image(face.symbol).font(.system(size: 10)).foregroundStyle(ScreenInk.controlGlyph) }
    }

    /// The three controls at a readable size, with the names the user searches for. On the plate,
    /// so these follow the colour scheme.
    private var legend: some View {
        ForEach(Array(controls.prefix(3).enumerated()), id: \.offset) { index, face in
            HStack(spacing: 10) {
                Circle().fill(RoomPaper.paper)
                    .overlay { Circle().strokeBorder(RoomPaper.edge, lineWidth: 1) }
                    .overlay { Image(face.symbol).font(.system(size: 15)).foregroundStyle(RoomPaper.moss) }
                    .frame(width: 32, height: 32)
                Text(face.title).diagramText(.footnote, RoomPaper.ink)
                Spacer(minLength: 0)
            }
            .at(136, 34 + 44 * CGFloat(index), 172, 44)
        }
    }
}

/// Where to swipe: a 6 pt cream dot, a 20 pt line from it and a small chevron at its end. Down from
/// 16 pt in from the top-right corner, or up from the middle of the bottom edge. Still: no motion,
/// no finger.
private struct SwipeTrail: View {
    let up: Bool

    var body: some View {
        Trail(up: up)
            .stroke(ScreenInk.cream, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .overlay { Trail.Dot(up: up).fill(ScreenInk.cream) }
    }

    nonisolated struct Trail: Shape {
        /// The dot's centre is 6 pt from its edge; down from the top, 16 pt in from the right.
        static let edgeGap: CGFloat = 6
        static let rightInset: CGFloat = 16
        static let length: CGFloat = 20
        let up: Bool

        static func start(in rect: CGRect, up: Bool) -> CGPoint {
            up ? CGPoint(x: rect.midX, y: rect.maxY - edgeGap) : CGPoint(x: rect.maxX - rightInset, y: rect.minY + edgeGap)
        }

        func path(in rect: CGRect) -> Path {
            let start = Self.start(in: rect, up: up)
            let step: CGFloat = up ? -1 : 1
            let end = CGPoint(x: start.x, y: start.y + step * Self.length)
            let arm = 4 / 2.squareRoot()
            return Path { p in
                p.move(to: start)
                p.addLine(to: end)
                p.move(to: CGPoint(x: end.x - arm, y: end.y - step * arm))
                p.addLine(to: end)
                p.addLine(to: CGPoint(x: end.x + arm, y: end.y - step * arm))
            }
        }

        /// The dot the line starts from.
        nonisolated struct Dot: Shape {
            let up: Bool

            func path(in rect: CGRect) -> Path {
                let centre = Trail.start(in: rect, up: up)
                return Path(ellipseIn: CGRect(x: centre.x - 3, y: centre.y - 3, width: 6, height: 6))
            }
        }
    }
}

// MARK: - 12.7 Holding the icon

private struct IconShortcuts: View {
    let kinds: [QuickActionKind]
    let icon: Image

    var body: some View {
        ScreenPart(frame: CGRect(x: 12, y: 12, width: 296, height: 176)) {
            ForEach(0..<4, id: \.self) { row in
                ForEach(0..<7, id: \.self) { column in
                    // The icon's own cell.
                    if row > 0 || column > 0 {
                        EmptyCell().offset(x: 12 + 42 * CGFloat(column), y: 12 + 42 * CGFloat(row))
                    }
                }
            }
            // The system's own dimmed Home Screen: the icon and the menu float over it, so no window.
            DiagramMask(window: nil, corner: 0)
            // The icon this device shows now (`AppIconPreview`), so the user looks for the same one.
            icon.resizable().clipShape(continuous(9)).at(12, 12, 40, 40).bubbleShadow()
            menu.frame(width: 176).offset(x: 12, y: 60).bubbleShadow()
        }
    }

    /// The items in the system's order, the first next to the icon. The system's own rows (Edit
    /// Home Screen and the rest) are left out. Titles and symbols are the Home Screen's own
    /// (`QuickActionKind.title`, `.image`): the companion's is our cat's paw, the others the system's.
    private var menu: some View {
        VStack(spacing: 0) {
            ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                if index > 0 { RoomPaper.edge.frame(height: 0.5) }
                HStack(spacing: 8) {
                    Text(verbatim: kind.title).diagramText(.footnote, RoomPaper.ink)
                    Spacer(minLength: 0)
                    kind.image.font(.system(size: 13)).foregroundStyle(RoomPaper.ink)
                }
                .padding(.horizontal, 12)
                .frame(height: 26)
            }
        }
        .background(continuous(12).fill(RoomPaper.paper))
        .clipShape(continuous(12))
        .overlay { continuous(12).strokeBorder(RoomPaper.edge, lineWidth: 1) }
    }
}

private extension View {
    /// The bubble's shadow: black 22 %, blur 8, down 4.
    func bubbleShadow() -> some View {
        let s = TourNoteMetrics.bubbleShadow
        return shadow(color: .black.opacity(s.opacity), radius: s.radius, y: s.y)
    }
}

// MARK: - DEBUG and previews

#if DEBUG
/// The diagrams on the pages' paper, for screenshots before the pages are wired.
/// - `pages`: the three pages with every Home Screen item, as on an iPhone.
/// - `conditions`: 12.7 with no camera, with no piece with a photo, and with neither.
/// - `ipad`: 12.5 with the Home Screen alone, and 12.7; chapter 12 has no 12.6 on iPad.
/// - `home-button`: 12.6 with the swipe up from the bottom edge, then with the swipe down.
/// At accessibility text sizes the diagrams are hidden and a line says so. Launch with
/// `-MeowverseOverlayGallery diagrams-<set>` once `OverlayGallery` lists the three pages.
struct TourCompanyDiagramGallery: View {
    enum Set: String {
        case pages, conditions, ipad
        case homeButton = "home-button"
    }

    @Environment(\.dynamicTypeSize) private var typeSize
    let set: Set

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 6) {
                        if TourCompanyDiagram.isShown(at: typeSize) {
                            item.diagram
                        } else {
                            Text(verbatim: "(diagram hidden at accessibility sizes)").font(.footnote)
                        }
                        Text(verbatim: item.label).font(.caption2).foregroundStyle(RoomPaper.note)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        // `-MeowverseDiagramsFromBottom` opens scrolled to the end, for the last plate on a short screen.
        .defaultScrollAnchor(ProcessInfo.processInfo.arguments.contains("-MeowverseDiagramsFromBottom") ? .bottom : .top)
        .memoryPage(.home)
    }

    private var items: [(label: String, diagram: TourCompanyDiagram)] {
        switch set {
        case .pages:
            [("12.5", .sample(.homeScreen)), ("12.6", .sample(.controlCenter)), ("12.7", .sample(.iconShortcuts))]
        case .conditions:
            [("12.7 no camera", .sample(.iconShortcuts, camera: false)),
             ("12.7 no piece with a photo", .sample(.iconShortcuts, photos: false)),
             ("12.7 neither", .sample(.iconShortcuts, camera: false, photos: false))]
        case .ipad:
            [("12.5 iPad", .sample(.homeScreen, homeOnly: true)), ("12.7", .sample(.iconShortcuts))]
        case .homeButton:
            [("12.6 Home button", .sample(.controlCenter, swipesUp: true)), ("12.6 Face ID", .sample(.controlCenter))]
        }
    }
}
#endif

private extension TourCompanyDiagram {
    /// A diagram with made-up conditions, for the gallery and the previews.
    static func sample(_ page: TourCompanyPage, camera: Bool = true, photos: Bool = true,
                       homeOnly: Bool = false, swipesUp: Bool = false) -> TourCompanyDiagram {
        TourCompanyDiagram(page: page, conditions: TourCompanyConditions(hasCamera: camera, hasPhotoFurniture: photos),
                           homeOnly: homeOnly, swipesUp: swipesUp)
    }
}

/// One diagram on the page's paper in light and in dark.
private struct DiagramPreview: View {
    let diagram: TourCompanyDiagram

    var body: some View {
        VStack(spacing: 0) {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                diagram
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(RoomPaper.leaf)
                    .environment(\.colorScheme, scheme)
            }
        }
    }
}

#Preview("12.5 Home Screen") { DiagramPreview(diagram: .sample(.homeScreen)) }
#Preview("12.5 on iPad") { DiagramPreview(diagram: .sample(.homeScreen, homeOnly: true)) }
#Preview("12.6 Control Center") { DiagramPreview(diagram: .sample(.controlCenter)) }
#Preview("12.6 Home button") { DiagramPreview(diagram: .sample(.controlCenter, swipesUp: true)) }
#Preview("12.7 Shortcuts") { DiagramPreview(diagram: .sample(.iconShortcuts)) }
#Preview("12.7 no camera") { DiagramPreview(diagram: .sample(.iconShortcuts, camera: false)) }
#Preview("12.7 no piece with a photo") { DiagramPreview(diagram: .sample(.iconShortcuts, photos: false)) }
#Preview("12.7 neither") { DiagramPreview(diagram: .sample(.iconShortcuts, camera: false, photos: false)) }
