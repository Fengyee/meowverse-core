import SwiftUI
import WidgetKit

// Round 11, step one: four widgets with the pixel cat (Home Screen small and medium, Lock Screen
// circular and rectangular). No photos and no names: the extension's own art, and the running
// companion that the app copies into the App Group (`PocketCatCompanyShelf`).
// Sizes, colours and spacing follow `art/ui/source/widget-mockups.py`, as approved in
// `art/ui/reviews/r11-widgets.md`.

// MARK: Timeline

struct PocketCatWidgetEntry: TimelineEntry {
    let moment: PocketCatWidgetPlan.Moment
    var date: Date { moment.date }
}

struct PocketCatWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> PocketCatWidgetEntry {
        PocketCatWidgetEntry(moment: .init(date: .now, mood: .sleeping, sessionID: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping (PocketCatWidgetEntry) -> Void) {
        // The widget gallery shows the cat at rest, never a running companion.
        let companion = context.isPreview ? nil : Self.runningCompanion()
        let plan = PocketCatWidgetPlan.plan(at: .now, companion: companion)
        completion(PocketCatWidgetEntry(moment: plan.moments[0]))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PocketCatWidgetEntry>) -> Void) {
        let plan = PocketCatWidgetPlan.plan(at: .now, companion: Self.runningCompanion())
        completion(Timeline(entries: plan.moments.map(PocketCatWidgetEntry.init), policy: .after(plan.reloadAt)))
    }

    /// The companion the Live Activity is showing, as the app left it in the App Group. The
    /// extension can't read the app's activities itself (`Activity.activities` is empty here).
    static func runningCompanion() -> PocketCatWidgetPlan.Companion? {
        PocketCatCompanyShelf.shared?.companion(at: .now)
    }
}

// MARK: Widgets

struct PocketCatHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PocketCatWidgetKind.home, provider: PocketCatWidgetProvider()) { entry in
            PocketCatHomeWidgetView(moment: entry.moment)
                .widgetURL(PocketCatWidgetLink.companion)
        }
        .configurationDisplayName(Text("Pixel Cat", tableName: "PocketCat"))
        .description(Text("Your pixel cat, and a button that brings it to keep you company.", tableName: "PocketCat"))
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct PocketCatLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PocketCatWidgetKind.lock, provider: PocketCatWidgetProvider()) { entry in
            PocketCatLockWidgetView(moment: entry.moment)
                .widgetURL(PocketCatWidgetLink.companion)
        }
        .configurationDisplayName(Text("Pixel Cat", tableName: "PocketCat"))
        .description(Text("Your pixel cat on the Lock Screen.", tableName: "PocketCat"))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

/// A tap anywhere but a button opens the companion page (E5), the same link as the Live Activity.
private enum PocketCatWidgetLink {
    static var companion: URL? {
        guard let host = Bundle.main.object(forInfoDictionaryKey: "MeowverseHostBundleID") as? String else { return nil }
        return PocketCatLink.url(for: host)
    }
}

// MARK: Colours

/// The app's paper tokens (`tokens.json`, `RoomPaper` in the app), which the extension can't
/// import, and the companion page's green window.
private struct PocketCatWidgetPalette {
    let paper, ink, edge, moss, seal: Color

    static func of(_ scheme: ColorScheme) -> Self {
        scheme == .dark
            ? .init(paper: .hex(0x473D34), ink: .hex(0xFFF4DE), edge: .hex(0xB49B79), moss: .hex(0xB8D0A6), seal: .hex(0x253123))
            : .init(paper: .hex(0xFFF4DE), ink: .hex(0x493B2D), edge: .hex(0xC3AB85), moss: .hex(0x4C674D), seal: .hex(0xFFFDF5))
    }

    /// `PocketCatView`'s window, #293B30, in both modes (A1).
    static let window = Color(red: 0.16, green: 0.23, blue: 0.19)
    /// The cat's shadow inside the window.
    static let shadow = Color(red: 10 / 255, green: 18 / 255, blue: 13 / 255).opacity(110 / 255)
}

private extension Color {
    static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

// MARK: Home Screen

private struct PocketCatHomeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var scheme
    let moment: PocketCatWidgetPlan.Moment

