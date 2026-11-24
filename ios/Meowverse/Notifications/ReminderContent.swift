import MeowverseCore
import UserNotifications

/// Turns a planned reminder into a notification. Text only: a lock screen is semi-public, so no
/// photo is ever attached. Only the cat's calls make a sound.
enum ReminderContent {
    nonisolated static let furnitureKey = "furnitureID"

    static func request(for reminder: PlannedReminder, catName: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title(for: reminder.kind, catName: catName)
        content.body = body(for: reminder.kind, catName: catName)
        switch reminder.kind {
        case .call:
            content.sound = .default
            content.threadIdentifier = "calls"
        case .onThisDay:
            content.threadIdentifier = "on-this-day"
        case .furniture:
            content.threadIdentifier = "furniture"
        case .catFact:
            content.threadIdentifier = "cat-facts"
        }
        if let id = reminder.furnitureID { content.userInfo = [furnitureKey: id] }
        let trigger = UNCalendarNotificationTrigger(dateMatching: reminder.fireDate, repeats: reminder.repeats)
        return UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)
    }

    static func title(for kind: PlannedReminder.Kind, catName: String) -> String {
        switch kind {
        case .call: catName
        case .onThisDay: String(localized: "历史上的今天")
        case .furniture: String(localized: "家具的回忆")
        // Its own key: the settings switch says 猫咪小知识 too, but is "Cat Facts" in English.
        case .catFact: String(localized: "notification.cat-fact.title", defaultValue: "猫咪小知识")
        }
    }

    static func body(for kind: PlannedReminder.Kind, catName: String) -> String {
        switch kind {
        case .call(let call): callLine(call)
        case .onThisDay(let memory): onThisDayLine(memory, catName: catName)
        case .furniture(let memory): furnitureLine(memory, catName: catName)
        case .catFact(let id): factText(id)
        }
    }

    /// A fact's text from the CatFacts table. No cat name: the fact is about cats in general.
    static func factText(_ id: String) -> String {
        Bundle.main.localizedString(forKey: id, value: nil, table: "CatFacts")
    }

    static func callLine(_ call: CatCall) -> String {
        switch call {
        case .ennEnAhh: String(localized: "嗯～喵呜～")
        case .snack: String(localized: "零食零食")
        case .food: String(localized: "开饭啦～")
        }
    }

    /// Says "on" or "in" only when the photo's link says so; otherwise just that the two were photographed.
    static func onThisDayLine(_ memory: OnThisDayMemory, catName: String) -> String {
        let subject = Wording.subject(catName), inline = Wording.inline(catName)
        let years = memory.yearsAgo, count = memory.photoCount
        let lastYear = years == 1
        guard let piece = memory.piece else {
            return lastYear
                ? String(localized: "去年的今天，你拍了 \(count) 张\(inline)的照片。")
                : String(localized: "\(years) 年前的今天，你拍了 \(count) 张\(inline)的照片。")
        }
        let name = Wording.mention(displayName: piece.displayName)
        switch piece.relation {
        case .on, .in:
            let place = piece.relation == .on ? Wording.on(name) : Wording.inside(name)
            return lastYear
                ? String(localized: "去年的今天，\(subject)在\(place)。")
                : String(localized: "\(years) 年前的今天，\(subject)在\(place)。")
        case .under, .near, .background, .unclear:
            return lastYear
                ? String(localized: "去年的今天，你拍下了\(inline)和\(name)。")
                : String(localized: "\(years) 年前的今天，你拍下了\(inline)和\(name)。")
        }
    }

    static func furnitureLine(_ memory: FurnitureMemory, catName: String) -> String {
        let inline = Wording.inline(catName), name = Wording.mention(displayName: memory.displayName), count = memory.photoCount
        return memory.isStored
            ? String(localized: "还记得收纳箱里的\(name)吗？它有 \(count) 张\(inline)的照片。")
            : String(localized: "还记得\(name)吗？它有 \(count) 张\(inline)的照片。")
    }
}
