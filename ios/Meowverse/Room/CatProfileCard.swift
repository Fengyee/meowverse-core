import ImageIO
import MeowverseCore
import SwiftUI

/// A small drawn paw: four oval toe beans over a wide, low pad (art-craft: not the system
/// `pawprint`). Decorative only; fill it with a RoomPaper colour.
nonisolated struct CatPawMark: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func oval(_ cx: CGFloat, _ cy: CGFloat, _ rw: CGFloat, _ rh: CGFloat, turn degrees: CGFloat = 0) -> Path {
            let box = CGRect(x: -rw * w / 2, y: -rh * h / 2, width: rw * w, height: rh * h)
            let transform = CGAffineTransform(translationX: rect.minX + cx * w, y: rect.minY + cy * h)
                .rotated(by: degrees * .pi / 180)
            return Path(ellipseIn: box).applying(transform)
        }
        var path = Path()
        path.addPath(oval(0.50, 0.70, 0.60, 0.40))
        path.addPath(oval(0.13, 0.40, 0.20, 0.27, turn: -24))
        path.addPath(oval(0.36, 0.18, 0.21, 0.28, turn: -8))
        path.addPath(oval(0.64, 0.18, 0.21, 0.28, turn: 8))
        path.addPath(oval(0.87, 0.40, 0.20, 0.27, turn: 24))
        return path
    }
}

/// The pack's preview picture with its backdrop cut away, so the cat stands on our paper and its
/// alpha makes the silhouette. Read once per file and kept (eight small pictures).
private func previewImage(of pack: CatPack) -> CGImage? {
    guard let preview = pack.manifest.preview else { return nil }
    let url = pack.url(for: preview)
    // Keyed by the pack's revision, not its URL: a pack replaced in the same folder gets a new
    // revision, so the old picture is not shown for it (D24-08).
    let key = pack.cacheKey + "/" + preview
    if let kept = PreviewCutouts.kept[key] { return kept }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CatArt.thumbnail(from: source, edge: 512) else { return nil }
    let cutout = PreviewCutouts.cutout(image) ?? image
    PreviewCutouts.kept[key] = cutout
    return cutout
}

enum PreviewCutouts {
    static var kept: [String: CGImage] = [:]

    /// The previews are rendered on a flat grey (#EEEEEE) with no alpha. Everything of the corner's
    /// colour connected to the border is the backdrop; the cat's own pale fur is shaded and never
    /// touches the border, so a white cat survives. Then (art director's review):
    /// - colour: the render's edge pixels mix fur with the grey (and some carry a pale halo); each is
    ///   un-mixed, c = (c − bg·(1−a)) / a, with its coverage `a` measured against the fur 2 px
    ///   inside, and pixels the blur adds outside the cat take that fur, so no pale rim shows on
    ///   dark paper;
    /// - edge: the mask (edge pixels weighted by their coverage) is closed by 1 px, blurred
    ///   (σ 1.5 px) and cut with smoothstep(0.4, 0.6): a smooth, antialiased outline, not 0/1 stairs.
    nonisolated static func cutout(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height, n = w * h
        guard w > 8, h > 8,
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: n * 4)
        var rgb = [Float](repeating: 0, count: n * 3)
        for i in 0..<n { for c in 0..<3 { rgb[i * 3 + c] = Float(px[i * 4 + c]) } }
        let bg = (rgb[0], rgb[1], rgb[2])
        let offsets = [-1, 1, -w, w]
        func inBounds(_ i: Int, _ d: Int) -> Bool {
            let x = i % w
            switch d {
            case -1: return x > 0
            case 1: return x < w - 1
            default: return i + d >= 0 && i + d < n
            }
        }
        /// One step of 3×3 dilation or erosion.
        func morph(_ src: [Bool], dilate: Bool) -> [Bool] {
            var out = src
            for y in 0..<h {
                for x in 0..<w {
                    var hit = !dilate
                    for yy in max(y - 1, 0)...min(y + 1, h - 1) {
                        for xx in max(x - 1, 0)...min(x + 1, w - 1) where src[yy * w + xx] == dilate {
                            hit = dilate
                        }
                    }
                    out[y * w + x] = hit
                }
            }
            return out
        }

