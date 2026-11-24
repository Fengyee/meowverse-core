import MeowverseCore
import SwiftUI
import UIKit

// The words and the steps of the chapters this build tells (docs/onboarding/PRODUCT_PLAN.md
// §3.3, the lines in docs/onboarding/LINES.md): the opening, chapters 1 to 5, chapters 6, 7 and
// 12 here, and chapters 8 to 11 and 13 to 15 in TourScriptT5.swift. The text lives in
// Tour.xcstrings, keyed by chapter and step so a reworded line keeps its key.

/// What a step's window opens over.
enum TourTarget: Equatable {
    /// A step with no window: a card or a line on its own.
    case none
    /// A control marked with `tourAnchor(id)`.
    case control(String)
    case scene(TourSceneTarget)
}

/// Bella's head in a bubble (VISUAL §8.4) and her full figure on a card.
enum TourArt: String {
    case h1, h2, h3, h4, h5, h6
    case b1, b2, b3, b4, b5, b6, b7, b8

    /// The head in a bubble. H2 looks down: only right for a bubble above its control, so a
    /// bubble below shows H1 instead (TourNoteArt.swift).
    func head(bubbleAbove: Bool) -> Image? {
        switch self {
        case .h1: BellaHead.default.image
        case .h2: (bubbleAbove ? BellaHead.lookDown : .default).image
        case .h3: BellaHead.waiting.image
        case .h4: BellaHead.happy.image
        case .h5: BellaHead.curious.image
        case .h6: BellaHead.notYet.image
        default: nil
        }
    }

    /// The whole figure on a card or the naming page.
    var body: Image? {
        switch self {
        case .b1: BellaBody.greeting.image
        case .b2: BellaBody.nameTag.image
        case .b3: BellaBody.photos.image
        case .b4: BellaBody.box.image
        case .b5: BellaBody.album.image
        case .b6: BellaBody.play.image
        case .b7: BellaBody.company.image
        case .b8: BellaBody.stretch.image
        default: nil
        }
    }
}

struct TourStep: Equatable {
    enum Kind: Equatable {
        case bubble
        /// The naming page: a sheet in the main window, where the keyboard can come up.
        case naming
        /// Chapter 12's three pages about the Home Screen, Control Center and the app icon
        /// (12.5 to 12.7): a paged sheet over whatever is on top. Closing it ends the chapter.
        case companyPages
    }

    /// The step's number in PRODUCT_PLAN, for the probe and the logs.
    var id: String
    var kind: Kind = .bubble
    var target: TourTarget = .none
    /// The user may use the real control inside the window. The step is done once they touched it
    /// and `doneWhen` then turned up (PROTOTYPE_T1 §3, correction 2).
    var does = false
    var doneWhen: TourTarget?
    var art: TourArt = .h2
    var line = ""
    /// Page mode has no window: this says where the control is.
    var place: String?
    /// Page mode says this alone, in place of `line` and `place`: a line that points at the window
    /// ("right here, tap to take a look", 9.0 and 10.0) has nothing to point at on a page, where
    /// the only button is 【下一步】 (T5.15, QA_EN).
    var pageLine: String?
    /// The bubble stays at one edge and only the window moves (a target that walks about).
    var docked = false
    /// 【下一步】 here ends the chapter (4.1: "or Next, which goes on to chapter 5").
    var nextEnds = false
    /// A "do" step whose control opens the app's own flow (the photo picker, the furniture page):
    /// touching it hands the chapter over, as picking a toy does in chapter 4 (rule 6).
    var handsOff = false
    /// 【下一步】 goes to this step rather than the next one (12.1: "or Next, straight to the pages").
    var nextGoesTo: String?
    /// The closing word on a last step is 「知道了」 rather than 「好」 (6.3, 7.3).
    var gotIt = false
    /// A gesture step (7.1, 7.2): a touch that starts in the window goes to the room, and the
    /// rest of that touch follows it wherever it moves (VISUAL §17.6, lead ruling of 2026-11-21).
    var gestures = false
    /// A step with no window that may show over the page on top (12.3 with Live Activities off and
    /// 12.4 are said on the company page), not only over the bare room.
    var anyLayer = false
    /// A control inside a "look" step's window that still takes a tap: 9.1 lets 「未放进家具」
    /// through, so the user can go on to 9.3 (LINES.md T5.14).
    var passes: String?
    /// The page under the window scrolls its target into view before the window opens (11.2, 13.1,
    /// 14.2; Q-05): the view that holds the target reads `TourCoordinator.scrollTarget`.
    var scrolls = false
    /// The bubble goes above the window when it fits there, so it does not cover what is under the
    /// row (13.1: the row's own footer about the camera; VISUAL §18.2 item 6).
    var bubbleAbove = false
    /// With `bubbleAbove`: when the bubble does not fit above (iPhone SE, large text), the window
    /// grows to take in this probe too (the footer), and the bubble goes below it.
    var alsoCovers: String?
}

enum TourScript {
    struct Context {
        /// The lead cat's name as it is now.
        var catName: String
        /// Whether the room's nameplate shows the cat's name (the first room, not renamed).
        var plateShowsName: Bool
        /// The built-in cat model is in use: the cat looks like Bella.
        var looksLikeBella: Bool
        var reduceMotion: Bool
        /// The current room has no furniture: chapter 3 points at the empty-room card's button.
        var roomIsEmpty = true
        /// The empty room's card is folded at this text size (`RoomScreen.foldsEmptyHint`).
        var emptyCardFolded = false
        /// The room's music is on: 5.2, "music starts switched off", is left out.
        var musicOn = false
        var isPad = false
        /// Chapter 6's piece: one in this room that holds at least one photo.
        var memoryPiece: String?
        /// Chapter 7's piece: one in this room that is not locked.
        var movablePiece: String?
        /// Live Activities are allowed for the app: 12.3 can start one.
        var liveActivitiesOn = true
        /// Company is already running: 12.3 has nothing to start.
        var companyRunning = false
        /// The device has a Dynamic Island (12.4 or 12.4 无岛).
        var hasIsland = false
        /// Chapter 12 began on the company page the user opened (from 12.3).
        var onCompanyPage = false
        /// The page the chapter began on (chapters 9, 10, 11, 13), or nil in the room: a chapter
        /// opened from Settings begins in the room and first leads the user to its page.
        var onPage: TourSurface?
        /// 「按建议放进家具」 is on the photo library now (9.3).
        var hasSuggestEntry = false
        /// The photo library shows a photo under its filter: 9.2 has one to point at.
        var libraryHasPhoto = true
        /// What 10.2 points at.
        var pieceMenu: PieceMenu = .none
        /// The Play panel offers one piece the cat can get onto, and lists its actions (11.1 .single).
        var oneCatPiece = false
        /// A reminder is switched on (14.1 .someOn, when replayed).
        var anyReminderOn = false
    }

