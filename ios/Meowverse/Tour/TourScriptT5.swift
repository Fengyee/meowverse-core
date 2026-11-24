import MeowverseCore
import SwiftUI

// Chapters 8 to 11 and 13 to 15 (T5): the words are docs/onboarding/LINES.md T5.1 to T5.8, the
// conditions T5.10, the lead's rulings T5.14. Chapters 9, 10, 11 and 13 begin on their own page
// (the photo library, the furniture library, the Play panel); 8, 14 and 15 in the room.

extension TourChapterID {
    /// The 「都讲完啦」 card. Not a chapter: no catalog has it, and the machine never runs it.
    static let allDone = TourChapterID("all-done")
}

extension TourScript {
    /// What chapter 10's second step can point at (LINES.md T5.10).
    enum PieceMenu: Equatable {
        /// The furniture library is a grid of covers: there is no 「⋯」, so no 10.2 (T5.14).
        case none
        /// The first piece in the room.
        case room
        /// Only pieces in the storage box are listed: their menu has no 「在房间里定位」.
        case stored
    }

    // MARK: Cards

    static func t5Card(_ chapter: TourChapterID, catName: String) -> (title: String, line: String, art: TourArt)? {
        let name = TourText.name(catName)
        switch chapter {
        case .photoBatch:
            return (String(localized: "tour.photoBatch.card.title", defaultValue: "一次带回很多照片", table: "Tour",
                           comment: "Chapter 8 card title."),
                    String(localized: "tour.photoBatch.card.line", defaultValue: "这些照片都存好了，只是还没放进家具。", table: "Tour",
                           comment: "Chapter 8 card, one sentence: the photos on the “to sort” bar are saved but in no piece yet."),
                    .b3)
        case .photoLibrary:
            return (String(localized: "tour.photoLibrary.card.title", defaultValue: "照片库", table: "Tour",
                           comment: "Chapter 9 card title."),
                    String(localized: "tour.photoLibrary.card.line", defaultValue: "带回来的每一张照片，都收在这里。", table: "Tour",
                           comment: "Chapter 9 card, one sentence."),
                    .b3)
        case .furnitureLibrary:
            return (String(localized: "tour.furnitureLibrary.card.title", defaultValue: "家具库和收纳箱", table: "Tour",
                           comment: "Chapter 10 card title."),
                    String(localized: "tour.furnitureLibrary.card.line", defaultValue: "摆着的、收起来的家具，都列在这里。", table: "Tour",
                           comment: "Chapter 10 card, one sentence."),
                    .b4)
        case .sendCat:
            let title = String(localized: "tour.sendCat.card.title", defaultValue: "请\(TourText.nameOrIt(catName))去家具上", table: "Tour",
                               comment: "Chapter 11 card title. The argument is the cat's name, or “it” when the name is too long.")
            let line = name.map {
                String(localized: "tour.sendCat.card.line", defaultValue: "家具不只是摆着看，\(Wording.subject($0))可以上去待一会儿。", table: "Tour",
                       comment: "Chapter 11 card, one sentence. The argument is the cat's name.")
            } ?? String(localized: "tour.sendCat.card.line.long", defaultValue: "家具不只是摆着看，猫咪可以上去待一会儿。", table: "Tour",
                        comment: "Chapter 11 card, when the cat's name is too long to repeat.")
            return (title, line, .b6)
        case .tabletop:
            return (String(localized: "tour.tabletop.card.title", defaultValue: "放到桌上看看", table: "Tour",
                           comment: "Chapter 13 card title; the same words as the row in the Play panel."),
                    String(localized: "tour.tabletop.card.line", defaultValue: "这间房间，还能摆到你真的桌子上。", table: "Tour",
                           comment: "Chapter 13 card, one sentence."),
                    .b6)
        case .reminders:
            return (String(localized: "tour.reminders.card.title", defaultValue: "让\(TourText.nameOrIt(catName))每天叫你一声", table: "Tour",
                           comment: "Chapter 14 card title. The argument is the cat's name, or “it” when the name is too long."),
                    remindersCardLine(name: name, hasFurniture: true), .b7)
        case .backup:
            return (String(localized: "tour.backup.card.title", defaultValue: "给这个家留个备份", table: "Tour",
                           comment: "Chapter 15 card title."),
                    String(localized: "tour.backup.card.line", defaultValue: "这个家越来越满了，留一份备份更安心。", table: "Tour",
                           comment: "Chapter 15 card, one sentence. Speaks only of peace of mind, not of keeping anything safe."),
                    .b5)
        case .allDone:
            return (String(localized: "tour.allDone.card.title", defaultValue: "都讲完啦", table: "Tour",
                           comment: "The card shown once, after every chapter was read and none skipped."),
                    name.map {
                        String(localized: "tour.allDone.card.line", defaultValue: "这个家，交给你和\(Wording.inline($0))了。", table: "Tour",
                               comment: "The “that's everything” card. The argument is the cat's name.")
                    } ?? String(localized: "tour.allDone.card.line.long", defaultValue: "这个家，交给你和猫咪了。", table: "Tour",
                                comment: "The “that's everything” card, when the cat's name is too long to repeat."),
                    .b8)
        default:
            return nil
        }
    }