        // 1. The backdrop: the corner's colour, connected to the border.
        var cat = [Bool](repeating: true, count: n)
        var queue: [Int] = []
        for x in 0..<w { queue += [x, (h - 1) * w + x] }
        for y in 0..<h { queue += [y * w, y * w + w - 1] }
        while let i = queue.popLast() {
            guard cat[i] else { continue }
            let d = max(abs(rgb[i * 3] - bg.0), abs(rgb[i * 3 + 1] - bg.1), abs(rgb[i * 3 + 2] - bg.2))
            guard d <= 4 else { continue }
            cat[i] = false
            for o in offsets where inBounds(i, o) { queue.append(i + o) }
        }

        //    Pockets of the backdrop closed in by legs and tail don't touch the border; they are the
        //    backdrop's exact flat grey over a patch no fur covers alike (≥ 12 px), so they go too.
        var seen = [Bool](repeating: false, count: n)
        for start in 0..<n where cat[start] && !seen[start] {
            func flat(_ i: Int) -> Bool {
                max(abs(rgb[i * 3] - bg.0), abs(rgb[i * 3 + 1] - bg.1), abs(rgb[i * 3 + 2] - bg.2)) <= 1
            }
            guard flat(start) else { continue }
            var patch: [Int] = []
            var stack = [start]
            seen[start] = true
            while let i = stack.popLast() {
                patch.append(i)
                for o in offsets where inBounds(i, o) && cat[i + o] && !seen[i + o] && flat(i + o) {
                    seen[i + o] = true
                    stack.append(i + o)
                }
            }
            guard patch.count >= 12 else { continue }
            // Grow it through the near-grey rim around it, as the border's fill does.
            var rim = patch
            while let i = rim.popLast() {
                cat[i] = false
                for o in offsets where inBounds(i, o) && cat[i + o] {
                    let j = i + o
                    let d = max(abs(rgb[j * 3] - bg.0), abs(rgb[j * 3 + 1] - bg.1), abs(rgb[j * 3 + 2] - bg.2))
                    if d <= 4 { rim.append(j) }
                }
            }
        }

        //    Slits of grey seen between two legs, at most 3 px wide, are too thin to cut out cleanly;
        //    they are filled with the fur on both sides, so no pale line runs down a leg. The slit's
        //    own soft rim, next to a filled pixel, takes the same fur.
        let source = rgb
        var filled = [Bool](repeating: false, count: n)
        let pale = min(bg.0, bg.1, bg.2) - 60
        for i in 0..<n where cat[i] && min(source[i * 3], source[i * 3 + 1], source[i * 3 + 2]) >= pale {
            let light = min(source[i * 3], source[i * 3 + 1], source[i * 3 + 2])
            /// The most fur-like pixel within 4 px, if one is clearly fur and darker than this one.
            func furSide(_ step: Int) -> Int? {
                var j = i, best: Int?, bestAway: Float = 0
                for _ in 1...4 {
                    guard inBounds(j, step), cat[j + step] else { break }
                    j += step
                    let away = max(abs(source[j * 3] - bg.0), abs(source[j * 3 + 1] - bg.1), abs(source[j * 3 + 2] - bg.2))
                    // Clearly fur, not the shading of pale fur: far from the grey, darker than this.
                    if away >= 120, max(source[j * 3], source[j * 3 + 1], source[j * 3 + 2]) < light - 50, away > bestAway {
                        best = j; bestAway = away
                    }
                }
                return best
            }
            for (back, ahead) in [(-1, 1), (-w, w)] {
                guard let l = furSide(back), let r = furSide(ahead) else { continue }
                for c in 0..<3 { rgb[i * 3 + c] = (source[l * 3 + c] + source[r * 3 + c]) / 2 }
                filled[i] = true
                break
            }
        }
        for _ in 0..<2 {
            let before = filled
            for i in 0..<n where cat[i] && !before[i] {
                guard let j = offsets.first(where: { inBounds(i, $0) && before[i + $0] }).map({ i + $0 }),
                      max(source[i * 3], source[i * 3 + 1], source[i * 3 + 2])
                        > max(rgb[j * 3], rgb[j * 3 + 1], rgb[j * 3 + 2]) + 40 else { continue }
                for c in 0..<3 { rgb[i * 3 + c] = rgb[j * 3 + c] }
                filled[i] = true
            }
        }

