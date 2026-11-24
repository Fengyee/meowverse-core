// Compiled only with MEOWVERSE_TALK_TO_BELLA=YES (Config.xcconfig): not in 1.0.
#if MEOWVERSE_TALK_TO_BELLA
import Foundation
import MeowverseCore
import os
import SwiftUI

/// Talk to Bella's pipeline (docs/TALK_TO_BELLA.md): tap → one sentence (`SpeechListener`) →
/// fixed phrases (`BellaCommandRules`) → the on-device model when the phrases miss and it is
/// available (`BellaIntentModel`) → `BellaCommandResolver` against the room → a `BellaPlan` the
/// room carries out with the Interactions menu's own calls.
///
/// Every tap starts a new request and drops the one before it. A request whose answer arrives
/// after a newer tap, after leaving the room or after switching rooms is thrown away: a late
/// answer never overrides what the person did since.
@MainActor
@Observable
final class TalkToBellaController {
    /// The room a request is about, read when the head is tapped and again when the answer is in.
    struct Room {
        let id: String
        let items: [PhotoFurniture]
        let catalog: FurnitureCatalog
        let catName: String
    }

    private(set) var state: BellaVoiceState = .idle
    /// The short line beside the head after a refusal.
    private(set) var hint: String?
    /// Where the last answer came from and what it led to, for UI tests (see `TestHook`).
    private(set) var probe = "none"

    /// Understood and puzzled hold this long, then the head goes back to idle.
    static let settle: Duration = .milliseconds(1500)
    /// Thinking longer than this counts as not understood, the same limit as the model's.
    static let thinkingLimit: Duration = BellaIntentModel.timeout + .milliseconds(300)
    /// The first time the head appears it says once what it is for.
    static let introKey = "talkToBella.introShown"

    @ObservationIgnored private let listener = SpeechListener()
    @ObservationIgnored private let intentModel = BellaIntentModel()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    private static let log = Logger(subsystem: "app.meowverse", category: "talkToBella")

    /// Marks the head unavailable when listening is already ruled out (no on-device recognition,
    /// a refused permission), and lifts that once it no longer is (permission given in Settings).
    func refreshAvailability() {
        if TestHook.transcript != nil { return }
        let ruledOut = SpeechListener.ruledOut
        if ruledOut, state != .unavailable {
            drop()
            state = .unavailable
        } else if !ruledOut, state == .unavailable {
            state = .idle
        }
    }

    /// The head was tapped. `room` gives the current room, or nil when the room cannot take a
    /// command now; `apply` carries out a plan; `openMenu` opens 互动 when voice is unavailable.
    func tap(room: @escaping () -> Room?, apply: @escaping (BellaPlan) -> Void, openMenu: () -> Void) {
        // Once the head has been tapped, the "tap me" line is not needed any more (art review E7).
        UserDefaults.standard.set(true, forKey: Self.introKey)
        switch state {
        case .unavailable:
            openMenu()
        case .listening:
            listener.stop()
        case .idle, .thinking, .understood, .puzzled:
            start(room: room, apply: apply)
        }
    }

    /// The "tap me" line (art review E3, E7): until the head has been tapped once, it shows once
    /// per launch when the room is free to show it, for the longest hint time.
    func introduce(catName: String) {
        guard !Self.introducedThisLaunch, !UserDefaults.standard.bool(forKey: Self.introKey),
              state == .idle, hint == nil, TestHook.transcript != nil || !SpeechListener.ruledOut else { return }
        Self.introducedThisLaunch = true
        show(String(localized: "点我，跟\(Wording.inline(catName))说句话", table: "TalkToBella"), token: generation,
             seconds: Self.longestHint)
    }

    @ObservationIgnored private static var introducedThisLaunch = false

    /// Stops listening and drops any answer still on its way. The head goes back to idle.
    func cancel() {
        guard state != .unavailable else { return }
        drop()
        state = .idle
    }

    private func drop() {
        generation += 1
        work?.cancel()
        work = nil
        listener.cancel()
        intentModel.reset()
        settleTask?.cancel()
        deadline?.cancel()
        clearHint()
    }

