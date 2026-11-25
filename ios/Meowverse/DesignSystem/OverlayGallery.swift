#if DEBUG
import MeowverseCore
import SwiftUI

/// A DEBUG-only page that lays out the round-6 overlay components the way art/ui/OVERLAY_SPEC.md
/// places them, so they can be screenshotted before the room is wired. Launch with
/// `-MeowverseOverlayGallery <page>`: `band` (default), `sound`, `rooms`, `theme`, `titles` or `cat-card` (a built-in cat's character card); the
/// round-8 suggested-filing pages (`filing-…`) are listed in `FilingGallery`.
/// `-MeowverseGalleryPlaying` shows the play-session state.
/// The arrangement here is a reference for the room's top bar, not the shipped one.
struct OverlayGallery: View {
    enum Page: String {
        case band, sound, rooms, theme, titles
        case filingScreen = "filing-screen", filingRound = "filing-round", filingConfirm = "filing-confirm"
        case filingCover = "filing-cover", filingRoundIntro = "filing-round-intro"
        case filingRoundEnd = "filing-round-end", filingMark = "filing-mark"
        /// Round 11: the companion's watch layout (`PocketCatWatchGallery`).
        case watch
        /// Round 12: Talk to Bella, the head in its six states and the hint (`BellaVoiceGallery`).
        case bella
        /// The about page's sponsor and thanks sections with made-up names (`CreditsGallery`).
        case credits
        /// The launch page's paw ring (`PawRing`): the page itself, then the ring held at
        /// four steps of its walk.
        case opening, paws
        /// The character card with a sample fun fact (`CatProfileGallery`).
        case catCard = "cat-card"
        /// The tour's chapter 12 pictures (`TourCompanyDiagramGallery`, VISUAL 17.8 item 1).
        case diagramsPages = "diagrams-pages", diagramsConditions = "diagrams-conditions", diagramsIPad = "diagrams-ipad"
    }

    static var page: Page? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-MeowverseOverlayGallery") else { return nil }
        return args.indices.contains(index + 1) ? Page(rawValue: args[index + 1]) ?? .band : .band
    }

    let page: Page
    private let playing = ProcessInfo.processInfo.arguments.contains("-MeowverseGalleryPlaying")

    var body: some View {
        switch page {
        case .titles: TitleSamples()
        case .watch: PocketCatWatchGallery()
        case .bella: BellaVoiceGallery()
        case .credits: CreditsGallery()
        case .opening: RoomOpeningView()
        case .paws: PawSteps()
        case .catCard: CatProfileGallery()
        case .diagramsPages: TourCompanyDiagramGallery(set: .pages)
        case .diagramsConditions: TourCompanyDiagramGallery(set: .conditions)
        case .diagramsIPad: TourCompanyDiagramGallery(set: .ipad)
        case .filingScreen, .filingRound, .filingConfirm, .filingCover, .filingRoundIntro, .filingRoundEnd, .filingMark:
            FilingGallery(page: page)
        default: Band(page: page, playing: playing)
        }
    }
}

/// The gallery's own copy, so the catalog stays with the room screen that ships it.
private func copy(_ zh: String, _ en: String) -> String {
    Locale.current.language.languageCode?.identifier == "zh" ? zh : en
}