    /// The opening's chapters 2 and 3 go straight on to the next one: their last step still says
    /// 【下一步】. Opened by hand, the closing word (LINES.md §1).
    static func goesOn(_ chapter: TourChapterID) -> Bool { chapter == .bringPhoto || chapter == .furnishFirst }

    /// Chapters with a card when they come on their own: chapter 1 in the opening, and every
    /// chapter told when it is needed (LINES.md T4.1: 「每次先出卡」).
    static func hasCard(_ chapter: TourChapterID) -> Bool {
        chapter == .welcome || TourCatalog.current[chapter]?.kind == .onDemand
    }

    /// Chapter 12's card line. An iPad has no Lock Screen widget in this chapter (LINES.md T4.8,
    /// plan A), so its line speaks of the Home Screen.
    static func companyCardLine(catName: String, isPad: Bool) -> String {
        let name = TourText.name(catName)
        if isPad {
            return name.map {
                String(localized: "tour.company.card.line.pad", defaultValue: "不开 App 的时候，也能在主屏幕上看到\(Wording.object($0))。", table: "Tour",
                       comment: "Chapter 12 card on iPad, one sentence. The argument is the cat's name.")
            } ?? String(localized: "tour.company.card.line.pad.long", defaultValue: "不开 App 的时候，也能在主屏幕上看到猫咪。", table: "Tour",
                        comment: "Chapter 12 card on iPad, when the cat's name is too long to repeat.")
        }
        return name.map {
            String(localized: "tour.company.card.line", defaultValue: "不开 App 的时候，\(Wording.subject($0))也能去锁屏上陪你。", table: "Tour",
                   comment: "Chapter 12 card, one sentence. The argument is the cat's name.")
        } ?? String(localized: "tour.company.card.line.long", defaultValue: "不开 App 的时候，猫咪也能去锁屏上陪你。", table: "Tour",
                    comment: "Chapter 12 card, when the cat's name is too long to repeat.")
    }

    static func card(_ chapter: TourChapterID, catName: String,
                     isPad: Bool = UIDevice.current.userInterfaceIdiom == .pad) -> (title: String, line: String, art: TourArt)? {
        switch chapter {
        case .welcome:
            (String(localized: "tour.welcome.card.title", defaultValue: "你好，我是 Bella", table: "Tour",
                    comment: "Chapter 1 card title. Bella is the guide's name."),
             String(localized: "tour.welcome.card.line", defaultValue: "我是这里的向导，带你认识一下这间小房间。", table: "Tour",
                    comment: "Chapter 1 card, one sentence."),
             .b1)
        case .play:
            (String(localized: "tour.play.card.title", defaultValue: "陪\(TourText.nameOrIt(catName))玩一会儿", table: "Tour",
                    comment: "Chapter 4 card title; only shown when replayed. The argument is the cat's name, or “it”."),
             String(localized: "tour.play.card.line", defaultValue: "玩具和小零食，都在“互动”里。", table: "Tour",
                    comment: "Chapter 4 card. “Play” is the label of the 互动 button."),
             .b6)
        case .bringPhoto:
            (String(localized: "tour.bringPhoto.card.title", defaultValue: "带一张照片回家", table: "Tour",
                    comment: "Chapter 2 card title; only shown when replayed from Settings."),
             String(localized: "tour.bringPhoto.card.line", defaultValue: "从一张照片开始，给这间房间添一件家具。", table: "Tour",
                    comment: "Chapter 2 card, one sentence."),
             .b3)
        case .furnishFirst:
            (String(localized: "tour.furnishFirst.card.title", defaultValue: "没有照片，也能先布置", table: "Tour",
                    comment: "Chapter 3 card title; only shown when replayed from Settings."),
             String(localized: "tour.furnishFirst.card.line", defaultValue: "先摆一件家具，照片以后再补。", table: "Tour",
                    comment: "Chapter 3 card, one sentence."),
             .b4)
        case .topRow:
            (String(localized: "tour.topRow.card.title", defaultValue: "房间上面这一排", table: "Tour",
                    comment: "Chapter 5 card title; only shown when replayed from Settings. The row of buttons along the top of the room."),
             String(localized: "tour.topRow.card.line", defaultValue: "房间的样子、声音和猫咪，都从这一排改。", table: "Tour",
                    comment: "Chapter 5 card, one sentence."),
             .b1)
        case .memories:
            (String(localized: "tour.memories.card.title", defaultValue: "点家具，看回忆", table: "Tour",
                    comment: "Chapter 6 card title."),
             String(localized: "tour.memories.card.line", defaultValue: "房间里有了带照片的家具。看看它记着什么？", table: "Tour",
                    comment: "Chapter 6 card, one sentence. Comes up once a piece in the room holds photos. Does not say a photo brought the piece."),
             .b5)
        case .moveAndLook:
            (String(localized: "tour.moveAndLook.card.title", defaultValue: "搬家具，看房间", table: "Tour",
                    comment: "Chapter 7 card title."),
             String(localized: "tour.moveAndLook.card.line", defaultValue: "家具能挪，房间能放大。两个手势就够了。", table: "Tour",
                    comment: "Chapter 7 card, one sentence: press and hold to move a piece, pinch to zoom."),
             .b4)
        case .company:
            (String(localized: "tour.company.card.title", defaultValue: "让\(TourText.nameOrIt(catName))陪着你", table: "Tour",
                    comment: "Chapter 12 card title. The argument is the cat's name, or “it” when the name is too long."),
             companyCardLine(catName: catName, isPad: isPad),
             .b7)
        default: t5Card(chapter, catName: catName)
        }
    }

