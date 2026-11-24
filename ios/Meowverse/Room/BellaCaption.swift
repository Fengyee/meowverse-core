import MeowverseCore
import SwiftUI

/// What Bella is doing right now, as reported by the room scene.
enum BellaStatus: Equatable {
    case atEntrance
    /// On her way; `to` is the furniture she is heading for, nil for a stroll.
    case walking(to: String?, gait: GroundGait = .groundWalk)
    case onFloor(CatAction)
    case onFurniture(String, CatAction, String?)
    case following(CatPlayItem)
    case enjoying(CatPlayItem)

    var restingItemId: String? {
        if case .onFurniture(let id, _, _) = self { return id }
        return nil
    }

    /// One short line, e.g. "Bella 在沙发上窝着". Names are looked up live, so a rename shows at once.
    /// Every case is one whole sentence, so a translation can order the words its own way.
    func caption(items: [PhotoFurniture], catName: String) -> String {
        func name(_ id: String) -> String? {
            items.first { $0.instanceId == id }.map(Wording.mention)
        }
        let subject = Wording.subject(catName)
        switch self {
        case .atEntrance:
            return String(localized: "\(subject)在门口坐着")
        case .walking(let id, let gait):
            let destination = id.flatMap(name)
            switch gait {
            case .groundWalk:
                return destination.map { String(localized: "\(subject)正走向\($0)") } ?? String(localized: "\(subject)正在散步")
            case .gracefulWalk:
                return destination.map { String(localized: "\(subject)正迈着慢步走向\($0)") } ?? String(localized: "\(subject)正迈着慢步")
            case .groundRun:
                return destination.map { String(localized: "\(subject)正跑向\($0)") } ?? String(localized: "\(subject)正在奔跑")
            case .groundJump:
                return destination.map { String(localized: "\(subject)正蹦跳着靠近\($0)") } ?? String(localized: "\(subject)正在地上蹦跳")
            }
        case .onFloor(let action):
            return String(localized: "\(subject)在地上\(Self.word(action))")
        case .following(let item):
            return String(localized: "\(subject)正靠近\(Wording.inSentence(item.title))")
        case .enjoying(let item):
            let thing = Wording.inSentence(item.title)
            return item.isTreat ? String(localized: "\(subject)正在吃\(thing)") : String(localized: "\(subject)正在玩\(thing)")
        case .onFurniture(let id, let action, let site):
            guard let name = name(id) else { return String(localized: "\(subject)在地上\(Self.word(action))") }
            // A site that is the inside of the piece itself is said once: "在纸箱里坐着".
            if let site, CaptionPlace.forSite(site) == .insidePiece, [.sit, .loaf, .sleep].contains(action) {
                return String(localized: "\(subject)在\(Wording.inside(name))\(Self.word(action))")
            }
            if let site = site.map(Wording.captionSite) {
                if action == .hide { return String(localized: "\(subject)躲在\(name)的\(site)") }
                if action == .dig { return String(localized: "\(subject)在\(name)里扒砂") }
                if action == .play { return String(localized: "\(subject)在\(name)的\(site)拍玩具") }
                if action == .eat || action == .drink { return String(localized: "\(subject)在\(name)的\(site)\(Self.word(action))") }
                return String(localized: "caption.resting-at-site", defaultValue: "\(subject)在\(name)的\(Wording.on(site))\(Self.word(action))")
            }
            return String(localized: "\(subject)在\(Wording.on(name))\(Self.word(action))")
        }
    }

    /// What she is doing, as the end of a caption ("…在沙发上窝着"; in English "… is loafing on …").
    private static func word(_ action: CatAction) -> String {
        switch action {
        case .sit: String(localized: "坐着")
        case .loaf: String(localized: "窝着")
        case .sleep: String(localized: "睡觉")
        case .play: String(localized: "拍玩具")
        case .scratch: String(localized: "caption.scratching", defaultValue: "磨爪", comment: "Caption ending: what the cat is doing, as in the other caption endings")
        case .hide: String(localized: "躲着探头")
        case .eat: String(localized: "低头吃东西")
        case .drink: String(localized: "舔水")
        case .dig: String(localized: "扒砂")
        }
    }

}

extension AppModel {
    /// What the first cat in the room is doing, or that no cat is here.
    var roomCaption: String {
        guard let cat = leadCat else { return String(localized: "这个房间里现在没有猫咪") }
        return bellaStatus.caption(items: roomFurniture, catName: cat.name)
    }
}

/// The live caption under the room. Plain text for VoiceOver: read when focused, never announced.
struct BellaCaptionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Label(model.roomCaption, systemImage: "pawprint.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoomPaper.paper, in: .capsule)
            .overlay { Capsule().strokeBorder(RoomPaper.edge.opacity(0.65)).accessibilityHidden(true) }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("bella-caption")
    }
}