private struct Band: View {
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.colorScheme) private var scheme
    let page: OverlayGallery.Page
    let playing: Bool
    @State private var soundOpen = false
    @State private var roomsOpen = false
    @AppStorage(RoomSoundKeys.music) private var music = false
    @AppStorage(RoomSoundKeys.effects) private var effects = true

    private var roomName: String {
        String(localized: "\(Wording.subject("Bella"))的房间")
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                (scheme == .dark ? Color(red: 0.17, green: 0.15, blue: 0.13) : Color(red: 0.953, green: 0.918, blue: 0.859))
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    if page != .theme {
                        if widthClass == .regular {
                            regularRow(width: proxy.size.width)
                        } else {
                            compactRows(width: proxy.size.width)
                        }
                    }
                    Spacer()
                    if page == .theme {
                        themeTray
                    } else {
                        bottomBand
                    }
                }
            }
        }
        .task {
            soundOpen = page == .sound
            roomsOpen = page == .rooms
        }
    }

    // MARK: - Top band, iPhone: two rows

    private func compactRows(width: CGFloat) -> some View {
        VStack(spacing: 8) {
            ZStack {
                HStack {
                    settings
                    Spacer()
                    share
                }
                title.frame(maxWidth: width - 2 * (12 + 44 + 10))
            }
            .padding(.horizontal, 12)
            HStack(alignment: .top, spacing: 4) {
                theme
                sound
                RoomTopDot().padding(.horizontal, -4) // 16 pt including the row's 4 pt spacing
                rooms
                cats
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Top band, iPad: one row, title centred on the screen

    private func regularRow(width: CGFloat) -> some View {
        ZStack(alignment: .top) {
            HStack(alignment: .top, spacing: 0) {
                settings.padding(.top, 3)
                theme.padding(.leading, 12)
                sound.padding(.leading, 6)
                Spacer()
                rooms
                cats.padding(.leading, 6)
                share.padding(.top, 3).padding(.leading, 12)
            }
            .padding(.horizontal, 20)
            // The groups are about 182 pt wide each at the default size: the title gets the rest.
            title.frame(maxWidth: min(360, 2 * (width / 2 - 20 - 182) - 24))
        }
        .padding(.top, 10)
    }

    // MARK: - Tokens

    private var settings: some View {
        Button {} label: { RoomRoundToken(glyph: .symbol("gearshape")) }
            .buttonStyle(.roomToken)
            .roomTokenAccessibility(label: Text("设置"), id: "open-settings", largeContent: Text("设置"), symbol: "gearshape")
    }

    private var share: some View {
        Button {} label: { RoomRoundToken(glyph: .art("TopShare")) }
            .buttonStyle(.roomToken)
            .roomTokenAccessibility(label: Text("分享房间"), id: "open-room-share", largeContent: Text("分享房间"),
                                    image: "TopShare")
    }

    private var title: some View {
        Menu {
            Button(roomName) {}
        } label: {
            RoomTitlePlate(title: roomName)
        }
        .menuStyle(.button)
        .buttonStyle(.roomToken)
        .disabled(playing)
        .accessibilityLabel(Text(verbatim: roomName))
        .accessibilityHint(Text(verbatim: copy("切换房间，或新建房间", "Switch rooms or make a new one"))) // not-localized: debug gallery, copy owned by the room screen
        .accessibilityIdentifier("room-switcher")
    }

    private var theme: some View {
        let label = copy("主题", "Theme") // not-localized: debug gallery, copy owned by the room screen
        let hint = copy("换墙纸、地板和灯光", "Change the wallpaper, floor and lighting") // not-localized: debug gallery, copy owned by the room screen
        return Button {} label: { RoomLabelledToken(title: label, image: "TopTheme") }
            .buttonStyle(.roomToken)
            .disabled(playing)
            .roomTokenAccessibility(label: Text(verbatim: label), hint: Text(verbatim: hint), id: "open-room-appearance",
                                    largeContent: Text(verbatim: label), image: "TopTheme")
    }

    private var sound: some View {
        let label = copy("音乐音效", "Sound") // not-localized: debug gallery, copy owned by the room screen
        let name = copy("音乐音效", "Music & sound") // not-localized: debug gallery, copy owned by the room screen
        let hint = copy("背景轻音乐和猫咪动作音效", "Background music and cat sound effects") // not-localized: debug gallery, copy owned by the room screen
        return Button { soundOpen = true } label: { RoomLabelledToken(title: label, image: "TopSound") }
            .buttonStyle(.roomToken)
            .roomTokenAccessibility(label: Text(verbatim: name), hint: Text(verbatim: hint),
                                    inputLabels: [Text(verbatim: name), Text(verbatim: label)], id: "open-room-sound",
                                    largeContent: Text(verbatim: name), image: "TopSound")
            .popover(isPresented: $soundOpen) {
                RoomFolio(title: name, image: "TopSound", illustration: "MemoryCompanion",
                          close: closeButton("close-room-sound") { soundOpen = false }) {
                    RoomFolioCard {
                        RoomFolioToggleRow(title: Text("背景轻音乐"),
                                           note: Text(verbatim: copy("房间里轻轻放一段八音盒。", "A soft music box plays in the room.")), // not-localized: debug gallery, copy owned by the room screen
                                           isOn: $music, id: "room-music")
                        RoomFolioToggleRow(title: Text("猫咪动作音效"),
                                           note: Text(verbatim: copy("吃东西、喝水、玩耍时的小声音。", "Small sounds when the cat eats, drinks or plays.")), // not-localized: debug gallery, copy owned by the room screen
                                           isOn: $effects, id: "room-sound-effects")
                    }
                }
                .frame(width: widthClass == .regular ? 360 : nil)
            }
    }

    private var rooms: some View {
        let label = copy("房间", "Rooms") // not-localized: debug gallery, copy owned by the room screen
        let name = copy("房间管理", "Manage rooms") // not-localized: debug gallery, copy owned by the room screen
        let hint = copy("改名、删除房间", "Rename or delete rooms") // not-localized: debug gallery, copy owned by the room screen
        return Button { roomsOpen = true } label: { RoomLabelledToken(title: label, image: "TopRooms") }
            .buttonStyle(.roomToken)
            .disabled(playing)
            .roomTokenAccessibility(label: Text(verbatim: name),
                                    hint: Text(verbatim: hint), inputLabels: [Text(verbatim: name), Text(verbatim: label)],
                                    id: "open-room-manager", largeContent: Text(verbatim: name), image: "TopRooms")
            .popover(isPresented: $roomsOpen) {
                RoomFolio(title: name, image: "TopRooms", detents: [.medium, .large],
                          close: closeButton("close-room-manager") { roomsOpen = false }) {
                    RoomFolioCard(footer: Text("房间里最多摆 \(String(GridRules.maxItems)) 件家具。")) {
                        RoomFolioRow(title: Text(verbatim: roomName)) {
                            Image(systemName: "checkmark").foregroundStyle(RoomPaper.moss).accessibilityHidden(true)
                        }
                    }
                }
                .frame(width: widthClass == .regular ? 360 : nil)
            }
    }

    private var cats: some View {
        let label = copy("猫咪", "Cats") // not-localized: debug gallery, copy owned by the room screen
        let name = copy("猫咪管理", "Manage cats") // not-localized: debug gallery, copy owned by the room screen
        let hint = copy("改名、换猫咪模型、移除猫咪", "Rename cats, change the cat model or remove cats") // not-localized: debug gallery, copy owned by the room screen
        return Button {} label: { RoomLabelledToken(title: label, image: "TopCats") }
            .buttonStyle(.roomToken)
            .disabled(playing)
            .roomTokenAccessibility(label: Text(verbatim: name),
                                    hint: Text(verbatim: hint), inputLabels: [Text(verbatim: name), Text(verbatim: label)],
                                    id: "open-cat-manager", largeContent: Text(verbatim: name), image: "TopCats")
    }

    private func closeButton(_ id: String, action: @escaping () -> Void) -> RoomFolioClose {
        RoomFolioClose(label: Text(verbatim: copy("关闭", "Close")), id: id, action: action) // not-localized: debug gallery, copy owned by the room screen
    }

    // MARK: - Bottom band (existing) and the 主题 tray

    private var bottomBand: some View {
        HStack(alignment: .bottom) {
            RoomLibraryControls(photos: {}, furniture: {})
            Spacer(minLength: 8)
            RoomActionControls(hasCat: true, canAdd: true, interact: {}, addPhoto: {})
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @State private var season = RoomTheme.mintConservatory
    @State private var plainWalls = false

    private var themeTray: some View {
        RoomFolio(title: copy("主题", "Theme"), image: "TopTheme", compact: true) { // not-localized: debug gallery, copy owned by the room screen
            RoomChipFlow {
                ForEach(RoomTheme.allCases, id: \.self) { item in
                    RoomPaperChip(title: Text(verbatim: item.title), selected: item == season,
                                  swatch: [Color(uiColor: UIColor(hex: item.art.wall)),
                                           Color(uiColor: UIColor(hex: item.art.floor))]) { season = item }
                }
            }
            .padding(.horizontal, 16)
            RoomFolioCard {
                RoomFolioToggleRow(title: Text("素色墙面"), isOn: $plainWalls)
            }
            HStack(spacing: 12) {
                Button("取消") {}.buttonStyle(.roomFolio(.secondary))
                Button("保存") {}.buttonStyle(.roomFolio(.primary))
            }
        }
        .clipShape(.rect(topLeadingRadius: 24, topTrailingRadius: 24))
        .shadow(color: .black.opacity(0.12), radius: 6, y: -2)
    }
}

// MARK: - Title face samples

private struct TitleSamples: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    private let samples = [
        "Bella 的房间", // not-localized: title face sample (cute face)
        "Bella’s room",
        "小橘子和大黄的阳光房", // not-localized: title face sample (long, cute face)
        "Momo 的房間", // not-localized: title face sample, 間 is outside KuaiLe so the whole title falls back
        "玥玥的小屋", // not-localized: title face sample, 玥 is outside KuaiLe so the whole title falls back
        "琮琮的小屋", // not-localized: title face sample, 琮 is in GB2312 so KuaiLe draws it
        "一二三四五六七八九十一二三四五六七八九十", // not-localized: 20-character name truncation sample
        "Mochi & Tofu’s sunny attic",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(samples, id: \.self) { name in
                    HStack(spacing: 10) {
                        RoomTitlePlate(title: name).frame(maxWidth: 243, alignment: .leading)
                        Text(verbatim: RoomTitleFont.face(for: name) == .cute ? "C" : "B")
                            .font(.caption.monospaced()).foregroundStyle(RoomPaper.ink.opacity(0.6))
                    }
                }
                RoomTitlePlate(title: samples[0]).disabled(true)
                HStack(spacing: 12) {
                    RoomRoundToken(glyph: .symbol("gearshape"))
                    RoomLabelledToken(title: "Rooms", image: "TopRooms")
                    RoomLabelledToken(title: "Cats", image: "TopCats").disabled(true)
                    RoomRoundToken(glyph: .art("TopShare")).environment(\.roomPaperPressed, true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoomPaper.leaf.ignoresSafeArea())
    }
}

/// `-MeowverseOverlayGallery cat-card`: a built-in cat's character card as it ships, Bella's or the
/// one `-MeowverseGalleryCat <id>` names, for reviewing the tags and the 小趣事 at every text size.
private struct CatProfileGallery: View {
    @State private var shown = true
    private let pack: CatPack? = {
        let arguments = ProcessInfo.processInfo.arguments
        let id = arguments.firstIndex(of: "-MeowverseGalleryCat").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "bella"
        return Bundle.main.resourceURL.flatMap { try? CatPack.builtIn(id: id, resourceDirectory: $0) }
    }()

    var body: some View {
        RoomPaper.paper.ignoresSafeArea()
            .sheet(isPresented: $shown) {
                if let pack, let profile = pack.profile {
                    CatProfileCardView(pack: pack, profile: profile, inUse: false, choose: {}, close: {})
                        .interactiveDismissDisabled()
                } else {
                    Text(verbatim: "The cat's pack is missing")
                }
            }
    }
}
#endif

#if DEBUG
/// The paw ring at 4, 10 and 16 steps (closed) and fading after it, around the house emblem.
private struct PawSteps: View {
    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow { step(4); step(10) }
            GridRow { step(16); step(18) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .memoryPage(.home)
    }

    private func step(_ steps: Double) -> some View {
        ZStack {
            PawRing(frozenSteps: steps)
            MemoryEmblem(.home).frame(width: 118, height: 84)
        }
        .scaleEffect(0.9)
        .frame(width: 190, height: 200)
    }
}
#endif