    /// The chapter's steps. Chapter 1 asks for the name first: `named` is what the user chose on
    /// the naming page (nil until then, and when they did not name the cat).
    static func steps(_ chapter: TourChapterID, context: Context, naming: NamingResult?) -> [TourStep] {
        switch chapter {
        case .welcome: welcome(context, naming: naming)
        case .bringPhoto: bringPhoto(context)
        case .furnishFirst: furnishFirst(context)
        case .play: play(context)
        case .topRow: topRow(context)
        case .memories: memories(context)
        case .moveAndLook: moveAndLook(context)
        case .company: company(context)
        case .photoBatch: photoBatch(context)
        case .photoLibrary: photoLibrary(context)
        case .furnitureLibrary: furnitureLibrary(context)
        case .sendCat: sendCat(context)
        case .tabletop: tabletop(context)
        case .reminders: reminders(context)
        case .backup: backup(context)
        default: []
        }
    }

    /// Chapters 6 and 7 point into the room: their first step, and 7.3, start from the room as it
    /// opens, not zoomed in (TECH_DESIGN §3.4).
    static func resetsZoom(before step: TourStep, in chapter: TourChapterID) -> Bool {
        switch chapter {
        case .memories: step.id == "6.1"
        case .moveAndLook: step.id == "7.1" || step.id == "7.3"
        default: false
        }
    }

    /// The card shown instead of the steps when a chapter is opened by hand and there is nothing
    /// to show it with (PRODUCT_PLAN §3.4 item 2): the chapter's title and picture, and one line.
    /// `roomHasFurniture`: chapter 7 with pieces in the room, all of them locked.
    static func placeholder(_ chapter: TourChapterID, catName: String,
                            roomHasFurniture: Bool) -> (title: String, line: String, art: TourArt)? {
        guard let card = card(chapter, catName: catName) else { return nil }
        switch chapter {
        case .memories: return (card.title, TourText.needsPhotos, card.art)
        case .moveAndLook: return (card.title, roomHasFurniture ? TourText.needsUnlocked : TourText.needsFurniture, card.art)
        default: return t5Placeholder(chapter).map { (card.title, $0, card.art) }
        }
    }

    enum NamingResult: Equatable {
        case named(String)
        case notNamed
    }

    private static func welcome(_ context: Context, naming: NamingResult?) -> [TourStep] {
        let cat: TourTarget = .scene(context.reduceMotion ? .floor : .cat)
        var steps = [
            TourStep(id: "1.1", target: cat, art: .h2,
                     line: String(localized: "tour.welcome.1", defaultValue: "这间房间是你家猫咪的，它就住在这儿。", table: "Tour",
                                  comment: "Chapter 1, step 1. The window is on the user's cat in the room."),
                     place: TourText.placeCat, docked: true),
            TourStep(id: "1.2", kind: .naming, art: .b2),
        ]
        switch naming {
        case .named(let name) where context.plateShowsName:
            steps.append(TourStep(id: "1.3a", target: .control("room-switcher"), art: .h4,
                                  line: String(localized: "tour.welcome.3a", defaultValue: "\(name)，好名字。上面的门牌也换好了。", table: "Tour",
                                               comment: "Chapter 1, after the user named the cat. The window is on the room's nameplate at the top, which now shows the name. Never shortened, however long the name."),
                                  place: TourText.placePlate))
        case .named(let name):
            // The plate does not follow this cat (the room has its own name): no window, and no
            // word about the plate.
            steps.append(TourStep(id: "1.3a", art: .h4,
                                  line: String(localized: "tour.welcome.3a.noPlate", defaultValue: "\(name)，好名字。以后提醒和锁屏上，都用这个名字。", table: "Tour",
                                               comment: "Chapter 1, after the user named the cat, when the room's nameplate does not show the cat's name (the room has a name of its own). Reminder titles and the Lock Screen companion do show the cat's name.")))
        case .notNamed, nil:
            let line = TourText.name(context.catName).map {
                String(localized: "tour.welcome.3b", defaultValue: "那就先叫\(Wording.object($0))。想好了，随时在“猫咪”里改。", table: "Tour",
                       comment: "Chapter 1, when the user did not name the cat. The argument is the cat's current name. English says “here”: the window is on the top-bar button 猫咪, which shows no label at large text sizes.")
            } ?? String(localized: "tour.welcome.3b.long", defaultValue: "那就先用现在的名字。想好了，随时在“猫咪”里改。", table: "Tour",
                        comment: "Chapter 1, when the user did not name the cat and its name is too long to repeat.")
            steps.append(TourStep(id: "1.3b", target: .control("open-cat-manager"), art: .h2, line: line, place: TourText.placeCats))
        }
        if context.looksLikeBella {
            steps.append(TourStep(id: "1.4", target: cat, art: .h5,
                                  line: String(localized: "tour.welcome.4", defaultValue: "它现在的样子是照着我做的，所以我们有点像。", table: "Tour",
                                               comment: "Chapter 1, last step: the user's cat uses the built-in model, which was made after Bella."),
                                  place: TourText.placeCat, docked: true))
        }
        return steps
    }