    /// Chapter 14's card line. A home with no furniture yet gets the fallback, which does not speak
    /// of old photos (PRODUCT_PLAN chapter 14, item 6).
    static func remindersCardLine(name: String?, hasFurniture: Bool) -> String {
        switch (name, hasFurniture) {
        case (let name?, true):
            String(localized: "tour.reminders.card.line", defaultValue: "\(Wording.subject(name))可以每天叫你一声，也能提醒你回来看老照片。", table: "Tour",
                   comment: "Chapter 14 card, one sentence. The argument is the cat's name.")
        case (nil, true):
            String(localized: "tour.reminders.card.line.long", defaultValue: "猫咪可以每天叫你一声，也能提醒你回来看老照片。", table: "Tour",
                   comment: "Chapter 14 card, when the cat's name is too long to repeat.")
        case (let name?, false):
            String(localized: "tour.reminders.card.line.fallback", defaultValue: "\(Wording.subject(name))可以每天到点叫你一声。要不要看看？", table: "Tour",
                   comment: "Chapter 14 card for a home with no furniture yet. The argument is the cat's name.")
        case (nil, false):
            String(localized: "tour.reminders.card.line.fallback.long", defaultValue: "猫咪可以每天到点叫你一声。要不要看看？", table: "Tour",
                   comment: "Chapter 14 card for a home with no furniture yet, when the cat's name is too long to repeat.")
        }
    }

    /// The card's line when it is not the chapter's usual one.
    static func cardLine(_ chapter: TourChapterID, catName: String, hasFurniture: Bool) -> String? {
        chapter == .reminders && !hasFurniture ? remindersCardLine(name: TourText.name(catName), hasFurniture: false) : nil
    }

    /// The placeholder card's line for chapters 8 to 11 and 13 (LINES.md T5.8).
    static func t5Placeholder(_ chapter: TourChapterID) -> String? {
        switch chapter {
        case .photoBatch:
            String(localized: "tour.needsUnsorted.line", defaultValue: "这一段要有待整理的照片才能演示。等下次带回一批，我再带你看。", table: "Tour",
                   comment: "Chapter 8 opened from Settings with no photos waiting to be sorted.")
        case .photoLibrary:
            String(localized: "tour.needsPhoto.line", defaultValue: "这一段要有照片才能演示。等第一张带回家，我再带你看。", table: "Tour",
                   comment: "Chapter 9 opened from Settings with no photo in the library.")
        case .furnitureLibrary: TourText.needsFurniture
        case .sendCat:
            String(localized: "tour.needsPerch.line", defaultValue: "这一段要有一件猫咪能上去的家具。等摆好一件，我再带你看。", table: "Tour",
                   comment: "Chapter 11 opened from Settings with no piece the cat can get onto (or no cat in the room).")
        case .tabletop:
            String(localized: "tour.needsCamera.line", defaultValue: "这一段要用相机。相机权限关着的时候，我就先不演示了。", table: "Tour",
                   comment: "Chapter 13 opened from Settings while camera access is off. Gives the reason; does not ask the user to turn it on.")
        default: nil
        }
    }