        // 2. The fur inside: the core (the cat eroded by 2 px, clear of the edge's mix and halo) as
        //    rendered; outward from it, ring by ring, the mean of the known neighbours.
        let core = morph(morph(cat, dilate: false), dilate: false)
        var known = core
        var fur = rgb
        for _ in 0..<8 {
            var next: [(Int, Float, Float, Float)] = []
            for i in 0..<n where !known[i] {
                var r: Float = 0, g: Float = 0, b: Float = 0, count: Float = 0
                for o in offsets where inBounds(i, o) && known[i + o] {
                    let j = (i + o) * 3
                    r += fur[j]; g += fur[j + 1]; b += fur[j + 2]; count += 1
                }
                if count > 0 { next.append((i, r / count, g / count, b / count)) }
            }
            for (i, r, g, b) in next {
                known[i] = true
                fur[i * 3] = r; fur[i * 3 + 1] = g; fur[i * 3 + 2] = b
            }
        }

        // 3. Each edge pixel's coverage: how far it lies from the grey towards the fur inside.
        //    Pale fur against the pale grey can't be told apart; it counts as covered.
        var cover = [Float](repeating: 1, count: n)
        for i in 0..<n where cat[i] && !core[i] && known[i] {
            let k = (fur[i * 3] - bg.0, fur[i * 3 + 1] - bg.1, fur[i * 3 + 2] - bg.2)
            let len = k.0 * k.0 + k.1 * k.1 + k.2 * k.2
            guard len > 400 else { continue }
            let dot = (rgb[i * 3] - bg.0) * k.0 + (rgb[i * 3 + 1] - bg.1) * k.1 + (rgb[i * 3 + 2] - bg.2) * k.2
            cover[i] = min(max(dot / len, 0), 1)
        }

        // 4. Alpha: close the mask by 1 px, weight the edge by coverage, blur, smoothstep.
        let closed = morph(morph(cat, dilate: true), dilate: false)
        var alpha = (0..<n).map { i -> Float in closed[i] ? (cat[i] ? cover[i] : 1) : 0 }
        let sigma: Float = 1.5, radius = 4
        let kernel = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        for pass in 0..<2 {
            var out = [Float](repeating: 0, count: n)
            for y in 0..<h {
                for x in 0..<w {
                    var sum: Float = 0
                    for k in -radius...radius {
                        let j = pass == 0 ? y * w + min(max(x + k, 0), w - 1) : min(max(y + k, 0), h - 1) * w + x
                        sum += alpha[j] * kernel[k + radius]
                    }
                    out[y * w + x] = sum / total
                }
            }
            alpha = out
        }

