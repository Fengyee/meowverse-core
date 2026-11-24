import ImageIO
import MeowverseCore
import SwiftUI
import UIKit

/// Colours measured from a theme's exported art (generated into RoomThemeArt.swift).
struct RoomThemeArt {
    /// The floor's plank fill, also the plinth's edge.
    let floor: UInt32
    /// The wall field above the wainscot: plain walls, and the wall's top and outer faces.
    let wall: UInt32
    let dayPaper: UInt32
    /// Six themes have a night painting; the other seven ship their day painting taken to night by
    /// the exporters (paper at night depth, ornaments kept visible).
    let nightPaper: UInt32
}

extension RoomTheme {
    var title: String {
        switch self {
        case .creamOak: String(localized: "奶油橡木", table: "RoomThemes")
        case .mintConservatory: String(localized: "薄荷温室", table: "RoomThemes")
        case .seaSalt: String(localized: "海盐蓝岸", table: "RoomThemes")
        case .peachBakery: String(localized: "桃桃烘焙", table: "RoomThemes")
        case .sakuraLetters: String(localized: "樱花来信", table: "RoomThemes")
        case .mushroomRain: String(localized: "雨后蘑菇", table: "RoomThemes")
        case .honeyPicnic: String(localized: "蜂蜜野餐", table: "RoomThemes")
        case .lilacMoon: String(localized: "雾紫月眠", table: "RoomThemes")
        case .winterKnit: String(localized: "冬日针织", table: "RoomThemes")
        case .forestLibrary: String(localized: "森林书房", table: "RoomThemes")
        // Named as their furniture sets are: the pack's colourway names read as lighting.
        case .gildedPalace: String(localized: "鎏金宫廷", table: "RoomThemes")
        case .jiangnanStudy: String(localized: "江南雅居", table: "RoomThemes")
        case .sakuraTatami: String(localized: "樱庭和室", table: "RoomThemes")
        }
    }

    /// The Swift case name, which names the bundled files (`theme-<name>-floor.webp` …).
    var fileStem: String {
        switch self {
        case .creamOak: "creamOak"
        case .mintConservatory: "mintConservatory"
        case .seaSalt: "seaSalt"
        case .peachBakery: "peachBakery"
        case .sakuraLetters: "sakuraLetters"
        case .mushroomRain: "mushroomRain"
        case .honeyPicnic: "honeyPicnic"
        case .lilacMoon: "lilacMoon"
        case .winterKnit: "winterKnit"
        case .forestLibrary: "forestLibrary"
        case .gildedPalace: "gildedPalace"
        case .jiangnanStudy: "jiangnanStudy"
        case .sakuraTatami: "sakuraTatami"
        }
    }

    func resource(_ part: String) -> URL? {
        Bundle.main.url(forResource: "theme-\(fileStem)-\(part)", withExtension: "webp")
    }

    /// The paper behind the room as one colour: the backdrop under the painting, the postcard's
    /// background, and what the status-bar shade is judged against.
    func paper(in phase: RoomLightPhase) -> UIColor {
        if phase == .night { return UIColor(hex: art.nightPaper) }
        return phase.backdrop(color: UIColor(hex: art.dayPaper))
    }
}