    private static func bringPhoto(_ context: Context) -> [TourStep] {
        let button: TourTarget = .control("add-photo")
        let guess = context.isPad
            ? String(localized: "tour.bringPhoto.2.pad", defaultValue: "这台 iPad 会猜照片里是什么家具，猜错了你可以改，也能自己选。", table: "Tour",
                     comment: "Chapter 2, step 2, on iPad. The window is on Add photos. The device, not Bella, guesses the furniture.")
            : String(localized: "tour.bringPhoto.2", defaultValue: "这台 iPhone 会猜照片里是什么家具，猜错了你可以改，也能自己选。", table: "Tour",
                     comment: "Chapter 2, step 2. The window is on Add photos. The device, not Bella, guesses the furniture.")
        let pick = TourText.name(context.catName).map {
            String(localized: "tour.bringPhoto.3", defaultValue: "点这里，挑一张有\(Wording.inline($0))也有家具的照片吧。", table: "Tour",
                   comment: "Chapter 2, step 3. The window is on Add photos; tapping it hands over to the photo picker. The argument is the cat's name.")
        } ?? String(localized: "tour.bringPhoto.3.long", defaultValue: "点这里，挑一张有猫咪也有家具的照片吧。", table: "Tour",
                    comment: "Chapter 2, step 3, when the cat's name is too long to repeat.")
        return [
            TourStep(id: "2.1", target: button, art: .h2,
                     line: String(localized: "tour.bringPhoto.1", defaultValue: "照片从这里带回家，只有你自己看得到。", table: "Tour",
                                  comment: "Chapter 2, step 1. The window is on Add photos. Owner-approved privacy line, one wording for every device and backup setting."),
                     place: TourText.placeAddPhoto),
            TourStep(id: "2.2", target: button, art: .h2, line: guess, place: TourText.placeAddPhoto),
            TourStep(id: "2.3", target: button, does: true, art: .h3, line: pick, place: TourText.placeAddPhoto, handsOff: true),
        ]
    }

    private static func furnishFirst(_ context: Context) -> [TourStep] {
        // The furniture library instead when the empty-room card has no button to point at: the
        // room has furniture (opened by hand), or the card is folded (xxxL and up).
        let (target, place) = context.roomIsEmpty && !context.emptyCardFolded
            ? ("place-furniture-first", TourText.placePlaceFirst) : ("furniture-list", TourText.placeFurnitureList)
        return [
            TourStep(id: "3.1", target: .control(target), does: true, art: .h3,
                     line: String(localized: "tour.furnishFirst.1", defaultValue: "没有合适的照片？先摆一件家具也行，会标着“还没有照片”。", table: "Tour",
                                  comment: "Chapter 3. The window is on Place furniture first on the empty-room card. “No photos yet” is the app's label for furniture without photos."),
                     place: place, handsOff: true),
        ]
    }

    private static func topRow(_ context: Context) -> [TourStep] {
        var steps = [
            TourStep(id: "5.1", target: .control("room-top-bar"), art: .h2,
                     line: String(localized: "tour.topRow.1", defaultValue: "这一排能换主题、开音乐、给猫咪改名，右上角还能做明信片。", table: "Tour",
                                  comment: "Chapter 5, step 1. The window is on the whole row of buttons along the top of the room. Only the free parts are named."),
                     place: TourText.placeTopRow),
        ]
        if !context.musicOn {
            steps.append(TourStep(id: "5.2", target: .control("open-room-sound"), art: .h5,
                                  line: String(localized: "tour.topRow.2", defaultValue: "音乐默认是关着的。想听的时候，来这儿打开。", table: "Tour",
                                               comment: "Chapter 5, step 2. The window is on the Sound button. Left out when the music is already on."),
                                  place: TourText.placeSound))
        }
        steps.append(TourStep(id: "5.3", target: .control("open-settings"), art: .h1,
                              line: String(localized: "tour.topRow.3", defaultValue: "先说到这儿，别的等你用到再讲。想重听，来设置里的“使用导览”。", table: "Tour",
                                           comment: "Chapter 5, last step of the opening. The window is on the Settings gear. “使用导览” (Tour) is the Settings row that replays the tour."),
                              place: TourText.placeSettings))
        return steps
    }

    private static func play(_ context: Context) -> [TourStep] {
        let name = TourText.name(context.catName)
        let first = name.map {
            String(localized: "tour.play.1", defaultValue: "想逗逗\(Wording.inline($0))吗？点这里，有玩具，也有小零食。", table: "Tour",
                   comment: "Chapter 4, step 1. The window is on the Play button (互动). The argument is the cat's name.")
        } ?? String(localized: "tour.play.1.long", defaultValue: "想逗逗它吗？点这里，有玩具，也有小零食。", table: "Tour",
                    comment: "Chapter 4, step 1, when the cat's name is too long to repeat.")
        let second = name.map {
            String(localized: "tour.play.2", defaultValue: "挑一个玩具，再到地板空地上点一下、拖一拖，\(Wording.subject($0))会追过去。", table: "Tour",
                   comment: "Chapter 4, step 2. The window is on “Choose a toy” in the Play panel. The argument is the cat's name.")
        } ?? String(localized: "tour.play.2.long", defaultValue: "挑一个玩具，再到地板空地上点一下、拖一拖，猫咪会追过去。", table: "Tour",
                    comment: "Chapter 4, step 2, when the cat's name is too long to repeat.")
        return [
            TourStep(id: "4.1", target: .control("choose-interaction"), does: true, doneWhen: .control("choose-toy"),
                     art: .h3, line: first, place: TourText.placePlay, nextEnds: true),
            TourStep(id: "4.2", target: .control("choose-toy"), does: true, art: .h3, line: second, place: TourText.placeToy),
        ]
    }
}

// MARK: - Chapters 6, 7 and 12 (T4; lines in LINES.md T4.1 to T4.5, rulings T4.8)