        // 5. Colour, premultiplied, and the cat's box.
        var minX = w, minY = h, maxX = -1, maxY = -1
        for i in 0..<n {
            let t = min(max((alpha[i] - 0.4) / 0.2, 0), 1)
            let a = t * t * (3 - 2 * t)
            var c = known[i] ? (fur[i * 3], fur[i * 3 + 1], fur[i * 3 + 2]) : bg
            if cat[i] {
                // Un-mixed from the grey; a thinly covered pixel only magnifies noise that way, so
                // the less fur it holds, the more it leans on the fur inside.
                let m = max(cover[i], 0.05)
                func unmix(_ v: Float, _ b: Float, _ inner: Float) -> Float {
                    let pure = min(max((v - b * (1 - m)) / m, 0), 255)
                    return inner + (pure - inner) * cover[i]
                }
                c = (unmix(rgb[i * 3], bg.0, c.0), unmix(rgb[i * 3 + 1], bg.1, c.1), unmix(rgb[i * 3 + 2], bg.2, c.2))
            }
            px[i * 4] = UInt8(min(max(c.0 * a, 0), 255))
            px[i * 4 + 1] = UInt8(min(max(c.1 * a, 0), 255))
            px[i * 4 + 2] = UInt8(min(max(c.2 * a, 0), 255))
            px[i * 4 + 3] = UInt8(min(max(a * 255, 0), 255))
            if a > 0.01 {
                let x = i % w, y = i / w
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard let whole = context.makeImage() else { return nil }
        guard maxX >= minX else { return whole }
        // Trimmed to the cat, so every cat fills her mat alike (the previews frame them differently).
        let margin = 2
        let box = CGRect(x: max(0, minX - margin), y: max(0, minY - margin),
                         width: min(w, maxX + margin + 1) - max(0, minX - margin),
                         height: min(h, maxY + margin + 1) - max(0, minY - margin))
        return whole.cropping(to: box) ?? whole
    }
}

// MARK: - The grid of cat models

/// One cat model in 猫咪管理's grid: her picture on a soft mat, her name, breed, and 正在使用 when
/// the room shows her. A built-in cat opens her character card; an imported one is chosen at once.
struct CatPackTile: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let pack: CatPack
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        Button(action: action) {
            Group {
                if typeSize.isAccessibilitySize {
                    // One column at accessibility sizes: a small picture beside the words, so she
                    // keeps her picture and the name keeps the width.
                    HStack(alignment: .center, spacing: 12) {
                        picture(side: 60)
                        VStack(alignment: .leading, spacing: 6) {
                            words.multilineTextAlignment(.leading)
                            if selected { inUseBadge }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(spacing: 8) {
                        picture(side: 88)
                        words.multilineTextAlignment(.center)
                        if selected { inUseBadge }
                    }
                }
            }
            .foregroundStyle(RoomPaper.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                shape.fill(RoomPaper.sheet)
                    .overlay { shape.strokeBorder(selected ? RoomPaper.moss : RoomPaper.edge, lineWidth: selected ? 2 : 1) }
            }
            .contentShape(shape)
        }
        .buttonStyle(.roomToken)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(pack.displayTitle), \(note)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? Text("正在使用", tableName: "CatProfiles") : Text(verbatim: ""))
        .accessibilityHint(pack.profile != nil
                           ? Text("打开\(Wording.inline(pack.displayTitle))的角色卡。", tableName: "CatProfiles")
                           : (selected ? Text(verbatim: "") : Text("让房间里的猫咪换成这个模型。")))
    }

    private var note: String {
        if let profile = pack.profile { return profile.breed }
        let origin = pack.origin == .builtIn ? String(localized: "内置") : String(localized: "导入")
        return [origin, pack.manifest.license].compactMap { $0 }.joined(separator: " · ")
    }