    /// The row's state in Settings' list while the chapter cannot be shown (LINES.md T5.8).
    static func t5Status(_ chapter: TourChapterID, _ snapshot: TourSnapshot) -> String? {
        switch chapter {
        case .photoBatch where snapshot.unsortedPhotoCount == 0:
            String(localized: "tour.status.needsUnsorted", defaultValue: "等有了待整理的照片再看", table: "Tour",
                   comment: "Settings, Tour list: chapter 8's state while no photo waits to be sorted.")
        case .photoLibrary where snapshot.photoCount == 0:
            String(localized: "tour.status.needsPhoto", defaultValue: "等有了照片再看", table: "Tour",
                   comment: "Settings, Tour list: chapter 9's state while the library has no photo.")
        case .furnitureLibrary where snapshot.furnitureCount == 0: TourText.statusNeedsFurniture
        case .sendCat where !(snapshot.roomHasCat && snapshot.hasPerchableFurniture):
            String(localized: "tour.status.needsPerch", defaultValue: "等有猫能上去的家具再看", table: "Tour",
                   comment: "Settings, Tour list: chapter 11's state while there is no piece the cat can get onto.")
        case .tabletop where snapshot.cameraDenied:
            String(localized: "tour.status.cameraOff", defaultValue: "相机权限已关闭", table: "Tour",
                   comment: "Settings, Tour list: chapter 13's state while camera access is off. The same words as the AR row.")
        default: nil
        }
    }

    // MARK: Steps

    /// A step in the room that leads to the page a chapter is told on, when it is opened by hand
    /// from Settings and so begins in the room (the tour never opens a page itself). Not in
    /// LINES.md: lines for the lead and product to settle.
    private static func leadIn(_ chapter: TourChapterID, context: Context, first: String) -> TourStep? {
        guard context.onPage == nil else { return nil }
        let (id, target, line, place): (String, String, String, String) = switch chapter {
        case .photoLibrary:
            ("9.0", "photo-library",
             String(localized: "tour.photoLibrary.open", defaultValue: "照片库在这里，点开看看。", table: "Tour",
                    comment: "Chapter 9 opened from Settings: the step in the room before the photo library is open. The window is on the Photo library bookplate."),
             TourText.placePhotoLibrary)
        case .furnitureLibrary:
            ("10.0", "furniture-list",
             String(localized: "tour.furnitureLibrary.open", defaultValue: "家具库在这里，点开看看。", table: "Tour",
                    comment: "Chapter 10 opened from Settings: the step in the room before the furniture library is open. The window is on the Furniture bookplate."),
             TourText.placeFurnitureList)
        case .sendCat, .tabletop:
            (chapter == .sendCat ? "11.0" : "13.0", "choose-interaction",
             String(localized: "tour.openPlay", defaultValue: "先点“互动”，在里面讲。", table: "Tour",
                    comment: "Chapters 11 and 13 opened from Settings: the step in the room before the Play panel is open. The window is on Play (互动)."),
             TourText.placePlay)
        default:
            ("", "", "", "")
        }
        guard !id.isEmpty else { return nil }
        var step = TourStep(id: id, target: .control(target), does: true, doneWhen: .control(first), art: .h3, line: line,
                            place: place, nextEnds: true)
        // 9.0 and 10.0 say "right here, tap to take a look": on a page only where it is (T5.15).
        // 11.0 and 13.0 ("tap Play first") still hold on a page, with their place line below.
        if chapter == .photoLibrary || chapter == .furnitureLibrary { step.pageLine = place }
        return step
    }

    /// Chapter 8, in the room: 「整理」 on the bar of photos to sort. Starting to sort hands the
    /// chapter over (`TourCoordinator`); the sorting flow has its own words and no mask (T5.1).
    static func photoBatch(_ context: Context) -> [TourStep] {
        [TourStep(id: "8.1", target: .control("start-sorting"), does: true, art: .h3,
                  line: String(localized: "tour.photoBatch.1", defaultValue: "点“整理”，一张张给它们找位置。不想现在弄，它们会等着。", table: "Tour",
                               comment: "Chapter 8, the only step. The window is on Sort (整理) on the bar that counts photos to sort."),
                  place: String(localized: "tour.place.sort", defaultValue: "“整理”在屏幕下方，写着几张照片待整理的那一条上。", table: "Tour",
                                comment: "Page mode, chapter 8: where Sort is."),
                  gotIt: true)]
    }