extension TourScript {
    /// Chapter 6. 6.1's window is on a piece of this room that holds photos, one not locked if
    /// there is one; touching it opens the piece, and 6.2 and 6.3 are said on its page. 【下一步】
    /// on 6.1 ends the chapter.
    fileprivate static func memories(_ context: Context) -> [TourStep] {
        guard let piece = context.memoryPiece else { return [] }
        return [
            TourStep(id: "6.1", target: .scene(.furniture(piece)), does: true, doneWhen: .control("add-source-photo"), art: .h3,
                     line: String(localized: "tour.memories.1", defaultValue: "点一下，就能翻看这件家具的照片。", table: "Tour",
                                  comment: "Chapter 6, step 1. The window is on a piece in the room that holds at least one photo. Tapping it opens the piece."),
                     place: TourText.placePiece, nextEnds: true),
            TourStep(id: "6.2", target: .control("add-source-photo"), art: .h2,
                     line: String(localized: "tour.memories.2", defaultValue: "同一件家具可以放很多张照片，从这儿再添。", table: "Tour",
                                  comment: "Chapter 6, step 2, on the piece's page. The window is on “Add another photo” (an icon at the top left)."),
                     place: TourText.placeAddAnother),
            TourStep(id: "6.3", target: .control("furniture-more"), art: .h2,
                     line: String(localized: "tour.memories.3", defaultValue: "这个按钮里，还能在房间里定位、锁定，或收进收纳箱。", table: "Tour",
                                  comment: "Chapter 6, last step, on the piece's page. The window is on the More menu (an ⋯ icon at the top left). English names its items: Show in Room, Lock, Put in storage."),
                     place: TourText.placeMore, gotIt: true),
        ]
    }

    /// Chapter 7. 7.1 lets through touches that start in its window (the piece), 7.2 those in
    /// the stage window round the whole room (VISUAL §17.6). Once the user really lifts the piece
    /// the tour steps aside until it is placed (`TourCoordinator`), then goes on with 7.2. 7.2 is
    /// done when the room stays zoomed in for about a second after the fingers leave; the room is
    /// set back before 7.3.
    fileprivate static func moveAndLook(_ context: Context) -> [TourStep] {
        guard let piece = context.movablePiece else { return [] }
        return [
            TourStep(id: "7.1", target: .scene(.furniture(piece)), does: true, art: .h3,
                     line: String(localized: "tour.moveAndLook.1", defaultValue: "想挪这件家具？按住它一会儿，再拖着走。", table: "Tour",
                                  comment: "Chapter 7, step 1. The window is on a piece that is not locked. English says touch and hold, as Apple does."),
                     place: TourText.placeLift, gestures: true),
            TourStep(id: "7.2", target: .scene(.stage), does: true, art: .h3,
                     line: String(localized: "tour.moveAndLook.2", defaultValue: "两根手指捏一捏能放大，放大后一根手指拖着看。", table: "Tour",
                                  comment: "Chapter 7, step 2. The window is round the whole room; pinch to zoom, then drag with one finger."),
                     place: TourText.placeRoom, gestures: true),
            TourStep(id: "7.3", target: .scene(.storage), art: .h5,
                     line: String(localized: "tour.moveAndLook.3", defaultValue: "房间右边这个箱子是收纳箱，收起来的家具和照片都在里面。", table: "Tour",
                                  comment: "Chapter 7, last step. The window is on the storage chest drawn at the right of the room."),
                     place: TourText.placeStorage, gotIt: true),
        ]
    }

    /// Chapter 12. From the room: 互动, then 陪我一会儿, then 开始陪伴; from the company page the user
    /// opened: from 12.3. 【下一步】 before company has started goes straight to the pages. On
    /// iPad only the pages about the Home Screen widget and the icon (T4.8, plan A).
    fileprivate static func company(_ context: Context) -> [TourStep] {
        let pages = TourStep(id: "12.5", kind: .companyPages, art: .h1)
        if context.isPad { return [pages] }
        let name = TourText.name(context.catName)
        var steps: [TourStep] = []
        if !context.onCompanyPage {
            steps += [
                TourStep(id: "12.1", target: .control("choose-interaction"), does: true, doneWhen: .control("choose-pocket-cat"), art: .h3,
                         line: String(localized: "tour.company.1", defaultValue: "先点“互动”，再点里面的“陪我一会儿”。", table: "Tour",
                                      comment: "Chapter 12, step 1. The window is on the Play button (互动). “Keep me company” (陪我一会儿) is the row in the Play panel, sentence case as it shows there."),
                         place: TourText.placePlay, nextGoesTo: "12.5"),
                TourStep(id: "12.2", target: .control("choose-pocket-cat"), does: true, doneWhen: .control("pocket-page"), art: .h3,
                         line: String(localized: "tour.company.2", defaultValue: "就是这一行，点进去。", table: "Tour",
                                      comment: "Chapter 12, step 2. The window is on the “Keep me company” row in the Play panel. “it” is the row."),
                         place: TourText.placeCompany, nextGoesTo: "12.5"),
            ]
        }
        guard context.liveActivitiesOn else {
            steps.append(TourStep(id: "12.3off", art: .h6,
                                  line: String(localized: "tour.company.3.off", defaultValue: "实时活动现在关着。这一页下面写了怎么打开。", table: "Tour",
                                               comment: "Chapter 12, on the company page, when Live Activities are switched off for the app in Settings. The page says how to switch them on."),
                                  anyLayer: true))
            steps.append(pages)
            return steps
        }
        if !context.companyRunning {
            let start = name.map {
                String(localized: "tour.company.3", defaultValue: "点“开始陪伴”，\(Wording.subject($0))会变成像素猫，待在锁屏上。", table: "Tour",
                       comment: "Chapter 12, step 3. The window is on “Start company” (开始陪伴) on the company page. The argument is the cat's name.")
            } ?? String(localized: "tour.company.3.long", defaultValue: "点“开始陪伴”，猫咪会变成像素猫，待在锁屏上。", table: "Tour",
                        comment: "Chapter 12, step 3, when the cat's name is too long to repeat or empty.")
            steps.append(TourStep(id: "12.3", target: .control("pocket-start"), does: true, doneWhen: .control("pocket-end"), art: .h3,
                                  line: start, place: TourText.placeStartCompany, nextGoesTo: "12.5"))
        }
        steps.append(TourStep(id: "12.4", art: .h4, line: lockTheScreen(name: name, island: context.hasIsland), anyLayer: true))
        steps.append(pages)
        return steps
    }