    private func start(room: @escaping () -> Room?, apply: @escaping (BellaPlan) -> Void) {
        guard let asked = room() else { return }
        drop()
        let token = generation
        let modelAllowed = TestHook.modelAllowed && BellaIntentModel.isAvailable
        if modelAllowed { intentModel.prewarm(for: BellaRoomOffer(items: asked.items, catalog: asked.catalog, catName: asked.catName)) }
        work = Task { [weak self] in
            guard let self else { return }
            let transcript: String
            if let scripted = TestHook.transcript {
                transcript = scripted
            } else {
                state = .listening(level: 0)
                let outcome = await listener.listen { [weak self] level in
                    guard let self, self.generation == token, case .listening = self.state else { return }
                    self.state = .listening(level: level)
                }
                guard generation == token, !Task.isCancelled else { return }
                switch outcome {
                case .heard(let words):
                    transcript = words
                case .nothing:
                    refuse(.notUnderstood, command: nil, source: nil, token: token)
                    return
                case .failed:
                    puzzle(String(localized: "现在用不了麦克风，稍后再试", table: "TalkToBella"), probe: "none failed", token: token)
                    return
                case .unavailable:
                    state = .unavailable
                    return
                }
            }
            state = .thinking
            watchThinking(token: token)
            let understanding = await understand(transcript, room: asked, modelAllowed: modelAllowed)
            // Late answers are dropped: a newer tap, leaving the room or another room.
            guard generation == token, !Task.isCancelled, let now = room(), now.id == asked.id else { return }
            deadline?.cancel()
            guard let understanding else {
                refuse(.notUnderstood, command: nil, source: nil, token: token)
                return
            }
            switch BellaCommandResolver.resolve(understanding.command, items: now.items, catalog: now.catalog) {
            case .success(let plan):
                probe = "\(understanding.source.rawValue) \(plan.probe)"
                Self.log.notice("carried out a \(understanding.source.rawValue, privacy: .public) command")
                apply(plan)
                state = .understood
                AccessibilityNotification.Announcement(Self.announcement(for: plan, items: now.items, catalog: now.catalog)).post()
                settle(token: token)
            case .failure(let refusal):
                let present = Set(now.items.compactMap { now.catalog.model(id: $0.modelId)?.category })
                refuse(refusal, command: understanding.command, source: understanding.source, present: present, token: token)
            }
        }
    }

    /// Fixed phrases first; the model only for what they miss, and only when it is available.
    /// A cat named after a lexicon word ("饼干，去吃") also goes to the model, which knows her
    /// name; the fixed phrase answers only if the model gives none.
    private func understand(_ transcript: String, room: Room, modelAllowed: Bool) async -> BellaUnderstanding? {
        let rules = BellaCommandRules.match(transcript, catName: room.catName)
            .map { BellaUnderstanding(command: $0, source: .rules) }
        if let rules, !(modelAllowed && BellaCommandRules.nameMayBeAWord(transcript, catName: room.catName)) {
            return rules
        }
        guard modelAllowed else { return nil }
        let offer = BellaRoomOffer(items: room.items, catalog: room.catalog, catName: room.catName)
        guard let command = await intentModel.command(for: transcript, offer: offer) else { return rules }
        return BellaUnderstanding(command: command, source: .model)
    }

    private func refuse(_ refusal: BellaRefusal, command: BellaCommand?, source: BellaCommandSource?,
                        present: Set<FurnitureCategory> = [], token: Int) {
        puzzle(Self.hint(for: refusal, command: command, present: present),
               probe: "\(source?.rawValue ?? "none") refused \(refusal.probe)", token: token)
    }

    private func puzzle(_ text: String, probe: String, token: Int) {
        self.probe = probe
        Self.log.notice("refused: \(probe, privacy: .public)")
        state = .puzzled
        AccessibilityNotification.Announcement(text).post()
        // Puzzled holds while its line shows; both go together (art review E6).
        settleTask?.cancel()
        show(text, token: token)
    }