    /// Chapter 9, on the photo library. 9.1 lets a tap on 「未放进家具」 through; 9.3 is said only
    /// while 「按建议放进家具」 is on the page (`hasSuggestEntry`), which is only under that filter
    /// (T5.14). The tour does not change the filter itself.
    static func photoLibrary(_ context: Context) -> [TourStep] {
        var steps: [TourStep] = []
        if let lead = leadIn(.photoLibrary, context: context, first: "photo-filters") { steps.append(lead) }
        steps.append(TourStep(id: "9.1", target: .control("photo-filters"), art: .h2,
                              line: String(localized: "tour.photoLibrary.1", defaultValue: "“未放进家具”里，是还没找到位置的照片。", table: "Tour",
                                           comment: "Chapter 9, step 1. The window is on the row of filters at the top of the photo library."),
                              place: String(localized: "tour.place.filters", defaultValue: "“未放进家具”在照片库顶上的那排筛选里。", table: "Tour",
                                            comment: "Page mode, chapter 9: where the Not in furniture filter is."),
                              passes: "filter-unlinked"))
        // 「未放进家具」 tapped in 9.1 may leave the page with no photo: then 9.1 is the last step.
        guard context.libraryHasPhoto else { return steps.map { var step = $0; step.gotIt = true; return step } }
        steps.append(TourStep(id: "9.2", target: .control("library-photo"), art: .h2,
                              line: String(localized: "tour.photoLibrary.2", defaultValue: "按住一张照片，能设封面、收藏、放进家具或分享。", table: "Tour",
                                           comment: "Chapter 9, step 2. The window is on the first photo. The four are items of the photo's long-press menu."),
                              place: String(localized: "tour.place.libraryPhoto", defaultValue: "照片库里的每张照片都能按住。用旁白时，选中一张，上下轻扫就能找到。", table: "Tour",
                                            comment: "Page mode, chapter 9: every photo has the menu; with VoiceOver, swipe up or down for the actions."),
                              gotIt: true))
        if context.hasSuggestEntry {
            let line = context.isPad
                ? String(localized: "tour.photoLibrary.3.pad", defaultValue: "这台 iPad 会找和放好的照片相像的，猜个去处，放不放由你定。", table: "Tour",
                         comment: "Chapter 9, step 3 on iPad. The window is on File as suggested. Never “automatic”: the iPad guesses, the user decides.")
                : String(localized: "tour.photoLibrary.3", defaultValue: "这台 iPhone 会找和放好的照片相像的，猜个去处，放不放由你定。", table: "Tour",
                         comment: "Chapter 9, step 3. The window is on File as suggested. Never “automatic”: the iPhone guesses, the user decides.")
            steps.append(TourStep(id: "9.3", target: .control("rerun-suggestions"), art: .h5, line: line,
                                  place: String(localized: "tour.place.suggest", defaultValue: "“按建议放进家具”在“未放进家具”这一页的照片上方。", table: "Tour",
                                                comment: "Page mode, chapter 9: where File as suggested is."),
                                  gotIt: true))
        }
        return steps
    }

    /// Chapter 10, on the furniture library. 10.2 only in the list, which has the 「⋯」 (T5.14).
    static func furnitureLibrary(_ context: Context) -> [TourStep] {
        var steps: [TourStep] = []
        if let lead = leadIn(.furnitureLibrary, context: context, first: "add-furniture") { steps.append(lead) }
        steps.append(TourStep(id: "10.1", target: .control("add-furniture"), art: .h2,
                              line: String(localized: "tour.furnitureLibrary.1", defaultValue: "不用照片，也能从这儿再添一件家具。", table: "Tour",
                                           comment: "Chapter 10, step 1. The window is on Add furniture at the top of the furniture library."),
                              place: String(localized: "tour.place.addFurniture", defaultValue: "“添加家具”在家具库这一页的最上面。", table: "Tour",
                                            comment: "Page mode, chapter 10: where Add furniture is."),
                              gotIt: true))
        guard context.pieceMenu != .none else { return steps }
        let line = context.pieceMenu == .stored
            ? String(localized: "tour.furnitureLibrary.2.stored", defaultValue: "点“⋯”，能锁定这件家具，或放回房间。", table: "Tour",
                     comment: "Chapter 10, step 2, when only pieces in the storage box are listed. The window is on a piece's ⋯ (More actions).")
            : String(localized: "tour.furnitureLibrary.2", defaultValue: "点“⋯”，能在房间里定位这件家具、锁定，或收进收纳箱。", table: "Tour",
                     comment: "Chapter 10, step 2. The window is on the ⋯ (More actions) of the first piece in the room. Use the menu's own item names.")
        steps.append(TourStep(id: "10.2", target: .control("piece-menu"), art: .h2, line: line,
                              place: String(localized: "tour.place.pieceMenu", defaultValue: "每件家具那一行的右边，有一个“更多操作”按钮，就是“⋯”。", table: "Tour",
                                            comment: "Page mode, chapter 10: where a piece's More actions button is."),
                              gotIt: true))
        return steps
    }