    var body: some View {
        let palette = PocketCatWidgetPalette.of(scheme)
        Group {
            if family == .systemMedium { medium(palette) } else { small(palette) }
        }
        .containerBackground(for: .widget) {
            // Removed by the system in tinted mode, the stitched edge with it.
            ZStack {
                palette.paper
                ContainerRelativeShape()
                    .inset(by: 6.5)
                    .stroke(palette.edge, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
    }

    /// 158 pt on an iPhone 15 Pro: the window at the top, the expression, the button.
    private func small(_ palette: PocketCatWidgetPalette) -> some View {
        VStack(spacing: 6) {
            PocketCatWidgetCat(mood: moment.mood, pointsPerPixel: 2, window: 68)
            PocketCatWidgetWord(moment: moment, font: .headline, ink: palette.ink)
                .frame(maxWidth: .infinity)
            PocketCatWidgetButtons.primary(moment, palette: palette)
                // Re-review two: the small button never grows past the default size.
                .dynamicTypeSize(...DynamicTypeSize.large)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 338 × 158 pt: a large window on the left; the expression and two buttons on the right.
    private func medium(_ palette: PocketCatWidgetPalette) -> some View {
        HStack(spacing: 16) {
            PocketCatWidgetCat(mood: moment.mood, pointsPerPixel: 3, window: 126)
            VStack(alignment: .leading, spacing: 8) {
                PocketCatWidgetWord(moment: moment, font: .title3, ink: palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                Spacer(minLength: 0)
                PocketCatWidgetButtons.primary(moment, palette: palette)
                PocketCatWidgetButtons.addPhotos(palette: palette)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The whole pixel cat: the colour cat in the companion page's dark green window, or in tinted
/// mode the one-colour cat as a template with no window (review 3-3), which would otherwise
/// turn into a solid plate of tint.
private struct PocketCatWidgetCat: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let mood: PocketCatMood
    let pointsPerPixel: CGFloat
    let window: CGFloat

    var body: some View {
        let side = 32 * pointsPerPixel
        Group {
            if renderingMode == .fullColor {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(PocketCatWidgetPalette.window)
                    Ellipse()
                        .fill(PocketCatWidgetPalette.shadow)
                        .frame(width: side * 0.76, height: 2.5 * pointsPerPixel + 2)
                        .offset(y: side / 2 - 1.75 * pointsPerPixel + 1)
                    pixels("pocket-figure-" + mood.rawValue, side: side)
                }
            } else {
                pixels("mono-figure-" + mood.rawValue, side: side)
                    .widgetAccentable()
            }
        }
        .frame(width: window, height: window)
        .accessibilityHidden(true)
    }

    private func pixels(_ name: String, side: CGFloat) -> some View {
        Image(name).resizable().interpolation(.none).frame(width: side, height: side)
    }
}

/// The expression. While a companion runs it is the Live Activity's (E2). It follows Dynamic
/// Type; the small widget's button does not (re-review two, rule 4).
private struct PocketCatWidgetWord: View {
    let moment: PocketCatWidgetPlan.Moment
    let font: Font.TextStyle
    let ink: Color

    var body: some View {
        Text(moment.mood.title)
            .font(.system(font, design: .rounded)).fontWeight(.semibold)
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityIdentifier("pocket-widget-expression")
    }
}

private enum PocketCatWidgetButtons {
    /// "Keep me company" (filled) starts company with the control's intent; while a companion
    /// runs, "Change expression" (outlined) changes that companion's expression with the Live
    /// Activity's own intent (E1).
    @ViewBuilder
    static func primary(_ moment: PocketCatWidgetPlan.Moment, palette: PocketCatWidgetPalette) -> some View {
        switch moment.button {
        case .start:
            Button(intent: StartPocketCatCompany()) {
                PocketCatWidgetCapsule(filled: true, palette: palette) { Text(PocketCatCopy.title) }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pocket-widget-start")
        case .change(let sessionID):
            Button(intent: ChangePocketCatMood(sessionID: sessionID)) {
                PocketCatWidgetCapsule(filled: false, palette: palette) { Text(PocketCatCopy.change) }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pocket-widget-change")
        }
    }

    /// "+ Add photos" opens the app on the Control Center button's path.
    static func addPhotos(palette: PocketCatWidgetPalette) -> some View {
        Button(intent: AddFromPhotos()) {
            PocketCatWidgetCapsule(filled: false, palette: palette) {
                Text("\(Image(systemName: "plus")) \(Text("Add photos", tableName: "PocketCat"))")
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pocket-widget-add-photos")
    }
}

/// The ink-green capsule: full width, 32 pt high, 8 pt side padding, text shrinking to 0.8
/// (re-review, decision 1). In tinted mode a filled capsule becomes a light plate under the
/// text, or both would turn into one solid shape.
private struct PocketCatWidgetCapsule<Label: View>: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let filled: Bool
    let palette: PocketCatWidgetPalette
    @ViewBuilder let label: () -> Label

    var body: some View {
        let tinted = renderingMode != .fullColor
        label()
            .font(.system(.subheadline, design: .rounded)).fontWeight(.semibold)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .foregroundStyle(filled && !tinted ? palette.seal : palette.moss)
            .background {
                if filled {
                    Capsule().fill(tinted ? AnyShapeStyle(.primary.opacity(0.24)) : AnyShapeStyle(palette.moss))
                } else {
                    Capsule().strokeBorder(palette.moss, lineWidth: 1.5)
                }
            }
            .contentShape(Capsule())
    }
}

// MARK: Lock Screen

private struct PocketCatLockWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let moment: PocketCatWidgetPlan.Moment

    var body: some View {
        if family == .accessoryCircular { circular } else { rectangular }
    }

    /// The one-colour head, 2 pt per pixel (40 pt) in the 72 pt circle.
    private var circular: some View {
        Image("mono-" + moment.mood.rawValue)
            .resizable()
            .interpolation(.none)
            .frame(width: 40, height: 40)
            .widgetAccentable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // No text in the circle, so the image says what it shows (E4).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Pixel cat, \(Text(moment.mood.title))", tableName: "PocketCat"))
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("pocket-widget-circular")
            .containerBackground(for: .widget) { AccessoryWidgetBackground() }
    }

    /// The one-colour cat (64 pt) and, beside it, what the cat is up to: a secondary line of up
    /// to two lines and the expression on one (re-review, decision 2). No background.
    private var rectangular: some View {
        HStack(spacing: 6) {
            Image("mono-figure-" + moment.mood.rawValue)
                .resizable()
                .interpolation(.none)
                .frame(width: 64, height: 64)
                .widgetAccentable()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if moment.keepsCompany {
                        Text("Keeping you company", tableName: "PocketCat")
                    } else {
                        Text(PocketCatCopy.title)
                    }
                }
                .font(.system(.footnote, design: .rounded)).fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                Text(moment.mood.title)
                    .font(.system(.headline, design: .rounded)).fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pocket-widget-rectangular")
        .containerBackground(for: .widget) { Color.clear }
    }
}