    /// 12.4 and 12.4 无岛.
    private static func lockTheScreen(name: String?, island: Bool) -> String {
        switch (name, island) {
        case (let name?, true):
            String(localized: "tour.company.4", defaultValue: "现在锁上屏幕看看。灵动岛上也有\(Wording.object(name))。", table: "Tour",
                   comment: "Chapter 12, after company started, on an iPhone with the Dynamic Island. No window. The argument is the cat's name.")
        case (nil, true):
            String(localized: "tour.company.4.long", defaultValue: "现在锁上屏幕看看。灵动岛上也有它。", table: "Tour",
                   comment: "Chapter 12, after company started, on an iPhone with the Dynamic Island, when the cat's name is too long to repeat or empty.")
        case (let name?, false):
            String(localized: "tour.company.4.noIsland", defaultValue: "现在锁上屏幕看看，\(Wording.subject(name))就在那儿。", table: "Tour",
                   comment: "Chapter 12, after company started, on an iPhone without the Dynamic Island. No window. The argument is the cat's name.")
        case (nil, false):
            String(localized: "tour.company.4.noIsland.long", defaultValue: "现在锁上屏幕看看，它就在那儿。", table: "Tour",
                   comment: "Chapter 12, after company started, on an iPhone without the Dynamic Island, when the cat's name is too long to repeat or empty.")
        }
    }

    /// The pages after chapter 12's steps, in order. iPad: only the Home Screen and the icon.
    static func companyPages(isPad: Bool) -> [TourCompanyPage] {
        isPad ? [.homeScreen, .iconShortcuts] : TourCompanyPage.allCases
    }

    /// One page's words (VISUAL §17.2): a title, Bella's line (bound by the length rules), the
    /// steps, numbered, in groups (12.5: the Home Screen, then the Lock Screen), and notes only
    /// some devices get. Not in Bella's voice. 12.7's list is the Home Screen items' own titles
    /// (`TourCompanyConditions.shortcuts`), drawn by the page.
    struct CompanyPage: Equatable {
        var title: String
        var line: String
        var art: TourArt
        var steps: [[String]]
        var notes: [String] = []
        /// A small heading over each group of steps, when the page has them (12.5 always; 12.6 when
        /// it has the Action button's group too, LINES.md T5.13).
        var titles: [String] = []
    }

    static func companyPage(_ page: TourCompanyPage, conditions: TourCompanyConditions,
                            liveActivitiesOn: Bool, isPad: Bool) -> CompanyPage {
        switch page {
        case .homeScreen:
            let how = String(localized: "tour.company.home.how", defaultValue: "在主屏幕上按住背景，直到 App 开始抖动。点屏幕顶部的“编辑”，再点“添加小组件”。搜索“喵空间”，点“像素猫”，选好大小，点“添加小组件”，最后点“完成”。", table: "Tour",
                             comment: "Chapter 12, page 1, how to add the Pixel Cat widget to the Home Screen. Each sentence is shown as a numbered step. Wording follows Apple's iPhone User Guide.")
            let lock = String(localized: "tour.company.home.lock", defaultValue: "按住锁屏，点“自定义”（iOS 18 上接着点“锁定屏幕”）。点“添加小组件”，选“像素猫”。最后点“完成”。", table: "Tour",
                              comment: "Chapter 12, page 1, how to add the widget to the Lock Screen, under the heading Lock Screen. Each sentence is a numbered step. Add Widgets is plural on the Lock Screen.")
            // iPad: the Home Screen only (LINES.md T4.8, plan A).
            return CompanyPage(title: String(localized: "tour.company.home.title", defaultValue: "放到主屏幕", table: "Tour", comment: "Chapter 12, page 1 title."),
                               line: String(localized: "tour.company.home.line", defaultValue: "想每次解锁都看到它？把“像素猫”放到主屏幕。", table: "Tour",
                                            comment: "Chapter 12, page 1, Bella's line. “Pixel Cat” is the widget's name."),
                               art: .h1, steps: isPad ? [sentences(how)] : [sentences(how), sentences(lock)],
                               titles: [String(localized: TourCompanyDiagram.homeScreenCaption), String(localized: TourCompanyDiagram.lockScreenCaption)])
        case .controlCenter:
            let how = String(localized: "tour.company.controls.how", defaultValue: "打开控制中心：配备面容 ID 的 iPhone 从屏幕右上角向下轻扫，配备主屏幕按钮的 iPhone 从屏幕底部向上轻扫。点左上方的“添加”按钮（＋），再点屏幕底部的“添加控制”。在控制资源库里找到喵空间，有三个：陪我一会儿、拍照添加、从相册添加。", table: "Tour",
                             comment: "Chapter 12, page 2, how to add the controls. Each sentence is shown as a numbered step. The three names are the controls' names in the controls gallery: Keep Me Company, Take Photo, Add from Photos.")
            var notes: [String] = []
            var steps = [sentences(how)]
            var titles: [String] = []
            if conditions.hasActionButton {
                // Its own group under its own heading, and Control Center then has one too (T5.13).
                steps.append(sentences(String(localized: "tour.company.controls.actionButton", defaultValue: "打开“设置”，点“操作按钮”。轻扫到“控制”，点下方的按钮（iOS 18 上是“选取控制”）。选“陪我一会儿”。", table: "Tour",
                                              comment: "Chapter 12, page 2, only on an iPhone with the Action button, under the heading Action button. Each sentence is a numbered step.")))
                titles = [String(localized: "tour.company.controls.group", defaultValue: "控制中心", table: "Tour",
                                 comment: "Chapter 12, page 2: heading of the Control Center steps, shown only when the Action button's group follows."),
                          String(localized: "tour.company.controls.actionButton.title", defaultValue: "操作按钮", table: "Tour",
                                 comment: "Chapter 12, page 2: heading of the Action button steps.")]
            }
            if !liveActivitiesOn {
                notes.append(String(localized: "tour.company.controls.needsLive", defaultValue: "“陪我一会儿”要用到实时活动。实时活动关着时，先到“设置”›“App”›“喵空间”里打开“实时活动”。", table: "Tour",
                                    comment: "Chapter 12, page 2, only while Live Activities are off for the app."))
            }
            return CompanyPage(title: String(localized: "tour.company.controls.title", defaultValue: "放进控制中心", table: "Tour", comment: "Chapter 12, page 2 title."),
                               line: String(localized: "tour.company.controls.line", defaultValue: "不用打开 App，也能把它叫出来。", table: "Tour",
                                            comment: "Chapter 12, page 2, Bella's line. “它” is the cat."),
                               art: .h5, steps: steps, notes: notes, titles: titles)
        case .iconShortcuts:
            return CompanyPage(title: String(localized: "tour.company.icon.title", defaultValue: "按住图标", table: "Tour", comment: "Chapter 12, page 3 title."),
                               line: String(localized: "tour.company.icon.line", defaultValue: "按住主屏幕上的喵空间图标，有几条近路。", table: "Tour",
                                            comment: "Chapter 12, page 3, Bella's line. English says touch and hold, as Apple does."),
                               art: .h1,
                               steps: [[String(localized: "tour.company.icon.how", defaultValue: "在主屏幕上按住喵空间的图标，弹出的“快速操作”菜单里有：", table: "Tour",
                                               comment: "Chapter 12, page 3; the list of the Home Screen quick actions follows.")]])
        }
    }