    /// Chapter 11, on the Play panel. 11.1 is the first piece in 「房间里的家具」, or, with only one
    /// piece, its first action; choosing an action closes the panel and hands the chapter over.
    /// 11.2 is the walking styles at the panel's foot: the panel is scrolled there first.
    static func sendCat(_ context: Context) -> [TourStep] {
        var steps: [TourStep] = []
        if let lead = leadIn(.sendCat, context: context, first: "send-cat") { steps.append(lead) }
        let name = TourText.name(context.catName)
        let line: String
        let place: String
        // Begun on the Play panel, the page is read over the panel itself: its words say the panel
        // is right behind it, not "tap Play first" (LINES.md E.1).
        let onPanel = context.onPage == .interactionPanel
        if context.oneCatPiece {
            line = name.map {
                String(localized: "tour.sendCat.1.single", defaultValue: "这件家具上能做的事都在这儿，选一个，\(Wording.subject($0))就会过去。", table: "Tour",
                       comment: "Chapter 11, step 1, with one piece the cat can get onto: the window is on its actions. The argument is the cat's name.")
            } ?? String(localized: "tour.sendCat.1.single.long", defaultValue: "这件家具上能做的事都在这儿，选一个，猫咪就会过去。", table: "Tour",
                        comment: "Chapter 11, step 1, one piece, when the cat's name is too long to repeat.")
            place = onPanel
                ? String(localized: "tour.place.sendCat.single.onPanel", defaultValue: "这一页后面就是互动面板，这件家具能做的事就在里面。", table: "Tour",
                         comment: "Page mode, chapter 11 with one piece, read over the Play panel: where its actions are.")
                : String(localized: "tour.place.sendCat.single", defaultValue: "这件家具能做的事在互动面板里，先点“互动”就能看到。", table: "Tour",
                         comment: "Page mode, chapter 11 with one piece: where its actions are.")
        } else {
            line = name.map {
                String(localized: "tour.sendCat.1", defaultValue: "选一件家具，再选一个动作，\(Wording.subject($0))就会过去。", table: "Tour",
                       comment: "Chapter 11, step 1. The window is on Furniture in the room in the Play panel. The argument is the cat's name.")
            } ?? String(localized: "tour.sendCat.1.long", defaultValue: "选一件家具，再选一个动作，猫咪就会过去。", table: "Tour",
                        comment: "Chapter 11, step 1, when the cat's name is too long to repeat.")
            place = onPanel
                ? String(localized: "tour.place.sendCat.onPanel", defaultValue: "这一页后面就是互动面板，“房间里的家具”就在里面。", table: "Tour",
                         comment: "Page mode, chapter 11, read over the Play panel: where Furniture in the room is.")
                : String(localized: "tour.place.sendCat", defaultValue: "“房间里的家具”在互动面板里，先点“互动”就能看到。", table: "Tour",
                         comment: "Page mode, chapter 11: where Furniture in the room is.")
        }
        steps.append(TourStep(id: "11.1", target: .control("send-cat"), does: true, art: .h3, line: line, place: place, handsOff: true))
        steps.append(TourStep(id: "11.2", target: .control("walk-style"), art: .h2,
                              line: String(localized: "tour.sendCat.2", defaultValue: "它走路的样子也能换：散步、慢步、奔跑、蹦跳。", table: "Tour",
                                           comment: "Chapter 11, step 2. The window is on Walking style at the foot of the Play panel. The four are the menu's names."),
                              place: onPanel
                                ? String(localized: "tour.place.gait.onPanel", defaultValue: "“走路方式”在这一页后面那个互动面板的最下面。", table: "Tour",
                                         comment: "Page mode, chapter 11, read over the Play panel: where Walking style is.")
                                : String(localized: "tour.place.gait", defaultValue: "“走路方式”在互动面板的最下面，先点“互动”，再往下滑。", table: "Tour",
                                         comment: "Page mode, chapter 11: where Walking style is."),
                              gotIt: true, scrolls: true))
        return steps
    }