    /// A hint stays by its length, at least 3 s (art review E4).
    private func show(_ text: String, token: Int, seconds: Double? = nil) {
        hint = text
        hintTask?.cancel()
        let seconds = seconds ?? Self.hintSeconds(text)
        hintTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.generation == token else { return }
            self.hint = nil
            if self.state == .puzzled { self.state = .idle }
        }
    }

    /// Hints stay by their length: at least 3 s, at most `longestHint` (art review E4).
    static let longestHint = 6.0
    static func hintSeconds(_ text: String) -> Double {
        min(longestHint, max(3, 1.5 + 0.15 * Double(text.count)))
    }

    /// Thinking has a way out: past the limit the request is dropped as not understood.
    private func watchThinking(token: Int) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: Self.thinkingLimit) } catch { return }
            guard let self, self.generation == token, self.state == .thinking else { return }
            self.drop()
            Self.log.notice("thinking took too long")
            self.refuse(.notUnderstood, command: nil, source: nil, token: self.generation)
        }
    }

    private func settle(token: Int) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.settle) } catch { return }
            guard let self, self.generation == token else { return }
            if self.state == .understood || self.state == .puzzled { self.state = .idle }
        }
    }

    private func clearHint() {
        hintTask?.cancel()
        hint = nil
    }

    /// What VoiceOver hears once a command is under way: what was understood ("好，去沙发").
    static func announcement(for plan: BellaPlan, items: [PhotoFurniture], catalog: FurnitureCatalog) -> String {
        switch plan {
        case .invite(let itemId, _, _):
            let item = items.first { $0.instanceId == itemId }
            guard let name = item.flatMap({ catalog.model(id: $0.modelId) })?.category.spokenName else {
                return String(localized: "好，这就去", table: "TalkToBella")
            }
            return String(localized: "好，去\(name)", table: "TalkToBella")
        case .play(let item):
            return item.isTreat ? String(localized: "好，吃点零食", table: "TalkToBella")
                : String(localized: "好，玩一会儿", table: "TalkToBella")
        case .come:
            return String(localized: "好，过来了", table: "TalkToBella")
        }
    }

    /// One short line per refusal. Category names come from the catalogue's own names.
    /// `noSuchFurniture(category)` means nothing offers that action: when a piece of that category
    /// is in the room (`present`), it just can't do this one, so don't say it is missing (QA P2-1).
    static func hint(for refusal: BellaRefusal, command: BellaCommand?, present: Set<FurnitureCategory> = []) -> String {
        switch refusal {
        case .notUnderstood:
            return String(localized: "没听懂，可以说“去沙发上躺着”", table: "TalkToBella")
        case .noSuchFurniture(let category):
            guard let category else { return String(localized: "房间里还没有能这样做的家具", table: "TalkToBella") }
            if present.contains(category) {
                return String(localized: "\(category.spokenName)上不能这样做", table: "TalkToBella")
            }
            return String(localized: "房间里还没有\(category.spokenName)", table: "TalkToBella")
        case .blocked:
            guard case .visit(_, let target?) = command else { return String(localized: "去那里的路被挡住了", table: "TalkToBella") }
            return String(localized: "去\(target.spokenName)的路被挡住了", table: "TalkToBella")
        }
    }

    /// DEBUG test switches. `-TalkToBellaTranscript "<一句话>"`: a tap skips the microphone and
    /// its permission prompts and sends this sentence down the rest of the pipeline.
    /// `-TalkToBellaRulesOnly`: never ask the model, so a simulator with Apple Intelligence gives
    /// the same answers as one without.
    enum TestHook {
        #if DEBUG
        static let transcript: String? = {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "-TalkToBellaTranscript"), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }()
        static let modelAllowed = !ProcessInfo.processInfo.arguments.contains("-TalkToBellaRulesOnly")
        #else
        static let transcript: String? = nil
        static let modelAllowed = true
        #endif
    }
}

private extension FurnitureCategory {
    /// The category's name inside a sentence: as the catalogue shows it in Chinese, lower case
    /// in other languages ("There's no sofa in the room yet").
    var spokenName: String { AppLanguage.isChinese ? title : title.lowercased(with: AppLanguage.locale) }
}

private extension BellaPlan {
    var probe: String {
        switch self {
        case .invite(let itemId, let siteId, let action): "invite \(itemId) \(siteId) \(action.rawValue)"
        case .play(let item): "play \(item.rawValue)"
        case .come(let cell): "come \(cell.x) \(cell.z)"
        }
    }
}

private extension BellaRefusal {
    var probe: String {
        switch self {
        case .notUnderstood: "notUnderstood"
        case .noSuchFurniture(let category): "noSuchFurniture \(category?.rawValue ?? "any")"
        case .blocked: "blocked"
        }
    }
}
#endif