    private var words: some View {
        VStack(alignment: typeSize.isAccessibilitySize ? .leading : .center, spacing: 2) {
            Text(verbatim: pack.displayTitle)
                .font(.system(.headline, design: .rounded, weight: .bold))
            Text(verbatim: note)
                .font(.footnote)
                .foregroundStyle(RoomPaper.note)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var inUseBadge: some View {
        Label { Text("正在使用", tableName: "CatProfiles") } icon: { Image(systemName: "checkmark") }
            .font(.system(.caption, design: .rounded, weight: .bold))
            .foregroundStyle(RoomPaper.sealInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(RoomPaper.moss))
    }

    private func picture(side: CGFloat) -> some View {
        ZStack {
            Circle().fill(RoomPaper.flyleaf)
            if let image = previewImage(of: pack) {
                Image(decorative: image, scale: 3)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(side * 0.14)
            }
        }
        .frame(width: side, height: side)
        .overlay(alignment: .bottomTrailing) {
            CatPawMark().fill(RoomPaper.clay.opacity(0.55)).frame(width: side * 0.18, height: side * 0.18).offset(x: 2, y: 2)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The character card

/// A built-in cat's character card, shown before she is chosen: her silhouette, the way to her 3D
/// model, her names, gender, breed, the line about who sponsored her, a few tags and a fun fact.
/// Only 就选它 chooses her; closing the card changes nothing.
struct CatProfileCardView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The chips' corners: half a one-line chip's height or more, so a one-line chip stays a
    /// capsule at every size (the corner is clamped to half the height); a chip whose words wrap
    /// (English at the largest sizes) becomes a rounded rectangle instead of a circle.
    @ScaledMetric(relativeTo: .subheadline) private var chipCorner: CGFloat = 17
    let pack: CatPack
    let profile: CatProfile
    let inUse: Bool
    let choose: () -> Void
    let close: () -> Void
    @State private var inspecting = false

    private var chinese: Bool { AppLanguage.isChinese }
    private var name: String { profile.name(chinese: chinese) }

    var body: some View {
        RoomFolio(title: String(localized: "角色卡", table: "CatProfiles"), image: "TopCats",
                  close: RoomFolioClose(label: Text("关闭"), id: "close-cat-card", action: close)) {
            SponsorCreditBanner(target: .cat(id: profile.id))
            portrait
            identity
            RoomFolioCard {
                // With only the nickname, this line is the thanks; a public name replaces it.
                if !namedAbove { bioRow }
                traitsRow
                if let funFact = profile.funFact { funFactRow(funFact) }
            }
            chooseButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cat-card")
        .sheet(isPresented: $inspecting) {
            NavigationStack {
                CatInspectView(pack: pack)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { inspecting = false }
                                .accessibilityIdentifier("close-cat-inspect")
                        }
                    }
            }
        }
    }

    /// Whether the banner at the top names her sponsor.
    private var namedAbove: Bool { !Credits.shown.bannerSponsors(for: .cat(id: profile.id)).isEmpty }

    private var bioRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "heart.fill").foregroundStyle(RoomPaper.clay).accessibilityHidden(true)
            Text(verbatim: profile.bio(chinese: chinese))
        }
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cat-card-bio")
    }