    /// Chapter 13, on the Play panel: the row is scrolled to before its window opens (T5.14).
    static func tabletop(_ context: Context) -> [TourStep] {
        var steps: [TourStep] = []
        if let lead = leadIn(.tabletop, context: context, first: "open-ar-tabletop") { steps.append(lead) }
        let place = context.onPage == .interactionPanel
            ? String(localized: "tour.place.tabletop.onPanel", defaultValue: "这一页后面就是互动面板，“放到桌上看看”就在里面。", table: "Tour",
                     comment: "Page mode, chapter 13, read over the Play panel: where See it on a table is.")
            : String(localized: "tour.place.tabletop", defaultValue: "“放到桌上看看”在互动面板里，先点“互动”就能看到。", table: "Tour",
                     comment: "Page mode, chapter 13: where See it on a table is.")
        steps.append(TourStep(id: "13.1", target: .control("open-ar-tabletop"), does: true, art: .h5,
                              line: String(localized: "tour.tabletop.1", defaultValue: "点这一行试试。要用相机，画面只在这台设备上，不录也不存。", table: "Tour",
                                           comment: "Chapter 13, the only step. The window is on See it on a table. Says no more than the row's own footer about the camera."),
                              place: place,
                              handsOff: true, gotIt: true, scrolls: true, bubbleAbove: true,
                              alsoCovers: "open-ar-tabletop-footer"))
        return steps
    }

    /// Chapter 14, in the room: the gear, then 「提醒」 in Settings, scrolled to first (Q-05). The
    /// tour stops at the row: the reminder page asks for permission itself when a reminder is
    /// switched on (PRODUCT_PLAN chapter 14).
    static func reminders(_ context: Context) -> [TourStep] {
        let first = context.anyReminderOn
            ? String(localized: "tour.reminders.1.someOn", defaultValue: "提醒在设置里。点这个齿轮看看。", table: "Tour",
                     comment: "Chapter 14, step 1, opened from Settings while a reminder is on. The window is on the gear (Settings).")
            : String(localized: "tour.reminders.1", defaultValue: "提醒在设置里，现在都关着。点这个齿轮看看。", table: "Tour",
                     comment: "Chapter 14, step 1. The window is on the gear (Settings). Next here ends the chapter.")
        return [
            TourStep(id: "14.1", target: .control("open-settings"), does: true, doneWhen: .control("open-reminders"), art: .h3,
                     line: first, place: TourText.placeSettings, nextEnds: true),
            TourStep(id: "14.2", target: .control("open-reminders"), does: true, art: .h3,
                     line: String(localized: "tour.reminders.2", defaultValue: "就是这一行。开哪几样、几点叫，都由你定。", table: "Tour",
                                  comment: "Chapter 14, step 2. The window is on Reminders in Settings."),
                     place: String(localized: "tour.place.reminders", defaultValue: "“提醒”在设置里靠下的那一组。", table: "Tour",
                                   comment: "Page mode, chapter 14: where Reminders is in Settings."),
                     handsOff: true, gotIt: true, scrolls: true),
        ]
    }

    /// Chapter 15, in the room: the gear. It does not name iCloud Drive (T5.14, plan A).
    static func backup(_ context: Context) -> [TourStep] {
        [TourStep(id: "15.1", target: .control("open-settings"), art: .h2,
                  line: String(localized: "tour.backup.1", defaultValue: "设置里的“备份与恢复”能导出一份，换设备也带得走。", table: "Tour",
                               comment: "Chapter 15, the only step. The window is on the gear (Settings). Backup & restore is a group title in Settings."),
                  place: TourText.placeSettings, gotIt: true)]
    }
}

extension TourText {
    static var placePhotoLibrary: String {
        String(localized: "tour.place.photoLibrary", defaultValue: "“照片库”在屏幕下方。", table: "Tour",
               comment: "Page mode: where the Photo library bookplate is. Used when chapter 9 is opened from Settings.")
    }
}