enum RoomThemeImages {
    /// Decodes a bundled theme image. WebP goes through ImageIO; nil if the file is missing.
    static func cgImage(_ url: URL?) -> CGImage? {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private static let cache = NSCache<NSString, UIImage>()

    /// Backdrop pieces, drawn at 2 px per point (the tile is 512 px, 256 pt).
    static func image(_ theme: RoomTheme, _ part: String) -> UIImage? {
        let key = "\(theme.fileStem)-\(part)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = cgImage(theme.resource(part)).map({ UIImage(cgImage: $0, scale: 2, orientation: .up) }) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// The room page's background: the theme's painted paper, with its four corner ornaments moved in
/// from the screen corners to where the controls leave them visible: below the top band and above
/// the bottom band, against the side edges (art/ui/THEMES.md). The painting is never
/// cropped to the screen, so a 2:3 painting suits every phone and iPad shape.
///
/// By day the day painting. At night (light that follows the local time) the night painting, or
/// for the seven themes without one the exporters' night version of the day painting. Dawn and
/// dusk lay the same tint over the painting that they lay over a plain colour.
struct RoomThemeBackdrop: View {
    let theme: RoomTheme
    let phase: RoomLightPhase
    /// Where the controls end: the top band's bottom below the safe-area top, and the bottom band's
    /// height above the safe-area bottom. Nil leaves the ornaments out (a backdrop only seen at
    /// the screen edges).
    var bands: RoomBackdropBands?

    var body: some View {
        let painting = phase == .night ? "night" : "day"
        let base = theme.paper(in: phase)
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            let size = CGSize(width: geometry.size.width + insets.leading + insets.trailing,
                              height: geometry.size.height + insets.top + insets.bottom)
            let global = geometry.frame(in: .global)
            ZStack(alignment: .topLeading) {
                Color(uiColor: base)
                if let tile = RoomThemeImages.image(theme, "\(painting)-paper") {
                    // Tiled from the screen's origin, so the two backdrops of the iPad layout meet without a seam.
                    let origin = CGPoint(x: (global.minX - insets.leading).truncatingRemainder(dividingBy: 256),
                                         y: (global.minY - insets.top).truncatingRemainder(dividingBy: 256))
                    Image(uiImage: tile).resizable(resizingMode: .tile)
                        .frame(width: size.width + 512, height: size.height + 512)
                        .offset(x: -256 - origin.x, y: -256 - origin.y)
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .clipped()
                }
                if let bands {
                    ornaments(painting, in: size, insets: insets, bands: bands, originY: global.minY - insets.top)
                }
                if let tint = phase.paintingTint {
                    Color(uiColor: tint.color).opacity(tint.weight)
                }
            }
            .frame(width: size.width, height: size.height)
            .offset(x: -insets.leading, y: -insets.top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Ornaments as large as the free space beside the controls allows: 92 pt on a phone, up to
    /// 150 pt on an iPad.
    static func ornamentSide(in size: CGSize) -> CGFloat {
        min(150, max(84, min(size.width, size.height) * 0.24))
    }

    /// Space kept between the bottom-right ornament and Talk to Bella's head: its listening ring
    /// reaches 6 pt out, then 8 pt of paper (art review A5).
    static let headClearance: CGFloat = 6 + 8
    /// Space kept between a lifted bottom-right ornament and the room's own drawing.
    static let roomClearance: CGFloat = 6

    /// `originY` is the global y of this backdrop's top edge, to place the bands' global values.
    private func ornaments(_ painting: String, in size: CGSize, insets: EdgeInsets, bands: RoomBackdropBands,
                           originY: CGFloat) -> some View {
        let side = Self.ornamentSide(in: size)
        let top = insets.top + bands.top
        let bottom = size.height - insets.bottom - bands.bottom - side
        let lowest = max(top + side, bottom)
        var spots: [(String, CGPoint)] = [
            ("tl", CGPoint(x: 0, y: top)), ("tr", CGPoint(x: size.width - side, y: top)),
            ("bl", CGPoint(x: 0, y: lowest)),
        ]
        // With the head showing, br moves up above it; where that would run into the room or the
        // top-right ornament (a short phone), br is left out rather than drawn behind the head.
        if let headTop = bands.headTop {
            let lifted = min(lowest, headTop - originY - Self.headClearance - side)
            let roomBottom = bands.roomTrailingBottom.map { $0 - originY + Self.roomClearance } ?? 0
            if lifted >= max(top + side, roomBottom) {
                spots.append(("br", CGPoint(x: size.width - side, y: lifted)))
            }
        } else {
            spots.append(("br", CGPoint(x: size.width - side, y: lowest)))
        }
        return ForEach(spots, id: \.0) { corner, spot in
            if let image = RoomThemeImages.image(theme, "\(painting)-\(corner)") {
                Image(uiImage: image).resizable().interpolation(.high)
                    .frame(width: side, height: side)
                    .offset(x: spot.x, y: spot.y)
            }
        }
    }
}

struct RoomBackdropBands: Equatable {
    var top: CGFloat
    var bottom: CGFloat
    /// Global y of the top of Talk to Bella's head while it shows; the br ornament clears it.
    var headTop: CGFloat? = nil
    /// The lowest global y the room's own drawing reaches in the right-hand ornament column.
    var roomTrailingBottom: CGFloat? = nil
}

extension EnvironmentValues {
    /// Set by the room screen from its measured top and bottom bands.
    @Entry var roomBackdropBands: RoomBackdropBands?
}

extension RoomLightPhase {
    /// The dawn and dusk tint as a layer over the painting: the same blend `backdrop(color:)` makes.
    /// Night has its own painting instead.
    var paintingTint: (color: UIColor, weight: Double)? {
        guard self != .night, let tint = backdropTint else { return nil }
        return (UIColor(red: tint.r, green: tint.g, blue: tint.b, alpha: 1), Double(tint.weight))
    }
}