    /// The silhouette on a soft mat with a few paws, and the 3D model under it.
    private var portrait: some View {
        let mat = RoundedRectangle(cornerRadius: 28, style: .continuous)
        let side: CGFloat = typeSize.isAccessibilitySize ? 110 : 150
        return VStack(spacing: 12) {
            ZStack {
                if let image = previewImage(of: pack) {
                    // The preview's alpha, filled with one soft colour: a silhouette, no new art. The
                    // frame follows her shape, so the little shadow sits under her feet.
                    let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
                    let size = aspect >= 1 ? CGSize(width: side, height: side / aspect)
                                           : CGSize(width: side * aspect, height: side)
                    Image(decorative: image, scale: 3)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .foregroundStyle(RoomPaper.ink.opacity(0.58))
                        .frame(width: size.width, height: size.height)
                        .background(alignment: .bottom) {
                            Ellipse()
                                .fill(RoomPaper.ink.opacity(0.12))
                                .frame(width: size.width * 0.72, height: 14)
                                .offset(y: 6)
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background {
                mat.fill(RoomPaper.flyleaf)
                    .overlay { mat.strokeBorder(RoomPaper.edge, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
            }
            .overlay(alignment: .topLeading) { paw(20, turn: -18).padding(16) }
            .overlay(alignment: .topTrailing) { paw(14, turn: 14).padding(.top, 30).padding(.trailing, 22) }
            .overlay(alignment: .bottomTrailing) { paw(22, turn: 20).padding(16) }
            .overlay(alignment: .bottomLeading) { paw(13, turn: -10).padding(.bottom, 26).padding(.leading, 26) }
            .accessibilityHidden(true)
            if pack.inspectURL != nil {
                Button { inspecting = true } label: {
                    Label { Text("查看 3D 模型").lineLimit(3).multilineTextAlignment(.center) } icon: { Image(systemName: "cube.transparent") }
                }
                .buttonStyle(.roomFolio(.secondary))
                .accessibilityHint(Text("打开\(Wording.inline(name))的 3D 模型，可以转动和缩放。"))
                .accessibilityIdentifier("cat-card-inspect")
            }
        }
        .padding(.horizontal, 16)
    }

    private func paw(_ size: CGFloat, turn: Double) -> some View {
        CatPawMark().fill(RoomPaper.clay.opacity(0.35)).frame(width: size, height: size).rotationEffect(.degrees(turn))
    }

    /// Her names, then gender and breed as two little tags.
    private var identity: some View {
        VStack(spacing: 10) {
            VStack(spacing: 2) {
                Text(verbatim: name)
                    .font(RoomTitleFont.font(for: name, size: 30, relativeTo: .title1, maximum: 44, typeSize: typeSize))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("cat-card-name")
                if let other = profile.otherName(chinese: chinese) {
                    Text(verbatim: other)
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(RoomPaper.note)
                        .accessibilityIdentifier("cat-card-other-name")
                }
            }
            .multilineTextAlignment(.center)
            RoomChipFlow(spacing: 8) {
                if let gender = profile.genderText {
                    fact(Text("性别", tableName: "CatProfiles"), gender, id: "cat-card-gender")
                }
                fact(Text("品种", tableName: "CatProfiles"), profile.breed, id: "cat-card-breed")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
    }

    private func fact(_ title: Text, _ value: String, id: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: chipCorner, style: .continuous)
        // Side by side; when that is wider than the card, the title above the value.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                title.foregroundStyle(RoomPaper.note)
                Text(verbatim: value).fontWeight(.semibold)
            }
            VStack(alignment: .leading, spacing: 2) {
                title.foregroundStyle(RoomPaper.note)
                Text(verbatim: value).fontWeight(.semibold)
            }
        }
        .font(.system(.subheadline, design: .rounded))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(shape.fill(RoomPaper.paper).overlay { shape.strokeBorder(RoomPaper.edge, lineWidth: 1) })
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    /// 小趣事: one line, only for a cat that has one.
    private func funFactRow(_ funFact: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("小趣事", tableName: "CatProfiles")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(RoomPaper.note)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: funFact)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cat-card-fun-fact")
    }

    /// Temperament and favourite things: short tags, each with a tiny paw.
    private var traitsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("性格和小爱好", tableName: "CatProfiles")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(RoomPaper.note)
                .accessibilityAddTraits(.isHeader)
            RoomChipFlow(spacing: 8) {
                ForEach(profile.traits, id: \.self) { trait in
                    HStack(spacing: 5) {
                        CatPawMark().fill(RoomPaper.moss).frame(width: 12, height: 12).accessibilityHidden(true)
                        Text(verbatim: trait)
                    }
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: chipCorner, style: .continuous).fill(RoomPaper.moss.opacity(0.14)))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cat-card-traits")
    }

    @ViewBuilder private var chooseButton: some View {
        Group {
            if inUse {
                Label { Text("正在使用", tableName: "CatProfiles") } icon: { Image(systemName: "checkmark") }
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(RoomPaper.moss)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("cat-card-in-use")
            } else {
                Button(action: choose) {
                    Label { Text("就选它", tableName: "CatProfiles").lineLimit(2).foregroundStyle(RoomPaper.sealInk) } icon: { CatPawMark().fill(RoomPaper.sealInk).frame(width: 16, height: 16) }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.roomFolio(.primary))
                .accessibilityHint(Text("让房间里的猫咪换成\(Wording.object(name))。", tableName: "CatProfiles"))
                .accessibilityIdentifier("choose-cat-pack")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}
