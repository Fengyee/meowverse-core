import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import MeowverseCore

/// Takes an already-rendered virtual scene. The compositor has no model, photo library or view access.
nonisolated enum RoomPostcard {
    static let destination = "https://fengyee.github.io/meowverse/"
    static let maximumTitleLength = 60
    static let sceneSize = CGSize(width: 1080, height: 730)

    enum RenderError: LocalizedError {
        case title, canvas, qr
        var errorDescription: String? {
            switch self {
            case .title: String(localized: "请填写 1–60 个字的标题。")
            case .canvas: String(localized: "暂时无法绘制明信片，请重试。")
            case .qr: String(localized: "暂时无法生成二维码，请重试。")
            }
        }
    }

    static let printScale: CGFloat = 2
    private static let side: CGFloat = 1200
    private static let appIcon: CGImage? = {
        guard let url = Bundle.main.url(forResource: "postcard-app-icon", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()
    private static let left: CGFloat = 64
    private static let paper = color(0xF7F3E9)
    private static let ink = color(0x2D443C)
    private static let sage = color(0x526957)
    private static let field = color(0xDEE6DB)
    /// Sans-serif text on the card: PingFang for Chinese, Helvetica Neue (as the web address) otherwise.
    private static let sansRegular = AppLanguage.isChinese ? "PingFangSC-Regular" : "HelveticaNeue"
    private static let sansMedium = AppLanguage.isChinese ? "PingFangSC-Medium" : "HelveticaNeue-Medium"

    /// `stats` nil (or with nothing to say) leaves the card exactly as it is without statistics.
    static func render(scene: CGImage, title: String, showsQR: Bool, stats: LibraryStats? = nil) throws -> CGImage {
        let clean = title.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= maximumTitleLength else { throw RenderError.title }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(side * printScale), height: Int(side * printScale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw RenderError.canvas }
        context.scaleBy(x: printScale, y: printScale)
        context.setFillColor(paper)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        try drawBrand(in: context)
        if let stats { drawStats(statsParts(stats), in: context) }
        drawScene(scene, in: context)
        try drawTitle(clean, width: showsQR ? 810 : 1072, in: context)
        if showsQR { try drawInvitation(in: context) }
        guard let card = context.makeImage() else { throw RenderError.canvas }
        return card
    }

    private static func color(_ hex: Int) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    private static func rect(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: x, y: side - top - height, width: width, height: height)
    }

    private static func text(_ value: String, font: CTFont, ink: CGColor) -> NSAttributedString {
        NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink
        ])
    }

    private static func line(_ value: String, font name: String, size: CGFloat, ink: CGColor,
                             x: CGFloat, baseline: CGFloat, rightAligned: Bool = false, kern: CGFloat? = nil,
                             in c: CGContext) {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let attributed = NSMutableAttributedString(attributedString: text(value, font: font, ink: ink))
        if let kern {
            attributed.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String), value: kern,
                                    range: NSRange(location: 0, length: attributed.length))
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let offset = rightAligned ? CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) : 0
        c.textPosition = CGPoint(x: x - offset, y: side - baseline)
        CTLineDraw(line, c)
    }

    private static func drawBrand(in c: CGContext) throws {
        guard let appIcon else { throw RenderError.canvas }
        let stamp = rect(left, 40, 78, 78)
        c.saveGState()
        c.addPath(CGPath(roundedRect: stamp, cornerWidth: 17, cornerHeight: 17, transform: nil))
        c.clip()
        c.interpolationQuality = .high
        c.draw(appIcon, in: stamp)
        c.restoreGState()
        let x = stamp.maxX + 16
        switch brand {
        case .latin:
            line(brand.words, font: "Georgia", size: 51, ink: ink, x: x, baseline: 99, in: c)
        case .chinese:
            // 48 pt KuaiLe on the same baseline: its ink (61–103 pt from the top) is centred where
            // Georgia's capitals are (64–100), beside the 40–118 stamp, and the full-height Han
            // weigh about as much as the Latin capitals. Kern 0: KuaiLe has no kern table, and
            // CoreText's default spacing would add space after the glyphs (art-craft).
            let font = CTFontCopyPostScriptName(CTFontCreateWithName(titleFace as CFString, 48, nil)) as String == titleFace
                ? titleFace : "PingFangSC-Semibold"
            line(brand.words, font: font, size: 48, ink: ink, x: x, baseline: 99, kern: 0, in: c)
        }
    }

    /// The app's name in the interface language (owner: 喵空间 everywhere in Chinese).
    private static let brand = PostcardBrand.forInterface(languageCode: AppLanguage.code)
    /// The title face (`RoomTitleFont.cuteFaceName`, bundled and listed in `UIAppFonts`). If it did not
    /// register, CoreText substitutes another font, so the Chinese name falls back to PingFang.
    private static let titleFace = "ZCOOLKuaiLe-Regular"

    // MARK: - Library statistics

    /// The pieces of the stats line, each a whole localizable phrase. Zero counts and an unknown
    /// date span are left out, never shown as 0 or guessed.
    static func statsParts(_ stats: LibraryStats) -> [String] {
        var parts: [String] = []
        if stats.photoCount > 0 { parts.append(String(localized: "\(stats.photoCount) 张照片")) }
        if stats.furnitureCount > 0 { parts.append(String(localized: "\(stats.furnitureCount) 件家具")) }
        if let span = stats.captureSpan, let text = captureSpanText(span) { parts.append(text) }
        return parts
    }

    /// The span of known capture days as year + month, e.g. "2023年3月 – 2026年11月"; one month
    /// when both ends fall in it. The language follows the app's interface, not the device language.
    static func captureSpanText(_ span: LibraryStats.CaptureSpan) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        func noon(_ day: String) -> Date? {
            guard PhotoLibrary.isValidDay(day) else { return nil }
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
        }
        let locale = AppLanguage.locale
        guard let start = noon(span.earliest), let end = noon(span.latest), start <= end else { return nil }
        if span.earliest.prefix(7) == span.latest.prefix(7) {
            return start.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).year().month())
        }
        return (start..<end).formatted(Date.IntervalFormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .year().month())
    }

    /// Right-aligned in the brand row, so the scene, title and invitation keep their layout.
    /// Shrinks to fit beside the wordmark; drops trailing parts only if it still cannot fit.
    private static func drawStats(_ parts: [String], in c: CGContext) {
        let maxWidth = side - left - 440
        var parts = parts
        while !parts.isEmpty {
            let value = parts.joined(separator: " · ")
            for size in stride(from: CGFloat(24), through: 17, by: -1) {
                let font = CTFontCreateWithName(sansRegular as CFString, size, nil)
                let line = CTLineCreateWithAttributedString(text(value, font: font, ink: sage))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                guard width <= maxWidth else { continue }
                c.textPosition = CGPoint(x: side - left - width, y: side - 90)
                CTLineDraw(line, c)
                return
            }
            parts.removeLast()
        }
    }

    private static func drawScene(_ image: CGImage, in c: CGContext) {
        let window = rect(60, 145, sceneSize.width, sceneSize.height)
        let factor = min(window.width / CGFloat(image.width), window.height / CGFloat(image.height))
        let w = CGFloat(image.width) * factor, h = CGFloat(image.height) * factor
        c.saveGState()
        c.addPath(CGPath(roundedRect: window, cornerWidth: 12, cornerHeight: 12, transform: nil))
        c.clip()
        c.setFillColor(field)
        c.fill(window)
        c.interpolationQuality = .high
        c.draw(image, in: CGRect(x: window.midX - w / 2, y: window.midY - h / 2, width: w, height: h))
        c.restoreGState()
    }

    private static func titleLines(_ title: String, size: CGFloat, width: CGFloat) -> [CTLine]? {
        let cascade = ["SongtiSC-Regular", "AppleColorEmoji"].map { name in
            CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: name] as CFDictionary)
        }
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontNameAttribute: "Georgia", kCTFontCascadeListAttribute: cascade
        ] as CFDictionary)
        let attributed = text(title, font: CTFontCreateWithFontDescriptor(descriptor, size, nil), ink: ink)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var lines: [CTLine] = [], start = 0
        while start < attributed.length, lines.count < 2 {
            let length = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            guard length > 0 else { return nil }
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length))
            guard CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line) <= width + 1
            else { return nil }
            lines.append(line)
            start += length
        }
        return start == attributed.length ? lines : nil
    }

    private static func drawTitle(_ title: String, width: CGFloat, in c: CGContext) throws {
        for fontSize in stride(from: 66, through: 16, by: -1) {
            let size = CGFloat(fontSize)
            guard let lines = titleLines(title, size: size, width: width) else { continue }
            let spacing = size * 1.24
            let baseline = CGFloat(1010) + size * 0.21 - CGFloat(lines.count - 1) * spacing / 2
            for (i, line) in lines.enumerated() {
                c.textPosition = CGPoint(x: left, y: side - baseline - CGFloat(i) * spacing)
                CTLineDraw(line, c)
            }
            return
        }
        throw RenderError.title
    }

    private static func drawInvitation(in c: CGContext) throws {
        guard let filter = CIFilter(name: "CIQRCodeGenerator", parameters: [
            "inputMessage": Data(destination.utf8), "inputCorrectionLevel": "M"
        ]), let code = filter.outputImage,
              let encoded = CIContext().createCGImage(code, from: code.extent)
        else { throw RenderError.qr }
        // Core Image includes a one-module rim around its ISO matrix. Removing that
        // rim lets this tile fit 5-pixel modules and a full 4-module white margin.
        let image: CGImage
        if encoded.width % 4 == 3,
           let matrix = encoded.cropping(to: CGRect(x: 1, y: 1, width: encoded.width - 2, height: encoded.height - 2)) {
            image = matrix
        } else {
            image = encoded
        }
        let tile = rect(942, 916, 186, 186)
        let module = floor(tile.width / CGFloat(image.width + 8))
        let width = CGFloat(image.width) * module
        let origin = CGPoint(x: floor(tile.midX - width / 2), y: floor(tile.midY - width / 2))
        c.saveGState()
        c.setFillColor(CGColor(gray: 1, alpha: 1))
        c.fill(tile)
        c.interpolationQuality = .none
        c.setShouldAntialias(false)
        c.draw(image, in: CGRect(origin: origin, size: CGSize(width: width, height: width)))
        c.restoreGState()
        c.setFillColor(color(0xB9C2B4))
        c.fill(rect(left, 1122, side - 2 * left, 1))
        line(String(localized: "扫码探索喵空间"), font: sansMedium, size: 23, ink: sage,
             x: left, baseline: 1161, in: c)
        line("fengyee.github.io/meowverse/", font: "HelveticaNeue", size: 23, ink: sage,
             x: side - left, baseline: 1161, rightAligned: true, in: c)
    }
}