    /// A paragraph cut after each full stop, the stop kept: one numbered step each.
    static func sentences(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if character == "\u{3002}" || (character == "." && (next == nil || next == " ")) {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { parts.append(rest) }
        return parts
    }
}

/// The tour's fixed words.
enum TourText {
    /// Bella signs every bubble; a name, not translated.
    static let speaker = "Bella"

    static var next: String { String(localized: "tour.next", defaultValue: "下一步", table: "Tour", comment: "Tour bubble button.") }
    static var back: String { String(localized: "tour.back", defaultValue: "上一步", table: "Tour", comment: "Tour page mode button.") }
    static var skip: String { String(localized: "tour.skip", defaultValue: "跳过这一段", table: "Tour", comment: "Tour button: leaves this chapter.") }
    static var skipAll: String { String(localized: "tour.skipAll", defaultValue: "全部跳过", table: "Tour", comment: "Tour button: leaves every chapter.") }
    static var start: String { String(localized: "tour.start", defaultValue: "开始", table: "Tour", comment: "Tour chapter card button.") }
    static var done: String { String(localized: "tour.done", defaultValue: "好", table: "Tour", comment: "Closing word on a chapter's last step.") }
    static var gotIt: String {
        String(localized: "tour.gotIt", defaultValue: "知道了", table: "Tour", comment: "Closing word on the last step of chapters 6 and 7, and on the placeholder card.")
    }
    static var skippedAll: String {
        String(localized: "tour.skippedAll", defaultValue: "好，不打扰你了。想看的时候，在设置里的“使用导览”。", table: "Tour",
               comment: "One line at the top of the screen after Skip all. “使用导览” (Tour) is the Settings row that replays the tour.")
    }

    static var namingTitle: String { String(localized: "tour.naming.title", defaultValue: "它叫什么名字？", table: "Tour", comment: "Naming page title.") }
    static var namingLine: String {
        String(localized: "tour.naming.line", defaultValue: "给它起个名字吧，以后随时能改。", table: "Tour", comment: "Naming page, under the title.")
    }
    static var namingLater: String { String(localized: "tour.naming.later", defaultValue: "先不起名", table: "Tour", comment: "Naming page: leave the name as it is.") }
    static var namingUse: String { String(localized: "tour.naming.use", defaultValue: "就叫这个", table: "Tour", comment: "Naming page: save the typed name.") }
    static var namingField: String { String(localized: "tour.naming.field", defaultValue: "猫咪的名字", table: "Tour", comment: "VoiceOver label of the naming page's text field.") }

    // Page mode has no window: Bella says where the thing is (PRODUCT_PLAN §3.3, 「分页文字版里的“在哪里”」).
    // Button names are the labels the app shows: 猫咪 is “Cats”, 互动 is “Play”.
    static var placeCat: String {
        String(localized: "tour.place.cat", defaultValue: "它在房间里。屏幕底下那行字，写着它正在做什么。", table: "Tour",
               comment: "Tour page mode, where the step points: the cat in the room. The line at the bottom of the room says what the cat is doing.")
    }
    static var placePlate: String {
        String(localized: "tour.place.plate", defaultValue: "门牌在屏幕顶上，写着房间的名字。", table: "Tour",
               comment: "Tour page mode, where the step points: the room's nameplate.")
    }
    static var placeCats: String {
        String(localized: "tour.place.cats", defaultValue: "“猫咪”按钮在屏幕上方那一排里。", table: "Tour",
               comment: "Tour page mode, where the step points. “Cats” is the label of the top-bar button 猫咪.")
    }
    static var placePlay: String {
        String(localized: "tour.place.play", defaultValue: "“互动”按钮在屏幕下方。", table: "Tour",
               comment: "Tour page mode, where the step points. “Play” is the label of the 互动 button.")
    }
    static var placeAddPhoto: String {
        String(localized: "tour.place.addPhoto", defaultValue: "“添加照片”按钮在屏幕下方。", table: "Tour",
               comment: "Tour page mode, where the step points. “Add photos” is the button's label.")
    }
    static var placePlaceFirst: String {
        String(localized: "tour.place.placeFirst", defaultValue: "“先摆家具”在写着“房间还是空的”的那张卡片上。", table: "Tour",
               comment: "Tour page mode, where the step points. “Place furniture first” is the button on the card titled “The room is still empty”.")
    }
    static var placeFurnitureList: String {
        String(localized: "tour.place.furnitureList", defaultValue: "“家具库”在屏幕下方。", table: "Tour",
               comment: "Tour page mode, where the step points. “Furniture” is the label of the 家具库 bookplate.")
    }
    static var placeTopRow: String {
        String(localized: "tour.place.topRow", defaultValue: "这一排按钮在屏幕顶上。", table: "Tour",
               comment: "Tour page mode, where the step points: the row of buttons along the top of the room.")
    }
    static var placeSound: String {
        String(localized: "tour.place.sound", defaultValue: "“音乐音效”按钮在屏幕上方那一排里。", table: "Tour",
               comment: "Tour page mode, where the step points. “Sound” is the button's label.")
    }
    static var placeSettings: String {
        String(localized: "tour.place.settings", defaultValue: "设置是屏幕顶上那个齿轮按钮。", table: "Tour",
               comment: "Tour page mode, where the step points: Settings, the gear at the top of the screen.")
    }
    static var placeToy: String {
        String(localized: "tour.place.toy", defaultValue: "“选玩具”在互动面板里，先点“互动”就能看到。", table: "Tour",
               comment: "Tour page mode, where the step points. “Choose a toy” is the row's label, “Play” the button's.")
    }

    // Chapters 6, 7 and 12 (LINES.md T4.1 to T4.3).
    static var placePiece: String {
        String(localized: "tour.place.piece", defaultValue: "房间里的家具，点一下就能打开。", table: "Tour",
               comment: "Tour page mode, where the step points: any piece of furniture in the room. VoiceOver opens it with its default action.")
    }
    static var placeAddAnother: String {
        String(localized: "tour.place.addAnother", defaultValue: "“再添一张照片”在这件家具那一页的顶上。", table: "Tour",
               comment: "Tour page mode, where the step points. “Add another photo” is the button at the top of a piece's page.")
    }
    static var placeMore: String {
        String(localized: "tour.place.more", defaultValue: "“更多”按钮在这件家具那一页的顶上。", table: "Tour",
               comment: "Tour page mode, where the step points. “More” is the menu button at the top of a piece's page; VoiceOver reads its name.")
    }
    static var placeLift: String {
        String(localized: "tour.place.lift", defaultValue: "房间里的家具都能按住挪动。用旁白时，选中一件，用“编辑摆放”。", table: "Tour",
               comment: "Tour page mode, chapter 7 step 1. “Edit placement” is the VoiceOver action on a piece.")
    }
    static var placeRoom: String {
        String(localized: "tour.place.room", defaultValue: "房间占着屏幕中间的一大块，在那里捏合和拖动。", table: "Tour",
               comment: "Tour page mode, chapter 7 step 2: the room itself, for pinching and dragging.")
    }
    static var placeStorage: String {
        String(localized: "tour.place.storage", defaultValue: "收纳箱是画在房间右边的那只小箱子。", table: "Tour",
               comment: "Tour page mode, where the step points: the storage chest drawn in the room.")
    }
    static var placeCompany: String {
        String(localized: "tour.place.company", defaultValue: "“陪我一会儿”在互动面板里，先点“互动”就能看到。", table: "Tour",
               comment: "Tour page mode, where the step points. “Keep me company” is the row's label, “Play” the button's.")
    }
    static var placeStartCompany: String {
        String(localized: "tour.place.startCompany", defaultValue: "“开始陪伴”在这一页上，表情选择的下面。", table: "Tour",
               comment: "Tour page mode, where the step points. “Start company” is the button on the company page, below the Expression picker.")
    }

    /// The line on the card of a chapter opened from Settings with nothing to show it with
    /// (LINES.md T4.4).
    static var needsFurniture: String {
        String(localized: "tour.needsFurniture.line", defaultValue: "这一段要有家具才能演示。等第一件搬进来，我再带你看。", table: "Tour",
               comment: "Card for chapter 7 opened from Settings while there is no furniture.")
    }
    static var needsPhotos: String {
        String(localized: "tour.needsPhotos.line", defaultValue: "这一段要有带照片的家具才能演示。等哪件有了照片，我再带你看。", table: "Tour",
               comment: "Card for chapter 6 opened from Settings while no piece holds a photo.")
    }
    /// The row's state in Settings' 「使用导览」 list for the same chapters.
    static var statusNeedsFurniture: String {
        String(localized: "tour.status.needsFurniture", defaultValue: "等有了家具再看", table: "Tour",
               comment: "Settings, Tour list: chapter 7's state while there is no furniture.")
    }
    /// Chapter 7 while every piece in the room is locked (lead's ruling on QA_T4 suggestion 2).
    static var needsUnlocked: String {
        String(localized: "tour.needsUnlocked.line", defaultValue: "这一段要有一件没锁定的家具。等哪件解锁了，我再带你看。", table: "Tour",
               comment: "Card for chapter 7 opened from Settings while every piece in the room is locked.")
    }
    static var statusNeedsUnlocked: String {
        String(localized: "tour.status.needsUnlocked", defaultValue: "等有家具解锁再看", table: "Tour",
               comment: "Settings, Tour list: chapter 7's state while every piece in the room is locked.")
    }
    static var statusNeedsPhotos: String {
        String(localized: "tour.status.needsPhotos", defaultValue: "等家具有了照片再看", table: "Tour",
               comment: "Settings, Tour list: chapter 6's state while no piece holds a photo.")
    }

    /// The name to say in a line, or nil when it is too long to repeat: more than 8 characters
    /// in Chinese, more than 12 in English (PRODUCT_PLAN §3.1 rule 19).
    /// An empty name is not said either (LINES.md T4.8).
    static func name(_ raw: String) -> String? {
        let limit = AppLanguage.isChinese ? 8 : 12
        return raw.isEmpty || raw.count > limit ? nil : raw
    }

    /// For a card title: the name, or "it".
    static func nameOrIt(_ raw: String) -> String {
        name(raw).map(Wording.inline) ?? String(localized: "tour.it", defaultValue: "它", table: "Tour", comment: "Stands for the cat in a title when the name is too long.")
    }
}
